--- disp.lua -- display geometry: the single place that turns buffer bytes into
--- terminal columns, UTF-8 aware. A line is walked character by character; each
--- char has a byte length and a display width (tab -> next tab stop, combining
--- marks 0, common CJK/emoji 2, else 1). Wrapping keeps chars whole. Everything
--- (wrap, cursor position, horizontal scroll, gj/gk, `|`, highlight columns) is
--- derived from this one walk, and `slice` even folds the highlight escapes in.
---
--- The width table is a pragmatic subset of wcwidth: correct for the vast
--- majority, imperfect at the fringes. A wide char clipped exactly at the screen
--- edge renders as a space.
---
--- Cost note: these walk the line up to the point of interest -- O(len) for a
--- single pathologically long line per frame; the `less`-handoff is the escape.

local M = {}

-- SGR RESET turns all attributes off. A highlight interval with no style (nil
-- sgr) renders as plain text -- an un-themed group is invisible, like every
-- editor's un-themed token. A tool that wants to be seen without a theme sets
-- its own style (e.g. `:hi search reverse`).
local RESET = "\27[0m"

-- Byte length of the UTF-8 char whose lead byte is b (defensive for stray
-- continuation bytes: treat as length 1... they never start a char here).
local function charlen(b)
  if b < 0x80 then return 1
  elseif b < 0xC0 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4 end
end
M.charlen = charlen   -- byte count of the char a lead byte opens (f/t target read)

-- Byte length of the VALID UTF-8 char starting at byte i, or nil if the byte
-- there does not open one: a stray continuation byte, a lead byte whose
-- continuation bytes are missing or truncated, or an encoding no decoder should
-- accept (C0/C1 overlongs, F5-FF past U+10FFFF, and the E0/ED/F0/F4 second-byte
-- cases -- overlongs and UTF-16 surrogates). charlen answers "how many bytes does
-- this lead byte PROMISE", which is all the keyboard can know when reading a typed
-- char one byte at a time (read_char_from); seqlen answers "how many are actually
-- THERE and well-formed", which is what a string already in the buffer needs. Both
-- exist because damaged text is a normal thing to open, not an error case: a
-- truncated char must count as one byte so a cursor steps over it and the renderer
-- draws one stand-in, instead of charlen's promise swallowing the good chars after
-- it. Every measurement, navigation and emission path here goes through seqlen.
local function seqlen(s, i)
  local b = s:byte(i)
  if not b then return nil end
  if b < 0x80 then return 1 end
  if b < 0xC2 or b > 0xF4 then return nil end        -- continuation, C0/C1 overlong, F5+
  local b2 = s:byte(i + 1)
  if not b2 or b2 < 0x80 or b2 > 0xBF then return nil end
  if (b == 0xE0 and b2 < 0xA0)                       -- overlong 3-byte
    or (b == 0xED and b2 > 0x9F)                     -- UTF-16 surrogate half
    or (b == 0xF0 and b2 < 0x90)                     -- overlong 4-byte
    or (b == 0xF4 and b2 > 0x8F) then return nil end -- past U+10FFFF
  local len = charlen(b)
  for k = 2, len - 1 do
    local c = s:byte(i + k)
    if not c or c < 0x80 or c > 0xBF then return nil end
  end
  return len
end
M.seqlen = seqlen

-- Decode the codepoint at byte i; returns codepoint, byte length. Assumes a
-- sequence seqlen has already accepted.
local function decode(s, i)
  local b = s:byte(i) or 0
  if b < 0x80 then return b, 1 end
  local len = charlen(b)
  local cp = b % (2 ^ (7 - len))
  for k = 1, len - 1 do cp = cp * 64 + ((s:byte(i + k) or 0) % 64) end
  return cp, len
end

