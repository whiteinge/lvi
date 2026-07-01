--- ex.lua -- the ex command dispatcher: one command line in, payload + status
--- out. This is THE shared core the design hinges on -- the `:` prompt, the
--- control socket, and (later) .exrc all call ex.dispatch, so a command means
--- the same thing everywhere (the tmux-like "identical at CLI and in config"
--- property). Status is "ok" or "err"; payload is the machine-readable result.
---
--- This is a deliberately MINIMAL first cut: enough addressing and commands to
--- navigate, mutate, and persist. A full ex address grammar (marks, /re/,
--- +/- offsets) and the rest of the command set land later, likely on LPeg.

local bufs = require("bufs")
local buffer = require("buffer")

local M = {}

-- Parse an optional leading address or a,b range. Returns a, b, rest (with a
-- and b nil when no address is present). Atoms supported: N, '.', '$', and '%'
-- as shorthand for 1,$.
local function parse_range(ed, s)
  s = s:gsub("^%s+", "")
  if s:sub(1, 1) == "%" then return 1, ed.buf:nlines(), s:sub(2) end
  local function atom(str)
    local n, r = str:match("^(%d+)(.*)$")
    if n then return tonumber(n), r end
    local c = str:sub(1, 1)
    if c == "." then return ed.cy, str:sub(2) end
    if c == "$" then return ed.buf:nlines(), str:sub(2) end
    return nil, str
  end
  local a, r = atom(s)
  if not a then return nil, nil, s end
  if r:sub(1, 1) == "," then
    local b, r2 = atom(r:sub(2))
    return a, (b or a), r2
  end
  return a, a, r
end

local function clampline(ed, n)
  local nl = ed.buf:nlines()
  if n < 1 then return 1 elseif n > nl then return nl else return n end
end

-- Resolve a command's effective line range: the given a..b, or the cursor line
-- when no address was supplied. Always returns from <= to, both clamped.
local function line_range(ed, a, b)
  local from = clampline(ed, a or ed.cy)
  local to   = clampline(ed, b or ed.cy)
  if from > to then from, to = to, from end
  return from, to
end

