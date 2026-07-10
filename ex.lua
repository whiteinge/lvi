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
local vpath = require("path")   -- `path` the name is taken by locals below

local M = {}

-- Events an `:on` hook may bind to. `change` fires (debounced) after a keyboard
-- edit settles; `write` fires right after a successful :w/:wq/:x (any surface);
-- `ready` fires once at startup, after the rc loads and the socket is live (the
-- startup analog of vim's VimEnter -- e.g. an rc hook loads a `-q` list); the
-- buf* events fire on buffer switches (editor.lua/bufs.lua).
local EVENTS = { change = true, write = true, ready = true,
                 bufenter = true, bufleave = true, bufdelete = true,
                 complete = true, scroll = true }

-- Command-line history. The ':' prompt (Ctrl-P/N) and the :cmdwin buffer both
-- append here via record_history and read ed.cmdhist directly. A rolling recent
-- set, not an audit log: capped and consecutive-deduped, session-only, never
-- written to disk. Appended to only when a command actually runs (like Vim) --
-- editing lines in the command window that you never execute leaves it alone.
local CMDHIST_MAX = 100
function M.record_history(ed, cmd)
  if cmd == "" then return end
  local h = ed.cmdhist
  if h[#h] == cmd then return end          -- collapse an immediate repeat
  h[#h + 1] = cmd
  if #h > CMDHIST_MAX then table.remove(h, 1) end
end

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
  local out = {}
  for opt in args:gmatch("%S+") do
    local name, val = opt:match("^(%a+)=(.+)$")
    if name then
      -- Validate, don't coerce: ts=0 would make every `col % ts` in disp NaN
      -- and render garbage with no error -- reject it here at the one surface.
      local n = tonumber(val)
      local valid = n and n >= 1 and math.floor(n) or nil
      if name == "tabstop" or name == "ts" then
        if not valid then return "bad tabstop: " .. val, "err" end
        ed.opts.tabstop = valid
      elseif name == "shiftwidth" or name == "sw" then
        if not valid then return "bad shiftwidth: " .. val, "err" end
        ed.opts.shiftwidth = valid
      else return "unknown option: " .. name, "err" end
    elseif opt:sub(-1) == "?" then
      local n = opt:sub(1, -2)
      if n == "wrap" then out[#out + 1] = ed.opts.wrap and "wrap" or "nowrap"
      elseif n == "tabstop" or n == "ts" then out[#out + 1] = "tabstop=" .. ed.opts.tabstop
      elseif n == "shiftwidth" or n == "sw" then out[#out + 1] = "shiftwidth=" .. ed.opts.shiftwidth
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
  local pri = rest:match("pri=(%-?%d+)")        -- z-order is not an SGR param; pull it out
  if pri then
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
  local codef, errf = vpath.tmp(), vpath.tmp()  -- private dir, not world-readable /tmp
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

-- POSIX ex file-argument expansion. The spec: a file argument containing any
-- of ~ { [ * ? $ " ' ` \ "shall be subjected to the process of shell
-- expansions", via the shell echoing the text back to ex. We do exactly that
-- (through run_capture, which stamps the LVI_* context vars first), so tilde,
-- $VAR -- including $LVI_FILE, this editor's substitute for ex's % -- and
-- globs all mean whatever sh(1) says; no expansion code of our own. One
-- deliberate departure from the spec's letter: the reprint verb is
-- `printf '%s\n'`, not echo -- XSI echo interprets backslash sequences
-- (mangling any name that contains one), and printf's one-word-per-LINE
-- output makes the one-file rule exact, so a quoted name even keeps its
-- spaces (:w "foo bar" works). More than one line is rejected: every caller
-- names exactly one file. Expansion runs the shell on user text ($(cmd)
-- executes cmd); no new capability -- the same surfaces already have :! --
-- but a script splicing picked names into a w/e/r line must backslash-escape
-- the metacharacters (contrib/lvi-open and lvi-shell.sh do).
-- Empty arg -> nil, no error (callers fall back to the buffer's own path).
local function expand_file(ed, s)
  if s == "" then return nil end
  if not s:find("[~{%[%*%?%$\"'`\\]") then return s end
  local out, code, err = run_capture(ed, "printf '%s\\n' " .. s)
  if code ~= 0 then return nil, "expansion failed: " .. fail_reason(err, code) end
  out = out:gsub("\n$", "")
  if out == "" then return nil, "expansion gave no file name: " .. s end
  if out:find("\n", 1, true) then return nil, "ambiguous file name (expands to several lines): " .. s end
  return out
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
  local tmp = vpath.tmp()                       -- carries buffer text: keep it private
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
  for m, pos in pairs(ed.marks) do
    if m:match("^%l$") then pre[#pre + 1] = clampline(ed, pos[1]) .. "mark " .. m end
  end
  pre[#pre + 1] = tostring(clampline(ed, ed.cy))      -- set ex's current line to ours
  pre[#pre + 1] = line                                -- the user's command, addresses and all
  pre[#pre + 1] = "wq!"
  local tmp, sf = vpath.tmp(), vpath.tmp()      -- carries buffer text: keep it private
  local wf = io.open(tmp, "wb"); wf:write(src); wf:close()
  wf = io.open(sf, "wb"); wf:write(table.concat(pre, "\n"), "\n"); wf:close()
  local _, code = run_capture(ed, ("%s -s '%s' < '%s'"):format(exe, tmp, sf))
  local result = slurp(tmp)
  os.remove(tmp); os.remove(sf)
  if code == 127 then
    return ("cannot run '%s': not found (set $LVI_EX)"):format(exe), "err"
  end
  if result ~= src then                               -- skip a no-op (e.g. read-only cmd)
    -- Splice only the window that actually changed: trim the common line
    -- prefix and suffix first. An ex one-liner (`:s` on one line of a large
    -- file) becomes a small splice instead of a whole-buffer one, keeping the
    -- undo record proportional to the change -- and, critically, giving the
    -- splice hook (mark/jumplist adjustment) a truthful region: a whole-buffer
    -- splice would read as "everything replaced" and clamp every mark to line
    -- 1. Scattered edits (`:g//d`) still collapse to one first-to-last window,
    -- so marks inside it clamp -- an accepted approximation.
    local new = buffer.split((result:gsub("\n$", "")))
    local old_n, new_n = ed.buf:nlines(), #new
    local pre = 0
    while pre < old_n and pre < new_n and ed.buf:line(pre + 1) == new[pre + 1] do
      pre = pre + 1
    end
    local suf = 0
    while suf < old_n - pre and suf < new_n - pre
      and ed.buf:line(old_n - suf) == new[new_n - suf] do
      suf = suf + 1
    end
    local mid = {}
    for i = pre + 1, new_n - suf do mid[#mid + 1] = new[i] end
    ed.buf:splice(pre + 1, old_n - pre - suf, mid)
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

-- True when writing buf to `p` risks clobbering another writer: p is the
-- buffer's own file and its mtime moved since our last read/write of it (the
-- stamp machinery wired in editor.lua; absent headless, where the check is
-- skipped). A save-as to a different path is not a conflict -- the user is
-- explicitly aiming elsewhere.
local function write_conflict(ed, buf, p)
  return p == buf.path and ed.file_changed ~= nil and ed.file_changed(buf)
end

-- Write every modified buffer to its own path (the :wa/:xa engine). Iterates
-- ed.buffers -- each rec.buf is the live object (ed.buf IS the current slot's
-- buf by reference, so its unsaved edits are seen without a save()); falls back
-- to the lone ed.buf in headless/single-buffer contexts. Changed-only, like :x:
-- a clean buffer is skipped so its mtime is untouched. A modified buffer with no
-- name is an error (E141-style) -- you can't write what has no path -- and stops
-- the run before any quit. Fires `write` once per buffer actually written.
-- Returns nwritten, or nil, errmsg.
local function write_all(ed, force)
  local n = 0
  for _, rec in ipairs(ed.buffers or { { buf = ed.buf } }) do
    local buf = rec.buf
    if buf.modified then
      if not buf.path then return nil, "No file name for a buffer" end
      if not force and write_conflict(ed, buf, buf.path) then
        return nil, ("File changed since last read: %s (add ! to override)"):format(buf.path)
      end
      local ok, err = pcall(buf.write, buf)
      if not ok then return nil, "write failed: " .. tostring(err) end
      if ed.stamp then ed.stamp(buf) end
      -- Pass the buffer so the hook's LVI_FILE names the file actually written,
      -- not whichever buffer happens to be current (same contract as bufdelete).
      if ed.fire_event then ed.fire_event("write", buf) end
      n = n + 1
    end
  end
  return n
end

-- ---- the command table --------------------------------------------------------
-- Every spelling lvi answers to maps to one handler; handlers receive
-- (ed, c) with c = { a, b (parsed range), bang (boolean), args, line (verbatim) }.
-- These names are the ones lvi OWNS: they shadow the system ex's commands of
-- the same name (everything else falls through to do_ex), so ADDING a name
-- here silently changes the meaning of any script that was reaching ex through
-- the fallthrough. Additions must also land in the manpage's owned-names note;
-- :sysex is the pin for scripts that want the system ex's semantics regardless.
local CMDS = {}
local function def(names, fn)
  for name in names:gmatch("%S+") do CMDS[name] = fn end
end

-- The command window (:cmdwin). A scratch buffer holding recent history, one
-- command per line, cursor on a trailing blank line: you edit commands with the
-- full editor (motions, operators, undo, your own :s) instead of a cramped
-- one-line prompt, then run the line under the cursor. There is deliberately NO
-- buffer-local keymap -- the buffer is ordinary and Enter keeps its meaning;
-- only bare :w on it is intercepted (to run) and :bd cancels. Reordering or
-- editing lines you never run has no effect: history is a scratch view, only
-- appended to when a command actually runs, never rewritten from the buffer.
local function cmdwin_populate(win, hist)
  win:delete(1, win:nlines())              -- -> a single empty line: the trailing blank
  if #hist > 0 then win:insert(1, hist) end -- history above it, blank stays last
end

-- Run the line under the cursor against the buffer :cmdwin was opened from,
-- then tear the window down. Returns that command's own payload/status, so it
-- surfaces exactly as if it had been typed at the ':' prompt.
local function cmdwin_exec(ed)
  local win = ed.buf
  local origin = win.cmdwin_origin
  local cmd = win:line(ed.cy):gsub("^%s+", ""):gsub("%s+$", "")
  local oi = origin and bufs.index_of(ed, origin)
  if oi then bufs.switch(ed, oi) end        -- back to where the window was opened
  local ci = bufs.index_of(ed, win)
  if ci then bufs.close(ed, true, ci) end   -- drop the scratch window (force: it's scratch anyway)
  if cmd == "" then return "", "ok" end     -- blank line: leave, run nothing
  M.record_history(ed, cmd)
  return M.dispatch(ed, cmd)                -- origin is current now, so it runs there
end

def("q quit", function(ed, c)
  if ed.buf.modified and not c.bang then
    return "No write since last change (add ! to override)", "err"
  end
  ed.running = false
  return "", "ok"
end)

def("w write", function(ed, c)
  -- In the command window, bare :w runs the current line instead of writing.
  -- :w <file> still saves normally -- a handy "dump my recent commands to disk".
  if ed.buf.cmdwin_origin and c.args == "" then return cmdwin_exec(ed) end
  local p, xerr = expand_file(ed, c.args)
  if xerr then return xerr, "err" end
  p = p or ed.buf.path
  if not p then return "No file name", "err" end
  if not c.bang and write_conflict(ed, ed.buf, p) then
    return "File changed since last read (add ! to override)", "err"
  end
  local ok, n = pcall(ed.buf.write, ed.buf, p)
  if not ok then return "write failed: " .. tostring(n), "err" end
  if ed.stamp then ed.stamp(ed.buf) end
  if ed.fire_event then ed.fire_event("write") end
  return ('"%s" %dL, %dB written'):format(p, ed.buf:nlines(), n), "ok"
end)

-- Snapshot the live buffer (unsaved edits and all) to the per-view scratch
-- path (ed.buffer_scratch, exported as $LVI_BUFFER). The companion to
-- `:silent !` for a tool that needs BOTH the terminal and the live buffer (a
-- picker built from unsaved text, e.g. contrib/lvi-tags), which the frozen
-- poll loop otherwise can't serve over the socket. Runs inline, before any
-- shell-out freezes us. We write the bytes ourselves rather than via
-- buf:write, which would REPOINT buf.path to the scratch file and clear
-- modified -- this must leave the buffer's identity and dirty state alone.
def("wbuf", function(ed)
  local p = ed.buffer_scratch
  if not p then return "no buffer scratch path", "err" end
  local ok, err = pcall(function()
    local f = assert(io.open(p, "wb"))
    f:write(ed.buf:text()); f:close()
  end)
  if not ok then return "wbuf failed: " .. tostring(err), "err" end
  return "", "ok"
end)

-- :x writes only when the buffer is modified, then quits -- so on a clean
-- buffer it leaves the file's mtime untouched (its whole reason to exist
-- over :wq, which always writes). An explicit target (:x file) is a save-as,
-- so it still writes. ZZ routes here, inheriting the skip.
def("wq x", function(ed, c)
  if c.name == "x" and c.args == "" and not ed.buf.modified then
    ed.running = false
    return "", "ok"
  end
  local p, xerr = expand_file(ed, c.args)
  if xerr then return xerr, "err" end
  p = p or ed.buf.path
  if not p then return "No file name", "err" end
  if not c.bang and write_conflict(ed, ed.buf, p) then
    return "File changed since last read (add ! to override)", "err"
  end
  local ok, n = pcall(ed.buf.write, ed.buf, p)
  if not ok then return "write failed: " .. tostring(n), "err" end
  if ed.stamp then ed.stamp(ed.buf) end
  if ed.fire_event then ed.fire_event("write") end
  ed.running = false
  return "", "ok"
end)

def("d delete", function(ed, c)
  local from, to = line_range(ed, c.a, c.b)
  ed.buf:delete(from, to)
  ed.cy = clampline(ed, from)
  ed.cx = 1
  return "", "ok"
end)

def("p print", function(ed, c)
  local from, to = line_range(ed, c.a, c.b)
  return table.concat(ed.buf:get(from, to), "\n"), "ok"
end)

def("f file", function(ed)
  return ('"%s" %d lines'):format(ed.buf.path or "[No File]", ed.buf:nlines()), "ok"
end)

def("u undo", function(ed)
  local l = ed.buf:undo()
  if l then ed.cy, ed.cx = l, 1 end
  return "", "ok"
end)

def("redo", function(ed)
  local l = ed.buf:redo()
  if l then ed.cy, ed.cx = l, 1 end
  return "", "ok"
end)

def("e edit", function(ed, c)
  if c.args == "#" then                               -- :e # -- the alternate buffer
    if bufs.alt(ed) then return "", "ok" end
    return "No alternate file", "err"
  elseif c.args ~= "" then
    local p, xerr = expand_file(ed, c.args)
    if xerr then return xerr, "err" end
    bufs.open(ed, p)
    return "", "ok"
  elseif ed.buf.path then
    if ed.buf.modified and not c.bang then
      return "No write since last change (add ! to override)", "err"
    end
    bufs.reload(ed)
    return "", "ok"
  end
  return "No file name", "err"
end)

def("bn bnext", function(ed) bufs.next(ed); return "", "ok" end)
def("bp bprev bprevious", function(ed) bufs.prev(ed); return "", "ok" end)

def("b buffer", function(ed, c)
  if c.args == "#" then                               -- :b # -- the alternate buffer
    if bufs.alt(ed) then return "", "ok" end
    return "No alternate file", "err"
  end
  local n = tonumber(c.args)
  if n then
    if bufs.switch(ed, n) then return "", "ok" end
  elseif c.args ~= "" then
    local i = bufs.find(ed, c.args)
    if i then bufs.switch(ed, i); return "", "ok" end
  end
  return "no such buffer: " .. c.args, "err"
end)

def("r read", function(ed, c)
  if c.args == "" then return "No file name", "err" end
  local text
  if c.args:sub(1, 1) == "!" then
    local code, err
    text, code, err = run_capture(ed, c.args:sub(2))
    if code ~= 0 then return "read failed: " .. fail_reason(err, code), "err" end
  else
    local p, xerr = expand_file(ed, c.args)
    if xerr then return xerr, "err" end
    local fh = io.open(p, "rb")
    if not fh then return "can't open " .. p, "err" end
    text = fh:read("*a") or ""; fh:close()
  end
  local lines = {}
  if text ~= "" then
    lines = buffer.split((text:sub(-1) == "\n") and text:sub(1, -2) or text)
  end
  local at = (c.a or ed.cy) + 1                       -- read after the addressed line
  ed.buf:insert(at, lines)
  ed.cy, ed.cx = clampline(ed, at), 1
  return "", "ok"
end)

def("map", function(ed, c)
  local lhs, rhs = c.args:match("^(%S+)%s+(.+)$")
  if not lhs then return "usage: map LHS RHS", "err" end
  ed.maps[parse_keys(lhs)] = parse_keys(rhs)
  return "", "ok"
end)

def("unmap", function(ed, c)
  if c.args == "" then return "usage: unmap LHS", "err" end
  ed.maps[parse_keys(c.args)] = nil
  return "", "ok"
end)

def("silent sil", function(ed, c)
  ed._silent = true
  -- pcall so a Lua error in the sub-command cannot leak the flag (which would
  -- silence every later :! for the rest of the session); the error itself
  -- still propagates to the caller's handler.
  local ok, p, s = pcall(M.dispatch, ed, c.args)
  ed._silent = nil
  if not ok then error(p, 0) end
  return p, s
end)

-- :bg CMD -- run a shell command detached, output discarded, WITHOUT handing
-- over the terminal (unlike :!/:silent !, which drop out of and back into the
-- alt screen -- a full-screen flash that is jarring when a map fires it
-- repeatedly, e.g. n/N stepping a list). Same mechanism as :on hooks; the
-- poll loop stays live, so the command's socket callbacks are serviced at
-- once. For non-interactive tools only -- a command that needs the tty (a
-- prompt, a pager) must use :! / :silent !.
def("bg", function(ed, c)
  if c.args == "" then return "no command", "err" end
  if ed.spawn_bg then ed.spawn_bg(c.args) end
  return "", "ok"
end)

-- POSIX :sh -- an interactive shell; exit it to return to the editor. With
-- LVI_WID in its environment this doubles as the path-completion escape hatch:
-- build a path with the shell's own completion, queue a write for this view
-- (`lvi -w "$LVI_WID" -d -- "w $PWD/name"`), and exit -- it runs the moment we
-- resume. Detached (-d) is the only way in: our loop is frozen while the shell
-- runs (as under any tty shell-out), so a synchronous client would hang, and
-- once hook children fill the listen backlog even connect() blocks.
def("sh shell", function(ed)
  return do_shell(ed, os.getenv("SHELL") or "sh")
end)

def("ls buffers files", function(ed) return bufs.list(ed), "ok" end)

-- :cmdwin [seed] -- open the command window (see the helpers above). An optional
-- seed becomes the trailing/current line, so Ctrl-F at the ':' prompt can carry
-- a half-typed command in. Reuses a resident window rather than stacking them.
def("cmdwin", function(ed, c)
  if ed.buf.cmdwin_origin then return "", "ok" end       -- already in the window
  local origin = ed.buf
  local win
  for _, rec in ipairs(ed.buffers or {}) do
    if rec.buf.cmdwin_origin then win = rec.buf; break end
  end
  if win then bufs.switch(ed, bufs.index_of(ed, win))
  else win = bufs.scratch(ed, "[Command Line]") end
  win.cmdwin_origin = origin
  cmdwin_populate(win, ed.cmdhist)
  if c.args ~= "" then win:set(win:nlines(), c.args) end  -- seed the trailing line
  ed.cy = win:nlines(); ed.cx = 1; ed.top = 1; ed.leftcol = 0
  ed.message = "command window -- :w runs the current line, :bd cancels"
  return "", "ok"
end)

def("bd bdelete", function(ed, c)
  local ok, err = bufs.close(ed, c.bang, tonumber(c.args))
  if not ok then return err, "err" end
  return "", "ok"
end)

def("qa qall quitall", function(ed, c)
  if not c.bang then
    for _, rec in ipairs(ed.buffers or {}) do
      if rec.buf.modified then
        return "No write since last change in a buffer (add ! to override)", "err"
      end
    end
  end
  ed.running = false
  return "", "ok"
end)

def("wa wall", function(ed, c)
  local n, err = write_all(ed, c.bang)
  if not n then return err, "err" end
  return ("%d buffer%s written"):format(n, n == 1 and "" or "s"), "ok"
end)

-- Write all changed buffers, then quit -- :wa + :qa. Changed-only (see
-- write_all), so like :x it leaves clean buffers' files untouched; xa and
-- wqa are aliases here (lvi has no readonly notion for wqa to force past).
def("xa xall wqa wqall", function(ed, c)
  local _, err = write_all(ed, c.bang)
  if err then return err, "err" end
  ed.running = false
  return "", "ok"
end)

-- Quit unconditionally, discarding any changes, and make the editor process
-- exit non-zero -- the scriptable "abort" (git commit et al. treat a nonzero
-- editor as "cancel this operation"). No modified check: cancelling is the
-- whole point. :cq N exits with code N; bare :cq (and :cq!) exits 1.
def("cq cquit", function(ed, c)
  ed.exit_code = tonumber(c.args) or 1
  ed.running = false
  return "", "ok"
end)

def("set se", function(ed, c) return do_set(ed, c.args) end)
def("hl", function(ed, c) return do_hl(ed, c.args) end)          -- transient ranges
def("hi highlight", function(ed, c) return do_histyle(ed, c.args) end) -- theme
def("nohl nohlsearch", function(ed) ed.highlights = {}; return "", "ok" end)

-- :[range]fold -- create a closed fold over the address range (>= 2 lines).
-- With no range, args may carry one or more "L1,L2" specs (space-separated), so
-- an external tool -- a fold-by-indent or fold-by-hunk script over the socket --
-- can push every fold in one command, the same way :hl pushes ranges. Folds are
-- a transient view overlay (see fold.lua): they never touch the buffer, so :w
-- and the delegated-ex path see all lines regardless. Companions: :foldopen /
-- :foldclose open/close every fold (the tool-facing spelling of zR / zM);
-- :foldclear removes them all.
def("fold", function(ed, c)
  ed.folds = ed.folds or {}
  local function add(a, b) if b > a then ed.folds[#ed.folds + 1] = { s = a, e = b, open = false } end end
  if c.a then add(math.min(c.a, c.b), math.max(c.a, c.b)) end
  for s1, s2 in c.args:gmatch("(%d+)%s*[,:%s]%s*(%d+)") do
    local a, b = tonumber(s1), tonumber(s2)
    add(math.min(a, b), math.max(a, b))
  end
  return "", "ok"
end)
def("foldclear", function(ed) ed.folds = {}; return "", "ok" end)
def("foldopen",  function(ed) for _, f in ipairs(ed.folds or {}) do f.open = true  end; return "", "ok" end)
def("foldclose", function(ed) for _, f in ipairs(ed.folds or {}) do f.open = false end; return "", "ok" end)

-- :on EVENT [command] -- run a shell command when EVENT fires (autocmd-ish,
-- but pointed at external tools). EVENT is change|bufenter|bufleave|bufdelete.
-- Multiple hooks per event compose; `:on EVENT` with no command clears them.
-- Hooks run detached and non-blocking (editor.lua's spawn_bg). Only
-- keyboard-initiated changes fire `change`, so a hook's own socket-driven
-- edits can't retrigger it (see editor.lua). The buf* events fire on buffer
-- switches with that buffer's path in LVI_FILE -- the glue that lets a
-- cross-file list repaint the current buffer's subset on arrival.
-- `complete` is the exception to all of the above: not auto-fired but read
-- SYNCHRONOUSLY by insert-mode Ctrl-P/Ctrl-N, which runs the single registered
-- command with the tty and inserts its stdout -- the completion funnel (see
-- editor.lua's complete_run and normal.lua). Being single, it REPLACES on
-- re-register instead of composing.
def("on", function(ed, c)
  local event, rest = c.args:match("^(%S+)%s*(.-)%s*$")
  if not event or event == "" then return "usage: on EVENT [command]", "err" end
  if not EVENTS[event] then return "unknown event: " .. event, "err" end
  if rest == "" then ed.hooks[event] = nil; return "", "ok" end
  -- `complete` names a single completer (you can't merge two pickers), so it
  -- REPLACES; the fire-and-forget events compose (append).
  if event == "complete" then ed.hooks.complete = { rest }; return "", "ok" end
  ed.hooks[event] = ed.hooks[event] or {}
  table.insert(ed.hooks[event], rest)
  return "", "ok"
end)

-- :fire [EVENT] -- raise an event by hand (default: change). The change
-- hooks are deliberately armed only by keyboard edits (the anti-loop gate,
-- see :on above), which leaves a tool that edits over the socket -- a
-- formatter, a diff-hunk applier -- with stale hook consumers (e.g. syntax
-- highlighting) until the next keystroke. Running `:fire` after its edits
-- is the explicit opt-in: `change` arms the normal idle debounce exactly
-- like a keystroke; any other event fires its hooks immediately. A tool
-- whose own `on change` hook edits and then fires change WILL loop -- but
-- now by its own explicit hand, not by accident.
def("fire", function(ed, c)
  local event = (c.args ~= "" and c.args) or "change"
  if not EVENTS[event] then return "unknown event: " .. event, "err" end
  if event == "change" then ed.change_pending = true
  elseif ed.fire_event then ed.fire_event(event) end
  return "", "ok"
end)

def("pos", function(ed) return ed.cy .. "\t" .. ed.cx, "ok" end)

-- Viewport-top query/set -- the socket sibling of :pos, exposing the scroll
-- position so an external tool can read it and drive it (scrollbind: bind two
-- views' tops so they scroll together; see contrib/lvi-diff). Bare :top reports
-- the top buffer line. `:top N` scrolls so line N is the top row. We can't move
-- the top without a visible cursor -- refresh() re-scrolls to keep the cursor
-- on screen and would undo a bare top set -- so :top N parks the cursor AT the
-- new top line (== `:N` then `zt`); refresh then sees cursor==top and holds it.
def("top", function(ed, c)
  if c.args == "" then return tostring(ed.top), "ok" end
  local n = tonumber(c.args)
  if not n then return "usage: top [N]", "err" end
  n = clampline(ed, n)
  ed.cy, ed.cx = n, 1
  ed.top, ed.topsub = n, 0
  return "", "ok"
end)

-- :status NAME [TEXT] -- set (or clear, if TEXT is empty) a named segment in
-- the status line. Generic: the editor knows nothing about what fills it --
-- an external list tool drives "[3/57] search", git a branch, etc. -- the
-- same relationship :hl has with the highlight overlay. Segments render in
-- name order (see render.lua).
def("status", function(ed, c)
  local name, text = c.args:match("^(%S+)%s*(.-)%s*$")
  if not name then return "usage: status NAME [TEXT]", "err" end
  ed.status[name] = (text ~= "") and text or nil
  return "", "ok"
end)

def("echo", function(ed, c) return c.args, "ok" end)

-- :msg / :msge TEXT -- write this view's one-line message (status line, left).
-- Distinct from :echo, which RETURNS text to the caller (the ':' prompt renders
-- the payload; the socket hands it back in the response frame): :msg targets the
-- human at THIS view even when a socket tool is the caller -- a preview/notice
-- channel for external tools (e.g. lvi-list surfacing the entry you stepped
-- onto). :msge is the error variant, styled by the `Error` group (:hi Error ...);
-- plain if unthemed -- the text is always legible, the theme only adds emphasis.
-- Newlines collapse (the status line is one row); the message clears on the next
-- normal-mode key, like every other message.
def("msg", function(ed, c) ed.message = (c.args:gsub("\n", " ")); ed.message_hl = nil; return "", "ok" end)
def("msge", function(ed, c) ed.message = (c.args:gsub("\n", " ")); ed.message_hl = "Error"; return "", "ok" end)

-- Force a full-screen redraw on the next paint (the driver honors
-- ed.force_clear). Same gesture as Ctrl-L, reachable over the socket so a
-- tool can repair the screen -- e.g. after a resize while the view is idle.
def("redraw", function(ed) ed.force_clear = true; return "", "ok" end)

-- The send-keys escape hatch: feed the argument as normal-mode keystrokes
-- into the interpreter's input funnel. This is what gives the socket (and
-- the ':' prompt) full normal-mode power for the operations ex can't express
-- (cursor-relative edits like 2dw, ci"). The driver drives the coroutine to
-- consume them; from the ':' prompt the running coroutine consumes them next.
def("normal norm", function(ed, c)
  for i = 1, #c.args do ed.inject[#ed.inject + 1] = c.args:byte(i) end
  return "", "ok"
end)

-- :sysex EX-LINE -- hand a line to the system ex VERBATIM, bypassing lvi's
-- command table above. The pin for scripts that need ex's semantics for a
-- name lvi also owns (lvi's :d, :u, ... shadow ex's), and insurance against
-- future lvi commands changing the meaning of a line that today reaches ex
-- through the fallthrough.
def("sysex", function(ed, c)
  if c.args == "" then return "usage: sysex EX-COMMAND", "err" end
  return do_ex(ed, c.args)
end)

function M.dispatch(ed, line)
  local a, b, rest = parse_range(ed, line)
  rest = rest:gsub("^%s+", "")
  local cmdword, bang, args = rest:match("^(%a*)(!?)%s*(.-)%s*$")
  cmdword = cmdword or ""

  if cmdword == "" then
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

  local fn = CMDS[cmdword]
  if fn then
    return fn(ed, { name = cmdword, a = a, b = b, bang = bang == "!",
                    args = args, line = line })
  end

  -- Anything lvi does not handle itself is delegated to the system ex, so vi's
  -- full line-editing vocabulary works without reimplementing it here.
  return do_ex(ed, line)
end

return M