-- Pragmatic wcwidth: 0 combining, 2 common wide ranges, else 1.
local function cpwidth(cp)
  if cp == 0 then return 0 end
  if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x0483 and cp <= 0x0489)
    or (cp >= 0x200B and cp <= 0x200F) or cp == 0xFEFF then return 0 end
  if (cp >= 0x1100 and cp <= 0x115F)      -- Hangul Jamo
    or (cp >= 0x2E80 and cp <= 0x303E)    -- CJK radicals .. punctuation
    or (cp >= 0x3041 and cp <= 0x33FF)    -- kana .. CJK compat
    or (cp >= 0x3400 and cp <= 0x4DBF)    -- CJK ext A
    or (cp >= 0x4E00 and cp <= 0x9FFF)    -- CJK unified
    or (cp >= 0xA000 and cp <= 0xA4CF)    -- Yi
    or (cp >= 0xAC00 and cp <= 0xD7A3)    -- Hangul syllables
    or (cp >= 0xF900 and cp <= 0xFAFF)    -- CJK compat ideographs
    or (cp >= 0xFE30 and cp <= 0xFE4F)    -- CJK compat forms
    or (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0xFFE0 and cp <= 0xFFE6) -- fullwidth
    or (cp >= 0x1F300 and cp <= 0x1FAFF)  -- emoji & symbols
    or (cp >= 0x20000 and cp <= 0x3FFFD)  -- CJK ext B+
    then return 2 end
  return 1
end

-- ---- control bytes ----------------------------------------------------------
-- A control byte must never reach the terminal raw. An ESC read from a file (an
-- ANSI-coloured capture) would be obeyed as a control sequence and take the rest
-- of the screen with it; a BEL would ring on every repaint; a ^L page break --
-- ordinary in older sources -- would clear it. So every render path substitutes
-- Unicode's Control Pictures (U+2400 + b, U+2421 for DEL) at EMISSION time only.
--
-- Each picture is exactly one column, which is the width charinfo has always
-- reported for a byte below 0x80 -- so no width, wrap, cursor, highlight or
-- scroll arithmetic changes, and the substitution stays a display concern that
-- the rest of the editor never sees. That is the whole design: the buffer holds
-- the real byte, the screen shows a safe stand-in.
--
-- A byte that is not part of a well-formed UTF-8 char gets the same treatment,
-- for the same reason plus one more: it is UNREADABLE raw. A terminal shown a
-- stray continuation byte draws nothing, a blank, or eats the next byte trying to
-- complete a sequence -- so damage looked like a space, which is the worst way for
-- corruption to present (it hid an editor bug that sliced the lead byte off an
-- em-dash). One stand-in per bad BYTE, not per damaged run: the buffer holds those
-- bytes separately and `x` deletes them one at a time, so the screen showing two
-- glyphs for two bytes is the honest report of what it takes to clean up.
--
-- This is the safety floor, not `:set list`. Exact notation (^I for tab, $ for
-- line ends, M- for meta) belongs to contrib/lvi-invis, which pages the live
-- buffer through `cat -vet`.
local CTRL = {}
for bb = 0, 31 do CTRL[bb] = "\226\144" .. string.char(0x80 + bb) end -- U+2400 + bb
CTRL[9] = nil                                    -- tab is expanded, never substituted
CTRL[127] = "\226\144\161"                       -- U+2421 SYMBOL FOR DELETE
M.CTRL = CTRL
local BAD = "\239\191\189"                       -- U+FFFD, one column, for a bad byte
M.BAD = BAD

-- Display width + byte length of the char at byte i, given running display col
-- (needed only for tab).
local function charinfo(s, i, col, ts)
  local b = s:byte(i)
  if b == 9 then return ts - (col % ts), 1 end
  if b < 0x80 then return 1, 1 end
  local len = seqlen(s, i)
  if not len then return 1, 1 end   -- one bad byte, one column: the U+FFFD stand-in
  return cpwidth(decode(s, i)), len
end

-- ---- character navigation (for cursor motion) -------------------------------
-- Both step by seqlen, so a damaged byte is one char: `l` never lands mid-char and
-- a truncated lead byte never lets the cursor jump the good chars behind it.
function M.next_char(s, i)
  local b = s:byte(i)
  return b and (i + (seqlen(s, i) or 1)) or (i + 1)
end

