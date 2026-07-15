--- normal.lua -- the normal-mode command interpreter, as a coroutine.
---
--- The whole grammar is written as straight-line code that *pulls* keys via
--- getkey() (which yields until the driver feeds a key), so counts, operators,
--- and motions compose without a hand-rolled state machine. The design:
---   * a MOTION returns a target (line,col) plus kind (char/line) + inclusive;
---   * an OPERATOR (d/c/y) consumes the range from the cursor to that target;
---   * a standalone motion just moves; a doubled operator (dd) is linewise.
--- Add a motion and it works with every operator for free, and vice versa.
---
--- Input funnel: getkey pops from ed.inject (fed by the driver from the
--- keyboard now; later also '.', macros, and the socket ':normal' hatch -- all
--- just "append keys to ed.inject"). getkey logs every key into ed.keylog so a
--- change can be saved as ed.last_change for a future '.' repeat.

local ex = require("ex")
local disp = require("disp")
local fold = require("fold")

local M = {}

local b = string.byte

-- ---- key input --------------------------------------------------------------
-- Pull the next raw key without logging: from the map-output queue first (so
-- map expansions are never re-mapped -> non-recursive), else the input funnel.
local function getkey_raw(ed)
  -- Replay budget (set per-pump by the driver; nil when a test drives the
  -- coroutine directly): hitting zero parks the coroutine so the driver can
  -- clear the queues -- the escape from a self-feeding macro (see editor.lua's
  -- pump).
  if ed.key_budget then
    ed.key_budget = ed.key_budget - 1
    if ed.key_budget <= 0 then coroutine.yield() end
  end
  if #ed.pending > 0 then return table.remove(ed.pending, 1) end
  while #ed.inject == 0 do coroutine.yield() end
  return table.remove(ed.inject, 1)
end

