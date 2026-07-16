-- Tests for folding: the pure fold.lua walk, the z-prefix commands and :fold
-- over the coroutine, and the collapsed render. Run: luajit test/fold_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local fold   = require("fold")
local normal = require("normal")
local render = require("render")
local editor = require("editor")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- ---- pure fold.lua walk -----------------------------------------------------
describe("fold.lua (pure)", function()
  -- lines 1..10, one closed fold over 3..6
  local function folds() return { { s = 3, e = 6, open = false } } end

  it("closed_head only matches the head line", function()
    expect(fold.closed_head(folds(), 3)).to.exist()
    expect(fold.closed_head(folds(), 4)).to_not.exist()  -- interior, not a head
    expect(fold.closed_head(folds(), 2)).to_not.exist()
  end)

  it("hidden covers the interior but not the head", function()
    expect(fold.hidden(folds(), 3)).to_not.be.truthy()        -- head stays visible
    expect(fold.hidden(folds(), 4)).to.be.truthy()
    expect(fold.hidden(folds(), 6)).to.be.truthy()
    expect(fold.hidden(folds(), 7)).to_not.be.truthy()
  end)

  it("next_vline steps from the head past the fold end", function()
    expect(fold.next_vline(folds(), 3, 10)).to.equal(7)  -- 3 -> 7 (skip 4,5,6)
    expect(fold.next_vline(folds(), 2, 10)).to.equal(3)  -- 2 -> 3 (the head)
    expect(fold.next_vline(folds(), 7, 10)).to.equal(8)
    expect(fold.next_vline(folds(), 10, 10)).to.equal(nil)
  end)

  it("prev_vline resolves a hidden landing to the head", function()
    expect(fold.prev_vline(folds(), 7, 10)).to.equal(3)  -- 7 -> 3 (skip 6,5,4)
    expect(fold.prev_vline(folds(), 3, 10)).to.equal(2)
    expect(fold.prev_vline(folds(), 1, 10)).to.equal(nil)
  end)

  it("an open fold hides nothing", function()
    local f = { { s = 3, e = 6, open = true } }
    expect(fold.hidden(f, 4)).to_not.be.truthy()
    expect(fold.next_vline(f, 3, 10)).to.equal(4)
  end)

  it("nested folds: outer closed hides the inner head", function()
    local f = { { s = 2, e = 8, open = false }, { s = 4, e = 6, open = false } }
    expect(fold.next_vline(f, 2, 10)).to.equal(9)         -- outer swallows inner
    expect(fold.innermost_closed(f, 5).s).to.equal(4)     -- tightest wins
    expect(fold.innermost(f, 5).s).to.equal(4)
  end)
end)

-- ---- driving the interpreter ------------------------------------------------
local function make(text)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.buf.on_splice = editor.make_splice_hook(ed)       -- so folds shift on edits
  ed.rows, ed.cols = 20, 40
  ed.interp = coroutine.create(function() normal.loop(ed) end)
  assert(coroutine.resume(ed.interp))
  return ed
end
local function feed(ed, s)
  for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
  assert(coroutine.resume(ed.interp))
  return ed
end

local TEXT = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10"

