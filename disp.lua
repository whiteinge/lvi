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

local REV_ON, REV_OFF = "\27[7m", "\27[0m"

-- Byte length of the UTF-8 char whose lead byte is b (defensive for stray
-- continuation bytes: treat as length 1... they never start a char here).
local function charlen(b)
  if b < 0x80 then return 1
  elseif b < 0xC0 then return 1
  elseif b < 0xE0 then return 2
  elseif b < 0xF0 then return 3
  else return 4 end
end

-- Decode the codepoint at byte i; returns codepoint, byte length.
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

-- Display width + byte length of the char at byte i, given running display col
-- (needed only for tab).
local function charinfo(s, i, col, ts)
  local b = s:byte(i)
  if b == 9 then return ts - (col % ts), 1 end
  if b < 0x80 then return 1, 1 end
  local cp, len = decode(s, i)
  return cpwidth(cp), len
end

-- ---- character navigation (for cursor motion) -------------------------------
function M.next_char(s, i)
  local b = s:byte(i)
  return b and (i + charlen(b)) or (i + 1)
end

function M.prev_char(s, i)
  local j = i - 1
  while j > 1 do
    local b = s:byte(j)
    if b and b >= 0x80 and b < 0xC0 then j = j - 1 else break end
  end
  return math.max(1, j)
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
function M.nsegs(s, W, ts)
  local n = #s
  if n == 0 then return 1 end
  local sub, col, i = 0, 0, 1
  while i <= n do
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > W and col > 0 then sub = sub + 1; col = 0; dw = charinfo(s, i, col, ts) end
    col = col + dw; i = i + len
  end
  return sub + 1
end

-- (sub-row, column), both 0-based, for buffer byte cx under wrap width W.
function M.locate(s, W, ts, cx)
  local sub, col, i, n = 0, 0, 1, #s
  while i < cx and i <= n do
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > W and col > 0 then sub = sub + 1; col = 0; dw = charinfo(s, i, col, ts) end
    col = col + dw; i = i + len
  end
  if cx <= n then
    local dw = charinfo(s, cx, col, ts)
    if col + dw > W and col > 0 then sub = sub + 1; col = 0 end
  elseif col >= W then
    sub = sub + 1; col = 0
  end
  return sub, col
end

-- Inverse of locate: byte at wrapped position (sub, col). Used by gj/gk.
function M.byteat(s, W, ts, tsub, tcol)
  local n = #s
  if n == 0 then return 1 end
  local sub, col, i, last = 0, 0, 1, 1
  while i <= n do
    local dw, len = charinfo(s, i, col, ts)
    if col + dw > W and col > 0 then sub = sub + 1; col = 0; dw = charinfo(s, i, col, ts) end
    if sub == tsub and col + dw > tcol then return i end
    if sub > tsub then return last end
    last = i; col = col + dw; i = i + len
  end
  return last
end

-- ---- rendering --------------------------------------------------------------
-- Tab-expanded display form of a whole line (multibyte chars pass through).
function M.expand(s, ts)
  if not s:find("\t", 1, true) then return s end
  local out, col, i, n = {}, 0, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 9 then local w = ts - (col % ts); out[#out + 1] = string.rep(" ", w); col = col + w; i = i + 1
    else local dw, len = charinfo(s, i, col, ts); out[#out + 1] = s:sub(i, i + len - 1); col = col + dw; i = i + len end
  end
  return table.concat(out)
end

function M.segments(s, W, ts)
  local rows = {}
  for si = 0, M.nsegs(s, W, ts) - 1 do rows[si + 1] = M.slice(s, ts, si * W, W, nil) end
  return rows
end

-- The display string covering columns [startcol, startcol+W), tabs expanded and
-- multibyte chars kept whole, with reverse-video escapes around cells inside any
-- interval `ivs` (0-based, end-exclusive display-col ranges). One char-aware walk
-- serves every render path.
function M.slice(s, ts, startcol, W, ivs)
  local endcol = startcol + W
  local out, col, i, n, on = {}, 0, 1, #s, false
  local function want(c)
    if ivs then for _, iv in ipairs(ivs) do if c >= iv[1] and c < iv[2] then return true end end end
    return false
  end
  local function put(cell, c)
    local h = want(c)
    if h and not on then out[#out + 1] = REV_ON; on = true
    elseif not h and on then out[#out + 1] = REV_OFF; on = false end
    out[#out + 1] = cell
  end
  while i <= n and col < endcol do
    local b = s:byte(i)
    local dw, len, glyph
    if b == 9 then dw, len = ts - (col % ts), 1
    elseif b < 0x80 then dw, len, glyph = 1, 1, s:sub(i, i)
    else local cp; cp, len = decode(s, i); dw = cpwidth(cp); glyph = s:sub(i, i + len - 1) end
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
  if on then out[#out + 1] = REV_OFF end
  return table.concat(out)
end

return M