local function logkey(ed, k)
  ed.keylog[#ed.keylog + 1] = k
  if ed.recording then ed.macro_buf[#ed.macro_buf + 1] = k end
  return k
end

local function getkey(ed) return logkey(ed, getkey_raw(ed)) end

-- Does some map LHS start with the byte-string `seq`?
local function starts_map(ed, seq)
  for lhs in pairs(ed.maps) do
    if lhs:sub(1, #seq) == seq then return true end
  end
  return false
end

-- Read the FIRST key of a command, expanding maps (non-recursive). RHS goes to
-- ed.pending and is consumed raw; only the expanded keys are logged (so `.` and
-- macros replay the expansion, not the LHS). Leader-style maps (LHS starting
-- with a non-command key like '\\') avoid ambiguity; there is no timeout, so a
-- partial LHS blocks until the next key.
local function first_key(ed)
  if #ed.pending > 0 then return getkey(ed) end -- RHS: raw, logged
  local k = getkey_raw(ed)
  if not starts_map(ed, string.char(k)) then return logkey(ed, k) end
  local seq = string.char(k)
  while not ed.maps[seq] and starts_map(ed, seq) do
    seq = seq .. string.char(getkey_raw(ed))
  end
  if ed.maps[seq] then
    local rhs = ed.maps[seq]
    for i = 1, #rhs do ed.pending[#ed.pending + 1] = rhs:byte(i) end
    return getkey(ed)
  end
  for i = #seq, 2, -1 do table.insert(ed.inject, 1, seq:byte(i)) end -- dead end: reprocess
  return logkey(ed, k)
end

-- optional leading count: 1-9 then 0-9 ('0' alone is the ^0 motion, not a count)
local function read_count(ed, k)
  if k < b("1") or k > b("9") then return nil, k end
  local n = k - b("0")
  while true do
    local d = getkey(ed)
    if d >= b("0") and d <= b("9") then n = n * 10 + (d - b("0"))
    else return n, d end
  end
end

local function combine(a, c) -- count1 * count2 with nils
  if a and c then return a * c elseif a then return a else return c end
end

-- ---- buffer/cursor helpers --------------------------------------------------
local function line(ed, l) return ed.buf:line(l) or "" end

local function first_nonblank(s)
  return (s:find("%S")) or 1
end

-- Clamp the cursor to the buffer: the ONE cursor-bounds rule. Exported because
-- the driver's refresh() applies the same invariant after socket-driven motion
-- -- a single definition, so the insert-mode EOL+1 special case cannot drift.
function M.clamp(ed)
  local nl = ed.buf:nlines()
  ed.cy = math.max(1, math.min(ed.cy, nl))
  -- The cursor never rests on a line hidden inside a closed fold: snap it to the
  -- fold's (visible) head. This is the one place that invariant lives, so every
  -- motion that lands in a fold -- G, marks, gg, a mistyped count -- collapses
  -- onto the fold line, and render's crow can always be found on a visible row.
  if ed.opts.foldenable and ed.folds and ed.folds[1] and fold.hidden(ed.folds, ed.cy) then
    ed.cy = fold.innermost_closed(ed.folds, ed.cy).s
  end
  local s = line(ed, ed.cy)
  local maxc = (ed.mode == "insert") and (#s + 1) or disp.last_char(s) -- char-aware cap
  ed.cx = math.max(1, math.min(ed.cx, maxc))
end
local clamp = M.clamp

local function char_class(c)
  if not c or c == "" then return "none" end
  if c:match("%s") then return "blank" end
  local b = c:byte(1)
  if (b and b >= 128) or c:match("[%w_]") then return "word" end -- multibyte = word
  return "punct"
end

-- Word class for the w/b/e family. With `big` (the W/B/E "bigword" variants),
-- punctuation folds into "word", so a WORD is any maximal run of non-blanks.
local function wclass(c, big)
  local cls = char_class(c)
  if big and cls == "punct" then return "word" end
  return cls
end

-- The word under the cursor (Vim's <cword>), using the same word class as
-- w/b/e -- so lvi exports a value it already knows how to compute rather than
-- inventing a second notion of "word". Empty when the cursor isn't on a word
-- char. Expanding byte-by-byte still captures a whole multibyte word (each
-- continuation byte is >=128, hence "word").
function M.cword(ed)
  local s, cx = line(ed, ed.cy), ed.cx
  if cx < 1 or cx > #s or char_class(s:sub(cx, cx)) ~= "word" then return "" end
  local i, j = cx, cx
  while i > 1     and char_class(s:sub(i - 1, i - 1)) == "word" do i = i - 1 end
  while j < #s    and char_class(s:sub(j + 1, j + 1)) == "word" do j = j + 1 end
  return s:sub(i, j)
end

-- ---- registers --------------------------------------------------------------
-- A register is { text = string, linewise = bool }. The unnamed register '"'
-- always mirrors the last delete/yank; a named register also updates it.
--
-- A register may be COMMAND-BACKED (`:register`, ed.reg_backends[name]): a
-- yank/delete into it also pipes its text to the `write` command, and a put
-- reads fresh from the `read` command instead of ed.regs. This is the clipboard
-- seam -- `register + read wl-paste write wl-copy` makes "+ the system clipboard
-- -- but the core learns nothing about clipboards: which command is pure config,
-- and any register name can be backed. The shell-out is injected (ed.reg_read /
-- ed.reg_write, absent headless), so this module stays pure/testable.
local set_reg = ex.set_reg   -- one implementation, shared with ex.lua's :d (M.set_reg there)
-- Deletes and changes route through set_del_reg instead, which layers vi's
-- numbered ("1.."9) and small-delete ("-) bookkeeping on top of set_reg; yanks
-- stay on set_reg (the numbered stack is delete history, not a yank ring).
local set_del_reg = ex.set_del_reg

-- Turn a backend's raw stdout into a register value. A clipboard is just bytes
-- with no linewise flag, so we infer: text carrying any newline is treated as
-- linewise (and gets the trailing '\n' linewise regs always end in) -- which is
-- the natural paste for copied lines AND the only safe reading, since do_put's
-- charwise branch would splice an embedded '\n' straight into a buffer line
-- (breaking the "a line never contains \n" invariant). Single-line text with no
-- newline is charwise, so `"+p` mid-line still works. Empty -> nil (put no-op).
local function reg_from_clip(text)
  if not text or text == "" then return nil end
  if text:find("\n", 1, true) then
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    return { text = text, linewise = true }
  end
  return { text = text, linewise = false }
end

local function get_reg(ed, name)
  local be = name and ed.reg_backends[name]
  if be and be.read and ed.reg_read then return reg_from_clip(ed.reg_read(be.read)) end
  return ed.regs[name or '"']
end

-- Insert-mode completion (Ctrl-P/Ctrl-N): replace the non-blank token before the
-- cursor with a word chosen by the `on complete` command. Core hands the command
-- its context and inserts its stdout (see editor.lua's complete_run and the
-- lvi-complete contrib script); a no-op with no completer registered or headless
-- (ed.complete_run absent). Byte-based like insert_char, so a multibyte token
-- round-trips. dir (prev/next) is advisory -- the completer may ignore it.
local function complete(ed, dir)
  local cmd = ed.hooks.complete and ed.hooks.complete[1]
  if not cmd or not ed.complete_run then return end
  local s = line(ed, ed.cy)
  local left = s:sub(1, ed.cx - 1)
  local token = left:match("%S+$") or ""
  local sel = ed.complete_run(cmd, token, left, dir)
  if not sel or sel == "" then return end
  local at = ed.cx - #token                              -- start of the token
  ed.buf:set(ed.cy, s:sub(1, at - 1) .. sel .. s:sub(ed.cx))
  ed.cx = at + #sel
end

-- ---- insert mode (also a coroutine loop) ------------------------------------
local function insert_char(ed, byte_)
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. string.char(byte_) .. s:sub(ed.cx))
  ed.cx = ed.cx + 1
end

-- Assemble a whole (possibly multibyte) char from an already-read lead byte,
-- pulling its remaining continuation bytes off the input. Any command that reads
-- a char to act on -- f/t/F/T, r, R -- must go through this: reading only the
-- lead byte lands mid-char and leaks the continuation bytes back into the input
-- stream (inserted as text or run as commands), which is bug 6.
local function read_char_from(ed, b)
  local out = { string.char(b) }
  for _ = 2, disp.charlen(b) do out[#out + 1] = string.char(getkey(ed)) end
  return table.concat(out)
end

-- <Tab> in insert mode: a literal tab, unless expandtab, then spaces to the
-- next *shiftwidth* boundary -- shiftwidth is lvi's one indent unit (there is no
-- softtabstop), so >> and Tab agree, and tabstop is left to mean only how wide a
-- literal tab renders. Column-aware via the cursor's display column (measured
-- with tabstop, since that governs how any existing tabs occupy columns).
local function insert_tab(ed)
  if not ed.opts.expandtab then insert_char(ed, 9); return end
  local sw = ed.opts.shiftwidth
  local dcol = disp.dispcol(line(ed, ed.cy), ed.opts.tabstop, ed.cx)
  for _ = 1, sw - dcol % sw do insert_char(ed, 32) end
end

local function split_line(ed) -- <CR> in insert mode
  local s = line(ed, ed.cy)
  local head, tail = s:sub(1, ed.cx - 1), s:sub(ed.cx)
  local indent = ""
  if ed.opts.autoindent then
    indent = s:match("^[ \t]*")                 -- carry the split line's indent onto the next
    if head:match("^[ \t]*$") then head = "" end -- ...and drop it from a line that was only indent
  end
  ed.buf:set(ed.cy, head)
  ed.buf:insert(ed.cy + 1, { indent .. tail })
  ed.cy = ed.cy + 1
  ed.cx = #indent + 1
end

local function backspace(ed)
  if ed.cx > 1 then
    local s = line(ed, ed.cy)
    local pc = disp.prev_char(s, ed.cx)          -- delete the whole char before cursor
    ed.buf:set(ed.cy, s:sub(1, pc - 1) .. s:sub(ed.cx))
    ed.cx = pc
  elseif ed.cy > 1 then -- join with previous line
    local prev, cur = line(ed, ed.cy - 1), line(ed, ed.cy)
    ed.cx = #prev + 1
    ed.buf:set(ed.cy - 1, prev .. cur)
    ed.buf:delete(ed.cy, ed.cy)
    ed.cy = ed.cy - 1
  end
end

-- Ctrl-W: delete the whitespace + word before the cursor (like the shell).
local function kill_word(ed)
  local s, c = line(ed, ed.cy), ed.cx
  local i = c - 1
  while i >= 1 and s:sub(i, i):match("%s") do i = i - 1 end     -- skip trailing blanks
  if i >= 1 then
    local cls = char_class(s:sub(i, i))
    while i >= 1 and char_class(s:sub(i, i)) == cls do i = i - 1 end
  end
  ed.buf:set(ed.cy, s:sub(1, i) .. s:sub(c))
  ed.cx = i + 1
end

-- Ctrl-U: delete from the cursor back to the start of the line.
local function kill_to_bol(ed)
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(ed.cx))
  ed.cx = 1
end

local function insert_mode(ed)
  ed.changed = true
  ed.mode = "insert"
  ed.message = "-- INSERT --"
  clamp(ed)
  while true do
    local k = getkey(ed)
    if k == 27 then                                    -- ESC
      -- vi's autoindent rule: a line left holding only its auto-inserted indent
      -- (nothing typed) is trimmed back to empty, so no trailing whitespace.
      if ed.opts.autoindent and line(ed, ed.cy):match("^[ \t]+$") then
        ed.buf:set(ed.cy, ""); ed.cx = 1
      end
      break
    elseif k == 13 or k == 10 then split_line(ed)      -- CR
    elseif k == 127 or k == 8 then backspace(ed)       -- Backspace / Ctrl-H
    elseif k == 23 then kill_word(ed)                  -- Ctrl-W: erase word (POSIX vi)
    elseif k == 21 then kill_to_bol(ed)                -- Ctrl-U: erase to line start
    -- Ctrl-A / Ctrl-E move to line ends. Not POSIX vi (readline muscle memory);
    -- vi's answer is <Esc> then I / A. Included by request.
    elseif k == 1 then ed.cx = 1                       -- Ctrl-A: start of line
    elseif k == 5 then ed.cx = #line(ed, ed.cy) + 1    -- Ctrl-E: end of line
    elseif k == 16 then complete(ed, "prev")           -- Ctrl-P: complete (backward)
    elseif k == 14 then complete(ed, "next")           -- Ctrl-N: complete (forward)
    elseif k == 9 then insert_tab(ed)                  -- Tab: literal, or spaces if expandtab
    elseif k >= 32 and k ~= 127 then insert_char(ed, k) -- printable + UTF-8 bytes
    end
    clamp(ed)
  end
  ed.mode = "normal"
  ed.message = nil; ed.message_hl = nil
  ed.cx = math.max(1, ed.cx - 1) -- vi steps left on leaving insert
  clamp(ed)
end

-- R: overwrite mode. Reuses insert's cursor semantics (mode == "insert" lets the
-- cursor sit at #s+1 so typing past EOL extends the line). Each printable key
-- replaces the whole char under the cursor (or appends at/after EOL); <CR> splits
-- like insert; backspace just moves left (no original-char restore -- retype to
-- fix). A typed multibyte char is read whole (read_char_from) and replaces one
-- char, so overwriting an em-dash leaves the line valid UTF-8, not a stray byte.
local function replace_mode(ed)
  ed.changed = true
  ed.mode = "insert"
  ed.message = "-- REPLACE --"
  clamp(ed)
  while true do
    local k = getkey(ed)
    if k == 27 then break                              -- ESC
    elseif k == 13 or k == 10 then split_line(ed)      -- CR
    elseif k == 127 or k == 8 then                     -- Backspace: move left only
      if ed.cx > 1 then ed.cx = disp.prev_char(line(ed, ed.cy), ed.cx) end
    elseif k == 9 or (k >= 32 and k ~= 127) then
      local ch = read_char_from(ed, k)                 -- whole char, multibyte included
      local s = line(ed, ed.cy)
      if ed.cx > #s then                               -- past EOL: extend
        for i = 1, #ch do insert_char(ed, ch:byte(i)) end
      else
        local nc = disp.next_char(s, ed.cx)
        ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. ch .. s:sub(nc))
        ed.cx = ed.cx + #ch
      end
    end
    clamp(ed)
  end
  ed.mode = "normal"
  ed.message = nil; ed.message_hl = nil
  ed.cx = math.max(1, ed.cx - 1)
  clamp(ed)
end

-- ---- operators over ranges --------------------------------------------------
-- Re-indent a line by `delta` display columns (>/< shift). Only the leading
-- <blank> run is touched; the rest of the line is preserved. The new indent is
-- emitted as spaces when `et` (expandtab), else tab-optimized to `ts`. A blank or
-- empty line is left unchanged on a right shift and cleared on a left shift
-- (matching ex: "empty lines shall not be changed" by >).
local function reindent(s, delta, et, ts)
  local lead, rest = s:match("^([ \t]*)(.*)$")
  if rest == "" then return (delta < 0) and "" or s end
  local w = 0
  for i = 1, #lead do
    if lead:sub(i, i) == "\t" then w = w + (ts - w % ts) else w = w + 1 end
  end
  local nw = math.max(0, w + delta)
  local indent = et and string.rep(" ", nw)
    or (string.rep("\t", math.floor(nw / ts)) .. string.rep(" ", nw % ts))
  return indent .. rest
end

local function op_lines(ed, op, a, c, reg)
  a = math.max(1, a); c = math.min(c, ed.buf:nlines())
  if a > c then return end
  if op == "shift_r" or op == "shift_l" then
    local sw = ed.opts.shiftwidth
    local ts = ed.opts.tabstop
    local et = ed.opts.expandtab
    local delta = (op == "shift_r" and 1 or -1) * sw
    local out = {}
    for i = a, c do out[#out + 1] = reindent(line(ed, i), delta, et, ts) end
    ed.buf:splice(a, c - a + 1, out)                    -- one splice = one undo
    ed.cy = a; ed.cx = first_nonblank(line(ed, a)); ed.changed = true
    clamp(ed)
    return
  end
  local text = table.concat(ed.buf:get(a, c), "\n") .. "\n" -- linewise regs end in \n
  local rec = (op == "y") and set_reg or set_del_reg  -- yank vs delete/change bookkeeping
  rec(ed, reg, text, true)
  if op == "y" then
    ed.cy = a
  elseif op == "d" then
    ed.buf:delete(a, c); ed.cy = a; ed.changed = true
  elseif op == "c" then
    ed.buf:delete(a, c); ed.buf:insert(a, { "" })
    ed.cy = a; ed.cx = 1; ed.changed = true
    insert_mode(ed)
  end
  clamp(ed)
end

local function pos_le(l1, c1, l2, c2)
  return l1 < l2 or (l1 == l2 and c1 <= c2)
end

-- Case transform for the gu/gU/g~ operators. Leaves non-letters (and the \n
-- joiners in a multi-line range) untouched.
local function apply_case(s, mode)
  if mode == "upper" then return (s:upper())
  elseif mode == "lower" then return (s:lower())
  else return (s:gsub("%a", function(ch) return ch:match("%l") and ch:upper() or ch:lower() end)) end
end

-- Charwise operator over a (possibly multi-line) range from (sl,sc) to (tl,tc).
-- `inclusive` keeps the char at the far end; exclusive drops it (stepping back a
-- line if that lands before column 1 -- which is what makes `dw` on the last
-- word of a line stop at the newline instead of joining, matching vi). Besides
-- d/c/y it also serves the case operators (op = upper/lower/toggle): same range
-- extraction, but it rewrites the span in place instead of deleting it.
local function op_chars_range(ed, op, sl, sc, tl, tc, inclusive, reg)
  if not pos_le(sl, sc, tl, tc) then sl, sc, tl, tc = tl, tc, sl, sc end
  local el, ec = tl, tc
  if not inclusive then
    ec = ec - 1
    while ec < 1 and el > sl do el = el - 1; ec = #line(ed, el) end
  end
  if el < sl or (el == sl and ec < sc) then return end -- empty range
  local first, last = line(ed, sl), line(ed, el)
  ec = math.min(ec, #last)
  local text
  if sl == el then
    text = first:sub(sc, ec)
  else
    local t = { first:sub(sc) }
    for i = sl + 1, el - 1 do t[#t + 1] = line(ed, i) end
    t[#t + 1] = last:sub(1, ec)
    text = table.concat(t, "\n")
  end
  if op == "upper" or op == "lower" or op == "toggle" then
    local cased, head, tail = apply_case(text, op), first:sub(1, sc - 1), last:sub(ec + 1)
    if sl == el then
      ed.buf:set(sl, head .. cased .. tail)
    else
      local parts = {}
      for seg in (cased .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = seg end
      parts[1] = head .. parts[1]; parts[#parts] = parts[#parts] .. tail
      ed.buf:splice(sl, el - sl + 1, parts)
    end
    ed.cy, ed.cx = sl, sc; ed.changed = true; clamp(ed); return
  end
  local rec = (op == "y") and set_reg or set_del_reg  -- yank vs delete/change bookkeeping
  rec(ed, reg, text, false)
  if op == "y" then
    ed.cy, ed.cx = sl, sc
  else
    ed.buf:splice(sl, el - sl + 1, { first:sub(1, sc - 1) .. last:sub(ec + 1) })
    ed.cy, ed.cx = sl, sc
    ed.changed = true
    if op == "c" then insert_mode(ed) end
  end
  clamp(ed)
end

-- ---- motions ----------------------------------------------------------------
-- Each: { kind = "char"|"line", inclusive = bool, move = fn(ed,count)->(l,c[,inc]) }.
-- Word motions cross line boundaries and stop on empty lines (POSIX-ish).
local function word_forward(ed, count, big)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    local s = line(ed, l)
    if #s > 0 and c <= #s and wclass(s:sub(c, c), big) ~= "blank" then
      local cls = wclass(s:sub(c, c), big)
      while c <= #s and wclass(s:sub(c, c), big) == cls do c = c + 1 end
    end
    while true do
      s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
        if #line(ed, l) == 0 then return end -- empty line is a word stop
      elseif wclass(s:sub(c, c), big) == "blank" then c = c + 1
      else return end
    end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.min(c, math.max(1, #line(ed, l)))
end

local function word_back(ed, count, big)
  local l, c = ed.cy, ed.cx
  local function step()
    c = c - 1
    while true do
      if c < 1 then
        if l <= 1 then c = 1; return end
        l = l - 1; c = #line(ed, l)
        if c == 0 then c = 1; return end   -- empty line is a word stop
      else
        local s = line(ed, l)
        if wclass(s:sub(c, c), big) == "blank" then c = c - 1 else break end
      end
    end
    local s = line(ed, l)
    local cls = wclass(s:sub(c, c), big)
    while c > 1 and wclass(s:sub(c - 1, c - 1), big) == cls do c = c - 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

local function word_end(ed, count, big)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    c = c + 1
    while true do
      local s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
      elseif wclass(s:sub(c, c), big) == "blank" then c = c + 1
      else break end
    end
    local s = line(ed, l)
    local cls = wclass(s:sub(c, c), big)
    while c < #s and wclass(s:sub(c + 1, c + 1), big) == cls do c = c + 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

-- The cw/cW special case. POSIX makes the w/W motion's region depend on which
-- operator is pending (MANPAGE-vi.txt "Move to Beginning of Bigword", rules
-- 1/3/4): a *change* stops at the end of the word, leaving the trailing blanks,
-- while d/y eat them -- so `cw` clears just the word and drops you in front of
-- the gap (the classic "cw a rebase todo's `pick`" case). This is the ONE place
-- POSIX keys a region off the operator; every other motion is operator-agnostic
-- (see apply_operator), so it lives as an opt-in hook on the two motion entries
-- rather than a branch in the generic operator path -- mirroring POSIX, which
-- documents the carve-out inside the motion, not the c command.
--
-- NB: NOT a clean alias for `ce`. On the last char of a word, `cw` changes only
-- that char while `ce` runs to the next word's end. The faithful transform is
-- word_forward's landing (the start of the next word) backed up over the blanks
-- to the last non-blank -- the end of the word the change should stop at.
local function change_word_target(ed, count, big)
  local s = line(ed, ed.cy)
  local onc = (ed.cx <= #s) and s:sub(ed.cx, ed.cx) or ""
  if (count or 1) == 1 and (onc == "" or wclass(onc, big) == "blank") then
    return ed.cy, ed.cx, true          -- rule 1: change just the char under the cursor
  end
  local tl, tc = word_forward(ed, count, big)
  local pl, pc = tl, tc - 1             -- one char back from the next word's start
  while pl > ed.cy or (pl == ed.cy and pc > ed.cx) do
    if pc < 1 then
      pl = pl - 1; pc = #line(ed, pl)   -- landing was at column 1: step to prior line's end
    elseif wclass(line(ed, pl):sub(pc, pc), big) == "blank" then
      pc = pc - 1                       -- skip back over the separating blanks
    else
      break                             -- sitting on the word's last non-blank
    end
  end
  if pl < ed.cy or (pl == ed.cy and pc < ed.cx) then pl, pc = ed.cy, ed.cx end
  return pl, math.max(1, pc), true
end

-- Last occurrence of ch that STARTS at a byte < bound (nil if none). ch may be
-- multibyte; matches stay char-aligned because a UTF-8 lead byte never appears
-- mid-character, so a plain byte find can only land on a char boundary.
local function rfind_before(s, ch, bound)
  local i, from = nil, 1
  while true do
    local p = s:find(ch, from, true)
    if not p or p >= bound then break end
    i, from = p, p + 1
  end
  return i
end

-- f/t/F/T within-line char search, shared by the motions and by ;/,. Returns the
-- target column, or nil if not found. `ch` is a whole (possibly multibyte) char;
-- byte columns step by disp.next_char/prev_char and by #ch so a landing never
-- bisects a char -- reading only the lead byte (the old bug) matched mid-char.
local function do_find(ed, kind, ch, count)
  local s, c, w = line(ed, ed.cy), ed.cx, #ch
  for _ = 1, (count or 1) do
    if kind == "f" then
      local i = s:find(ch, c + 1, true); if not i then return nil end; c = i
    elseif kind == "t" then
      local from = (s:sub(c + 1, c + w) == ch) and (c + 1 + w) or (c + 1)
      local i = s:find(ch, from, true); if not i then return nil end; c = disp.prev_char(s, i)
    elseif kind == "F" then
      local i = rfind_before(s, ch, c); if not i then return nil end; c = i
    elseif kind == "T" then
      local i = rfind_before(s, ch, c)
      if i and i + w == c then i = rfind_before(s, ch, i) end   -- already just past it: keep going
      if not i then return nil end; c = i + w
    end
  end
  return c
end

-- f/t are forward+inclusive; F/T are backward (exclusive of the origin in our
-- range model). Each records ed.last_find so ;/, can repeat it.
local function find_motion(kind, inclusive)
  return { kind = "char", inclusive = inclusive, move = function(ed, count)
    ed.last_find = { kind = kind, char = read_char_from(ed, getkey(ed)) }
    local c = do_find(ed, kind, ed.last_find.char, count)
    return ed.cy, c or ed.cx
  end }
end

local flip = { f = "F", F = "f", t = "T", T = "t" }

-- Paragraph ({ }) and section ([[ ]]) motions. Pragmatic subset of POSIX: a
-- SECTION boundary is a line starting with '{' or <form-feed>, or the first/last
-- line; a PARAGRAPH boundary is a section boundary or an empty line. We skip the
-- nroff `sections`/`paragraphs` macro options (lvi has none). The cursor lands on
-- the boundary line's first column, which matches vim. We also skip POSIX's rule
-- (MANPAGE-vi.txt "section/paragraph boundary") that promotes these to line mode
-- when they're an operator target at a line boundary: they stay plain charwise-
-- exclusive, so `d}` deletes to the boundary where vi/vim would take whole lines.
-- Unlike cw's carve-out (change_word_target), this promotion is operator-agnostic
-- and needs per-cursor line/char negotiation, so it's a deliberate divergence,
-- not a wart worth teaching every operator -- documented on `d c y` in the manpage.
local function is_boundary(ed, l, section_only)
  local s = line(ed, l)
  local c = s:sub(1, 1)
  if c == "{" or c == "\f" then return true end
  return (not section_only) and s == ""
end

-- One step to the next/prev boundary. When starting inside a run of empty lines
-- (paragraph mode), skip the whole run first so we don't re-stop on it.
local function para_step(ed, l, forward, section_only)
  local N = ed.buf:nlines()
  if forward then
    if l >= N then return N end
    if not section_only and line(ed, l) == "" then
      while l < N and line(ed, l) == "" do l = l + 1 end
    else
      l = l + 1
    end
    while l < N and not is_boundary(ed, l, section_only) do l = l + 1 end
    return l
  else
    if l <= 1 then return 1 end
    if not section_only and line(ed, l) == "" then
      while l > 1 and line(ed, l) == "" do l = l - 1 end
    else
      l = l - 1
    end
    while l > 1 and not is_boundary(ed, l, section_only) do l = l - 1 end
    return l
  end
end

local function para_target(ed, count, forward, section_only)
  local l = ed.cy
  for _ = 1, (count or 1) do l = para_step(ed, l, forward, section_only) end
  return l
end

-- Sentence motions ( ). A sentence ends at '.', '!' or '?' -- optionally
-- followed by any run of closing )]"' chars -- and then either the end of the
-- line or TWO <space> characters (POSIX; note vim breaks on a single space, see
-- MANPAGE-vi.txt "sentence boundary"). A paragraph boundary is also a sentence
-- boundary. The sentence *start* is the first non-blank after such a break.
-- Charwise-exclusive, count-aware, like vim's ( and ).
local CLOSERS = { [")"] = true, ["]"] = true, ['"'] = true, ["'"] = true }

-- The sentence start on the line following a terminator/blank at EOL of line l.
local function sent_after_eol(ed, l, N)
  if l >= N then return l, math.max(1, #line(ed, l)) end
  local nl = l + 1
  if is_boundary(ed, nl, false) then return nl, 1 end   -- empty / '{' line = boundary
  return nl, first_nonblank(line(ed, nl))
end

local function sent_forward(ed, l, c)
  local N = ed.buf:nlines()
  local s = line(ed, l)
  while true do
    if c > #s then                                       -- ran off the line
      local left_bnd = is_boundary(ed, l, false)
      if l >= N then return l, math.max(1, #s) end        -- EOF
      l = l + 1; s = line(ed, l); c = 1
      if is_boundary(ed, l, false) then return l, 1 end   -- crossed into a boundary line
      if left_bnd then return l, first_nonblank(s) end    -- first non-blank after one
    else
      local ch = s:sub(c, c)
      if ch == "." or ch == "!" or ch == "?" then
        local j = c + 1
        while CLOSERS[s:sub(j, j)] do j = j + 1 end
        if j > #s then                                    -- terminator at end of line
          return sent_after_eol(ed, l, N)
        elseif s:sub(j, j) == " " and s:sub(j + 1, j + 1) == " " then
          local k = j                                     -- terminator + >=2 spaces
          while s:sub(k, k) == " " or s:sub(k, k) == "\t" do k = k + 1 end
          if k > #s then return sent_after_eol(ed, l, N) end
          return l, k
        end
      end
      c = c + 1
    end
  end
end

local function pos_lt(l1, c1, l2, c2) return l1 < l2 or (l1 == l2 and c1 < c2) end

-- The first sentence start of the buffer (line 1 is always a boundary).
local function sent_first(ed)
  local s = line(ed, 1)
  return 1, (s == "") and 1 or first_nonblank(s)
end

-- Previous sentence start: walk forward from the first start, keeping the last
-- one still before the cursor. Linear in distance-from-start, like the other
-- backward motions here; reuses the (tested) forward scanner rather than
-- re-deriving boundary detection in reverse.
local function sent_backward(ed, l, c)
  local cl, cc = sent_first(ed)
  if not pos_lt(cl, cc, l, c) then return cl, cc end       -- already at/before the first
  while true do
    local nl, nc = sent_forward(ed, cl, cc)
    if not pos_lt(nl, nc, l, c) then return cl, cc end      -- next would reach/pass cursor
    if nl == cl and nc == cc then return cl, cc end         -- no progress (EOF)
    cl, cc = nl, nc
  end
end

local function sent_target(ed, count, forward)
  local l, c = ed.cy, ed.cx
  for _ = 1, (count or 1) do
    if forward then l, c = sent_forward(ed, l, c) else l, c = sent_backward(ed, l, c) end
  end
  return l, c
end

-- % : jump to the matching bracket. If the cursor isn't on one of ()[]{}, scan
-- forward on the current line for the first one (error/no-op if none). An open
-- bracket searches forward for its close, a close searches backward, counting
-- nesting of the SAME pair type only -- other bracket types are ignored (POSIX
-- leaves that implementation-defined; matches vim, no string/comment awareness).
-- Charwise-inclusive so d%/y%/c% span both brackets; we skip POSIX's rule that
-- makes a whole-line-spanning match linewise (same simplification as the other
-- motions here). No count (the N% "percent of file" jump is a vim extension).
local PAIRS  = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local OPENOF = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

local function match_bracket(ed)
  local l, c = ed.cy, ed.cx
  local s = line(ed, l)
  while c <= #s and not (PAIRS[s:sub(c, c)] or OPENOF[s:sub(c, c)]) do c = c + 1 end
  if c > #s then return ed.cy, ed.cx end               -- no bracket on the line: no-op
  local ch = s:sub(c, c)
  local N = ed.buf:nlines()
  local fwd = PAIRS[ch] ~= nil
  -- The starting bracket's own type increments the counter; its opposite
  -- decrements it (so it works the same scanning either direction).
  local same  = ch
  local other = fwd and PAIRS[ch] or OPENOF[ch]
  local depth = 0
  while l >= 1 and l <= N do
    s = line(ed, l)
    local d = (c >= 1 and c <= #s) and s:sub(c, c) or ""
    if d == same then depth = depth + 1
    elseif d == other then
      depth = depth - 1
      if depth == 0 then return l, c end
    end
    if fwd then
      c = c + 1
      if c > #s then l, c = l + 1, 1 end
    else
      c = c - 1
      if c < 1 then l = l - 1; c = (l >= 1) and #line(ed, l) or 0 end
    end
  end
  return ed.cy, ed.cx                                  -- unmatched: no-op
end

-- ---- screen geometry (shared by H/M/L and the scroll commands) --------------
local function textrows(ed) return ed.rows - 1 end

-- Fold-aware buffer-line stepping. When folds are present these skip closed-fold
-- interiors (a closed fold is one screen row at its head); with no folds they
-- collapse to plain l+/-1, so the fold-free fast paths are unchanged. These are
-- the single point where this module bends the buffer-line <-> screen-row
-- mapping away from affine -- the same bend wrap already made (one line -> many
-- rows); folding is its inverse (many lines -> one row).
local function has_folds(ed) return ed.opts.foldenable and ed.folds and ed.folds[1] ~= nil end
local function nextv(ed, l)
  if has_folds(ed) then return fold.next_vline(ed.folds, l, ed.buf:nlines()) end
  return (l < ed.buf:nlines()) and l + 1 or nil
end
local function prevv(ed, l)
  if has_folds(ed) then return fold.prev_vline(ed.folds, l, ed.buf:nlines()) end
  return (l > 1) and l - 1 or nil
end
-- Screen rows a buffer line occupies: 1 for a closed-fold head (its summary),
-- else its wrapped segment count.
local function segs_at(ed, l, W, ts)
  if has_folds(ed) and fold.closed_head(ed.folds, l) then return 1 end
  return disp.nsegs(line(ed, l), W, ts, ed.opts.linebreak)
end

-- Move a screen position (line l, sub-row sub) by `rows` screen rows (negative =
-- up), honoring wrap AND folds, clamped to the buffer. In nowrap each visible
-- line is one row; a closed fold collapses its interior to a single head row.
local function advance_rows(ed, l, sub, rows)
  local N = ed.buf:nlines()
  if not ed.opts.wrap then
    if not has_folds(ed) then return math.max(1, math.min(l + rows, N)), 0 end
    if rows >= 0 then
      for _ = 1, rows do local nl = nextv(ed, l); if nl then l = nl else break end end
    else
      for _ = 1, -rows do local pl = prevv(ed, l); if pl then l = pl else break end end
    end
    return l, 0
  end
  local W, ts = ed.cols, ed.opts.tabstop
  if rows > 0 then
    for _ = 1, rows do
      if sub + 1 < segs_at(ed, l, W, ts) then sub = sub + 1
      else local nl = nextv(ed, l); if nl then l, sub = nl, 0 else break end end
    end
  else
    for _ = 1, -rows do
      if sub > 0 then sub = sub - 1
      else local pl = prevv(ed, l); if pl then l, sub = pl, segs_at(ed, pl, W, ts) - 1 else break end end
    end
  end
  return l, sub
end

-- The bottommost buffer line with a row on screen. Walk textrows-1 rows down
-- from the top; in wrap a single line spans several rows, so this is well below
-- top+textrows-1. (nowrap collapses to exactly top+textrows-1, clamped.)
local function visible_bottom(ed)
  return (advance_rows(ed, ed.top, ed.topsub, textrows(ed) - 1))
end

-- The gg/gj/gk body, split out so the standalone `g` command (which must peek
-- the next key to tell a g-motion from a g-operator like gU) can run it with the
-- already-read suffix, while the motion table entry (for the dgg operator path)
-- reads its own suffix. Each path reads the suffix exactly once.
local function g_motion_move(ed, k2, count)
  if k2 == b("g") then
    local t = math.max(1, math.min(count or 1, ed.buf:nlines()))
    return t, first_nonblank(line(ed, t))
  end
  if k2 ~= b("j") and k2 ~= b("k") then return ed.cy, ed.cx end
  local down, n = (k2 == b("j")), (count or 1)
  if not ed.opts.wrap then           -- no wrapping: gj == j
    return ed.cy + (down and n or -n), ed.cx
  end
  -- Move by screen (display) rows, holding the current visual column.
  local W, ts, lb = ed.cols, ed.opts.tabstop, ed.opts.linebreak
  local N, l = ed.buf:nlines(), ed.cy
  local sub, ccol = disp.locate(line(ed, l), W, ts, ed.cx, lb)
  for _ = 1, n do
    if down then
      if sub + 1 < disp.nsegs(line(ed, l), W, ts, lb) then sub = sub + 1
      elseif l < N then l, sub = l + 1, 0 else break end
    else
      if sub > 0 then sub = sub - 1
      elseif l > 1 then l = l - 1; sub = disp.nsegs(line(ed, l), W, ts, lb) - 1
      else break end
    end
  end
  return l, disp.byteat(line(ed, l), W, ts, sub, ccol, lb)
end

-- The global-mark seam. Uppercase marks A-Z are delegated to an external tool
-- (contrib/lvi-gmark) rather than lvi's per-buffer ed.marks: `m{A-Z}` fires the
-- `markset` event and `` `{A-Z} `` / '{A-Z} fires `markjump`, each handing the
-- char to the hook via $LVI_MARK. The tool owns the (cross-session, file-aware)
-- storage -- on set it persists file+line+col, on jump it opens the file and
-- moves over the socket -- so the core keeps no path-bearing marks and no
-- shared-file format. Fired only when the matching hook is registered; with none
-- (the tool not wired up), uppercase degrades to an ordinary buffer-local mark,
-- so it never silently no-ops. jump returns the cursor unmoved (the tool moves
-- asynchronously), so do_motion records no jumplist entry for it. Returns true
-- when the event was fired (the caller then does nothing more).
local function mark_event(ed, event, ch)
  local hooks = ed.hooks and ed.hooks[event]
  if not (ed.fire_event and hooks and #hooks > 0) then return false end
  ed.event_mark = ch
  ed.fire_event(event)          -- synchronous: spawns detached children with $LVI_MARK set
  ed.event_mark = false
  return true
end

local motions = {
  [b("h")] = { kind = "char", move = function(ed, n)
    local s, c = line(ed, ed.cy), ed.cx
    for _ = 1, (n or 1) do c = disp.prev_char(s, c) end
    return ed.cy, c
  end },
  [b("l")] = { kind = "char", move = function(ed, n)
    local s, c = line(ed, ed.cy), ed.cx
    for _ = 1, (n or 1) do if c <= #s then c = disp.next_char(s, c) end end
    return ed.cy, c
  end },
  [b("0")] = { kind = "char", move = function(ed) return ed.cy, 1 end },
  [b("^")] = { kind = "char", move = function(ed) return ed.cy, first_nonblank(line(ed, ed.cy)) end },
  [b("$")] = { kind = "char", inclusive = true, move = function(ed) return ed.cy, math.max(1, #line(ed, ed.cy)) end },
  [b("w")] = { kind = "char", move = word_forward,
               c_target = function(ed, n) return change_word_target(ed, n, false) end },
  [b("b")] = { kind = "char", move = word_back },
  [b("e")] = { kind = "char", inclusive = true, move = word_end },
  [b("W")] = { kind = "char", move = function(ed, n) return word_forward(ed, n, true) end,
               c_target = function(ed, n) return change_word_target(ed, n, true) end },
  [b("B")] = { kind = "char", move = function(ed, n) return word_back(ed, n, true) end },
  [b("E")] = { kind = "char", inclusive = true, move = function(ed, n) return word_end(ed, n, true) end },
  [b("%")] = { kind = "char", inclusive = true, jump = true, move = match_bracket },
  [b("f")] = find_motion("f", true),
  [b("t")] = find_motion("t", true),
  [b("F")] = find_motion("F", false),
  [b("T")] = find_motion("T", false),
  [b(";")] = { kind = "char", move = function(ed, count)
    local lf = ed.last_find; if not lf then return ed.cy, ed.cx, false end
    return ed.cy, do_find(ed, lf.kind, lf.char, count) or ed.cx, (lf.kind == "f" or lf.kind == "t")
  end },
  [b(",")] = { kind = "char", move = function(ed, count)
    local lf = ed.last_find; if not lf then return ed.cy, ed.cx, false end
    local k = flip[lf.kind]
    return ed.cy, do_find(ed, k, lf.char, count) or ed.cx, (k == "f" or k == "t")
  end },
  -- dgg and the like: the operator path reads the suffix here. Standalone `g`
  -- (which may instead be gU/gq/...) is handled in command().
  [b("g")] = { kind = "line", move = function(ed, count) return g_motion_move(ed, getkey(ed), count) end },
  [96] = { kind = "char", jump = true, move = function(ed) -- `{mark}: exact position
    local ch = string.char(getkey(ed))
    if ch:match("%u") and mark_event(ed, "markjump", ch) then return ed.cy, ed.cx end
    local m = ed.marks[ch]
    if not m then return ed.cy, ed.cx end
    return m[1], m[2]
  end },
  [39] = { kind = "line", jump = true, move = function(ed) -- '{mark}: mark's line
    local ch = string.char(getkey(ed))
    if ch:match("%u") and mark_event(ed, "markjump", ch) then return ed.cy, ed.cx end
    local m = ed.marks[ch]
    if not m then return ed.cy, ed.cx end
    local l = math.max(1, math.min(m[1], ed.buf:nlines()))
    return l, first_nonblank(line(ed, l))
  end },
  [124] = { kind = "char", move = function(ed, count) -- N| : goto display column N
    local ts = ed.opts.tabstop
    return ed.cy, disp.byte_at_dispcol(line(ed, ed.cy), ts, (count or 1) - 1)
  end },
  [b("j")] = { kind = "line", move = function(ed, n)
    if not has_folds(ed) then return ed.cy + (n or 1), ed.cx end
    local l = ed.cy                          -- step over closed folds (one row each)
    for _ = 1, (n or 1) do local nl = nextv(ed, l); if nl then l = nl else break end end
    return l, ed.cx
  end },
  [b("k")] = { kind = "line", move = function(ed, n)
    if not has_folds(ed) then return ed.cy - (n or 1), ed.cx end
    local l = ed.cy
    for _ = 1, (n or 1) do local pl = prevv(ed, l); if pl then l = pl else break end end
    return l, ed.cx
  end },
  [b("G")] = { kind = "line", jump = true, move = function(ed, n)
    local t = n or ed.buf:nlines()
    t = math.max(1, math.min(t, ed.buf:nlines()))
    return t, first_nonblank(line(ed, t))
  end },
  -- H/M/L: top / middle / bottom line of the *screen*, as linewise motions (so
  -- they compose with operators). Wrap-aware via visible_bottom, which walks
  -- screen rows -- a wrapped line spans several, so plain buffer-line arithmetic
  -- would point past the visible area (and dragging the cursor there scrolls).
  [b("H")] = { kind = "line", jump = true, move = function(ed, n)
    local l = math.min(ed.top + (n or 1) - 1, visible_bottom(ed))
    return l, first_nonblank(line(ed, l))
  end },
  [b("L")] = { kind = "line", jump = true, move = function(ed, n)
    local l = math.max(ed.top, visible_bottom(ed) - (n or 1) + 1)
    return l, first_nonblank(line(ed, l))
  end },
  [b("M")] = { kind = "line", jump = true, move = function(ed)
    local l = math.floor((ed.top + visible_bottom(ed)) / 2)
    return l, first_nonblank(line(ed, l))
  end },
  -- Paragraph / section motions (charwise-exclusive; land on the boundary's
  -- first column). [[ / ]] read their doubled key like g does gg.
  [b("}")] = { kind = "char", jump = true, move = function(ed, count) return para_target(ed, count, true, false), 1 end },
  [b("{")] = { kind = "char", jump = true, move = function(ed, count) return para_target(ed, count, false, false), 1 end },
  [b("]")] = { kind = "char", jump = true, move = function(ed, count)
    if getkey(ed) ~= b("]") then return ed.cy, ed.cx end
    return para_target(ed, count, true, true), 1
  end },
  [b("[")] = { kind = "char", jump = true, move = function(ed, count)
    if getkey(ed) ~= b("[") then return ed.cy, ed.cx end
    return para_target(ed, count, false, true), 1
  end },
  [b(")")] = { kind = "char", jump = true, move = function(ed, count) return sent_target(ed, count, true) end },
  [b("(")] = { kind = "char", jump = true, move = function(ed, count) return sent_target(ed, count, false) end },
}

-- The jumplist: a per-buffer rolling record of positions a "jump-class" motion
-- (G, %, marks, {}, (), [[ ]], H/M/L -- the entries flagged jump=true) left
-- FROM, so Ctrl-O/Ctrl-I can walk back and forth. Mirrors vim's setpcmark:
-- jumps are per-buffer (swapped by bufs alongside marks), the store is
-- ed.jumps = { list = {line,col}..., idx }, and idx is a 1-based cursor into
-- list where idx == #list+1 means "at the live edge, not navigating". Only bare
-- motions push (via do_motion) -- an operator's motion target (apply_operator)
-- must not, matching vi. Search (n/N//) is a contrib tool over the socket, so it
-- doesn't feed this; only the core jump motions do.
local JUMP_MAX = 100

-- Record a position into a rolling {list, idx} store (dedup by line like vim, cap
-- the list, reset idx to the edge). Shared by the jumplist here and the driver's
-- changelist (editor.record_change feeds ed.changes through this) -- same shape,
-- two stores, because jumps and edits answer different questions (see :jumps /
-- :changes). Exported as M.record_pos.
local function record_pos(j, l, c)
  for i = #j.list, 1, -1 do
    if j.list[i][1] == l then table.remove(j.list, i) end
  end
  j.list[#j.list + 1] = { l, c }
  while #j.list > JUMP_MAX do table.remove(j.list, 1) end
  j.idx = #j.list + 1
end
M.record_pos = record_pos

-- Ctrl-O: step to an older position. On the first step from the live edge, the
-- current position is recorded first (like vim), so Ctrl-I can bring you back.
local function jump_back(ed)
  local j = ed.jumps
  if #j.list == 0 then return end
  if j.idx > #j.list then
    record_pos(j, ed.cy, ed.cx)   -- save the edge; leaves idx == #list+1
    j.idx = #j.list               -- ...then step onto the just-saved entry
  end
  if j.idx <= 1 then return end   -- nothing older
  j.idx = j.idx - 1
  ed.cy, ed.cx = j.list[j.idx][1], j.list[j.idx][2]
  clamp(ed)
end

-- Ctrl-I: step back toward newer positions (only meaningful after Ctrl-O).
local function jump_fwd(ed)
  local j = ed.jumps
  if j.idx >= #j.list then return end
  j.idx = j.idx + 1
  ed.cy, ed.cx = j.list[j.idx][1], j.list[j.idx][2]
  clamp(ed)
end

-- g; / g,: walk the changelist (ed.changes, fed by keyboard edits in the driver
-- -- see editor.record_change). Unlike Ctrl-O, the live position is NOT saved:
-- the list holds only edit sites, so g; from the edge (idx == #list+1) lands on
-- the most recent change. idx is a 1-based cursor; g; steps older, g, newer, and
-- both clamp at the ends (vi beeps; we set a message). Not jump-class -- change
-- navigation doesn't feed the jumplist.
local function change_nav(ed, n, older)
  local ch = ed.changes
  if #ch.list == 0 then ed.message = "change list is empty"; return end
  local idx = (older and ch.idx - n) or (ch.idx + n)
  if idx < 1 then idx = 1; ed.message = "at start of changelist"
  elseif idx > #ch.list then idx = #ch.list; ed.message = "at end of changelist" end
  ch.idx = idx
  ed.cy, ed.cx = ch.list[idx][1], ch.list[idx][2]
  clamp(ed)
end

local function do_motion(ed, m, count)
  local oy, ox = ed.cy, ed.cx
  local tl, tc = m.move(ed, count)
  ed.cy, ed.cx = tl, tc
  clamp(ed)
  -- Record the origin in the jumplist -- but only if a jump-class motion
  -- actually moved us, so a no-op jump (mistyped [[, % off a bracket, missing
  -- mark) leaves no stray entry. Same event sets the previous-context mark
  -- (POSIX vi's ` / '), so `` and '' return to where the last jump left from --
  -- and a second `` toggles back, since this very motion (`{mark} is jump-class)
  -- reads the old value before we overwrite it. The `\`` and `'` keys index the
  -- ONE previous-context mark, so both must be set; distinct tables, never a
  -- shared reference -- the splice hook adjusts each entry in ed.marks once, and
  -- aliasing would double-shift it.
  if m.jump and (ed.cy ~= oy or ed.cx ~= ox) then
    record_pos(ed.jumps, oy, ox)
    ed.marks["`"] = { oy, ox }
    ed.marks["'"] = { oy, ox }
  end
end

-- Shift operators are always linewise, even over a charwise motion (>w shifts
-- the lines the motion spans), so they route to op_lines regardless of m.kind.
local SHIFT = { shift_r = true, shift_l = true }

local function apply_operator(ed, op, m, count, reg)
  -- The lone operator-specific region in POSIX vi: `c` over w/W stops at the end
  -- of the word instead of eating the trailing blanks (see change_word_target).
  if op == "c" and m.c_target then
    local tl, tc, inc = m.c_target(ed, count)
    op_chars_range(ed, op, ed.cy, ed.cx, tl, tc, inc, reg)
    return
  end
  local tl, tc, inc = m.move(ed, count)
  if inc == nil then inc = m.inclusive end
  if m.kind == "line" or SHIFT[op] then
    local a, c = ed.cy, tl
    if a > c then a, c = c, a end
    op_lines(ed, op, a, c, reg)
  else
    op_chars_range(ed, op, ed.cy, ed.cx, tl, tc, inc, reg)
  end
end

-- ---- scrolling (Ctrl-F/B/D/U/E/Y) -------------------------------------------
-- These invert the usual model: the WINDOW drives and the cursor follows (a
-- normal motion is the reverse). Everything is measured in SCREEN rows, so it
-- works in both wrap (line + sub-row) and nowrap (one row per line) modes. The
-- driver's refresh() won't fight us: we always leave the cursor on-screen, and
-- refresh() only re-scrolls when the cursor is off-screen.

-- Screen rows from the top of the window down to the cursor (0 = cursor on the
-- top row). Assumes the cursor is at or below the top (true whenever we scroll,
-- since the cursor is on-screen beforehand).
local function cursor_row_offset(ed)
  if not ed.opts.wrap then
    if not has_folds(ed) then return ed.cy - ed.top end
    local n, l = 0, ed.top                    -- count only visible lines between
    while l and l < ed.cy do n = n + 1; l = nextv(ed, l) end
    return n
  end
  local W, ts = ed.cols, ed.opts.tabstop
  -- A closed-fold head is a single row: its cursor sub-row is 0, not the wrapped
  -- position of ed.cx in the underlying (hidden-bodied) line.
  local csub = fold.closed_head and has_folds(ed) and fold.closed_head(ed.folds, ed.cy)
      and 0 or select(1, disp.locate(line(ed, ed.cy), W, ts, ed.cx, ed.opts.linebreak))
  local l, sub, n = ed.top, ed.topsub, 0
  while l < ed.cy or (l == ed.cy and sub < csub) do
    if sub + 1 < segs_at(ed, l, W, ts) then sub = sub + 1 else l, sub = (nextv(ed, l) or (l + 1)), 0 end
    n = n + 1
  end
  return n
end

-- Place the cursor `off` screen rows below the (already-updated) top, holding
-- the visual column.
local function place_cursor_at_offset(ed, off)
  if not ed.opts.wrap then
    if has_folds(ed) then
      ed.cy = (advance_rows(ed, ed.top, 0, off))  -- step visible rows (skip folds)
    else
      ed.cy = ed.top + off                     -- column (ed.cx) preserved
    end
  else
    local W, ts, lb = ed.cols, ed.opts.tabstop, ed.opts.linebreak
    local _, ccol = disp.locate(line(ed, ed.cy), W, ts, ed.cx, lb)
    local cl, csub = advance_rows(ed, ed.top, ed.topsub, off)
    ed.cy = cl
    ed.cx = disp.byteat(line(ed, cl), W, ts, csub, ccol, lb)
  end
  clamp(ed)
end

-- Page/half-page (Ctrl-F/B/D/U): scroll by `rows` and keep the cursor on the
-- same screen row.
local function scroll_page(ed, rows)
  local off = cursor_row_offset(ed)
  ed.top, ed.topsub = advance_rows(ed, ed.top, ed.topsub, rows)
  place_cursor_at_offset(ed, off)
end

-- Line reveal (Ctrl-E/Y): scroll by `rows` but keep the cursor on its buffer
-- line while that line stays on screen; only drag it at the window edge.
local function scroll_reveal(ed, rows)
  local off = cursor_row_offset(ed)
  local nt, ns = advance_rows(ed, ed.top, ed.topsub, rows)
  if nt == ed.top and ns == ed.topsub then return end   -- at a buffer edge
  ed.top, ed.topsub = nt, ns
  local noff = off - rows
  noff = math.max(0, math.min(noff, textrows(ed) - 1))
  place_cursor_at_offset(ed, noff)
end

-- ---- folds (z-prefix commands) ----------------------------------------------
-- All operate on ed.folds (see fold.lua); folds never touch the buffer, so none
-- of these mark ed.changed or checkpoint undo. clamp() enforces "cursor off any
-- hidden line", so closing a fold over the cursor snaps it onto the fold head.
local function fold_create(ed, a, c)          -- a closed fold over lines a..c
  if a > c then a, c = c, a end
  if c > a then ed.folds[#ed.folds + 1] = { s = a, e = c, open = false }; ed.cy = a end
  clamp(ed)
end

-- zf{motion}: fold the lines the motion spans (linewise, like an operator, so
-- zf3j / zf} / zfG all work and an inner count multiplies the z-count).
local function fold_create_motion(ed, count)
  local k = getkey(ed)
  local c2
  c2, k = read_count(ed, k)
  local m = motions[k]
  if not m then return end
  fold_create(ed, ed.cy, (m.move(ed, combine(count, c2))))
end

local function fold_open(ed)                   -- zo: reveal one level at the cursor
  local f = fold.innermost_closed(ed.folds, ed.cy)
  if f then f.open = true end
end

local function fold_close(ed)                  -- zc: close the tightest open fold here
  local best
  for _, f in ipairs(ed.folds) do
    if f.open and ed.cy >= f.s and ed.cy <= f.e and (not best or (f.e - f.s) < (best.e - best.s)) then
      best = f
    end
  end
  if best then best.open = false; clamp(ed) end
end

local function fold_toggle(ed)                 -- za: open if closed here, else close
  local closed = fold.innermost_closed(ed.folds, ed.cy)
  if closed then closed.open = true else fold_close(ed) end
end

local function fold_delete(ed)                 -- zd: remove the fold at the cursor
  local f = fold.innermost(ed.folds, ed.cy)
  if not f then return end
  for i, g in ipairs(ed.folds) do if g == f then table.remove(ed.folds, i); break end end
  clamp(ed)
end

-- ---- single-key actions -----------------------------------------------------
local function do_put(ed, after, reg)
  local r = get_reg(ed, reg)
  if not r or r.text == "" then return end
  if r.linewise then
    local lines = {}
    for ln in r.text:gmatch("(.-)\n") do lines[#lines + 1] = ln end
    local at = after and ed.cy + 1 or ed.cy
    ed.buf:insert(at, lines)
    ed.cy, ed.cx = at, 1
  else
    local s = line(ed, ed.cy)
    local at = ed.cx + ((after and #s > 0) and 1 or 0)
    local head, tail = s:sub(1, at - 1), s:sub(at)
    if not r.text:find("\n", 1, true) then
      ed.buf:set(ed.cy, head .. r.text .. tail)
      ed.cx = at + #r.text - 1
    else
      -- A multi-line charwise register (e.g. from d}/d/pat/visual across lines)
      -- splits the current line at the cursor: the register's segments open on
      -- `head` and close by re-joining `tail`. Putting the '\n' verbatim would
      -- break the "a line never contains \n" invariant (buffer.lua:no_newline).
      local segs = {}
      for seg in (r.text .. "\n"):gmatch("(.-)\n") do segs[#segs + 1] = seg end
      segs[1] = head .. segs[1]
      local lastlen = #segs[#segs]                 -- last pasted char, pre-tail
      segs[#segs] = segs[#segs] .. tail
      ed.buf:splice(ed.cy, 1, segs)
      ed.cy = ed.cy + #segs - 1
      ed.cx = math.max(1, lastlen)                 -- cursor on last char of new text
    end
  end
  ed.changed = true
  clamp(ed)
end

-- The ':' command prompt as a reusable loop, so the ':' key and the '!' filter
-- operator (which seeds it with an address range) share one implementation.
-- `seed` pre-fills the line (cursor conceptually at its end). Returns true if a
-- command was submitted (Enter), false if cancelled -- the '!' operator uses
-- that to decide whether the edit counts as a change for '.'.
local function run_prompt(ed, seed)
  ed.mode = "command"; ed.cmdline = seed or ""
  local hidx = #ed.cmdhist + 1
  local stash = nil
  while true do
    local k = getkey(ed)
    if k == 13 or k == 10 then
      local cmd = ed.cmdline
      ed.mode = "normal"; ed.cmdline = ""
      ex.record_history(ed, cmd)
      local payload, status = ex.dispatch(ed, cmd)
      if status == "err" then
        ed.message = payload:gsub("\n", " "); ed.message_hl = "Error"
      elseif payload and payload:find("\n", 1, true) and ed.suspend then
        ed.suspend(payload)                     -- multi-line output -> the terminal
      elseif payload and payload ~= "" then
        ed.message = payload:gsub("\n", " ")
      end
      return true
    elseif k == 27 or k == 3 then ed.mode = "normal"; ed.cmdline = ""; return false  -- Esc / Ctrl-C cancel
    elseif k == 127 or k == 8 then
      if #ed.cmdline == 0 then ed.mode = "normal"; return false end
      -- Erase the whole trailing char (may be multibyte), like insert mode.
      ed.cmdline = ed.cmdline:sub(1, disp.prev_char(ed.cmdline, #ed.cmdline + 1) - 1)
    elseif k == 6 then                                 -- Ctrl-F: open the command window
      -- Carry any half-typed line in as the seed, then hand off. The window
      -- gives full-editor editing for anything too fiddly for a one-line prompt.
      local carry = ed.cmdline
      ed.mode = "normal"; ed.cmdline = ""
      ex.dispatch(ed, carry == "" and "cmdwin" or ("cmdwin " .. carry))
      return false
    elseif k == 16 then                                -- Ctrl-P: older history
      if hidx > 1 then
        if hidx == #ed.cmdhist + 1 then stash = ed.cmdline end
        hidx = hidx - 1; ed.cmdline = ed.cmdhist[hidx]
      end
    elseif k == 14 then                                -- Ctrl-N: newer history
      if hidx <= #ed.cmdhist then
        hidx = hidx + 1
        ed.cmdline = (hidx > #ed.cmdhist) and (stash or "") or ed.cmdhist[hidx]
      end
    -- Printable ASCII, tab, and UTF-8 bytes (>= 128) -- the same set insert
    -- mode accepts, so :e on a non-ASCII filename or a UTF-8 :s pattern is
    -- typeable at the prompt, not only over the socket.
    elseif k == 9 or (k >= 32 and k ~= 127) then ed.cmdline = ed.cmdline .. string.char(k) end
  end
end

local actions
actions = {
  [b("x")] = function(ed, count, reg)
    local s = line(ed, ed.cy)
    if #s == 0 then return end
    local a, endb = ed.cx, ed.cx
    for _ = 1, (count or 1) do if endb <= #s then endb = disp.next_char(s, endb) end end
    set_del_reg(ed, reg, s:sub(a, endb - 1), false)
    ed.buf:set(ed.cy, s:sub(1, a - 1) .. s:sub(endb))
    ed.changed = true
    clamp(ed)
  end,
  -- X: delete `count` chars BEFORE the cursor (the backward x). Char-aware, so a
  -- multibyte char counts as one; a no-op at column 1.
  [b("X")] = function(ed, count, reg)
    local s, a = line(ed, ed.cy), ed.cx
    local start = a
    for _ = 1, (count or 1) do start = disp.prev_char(s, start) end
    if start >= a then return end
    set_del_reg(ed, reg, s:sub(start, a - 1), false)
    ed.buf:set(ed.cy, s:sub(1, start - 1) .. s:sub(a))
    ed.cx = start
    ed.changed = true
    clamp(ed)
  end,
  -- D / C: operate from the cursor to end-of-line, plus count-1 whole following
  -- lines (= d$ / c$ with the vi count semantics). Reuse the charwise range core.
  [b("D")] = function(ed, count, reg)
    local last = math.min(ed.cy + (count or 1) - 1, ed.buf:nlines())
    op_chars_range(ed, "d", ed.cy, ed.cx, last, math.max(1, #line(ed, last)), true, reg)
  end,
  [b("C")] = function(ed, count, reg)
    local last = math.min(ed.cy + (count or 1) - 1, ed.buf:nlines())
    op_chars_range(ed, "c", ed.cy, ed.cx, last, math.max(1, #line(ed, last)), true, reg)
  end,
  -- Y: yank `count` whole lines (= yy). Linewise.
  [b("Y")] = function(ed, count, reg)
    op_lines(ed, "y", ed.cy, math.min(ed.cy + (count or 1) - 1, ed.buf:nlines()), reg)
  end,
  -- s / S: substitute. s = change `count` chars (cl) but always enters insert
  -- (even on an empty line); S = change `count` whole lines (cc).
  [b("s")] = function(ed, count, reg)
    local s, a, endb = line(ed, ed.cy), ed.cx, ed.cx
    for _ = 1, (count or 1) do if endb <= #s then endb = disp.next_char(s, endb) end end
    set_del_reg(ed, reg, s:sub(a, endb - 1), false)
    ed.buf:set(ed.cy, s:sub(1, a - 1) .. s:sub(endb))
    ed.changed = true
    insert_mode(ed)
  end,
  [b("S")] = function(ed, count, reg)
    op_lines(ed, "c", ed.cy, math.min(ed.cy + (count or 1) - 1, ed.buf:nlines()), reg)
  end,
  -- J: join `count` lines (default 2) onto the current one. A single space is
  -- inserted at each join unless the left side already ends in a blank or the
  -- (leading-blank-stripped) right side starts with ')' -- the classic vi rule.
  -- The cursor lands at the first join point (after the initial line's text).
  [b("J")] = function(ed, count)
    local n = math.max(2, count or 2)
    local last = math.min(ed.cy + n - 1, ed.buf:nlines())
    if last <= ed.cy then return end
    local cur = line(ed, ed.cy)
    local joincol = math.max(1, #cur + 1)
    for _ = ed.cy + 1, last do
      local nxt = line(ed, ed.cy + 1):gsub("^%s+", "")
      local sep = (cur ~= "" and not cur:match("%s$") and nxt ~= "" and nxt:sub(1, 1) ~= ")") and " " or ""
      cur = cur .. sep .. nxt
      ed.buf:delete(ed.cy + 1, ed.cy + 1)
    end
    ed.buf:set(ed.cy, cur)
    ed.cx = math.min(joincol, math.max(1, #cur))
    ed.changed = true
    clamp(ed)
  end,
  -- ~: toggle the case of `count` chars at the cursor, advancing over them.
  -- Char-aware; only single-byte ASCII letters flip (multibyte passes through).
  [b("~")] = function(ed, count)
    local s = line(ed, ed.cy)
    if #s == 0 or ed.cx > #s then return end
    local i, parts = ed.cx, {}
    for _ = 1, (count or 1) do
      if i > #s then break end
      local j = disp.next_char(s, i)
      local ch = s:sub(i, j - 1)
      if #ch == 1 then
        if ch:match("%l") then ch = ch:upper() elseif ch:match("%u") then ch = ch:lower() end
      end
      parts[#parts + 1] = ch
      i = j
    end
    ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. table.concat(parts) .. s:sub(i))
    ed.cx = i
    ed.changed = true
    clamp(ed)
  end,
  -- Reposition the window so the current (or [count]) line sits at the top /
  -- center / bottom. Two spellings per position: the POSIX one (z<CR>/z./z-)
  -- moves the cursor to that line's first non-blank; the vim one (zt/zz/zb)
  -- leaves it in the same column. We always leave the cursor on-screen, so
  -- refresh() won't re-scroll and fight us.
  [b("z")] = function(ed, count)
    local k = getkey(ed)
    -- Fold sub-commands (vim's z-prefix set). These return early; anything else
    -- falls through to the window-positioning spellings below.
    if k == b("f") then return fold_create_motion(ed, count)
    elseif k == b("o") then return fold_open(ed)
    elseif k == b("O") then                       -- open every fold covering the cursor (all levels)
      for _, f in ipairs(ed.folds) do if ed.cy >= f.s and ed.cy <= f.e then f.open = true end end
      return
    elseif k == b("c") then return fold_close(ed)
    elseif k == b("a") then return fold_toggle(ed)
    elseif k == b("d") then return fold_delete(ed)
    elseif k == b("R") then for _, f in ipairs(ed.folds) do f.open = true end; return
    elseif k == b("M") then for _, f in ipairs(ed.folds) do f.open = false end; return clamp(ed)
    elseif k == b("E") then ed.folds = {}; return
    elseif k == b("i") then ed.opts.foldenable = not ed.opts.foldenable; return clamp(ed)  -- zi: honor folds or not
    elseif k == b("j") then                       -- to the start of the next fold
      local best
      for _, f in ipairs(ed.folds) do if f.s > ed.cy and (not best or f.s < best) then best = f.s end end
      if best then ed.cy, ed.cx = best, 1; clamp(ed) end
      return
    elseif k == b("k") then                       -- to the end of the previous fold
      local best
      for _, f in ipairs(ed.folds) do if f.e < ed.cy and (not best or f.e > best) then best = f.e end end
      if best then ed.cy, ed.cx = best, 1; clamp(ed) end
      return
    end
    local tr = ed.rows - 1
    local target = count and math.max(1, math.min(count, ed.buf:nlines())) or ed.cy
    -- How many screen rows above `target` the window top should sit: 0 (top),
    -- half a screen (center), or a full screen minus one (bottom).
    local offset, keepcol
    if k == 13 or k == 10 then offset = 0                                    -- z<CR>
    elseif k == b("t") then offset, keepcol = 0, true                        -- zt
    elseif k == b(".") then offset = math.floor(tr / 2)                      -- z.
    elseif k == b("z") then offset, keepcol = math.floor(tr / 2), true       -- zz
    elseif k == b("-") then offset = tr - 1                                  -- z-
    elseif k == b("b") then offset, keepcol = tr - 1, true                   -- zb
    else return end
    -- Measure the offset in SCREEN rows (not buffer lines) so a wrapped target
    -- -- or wrapped lines above it -- still lands centered/at bottom: walk up
    -- from the target line's first row. advance_rows honors wrap and clamps at
    -- the buffer top; in nowrap it collapses to one row per line (top = target -
    -- offset). Leaving the cursor on-screen keeps refresh() from re-scrolling.
    if ed.opts.wrap then
      ed.top, ed.topsub = advance_rows(ed, target, 0, -offset)
    else
      ed.top = math.max(1, target - offset)
      ed.topsub = 0
    end
    ed.cy = target
    if not keepcol then ed.cx = first_nonblank(line(ed, target)) end
    clamp(ed)
  end,
  -- ZZ: write (if modified) and quit; ZQ: quit without writing. Both go through
  -- ex so they mean exactly what `:x` / `:q!` do.
  [b("Z")] = function(ed)
    local k = getkey(ed)
    if k == b("Z") then
      local payload, status = ex.dispatch(ed, "x")
      if status == "err" then ed.message = payload:gsub("\n", " ") end
    elseif k == b("Q") then
      ex.dispatch(ed, "q!")
    end
  end,
  -- Ctrl-G: show file info on the message line (name, modified, position, %).
  [7] = function(ed)
    local n = ed.buf:nlines()
    local pct = (n > 0) and math.floor((ed.cy / n) * 100) or 0
    ed.message = ('"%s"%s line %d of %d --%d%%-- col %d'):format(
      ed.buf.path or "[No File]", ed.buf.modified and " [Modified]" or "", ed.cy, n, pct, ed.cx)
  end,
  [b("r")] = function(ed, count)
    local key = getkey(ed)
    if key == 27 then return end                   -- r<ESC>: cancel, no replacement
    local s, a, n = line(ed, ed.cy), ed.cx, (count or 1)
    local endb, k = a, 0
    while k < n and endb <= #s do endb = disp.next_char(s, endb); k = k + 1 end
    if k < n then return end                       -- not enough chars on the line
    if key == 13 or key == 10 then
      -- r<CR>/<NL>: split the line (POSIX). Enter in raw mode arrives as a
      -- carriage-return byte; replacing a char with a literal \r would embed an
      -- invalid byte that breaks rendering, so the only correct reading is a
      -- line break. Discard the count chars at/after the cursor, keep the prefix,
      -- and push the remainder onto a new line -- with count-1 empty lines before
      -- it. Cursor lands on the first non-blank of that new last line.
      local prefix, suffix = s:sub(1, a - 1), s:sub(endb)
      local newlines = {}
      for i = 1, n - 1 do newlines[i] = "" end
      newlines[n] = suffix
      ed.buf:set(ed.cy, prefix)
      ed.buf:insert(ed.cy + 1, newlines)
      ed.cy, ed.cx = ed.cy + n, first_nonblank(suffix)
    else
      local ch = read_char_from(ed, key)          -- whole char, multibyte included
      ed.buf:set(ed.cy, s:sub(1, a - 1) .. string.rep(ch, n) .. s:sub(endb))
      ed.cx = a + (n - 1) * #ch                    -- onto the last replaced char's start
    end
    ed.changed = true
  end,
  [b("p")] = function(ed, _, reg) do_put(ed, true, reg) end,
  [b("P")] = function(ed, _, reg) do_put(ed, false, reg) end,
  [b("m")] = function(ed) -- m{mark}: set a mark at the cursor
    local ch = string.char(getkey(ed))
    if not (ch:match("%u") and mark_event(ed, "markset", ch)) then
      ed.marks[ch] = { ed.cy, ed.cx }
    end
  end,
  [26] = function(ed) if ed.suspend_self then ed.suspend_self() end end, -- Ctrl-Z: suspend
  -- Ctrl-L: force a full redraw (classic vi). The driver clears the screen
  -- before the next frame; because this key is itself an event, it also picks up
  -- any pending terminal resize -- the manual escape hatch for the idle case.
  [12] = function(ed) ed.force_clear = true end,
  [30] = function(ed)               -- Ctrl-^: switch to the alternate buffer (:e #)
    local payload, status = ex.dispatch(ed, "b #")
    if status == "err" then ed.message = payload end
  end,
  -- Scrolling. Ctrl-F/B page (count = pages, 2-row overlap like vi); Ctrl-D/U
  -- half-page (count = the scroll size in rows); Ctrl-E/Y reveal one line
  -- (count = rows).
  [6]  = function(ed, count) scroll_page(ed,  (count or 1) * math.max(1, textrows(ed) - 2)) end, -- Ctrl-F
  [2]  = function(ed, count) scroll_page(ed, -(count or 1) * math.max(1, textrows(ed) - 2)) end, -- Ctrl-B
  [4]  = function(ed, count) scroll_page(ed,  count or math.max(1, math.floor(textrows(ed) / 2))) end, -- Ctrl-D
  [21] = function(ed, count) scroll_page(ed, -(count or math.max(1, math.floor(textrows(ed) / 2)))) end, -- Ctrl-U
  [5]  = function(ed, count) scroll_reveal(ed,  (count or 1)) end,   -- Ctrl-E
  [25] = function(ed, count) scroll_reveal(ed, -(count or 1)) end,   -- Ctrl-Y
  [15] = function(ed) jump_back(ed) end,   -- Ctrl-O: older position in the jumplist
  [9]  = function(ed) jump_fwd(ed) end,    -- Ctrl-I / Tab: newer position
  [b("u")] = function(ed)
    local l, c = ed.buf:undo()
    if l then ed.cy, ed.cx = l, c or 1; clamp(ed) else ed.message = "Already at oldest change" end
  end,
  [18] = function(ed) -- Ctrl-R: redo
    local l, c = ed.buf:redo()
    if l then ed.cy, ed.cx = l, c or 1; clamp(ed) else ed.message = "Already at newest change" end
  end,
  -- q{reg} starts recording keys into a register; q again stops. Recording
  -- reuses getkey's capture; the trailing 'q' that stops it is dropped. A macro
  -- is just register text, so a yanked register can be run as one too (like vi).
  [b("q")] = function(ed)
    if ed.recording then
      table.remove(ed.macro_buf) -- drop the trailing 'q' that triggered the stop
      local chars = {}
      for i = 1, #ed.macro_buf do chars[i] = string.char(ed.macro_buf[i]) end
      ed.regs[ed.recording] = { text = table.concat(chars), linewise = false }
      ed.recording, ed.macro_buf = nil, nil
    else
      ed.recording = string.char(getkey(ed))
      ed.macro_buf = {}
    end
  end,
  -- @{reg} replays a register's keys (count times); @@ replays the last one.
  [b("@")] = function(ed, count)
    local rc = getkey(ed)
    local reg = (rc == b("@")) and ed.last_macro or string.char(rc)
    if not reg then return end
    local r = get_reg(ed, reg)                     -- backend-aware: @+ runs the clipboard
    if not r or r.text == "" then return end
    ed.last_macro = reg
    local merged = {}
    for _ = 1, (count or 1) do
      for i = 1, #r.text do merged[#merged + 1] = r.text:byte(i) end
    end
    for i = 1, #ed.inject do merged[#merged + 1] = ed.inject[i] end
    ed.inject = merged
  end,
  [b("i")] = function(ed) insert_mode(ed) end,
  [b("R")] = function(ed) replace_mode(ed) end,
  [b("a")] = function(ed)
    if #line(ed, ed.cy) > 0 then ed.cx = ed.cx + 1 end
    insert_mode(ed)
  end,
  [b("A")] = function(ed) ed.cx = #line(ed, ed.cy) + 1; insert_mode(ed) end,
  [b("I")] = function(ed) ed.cx = first_nonblank(line(ed, ed.cy)); insert_mode(ed) end,
  -- o/O open a line below/above; with autoindent it inherits the current line's
  -- leading whitespace (trimmed by the ESC rule if you type nothing).
  [b("o")] = function(ed)
    local indent = ed.opts.autoindent and line(ed, ed.cy):match("^[ \t]*") or ""
    ed.buf:insert(ed.cy + 1, { indent }); ed.cy = ed.cy + 1; ed.cx = #indent + 1; insert_mode(ed)
  end,
  [b("O")] = function(ed)
    local indent = ed.opts.autoindent and line(ed, ed.cy):match("^[ \t]*") or ""
    ed.buf:insert(ed.cy, { indent }); ed.cx = #indent + 1; insert_mode(ed)
  end,
  -- '.' repeats the last change by replaying its recorded keys: prepend them to
  -- the funnel so they run as the next command(s). '.' itself makes no change,
  -- so it never overwrites last_change (no recursion).
  [b(".")] = function(ed)
    if not ed.last_change then return end
    local merged = {}
    for i = 1, #ed.last_change do merged[#merged + 1] = ed.last_change[i] end
    for i = 1, #ed.inject do merged[#merged + 1] = ed.inject[i] end
    ed.inject = merged
  end,
  [b(":")] = function(ed) run_prompt(ed, "") end,
}

-- ---- text objects -----------------------------------------------------------
-- A TEXT OBJECT is the operator model's missing half: a motion returns ONE
-- endpoint (the cursor is the other), but an object returns BOTH endpoints of a
-- range *around* the cursor, so `diw` works wherever in the word you sit. Each
-- entry is fn(ed, around) -> sl, sc, tl, tc, kind ("char"|"line"), or nil when
-- there is no such object at the cursor (a clean no-op: the operator is dropped,
-- crucially WITHOUT entering insert mode for `c`). `around` picks the "a"
-- variant (aw vs iw, a" vs i"). Operator-pending only -- lvi has no visual mode,
-- so a bare `iw` is simply unrecognized.

-- Maximal run of ONE character class around column cx (M.cword generalized to
-- any class). Returns i, j, class; nil on an empty line.
local function class_run(s, cx, big)
  if #s == 0 then return nil end
  cx = math.max(1, math.min(cx, #s))
  local cls = wclass(s:sub(cx, cx), big)
  local i, j = cx, cx
  while i > 1  and wclass(s:sub(i - 1, i - 1), big) == cls do i = i - 1 end
  while j < #s and wclass(s:sub(j + 1, j + 1), big) == cls do j = j + 1 end
  return i, j, cls
end

-- iw = the run under the cursor; aw adds the trailing blank run (else leading),
-- or on blanks adds the following word. Single-line by design: a word object
-- never joins lines, and the trailing-else-leading rule mirrors vi's own
-- fallback when the word ends the line -- so it matches vi in every real case
-- while never surprising you by merging two lines. Count punted.
local function obj_word(ed, around, big)
  local l, s = ed.cy, line(ed, ed.cy)
  local i, j, cls = class_run(s, ed.cx, big)
  if not i then return nil end                          -- empty line: no object
  if around then
    if cls == "blank" then                              -- aw on blanks: + next word
      local k = j
      if k < #s then
        local ncls = wclass(s:sub(k + 1, k + 1), big)
        while k < #s and wclass(s:sub(k + 1, k + 1), big) == ncls do k = k + 1 end
      end
      j = k
    else                                                -- aw on a word: trailing else leading blanks
      local k = j
      while k < #s and wclass(s:sub(k + 1, k + 1), big) == "blank" do k = k + 1 end
      if k > j then j = k
      else while i > 1 and wclass(s:sub(i - 1, i - 1), big) == "blank" do i = i - 1 end end
    end
  end
  return l, i, l, j, "char"
end

-- Innermost `o`..`c` pair enclosing the cursor -> ol, oc, cl, cc, or nil. Scans
-- backward for the opener (balancing nested pairs), then forward for its mate. A
-- bracket the cursor sits ON counts as enclosing (so di( works with the cursor
-- on either paren) -- hence the guard that skips the char under the cursor when
-- it is the closer, so we hunt outward for the opener rather than balance it.
local function enclosing_pair(ed, o, c)
  local N = ed.buf:nlines()
  local l, col, depth = ed.cy, ed.cx, 0
  local ol, oc
  while l >= 1 do
    local s = line(ed, l)
    while col >= 1 do
      local d = s:sub(col, col)
      if d == c and not (l == ed.cy and col == ed.cx) then depth = depth + 1
      elseif d == o then
        if depth == 0 then ol, oc = l, col; break end
        depth = depth - 1
      end
      col = col - 1
    end
    if ol then break end
    l = l - 1; if l >= 1 then col = #line(ed, l) end
  end
  if not ol then return nil end
  l, col, depth = ol, oc + 1, 0
  while l <= N do
    local s = line(ed, l)
    while col <= #s do
      local d = s:sub(col, col)
      if d == o then depth = depth + 1
      elseif d == c then
        if depth == 0 then return ol, oc, l, col end
        depth = depth - 1
      end
      col = col + 1
    end
    l = l + 1; col = 1
  end
  return nil                                            -- unbalanced: no object
end

-- i( = strictly inside the pair; a( = the brackets included. A bracket pair
-- alone on its own lines is NOT promoted to linewise (i.e. di( leaves the
-- brackets touching) -- the same simplification match_bracket already takes
-- (see its note on skipping POSIX's whole-line-spanning rule).
local function obj_pair(ed, around, o, c)
  local ol, oc, cl, cc = enclosing_pair(ed, o, c)
  if not ol then return nil end
  if around then return ol, oc, cl, cc, "char" end
  return ol, oc + 1, cl, cc - 1, "char"                 -- inner: strip the delimiters
end

-- Quote objects are single-line -- exactly like vi's i"/a", which also fail off
-- the line. Quotes pair left-to-right; the object is the pair containing the
-- cursor, else the next pair to its right (so ci" before a string still works).
-- a" extends over trailing blanks (else leading), like aw. No escape awareness
-- (a deliberately vi-simple heuristic, not a lexer).
local function obj_quote(ed, around, q)
  local l, s = ed.cy, line(ed, ed.cy)
  local pos = {}
  for i = 1, #s do if s:sub(i, i) == q then pos[#pos + 1] = i end end
  local op, cl
  for k = 1, #pos - 1, 2 do
    if ed.cx <= pos[k + 1] then op, cl = pos[k], pos[k + 1]; break end
  end
  if not op then return nil end
  if around then
    local j = cl
    while j < #s and s:sub(j + 1, j + 1):match("%s") do j = j + 1 end
    if j > cl then cl = j
    else while op > 1 and s:sub(op - 1, op - 1):match("%s") do op = op - 1 end end
    return l, op, l, cl, "char"
  end
  return l, op + 1, l, cl - 1, "char"                   -- inner: between the quotes
end

-- ip = the block of like-emptiness lines around the cursor (all non-blank, or
-- all blank); ap adds the adjacent run of the opposite kind (trailing else
-- leading). Linewise.
local function obj_para(ed, around)
  local N = ed.buf:nlines()
  local blank = line(ed, ed.cy) == ""
  local a, z = ed.cy, ed.cy
  while a > 1 and (line(ed, a - 1) == "") == blank do a = a - 1 end
  while z < N and (line(ed, z + 1) == "") == blank do z = z + 1 end
  if around then
    local z0 = z
    while z < N and (line(ed, z + 1) == "") ~= blank do z = z + 1 end
    if z == z0 then
      while a > 1 and (line(ed, a - 1) == "") ~= blank do a = a - 1 end
    end
  end
  return a, 1, z, 1, "line"
end

-- The object registry, keyed by the char after i/a. Aliases follow vi: b/B for
-- ()/{} blocks, and open/close bracket both select their pair.
local textobjs = {
  [b("w")] = function(ed, a) return obj_word(ed, a, false) end,
  [b("W")] = function(ed, a) return obj_word(ed, a, true) end,
  [b("p")] = function(ed, a) return obj_para(ed, a) end,
  [b("(")] = function(ed, a) return obj_pair(ed, a, "(", ")") end,
  [b(")")] = function(ed, a) return obj_pair(ed, a, "(", ")") end,
  [b("b")] = function(ed, a) return obj_pair(ed, a, "(", ")") end,
  [b("{")] = function(ed, a) return obj_pair(ed, a, "{", "}") end,
  [b("}")] = function(ed, a) return obj_pair(ed, a, "{", "}") end,
  [b("B")] = function(ed, a) return obj_pair(ed, a, "{", "}") end,
  [b("[")] = function(ed, a) return obj_pair(ed, a, "[", "]") end,
  [b("]")] = function(ed, a) return obj_pair(ed, a, "[", "]") end,
  [b("<")] = function(ed, a) return obj_pair(ed, a, "<", ">") end,
  [b(">")] = function(ed, a) return obj_pair(ed, a, "<", ">") end,
  [b('"')] = function(ed, a) return obj_quote(ed, a, '"') end,
  [b("'")] = function(ed, a) return obj_quote(ed, a, "'") end,
  [b("`")] = function(ed, a) return obj_quote(ed, a, "`") end,
}

-- Apply an operator over a text object. nil object -> clean no-op. Shift is
-- always linewise (like apply_operator). An empty inner range (adjacent
-- delimiters, e.g. ci( on "()") is the one special case: `c` opens insert
-- between them; d/y do nothing -- matching vi, and NOT leaking into insert.
local function apply_textobj(ed, op, obj, around, reg)
  local sl, sc, tl, tc, kind = obj(ed, around)
  if not sl then return end
  if kind == "line" or SHIFT[op] then
    op_lines(ed, op, sl, tl, reg)
  elseif tl < sl or (tl == sl and tc < sc) then
    if op == "c" then ed.cy, ed.cx = sl, sc; clamp(ed); insert_mode(ed) end
  else
    op_chars_range(ed, op, sl, sc, tl, tc, true, reg)
  end
end

-- ---- g-operators and the ! filter -------------------------------------------
-- These take a following motion / text object like d/c/y do, but resolve it to
-- a range with read_gtarget rather than the operators table, because their
-- action isn't a splice: gu/gU/g~ rewrite the span, gq and ! route the lines
-- through an external command (the UNIX-as-IDE filter -- ! prompts for the
-- command, gq uses $LVI_FMT or fmt(1)). All share :{a},{c}!cmd, which lvi
-- delegates to the system ex.

local GCASE = { [b("u")] = "lower", [b("U")] = "upper", [b("~")] = "toggle" }

-- Read the motion / text object / doubled key following a g-operator or ! and
-- return sl,sc,tl,tc,kind ("char"/"line"),inclusive. `opkey` is the operator's
-- own key: a doubled press (guu, gqq, !!) means the current line(s) + count.
local function read_gtarget(ed, opkey, total)
  local k = getkey(ed)
  local c2; c2, k = read_count(ed, k)
  total = combine(total, c2)
  if k == opkey then
    return ed.cy, 1, math.min(ed.cy + (total or 1) - 1, ed.buf:nlines()), 1, "line", true
  end
  if k == b("i") or k == b("a") then
    local key = getkey(ed)
    local obj = textobjs[key]
    if not obj and ed.textobj_cmds[key] then
      local cmd = ed.textobj_cmds[key]
      obj = function(e, a) return ex.textobj_range(e, cmd, a, key) end
    end
    if not obj then return nil end
    local sl, sc, tl, tc, kind = obj(ed, k == b("a"))
    if not sl then return nil end
    return sl, sc, tl, tc, kind or "char", true
  end
  local m = motions[k]
  if not m then return nil end
  local tl, tc, inc = m.move(ed, total)
  if inc == nil then inc = m.inclusive end
  if m.kind == "line" then return ed.cy, 1, tl, 1, "line", true end
  return ed.cy, ed.cx, tl, tc, "char", inc and true or false
end

local function apply_gcase(ed, opkey, total)
  local mode = GCASE[opkey]
  local sl, sc, tl, tc, kind, inc = read_gtarget(ed, opkey, total)
  if not sl then return end
  if kind == "line" then op_chars_range(ed, mode, sl, 1, tl, math.max(1, #line(ed, tl)), true, nil)
  else op_chars_range(ed, mode, sl, sc, tl, tc, inc, nil) end
end

-- Filter the target's line span through an external command. `interactive`
-- (the ! operator) seeds the : prompt with the range so you type the command;
-- otherwise (gq) run the `fmtprg` option directly. changed=true so `.` repeats it.
local function apply_lines_filter(ed, opkey, total, interactive)
  local sl, _, tl = read_gtarget(ed, opkey, total)
  if not sl then return end
  local a, c = math.min(sl, tl), math.max(sl, tl)
  if interactive then
    if run_prompt(ed, ("%d,%d!"):format(a, c)) then ed.changed = true end
  else
    local _, st = ex.dispatch(ed, ("%d,%d!%s"):format(a, c, ed.opts.fmtprg))
    if st ~= "err" then ed.changed = true end
  end
end

-- g@{motion}: hand the motion's span to the external `operatorfunc` command,
-- spawned detached like `:[range]bg` (the same mechanism, driven from a motion
-- instead of an ex address). This is the non-mutating/async-mutating sibling of
-- `!`/gq: those pipe the LINES through a filter synchronously and splice stdout
-- back; g@ exports the span as env ($LVI_LINE1/2, plus $LVI_COL1/2 and $LVI_KIND
-- for a charwise motion) and lets the tool act over the socket -- so it reaches
-- part of a line, and plugs into the :hl / hooks substrate. g@@ (doubled) is the
-- current line(s) + count, matching guu/gqq/!!. `.` repeats it (changed=true).
local function apply_opfunc(ed, total)
  local cmd = ed.opts.operatorfunc
  if not cmd or cmd == "" then return end        -- unarmed: a clean no-op
  if not ed.spawn_bg then return end
  local sl, sc, tl, tc, kind, inc = read_gtarget(ed, b("@"), total)
  if not sl then return end                      -- no such target: clean no-op
  if kind == "line" then
    ed.spawn_bg(cmd, nil, math.min(sl, tl), math.max(sl, tl), nil, nil, "line")
    ed.changed = true
    return
  end
  -- Deliver an inclusive low..high char span in byte columns -- the same contract
  -- :textobj returns (char L1 C1 L2 C2, both ends inclusive). Order the cursor and
  -- target, then, for an exclusive motion, drop the high end (step back a column,
  -- crossing to the prior line's end if it falls off the start). A text object has
  -- no inc flag (nil) and is inclusive like d/c/y's apply_textobj; a motion always
  -- carries an explicit true/false.
  if inc == nil then inc = true end
  local l1, c1, l2, c2 = sl, sc, tl, tc
  if l1 > l2 or (l1 == l2 and c1 > c2) then l1, c1, l2, c2 = tl, tc, sl, sc end
  if not inc then
    c2 = c2 - 1
    if c2 < 1 and l2 > l1 then l2 = l2 - 1; c2 = math.max(1, #line(ed, l2)) end
  end
  ed.spawn_bg(cmd, nil, l1, l2, c1, c2, "char")
  ed.changed = true
end

local operators = { [b("d")] = "d", [b("c")] = "c", [b("y")] = "y",
                    [b(">")] = "shift_r", [b("<")] = "shift_l" }

-- ---- the command loop -------------------------------------------------------
local function command(ed)
  ed.buf:undo_checkpoint() -- one undo reverts one user-level command
  ed.keylog = {}
  ed.changed = false
  local reg
  -- Between commands is the one parked state where the interpreter has no
  -- half-consumed grammar: a socket command may safely inject keys or close an
  -- undo group here. Every other park (awaiting an operator's motion, insert
  -- mode, a prompt) is mid-command, and the driver defers socket keys until we
  -- are back (editor.lua's flush_deferred).
  ed.at_boundary = true
  local k = first_key(ed)                    -- parks here; prior message stays visible
  ed.at_boundary = false
  ed.message = nil; ed.message_hl = nil      -- clear only once a new command's key arrives
  if k == b('"') then reg = string.char(getkey(ed)); k = getkey(ed) end
  local count1
  count1, k = read_count(ed, k)
  local op = operators[k]
  if op then
    local k2 = getkey(ed)
    local count2
    count2, k2 = read_count(ed, k2)
    local total = combine(count1, count2)
    if k2 == b("i") or k2 == b("a") then       -- text object: di( ci" yap ...
      local key = getkey(ed)
      local obj = textobjs[key]
      if not obj and ed.textobj_cmds[key] then -- custom object via :textobj (synchronous filter)
        local cmd = ed.textobj_cmds[key]
        obj = function(e, a) return ex.textobj_range(e, cmd, a, key) end
      end
      if obj then apply_textobj(ed, op, obj, k2 == b("a"), reg) end
    elseif k2 == k then -- dd / yy / cc
      op_lines(ed, op, ed.cy, ed.cy + (total or 1) - 1, reg)
    else
      local m = motions[k2]
      if m then apply_operator(ed, op, m, total, reg) end
    end
  elseif k == b("!") then                      -- filter lines through a command (prompts)
    apply_lines_filter(ed, b("!"), count1, true)
  elseif k == b("g") then                       -- g-namespace: gg/gj/gk motions, gu/gU/g~/gq operators
    local k2 = getkey(ed)
    if GCASE[k2] then apply_gcase(ed, k2, count1)
    elseif k2 == b("q") then apply_lines_filter(ed, b("q"), count1, false)
    elseif k2 == b("@") then apply_opfunc(ed, count1)
    elseif k2 == b(";") then change_nav(ed, count1 or 1, true)   -- g;: older change
    elseif k2 == b(",") then change_nav(ed, count1 or 1, false)  -- g,: newer change
    else do_motion(ed, { kind = "line", move = function(e, c) return g_motion_move(e, k2, c) end }, count1) end
  elseif motions[k] then
    do_motion(ed, motions[k], count1)
  elseif actions[k] then
    actions[k](ed, count1, reg)
  end
end

-- The coroutine body: parse commands forever. Quit is the driver noticing
-- ed.running == false; this loop never has to return.
function M.loop(ed)
  while true do
    command(ed)
    if ed.changed then
      ed.last_change = {}
      for i = 1, #ed.keylog do ed.last_change[i] = ed.keylog[i] end
    end
  end
end

return M