-- :set -- minimal option handling. Booleans: `wrap` / `nowrap` / `wrap?`.
-- Numerics: `tabstop=4` (alias `ts`) / `tabstop?`. Space-separated options are
-- each applied; queries are collected into the reply.
local function do_set(ed, args)
  ed.opts = ed.opts or { wrap = true, tabstop = 8 }
  local out = {}
  for opt in args:gmatch("%S+") do
    local name, val = opt:match("^(%a+)=(.+)$")
    if name then
      if name == "tabstop" or name == "ts" then
        ed.opts.tabstop = tonumber(val) or ed.opts.tabstop
      else return "unknown option: " .. name, "err" end
    elseif opt:sub(-1) == "?" then
      local n = opt:sub(1, -2)
      if n == "wrap" then out[#out + 1] = ed.opts.wrap and "wrap" or "nowrap"
      elseif n == "tabstop" or n == "ts" then out[#out + 1] = "tabstop=" .. ed.opts.tabstop
      else return "unknown option: " .. n, "err" end
    elseif opt == "wrap" then ed.opts.wrap = true
    elseif opt == "nowrap" then ed.opts.wrap = false
    else return "unknown option: " .. opt, "err" end
  end
  return table.concat(out, "\n"), "ok"
end

-- :hl GROUP [specs...] -- set a named highlight group's ranges (replacing it);
-- no specs clears the group. Specs: L:C1-C2 (byte cols), L:C (one col), L (whole
-- line). Named groups let independent lists (search, qf-current, ...) coexist.
local function do_hl(ed, args)
  ed.highlights = ed.highlights or {}
  local group, rest = args:match("^(%S+)%s*(.-)%s*$")
  if not group then return "usage: hl GROUP [L:C1-C2 ...]", "err" end
  local ranges = {}
  for spec in rest:gmatch("%S+") do
    local l, c1, c2 = spec:match("^(%d+):(%d+)%-(%d+)$")
    if l then
      ranges[#ranges + 1] = { line = tonumber(l), c1 = tonumber(c1), c2 = tonumber(c2) }
    else
      local l2, c = spec:match("^(%d+):(%d+)$")
      if l2 then
        ranges[#ranges + 1] = { line = tonumber(l2), c1 = tonumber(c), c2 = tonumber(c) }
      else
        local lw = spec:match("^(%d+)$")
        if lw then ranges[#ranges + 1] = { line = tonumber(lw), c1 = 1, c2 = math.huge }
        else return "bad highlight spec: " .. spec, "err" end
      end
    end
  end
  ed.highlights[group] = ranges
  return "", "ok"
end

-- Run a shell command. On a tty (ed.shell present) it runs interactively with
-- the real terminal; otherwise (socket/headless) its stdout is captured and
-- returned as the payload. ed._silent suppresses the interactive "Press ENTER".
local function do_shell(ed, cmd)
  if cmd == "" then return "no command", "err" end
  if ed.shell then
    ed.shell(cmd, not ed._silent)
    return "", "ok"
  end
  local p = io.popen(cmd, "r")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  return out, "ok"
end

-- Run cmd and capture stdout. On a tty, ed._silent (set by :silent) hands the
-- child the real terminal via ed.with_tty -- so an interactive program (fzy)
-- can draw its UI while we still capture its selection. Otherwise a plain pipe.
local function run_capture(ed, cmd)
  local run = function()
    local p = io.popen(cmd, "r")
    local o = p and p:read("*a") or ""
    if p then p:close() end
    return o
  end
  if ed._silent and ed.with_tty then return ed.with_tty(run) end
  return run()
end

-- Filter lines a..b through cmd (input via a temp file to avoid a bidirectional-
-- pipe deadlock), replacing them with its stdout. One splice = one undo.
local function do_filter(ed, a, b, cmd)
  if cmd == "" then return "no command", "err" end
  local from, to = line_range(ed, a, b)
  local tmp = os.tmpname()
  local f = io.open(tmp, "wb")
  f:write(table.concat(ed.buf:get(from, to), "\n"), "\n")
  f:close()
  local out = run_capture(ed, cmd .. " < " .. tmp)
  os.remove(tmp)
  local lines = {}
  if out ~= "" then
    local body = (out:sub(-1) == "\n") and out:sub(1, -2) or out
    for ln in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
  end
  ed.buf:splice(from, to - from + 1, lines)
  ed.cy, ed.cx = clampline(ed, from), 1
  return "", "ok"
end

function M.dispatch(ed, line)
  local a, b, rest = parse_range(ed, line)
  rest = rest:gsub("^%s+", "")
  local cmd, bang, args = rest:match("^(%a*)(!?)%s*(.-)%s*$")
  cmd = cmd or ""

  if cmd == "" then
    if bang == "!" then                                 -- :[range]!cmd
      if a then return do_filter(ed, a, b, args)        -- filter the range
      else return do_shell(ed, args) end                -- :!cmd -- run it
    end
    if a then ed.cy = clampline(ed, b); ed.cx = 1 end   -- bare address: goto line
    return "", "ok"
  end

  if cmd == "q" or cmd == "quit" then
    if ed.buf.modified and bang ~= "!" then
      return "No write since last change (add ! to override)", "err"
    end
    ed.running = false
    return "", "ok"

  elseif cmd == "w" or cmd == "write" then
    local p = (args ~= "" and args) or ed.buf.path
    if not p then return "No file name", "err" end
    local ok, n = pcall(ed.buf.write, ed.buf, p)
    if not ok then return "write failed: " .. tostring(n), "err" end
    return ('"%s" %dL, %dB written'):format(p, ed.buf:nlines(), n), "ok"

  elseif cmd == "wq" or cmd == "x" then
    local p = (args ~= "" and args) or ed.buf.path
    if not p then return "No file name", "err" end
    local ok, n = pcall(ed.buf.write, ed.buf, p)
    if not ok then return "write failed: " .. tostring(n), "err" end
    ed.running = false
    return "", "ok"

  elseif cmd == "d" or cmd == "delete" then
    local from, to = line_range(ed, a, b)
    ed.buf:delete(from, to)
    ed.cy = clampline(ed, from)
    ed.cx = 1
    return "", "ok"

  elseif cmd == "p" or cmd == "print" then
    local from, to = line_range(ed, a, b)
    return table.concat(ed.buf:get(from, to), "\n"), "ok"

  elseif cmd == "f" or cmd == "file" then
    return ('"%s" %d lines'):format(ed.buf.path or "[No File]", ed.buf:nlines()), "ok"

  elseif cmd == "u" or cmd == "undo" then
    local l = ed.buf:undo()
    if l then ed.cy, ed.cx = l, 1 end
    return "", "ok"

  elseif cmd == "redo" then
    local l = ed.buf:redo()
    if l then ed.cy, ed.cx = l, 1 end
    return "", "ok"

  elseif cmd == "e" or cmd == "edit" then
    if args ~= "" then
      bufs.open(ed, args)
      return "", "ok"
    elseif ed.buf.path then
      if ed.buf.modified and bang ~= "!" then
        return "No write since last change (add ! to override)", "err"
      end
      bufs.reload(ed)
      return "", "ok"
    end
    return "No file name", "err"

  elseif cmd == "bn" or cmd == "bnext" then
    bufs.next(ed); return "", "ok"
  elseif cmd == "bp" or cmd == "bprev" or cmd == "bprevious" then
    bufs.prev(ed); return "", "ok"
  elseif cmd == "b" or cmd == "buffer" then
    local n = tonumber(args)
    if n then
      if bufs.switch(ed, n) then return "", "ok" end
    elseif args ~= "" then
      local i = bufs.find(ed, args)
      if i then bufs.switch(ed, i); return "", "ok" end
    end
    return "no such buffer: " .. args, "err"
  elseif cmd == "r" or cmd == "read" then
    if args == "" then return "No file name", "err" end
    local text
    if args:sub(1, 1) == "!" then
      text = run_capture(ed, args:sub(2))
    else
      local fh = io.open(args, "rb")
      if not fh then return "can't open " .. args, "err" end
      text = fh:read("*a") or ""; fh:close()
    end
    local lines = {}
    if text ~= "" then
      lines = buffer.split((text:sub(-1) == "\n") and text:sub(1, -2) or text)
    end
    local at = (a or ed.cy) + 1                         -- read after the addressed line
    ed.buf:insert(at, lines)
    ed.cy, ed.cx = clampline(ed, at), 1
    return "", "ok"

  elseif cmd == "silent" or cmd == "sil" then
    ed._silent = true
    local p, s = M.dispatch(ed, args)                   -- run the sub-command silently
    ed._silent = nil
    return p, s

  elseif cmd == "ls" or cmd == "buffers" or cmd == "files" then
    return bufs.list(ed), "ok"
  elseif cmd == "bd" or cmd == "bdelete" then
    local ok, err = bufs.close(ed, bang == "!", tonumber(args))
    if not ok then return err, "err" end
    return "", "ok"
  elseif cmd == "qa" or cmd == "qall" or cmd == "quitall" then
    if bang ~= "!" then
      for _, rec in ipairs(ed.buffers or {}) do
        if rec.buf.modified then
          return "No write since last change in a buffer (add ! to override)", "err"
        end
      end
    end
    ed.running = false
    return "", "ok"

  elseif cmd == "set" or cmd == "se" then
    return do_set(ed, args)

  elseif cmd == "hl" or cmd == "highlight" then
    return do_hl(ed, args)

  elseif cmd == "nohl" or cmd == "nohlsearch" then
    ed.highlights = {}
    return "", "ok"

  elseif cmd == "pos" then                  -- cursor position query: line<TAB>col
    return ed.cy .. "\t" .. ed.cx, "ok"

  elseif cmd == "echo" then
    return args, "ok"

  elseif cmd == "normal" or cmd == "norm" then
    -- The send-keys escape hatch: feed the argument as normal-mode keystrokes
    -- into the interpreter's input funnel. This is what gives the socket (and
    -- the ':' prompt) full normal-mode power for the operations ex can't express
    -- (cursor-relative edits like 2dw, ci"). The driver drives the coroutine to
    -- consume them; from the ':' prompt the running coroutine consumes them next.
    ed.inject = ed.inject or {}
    for i = 1, #args do ed.inject[#ed.inject + 1] = args:byte(i) end
    return "", "ok"
  end

  return "unknown command: " .. cmd, "err"
end

return M
