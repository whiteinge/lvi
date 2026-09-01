-- Tests for view.lua (buffer -> screen geometry). Run: luajit test/view_test.lua
--
-- These used to be two copies: editor.lua's scroll pass and normal.lua's scroll
-- commands each carried their own hasfolds/nextv/prevv/segs and their own row
-- walk. The copies had drifted -- only the driver's walk knew about the phantom
-- edge-wrap row -- so the phantom cases below are regression tests for the
-- interpreter's half, which silently miscounted before the merge.
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local editor = require("editor")
local view   = require("view")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function ed_with(text, over)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.rows, ed.cols = 10, 10
  ed.opts.wrap = false
  for k, v in pairs(over or {}) do
    if k == "opts" then for ok, ov in pairs(v) do ed.opts[ok] = ov end else ed[k] = v end
  end
  return ed
end

local function lines(n, len)
  local t = {}
  for i = 1, n do t[i] = ("x"):rep(len or 1) end
  return table.concat(t, "\n")
end

describe("view geometry", function()
  it("reports the text area, not the screen", function()
    local ed = ed_with("a")
    expect(view.textw(ed)).to.equal(10)
    expect(view.textrows(ed)).to.equal(9)          -- minus the status line
    ed.opts.gutter = "number"
    expect(view.textw(ed)).to.equal(6)             -- minus a 4-cell margin
    expect(view.textrows(ed)).to.equal(9)          -- rows are untouched
  end)
end)

describe("view.nextv / view.prevv", function()
  it("step one line at a time with no folds", function()
    local ed = ed_with(lines(5))
    expect(view.nextv(ed, 2)).to.equal(3)
    expect(view.prevv(ed, 2)).to.equal(1)
    expect(view.nextv(ed, 5)).to_not.exist()       -- nil at the ends
    expect(view.prevv(ed, 1)).to_not.exist()
  end)

  it("skip a closed fold's interior", function()
    local ed = ed_with(lines(8))
    ex.dispatch(ed, "3,6fold")
    expect(view.nextv(ed, 2)).to.equal(3)          -- onto the head
    expect(view.nextv(ed, 3)).to.equal(7)          -- over the body
    expect(view.prevv(ed, 7)).to.equal(3)          -- back to the head, not 6
  end)

  it("ignore folds while foldenable is off (zi)", function()
    local ed = ed_with(lines(8))
    ex.dispatch(ed, "3,6fold")
    ed.opts.foldenable = false
    expect(view.hasfolds(ed)).to_not.be.truthy()
    expect(view.nextv(ed, 3)).to.equal(4)
  end)
end)

describe("view.segs", function()
  it("counts one row per line when not wrapping, however long", function()
    local ed = ed_with(lines(3, 40))
    expect(view.segs(ed, 1)).to.equal(1)
  end)

  -- Not hypothetical: rows_to walks with segs in BOTH modes (the nowrap+folds
  -- branch of refresh), so a nowrap long line counted as several rows makes the
  -- driver scroll early.
  it("keeps a nowrap row walk honest across long lines and folds", function()
    local ed = ed_with(lines(20, 60))
    ex.dispatch(ed, "4,8fold")
    local n, reached = view.rows_to(ed, 1, 0, 12, 0)
    expect(reached).to.be.truthy()
    expect(n).to.equal(7)                          -- 1,2,3,fold,9,10,11 -> 12
  end)

  it("counts wrapped rows against the TEXT width", function()
    local ed = ed_with(lines(3, 20), { opts = { wrap = true } })
    expect(view.segs(ed, 1)).to.equal(2)           -- 20 chars at width 10
    ed.opts.gutter = "git,lint"                    -- 2 cells -> width 8
    expect(view.segs(ed, 1)).to.equal(3)
  end)

  it("counts a closed fold head as one row", function()
    local ed = ed_with(lines(8, 25), { opts = { wrap = true } })
    expect(view.segs(ed, 3)).to.equal(3)
    ex.dispatch(ed, "3,6fold")
    expect(view.segs(ed, 3)).to.equal(1)           -- the summary row
  end)
end)

describe("view.advance", function()
  it("moves whole lines and clamps at both ends when not wrapping", function()
    local ed = ed_with(lines(5))
    expect((view.advance(ed, 2, 0, 2))).to.equal(4)
    expect((view.advance(ed, 2, 0, -5))).to.equal(1)
    expect((view.advance(ed, 2, 0, 99))).to.equal(5)
  end)

  it("moves by screen rows inside a wrapped line", function()
    local ed = ed_with(lines(4, 25), { opts = { wrap = true } })
    local l, sub = view.advance(ed, 1, 0, 2)       -- 25 chars at width 10 = 3 rows
    expect(l).to.equal(1); expect(sub).to.equal(2)
    l, sub = view.advance(ed, 1, 0, 3)             -- one row past: next line
    expect(l).to.equal(2); expect(sub).to.equal(0)
  end)

  it("lands on the last row of the previous line going up", function()
    local ed = ed_with(lines(4, 25), { opts = { wrap = true } })
    local l, sub = view.advance(ed, 2, 0, -1)
    expect(l).to.equal(1); expect(sub).to.equal(2)
  end)

  it("steps over a closed fold as a single row", function()
    local ed = ed_with(lines(8))
    ex.dispatch(ed, "3,6fold")
    expect((view.advance(ed, 2, 0, 2))).to.equal(7)   -- 2 -> head 3 -> 7
  end)
end)

describe("view.rows_to", function()
  it("counts the rows between two screen positions", function()
    local ed = ed_with(lines(6, 25), { opts = { wrap = true } })
    local n, reached = view.rows_to(ed, 1, 0, 3, 1)
    expect(n).to.equal(7)                          -- 3 + 3 rows, then one more
    expect(reached).to.be.truthy()
  end)

  it("stops at `bound` and reports not-reached", function()
    local ed = ed_with(lines(20))
    expect(select(2, view.rows_to(ed, 1, 0, 5, 0, nil, nil, 9))).to.be.truthy()
    -- rows 0..bound-1 are the ones on screen, so a target exactly `bound` rows
    -- down is OFF it. This off-by-one decides whether refresh scrolls.
    expect(select(2, view.rows_to(ed, 1, 0, 10, 0, nil, nil, 9))).to_not.be.truthy()
    expect(select(2, view.rows_to(ed, 1, 0, 9, 0, nil, nil, 9))).to.be.truthy()
  end)

  it("gives up rather than walking past the end of the buffer", function()
    local ed = ed_with(lines(4))
    expect(select(2, view.rows_to(ed, 1, 0, 99, 0))).to_not.be.truthy()
  end)

  -- The phantom edge-wrap row: a cursor past EOL on an exactly-full row sits on
  -- a row the segment walk never produces (disp.locate returns sub == the
  -- segment count). Without the stretch, a walk looking for it steps past the
  -- line and reports the on-screen cursor as off-screen -- bugs 4/5.
  it("finds the phantom edge-wrap row", function()
    local ed = ed_with(lines(6, 10), { mode = "insert", opts = { wrap = true } })
    expect(view.segs(ed, 3)).to.equal(1)           -- exactly one full row
    local n, reached = view.rows_to(ed, 1, 0, 3, 1)  -- sub 1 == the phantom row
    expect(reached).to.be.truthy()
    expect(n).to.equal(3)                          -- rows 0,1,2 then the phantom
  end)

  it("does not stretch a line the target is not on", function()
    local ed = ed_with(lines(6, 10), { opts = { wrap = true } })
    local n = view.rows_to(ed, 1, 0, 4, 0)
    expect(n).to.equal(3)                          -- no phantom row in between
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
