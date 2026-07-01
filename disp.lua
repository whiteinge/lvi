--- disp.lua -- display geometry: the single place that turns buffer bytes into
--- terminal columns. Wrap boundaries, the cursor's screen position, horizontal
--- scroll, and (later) gj/gk are all "advance N *display* columns", so they all
--- go through here. Tabs expand to the next tab stop; a wide-char/UTF-8 width is
--- a future extension of one function (charwidth) rather than a rewrite.
---
--- Cost note: locate/segments/expand walk the line, so they are O(len) for the
--- portion up to the point of interest. Fine for normal lines; a single
--- pathologically long line (e.g. minified JSON) is O(len) per frame -- the
--- `less`-handoff is the escape hatch for genuinely huge content.

local M = {}

-- Columns consumed by the byte `b` starting at 0-based display column `col`.
-- Tab aligns to the next multiple of tabstop; everything else is 1 (for now).
local function charwidth(b, col, ts)
  if b == 9 then return ts - (col % ts) end
  return 1
end

-- Expand tabs to spaces for display (used by the nowrap slice). Returns the
-- string unchanged when it has no tab.
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

-- 0-based display column at which buffer byte `cx` begins (width of the prefix
-- before it). Used for the nowrap cursor column.
function M.dispcol(s, ts, cx)
  local col = 0
  for i = 1, math.min(cx - 1, #s) do
    col = col + charwidth(s:byte(i), col, ts)
  end
  return col
end

-- Wrap `s` into a list of display strings, each at most W columns wide (tabs
-- expanded). An empty line is one empty row.
function M.segments(s, W, ts)
  if #s == 0 then return { "" } end
  local rows, cur, col = {}, {}, 0
  for i = 1, #s do
    local b = s:byte(i)
    local w = charwidth(b, col, ts)
    if col + w > W and col > 0 then
      rows[#rows + 1] = table.concat(cur)
      cur, col = {}, 0
      w = charwidth(b, col, ts)
    end
    cur[#cur + 1] = (b == 9) and string.rep(" ", w) or string.char(b)
    col = col + w
  end
  rows[#rows + 1] = table.concat(cur)
  return rows
end

-- Number of wrapped rows `s` occupies at width W (count-only; cheaper than
-- building the strings).
function M.nsegs(s, W, ts)
  if #s == 0 then return 1 end
  local sub, col = 0, 0
  for i = 1, #s do
    local w = charwidth(s:byte(i), col, ts)
    if col + w > W and col > 0 then sub = sub + 1; col = 0; w = charwidth(s:byte(i), col, ts) end
    col = col + w
  end
  return sub + 1
end

-- Locate buffer byte `cx` under wrap width W: returns (sub-row 0-based, display
-- column 0-based) where that position sits. Consistent with segments().
function M.locate(s, W, ts, cx)
  local sub, col = 0, 0
  local n = #s
  for i = 1, math.min(cx - 1, n) do
    local w = charwidth(s:byte(i), col, ts)
    if col + w > W and col > 0 then sub = sub + 1; col = 0; w = charwidth(s:byte(i), col, ts) end
    col = col + w
  end
  if cx <= n then                       -- would placing char cx wrap first?
    local w = charwidth(s:byte(cx), col, ts)
    if col + w > W and col > 0 then sub = sub + 1; col = 0 end
  elseif col >= W then                   -- cursor past end lands on a fresh row
    sub, col = sub + 1, 0
  end
  return sub, col
end

-- Inverse of locate: the buffer byte whose visual position is (tsub, tcol),
-- clamped to that sub-row's content. Used by gj/gk to hold a screen column.
function M.byteat(s, W, ts, tsub, tcol)
  local n = #s
  if n == 0 then return 1 end
  local sub, col, cand = 0, 0, nil
  for i = 1, n do
    local w = charwidth(s:byte(i), col, ts)
    if col + w > W and col > 0 then sub = sub + 1; col = 0; w = charwidth(s:byte(i), col, ts) end
    if sub == tsub then
      if col <= tcol then cand = i
      else cand = cand or i; break end
    elseif sub > tsub then break end
    col = col + w
  end
  return cand or n
end

return M