describe("fold commands (normal mode)", function()
  it("zf{motion} creates a closed fold spanning the motion", function()
    local ed = make(TEXT)
    feed(ed, "3G")     -- line 3
    feed(ed, "zf3j")   -- fold lines 3..6
    expect(#ed.folds).to.equal(1)
    expect(ed.folds[1].s).to.equal(3)
    expect(ed.folds[1].e).to.equal(6)
    expect(ed.folds[1].open).to_not.be.truthy()
    expect(ed.cy).to.equal(3)                 -- cursor lands on the fold head
  end)

  it("j steps over a closed fold; k steps back onto its head", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")                        -- fold 3..6, cursor on 3
    feed(ed, "j"); expect(ed.cy).to.equal(7)  -- 3 -> 7, skipping the interior
    feed(ed, "k"); expect(ed.cy).to.equal(3)  -- back onto the head
  end)

  it("zo opens, zc recloses, za toggles", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")
    feed(ed, "zo"); expect(ed.folds[1].open).to.be.truthy()
    feed(ed, "j");  expect(ed.cy).to.equal(4)   -- open: interior is navigable
    feed(ed, "3Gzc"); expect(ed.folds[1].open).to_not.be.truthy()
    feed(ed, "za"); expect(ed.folds[1].open).to.be.truthy()
    feed(ed, "za"); expect(ed.folds[1].open).to_not.be.truthy()
  end)

  it("zO opens every fold covering the cursor (all levels)", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "fold 3,8 3,6")            -- two folds sharing the head line 3
    feed(ed, "3G")
    feed(ed, "zo"); expect(ed.folds[1].open and ed.folds[2].open).to_not.be.truthy() -- zo: one level
    ex.dispatch(ed, "foldclose")               -- reclose both
    feed(ed, "3GzO")
    expect(ed.folds[1].open and ed.folds[2].open).to.be.truthy()                     -- zO: all levels
  end)

  it("zR opens all and zM closes all", function()
    local ed = make(TEXT)
    feed(ed, "1Gzfj")     -- fold 1..2
    feed(ed, "5Gzfj")     -- fold 5..6
    feed(ed, "zR"); expect(ed.folds[1].open and ed.folds[2].open).to.be.truthy()
    feed(ed, "zM"); expect(ed.folds[1].open or ed.folds[2].open).to_not.be.truthy()
  end)

  it("zd deletes the fold at the cursor; zE clears all", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")
    feed(ed, "zd"); expect(#ed.folds).to.equal(0)
    feed(ed, "1Gzfj"); feed(ed, "5Gzfj")
    feed(ed, "zE"); expect(#ed.folds).to.equal(0)
  end)

  it("closing a fold over the cursor snaps the cursor to the head", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")   -- fold 3..6
    feed(ed, "zo")       -- open it
    feed(ed, "5G")       -- cursor deep inside the (open) fold
    feed(ed, "zc")       -- reclose: cursor must leave the hidden interior
    expect(ed.cy).to.equal(3)
  end)
end)

describe("fold edits shift ranges", function()
  it("inserting lines above a fold shifts it down", function()
    local ed = make(TEXT)
    feed(ed, "5Gzfj")                 -- fold 5..6
    feed(ed, "1GO")                   -- open a line above line 1
    feed(ed, "x\27")                  -- type something, leave insert
    expect(ed.folds[1].s).to.equal(6) -- 5 -> 6
    expect(ed.folds[1].e).to.equal(7) -- 6 -> 7
  end)

  it("deleting the whole folded region drops the fold", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")               -- fold 3..6 (4 lines)
    feed(ed, "3G")                   -- head; clamp keeps us visible
    feed(ed, "4dd")                  -- delete lines 3..6 entirely
    expect(#ed.folds).to.equal(0)
  end)
end)

describe("folds and marks/jumps", function()
  it("folding never moves a mark", function()
    local ed = make(TEXT)
    feed(ed, "8Gma")                    -- mark a at line 8
    feed(ed, "3Gzf3j")                  -- fold 3..6 (above the mark)
    expect(ed.marks.a[1]).to.equal(8)   -- folds are a view overlay; marks untouched
  end)

  it("jumping to a mark inside a closed fold snaps to the head (mark kept)", function()
    local ed = make(TEXT)
    feed(ed, "5Gma")                    -- mark a at line 5
    feed(ed, "3Gzf3j")                  -- fold 3..6 -- line 5 now hidden
    feed(ed, "1G`a")                    -- jump to the mark
    expect(ed.cy).to.equal(3)           -- clamp keeps the cursor off a hidden line
    expect(ed.marks.a[1]).to.equal(5)   -- the mark itself is unchanged
  end)

  it("Ctrl-O returns across a fold onto a visible line", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")                  -- fold 3..6, cursor on the head (3)
    feed(ed, "G")                       -- jump to line 10 (records origin 3)
    feed(ed, string.char(15))           -- Ctrl-O back
    expect(ed.cy).to.equal(3)
  end)
end)

describe(":fold ex command", function()
  it("creates a fold over an address range", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "3,6fold")
    expect(#ed.folds).to.equal(1)
    expect(ed.folds[1].s).to.equal(3)
    expect(ed.folds[1].e).to.equal(6)
  end)

  it("accepts multiple L1,L2 specs in args (the socket/tool form)", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "fold 1,2 5,7")
    expect(#ed.folds).to.equal(2)
    expect(ed.folds[2].s).to.equal(5)
    expect(ed.folds[2].e).to.equal(7)
  end)

  it("foldopen/foldclose/foldclear act on all folds", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "fold 1,2 5,7")
    ex.dispatch(ed, "foldopen")
    expect(ed.folds[1].open and ed.folds[2].open).to.be.truthy()
    ex.dispatch(ed, "foldclose")
    expect(ed.folds[1].open or ed.folds[2].open).to_not.be.truthy()
    ex.dispatch(ed, "foldclear")
    expect(#ed.folds).to.equal(0)
  end)

  it("foldset replaces the set, preserving open state of surviving ranges", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "fold 1,2 5,7")
    ed.folds[2].open = true                      -- the user opened 5,7 (zo)
    ex.dispatch(ed, "foldset 5,7 9,10")          -- re-push: 1,2 gone, 9,10 new
    expect(#ed.folds).to.equal(2)
    expect(ed.folds[1].s).to.equal(5)
    expect(ed.folds[1].open).to.be.truthy()      -- survived the replace: still open
    expect(ed.folds[2].s).to.equal(9)
    expect(ed.folds[2].open).to_not.be.truthy()  -- new fold: arrives closed
  end)

  it("foldset with no specs clears every fold", function()
    local ed = make(TEXT)
    ex.dispatch(ed, "fold 1,2 5,7")
    ex.dispatch(ed, "foldset")
    expect(#ed.folds).to.equal(0)
  end)
end)

describe("foldenable toggle (zi / :set)", function()
  it("zi disables folding: interior navigable, folds kept intact", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")                        -- fold 3..6, cursor on head 3
    feed(ed, "zi")                            -- stop honoring folds
    expect(ed.opts.foldenable).to_not.be.truthy()
    feed(ed, "j"); expect(ed.cy).to.equal(4)  -- former interior is now navigable
    expect(#ed.folds).to.equal(1)             -- the fold itself is untouched
    expect(ed.folds[1].open).to_not.be.truthy()
  end)

  it("re-enabling with zi snaps the cursor off a now-hidden line", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")
    feed(ed, "zi"); feed(ed, "5G")            -- disable, park deep in the (closed) range
    expect(ed.cy).to.equal(5)
    feed(ed, "zi")                            -- honor folds again
    expect(ed.opts.foldenable).to.be.truthy()
    expect(ed.cy).to.equal(3)                 -- clamp snaps back onto the visible head
  end)

  it(":set nofoldenable makes j ignore the fold; :set fen? reports state", function()
    local ed = make(TEXT)
    feed(ed, "3Gzf3j")
    ex.dispatch(ed, "set nofoldenable")
    feed(ed, "3Gj"); expect(ed.cy).to.equal(4)
    local rep = ex.dispatch(ed, "set fen?")
    expect(rep).to.equal("nofoldenable")
    ex.dispatch(ed, "set foldenable")
    expect(ex.dispatch(ed, "set fen?")).to.equal("foldenable")
  end)
end)

-- ---- render -----------------------------------------------------------------
local function render_ed(text, wrap)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.rows, ed.cols = 12, 40
  ed.opts.wrap = wrap and true or false
  return ed
end

describe("render collapses closed folds", function()
  it("draws a summary row and hides the interior (nowrap)", function()
    local ed = render_ed(TEXT, false)
    ed.folds = { { s = 3, e = 6, open = false } }
    local f = render.frame(ed)
    expect(f:find("4 lines", 1, true)).to.exist()   -- e - s + 1 = 4
    expect(f:find("l3", 1, true)).to.exist()        -- head text is shown
    expect(f:find("l4", 1, true)).to_not.exist()    -- interior hidden
    expect(f:find("l5", 1, true)).to_not.exist()
    expect(f:find("l7", 1, true)).to.exist()        -- resumes after the fold
  end)

  -- Regression: a fold running to the LAST buffer line. next_vline correctly
  -- returns nil at EOF; the walk must stop, not fall through to l+1 and redraw
  -- the hidden interior (the `x and next_vline() or l+1` idiom bit exactly here).
  it("hides the interior of a fold that ends on the last line (nowrap)", function()
    local ed = render_ed(TEXT, false)                -- TEXT is l1..l10
    ed.folds = { { s = 8, e = 10, open = false } }   -- fold to EOF
    local f = render.frame(ed)
    expect(f:find("3 lines", 1, true)).to.exist()    -- summary drawn
    expect(f:find("l8", 1, true)).to.exist()         -- head visible
    expect(f:find("l9", 1, true)).to_not.exist()     -- interior hidden
    expect(f:find("l10", 1, true)).to_not.exist()
  end)

  it("hides the interior of a fold that ends on the last line (wrap)", function()
    local ed = render_ed(TEXT, true)
    ed.folds = { { s = 8, e = 10, open = false } }
    local f = render.frame(ed)
    expect(f:find("3 lines", 1, true)).to.exist()
    expect(f:find("l9", 1, true)).to_not.exist()
    expect(f:find("l10", 1, true)).to_not.exist()
  end)

  it("hides the interior in wrap mode too", function()
    local ed = render_ed(TEXT, true)
    ed.folds = { { s = 3, e = 6, open = false } }
    local f = render.frame(ed)
    expect(f:find("4 lines", 1, true)).to.exist()
    expect(f:find("l4", 1, true)).to_not.exist()
    expect(f:find("l7", 1, true)).to.exist()
  end)

  it("an open fold renders every line normally", function()
    local ed = render_ed(TEXT, false)
    ed.folds = { { s = 3, e = 6, open = true } }
    local f = render.frame(ed)
    expect(f:find("l4", 1, true)).to.exist()
    expect(f:find("lines:", 1, true)).to_not.exist()
  end)

  it("nofoldenable renders every line even with a closed fold present", function()
    local ed = render_ed(TEXT, false)
    ed.folds = { { s = 3, e = 6, open = false } }
    ed.opts.foldenable = false
    local f = render.frame(ed)
    expect(f:find("lines:", 1, true)).to_not.exist()  -- no summary row
    expect(f:find("l4", 1, true)).to.exist()          -- interior shown
    expect(f:find("l5", 1, true)).to.exist()
  end)

  it("themes the marker via the Folded group (:hi Folded ...)", function()
    local ed = render_ed(TEXT, false)
    ed.folds = { { s = 3, e = 6, open = false } }
    ed.hlstyles["Folded"] = "7"                     -- reverse video
    local f = render.frame(ed)
    expect(f:find("\27%[7m")).to.exist()            -- SGR opened around the row
    expect(f:find("4 lines", 1, true)).to.exist()
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
