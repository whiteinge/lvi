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
--- draws as plain text (an un-themed group is invisible), so a tool that wants
--- to be seen without a theme sets its own style, e.g. `:hi search reverse`.
--- This is the mechanism external search, quickfix, and syntax highlighting all
--- build on.

local term = require("term")
local disp = require("disp")
local fold = require("fold")

local M = {}

-- A closed fold's one-row summary: "+-- N lines: <head text>", sliced to the
-- window. Themed by the `Folded` group (`:hi Folded ...`, like vim): when it
-- carries a style the row is padded to the window width and covered by one
-- interval, so it reads as a full-width bar; un-themed it draws as plain text.
-- It is a synthetic row, not the underlying line, so the buffer's own :hl
-- overlay does not apply here.
local function fold_summary(head, buf, ts, W, sgr)
  local text = ("+--%3d lines: %s"):format(head.e - head.s + 1, buf:line(head.s) or "")
  if not sgr or sgr == "" then return disp.slice(text, ts, 0, W, nil) end
  local w = disp.width(text, ts)
  if w < W then text = text .. string.rep(" ", W - w) end
  return disp.slice(text, ts, 0, W, { { 0, W, sgr, 0 } })
end

-- Bucket every highlight range by line, once per frame: O(total ranges), then
-- O(1) lookup per visible line.
local function hl_index(ed)
  local idx = {}
  local styles = ed.hlstyles
  local pris = ed.hlpri
  for group, ranges in pairs(ed.highlights) do
    local sgr = styles[group]                 -- nil -> plain text (invisible, in slice)
    local pri = pris[group] or 0              -- z-order; higher wins per cell (see intervals)
    for _, r in ipairs(ranges) do
      idx[r.line] = idx[r.line] or {}
      table.insert(idx[r.line], { line = r.line, c1 = r.c1, c2 = r.c2, sgr = sgr, pri = pri })
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
    if e > s then out[#out + 1] = { s, e, r.sgr, r.pri or 0 } end
  end
  -- slice resolves overlaps by "last interval wins", so sort ascending by pri:
  -- the highest-priority group covering a cell ends up last and shows through.
  table.sort(out, function(a, b) return a[4] < b[4] end)
  return (#out > 0) and out or nil
end

-- The named status segments (set via :status), joined in name order into one
-- middle string. Generic: the editor doesn't know a list from a clock; a tool
-- fills them. Empty when nothing is set.
local function status_mid(ed)

  local names = {}
  for name in pairs(ed.status) do names[#names + 1] = name end
  table.sort(names)
  local segs = {}
  for _, name in ipairs(names) do segs[#segs + 1] = ed.status[name] end
  return (table.concat(segs, "  "):gsub("\n", " "))
end

-- Left (name/message) and right (position) halves of the status line.
local function status_halves(ed)
  local buf = ed.buf
  local left = ed.message or (buf.path or buf.name or "[No Name]") .. (buf.modified and " [+]" or "")
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
  local ts = ed.opts.tabstop
  local wrap = ed.opts.wrap
  local lb = ed.opts.linebreak
  local folds = ed.folds or {}
  local hasfolds = folds[1] ~= nil
  local foldsgr = ed.hlstyles and ed.hlstyles["Folded"]   -- :hi Folded ... (optional theme)
  local nl = buf:nlines()
  local hidx = hl_index(ed)
  local out = { term.hide, term.home }
  local crow, ccol

  if wrap then
    -- Each buffer line occupies one or more screen rows; paint from
    -- (ed.top, ed.topsub), noting the cursor's screen row as we pass it. A
    -- closed fold is a single summary row at its head, and the walk skips its
    -- hidden interior via fold.next_vline (the inverse of a wrapped line).
    local ccsub, cccol = disp.locate(buf:line(ed.cy) or "", W, ts, ed.cx, lb)
    local l, skip, sr = ed.top, ed.topsub, 0
    while sr < textrows and l ~= nil and l <= nl do
      local head = hasfolds and fold.closed_head(folds, l) or nil
      if head then
        out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol .. fold_summary(head, buf, ts, W, foldsgr)
        if l == ed.cy then crow, ccol = sr + 1, 1 end
        sr, skip = sr + 1, 0
        l = hasfolds and fold.next_vline(folds, l, nl) or (l + 1)
      else
        local orig = buf:line(l) or ""
        local ivs = intervals(hidx[l], orig, ts)
        -- Walk the line's wrapped segments via seg_end (variable width under
        -- linebreak), skipping the first `skip` (topsub). Each row is sliced to
        -- its own width `w`, never full W, so a linebreak row can't spill the
        -- next word onto this line.
        local a, sc, si, len = 1, 0, 0, #orig
        repeat
          local b, w = disp.seg_end(orig, a, W, ts, lb)
          if si >= skip then
            if sr >= textrows then break end
            out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol .. disp.slice(orig, ts, sc, w, ivs)
            if l == ed.cy and si == ccsub then crow, ccol = sr + 1, cccol + 1 end
            sr = sr + 1
          end
          a, sc, si = b, sc + w, si + 1
        until a > len
        -- Phantom edge-wrap row: the cursor is past EOL on an exactly-full row, so
        -- disp.locate placed it on a fresh continuation row (ccsub == segment
        -- count, cccol == 0). The segment loop never drew that row; draw it empty
        -- and land the cursor there, matching refresh's phantom-aware scroll.
        if l == ed.cy and ccsub >= si and si >= skip and sr < textrows then
          out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol
          crow, ccol = sr + 1, cccol + 1
          sr = sr + 1
        end
        skip = 0
        l = hasfolds and fold.next_vline(folds, l, nl) or (l + 1)
      end
    end
    while sr < textrows do out[#out + 1] = term.move(sr + 1, 1) .. term.clr_eol .. "~"; sr = sr + 1 end
    crow, ccol = crow or 1, ccol or 1
  else
    -- One visible buffer line per screen row; slice by the horizontal offset
    -- leftcol. With folds present, walk fold.next_vline instead of top+i (which
    -- would count hidden lines) and draw a summary row for each closed head.
    local left = ed.leftcol or 0
    local L = ed.top
    for i = 0, textrows - 1 do
      out[#out + 1] = term.move(i + 1, 1) .. term.clr_eol
      if L == nil or L > nl then out[#out + 1] = "~"
      else
        local head = hasfolds and fold.closed_head(folds, L) or nil
        if head then out[#out + 1] = fold_summary(head, buf, ts, W, foldsgr)
        else
          local ln = buf:line(L)
          out[#out + 1] = disp.slice(ln, ts, left, W, intervals(hidx[L], ln, ts))
        end
        if L == ed.cy then crow = i + 1 end
        L = hasfolds and fold.next_vline(folds, L, nl) or (L + 1)
      end
    end
    crow = crow or 1
    if hasfolds and fold.closed_head(folds, ed.cy) then ccol = 1   -- cursor on a fold row: col 1
    else ccol = disp.dispcol(buf:line(ed.cy) or "", ts, ed.cx) - left + 1 end
  end

  -- Bottom row: command line while typing ':', otherwise the status line.
  out[#out + 1] = term.move(rows, 1) .. term.clr_eol
  if ed.mode == "command" then
    -- Char-aware slice (a byte :sub could bisect a UTF-8 char at the edge) and
    -- a display-width cursor (a multibyte cmdline is wider in bytes than cells).
    local pline = ":" .. ed.cmdline
    out[#out + 1] = disp.slice(pline, ts, 0, cols, nil)
    crow, ccol = rows, math.min(cols, 1 + disp.width(pline, ts))
  else
    -- Padding by DISPLAY width, truncation char-aware: a multibyte path or
    -- message is wider in bytes than cells, and a byte :sub could bisect a
    -- UTF-8 char at the screen edge -- the same care the text area gets.
    local left_s, right = status_halves(ed)
    local mid = status_mid(ed)
    local lw, mw, rw = disp.width(left_s, ts), disp.width(mid, ts), disp.width(right, ts)
    local line
    if mid ~= "" then
      -- left ... mid ... right, centering the middle in the slack; overflow is
      -- truncated by the slice below (position on the right is the first to go).
      local room = cols - lw - mw - rw
      if room >= 2 then
        local lpad = math.floor(room / 2)
        line = left_s .. string.rep(" ", lpad) .. mid .. string.rep(" ", room - lpad) .. right
      else
        line = left_s .. "  " .. mid .. "  " .. right
      end
    else
      local pad = cols - lw - rw
      line = (pad >= 1) and (left_s .. string.rep(" ", pad) .. right)
                         or  (left_s .. " " .. right)
    end
    -- The message (left half) can carry a theme group (:msge -> "Error"): style
    -- just its columns, like fold_summary. Un-themed -> plain, so the text stays
    -- legible either way.
    local msgsgr = ed.message and ed.message_hl and ed.hlstyles and ed.hlstyles[ed.message_hl]
    local ivs = (msgsgr and msgsgr ~= "") and { { 0, lw, msgsgr, 0 } } or nil
    out[#out + 1] = disp.slice(line, ts, 0, cols, ivs)
  end

  crow = math.max(1, math.min(crow, rows))
  ccol = math.max(1, math.min(ccol, cols))
  out[#out + 1] = term.move(crow, ccol) .. term.show
  return table.concat(out)
end

return M
