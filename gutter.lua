--- gutter.lua -- the left margin: an ordered strip of named columns.
---
--- This module reverses a published ruling. lvi held for a long time that every
--- screen column is real content and the highlight overlay is a recolor, never a
--- layout; the margin breaks that in one place, since a row's buffer text now
--- starts at screen column gw+1. A spike measured the price before the reversal:
--- the offset is confined to M.width/M.textw below, no existing test needed
--- changing, and the invariance property in test/gutter_test.lua pins the whole
--- claim down -- a margin g columns wide must behave exactly as a screen g
--- columns narrower. Two things paid for it:
---
---   * MARKING A LINE STOPPED MEANING RECOLORING IT. The `:hl` first-cell sign
---     gave every producer one cell to fight over, decided by an unstable
---     equal-priority tie, so a line that was both a lint hit and a git hunk
---     showed one of them. A column per producer removes the contest, and the
---     marks stop competing with syntax highlighting for the same cells.
---
---   * THE OFFSET COSTS NOTHING DOWNSTREAM, because nothing maps a screen
---     position back to a buffer position. That would be mouse support, which is
---     permanently out of scope (the clipboard is the answer instead) -- so the
---     tax the old ruling was avoiding is priced at zero. Keep it that way: a
---     future feature that needs the reverse mapping is the one to argue about.
---
--- The design follows :status, not vim's 'signcolumn'. A gutter is an ORDERED
--- LIST OF NAMED COLUMNS named in the rc -- `set gutter=number,git,lint` -- and
--- the editor knows nothing about what a name means. Two kinds of column:
---
---   * `number` / `relativenumber` -- editor-owned, because their content is a
---     function of the row (and, for relative, of the cursor). Nothing outside
---     the editor can compute them without being asked once per visible row per
---     frame, and lvi's only outward call is a detached spawn. Width follows the
---     buffer's line count.
---
---   * anything else -- a one-cell TOOL column, filled by pushing marks in
---     (`:gutter git 4:+ 9:-`), exactly as `:hl` pushes ranges: the whole column
---     is replaced per push, so a producer re-states its world and never has to
---     clear. Style comes from the same `:hi` group table the overlay uses, so a
---     column named `git` is themed by `:hi git ...` and an unstyled column
---     draws as plain text (like an un-themed :hl group).
---
--- Placement is the USER's (the rc names the order); content is the TOOL's (it
--- pushes marks). That is the state-ownership razor applied to layout, and it is
--- why there is no priority number: vim needs one because several producers
--- share one column, and here they don't.
---
--- Marks carry an optional per-mark group (`4:+:GitAdd`) because one producer
--- legitimately wants two colors in its column -- a green `+` and a red `-` --
--- and the column name alone cannot say which.
---
--- `:nohl` deliberately does NOT clear these. The two are separate channels on
--- purpose: the point of a margin is a marker that does not clutter the text, so
--- margin-on with the overlay off is a state worth being able to reach. `set
--- gutter=` is how you silence the margin.

local disp = require("disp")

local M = {}

-- vim's 'numberwidth' default is 4: three digits plus the separating space.
local NUMW_MIN = 3

local function isnum(n) return n == "number" or n == "nu" end
local function isrel(n) return n == "relativenumber" or n == "rnu" end

