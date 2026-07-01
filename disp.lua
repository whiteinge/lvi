--- disp.lua -- display geometry: the single place that turns buffer bytes into
--- terminal columns. Model: a line's on-screen form is its tab-expanded display
--- string D; wrapping is just chunking D every W columns, and a byte's screen
--- position is its display-column offset in D. Wrap boundaries, cursor position,
--- horizontal scroll, gj/gk, `|`, and highlight column math all derive from this.
--- A wide-char/UTF-8 width is a future extension of charwidth (tabs handled now).
---
--- Cost note: these walk the line up to the point of interest -- O(len) for a
--- single pathologically long line per frame; the `less`-handoff is the escape.

local M = {}

-- Columns consumed by byte `b` starting at 0-based display column `col`.
local function charwidth(b, col, ts)
  if b == 9 then return ts - (col % ts) end
  return 1
end

-- Expand tabs to spaces: the display form of a line. Unchanged when no tab.
function M.expand(s, ts)
  if not s:find("\t", 1, true) then return s end
  local out, col = {}, 0
  for i = 1, #s do
    local b = s:byte(i)
    if b == 9 then
      local w = ts - (col % ts); out[#out + 1] = string.rep(" ", w); col = col + w
    else
      out[#out + 1] = string.char(b); col = col + 1
    end
  end
  return table.concat(out)
end

-- 0-based display column at which buffer byte `cx` begins.
function M.dispcol(s, ts, cx)
  local col = 0
  for i = 1, math.min(cx - 1, #s) do col = col + charwidth(s:byte(i), col, ts) end
  return col
end

-- Total display width of a line.
function M.width(s, ts) return M.dispcol(s, ts, #s + 1) end

-- The buffer byte occupying 0-based display column `dcol` (clamped to the line).
function M.byte_at_dispcol(s, ts, dcol)
  local n = #s
  if n == 0 then return 1 end
  local col = 0
  for i = 1, n do
    local w = charwidth(s:byte(i), col, ts)
    if col + w > dcol then return i end
    col = col + w
  end
  return n
end

-- Wrap into display strings of at most W columns (chunks of the display form).
function M.segments(s, W, ts)
  local d = M.expand(s, ts)
  if #d == 0 then return { "" } end
  local rows = {}
  for i = 1, #d, W do rows[#rows + 1] = d:sub(i, i + W - 1) end
  return rows
end

-- Number of wrapped rows at width W.
function M.nsegs(s, W, ts)
  local w = M.width(s, ts)
  return (w == 0) and 1 or math.ceil(w / W)
end

-- (sub-row, column) both 0-based for buffer byte `cx` under wrap width W.
function M.locate(s, W, ts, cx)
  local dc = M.dispcol(s, ts, cx)
  return math.floor(dc / W), dc % W
end

-- Inverse of locate: the byte at wrapped position (sub, col). Used by gj/gk.
function M.byteat(s, W, ts, sub, col)
  return M.byte_at_dispcol(s, ts, sub * W + col)
end

return M
