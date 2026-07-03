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

local M = {}

local b = string.byte

-- ---- key input --------------------------------------------------------------
-- Pull the next raw key without logging: from the map-output queue first (so
-- map expansions are never re-mapped -> non-recursive), else the input funnel.
local function getkey_raw(ed)
  if ed.pending and #ed.pending > 0 then return table.remove(ed.pending, 1) end
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
  if ed.pending and #ed.pending > 0 then return getkey(ed) end -- RHS: raw, logged
  local k = getkey_raw(ed)
  if not ed.maps or not starts_map(ed, string.char(k)) then return logkey(ed, k) end
  local seq = string.char(k)
  while not ed.maps[seq] and starts_map(ed, seq) do
    seq = seq .. string.char(getkey_raw(ed))
  end
  if ed.maps[seq] then
    ed.pending = ed.pending or {}
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

local function clamp(ed)
  local nl = ed.buf:nlines()
  ed.cy = math.max(1, math.min(ed.cy, nl))
  local s = line(ed, ed.cy)
  local maxc = (ed.mode == "insert") and (#s + 1) or disp.last_char(s) -- char-aware cap
  ed.cx = math.max(1, math.min(ed.cx, maxc))
end

local function char_class(c)
  if not c or c == "" then return "none" end
  if c:match("%s") then return "blank" end
  local b = c:byte(1)
  if (b and b >= 128) or c:match("[%w_]") then return "word" end -- multibyte = word
  return "punct"
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
local function set_reg(ed, name, text, linewise)
  local r = { text = text, linewise = linewise }
  if name then ed.regs[name] = r end
  ed.regs['"'] = r
end
local function get_reg(ed, name) return ed.regs[name or '"'] end

-- ---- insert mode (also a coroutine loop) ------------------------------------
local function insert_char(ed, byte_)
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. string.char(byte_) .. s:sub(ed.cx))
  ed.cx = ed.cx + 1
end

local function split_line(ed) -- <CR> in insert mode
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(1, ed.cx - 1))
  ed.buf:insert(ed.cy + 1, { s:sub(ed.cx) })
  ed.cy = ed.cy + 1
  ed.cx = 1
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
    if k == 27 then break                              -- ESC
    elseif k == 13 or k == 10 then split_line(ed)      -- CR
    elseif k == 127 or k == 8 then backspace(ed)       -- Backspace / Ctrl-H
    elseif k == 23 then kill_word(ed)                  -- Ctrl-W: erase word (POSIX vi)
    elseif k == 21 then kill_to_bol(ed)                -- Ctrl-U: erase to line start
    -- Ctrl-A / Ctrl-E move to line ends. Not POSIX vi (readline muscle memory);
    -- vi's answer is <Esc> then I / A. Included by request.
    elseif k == 1 then ed.cx = 1                       -- Ctrl-A: start of line
    elseif k == 5 then ed.cx = #line(ed, ed.cy) + 1    -- Ctrl-E: end of line
    elseif k == 9 or (k >= 32 and k ~= 127) then insert_char(ed, k) -- printable + UTF-8 bytes
    end
    clamp(ed)
  end
  ed.mode = "normal"
  ed.message = nil
  ed.cx = math.max(1, ed.cx - 1) -- vi steps left on leaving insert
  clamp(ed)
end

