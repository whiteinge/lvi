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

-- Events an `:on` hook may bind to. `change` fires (debounced) after a keyboard
-- edit settles; `write` fires right after a successful :w/:wq/:x (any surface);
-- `ready` fires once at startup, after the rc loads and the socket is live (the
-- startup analog of vim's VimEnter -- e.g. an rc hook loads a `-q` list); the
-- buf* events fire on buffer switches (editor.lua/bufs.lua).
local EVENTS = { change = true, write = true, ready = true,
                 bufenter = true, bufleave = true, bufdelete = true }

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
--
-- `modified` (alias `mod`) is the odd one out: it is not an ed.opts flag but the
-- buffer's derived dirty state, exposed here as the vi/vim option surface so a
-- tool can query it (`set modified?`) and clear it (`set nomodified`) over the
-- socket -- the primitive lvi-mirror uses to sync the dirty flag across panes.
-- Clearing aligns the undo saved-marker with the current state (what :w does
-- minus the I/O), so it composes with later edits/undos; setting parks the
-- marker at a never-reached id (-1) so the buffer reads dirty until a real save.
local function do_set(ed, args)
  ed.opts = ed.opts or { wrap = true, tabstop = 8, shiftwidth = 8, expandtab = false }
  local out = {}
  for opt in args:gmatch("%S+") do
    local name, val = opt:match("^(%a+)=(.+)$")
    if name then
      if name == "tabstop" or name == "ts" then
        ed.opts.tabstop = tonumber(val) or ed.opts.tabstop
      elseif name == "shiftwidth" or name == "sw" then
        ed.opts.shiftwidth = tonumber(val) or ed.opts.shiftwidth
      else return "unknown option: " .. name, "err" end
    elseif opt:sub(-1) == "?" then
      local n = opt:sub(1, -2)
      if n == "wrap" then out[#out + 1] = ed.opts.wrap and "wrap" or "nowrap"
      elseif n == "tabstop" or n == "ts" then out[#out + 1] = "tabstop=" .. ed.opts.tabstop
      elseif n == "shiftwidth" or n == "sw" then out[#out + 1] = "shiftwidth=" .. (ed.opts.shiftwidth or 8)
      elseif n == "expandtab" or n == "et" then out[#out + 1] = ed.opts.expandtab and "expandtab" or "noexpandtab"
      elseif n == "modified" or n == "mod" then out[#out + 1] = ed.buf.modified and "modified" or "nomodified"
      else return "unknown option: " .. n, "err" end
    elseif opt:sub(-1) == "!" then                      -- toggle a boolean (vim `set wrap!`)
      local n = opt:sub(1, -2)
      if n == "wrap" then ed.opts.wrap = not ed.opts.wrap
      elseif n == "expandtab" or n == "et" then ed.opts.expandtab = not ed.opts.expandtab
      elseif n == "modified" or n == "mod" then
        if ed.buf.modified then ed.buf._undo.saved = ed.buf._undo.now; ed.buf.modified = false
        else ed.buf._undo.saved = -1; ed.buf.modified = true end
      else return "not a boolean option: " .. n, "err" end
    elseif opt == "wrap" then ed.opts.wrap = true
    elseif opt == "nowrap" then ed.opts.wrap = false
    elseif opt == "expandtab" or opt == "et" then ed.opts.expandtab = true
    elseif opt == "noexpandtab" or opt == "noet" then ed.opts.expandtab = false
    elseif opt == "modified" or opt == "mod" then ed.buf._undo.saved = -1; ed.buf.modified = true
    elseif opt == "nomodified" or opt == "nomod" then ed.buf._undo.saved = ed.buf._undo.now; ed.buf.modified = false
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

-- Named terminal colors -> the 0-based ANSI index; fg adds 30, bg adds 40.
local COLORS = { black = 0, red = 1, green = 2, yellow = 3,
                 blue = 4, magenta = 5, cyan = 6, white = 7 }
local ATTRS  = { bold = 1, dim = 2, italic = 3, underline = 4, blink = 5, reverse = 7 }

-- Parse a style spec ("fg=red bg=234 bold underline") into SGR parameters
-- ("31;48;5;234;1;4"), or nil,err. fg/bg take a basic color name or a 0-255
-- number (256-color palette); bare words are attributes; `sgr=<params>` passes
-- raw SGR through verbatim (how ANSI backends carry their own colors, incl.
-- truecolor). Order is irrelevant to the terminal (the parameters combine).
local function parse_style(spec)
  local params = {}
  for tok in spec:gmatch("%S+") do
    local raw = tok:match("^sgr=([%d;]+)$")           -- raw SGR passthrough
    local key, val = tok:match("^(%a+)=(%w+)$")
    if raw then
      params[#params + 1] = raw
    elseif key == "fg" or key == "bg" then
      if COLORS[val] then
        params[#params + 1] = (key == "fg" and 30 or 40) + COLORS[val]
      else
        local n = tonumber(val)
        if not n or n < 0 or n > 255 then return nil, "bad color: " .. val end
        params[#params + 1] = (key == "fg" and "38;5;" or "48;5;") .. n
      end
    elseif key then
      return nil, "bad style key: " .. key
    elseif ATTRS[tok] then
      params[#params + 1] = ATTRS[tok]
    else
      return nil, "bad style spec: " .. tok
    end
  end
  return table.concat(params, ";")
end

-- :hi[ghlight] GROUP [fg=.. bg=.. attr.. pri=N] -- define a highlight group's
-- color (vim-style). No spec (or NONE) clears the style, leaving the group as
-- plain (invisible) text. `pri=N` sets the group's z-order: when two groups cover
-- the same cell the higher pri draws on top (default 0). Syntax stays at 0 so
-- overlays that must be seen through it set a positive pri (search uses pri=10).
-- Styles are theme state (set in the rc file) and persist across :nohl, which
-- clears only the transient ranges.
local function do_histyle(ed, args)
  local group, rest = args:match("^(%S+)%s*(.-)%s*$")
  if not group or group == "" then return "usage: hi GROUP [fg=.. bg=.. bold .. pri=N]", "err" end
  ed.hlstyles = ed.hlstyles or {}
  local pri = rest:match("pri=(%-?%d+)")        -- z-order is not an SGR param; pull it out
  if pri then
    ed.hlpri = ed.hlpri or {}
    ed.hlpri[group] = tonumber(pri)
    rest = rest:gsub("%s*pri=%-?%d+%s*", " "):match("^%s*(.-)%s*$")
  end
  if rest == "" or rest == "NONE" or rest == "none" then
    ed.hlstyles[group] = nil
    return "", "ok"
  end
  local params, err = parse_style(rest)
  if not params then return err, "err" end
  ed.hlstyles[group] = params
  return "", "ok"
end

-- Run cmd and capture stdout; returns stdout, exit_code. The exit code comes via
-- a temp file (`; echo $?`) since LuaJIT's popen:close() doesn't surface it, and
-- WITHOUT capturing stderr (which would fight an interactive finder's UI). On a
-- tty, ed._silent hands the child the real terminal (ed.with_tty) so fzy/fzf can
-- draw while we still capture its selection.
local function slurp(path)
  local h = io.open(path, "r"); if not h then return "" end
  local s = h:read("*a") or ""; h:close(); return s
end

-- Returns stdout, exit_code, stderr. stderr is captured to a temp file ONLY for
-- non-interactive commands (so it can go in an error message and not flash onto
-- the alt screen); an interactive finder keeps its stderr (that's its UI).
local function run_capture(ed, cmd)
  if ed.export_context then ed.export_context() end    -- stamp LVI_FILE/LINE/COL/CWORD
  local interactive = ed._silent and ed.with_tty
  local codef, errf = os.tmpname(), os.tmpname()
  local redir = interactive and "" or (" 2>" .. errf)
  local run = function()
    local p = io.popen(cmd .. redir .. "; echo $? >" .. codef, "r")
    local o = p and p:read("*a") or ""
    if p then p:close() end
    return o
  end
  local out = interactive and ed.with_tty(run) or run()
  local code = tonumber((slurp(codef):match("%d+"))) or 0
  local err = interactive and "" or slurp(errf)
  os.remove(codef); os.remove(errf)
  return out, code, err
end

-- First non-blank line of stderr, else "exit N" -- a concise failure reason.
local function fail_reason(err, code)
  return err:match("%S[^\n]*") or ("exit " .. code)
end

-- Run a shell command. On a tty (ed.shell present) it runs interactively with
-- the real terminal; otherwise (socket/headless) its stdout is captured and
-- returned as the payload. ed._silent suppresses the interactive "Press ENTER".
local function do_shell(ed, cmd)
  if cmd == "" then return "no command", "err" end
  if ed.shell then                                    -- interactive on a tty
    local code = ed.shell(cmd, not ed._silent)
    if code ~= 0 then return ("shell failed: exit %d"):format(code), "err" end
    return "", "ok"
  end
  local out, code, err = run_capture(ed, cmd)         -- socket/headless: capture
  if code ~= 0 then return ("!" .. cmd .. ": " .. fail_reason(err, code)), "err" end
  return out, "ok"
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
  local out, code, err = run_capture(ed, cmd .. " < " .. tmp)
  os.remove(tmp)
  if code ~= 0 then return "filter failed: " .. fail_reason(err, code) .. " (unchanged)", "err" end
  local lines = {}
  if out ~= "" then
    local body = (out:sub(-1) == "\n") and out:sub(1, -2) or out
    for ln in (body .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
  end
  ed.buf:splice(from, to - from + 1, lines)
  ed.cy, ed.cx = clampline(ed, from), 1
  return "", "ok"
end

-- Delegate a command lvi does not implement itself to the system ex (the whole
-- of vi's line-editing -- :s, :g, :m, :t, :j, full addressing -- for free, using
-- whatever ex is installed). Mechanism: the do_filter pattern over the WHOLE
-- buffer -- write it to a temp file, drive `ex -s` with a script, read it back.
--
-- The script is a PREAMBLE that mirrors lvi's state into ex, then the user's
-- command verbatim (so ex parses its own addresses), then wq!: we recreate each
-- lvi mark (so `:'a,'bs/...` resolves) and set ex's current line to lvi's cursor
-- (so a bare `:s` acts on the right line). No parsing of the user command needed.
--
-- Limits (documented, by design): output is discarded (this is for buffer edits,
-- not `:g//p`); ex errors are not reliably reportable (Vim's `ex -s` returns 1
-- even on success and hides stderr), so a bad command is a safe no-op rather than
-- a message -- reach for ex directly if you need to see why. The one hard failure
-- we do catch is ex being unrunnable. One splice = one undo.
local function do_ex(ed, line)
  local exe = os.getenv("LVI_EX") or "ex"
  local src = ed.buf:text()
  local pre = {}
  for m, pos in pairs(ed.marks or {}) do
    if m:match("^%l$") then pre[#pre + 1] = clampline(ed, pos[1]) .. "mark " .. m end
  end
  pre[#pre + 1] = tostring(clampline(ed, ed.cy))      -- set ex's current line to ours
  pre[#pre + 1] = line                                -- the user's command, addresses and all
  pre[#pre + 1] = "wq!"
  local tmp, sf = os.tmpname(), os.tmpname()
  local wf = io.open(tmp, "wb"); wf:write(src); wf:close()
  wf = io.open(sf, "wb"); wf:write(table.concat(pre, "\n"), "\n"); wf:close()
  local _, code = run_capture(ed, ("%s -s '%s' < '%s'"):format(exe, tmp, sf))
  local result = slurp(tmp)
  os.remove(tmp); os.remove(sf)
  if code == 127 then
    return ("cannot run '%s': not found (set $LVI_EX)"):format(exe), "err"
  end
  if result ~= src then                               -- skip a no-op (e.g. read-only cmd)
    ed.buf:splice(1, ed.buf:nlines(), buffer.split((result:gsub("\n$", ""))))
    ed.cy, ed.cx = clampline(ed, ed.cy), 1
  end
  return "", "ok"
end

-- Parse a key notation string into raw bytes. Names (case-insensitive):
-- <CR> <Esc> <Space> <Tab> <Bar> <Bslash> <lt> <NL>, and <C-x> for ctrl-keys.
-- Unknown <...> is left as a literal '<'.
local KEYNAMES = { CR = 13, RETURN = 13, NL = 10, ESC = 27, SPACE = 32,
                   TAB = 9, BAR = 124, BSLASH = 92, LT = 60 }
local function parse_keys(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    if s:sub(i, i) == "<" then
      local close = s:find(">", i + 1, true)
      local tok = close and s:sub(i + 1, close - 1):upper()
      local ctrl = tok and tok:match("^C%-(.)$")
      if tok and KEYNAMES[tok] then out[#out + 1] = string.char(KEYNAMES[tok]); i = close + 1
      elseif ctrl then out[#out + 1] = string.char(ctrl:byte() % 32); i = close + 1
      else out[#out + 1] = "<"; i = i + 1 end
    else
      out[#out + 1] = s:sub(i, i); i = i + 1
    end
  end
  return table.concat(out)
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
    -- A non-empty remainder with no recognized command word means the address
    -- itself uses syntax lvi does not parse (a mark like 'a, a /re/ search):
    -- hand the whole line to ex, which understands the full address grammar.
    if rest ~= "" then return do_ex(ed, line) end
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
    if ed.fire_event then ed.fire_event("write") end
    return ('"%s" %dL, %dB written'):format(p, ed.buf:nlines(), n), "ok"

  elseif cmd == "wq" or cmd == "x" then
    -- :x writes only when the buffer is modified, then quits -- so on a clean
    -- buffer it leaves the file's mtime untouched (its whole reason to exist
    -- over :wq, which always writes). An explicit target (:x file) is a save-as,
    -- so it still writes. ZZ routes here, inheriting the skip.
    if cmd == "x" and args == "" and not ed.buf.modified then
      ed.running = false
      return "", "ok"
    end
    local p = (args ~= "" and args) or ed.buf.path
    if not p then return "No file name", "err" end
    local ok, n = pcall(ed.buf.write, ed.buf, p)
    if not ok then return "write failed: " .. tostring(n), "err" end
    if ed.fire_event then ed.fire_event("write") end
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
    if args == "#" then                                 -- :e # -- the alternate buffer
      if bufs.alt(ed) then return "", "ok" end
      return "No alternate file", "err"
    elseif args ~= "" then
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
    if args == "#" then                                 -- :b # -- the alternate buffer
      if bufs.alt(ed) then return "", "ok" end
      return "No alternate file", "err"
    end
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
      local code, err
      text, code, err = run_capture(ed, args:sub(2))
      if code ~= 0 then return "read failed: " .. fail_reason(err, code), "err" end
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

  elseif cmd == "map" then
    local lhs, rhs = args:match("^(%S+)%s+(.+)$")
    if not lhs then return "usage: map LHS RHS", "err" end
    ed.maps = ed.maps or {}
    ed.maps[parse_keys(lhs)] = parse_keys(rhs)
    return "", "ok"
  elseif cmd == "unmap" then
    if args == "" then return "usage: unmap LHS", "err" end
    if ed.maps then ed.maps[parse_keys(args)] = nil end
    return "", "ok"

  elseif cmd == "silent" or cmd == "sil" then
    ed._silent = true
    local p, s = M.dispatch(ed, args)                   -- run the sub-command silently
    ed._silent = nil
    return p, s

  elseif cmd == "bg" then
    -- :bg CMD -- run a shell command detached, output discarded, WITHOUT handing
    -- over the terminal (unlike :!/:silent !, which drop out of and back into the
    -- alt screen -- a full-screen flash that is jarring when a map fires it
    -- repeatedly, e.g. n/N stepping a list). Same mechanism as :on hooks; the
    -- poll loop stays live, so the command's socket callbacks are serviced at
    -- once. For non-interactive tools only -- a command that needs the tty (a
    -- prompt, a pager) must use :! / :silent !.
    if args == "" then return "no command", "err" end
    if ed.spawn_bg then ed.spawn_bg(args) end
    return "", "ok"

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

  elseif cmd == "hl" then
    return do_hl(ed, args)                    -- apply a group's ranges (transient)

  elseif cmd == "hi" or cmd == "highlight" then
    return do_histyle(ed, args)               -- define a group's color (theme)

  elseif cmd == "nohl" or cmd == "nohlsearch" then
    ed.highlights = {}
    return "", "ok"

  elseif cmd == "on" then
    -- :on EVENT [command] -- run a shell command when EVENT fires (autocmd-ish,
    -- but pointed at external tools). EVENT is change|bufenter|bufleave|bufdelete.
    -- Multiple hooks per event compose; `:on EVENT` with no command clears them.
    -- Hooks run detached and non-blocking (editor.lua's spawn_bg). Only
    -- keyboard-initiated changes fire `change`, so a hook's own socket-driven
    -- edits can't retrigger it (see editor.lua). The buf* events fire on buffer
    -- switches with that buffer's path in LVI_FILE -- the glue that lets a
    -- cross-file list repaint the current buffer's subset on arrival.
    local event, rest = args:match("^(%S+)%s*(.-)%s*$")
    if not event or event == "" then return "usage: on EVENT [command]", "err" end
    if not EVENTS[event] then return "unknown event: " .. event, "err" end
    ed.hooks = ed.hooks or {}
    if rest == "" then ed.hooks[event] = nil; return "", "ok" end
    ed.hooks[event] = ed.hooks[event] or {}
    table.insert(ed.hooks[event], rest)
    return "", "ok"

  elseif cmd == "pos" then                  -- cursor position query: line<TAB>col
    return ed.cy .. "\t" .. ed.cx, "ok"

  elseif cmd == "status" then
    -- :status NAME [TEXT] -- set (or clear, if TEXT is empty) a named segment in
    -- the status line. Generic: the editor knows nothing about what fills it --
    -- an external list tool drives "[3/57] search", git a branch, etc. -- the
    -- same relationship :hl has with the highlight overlay. Segments render in
    -- name order (see render.lua).
    local name, text = args:match("^(%S+)%s*(.-)%s*$")
    if not name then return "usage: status NAME [TEXT]", "err" end
    ed.status = ed.status or {}
    ed.status[name] = (text ~= "") and text or nil
    return "", "ok"

  elseif cmd == "echo" then
    return args, "ok"

  elseif cmd == "redraw" then
    -- Force a full-screen redraw on the next paint (the driver honors
    -- ed.force_clear). Same gesture as Ctrl-L, reachable over the socket so a
    -- tool can repair the screen -- e.g. after a resize while the view is idle.
    ed.force_clear = true
    return "", "ok"

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

  -- Anything lvi does not handle itself is delegated to the system ex, so vi's
  -- full line-editing vocabulary works without reimplementing it here.
  return do_ex(ed, line)
end

return M
