--- view.lua -- how the buffer maps onto the screen.
---
--- One home for the geometry every other module kept asking about separately:
--- how wide the text area is, how many screen rows a buffer line occupies, which
--- line is visibly next, and how to walk a screen position by rows. `editor.lua`
--- (the scroll/clamp pass) and `normal.lua` (the scroll commands and gj/gk) each
--- carried their own copy of all four, and the copies had drifted -- the
--- phantom-edge-wrap guard existed in the driver's walk and not the
--- interpreter's, which is exactly the kind of divergence a second copy buys.
---
--- Three ideas, in dependency order:
---
---   1. TEXT WIDTH is not screen width. gutter.lua owns the margin; everything
---      that measures in screen columns measures against what is left. This is
---      the single seam -- see gutter.lua's header.
---
---   2. A VISIBLE LINE is not the next line. A closed fold collapses its
---      interior to one summary row at the head, so stepping is nextv/prevv, not
---      l+1/l-1, whenever folds are present.
---
---   3. A SCREEN ROW is not a buffer line. Under wrap a line occupies segs()
---      rows, so a screen position is the pair (line, sub-row) and moving by
---      rows is advance(). nowrap collapses to one row per visible line, which
---      is a fast path here rather than a special case at every call site.
---
--- The phantom edge-wrap row is the one wrinkle worth knowing about before
--- changing anything here. With the cursor past EOL on an exactly-full row (an
--- insert at the screen edge), disp.locate reports sub == the segment count --
--- a row that the segment walk itself never produces. rows_to() therefore
--- stretches the cursor line by one row when asked about that position; without
--- it, a walk looking for the cursor never reaches it and concludes the on-screen
--- cursor is off-screen. That was bugs 4/5, and it is guarded by the invariance
--- property in test/gutter_test.lua plus the refresh specs in test/editor_test.lua.

local disp = require("disp")
local fold = require("fold")
local gutter = require("gutter")

local M = {}

-- The width available to buffer text: the screen minus the left margin.
function M.textw(ed) return gutter.textw(ed) end

-- Text rows: the screen minus the status/command line.
function M.textrows(ed) return ed.rows - 1 end

-- Are folds in play at all? `zi` (nofoldenable) leaves ed.folds intact but makes
-- every line visible, so every fold path -- stepping, clamping, revealing --
-- hangs off this one predicate.
function M.hasfolds(ed)
  return ed.opts.foldenable and ed.folds and ed.folds[1] ~= nil
end

-- Fold-aware buffer-line stepping: skip closed-fold interiors (a closed fold is
-- one screen row at its head), else plain +1/-1. nil at either end.
function M.nextv(ed, l, nl)
  nl = nl or ed.buf:nlines()
  if M.hasfolds(ed) then return fold.next_vline(ed.folds, l, nl) end
  return (l < nl) and l + 1 or nil
end

function M.prevv(ed, l, nl)
  nl = nl or ed.buf:nlines()
  if M.hasfolds(ed) then return fold.prev_vline(ed.folds, l, nl) end
  return (l > 1) and l - 1 or nil
end

-- Screen rows a buffer line occupies: 1 when not wrapping (a long line is
-- truncated at the edge, not continued) or for a closed-fold head (its summary),
-- else the line's wrapped segment count. W/ts are passed in because the callers
-- hoist them out of per-row loops.
--
-- The nowrap answer is part of the contract, not a shortcut: rows_to walks with
-- this in both modes, and the two copies this replaced only ever called their
-- version from inside a wrap branch -- so leaving it to the caller would be
-- handing back the footgun the merge is here to remove.
function M.segs(ed, l, W, ts)
  if not ed.opts.wrap then return 1 end
  if M.hasfolds(ed) and fold.closed_head(ed.folds, l) then return 1 end
  return disp.nsegs(ed.buf:line(l) or "", W or M.textw(ed), ts or ed.opts.tabstop,
                    ed.opts.linebreak)
end

-- Move a screen position (line l, sub-row sub) by `rows` screen rows (negative =
-- up), honoring wrap AND folds, clamped to the buffer.
function M.advance(ed, l, sub, rows)
  local N = ed.buf:nlines()
  if not ed.opts.wrap then
    if not M.hasfolds(ed) then return math.max(1, math.min(l + rows, N)), 0 end
    if rows >= 0 then
      for _ = 1, rows do local nx = M.nextv(ed, l, N); if nx then l = nx else break end end
    else
      for _ = 1, -rows do local pv = M.prevv(ed, l, N); if pv then l = pv else break end end
    end
    return l, 0
  end
  local W, ts = M.textw(ed), ed.opts.tabstop
  if rows > 0 then
    for _ = 1, rows do
      if sub + 1 < M.segs(ed, l, W, ts) then sub = sub + 1
      else local nx = M.nextv(ed, l, N); if nx then l, sub = nx, 0 else break end end
    end
  else
    for _ = 1, -rows do
      if sub > 0 then sub = sub - 1
      else
        local pv = M.prevv(ed, l, N)
        if pv then l, sub = pv, M.segs(ed, pv, W, ts) - 1 else break end
      end
    end
  end
  return l, sub
end

-- Screen rows from (fl, fsub) forward to (tl, tsub): the count, and whether the
-- target was actually reached. `bound` stops the walk after that many rows and
-- reports not-reached -- which is how the driver asks "is the cursor on screen?"
-- without walking a whole buffer. Unbounded, this is just "which screen row is
-- the cursor on".
--
-- The target line is stretched by a row when tsub names the phantom edge-wrap
-- row (see the header): the segment walk cannot produce that row, so a walk
-- looking for it would step past the line and never match.
function M.rows_to(ed, fl, fsub, tl, tsub, W, ts, bound)
  local nl = ed.buf:nlines()
  W, ts = W or M.textw(ed), ts or ed.opts.tabstop
  local l, sub, n = fl, fsub, 0
  while true do
    -- Bound BEFORE match, deliberately: rows 0..bound-1 are the ones on screen,
    -- so a target sitting exactly `bound` rows down is off it.
    if bound and n >= bound then return n, false end
    if l == tl and sub == tsub then return n, true end
    if l == nil or l > nl then return n, false end
    local ns = M.segs(ed, l, W, ts)
    if l == tl and tsub >= ns then ns = tsub + 1 end
    if sub + 1 < ns then sub = sub + 1 else l, sub = M.nextv(ed, l, nl), 0 end
    n = n + 1
  end
end

return M