-- The configured column names, in order. `number` and `relativenumber` are two
-- spellings of ONE column (absolute, or relative-with-absolute-on-the-cursor):
-- listing both would draw the line number twice, so the first wins.
function M.names(ed)
  local out, seen_num = {}, false
  for n in (ed.opts.gutter or ""):gmatch("[^,]+") do
    n = n:match("^%s*(.-)%s*$")
    if n ~= "" then
      if isnum(n) or isrel(n) then
        if not seen_num then seen_num = true; out[#out + 1] = n end
      else
        out[#out + 1] = n
      end
    end
  end
  return out
end

-- POSIX vi's `number` option, defined ONTO the column list rather than kept as a
-- second piece of state: `set number` appends the numeric column (innermost,
-- next to the text, where vim puts it), `set nonumber` removes it whichever
-- spelling it wears, and `set relativenumber` swaps the spelling in place.
-- One store, so `set gutter=` and `set number` can never disagree.
function M.numkind(ed)
  for _, n in ipairs(M.names(ed)) do
    if isnum(n) then return "number" elseif isrel(n) then return "relativenumber" end
  end
  return nil
end

-- kind: "number" | "relativenumber" | nil (remove). Order is preserved when the
-- column is already there, so toggling relative does not move the margin around.
function M.setnum(ed, kind)
  local out, placed = {}, false
  for _, n in ipairs(M.names(ed)) do
    if isnum(n) or isrel(n) then
      if kind then out[#out + 1] = kind; placed = true end   -- swap in place
    else
      out[#out + 1] = n
    end
  end
  if kind and not placed then out[#out + 1] = kind end
  ed.opts.gutter = table.concat(out, ",")
end

-- One column's width. A number column grows with the buffer (so opening a
-- 10000-line file reflows the text by one column, as in vim); a tool column is
-- always one cell -- a mark is a mark, and a producer that wants two symbols
-- asks for two columns.
local function colw(ed, n)
  if isnum(n) or isrel(n) then
    local nl = (ed.buf and ed.buf.nlines) and ed.buf:nlines() or 1
    return math.max(NUMW_MIN, #tostring(nl)) + 1
  end
  return 1
end

-- Total gutter width, capped so the text area can never vanish. This and
-- M.textw are the ONLY places the rest of the editor learns that screen column
-- 1 is not buffer column 1.
function M.width(ed)
  local w = 0
  for _, n in ipairs(M.names(ed)) do w = w + colw(ed, n) end
  if w > ed.cols - 1 then w = math.max(0, ed.cols - 1) end
  return w
end

-- The width available to buffer text. Every wrap, scroll and horizontal-offset
-- calculation in the editor measures against THIS, not ed.cols.
function M.textw(ed)
  return math.max(1, ed.cols - M.width(ed))
end

-- One row's gutter, already styled and padded to M.width. `l` is the buffer
-- line shown on this row, or nil for a wrapped continuation row or a `~` filler
-- -- both of which blank out, so the eye reads one number per buffer line.
--
-- `ns`/`W` are M.names/M.width hoisted out of the caller's row loop: this runs
-- once per screen row per frame, and re-parsing `set gutter=` for every one of
-- them is a table and a gmatch of garbage per row for an answer that cannot
-- change mid-frame. Omitted, they are computed here.
function M.cell(ed, l, ts, ns, W)
  ns, W = ns or M.names(ed), W or M.width(ed)
  if W == 0 then return "" end
  local parts, ivs, at = {}, {}, 0
  for _, n in ipairs(ns) do
    local w, text, group = colw(ed, n), nil, nil
    if isnum(n) or isrel(n) then
      if l then
        local v = l
        if isrel(n) and l ~= ed.cy then v = math.abs(l - ed.cy) end
        text = ("%" .. (w - 1) .. "d "):format(v)
        if #text > w then text = text:sub(-w) end        -- number wider than its column
      else
        text = string.rep(" ", w)
      end
      -- Vim's split: the cursor's own number may be themed apart from the rest.
      -- Fall back to LineNr so a single `:hi LineNr` styles the whole column.
      group = (l == ed.cy and ed.hlstyles["CursorLineNr"]) and "CursorLineNr" or "LineNr"
    else
      -- Only a cell that actually BEARS a mark is styled: an unmarked cell must
      -- stay blank, or a column themed with a bg= would paint a solid bar down
      -- every line instead of marking the few it means.
      local m = l and ed.gutters[n] and ed.gutters[n][l]
      if m then
        text, group = m.ch, m.group
        local tw = disp.width(text, ts)
        if tw < w then text = text .. string.rep(" ", w - tw)
        elseif tw > w then text = disp.slice(text, ts, 0, w, nil) end
      else
        text = string.rep(" ", w)
      end
    end
    local sgr = group and ed.hlstyles[group]
    if sgr and sgr ~= "" then ivs[#ivs + 1] = { at, at + w, sgr, 0 } end
    parts[#parts + 1], at = text, at + w
  end
  -- Through disp.slice like every other painted row: it owns the SGR open/reset
  -- bookkeeping, and a producer's mark may be multibyte.
  return disp.slice(table.concat(parts), ts, 0, W, (#ivs > 0) and ivs or nil)
end

return M
