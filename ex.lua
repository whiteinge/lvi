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
local disp = require("disp")   -- :pos converts a char/display column to a byte
local vpath = require("path")   -- `path` the name is taken by locals below
local sys = require("sys")      -- shq, to quote a prompted :motion argument

local M = {}

-- Events an `:on` hook may bind to. `change` fires (debounced) after a keyboard
-- edit settles; `write` fires right after a successful :w/:wq/:x (any surface);
-- `ready` fires once at startup, after the rc loads and the socket is live (the
-- startup analog of vim's VimEnter -- e.g. an rc hook loads a `-q` list); the
-- buf* events fire on buffer switches (editor.lua/bufs.lua).
local EVENTS = { change = true, write = true, ready = true,
                 bufenter = true, bufleave = true, bufdelete = true,
                 complete = true, scroll = true,
                 markset = true, markjump = true, exit = true }

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

-- Pipe register text to a backend's `write` command (the clipboard seam) when
-- the register NAME is command-backed (:register) and we can shell out (absent
-- headless). No-op otherwise.
local function reg_pipe(ed, name, text)
  local be = ed.reg_backends[name]
  if be and be.write and ed.reg_write then ed.reg_write(be.write, text) end
end

-- Write a register value. A register is { text, linewise }. `name` (nil = the
-- unnamed register only) sets the named register; the unnamed '"' ALWAYS
-- mirrors the last yank/delete. A command-backed register (:register) also
-- pipes its text to `write` -- for the NAMED target, and, because '"' mirrors
-- every yank/delete, for '"' as well (guarded so an explicit '"' target does
-- not double-fire). Backing '"' is thus the single capture point every
-- yank/delete flows through -- the seam a history tool (lvi-yankring) uses --
-- while an un-backed '"' (the default) shells out nowhere. Shared by the ex
-- line commands (:d) and normal.lua's operators so a yank/delete means the same
-- thing on every surface -- normal.lua binds its `set_reg` to this.
function M.set_reg(ed, name, text, linewise)
  -- `_` is the black-hole (vim's "_): the text goes nowhere -- not the named
  -- register, not the unnamed mirror, not a clipboard backend. Handled here so
  -- one check covers every surface: :d _, and normal-mode "_d / "_y / "_c
  -- (the `"` prefix accepts any character).
  if name == "_" then return end
  -- An UPPERCASE buffer name appends to the lowercase register rather than
  -- replacing it (POSIX vi): "Ayy tacks the yank onto whatever "a holds. A
  -- linewise piece keeps the whole run linewise. The unnamed mirror below then
  -- takes the full concatenated value, so `"` reflects the register just used.
  if name and name:match("%u") then
    name = name:lower()
    local prev = ed.regs[name]
    if prev then text, linewise = prev.text .. text, (prev.linewise or linewise) end
  end
  local r = { text = text, linewise = linewise }
  if name then ed.regs[name] = r; reg_pipe(ed, name, text) end
  ed.regs['"'] = r
  if name ~= '"' then reg_pipe(ed, '"', text) end
end

-- Record a DELETE or CHANGE, adding vi's numbered/small-delete bookkeeping on
-- top of set_reg. With no register named:
--   * a LARGE delete (linewise, or charwise spanning a newline) shifts the
--     numbered stack "1.."9 down one and stores the text in "1;
--   * a SMALL delete (charwise, within a single line) goes to the "- register.
-- Naming a register ("add) skips all of that -- only that register and the
-- unnamed '"' move, exactly like vi/Vim. Yanks never reach here (they call
-- set_reg directly); the numbered stack is delete history, not a yank ring.
function M.set_del_reg(ed, name, text, linewise)
  M.set_reg(ed, name, text, linewise)
  if name then return end
  if linewise or text:find("\n", 1, true) then          -- large -> shift into "1
    for i = 9, 2, -1 do ed.regs[tostring(i)] = ed.regs[tostring(i - 1)] end
    ed.regs["1"] = { text = text, linewise = linewise }
  else                                                   -- small -> "-
    ed.regs["-"] = { text = text, linewise = linewise }
  end
end

-- Parse an optional leading address or a two-address range, returning a, b, rest
-- (a and b nil when no address is present). An address is a base atom with any
-- number of +/- line offsets folded in:
--   base:    N | . (current) | $ (last) | 'x (mark x)
--   offset:  +N | -N   (a bare +/- is +/-1; they chain: .+3-1)
-- '%' stays the 1,$ shorthand; a leading offset with no base counts from the
-- current line (:+d is the next line). Two atoms join with ',' or ';'; ';' moves
-- the current line to the first address before the second is read (POSIX -- it
-- matters once /re/ addresses land). Anything we cannot resolve here -- an unset
-- mark, a /re/ search address -- yields nil so dispatch hands the whole line to
-- the system ex, which owns the full address grammar. Lines come back UNCLAMPED;
-- line_range still clamps and orders them.
local function parse_range(ed, s)
  s = s:gsub("^%s+", "")
  if s:sub(1, 1) == "%" then return 1, ed.buf:nlines(), s:sub(2) end

  local function atom(str, cur)
    str = str:gsub("^%s+", "")
    local base, r
    local n = str:match("^%d+")
    if n then base, r = tonumber(n), str:sub(#n + 1)
    elseif str:sub(1, 1) == "." then base, r = cur, str:sub(2)
    elseif str:sub(1, 1) == "$" then base, r = ed.buf:nlines(), str:sub(2)
    elseif str:sub(1, 1) == "'" then                        -- 'x -- a mark
      local pos = ed.marks[str:sub(2, 2)]
      if not pos then return nil, str end                   -- unset/unknown -> defer to ex
      base, r = pos[1], str:sub(3)
    elseif str:sub(1, 1) == "+" or str:sub(1, 1) == "-" then
      base, r = cur, str                                    -- leading offset -> from cur
    else
      return nil, str
    end
    while true do                                           -- fold +N / -N (bare = +/-1)
      local sign, digits, rest = r:match("^%s*([+-])(%d*)(.*)$")
      if not sign then break end
      base = base + (sign == "+" and 1 or -1) * (digits == "" and 1 or tonumber(digits))
      r = rest
    end
    return base, r
  end

  local a, r = atom(s, ed.cy)
  if not a then return nil, nil, s end
  local sep = r:sub(1, 1)
  if sep == "," or sep == ";" then
    local b, r2 = atom(r:sub(2), sep == ";" and a or ed.cy)
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

-- :set -- minimal option handling. Booleans: `wrap` / `nowrap` / `wrap?`
-- (also `linebreak`/`lbr`: wrap only at whitespace, never mid-word).
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
  -- A string option takes the REST of the line verbatim: its value bears spaces
  -- (`fmtprg=fmt -w 72`) and so can't live in the %S+-tokenized list below --
  -- give it its own :set line. (rc comments are stripped upstream in config.lua,
  -- so a trailing `" note` never reaches here.)
  local sname, sval = args:match("^(%a+)=(.*)$")
  if sname == "fmtprg" or sname == "fp" then ed.opts.fmtprg = sval; return nil, "ok" end
  -- operatorfunc: the shell command g@{motion} spawns over the motion's span (see
  -- normal.lua). A string value bearing spaces, so it needs its own :set line like
  -- fmtprg. Empty (`:set opfunc=`) disarms g@ back to a no-op.
  if sname == "operatorfunc" or sname == "opfunc" then ed.opts.operatorfunc = sval; return nil, "ok" end
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
      elseif n == "linebreak" or n == "lbr" then out[#out + 1] = ed.opts.linebreak and "linebreak" or "nolinebreak"
      elseif n == "foldenable" or n == "fen" then out[#out + 1] = ed.opts.foldenable and "foldenable" or "nofoldenable"
      elseif n == "tabstop" or n == "ts" then out[#out + 1] = "tabstop=" .. ed.opts.tabstop
      elseif n == "shiftwidth" or n == "sw" then out[#out + 1] = "shiftwidth=" .. ed.opts.shiftwidth
      elseif n == "fmtprg" or n == "fp" then out[#out + 1] = "fmtprg=" .. ed.opts.fmtprg
      elseif n == "operatorfunc" or n == "opfunc" then out[#out + 1] = "operatorfunc=" .. ed.opts.operatorfunc
      elseif n == "expandtab" or n == "et" then out[#out + 1] = ed.opts.expandtab and "expandtab" or "noexpandtab"
      elseif n == "autoindent" or n == "ai" then out[#out + 1] = ed.opts.autoindent and "autoindent" or "noautoindent"
      elseif n == "modified" or n == "mod" then out[#out + 1] = ed.buf.modified and "modified" or "nomodified"
      elseif n == "scratch" then out[#out + 1] = ed.buf.scratch and "scratch" or "noscratch"
      elseif n == "readonly" or n == "ro" then out[#out + 1] = ed.buf.readonly and "readonly" or "noreadonly"
      else return "unknown option: " .. n, "err" end
    elseif opt:sub(-1) == "!" then                      -- toggle a boolean (vim `set wrap!`)
      local n = opt:sub(1, -2)
      if n == "wrap" then ed.opts.wrap = not ed.opts.wrap
      elseif n == "linebreak" or n == "lbr" then ed.opts.linebreak = not ed.opts.linebreak
      elseif n == "foldenable" or n == "fen" then ed.opts.foldenable = not ed.opts.foldenable
      elseif n == "expandtab" or n == "et" then ed.opts.expandtab = not ed.opts.expandtab
      elseif n == "autoindent" or n == "ai" then ed.opts.autoindent = not ed.opts.autoindent
      elseif n == "modified" or n == "mod" then
        if ed.buf.modified then ed.buf._undo.saved = ed.buf._undo.now; ed.buf.modified = false
        else ed.buf._undo.saved = -1; ed.buf.modified = true end
      elseif n == "scratch" then
        -- Recompute modified now: flipping scratch changes it, but
        -- update_modified only fires on the next edit otherwise.
        ed.buf.scratch = not ed.buf.scratch
        ed.buf.modified = (not ed.buf.scratch) and (ed.buf._undo.now ~= ed.buf._undo.saved)
      elseif n == "readonly" or n == "ro" then ed.buf.readonly = not ed.buf.readonly
      else return "not a boolean option: " .. n, "err" end
    elseif opt == "wrap" then ed.opts.wrap = true
    elseif opt == "nowrap" then ed.opts.wrap = false
    elseif opt == "linebreak" or opt == "lbr" then ed.opts.linebreak = true
    elseif opt == "nolinebreak" or opt == "nolbr" then ed.opts.linebreak = false
    elseif opt == "foldenable" or opt == "fen" then ed.opts.foldenable = true
    elseif opt == "nofoldenable" or opt == "nofen" then ed.opts.foldenable = false
    elseif opt == "expandtab" or opt == "et" then ed.opts.expandtab = true
    elseif opt == "noexpandtab" or opt == "noet" then ed.opts.expandtab = false
    elseif opt == "autoindent" or opt == "ai" then ed.opts.autoindent = true
    elseif opt == "noautoindent" or opt == "noai" then ed.opts.autoindent = false
    elseif opt == "modified" or opt == "mod" then ed.buf._undo.saved = -1; ed.buf.modified = true
    elseif opt == "nomodified" or opt == "nomod" then ed.buf._undo.saved = ed.buf._undo.now; ed.buf.modified = false
    elseif opt == "scratch" then ed.buf.scratch = true; ed.buf.modified = false
    elseif opt == "noscratch" then
      ed.buf.scratch = false; ed.buf.modified = ed.buf._undo.now ~= ed.buf._undo.saved
    elseif opt == "readonly" or opt == "ro" then ed.buf.readonly = true
    elseif opt == "noreadonly" or opt == "noro" then ed.buf.readonly = false
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
  -- `-- NAME` takes the rest of the argument literally, no expansion -- the
  -- spelling for a script splicing an arbitrary picked/stored name into a file
  -- command, which otherwise must backslash-escape every metacharacter (and
  -- keep its escape class in lockstep with the pattern below).
  local lit = s:match("^%-%- (.*)$")
  if lit then return lit ~= "" and lit or nil end
  if not s:find("[~{%[%*%?%$\"'`\\]") then return s end
  local out, code, err = run_capture(ed, "printf '%s\\n' " .. s)
  if code ~= 0 then return nil, "expansion failed: " .. fail_reason(err, code) end
  out = out:gsub("\n$", "")
  if out == "" then return nil, "expansion gave no file name: " .. s end
  if out:find("\n", 1, true) then return nil, "ambiguous file name (expands to several lines): " .. s end
  return out
end

-- expand_file's sibling for the one command that takes SEVERAL names (:next).
-- Same expansion contract, with the one difference that several output lines are
-- the point rather than an ambiguity error -- so `:n *.c` opens every match, as
-- a vi user expects. With no metacharacter to hand the shell we split on blanks
-- ourselves, mirroring expand_file's verbatim path; a name containing a blank is
-- quoted, and the quote puts it back on the shell path where it belongs.
-- Returns a list (empty for no argument), or nil + an error message.
local function expand_files(ed, s)
  if s == "" then return {} end
  local lit = s:match("^%-%- (.*)$")
  if lit then return lit ~= "" and { lit } or {} end
  local files = {}
  if not s:find("[~{%[%*%?%$\"'`\\]") then
    for w in s:gmatch("%S+") do files[#files + 1] = w end
    return files
  end
  local out, code, err = run_capture(ed, "printf '%s\\n' " .. s)
  if code ~= 0 then return nil, "expansion failed: " .. fail_reason(err, code) end
  for line in out:gmatch("[^\n]+") do files[#files + 1] = line end
  if #files == 0 then return nil, "expansion gave no file name: " .. s end
  return files
end

-- Write bytes to a path, replacing or appending. The plain-bytes counterpart
-- to Buffer:write, for the writes that are NOT the buffer saving itself: a
-- partial range, an append, the :wbuf snapshot. Returns true, or nil + a
-- message.
--
-- `backup` runs Buffer:write's dance -- the whole new text into PATH.lvi~
-- first, the target rewritten in place after, the copy removed on success --
-- and every :w that REPLACES a file asks for it. What that protects is not the
-- buffer's identity but the bytes already in the file: replacing them destroys
-- them, and a write cut short leaves neither the old nor the new, whoever's
-- file it is. (`:1,2w` with no name replaces the buffer's OWN file, which was
-- the case that made the identity reading wrong.) An append only adds, so it
-- has nothing to lose; :wbuf's snapshot is regenerated on demand.
local function write_text(path, body, append, backup)
  local bak = path .. ".lvi~"
  local bf = backup and not append and io.open(bak, "wb")
  if bf then bf:write(body); bf:close() end
  local f, oerr = io.open(path, append and "ab" or "wb")
  if not f then
    if bf then os.remove(bak) end               -- target untouched; copy not needed
    return nil, ("cannot open %s: %s"):format(path, tostring(oerr))
  end
  local ok, werr = f:write(body)
  f:close()
  if not ok then
    return nil, ("short write to %s: %s%s"):format(path, tostring(werr),
      bf and (" (new text preserved in " .. bak .. ")") or "")
  end
  if bf then os.remove(bak) end
  return true
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

-- :[range]w !cmd -- the range's text on a command's stdin (POSIX's write-to-a-
-- command form). do_filter's sibling minus the splice: here the buffer is the
-- INPUT and nothing comes back into it. Same temp-file hand-off for the same
-- reason (a bidirectional pipe would deadlock), and the same tty rules as :! --
-- on a terminal the command owns the screen, so `w !sudo tee -- "$LVI_FILE"`
-- can prompt for a password; over the socket its stdout is the reply. The
-- redirect wraps cmd in a subshell so the input reaches the whole pipeline,
-- not just the last stage of a `cmd1 && cmd2`.
local function do_write_cmd(ed, from, to, cmd)
  if cmd == "" then return "no command", "err" end
  local tmp = vpath.tmp()                       -- carries buffer text: keep it private
  local ok, werr = write_text(tmp, ed.buf:text(from, to))
  if not ok then os.remove(tmp); return "write failed: " .. werr, "err" end
  local payload, status = do_shell(ed, ("(%s) < %s"):format(cmd, tmp))
  os.remove(tmp)
  return payload, status
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

-- Custom text objects (`:textobj KEY CMD`). The normal-mode dispatch calls this
-- when an operator meets `i`/`a` + a KEY that has no builtin object: we shell out
-- SYNCHRONOUSLY -- the same discipline as do_ex, and the same latency profile as
-- a `:s` typed at the prompt -- so the operator (including `c`, which must enter
-- insert mode) applies through the ordinary coroutine path, exactly like a
-- builtin object. No socket callback, no async: the tool is a pure filter.
--
-- Contract. Invoked as:  CMD <tmpfile> <i|a> <line> <col>
--   tmpfile   the current buffer's text (unsaved edits included), private temp
--   i|a       inner vs "a"/around
--   line col  the cursor, 1-based (line) and 1-based byte column
-- It prints ONE line to stdout, then exits:
--   char L1 C1 L2 C2   a charwise range, 1-based, byte columns, inclusive of both ends
--   line L1 L2         a linewise range (whole lines L1..L2)
--   (nothing)          no such object at the cursor -- a clean no-op
-- Anything malformed is treated as "no object". Returns sl,sc,tl,tc,kind or nil.
function M.textobj_range(ed, cmd, around, key)
  local tmp = vpath.tmp()
  local wf = io.open(tmp, "wb"); if not wf then return nil end
  wf:write(ed.buf:text()); wf:close()
  -- All args are shell-safe (a path in the private dir, a literal i/a, digits).
  -- stderr to /dev/null for the same reason motion_target does it: the editor
  -- holds the terminal in raw mode on the alternate screen, so a filter's
  -- diagnostics would land in the middle of the text.
  local full = ("%s '%s' %s %d %d 2>/dev/null"):format(cmd, tmp, around and "a" or "i", ed.cy, ed.cx)
  local p = io.popen(full, "r")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  os.remove(tmp)
  local kind, rest = out:match("^%s*(%a+)%s+(.-)%s*$")
  if kind == "char" then
    local l1, c1, l2, c2 = rest:match("^(%d+)%s+(%d+)%s+(%d+)%s+(%d+)$")
    if l1 then return tonumber(l1), tonumber(c1), tonumber(l2), tonumber(c2), "char" end
  elseif kind == "line" then
    local l1, l2 = rest:match("^(%d+)%s+(%d+)$")
    if l1 then return tonumber(l1), 1, tonumber(l2), 1, "line" end
  end
  return nil                                          -- no object / malformed output
end

-- External motions (`:motion KEY CMD`). Same discipline as textobj_range above
-- and for the same reasons: a SYNCHRONOUS filter, so an external motion composes
-- with operators through the ordinary coroutine path -- `d/foo` deletes, `c/foo`
-- can still enter insert mode -- instead of arriving over the socket after the
-- command that wanted it has finished.
--
-- Contract. Invoked as:  CMD <tmpfile> <count> <line> <col> <arg>
--   tmpfile   the current buffer's text (unsaved edits included), private temp
--   count     the count typed before the key, or 1
--   line col  the cursor, 1-based (line) and 1-based byte column
--   arg       the prompted argument (a search pattern), "" for a key that does
--             not prompt. $LVI_SOCK and $LVI_WID are in the environment (static
--             per view) if the tool wants to keep state or call back; the rest of
--             the $LVI_* set is refreshed only for spawned hooks, so position
--             comes from argv, not the environment.
-- It prints ONE line to stdout, then exits:
--   char L C [incl]   a charwise target, 1-based, byte column. Exclusive like
--                     vi's search unless `incl` follows, so `d/foo` stops before
--                     the match and a tool that means "through it" says so.
--   line L            a linewise target (whole lines, cursor to L)
--   err TEXT          no target, and TEXT to say why (vi's "Pattern not found")
--   (nothing)         no target and nothing to say -- a silent no-op
-- Anything malformed is "no target". Returns tl,tc,kind,inclusive -- or nil plus
-- a message.
--
-- stderr goes to /dev/null: the editor holds the terminal in raw mode on the
-- alternate screen, so a filter's diagnostics would land in the middle of the
-- text. `err` is the channel that reaches the user.
function M.motion_target(ed, cmd, count, arg)
  local tmp = vpath.tmp()
  local wf = io.open(tmp, "wb"); if not wf then return nil end
  wf:write(ed.buf:text()); wf:close()
  local full = ("%s %s %d %d %d %s 2>/dev/null"):format(
                 cmd, sys.shq(tmp), count or 1, ed.cy, ed.cx, sys.shq(arg or ""))
  local p = io.popen(full, "r")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  os.remove(tmp)
  local kind, rest = out:match("^%s*(%a+)%s+(.-)%s*$")
  if kind == "char" then
    local l, c, flag = rest:match("^(%d+)%s+(%d+)%s*(%a*)$")
    if l then return tonumber(l), tonumber(c), "char", flag == "incl" end
  elseif kind == "line" then
    local l = rest:match("^(%d+)$")
    if l then return tonumber(l), 1, "line", false end
  elseif kind == "err" and rest ~= "" then
    return nil, rest
  end
  return nil
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

-- The inverse of parse_keys: render raw key bytes back into the notation :map
-- accepts, so a listed row pastes straight back into an rc. Only what MUST be
-- escaped is: the control bytes (by name where they have one, else <C-x>) and
-- '<' itself, which would otherwise re-parse as the start of a name. '|' and
-- '\' stay literal -- they have names (<Bar>/<Bslash>) but round-trip as
-- themselves, and '\' is the leader in every shipped binding, unreadable
-- spelled out.
--
-- SPACE is the one context-dependent case, hence `lhs`: :map splits its two
-- arguments on whitespace, so a space in the LHS must come back as <Space> to
-- re-parse, while a space in the RHS is ordinary text (`:bg lvi-list next`)
-- that spelling out would make every row unreadable.
local SHOWKEY = { [13] = "CR", [10] = "NL", [27] = "Esc", [9] = "Tab", [60] = "lt" }
local function show_keys(s, lhs)
  return (s:gsub(".", function(ch)
    local b = ch:byte()
    if SHOWKEY[b] then return "<" .. SHOWKEY[b] .. ">" end
    if b == 32 then return lhs and "<Space>" or ch end
    if b < 32 then return "<C-" .. string.char(b + 96) .. ">" end
    return ch
  end))
end

-- The map table as `lhs<TAB>rhs` rows, sorted by the RAW lhs so a leader's
-- bindings group together. `only` restricts it to one lhs (the :map LHS query).
-- Shared with editor.lua, which stamps the same rows into $LVI_MAPS for
-- children (contrib/lvi-cmd): one rendering, one format, both surfaces.
function M.maplist(ed, only)
  local keys = {}
  for lhs in pairs(ed.maps) do
    if not only or lhs == only then keys[#keys + 1] = lhs end
  end
  table.sort(keys)
  local rows = {}
  for _, lhs in ipairs(keys) do
    rows[#rows + 1] = show_keys(lhs, true) .. "\t" .. show_keys(ed.maps[lhs])
  end
  return table.concat(rows, "\n")
end

-- True when writing buf to `p` risks clobbering another writer: p is the
-- buffer's own file and its mtime moved since our last read/write of it (the
-- stamp machinery wired in editor.lua; absent headless, where the check is
-- skipped). A save-as to a different path is not a conflict -- the user is
-- explicitly aiming elsewhere.
local function write_conflict(ed, buf, p)
  return p == buf.path and ed.file_changed ~= nil and ed.file_changed(buf)
end

-- A repoint -- lvi's `:w NAME` save-as, or POSIX's `:f NAME` -- changes what
-- file this buffer IS, and everything keyed to the path is now stale: the
-- socket's .file sidecar `lvi -l` lists, and any `on bufenter` hook that
-- derives policy from the name (contrib/lvi-ftype picks settings off the
-- extension). bufenter is exactly that seam -- "recompute what depends on which
-- buffer this is" -- and its consumers are total projections, so re-firing it
-- is idempotent by their own contract. Fired only when the path actually moved.
local function note_repoint(ed, was)
  if ed.buf.path ~= was and ed.fire_event then ed.fire_event("bufenter") end
end

-- POSIX `readonly`: a write to the buffer's OWN file fails unless forced (`w!`),
-- guarding an accidental overwrite. Writing elsewhere (`:w other`) is allowed,
-- matching vi/vim; `!` overrides, as does `:set noreadonly`.
local function readonly_block(buf, p, force)
  return buf.readonly and not force and p == buf.path
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
      if readonly_block(buf, buf.path, force) then
        return nil, ("'readonly' option is set: %s (add ! to override)"):format(buf.path)
      end
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

-- POSIX write, all three forms; the range defaults to the whole buffer:
--
--   :[range]w [file]     write, replacing file
--   :[range]w >>[file]   append to file instead of replacing it
--   :[range]w !cmd       pipe the lines to a command's standard input
--
-- Only the first form writing the WHOLE buffer is the buffer saving ITSELF, and
-- only it carries the buffer's identity: it goes through Buffer:write, so it
-- gets the .lvi~ safety copy, repoints buf.path (lvi's save-as deviation) and
-- clears `modified`. The other three cases -- a partial range, an append, a
-- pipe -- write FROM the buffer to somewhere else, so they leave its name and
-- dirty state alone. POSIX says the same thing from the other side: only a
-- complete write clears the modification flag.
--
-- `w !cmd` vs `w!file` turns on the blank, and the dispatcher's parse already
-- makes that split for us -- `w!` becomes the bang, a blank before the `!`
-- leaves it at the head of args -- which is exactly POSIX's rule.
--
-- The `write` hook fires for every form that names a file, including a save-as
-- elsewhere (as it always has). It does NOT fire for `w !cmd`: the command is
-- opaque, so lvi cannot say whether a file was written or which one.
-- The addressed range, defaulting to the whole buffer; `whole` is the flag the
-- write forms turn on, so both :w and :wq/:x read it the same way.
local function write_range(ed, c)
  local nlines = ed.buf:nlines()
  if not c.a then return 1, nlines, true end
  local from, to = line_range(ed, c.a, c.b)
  return from, to, (from == 1 and to == nlines)
end

-- The file-writing core, shared by :w and :wq/:x so the two cannot drift (they
-- had: :w grew POSIX's forms and the range while :wq kept filing `>>log` as a
-- literal name and ignoring its address). Returns payload, status.
local function do_write_file(ed, c, from, to, whole, target, append)
  local p, xerr = expand_file(ed, target)
  if xerr then return xerr, "err" end
  p = p or ed.buf.path
  if not p then return "No file name", "err" end
  if readonly_block(ed.buf, p, c.bang) then
    return "'readonly' option is set (add ! to override)", "err"
  end
  if not c.bang and write_conflict(ed, ed.buf, p) then
    return "File changed since last read (add ! to override)", "err"
  end

  local n
  local was = ed.buf.path
  if whole and not append then
    local ok, err = pcall(ed.buf.write, ed.buf, p)
    if not ok then return "write failed: " .. tostring(err), "err" end
    n = err
  else
    local body = ed.buf:text(from, to)
    local ok, werr = write_text(p, body, append, true)
    if not ok then return "write failed: " .. werr, "err" end
    n = #body
  end
  -- Re-stamp only when we moved the mtime of the file this buffer claims;
  -- writing elsewhere tells us nothing new about our own.
  if ed.stamp and p == ed.buf.path then ed.stamp(ed.buf) end
  note_repoint(ed, was)                      -- identity settles before the hooks
  if ed.fire_event then ed.fire_event("write") end
  return ('"%s" %dL, %dB %s'):format(p, to - from + 1, n,
                                     append and "appended" or "written"), "ok"
end

def("w write", function(ed, c)
  -- In the command window, bare :w runs the current line instead of writing.
  -- :w <file> still saves normally -- a handy "dump my recent commands to disk".
  if ed.buf.cmdwin_origin and c.args == "" then return cmdwin_exec(ed) end
  local from, to, whole = write_range(ed, c)

  if c.args:sub(1, 1) == "!" then
    return do_write_cmd(ed, from, to, c.args:sub(2))
  end

  local target, append = c.args, false
  local tail = c.args:match("^>>%s*(.*)$")
  if tail then target, append = tail, true end       -- bare `>>` appends to our own file
  return do_write_file(ed, c, from, to, whole, target, append)
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
  local ok, err = write_text(p, ed.buf:text())
  if not ok then return "wbuf failed: " .. err, "err" end
  return "", "ok"
end)

-- :x writes only when the buffer is modified, then quits -- so on a clean
-- buffer it leaves the file's mtime untouched (its whole reason to exist
-- over :wq, which always writes). An explicit target (:x file) is a save-as,
-- so it still writes. ZZ routes here, inheriting the skip.
--
-- Neither takes :w's `>>` or `!cmd`: an append leaves the buffer modified, so
-- `wq >>` would quit discarding the changes it just appended, and a pipe never
-- says whether -- or where -- anything was written. They have to be REFUSED
-- rather than left to fall through, because neither `>` nor `!` is a
-- metacharacter expand_file expands: `:wq !cat` took the whole thing as a file
-- name, created `!cat`, repointed the buffer at it and quit.
def("wq x", function(ed, c)
  local from, to, whole = write_range(ed, c)
  if c.name == "x" and c.args == "" and whole and not ed.buf.modified then
    ed.running = false
    return "", "ok"
  end
  if c.args:sub(1, 1) == "!" or c.args:sub(1, 2) == ">>" then
    return (":%s takes a file name only -- write with :w, then :q"):format(c.name), "err"
  end
  if not whole and not c.bang then
    return "Use ! to write partial buffer", "err"
  end
  local payload, status = do_write_file(ed, c, from, to, whole, c.args, false)
  if status ~= "ok" then return payload, status end
  ed.running = false
  return "", "ok"                                    -- quitting: nothing to print
end)

-- :[range]d[elete] [buffer] -- delete the lines, saving them to a register just
-- like the normal-mode `d` operator: always the unnamed '"' (and the numbered
-- stack "1, since a line delete is "large"), plus a named register when a
-- single-letter buffer is given (POSIX ex's optional buffer arg). The text is
-- linewise (trailing '\n'), matching a linewise yank/dd, so a following :put / p
-- pastes whole lines. `_` is the black-hole buffer (vim's "_): the delete
-- touches no register at all -- for socket tools (lvi-diff, lvi-mirror) whose
-- pushed deletes must not rotate the user's delete history or feed a
-- command-backed clipboard. (Mark/search addresses like :'a,'bd still fall
-- through to the system ex, whose registers lvi can't see -- see the addressing
-- note at the top of this file.)
def("d delete", function(ed, c)
  local from, to = line_range(ed, c.a, c.b)
  local reg = c.args:match("^([%a_])%s*$")        -- optional single-letter buffer
  M.set_del_reg(ed, reg, table.concat(ed.buf:get(from, to), "\n") .. "\n", true)
  ed.buf:delete(from, to)
  ed.cy = clampline(ed, from)
  ed.cx = 1
  return "", "ok"
end)

def("p print", function(ed, c)
  local from, to = line_range(ed, c.a, c.b)
  return table.concat(ed.buf:get(from, to), "\n"), "ok"
end)

-- POSIX `file [file]`: with an argument, set the buffer's pathname; either way,
-- report it. The argument form is the repoint-WITHOUT-writing primitive. `:w
-- NAME` also repoints (lvi's save-as), but only by writing, which is the wrong
-- move when the file has already moved under you -- an external `mv`, a shell
-- rename from :sh -- and your edits are not ready to save. Without it the
-- buffer keeps pointing at a path that no longer exists, and the next bare `:w`
-- silently recreates the file at the OLD name.
--
-- Renaming does not mark the buffer modified (POSIX is explicit), and it
-- re-stamps: the buffer now claims a different file, so what we knew about the
-- mtime of the old one says nothing about this one. As with `:w NAME`, aiming
-- at a file that already exists is taken as deliberate, not a conflict.
--
-- One documented shortfall: POSIX also parks the old name in the ALTERNATE
-- pathname. lvi has no such slot -- `#` here names the alternate BUFFER, an
-- index into the one buffer list -- so the old name is simply dropped.
def("f file", function(ed, c)
  if c.args ~= "" then
    local p, xerr = expand_file(ed, c.args)
    if xerr then return xerr, "err" end
    if p then
      local was = ed.buf.path
      ed.buf.path = p
      if ed.stamp then ed.stamp(ed.buf) end
      note_repoint(ed, was)
    end
  end
  -- Match the status line (render): a pathless buffer reports its display name
  -- ([stdin], [Command Line], ...) if it has one, else the generic label.
  return ('"%s" %d lines'):format(ed.buf.path or ed.buf.name or "[No File]", ed.buf:nlines()), "ok"
end)

-- :path -- the buffer's file path, machine-readable: exactly the path (as
-- opened; the same value hooks see in $LVI_FILE), empty for a pathless buffer
-- ([stdin], scratch, ...). The script-side :f -- tools were parsing :f's human
-- format with sed, which breaks silently if that wording ever shifts.
def("path", function(ed)
  return ed.buf.path or "", "ok"
end)

-- :undojoin -- join the NEXT change with the last undo group (vim's :undojoin).
-- The seam a socket tool interleaves between its commands so a multi-command
-- edit (lvi-diff's delete+read hunk move, lvi-mirror's hunk stream) reverts
-- with ONE `u` instead of one per command.
def("undojoin", function(ed)
  ed.buf:undojoin()
  return "", "ok"
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

-- The POSIX ex file-walk commands, which in lvi are the buffer walk. lvi has ONE
-- list where vim has two: the files named on the command line ARE the buffer
-- list, in order (editor.run), and :e appends to it, so ex's argument list and
-- vim's buffer list are the same object here -- :n IS :bn, and there is no
-- second list for :args to show that :ls does not already show. Vim needs the
-- split because its buffer list fills up with views you never asked for; lvi has
-- the walk skip scratch buffers instead (see bufs.step). Two deviations from
-- POSIX, both documented in the manpage: the walk is cyclic (ex stops with an
-- error at the end of the list), and it skips those scratch views.
--
-- :n FILE... opens the named files as buffers and goes to the first, which is
-- ex's "replace the argument list, edit the first file" minus the discard: with
-- no separate list to replace, emulating the discard would mean closing resident
-- buffers and throwing away modified text.
def("n next", function(ed, c)
  if c.args == "" then bufs.next(ed); return "", "ok" end
  local files, xerr = expand_files(ed, c.args)
  if xerr then return xerr, "err" end
  -- Open in order (each switches), then come back to the first one named. We
  -- track it as a buffer OBJECT, not an index, since opening the rest may find
  -- them already resident and leave the list in any order.
  local first
  for _, f in ipairs(files) do
    bufs.open(ed, f)
    first = first or ed.buf
  end
  local i = first and bufs.index_of(ed, first)
  if i then bufs.switch(ed, i) end
  return "", "ok"
end)

def("N prev previous", function(ed) bufs.prev(ed); return "", "ok" end)
def("rew rewind first", function(ed) bufs.first(ed); return "", "ok" end)
def("last", function(ed) bufs.last(ed); return "", "ok" end)

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

-- :map LHS RHS binds; :map alone LISTS what is bound, and :map LHS shows the
-- one row (vim's reading, and unambiguous here -- a binding always has an RHS,
-- so an argument count says which is meant). The listing is the :hooks/:marks
-- mold: `lhs<TAB>rhs` rows, in the notation :map parses, so a row pastes back.
--
-- It exists because a map is the ONE registration seam with no way to read it
-- back from inside the editor -- :hooks, :marks, :registers, :ls, :jumps all
-- list, and a keymap you have to grep your rc for is the least memorable thing
-- in the editor. That is also why it is the substrate under contrib/lvi-cmd:
-- fuzzy recall of a fading binding beats naming it, and neither needs a new
-- alias namespace to squat on names lvi may later own.
def("map", function(ed, c)
  local lhs, rhs = c.args:match("^(%S+)%s+(.+)$")
  if not rhs then
    local only = (c.args ~= "") and parse_keys(c.args) or nil
    local rows = M.maplist(ed, only)
    if rows == "" then return only and "no mapping for " .. c.args or "no mappings", "ok" end
    return rows, "ok"
  end
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

-- :[range]bg CMD -- run a shell command detached, output discarded, WITHOUT
-- handing over the terminal (unlike :!/:silent !, which drop out of and back
-- into the alt screen -- a full-screen flash that is jarring when a map fires it
-- repeatedly, e.g. n/N stepping a list). Same mechanism as :on hooks; the
-- poll loop stays live, so the command's socket callbacks are serviced at
-- once. For non-interactive tools only -- a command that needs the tty (a
-- prompt, a pager) must use :! / :silent !. A leading address range is resolved
-- (like `:!`'s) and exported as $LVI_LINE1/$LVI_LINE2, so a tool can act on a
-- user-typed line span -- the non-mutating sibling of the `:[range]!` filter.
def("bg", function(ed, c)
  if c.args == "" then return "no command", "err" end
  if ed.spawn_bg then
    if c.a then local from, to = line_range(ed, c.a, c.b); ed.spawn_bg(c.args, nil, from, to)
    else ed.spawn_bg(c.args) end
  end
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

-- `args`/`ar` are POSIX ex's "write the argument list, current entry marked".
-- With one list that is exactly this listing, current entry marked `%`, so they
-- are spellings of :ls rather than a second command showing a second list.
-- Unlike the file walk this shows scratch buffers too: they are resident, and
-- the walk skipping them is no reason to hide them from the one command that
-- says what is open.
def("ls buffers files args ar", function(ed) return bufs.list(ed), "ok" end)

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
-- wqa are aliases here. A `readonly` buffer stops the run unless forced (the !
-- write_all threads through), matching :w's guard.
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
-- :foldclear removes them all; :foldset replaces the whole set, preserving the
-- open state of ranges that survive.
-- Feed every L1,L2 spec of a fold-family command -- the address range, then the
-- space-separated arg pairs -- to `add`, normalized to s < e. One grammar for
-- both verbs (:fold appends, :foldset replaces), so a producer can switch verbs
-- without touching its emitter.
local function fold_specs(c, add)
  if c.a then add(math.min(c.a, c.b), math.max(c.a, c.b)) end
  for s1, s2 in c.args:gmatch("(%d+)%s*[,:%s]%s*(%d+)") do
    local a, b = tonumber(s1), tonumber(s2)
    add(math.min(a, b), math.max(a, b))
  end
end

def("fold", function(ed, c)
  ed.folds = ed.folds or {}
  fold_specs(c, function(a, b)
    if b > a then ed.folds[#ed.folds + 1] = { s = a, e = b, open = false } end
  end)
  return "", "ok"
end)
def("foldclear", function(ed) ed.folds = {}; return "", "ok" end)
def("foldopen",  function(ed) for _, f in ipairs(ed.folds or {}) do f.open = true  end; return "", "ok" end)
def("foldclose", function(ed) for _, f in ipairs(ed.folds or {}) do f.open = false end; return "", "ok" end)

-- :foldset [L1,L2 ...] -- replace the fold set wholesale (no specs = no folds).
-- A range that survives the replacement (same endpoints) keeps its open/closed
-- state; new ranges arrive closed. This is the re-push spelling for a fold tool
-- that recomputes policy on every run (contrib/lvi-fold on an `on bufenter`
-- hook): :foldclear + :fold would re-close everything the user opened -- and
-- flash the buffer unfolded between the two commands -- one atomic replace does
-- neither. Endpoint matching is enough because splice hooks shift resident
-- folds across edits by the same delta the recomputing tool sees in the buffer.
def("foldset", function(ed, c)
  local old, new = ed.folds or {}, {}
  fold_specs(c, function(a, b)
    if b <= a then return end
    local f = { s = a, e = b, open = false }
    for _, g in ipairs(old) do
      if g.s == a and g.e == b then f.open = g.open; break end
    end
    new[#new + 1] = f
  end)
  ed.folds = new
  return "", "ok"
end)

-- :on EVENT [command] -- run a shell command when EVENT fires (autocmd-ish,
-- but pointed at external tools). EVENT is change|bufenter|bufleave|bufdelete.
-- Multiple hooks per event compose; `:on EVENT` with no command clears them,
-- and `:on! EVENT command` retracts just that one (see below).
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
--
-- `:on! EVENT command` removes the hook whose command is exactly `command`,
-- leaving every other hook on that event in place. Adding composes, so removing
-- has to be per-item too: without it the only retraction is `:on EVENT`, which
-- takes down the other tools' hooks along with yours -- so a tool that arms a
-- hook temporarily (contrib/lvi-send's on-write runner) could never disarm.
-- Matching on the exact string keeps this off the state-reading path the hooks
-- are otherwise held to: a tool retracts the string it registered, so it needs
-- no :hooks read (whose read-to-write gap would race the user) to disarm. It is
-- the mirror of the dedupe below -- same comparison, opposite verb -- so a
-- command that :on would refuse to add twice is one :on! can remove. Removing a
-- hook that was never registered is a silent no-op for that symmetry. The bang
-- REQUIRES a command: bare `:on! EVENT` is an error rather than a synonym for
-- the clear-all, since a script whose command variable came out empty would
-- otherwise nuke every hook on the event -- the exact accident this exists to
-- prevent.
def("on", function(ed, c)
  local event, rest = c.args:match("^(%S+)%s*(.-)%s*$")
  if not event or event == "" then return "usage: on EVENT [command]", "err" end
  if not EVENTS[event] then return "unknown event: " .. event, "err" end
  if c.bang then
    if rest == "" then return "usage: on! EVENT command", "err" end
    local hooks = ed.hooks[event]
    if not hooks then return "", "ok" end
    for i, h in ipairs(hooks) do
      if h == rest then
        table.remove(hooks, i)
        -- Drop the empty list rather than leave one behind: :hooks and the
        -- fire path both read "no hooks" as absent, not as a zero-length table.
        if #hooks == 0 then ed.hooks[event] = nil end
        return "", "ok"
      end
    end
    return "", "ok"
  end
  if rest == "" then ed.hooks[event] = nil; return "", "ok" end
  -- `complete` names a single completer (you can't merge two pickers), so it
  -- REPLACES; the fire-and-forget events compose (append).
  if event == "complete" then ed.hooks.complete = { rest }; return "", "ok" end
  ed.hooks[event] = ed.hooks[event] or {}
  -- Re-registering an identical command is a no-op, so a wiring script re-run
  -- on the same view (lvi-diff, lvi-stagediff --attach) never stacks duplicates.
  for _, h in ipairs(ed.hooks[event]) do
    if h == rest then return "", "ok" end
  end
  table.insert(ed.hooks[event], rest)
  return "", "ok"
end)

-- :textobj KEY CMD -- register a custom text object on the single character KEY
-- (used after i/a in operator-pending: `di<KEY>`, `ca<KEY>`). CMD is the filter
-- run by ex.textobj_range above. KEY alone unregisters. A builtin object of the
-- same key (w, (, ", ...) always wins -- :textobj only fills unclaimed keys.
def("textobj", function(ed, c)
  local key, cmd = c.args:match("^(%S+)%s*(.-)%s*$")
  if not key or key == "" then return "usage: textobj KEY [command]", "err" end
  if #key ~= 1 then return "textobj: KEY must be a single character", "err" end
  if cmd == "" then ed.textobj_cmds[key:byte(1)] = nil; return "", "ok" end
  ed.textobj_cmds[key:byte(1)] = cmd
  return "", "ok"
end)

-- :motion KEY [prompt] CMD -- register an external motion on the single
-- character KEY, run by ex.motion_target above. It behaves like any other
-- motion: bare it moves (jump-class, so Ctrl-O and `` come back), after an
-- operator it supplies the range, so `d/foo` and `y*` compose for free.
--
-- `prompt` (the literal word, before CMD) makes the key read a line first, under
-- KEY as the prompt character -- which is what makes `/` feel like `/`. The
-- editor does the prompting, not the tool: the tool is a popen child of an editor
-- holding the terminal in raw mode, so a `read` of its own would take raw
-- keystrokes with no echo. A key without `prompt` works from the cursor (`*` on
-- the word under it, `]c` on the next hunk) and gets "" as its argument.
--
-- KEY alone unregisters. A builtin motion of the same key always wins -- :motion
-- only fills unclaimed keys, so `/ ? n N *` are available and `w` is not.
-- Single character only, like :textobj: a key is one byte at the funnel, and a
-- two-key sequence would need its own dispatch table.
def("motion", function(ed, c)
  local key, rest = c.args:match("^(%S+)%s*(.-)%s*$")
  if not key or key == "" then return "usage: motion KEY [prompt] [command]", "err" end
  if #key ~= 1 then return "motion: KEY must be a single character", "err" end
  if rest == "" then ed.motion_cmds[key:byte(1)] = nil; return "", "ok" end
  local prompt = false
  if rest == "prompt" then return "motion: prompt needs a command", "err" end
  local first, tail = rest:match("^(%S+)%s+(.*)$")
  if first == "prompt" then prompt = true; rest = tail end
  if rest == "" then return "motion: prompt needs a command", "err" end
  ed.motion_cmds[key:byte(1)] = { cmd = rest, prompt = prompt }
  return "", "ok"
end)

-- :register NAME [read CMD] [write CMD] -- back the single-char register NAME
-- with shell commands, so a yank/delete into it pipes its text to `write` and a
-- put reads `read`'s stdout (see normal.lua's registers block). The clipboard
-- seam: `register + read wl-paste write wl-copy` (or pbpaste/pbcopy, xclip -o /
-- xclip). NAME with no clause clears the whole backend. The two directions are
-- independent -- set them on one line or two, in either order; a later call
-- merges (write-only then read-only leaves both bound). Each command runs until
-- the other keyword or end of line, so a `read`/`write` command may hold spaces
-- and pipes but not the literal other keyword as a bare word (no real clipboard
-- tool does). Any register name works; `+` is only the conventional clipboard
-- one, and `""` is the unnamed register -- doubled because a lone `"` in an rc
-- file is a comment (see config.lua), so `register " ...` there would truncate;
-- `register "" write CMD` backs it comment-safely (both surfaces accept it).
-- lvi never spawns these itself -- yank/put do, synchronously.
def("register", function(ed, c)
  local name, rest = c.args:match("^(%S+)%s*(.-)%s*$")
  if not name then return "usage: register NAME [read CMD] [write CMD]", "err" end
  if name == '""' then name = '"' end            -- rc-safe spelling of the unnamed register
  if #name ~= 1 then return "register: NAME must be a single character", "err" end
  if rest == "" then ed.reg_backends[name] = nil; return "", "ok" end
  local rd, wr
  local r1, w1 = rest:match("^read%s+(.-)%s+write%s+(.+)$")
  local w2, r2 = rest:match("^write%s+(.-)%s+read%s+(.+)$")
  if r1 then rd, wr = r1, w1
  elseif w2 then wr, rd = w2, r2
  else rd = rest:match("^read%s+(.+)$"); wr = rest:match("^write%s+(.+)$") end
  if not rd and not wr then return "usage: register NAME [read CMD] [write CMD]", "err" end
  local be = ed.reg_backends[name] or {}
  if rd then be.read = rd end
  if wr then be.write = wr end
  ed.reg_backends[name] = be
  return "", "ok"
end)

-- Render a register's raw text for a one-line listing: every control byte
-- becomes caret notation (^J for a newline, ^I tab, ^[ ESC, ^? DEL), so a
-- linewise register and a macro full of control keys each stay ON one line and
-- can't smear the status line / pager with raw escapes. This is display-only;
-- the stored text is untouched.
local function reg_caret(s)
  return (s:gsub("[%z\1-\31\127]", function(ch)
    local n = ch:byte()
    return (n == 127) and "^?" or ("^" .. string.char(n + 64))
  end))
end

-- :registers [names] (aliases reg, display; Vim's :reg) -- list registers and
-- their contents as one line each: "type  \"name  value". type is `l` linewise
-- / `c` charwise (blank for a backend-only register); a command-backed register
-- (:register) appends its {read/write} spec so you can confirm the clipboard is
-- wired. With no argument every non-empty (or backed) register is shown, unnamed
-- first, then a-z, then any others; naming registers (`:reg a "` -- each char is
-- one name) restricts the list. Multi-line output pages like :%p at the prompt;
-- over the socket it is the read side of the register API (:register is write).
-- Note the singular/plural split: :register CONFIGURES one register, :registers
-- (:reg) DISPLAYS them.
local function do_registers(ed, args)
  local want = {}
  for name in args:gmatch("%S") do want[name] = true end   -- each non-blank char is a register name
  local all = not next(want)
  local out = {}
  local function emit(name)
    if not (all or want[name]) then return end
    local r, be = ed.regs[name], ed.reg_backends[name]
    if not r and not be then return end
    local typ = r and (r.linewise and "l" or "c") or " "
    local val = r and reg_caret(r.text) or ""
    if be then
      local spec = {}
      if be.read  then spec[#spec + 1] = "read "  .. be.read  end
      if be.write then spec[#spec + 1] = "write " .. be.write end
      spec = "{" .. table.concat(spec, ", ") .. "}"
      val = (val ~= "") and (val .. "  " .. spec) or spec
    end
    out[#out + 1] = ('%s  "%s  %s'):format(typ, name, val)
  end
  emit('"')
  for i = string.byte("a"), string.byte("z") do emit(string.char(i)) end
  local extra = {}                                          -- any non-a-z, non-'"' names (digits/symbols, backends)
  local seen = {}
  for name in pairs(ed.regs) do
    if name ~= '"' and not name:match("^%l$") then extra[#extra + 1] = name; seen[name] = true end
  end
  for name in pairs(ed.reg_backends) do
    if name ~= '"' and not name:match("^%l$") and not seen[name] then extra[#extra + 1] = name end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do emit(name) end
  if #out == 0 then return "no registers", "ok" end
  return table.concat(out, "\n"), "ok"
end
def("registers reg display", function(ed, c) return do_registers(ed, c.args) end)

-- :marks [chars] (Vim's :marks) -- list this buffer's marks, one line each as
-- "mark line col text" (text is the marked line, leading blanks stripped; col is
-- the 1-based byte column, as :pos reports). No argument lists every set mark --
-- a-z, then the auto `.` (last change) and any others (m may set any char);
-- naming marks (`:marks a .`) restricts it. Marks are PER-BUFFER in lvi (bufs
-- swaps them with the rest of the view state), so this is inherently the current
-- buffer's set -- there are no Vim global/file marks (even `mA` is buffer-local),
-- so no file column is needed. Multi-line output pages like :%p at the prompt.
local function do_marks(ed, args)
  local want = {}
  for name in args:gmatch("%S") do want[name] = true end
  local all = not next(want)
  local rows = {}
  local function emit(name)
    if not (all or want[name]) then return end
    local m = ed.marks[name]
    if not m then return end
    local text = (ed.buf:line(clampline(ed, m[1])) or ""):gsub("^%s+", "")
    rows[#rows + 1] = ("%s  %5d %4d  %s"):format(name, m[1], m[2], text)
  end
  for i = string.byte("a"), string.byte("z") do emit(string.char(i)) end
  local extra = {}                                        -- `.` and any non-a-z marks, sorted
  for name in pairs(ed.marks) do if not name:match("^%l$") then extra[#extra + 1] = name end end
  table.sort(extra)
  for _, name in ipairs(extra) do emit(name) end
  if #rows == 0 then return "no marks", "ok" end
  return table.concat(rows, "\n"), "ok"
end
def("marks", function(ed, c) return do_marks(ed, c.args) end)

-- :hooks [event ...] -- list the registered :on hooks, one `event<TAB>cmd` row
-- per hook, in the :marks/:registers listing mold. A DISPLAY for the human
-- debugging their wiring ("why is this firing twice?") -- scripts must not
-- read-modify-write hook state (the state-ownership razor); re-registering
-- idempotently is the supported script move (:on dedups identical commands).
def("hooks", function(ed, c)
  local want = {}
  for name in c.args:gmatch("%S+") do want[name] = true end
  local all = not next(want)
  local events = {}
  for event in pairs(ed.hooks) do events[#events + 1] = event end
  table.sort(events)
  local rows = {}
  for _, event in ipairs(events) do
    if all or want[event] then
      for _, cmd in ipairs(ed.hooks[event]) do
        rows[#rows + 1] = event .. "\t" .. cmd
      end
    end
  end
  if #rows == 0 then return "no hooks", "ok" end
  return table.concat(rows, "\n"), "ok"
end)

-- Mirror of normal.lua's mark_event (ex must NOT require normal -- normal
-- requires ex, so that dependency runs one way only). Fires the global-mark seam
-- for an uppercase mark; returns true when a hook consumed it, false to fall back
-- to a buffer-local mark. Kept in sync with normal.lua's copy by hand.
local function fire_mark_event(ed, event, ch)
  local hooks = ed.hooks and ed.hooks[event]
  if not (ed.fire_event and hooks and #hooks > 0) then return false end
  ed.event_mark = ch
  ed.fire_event(event)
  ed.event_mark = false
  return true
end

-- :mark {char} [LINE [COL]]  (POSIX :[addr]k / :[addr]mark) -- set a mark WITHOUT
-- moving the cursor. normal-mode `m` can only mark where the cursor already sits;
-- this is the ex-side setter POSIX calls :k/:mark, the piece lvi long lacked. It
-- is what lets an external tool stamp a mark at a spot it is NOT on -- e.g.
-- contrib/lvi-pos sets `" byte-exactly on restore with no visit-and-return cursor
-- dance, so a restore-on-bufenter can't fight a list jump for the cursor.
-- Position precedence: an explicit LINE [COL] wins (byte-exact, mirroring :pos);
-- else a leading ex address supplies the line (POSIX's line-granular form, col 1);
-- else the cursor. Clamped into the buffer like :pos, so a stale saved spot lands
-- as near as it can.
--
-- DEVIATION from POSIX: lvi's dispatch takes the whole leading letter-run as the
-- command word, so the no-space spelling `:ka` parses as command `ka` (which then
-- falls through to the system ex). A space is required -- `:k a`, `:mark a`.
--
-- Uppercase A-Z mirror normal-mode m{A-Z}: they fire the `markset` global-mark
-- seam (contrib/lvi-gmark) AT THE CURSOR, degrading to a buffer-local mark when no
-- hook is wired. That seam carries only the cursor (via $LVI_LINE/$LVI_COL), so an
-- uppercase mark with an explicit LINE/COL can't ride it and is refused rather
-- than silently recording the cursor in place of the asked-for spot.
def("mark k", function(ed, c)
  local ch, rest = c.args:match("^(%S)%s*(.-)%s*$")
  if not ch then return "usage: mark {char} [LINE [COL]]", "err" end
  local ls, cs = rest:match("^(%d+)%s+(%d+)$")
  ls = ls or rest:match("^(%d+)$")
  if rest ~= "" and not ls then return "usage: mark {char} [LINE [COL]]", "err" end
  if ch:match("%u") then                                    -- global mark: cursor only
    if ls or c.a then return "mark " .. ch .. ": a global mark records the cursor; no line/col", "err" end
    if fire_mark_event(ed, "markset", ch) then return "", "ok" end
    ed.marks[ch] = { ed.cy, ed.cx }                         -- no gmark hook: degrade to buffer-local
    return "", "ok"
  end
  local line, col
  if ls then line, col = tonumber(ls), (cs and tonumber(cs) or 1)
  elseif c.a then line, col = c.b, 1
  else line, col = ed.cy, ed.cx end
  line = clampline(ed, line)
  local len = #(ed.buf:line(line) or "")
  col = math.max(1, math.min(col, math.max(1, len)))
  ed.marks[ch] = { line, col }
  return "", "ok"
end)

-- :jumps / :changes (Vim's) -- list a per-buffer position store ({list, idx}),
-- oldest first, one line each as "line col text" (col is a 1-based byte column,
-- as :pos/:marks report). A ">" flags the current position -- the entry idx sits
-- on, or a trailing ">" when idx is at the live edge (idx == #list+1, not
-- navigating). Both stores are per-buffer (bufs swaps them with the view state),
-- so each lists the current buffer's. The jumplist is fed by jump-class motions
-- (Ctrl-O/Ctrl-I walk it); the changelist by keyboard edits (g;/g, walk it, and
-- the `.` mark is its head). Multi-line output pages like :%p at the prompt.
local function do_poslist(ed, store, empty)
  if #store.list == 0 then return empty, "ok" end
  local rows = {}
  for i, p in ipairs(store.list) do
    local mark = (i == store.idx) and ">" or " "
    local text = (ed.buf:line(clampline(ed, p[1])) or ""):gsub("^%s+", "")
    rows[#rows + 1] = ("%s %5d %4d  %s"):format(mark, p[1], p[2], text)
  end
  if store.idx > #store.list then rows[#rows + 1] = ">" end  -- at the edge
  return table.concat(rows, "\n"), "ok"
end
def("jumps", function(ed) return do_poslist(ed, ed.jumps, "no jumps") end)
def("changes", function(ed) return do_poslist(ed, ed.changes, "no changes") end)

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

-- :pos [LINE [COL [UNIT]]] [jump] -- query or set the cursor. Bare :pos reports
-- line<TAB>col (a 1-based BYTE column, matching :marks and Vim's `" mark). With
-- arguments it MOVES the cursor there: the byte-exact setter contrib/lvi-pos
-- needs to restore a saved column, and normal-mode motions can't reach one --
-- `l` steps by character and `|` by display column, so neither lands on a raw
-- byte offset once a line has tabs or multibyte. LINE/COL are clamped into the
-- buffer (a position that outlived an edit lands as near as it can, viminfo's
-- tolerance), then normal.clamp gives the resting column its final char-aware
-- snap -- here rather than at refresh, so the jump test below can compare the
-- position the cursor actually comes to rest at.
--
-- A trailing `jump` makes the move JUMP-CLASS: it records where you left, so
-- Ctrl-O and `` bring you back. Without it :pos is silent like :top, which is
-- right for a restore (contrib/lvi-pos putting the cursor back where it was) and
-- wrong for a navigation -- and navigation over the socket is most of what
-- drives :pos: a list step, a tag jump, the next diff hunk, the next
-- misspelling. Those are jumps in vi too (/ ? n N and vim's quickfix all set the
-- previous-context mark), so a tool that means one asks for one. It stays opt-in
-- rather than the default because the two callers are indistinguishable from
-- here, and only the tool knows which it is.
--
-- UNIT says what COL counts, because the tools that name a column do not agree
-- and the number alone cannot say which they meant. `byte` (the default, and
-- lvi's own unit everywhere else), `char` (a UTF-8 character, what most linters
-- report), or `display` (a screen cell, tabs expanded -- what the GNU Coding
-- Standards prescribe for compiler diagnostics, and what gcc emits). The three
-- coincide for ASCII text with no tabs, which is why a mismatch is invisible
-- until it isn't. Converting is the editor's job and only the editor's: the
-- line's bytes are needed to do it, and a tool driving the socket does not have
-- them (contrib/lvi-list records its list's unit and passes it here).
--
-- `display` counts tab stops at the view's own `tabstop`, since that is what
-- lvi's `|` means and what the screen shows. GNU fixes them at 8 -- as does
-- lvi's default -- so a GNU column is exact unless you have changed it.
def("pos", function(ed, c)
  if c.args == "" then return ed.cy .. "\t" .. ed.cx, "ok" end
  -- Pop `jump` off the end first: UNIT is \a+ and would swallow it.
  local args, isjump = c.args, false
  local rest = args:match("^(.*%S)%s+jump$") or args:match("^jump$") and ""
  if rest then args, isjump = rest, true end
  local l, col, unit = args:match("^(%d+)%s+(%d+)%s+(%a+)$")
  if not l then l, col = args:match("^(%d+)%s+(%d+)$") end
  l = l or args:match("^(%d+)$")
  if not l then return "usage: pos [LINE [COL [byte|char|display]]] [jump]", "err" end
  if unit and unit ~= "byte" and unit ~= "char" and unit ~= "display" then
    return "pos: unknown column unit: " .. unit, "err"
  end
  local oy, ox = ed.cy, ed.cx
  ed.cy = clampline(ed, tonumber(l))
  local line = ed.buf:line(ed.cy) or ""
  local cx = col and tonumber(col) or 1
  if col and unit == "display" then
    cx = disp.byte_at_dispcol(line, ed.opts.tabstop, cx - 1)
  elseif col and unit == "char" then
    local i = 1
    for _ = 2, cx do
      if i > #line then break end
      i = disp.next_char(line, i)
    end
    cx = i
  end
  ed.cx = math.max(1, math.min(cx, math.max(1, #line)))
  -- The snap refresh would apply anyway, done now so the test below sees the
  -- RESTING position: only a move that lands somewhere else is a jump, matching
  -- do_motion, and a column the char-aware cap folds back onto the one we left
  -- is not a move. A no-op :pos jump (a list re-jumping you to the entry you are
  -- on) must not push a stray entry and cost you the one Ctrl-O would have gone
  -- to. normal.lua requires us, so the require is lazy: at load time it would be
  -- a cycle.
  local normal = require("normal")
  normal.clamp(ed)
  if isjump and (ed.cy ~= oy or ed.cx ~= ox) then normal.record_jump(ed, oy, ox) end
  return "", "ok"
end)

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
-- onto). Each variant tags the message with a theme group so the rc can set it
-- apart from the path/name that normally fills that half: :msg -> `Message`,
-- :msge -> `Error` (:hi Message reverse / :hi Error ...). Plain if unthemed -- the
-- text is always legible, the theme only adds emphasis. Newlines collapse (the
-- status line is one row); the message clears on the next normal-mode key, like
-- every other message.
def("msg", function(ed, c) ed.message = (c.args:gsub("\n", " ")); ed.message_hl = "Message"; return "", "ok" end)
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
  local function push(s) for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end end
  if c.a then
    -- :[range]normal -- run the keys once per line in the range, the block-visual
    -- and multi-cursor workhorse. Built as one flat key stream (the pump drains
    -- it like any other, so no driver loop is needed): for each line, {n}G
    -- positions it absolutely and a trailing <Esc> ends any insert the keys
    -- opened (vim auto-terminates the same way). Top to bottom, vi's line-wise
    -- order (:g, :s, :w !cmd all flow this way; a per-line macro that reads the
    -- line above sees it already edited). Keys that add or delete lines are the
    -- caller's responsibility -- with absolute positioning a shifting buffer can
    -- skip or repeat lines; :normal is for per-line edits, and :g//d, :d, :m are
    -- the tools for changing the line count.
    local from, to = line_range(ed, c.a, c.b)
    for ln = from, to do push(tostring(ln) .. "G"); push(c.args); ed.inject[#ed.inject + 1] = 27 end
  else
    push(c.args)
  end
  return "", "ok"
end)

-- :source [FILE] (POSIX :so) -- run FILE as a file of ex commands, through the
-- same loop the startup rc uses (config.run): '"' comments and blank lines
-- skipped, a failing line collected and reported but not fatal to the rest.
-- Bare :source loads the rc auto-discovery locations ($XDG_CONFIG_HOME/lvi/
-- lvirc, then ~/.lvirc) IGNORING $LVIRC: the caller is usually an alternate rc
-- that $LVIRC itself names (contrib/lvirc-man pulling the user's maps in
-- before overriding for the pager), so honoring the override would source the
-- file into itself -- and finding no rc is then a quiet no-op, not an error
-- (having no personal config is a fine state to pull in). The depth cap
-- breaks mutual includes. require() runs late: config requires ex, so a
-- top-level require here would be a cycle.
def("source so", function(ed, c)
  local config = require("config")
  local p, xerr = expand_file(ed, c.args)
  if xerr then return xerr, "err" end
  if not p then p = config.user_rc_path(); if not p then return "", "ok" end end
  if (ed.source_depth or 0) >= 8 then
    return "source nested too deeply: " .. p, "err"
  end
  ed.source_depth = (ed.source_depth or 0) + 1
  local errs = config.run(ed, p)
  ed.source_depth = ed.source_depth - 1
  if not errs then return "cannot open " .. p, "err" end
  if #errs > 0 then return config.summary(p, errs), "err" end
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

  -- Remember a delegated substitute so normal-mode & can repeat it (POSIX vi).
  -- cmdword being a prefix of "substitute" (s, su, ... substitute) catches every
  -- spelling without matching :sort/:set. We stash the un-addressed tail (rest);
  -- do_ex re-runs it against the current line -- lvi does not parse :s, so it
  -- could not reconstruct the command from parts any other way.
  if cmdword ~= "" and ("substitute"):sub(1, #cmdword) == cmdword then
    ed.last_subst = rest
  end

  -- Anything lvi does not handle itself is delegated to the system ex, so vi's
  -- full line-editing vocabulary works without reimplementing it here.
  return do_ex(ed, line)
end

return M