-- Walk back over at most 3 continuation bytes to the earliest plausible start,
-- then accept it only if a valid char there really reaches i-1; otherwise byte i-1
-- stands alone (damaged). The `>=` also snaps a mid-char i to its enclosing char.
function M.prev_char(s, i)
  local j = i - 1
  if j < 1 then return 1 end
  local k, lo = j, math.max(1, j - 3)
  while k > lo do
    local b = s:byte(k)
    if b and b >= 0x80 and b < 0xC0 then k = k - 1 else break end
  end
  local len = seqlen(s, k)
  if len and k + len - 1 >= j then return k end
  return j
end

-- Byte index of the last char's start (1 if empty) -- the normal-mode cursor cap.
function M.last_char(s)
  if #s == 0 then return 1 end
  return M.prev_char(s, #s + 1)
end

-- ---- measurement ------------------------------------------------------------
function M.width(s, ts)
  local col, i, n = 0, 1, #s
  while i <= n do local dw, len = charinfo(s, i, col, ts); col = col + dw; i = i + len end
  return col
end

-- 0-based display column at which buffer byte cx begins.
function M.dispcol(s, ts, cx)
  local col, i, n = 0, 1, #s
  while i < cx and i <= n do local dw, len = charinfo(s, i, col, ts); col = col + dw; i = i + len end
  return col
end

-- The buffer byte whose char occupies display column dcol (clamped).
function M.byte_at_dispcol(s, ts, dcol)
  local n = #s
  if n == 0 then return 1 end
  local col, i, last = 0, 1, 1
  while i <= n do
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > dcol then return i end
    last = i; col = col + dw; i = i + len
  end
  return last
end

-- ---- wrapping ---------------------------------------------------------------
-- The single source of truth for where a wrapped screen row ends. Given a
-- segment starting at byte `start` (at display col 0), return the byte at which
-- the NEXT segment begins (one past this row's last byte) and this segment's
-- display width. nsegs/locate/byteat and the renderer all derive from this, so
-- they cannot disagree about a break position. No byte is ever skipped: bytes
-- [start, next) are exactly this row, [next, ..) the next -- which keeps locate
-- and byteat exact inverses. `lb` enables whitespace `linebreak`: back the break
-- up to just after the last space/tab that fit (so trailing spaces stay on the
-- upper row, Vim-style), falling back to a hard mid-word break when the segment
-- holds no whitespace (an over-long word). Always advances (next > start when
-- start <= #s) via the `col > 0` guard, so callers can never spin.
local function seg_end(s, start, W, ts, lb)
  local n = #s
  local col, i = 0, start
  local brk, brkcol                             -- byte just after last whitespace, and its col
  while i <= n do
    local b = s:byte(i)
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > W and col > 0 then            -- this char won't fit on the row
      if lb and brk and brk > start then return brk, brkcol end
      return i, col
    end
    col = col + dw; i = i + len
    if lb and (b == 32 or b == 9) then brk, brkcol = i, col end
  end
  return i, col
end
M.seg_end = seg_end

function M.nsegs(s, W, ts, lb)
  local n = #s
  if n == 0 then return 1 end
  local i, count = 1, 0
  while i <= n do i = seg_end(s, i, W, ts, lb); count = count + 1 end
  return count
end

-- (sub-row, column), both 0-based, for buffer byte cx under wrap width W.
function M.locate(s, W, ts, cx, lb)
  local n = #s
  local sub, a = 0, 1
  while a <= n do
    local b = seg_end(s, a, W, ts, lb)
    if cx < b then break end                    -- cx lives in segment [a, b)
    if cx == b and b > n then break end         -- cursor past EOL sticks to the last row
    sub, a = sub + 1, b
  end
  local col, j = 0, a                           -- display width of [a, cx)
  while j < cx and j <= n do
    local dw, len = charinfo(s, j, col, ts); col = col + dw; j = j + len
  end
  if cx > n and col >= W then sub, col = sub + 1, 0 end   -- phantom edge-wrap past EOL
  return sub, col
end

-- Inverse of locate: byte at wrapped position (sub, col). Used by gj/gk.
function M.byteat(s, W, ts, tsub, tcol, lb)
  local n = #s
  if n == 0 then return 1 end
  local sub, a = 0, 1
  while sub < tsub and a <= n do a = seg_end(s, a, W, ts, lb); sub = sub + 1 end
  local b = seg_end(s, a, W, ts, lb)            -- end of the target segment
  local col, i, last = 0, a, math.min(a, n)
  while i < b and i <= n do
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > tcol then return i end
    last = i; col = col + dw; i = i + len
  end
  return last
end

-- ---- rendering --------------------------------------------------------------
-- Tab-expanded display form of a whole line (well-formed multibyte chars pass
-- through; control and bad bytes get their stand-ins). The fast path is pure
-- printable ASCII -- a high byte has to be walked now, since a damaged one is
-- substituted and only seqlen can tell it from a good char.
function M.expand(s, ts)
  if not s:find("[^\32-\126]") then return s end
  local out, col, i, n = {}, 0, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 9 then local w = ts - (col % ts); out[#out + 1] = string.rep(" ", w); col = col + w; i = i + 1
    else
      local dw, len = charinfo(s, i, col, ts)
      out[#out + 1] = CTRL[b] or (b >= 0x80 and not seqlen(s, i) and BAD) or s:sub(i, i + len - 1)
      col = col + dw; i = i + len
    end
  end
  return table.concat(out)
end

function M.segments(s, W, ts, lb)
  local rows, n = {}, #s
  if n == 0 then return { "" } end
  local a, sc = 1, 0
  while a <= n do
    local b, w = seg_end(s, a, W, ts, lb)
    rows[#rows + 1] = M.slice(s, ts, sc, w, nil)
    a, sc = b, sc + w
  end
  return rows
end

-- The display string covering columns [startcol, startcol+W), tabs expanded and
-- multibyte chars kept whole, with SGR escapes around cells inside any interval
-- `ivs` (0-based, end-exclusive display-col ranges). Each interval is
-- { startcol, endcol, sgr } where sgr is the group's SGR parameter string (e.g.
-- "38;5;2;1"); a nil sgr means no styling (plain text). When adjacent cells
-- carry different styles we reset and re-open, so touching tokens keep their own
-- colors. Overlapping intervals: the last one in the list wins per cell (tokens
-- from one highlighter don't overlap; cross-group order is set by pri). One
-- char-aware walk serves every render path. The caller (render.intervals) sorts
-- by group priority ascending so this last-wins rule lets a higher-pri overlay
-- (e.g. search over syntax) show through where they cover the same cell.
function M.slice(s, ts, startcol, W, ivs)
  local endcol = startcol + W
  local out, col, i, n, cur = {}, 0, 1, #s, nil
  local function sgr_at(c)
    if not ivs then return nil end
    local hit
    for _, iv in ipairs(ivs) do if c >= iv[1] and c < iv[2] then hit = iv[3] end end
    return hit
  end
  local function put(cell, c)
    local want = sgr_at(c)
    if want ~= cur then
      if cur then out[#out + 1] = RESET end
      if want then out[#out + 1] = "\27[" .. want .. "m" end
      cur = want
    end
    out[#out + 1] = cell
  end
  while i <= n and col < endcol do
    local b = s:byte(i)
    local dw, len, glyph
    if b == 9 then dw, len = ts - (col % ts), 1
    elseif b < 0x80 then dw, len, glyph = 1, 1, CTRL[b] or s:sub(i, i)
    else
      local n2 = seqlen(s, i)
      if not n2 then dw, len, glyph = 1, 1, BAD          -- damaged byte: one stand-in
      else dw, len, glyph = cpwidth(decode(s, i)), n2, s:sub(i, i + n2 - 1) end
    end
    if col + dw > startcol then
      if b == 9 then
        for c = math.max(col, startcol), math.min(col + dw, endcol) - 1 do put(" ", c) end
      elseif dw == 0 then
        out[#out + 1] = glyph                                   -- combining mark
      elseif col >= startcol and col + dw <= endcol then
        put(glyph, col)                                         -- fully visible
      else
        for c = math.max(col, startcol), math.min(col + dw, endcol) - 1 do put(" ", c) end -- clipped wide
      end
    end
    col = col + dw; i = i + len
  end
  if cur then out[#out + 1] = RESET end
  return table.concat(out)
end

return M