-- R: overwrite mode. Reuses insert's cursor semantics (mode == "insert" lets the
-- cursor sit at #s+1 so typing past EOL extends the line). Each printable key
-- replaces the char under the cursor (or appends at/after EOL); <CR> splits like
-- insert; backspace just moves left (no original-char restore -- retype to fix).
-- Overwrite is byte-oriented, matching the rest of lvi's minimal input handling:
-- ASCII is exact; a typed multibyte char is not specially reassembled.
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
      local s = line(ed, ed.cy)
      if ed.cx > #s then insert_char(ed, k)            -- past EOL: extend
      else
        local nc = disp.next_char(s, ed.cx)
        ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. string.char(k) .. s:sub(nc))
        ed.cx = ed.cx + 1
      end
    end
    clamp(ed)
  end
  ed.mode = "normal"
  ed.message = nil
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
    local sw = (ed.opts and ed.opts.shiftwidth) or 8
    local ts = (ed.opts and ed.opts.tabstop) or 8
    local et = ed.opts and ed.opts.expandtab
    local delta = (op == "shift_r" and 1 or -1) * sw
    local out = {}
    for i = a, c do out[#out + 1] = reindent(line(ed, i), delta, et, ts) end
    ed.buf:splice(a, c - a + 1, out)                    -- one splice = one undo
    ed.cy = a; ed.cx = first_nonblank(line(ed, a)); ed.changed = true
    clamp(ed)
    return
  end
  local text = table.concat(ed.buf:get(a, c), "\n") .. "\n" -- linewise regs end in \n
  set_reg(ed, reg, text, true)
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

-- Charwise operator over a (possibly multi-line) range from (sl,sc) to (tl,tc).
-- `inclusive` keeps the char at the far end; exclusive drops it (stepping back a
-- line if that lands before column 1 -- which is what makes `dw` on the last
-- word of a line stop at the newline instead of joining, matching vi).
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
  set_reg(ed, reg, text, false)
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
local function word_forward(ed, count)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    local s = line(ed, l)
    if #s > 0 and c <= #s and char_class(s:sub(c, c)) ~= "blank" then
      local cls = char_class(s:sub(c, c))
      while c <= #s and char_class(s:sub(c, c)) == cls do c = c + 1 end
    end
    while true do
      s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
        if #line(ed, l) == 0 then return end -- empty line is a word stop
      elseif char_class(s:sub(c, c)) == "blank" then c = c + 1
      else return end
    end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.min(c, math.max(1, #line(ed, l)))
end

local function word_back(ed, count)
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
        if char_class(s:sub(c, c)) == "blank" then c = c - 1 else break end
      end
    end
    local s = line(ed, l)
    local cls = char_class(s:sub(c, c))
    while c > 1 and char_class(s:sub(c - 1, c - 1)) == cls do c = c - 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

local function word_end(ed, count)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    c = c + 1
    while true do
      local s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
      elseif char_class(s:sub(c, c)) == "blank" then c = c + 1
      else break end
    end
    local s = line(ed, l)
    local cls = char_class(s:sub(c, c))
    while c < #s and char_class(s:sub(c + 1, c + 1)) == cls do c = c + 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

-- f/t/F/T within-line char search, shared by the motions and by ;/,. Returns the
-- target column, or nil if not found.
local function do_find(ed, kind, ch, count)
  local s, c = line(ed, ed.cy), ed.cx
  for _ = 1, (count or 1) do
    if kind == "f" then
      local i = s:find(ch, c + 1, true); if not i then return nil end; c = i
    elseif kind == "t" then
      local from = (s:sub(c + 1, c + 1) == ch) and c + 2 or c + 1
      local i = s:find(ch, from, true); if not i then return nil end; c = i - 1
    elseif kind == "F" then
      local i; for j = c - 1, 1, -1 do if s:sub(j, j) == ch then i = j; break end end
      if not i then return nil end; c = i
    elseif kind == "T" then
      local from = (s:sub(c - 1, c - 1) == ch) and c - 2 or c - 1
      local i; for j = from, 1, -1 do if s:sub(j, j) == ch then i = j; break end end
      if not i then return nil end; c = i + 1
    end
  end
  return c
end

-- f/t are forward+inclusive; F/T are backward (exclusive of the origin in our
-- range model). Each records ed.last_find so ;/, can repeat it.
local function find_motion(kind, inclusive)
  return { kind = "char", inclusive = inclusive, move = function(ed, count)
    ed.last_find = { kind = kind, char = string.char(getkey(ed)) }
    local c = do_find(ed, kind, ed.last_find.char, count)
    return ed.cy, c or ed.cx
  end }
end

local flip = { f = "F", F = "f", t = "T", T = "t" }

-- Paragraph ({ }) and section ([[ ]]) motions. Pragmatic subset of POSIX: a
-- SECTION boundary is a line starting with '{' or <form-feed>, or the first/last
-- line; a PARAGRAPH boundary is a section boundary or an empty line. We skip the
-- nroff `sections`/`paragraphs` macro options (lvi has none) and POSIX's rule
-- that switches these between line/char mode as operator targets -- they are
-- plain charwise-exclusive motions landing on the boundary line's first column
-- (the common vim behavior; see MANPAGE-vi.txt "section/paragraph boundary").
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
  [b("w")] = { kind = "char", move = word_forward },
  [b("b")] = { kind = "char", move = word_back },
  [b("e")] = { kind = "char", inclusive = true, move = word_end },
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
  [b("g")] = { kind = "line", move = function(ed, count) -- gg / gj / gk
    local k2 = getkey(ed)
    if k2 == b("g") then
      local t = math.max(1, math.min(count or 1, ed.buf:nlines()))
      return t, first_nonblank(line(ed, t))
    end
    if k2 ~= b("j") and k2 ~= b("k") then return ed.cy, ed.cx end
    local down, n = (k2 == b("j")), (count or 1)
    if not (ed.opts and ed.opts.wrap) then           -- no wrapping: gj == j
      return ed.cy + (down and n or -n), ed.cx
    end
    -- Move by screen (display) rows, holding the current visual column.
    local W, ts = ed.cols or 80, ed.opts.tabstop or 8
    local N, l = ed.buf:nlines(), ed.cy
    local sub, ccol = disp.locate(line(ed, l), W, ts, ed.cx)
    for _ = 1, n do
      if down then
        if sub + 1 < disp.nsegs(line(ed, l), W, ts) then sub = sub + 1
        elseif l < N then l, sub = l + 1, 0 else break end
      else
        if sub > 0 then sub = sub - 1
        elseif l > 1 then l = l - 1; sub = disp.nsegs(line(ed, l), W, ts) - 1
        else break end
      end
    end
    return l, disp.byteat(line(ed, l), W, ts, sub, ccol)
  end },
  [96] = { kind = "char", move = function(ed) -- `{mark}: exact position
    local m = ed.marks and ed.marks[string.char(getkey(ed))]
    if not m then return ed.cy, ed.cx end
    return m[1], m[2]
  end },
  [39] = { kind = "line", move = function(ed) -- '{mark}: mark's line
    local m = ed.marks and ed.marks[string.char(getkey(ed))]
    if not m then return ed.cy, ed.cx end
    local l = math.max(1, math.min(m[1], ed.buf:nlines()))
    return l, first_nonblank(line(ed, l))
  end },
  [124] = { kind = "char", move = function(ed, count) -- N| : goto display column N
    local ts = (ed.opts and ed.opts.tabstop) or 8
    return ed.cy, disp.byte_at_dispcol(line(ed, ed.cy), ts, (count or 1) - 1)
  end },
  [b("j")] = { kind = "line", move = function(ed, n) return ed.cy + (n or 1), ed.cx end },
  [b("k")] = { kind = "line", move = function(ed, n) return ed.cy - (n or 1), ed.cx end },
  [b("G")] = { kind = "line", move = function(ed, n)
    local t = n or ed.buf:nlines()
    t = math.max(1, math.min(t, ed.buf:nlines()))
    return t, first_nonblank(line(ed, t))
  end },
  -- H/M/L: top/middle/bottom of the screen (linewise, so they compose with
  -- operators). Measured in buffer lines from ed.top -- exact in nowrap (the
  -- render reality); in wrap they approximate by line rather than screen row.
  [b("H")] = { kind = "line", move = function(ed, n)
    local l = math.min((ed.top or 1) + (n or 1) - 1, ed.buf:nlines())
    return l, first_nonblank(line(ed, l))
  end },
  [b("L")] = { kind = "line", move = function(ed, n)
    local bottom = math.min((ed.top or 1) + (ed.rows or 24) - 2, ed.buf:nlines())
    local l = math.max(ed.top or 1, bottom - (n or 1) + 1)
    return l, first_nonblank(line(ed, l))
  end },
  [b("M")] = { kind = "line", move = function(ed)
    local top = ed.top or 1
    local bottom = math.min(top + (ed.rows or 24) - 2, ed.buf:nlines())
    local l = math.floor((top + bottom) / 2)
    return l, first_nonblank(line(ed, l))
  end },
  -- Paragraph / section motions (charwise-exclusive; land on the boundary's
  -- first column). [[ / ]] read their doubled key like g does gg.
  [b("}")] = { kind = "char", move = function(ed, count) return para_target(ed, count, true, false), 1 end },
  [b("{")] = { kind = "char", move = function(ed, count) return para_target(ed, count, false, false), 1 end },
  [b("]")] = { kind = "char", move = function(ed, count)
    if getkey(ed) ~= b("]") then return ed.cy, ed.cx end
    return para_target(ed, count, true, true), 1
  end },
  [b("[")] = { kind = "char", move = function(ed, count)
    if getkey(ed) ~= b("[") then return ed.cy, ed.cx end
    return para_target(ed, count, false, true), 1
  end },
}

local function do_motion(ed, m, count)
  local tl, tc = m.move(ed, count)
  ed.cy, ed.cx = tl, tc
  clamp(ed)
end

-- Shift operators are always linewise, even over a charwise motion (>w shifts
-- the lines the motion spans), so they route to op_lines regardless of m.kind.
local SHIFT = { shift_r = true, shift_l = true }

local function apply_operator(ed, op, m, count, reg)
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
local function textrows(ed) return (ed.rows or 24) - 1 end

-- Move a screen position (line l, sub-row sub) by `rows` screen rows (negative =
-- up), honoring wrap, clamped to the buffer. In nowrap each line is one row.
local function advance_rows(ed, l, sub, rows)
  local N = ed.buf:nlines()
  if not (ed.opts and ed.opts.wrap) then
    return math.max(1, math.min(l + rows, N)), 0
  end
  local W, ts = ed.cols or 80, (ed.opts and ed.opts.tabstop) or 8
  if rows > 0 then
    for _ = 1, rows do
      if sub + 1 < disp.nsegs(line(ed, l), W, ts) then sub = sub + 1
      elseif l < N then l, sub = l + 1, 0 else break end
    end
  else
    for _ = 1, -rows do
      if sub > 0 then sub = sub - 1
      elseif l > 1 then l = l - 1; sub = disp.nsegs(line(ed, l), W, ts) - 1
      else break end
    end
  end
  return l, sub
end

-- Screen rows from the top of the window down to the cursor (0 = cursor on the
-- top row). Assumes the cursor is at or below the top (true whenever we scroll,
-- since the cursor is on-screen beforehand).
local function cursor_row_offset(ed)
  if not (ed.opts and ed.opts.wrap) then return ed.cy - (ed.top or 1) end
  local W, ts = ed.cols or 80, (ed.opts and ed.opts.tabstop) or 8
  local csub = select(1, disp.locate(line(ed, ed.cy), W, ts, ed.cx))
  local l, sub, n = ed.top or 1, ed.topsub or 0, 0
  while l < ed.cy or (l == ed.cy and sub < csub) do
    if sub + 1 < disp.nsegs(line(ed, l), W, ts) then sub = sub + 1 else l, sub = l + 1, 0 end
    n = n + 1
  end
  return n
end

-- Place the cursor `off` screen rows below the (already-updated) top, holding
-- the visual column.
local function place_cursor_at_offset(ed, off)
  if not (ed.opts and ed.opts.wrap) then
    ed.cy = (ed.top or 1) + off                       -- column (ed.cx) preserved
  else
    local W, ts = ed.cols or 80, (ed.opts and ed.opts.tabstop) or 8
    local _, ccol = disp.locate(line(ed, ed.cy), W, ts, ed.cx)
    local cl, csub = advance_rows(ed, ed.top or 1, ed.topsub or 0, off)
    ed.cy = cl
    ed.cx = disp.byteat(line(ed, cl), W, ts, csub, ccol)
  end
  clamp(ed)
end

-- Page/half-page (Ctrl-F/B/D/U): scroll by `rows` and keep the cursor on the
-- same screen row.
local function scroll_page(ed, rows)
  local off = cursor_row_offset(ed)
  ed.top, ed.topsub = advance_rows(ed, ed.top or 1, ed.topsub or 0, rows)
  place_cursor_at_offset(ed, off)
end

-- Line reveal (Ctrl-E/Y): scroll by `rows` but keep the cursor on its buffer
-- line while that line stays on screen; only drag it at the window edge.
local function scroll_reveal(ed, rows)
  local off = cursor_row_offset(ed)
  local nt, ns = advance_rows(ed, ed.top or 1, ed.topsub or 0, rows)
  if nt == (ed.top or 1) and ns == (ed.topsub or 0) then return end   -- at a buffer edge
  ed.top, ed.topsub = nt, ns
  local noff = off - rows
  noff = math.max(0, math.min(noff, textrows(ed) - 1))
  place_cursor_at_offset(ed, noff)
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
    ed.buf:set(ed.cy, s:sub(1, at - 1) .. r.text .. s:sub(at))
    ed.cx = at + #r.text - 1
  end
  ed.changed = true
  clamp(ed)
end

local actions
actions = {
  [b("x")] = function(ed, count, reg)
    local s = line(ed, ed.cy)
    if #s == 0 then return end
    local a, endb = ed.cx, ed.cx
    for _ = 1, (count or 1) do if endb <= #s then endb = disp.next_char(s, endb) end end
    set_reg(ed, reg, s:sub(a, endb - 1), false)
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
    set_reg(ed, reg, s:sub(start, a - 1), false)
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
    set_reg(ed, reg, s:sub(a, endb - 1), false)
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
  -- z{CR|.|-}: reposition the window so the current (or [count]) line sits at the
  -- top / center / bottom. Cursor moves to that line's first non-blank. We always
  -- leave the cursor on-screen, so refresh() won't re-scroll and fight us.
  [b("z")] = function(ed, count)
    local k = getkey(ed)
    local tr = (ed.rows or 24) - 1
    local target = count and math.max(1, math.min(count, ed.buf:nlines())) or ed.cy
    local top
    if k == 13 or k == 10 then top = target
    elseif k == b(".") then top = target - math.floor(tr / 2)
    elseif k == b("-") then top = target - (tr - 1)
    else return end
    ed.top = math.max(1, math.min(top, ed.buf:nlines()))
    ed.topsub = 0
    ed.cy, ed.cx = target, first_nonblank(line(ed, target))
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
      ed.buf:set(ed.cy, s:sub(1, a - 1) .. string.rep(string.char(key), n) .. s:sub(endb))
      ed.cx = a + n - 1
    end
    ed.changed = true
  end,
  [b("p")] = function(ed, _, reg) do_put(ed, true, reg) end,
  [b("P")] = function(ed, _, reg) do_put(ed, false, reg) end,
  [b("m")] = function(ed) -- m{mark}: set a mark at the cursor
    ed.marks = ed.marks or {}
    ed.marks[string.char(getkey(ed))] = { ed.cy, ed.cx }
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
  [b("u")] = function(ed)
    local l = ed.buf:undo()
    if l then ed.cy, ed.cx = l, 1; clamp(ed) else ed.message = "Already at oldest change" end
  end,
  [18] = function(ed) -- Ctrl-R: redo
    local l = ed.buf:redo()
    if l then ed.cy, ed.cx = l, 1; clamp(ed) else ed.message = "Already at newest change" end
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
    local r = ed.regs[reg]
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
  [b("o")] = function(ed) ed.buf:insert(ed.cy + 1, { "" }); ed.cy = ed.cy + 1; ed.cx = 1; insert_mode(ed) end,
  [b("O")] = function(ed) ed.buf:insert(ed.cy, { "" }); ed.cx = 1; insert_mode(ed) end,
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
  [b(":")] = function(ed)
    ed.mode = "command"; ed.cmdline = ""
    while true do
      local k = getkey(ed)
      if k == 13 or k == 10 then
        local cmd = ed.cmdline
        ed.mode = "normal"; ed.cmdline = ""
        local payload, status = ex.dispatch(ed, cmd)
        if status == "err" then
          ed.message = payload:gsub("\n", " ")
        elseif payload and payload:find("\n", 1, true) and ed.suspend then
          ed.suspend(payload)                     -- multi-line output -> the terminal
        elseif payload and payload ~= "" then
          ed.message = payload:gsub("\n", " ")
        end
        return
      elseif k == 27 then ed.mode = "normal"; ed.cmdline = ""; return
      elseif k == 127 or k == 8 then
        if #ed.cmdline == 0 then ed.mode = "normal"; return end
        ed.cmdline = ed.cmdline:sub(1, -2)
      elseif k >= 32 and k < 127 then ed.cmdline = ed.cmdline .. string.char(k) end
    end
  end,
}

local operators = { [b("d")] = "d", [b("c")] = "c", [b("y")] = "y",
                    [b(">")] = "shift_r", [b("<")] = "shift_l" }

-- ---- the command loop -------------------------------------------------------
local function command(ed)
  ed.buf:undo_checkpoint() -- one undo reverts one user-level command
  ed.keylog = {}
  ed.changed = false
  local reg
  local k = first_key(ed)                    -- parks here; prior message stays visible
  ed.message = nil                           -- clear only once a new command's key arrives
  if k == b('"') then reg = string.char(getkey(ed)); k = getkey(ed) end
  local count1
  count1, k = read_count(ed, k)
  local op = operators[k]
  if op then
    local k2 = getkey(ed)
    local count2
    count2, k2 = read_count(ed, k2)
    local total = combine(count1, count2)
    if k2 == k then -- dd / yy / cc
      op_lines(ed, op, ed.cy, ed.cy + (total or 1) - 1, reg)
    else
      local m = motions[k2]
      if m then apply_operator(ed, op, m, total, reg) end
    end
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
