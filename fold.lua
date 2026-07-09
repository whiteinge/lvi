--- fold.lua -- folds as a pure view overlay.
---
--- A fold is { s = startline, e = endline, open = bool }; a *closed* fold hides
--- its interior (lines s+1..e) and renders line s as a one-row summary. Folds
--- are transient per-view state, exactly like the :hl overlay -- they never
--- touch the buffer, so :w, the delegated-ex path (:s/:g), and every other
--- consumer see all lines regardless of what is folded. They travel with the
--- view (bufs saves/loads ed.folds), and editor.make_splice_hook shifts their
--- endpoints across edits the same way it shifts marks.
---
--- This module is deliberately PURE: it takes a folds list and line numbers and
--- returns line numbers, with no reference to the buffer, disp, or ed. That is
--- what lets render.lua and normal.lua share ONE definition of "which buffer
--- line is visible" -- the single mapping that folding, like wrap, bends away
--- from the affine `top + i`. Callers combine these with their own segment
--- logic (disp.nsegs) for wrap.
---
--- Folds are assumed properly nested or disjoint (never partially overlapping),
--- matching vim; the walks tolerate overlap by always jumping to the widest
--- covering fold, so a malformed set degrades to "shows less" rather than loops.

local M = {}

-- The closed fold whose HEAD is line l (the row rendered as a summary), or nil.
-- A visible head belongs to exactly one fold: any fold that also covered l would
-- have to contain it closed, but then l would be hidden and never reached.
function M.closed_head(folds, l)
  for _, f in ipairs(folds) do
    if not f.open and f.s == l then return f end
  end
  return nil
end

-- Is line l hidden -- strictly inside the interior (s+1..e) of some closed fold?
-- The head line s stays visible; only s+1..e collapse.
function M.hidden(folds, l)
  for _, f in ipairs(folds) do
    if not f.open and l > f.s and l <= f.e then return true end
  end
  return false
end

-- The innermost closed fold covering line l (largest start wins = tightest), or
-- nil. Used by zo/za: opening reveals one nesting level from the inside out.
function M.innermost_closed(folds, l)
  local best
  for _, f in ipairs(folds) do
    if not f.open and l >= f.s and l <= f.e then
      if not best or f.s > best.s then best = f end
    end
  end
  return best
end

-- The innermost fold (open or closed) covering l -- smallest span wins. Used by
-- zd (delete the fold you are standing in) and zc (close the tightest one).
function M.innermost(folds, l)
  local best
  for _, f in ipairs(folds) do
    if l >= f.s and l <= f.e then
      if not best or (f.e - f.s) < (best.e - best.s) then best = f end
    end
  end
  return best
end

-- The next visible buffer line after l (skipping closed-fold interiors), or nil
-- past `nlines`. From a closed head you step past the fold's end; if the landing
-- line is itself hidden (adjacent/nested folds) advance over the widest fold
-- covering it until a visible line -- a head or an unfolded line -- is reached.
function M.next_vline(folds, l, nlines)
  local head = M.closed_head(folds, l)
  if head then l = head.e end
  l = l + 1
  while l <= nlines and M.hidden(folds, l) do
    local jump = l
    for _, f in ipairs(folds) do
      if not f.open and l > f.s and l <= f.e and f.e > jump then jump = f.e end
    end
    l = jump + 1
  end
  return (l <= nlines) and l or nil
end

-- The previous visible buffer line before l, or nil past the top. A hidden
-- landing line resolves to the head (start) of the widest closed fold covering
-- it, which is always visible.
function M.prev_vline(folds, l, nlines)
  l = l - 1
  while l >= 1 and M.hidden(folds, l) do
    local jump = l
    for _, f in ipairs(folds) do
      if not f.open and l > f.s and l <= f.e and f.s < jump then jump = f.s end
    end
    l = jump
  end
  return (l >= 1) and l or nil
end

return M
