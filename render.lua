--- render.lua -- the viewport-bounded renderer.
---
--- render.frame(ed) returns the byte string to write to the terminal for one
--- full repaint. It is (almost) pure -- it reads ed's view state and produces a
--- string -- which makes it unit-testable without a real tty. Per the rendering
--- design ([[lvi-rendering]] in project memory): we only ever touch the lines
--- and columns actually visible, so cost is O(viewport), never O(buffer).
--- Highlights are a stateless overlay -- named groups of byte ranges in
--- ed.highlights, set from outside (`:hl`). Each group may carry a style in
--- ed.hlstyles (set by `:hi`, an SGR parameter string); a group with no style
--- draws in reverse video, so the plain search / quickfix overlay is unchanged.
--- This is the mechanism external search, quickfix, and syntax highlighting all
--- build on.

local term = require("term")
local disp = require("disp")

local M = {}

-- Bucket every highlight range by line, once per frame: O(total ranges), then
-- O(1) lookup per visible line.
local function hl_index(ed)
  local idx = {}
  if not ed.highlights then return idx end
  local styles = ed.hlstyles or {}
  for group, ranges in pairs(ed.highlights) do
    local sgr = styles[group]                 -- nil -> default reverse video (in slice)
    for _, r in ipairs(ranges) do
      idx[r.line] = idx[r.line] or {}
      table.insert(idx[r.line], { line = r.line, c1 = r.c1, c2 = r.c2, sgr = sgr })
    end
  end
  return idx
end

-- Convert a line's highlight ranges (byte columns) into 0-based, end-exclusive
-- display-column intervals, carrying each range's SGR style through to slice.
local function intervals(ranges, orig, ts)
  if not ranges then return nil end
  local out = {}
  for _, r in ipairs(ranges) do
    local s = disp.dispcol(orig, ts, r.c1)
    local e = (r.c2 >= #orig) and disp.width(orig, ts) or disp.dispcol(orig, ts, r.c2 + 1)
    if e > s then out[#out + 1] = { s, e, r.sgr } end
  end
  return (#out > 0) and out or nil
end

-- Left (name/message) and right (position) halves of the status line.
local function status_halves(ed)
  local buf = ed.buf
  local left = ed.message or (buf.path or "[No Name]") .. (buf.modified and " [+]" or "")
  if not ed.message and ed.buffers and #ed.buffers > 1 then
    left = left .. "  [" .. ed.bufidx .. "/" .. #ed.buffers .. "]"
  end
  if ed.recording then left = "recording @" .. ed.recording .. "  " .. left end
  left = left:gsub("\n", " ")                 -- never inject a newline mid-line
  local nl = buf:nlines()
  local pct
  if nl <= 1 then pct = "All"
  else pct = math.floor((ed.cy - 1) / (nl - 1) * 100 + 0.5) .. "%" end
  return left, ed.cy .. "," .. ed.cx .. "  " .. pct
end

function M.frame(ed)
  local rows, cols = ed.rows, ed.cols
  local W = cols
  local textrows = rows - 1
  local buf = ed.buf
  local ts = (ed.opts and ed.opts.tabstop) or 8
  local wrap = ed.opts and ed.opts.wrap
  local hidx = hl_index(ed)
  local out = { term.hide, term.home }
  local crow, ccol

  if wrap then
    -- Each buffer line occupies one or more screen rows; paint from
    -- (ed.top, ed.topsub), noting the cursor's screen row as we pass it.
    local ccsub, cccol = disp.locate(buf:line(ed.cy) or "", W, ts, ed.cx)
    local l, skip, sr = ed.top, (ed.topsub or 0), 0
    while sr < textrows and l <= buf:nlines() do
      local orig = buf:line(l) or ""
      local ivs = intervals(hidx[l], orig, ts)
      local nseg = disp.nsegs(orig, W, ts)
      for si = 1 + skip, nseg do
        if sr >= textrows then break end
        out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol .. disp.slice(orig, ts, (si - 1) * W, W, ivs)
        if l == ed.cy and (si - 1) == ccsub then crow, ccol = sr + 1, cccol + 1 end
        sr = sr + 1
      end
      skip, l = 0, l + 1
    end
    while sr < textrows do out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol .. "~"; sr = sr + 1 end
    crow, ccol = crow or 1, ccol or 1
  else
    -- One buffer line per screen row; slice by the horizontal offset leftcol.
    local left = ed.leftcol or 0
    for i = 0, textrows - 1 do
      out[#out + 1] = term.move(i + 1, 1) .. term.clr_eol
      local L = ed.top + i
      local ln = buf:line(L)
      if ln == nil then out[#out + 1] = "~"
      else out[#out + 1] = disp.slice(ln, ts, left, W, intervals(hidx[L], ln, ts)) end
    end
    crow = ed.cy - ed.top + 1
    ccol = disp.dispcol(buf:line(ed.cy) or "", ts, ed.cx) - left + 1
  end

  -- Bottom row: command line while typing ':', otherwise the status line.
  out[#out + 1] = term.move(rows, 1) .. term.clr_eol
  if ed.mode == "command" then
    out[#out + 1] = (":" .. ed.cmdline):sub(1, cols)
    crow, ccol = rows, math.min(cols, 2 + #ed.cmdline)
  else
    local left_s, right = status_halves(ed)
    local pad = cols - #left_s - #right
    local line = (pad >= 1) and (left_s .. string.rep(" ", pad) .. right)
                             or  (left_s .. " " .. right)
    out[#out + 1] = line:sub(1, cols)
  end

  crow = math.max(1, math.min(crow, rows))
  ccol = math.max(1, math.min(ccol, cols))
  out[#out + 1] = term.move(crow, ccol) .. term.show
  return table.concat(out)
end

return M
