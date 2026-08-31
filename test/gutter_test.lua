-- Tests for gutter.lua and its wiring. Run: luajit test/gutter_test.lua
--
-- The centerpiece is the INVARIANCE property at the bottom: a gutter g columns
-- wide must behave exactly like a terminal g columns narrower. That is the whole
-- claim the spike rests on -- if the row->column offset had leaked out of
-- gutter.width/textw into the wrap, scroll or fold arithmetic, these pairs would
-- diverge, and no amount of "the frame looks right" would catch it.
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local editor = require("editor")
local render = require("render")
local normal = require("normal")
local gutter = require("gutter")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function ed_with(text, over)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.rows, ed.cols = 5, 20
  ed.opts.wrap = false
  for k, v in pairs(over or {}) do
    if k == "opts" then for ok, ov in pairs(v) do ed.opts[ok] = ov end else ed[k] = v end
  end
  return ed
end

describe("gutter geometry", function()
  it("is absent by default -- text still starts at screen column 1", function()
    local ed = ed_with("hello")
    expect(gutter.width(ed)).to.equal(0)
    expect(gutter.textw(ed)).to.equal(20)
  end)

  it("a tool column is one cell; several add up in order", function()
    local ed = ed_with("hello", { opts = { gutter = "git,lint,mark" } })
    expect(gutter.width(ed)).to.equal(3)
    expect(gutter.textw(ed)).to.equal(17)
  end)

  it("a number column follows the buffer's line count", function()
    local ed = ed_with("a\nb\nc", { opts = { gutter = "number" } })
    expect(gutter.width(ed)).to.equal(4)                      -- 3 digits + separator
    local big = {}
    for i = 1, 1200 do big[i] = "x" end
    local ed2 = ed_with(table.concat(big, "\n"), { opts = { gutter = "number" } })
    expect(gutter.width(ed2)).to.equal(5)                     -- 4 digits + separator
  end)

  it("number and relativenumber are one column, not two", function()
    local ed = ed_with("a\nb\nc", { opts = { gutter = "number,relativenumber" } })
    expect(gutter.width(ed)).to.equal(4)
    expect(#gutter.names(ed)).to.equal(1)
  end)

  it("never eats the whole screen: text keeps at least one column", function()
    local ed = ed_with("a\nb\nc", { cols = 3, opts = { gutter = "number,git,lint" } })
    expect(gutter.width(ed)).to.equal(2)
    expect(gutter.textw(ed)).to.equal(1)
  end)
end)

describe(":set gutter", function()
  it("sets, queries and clears the column list", function()
    local ed = ed_with("x")
    expect(select(2, ex.dispatch(ed, "set gutter=number,git"))).to.equal("ok")
    expect(ed.opts.gutter).to.equal("number,git")
    expect(ex.dispatch(ed, "set gutter?")).to.equal("gutter=number,git")
    ex.dispatch(ed, "set gutter=")
    expect(ed.opts.gutter).to.equal("")
    expect(gutter.width(ed)).to.equal(0)
  end)

  it("still parses alongside other options on one line", function()
    local ed = ed_with("x")
    ex.dispatch(ed, "set gutter=git ts=4")
    expect(ed.opts.gutter).to.equal("git")
    expect(ed.opts.tabstop).to.equal(4)
  end)
end)

-- POSIX vi specifies `number`; lvi defines it onto the column list rather than
-- carrying a second flag that could disagree with `set gutter=`.
describe(":set number (POSIX)", function()
  it("adds and removes the numeric column", function()
    local ed = ed_with("a\nb")
    ex.dispatch(ed, "set number")
    expect(ed.opts.gutter).to.equal("number")
    expect(gutter.width(ed)).to.equal(4)
    ex.dispatch(ed, "set nonumber")
    expect(ed.opts.gutter).to.equal("")
    expect(gutter.width(ed)).to.equal(0)
  end)

  it("puts the number innermost, next to the text", function()
    local ed = ed_with("a\nb", { opts = { gutter = "git,lint" } })
    ex.dispatch(ed, "set nu")
    expect(ed.opts.gutter).to.equal("git,lint,number")
  end)

  it("swaps relativenumber in place without moving the margin", function()
    local ed = ed_with("a\nb", { opts = { gutter = "number,lint" } })
    ex.dispatch(ed, "set relativenumber")
    expect(ed.opts.gutter).to.equal("relativenumber,lint")
    ex.dispatch(ed, "set nu")
    expect(ed.opts.gutter).to.equal("number,lint")
  end)

  it("removes either spelling with nonumber", function()
    local ed = ed_with("a\nb", { opts = { gutter = "rnu,lint" } })
    ex.dispatch(ed, "set nonumber")
    expect(ed.opts.gutter).to.equal("lint")
  end)

  it("queries and toggles", function()
    local ed = ed_with("a\nb")
    expect(ex.dispatch(ed, "set number?")).to.equal("nonumber")
    ex.dispatch(ed, "set number!")
    expect(ex.dispatch(ed, "set number?")).to.equal("number")
    expect(ex.dispatch(ed, "set rnu?")).to.equal("norelativenumber")
    ex.dispatch(ed, "set rnu!")
    expect(ex.dispatch(ed, "set number?")).to.equal("nonumber")
    expect(ex.dispatch(ed, "set relativenumber?")).to.equal("relativenumber")
  end)

  it("leaves set gutter= and set number telling one story", function()
    local ed = ed_with("a\nb")
    ex.dispatch(ed, "set gutter=number,git")
    expect(ex.dispatch(ed, "set number?")).to.equal("number")
    ex.dispatch(ed, "set nonumber")
    expect(ex.dispatch(ed, "set gutter?")).to.equal("gutter=git")
  end)
end)

describe(":gutter marks", function()
  it("pushes marks and replaces the whole column per push", function()
    local ed = ed_with("a\nb\nc\nd")
    expect(select(2, ex.dispatch(ed, "gutter lint 2:E 4:W"))).to.equal("ok")
    expect(ed.gutters.lint[2].ch).to.equal("E")
    expect(ed.gutters.lint[4].ch).to.equal("W")
    ex.dispatch(ed, "gutter lint 3:X")
    expect(ed.gutters.lint[2]).to_not.exist()               -- replaced, not merged
    expect(ed.gutters.lint[3].ch).to.equal("X")
  end)

  it("clears a column with no specs", function()
    local ed = ed_with("a\nb")
    ex.dispatch(ed, "gutter lint 1:E")
    ex.dispatch(ed, "gutter lint")
    expect(next(ed.gutters.lint)).to_not.exist()
  end)

  it("defaults a mark's group to the column name, or takes one per mark", function()
    local ed = ed_with("a\nb\nc")
    ex.dispatch(ed, "gutter git 1:+:GitAdd 2:-:GitDel 3:~")
    expect(ed.gutters.git[1].group).to.equal("GitAdd")
    expect(ed.gutters.git[2].group).to.equal("GitDel")
    expect(ed.gutters.git[3].group).to.equal("git")         -- falls back to the column
  end)

  -- Found by the live lvi-list demo: its current-entry group is `<name>-cur`,
  -- and a group name is an unrestricted %S+ everywhere else in lvi.
  it("takes a hyphen in a mark's group name", function()
    local ed = ed_with("a")
    ex.dispatch(ed, "gutter lint 1:E:lint-cur")
    expect(ed.gutters.lint[1].ch).to.equal("E")
    expect(ed.gutters.lint[1].group).to.equal("lint-cur")
  end)

  -- lvi-list does not restrict a list name, and its current-entry group is
  -- `<name>-cur`, so a group starting with a digit is one a producer will send.
  -- Rejecting it did not error: the whole tail became the glyph, silently.
  it("takes a digit at the front of a mark's group name", function()
    local ed = ed_with("a")
    ex.dispatch(ed, "gutter 2fixme 1:>:2fixme-cur")
    expect(ed.gutters["2fixme"][1].ch).to.equal(">")
    expect(ed.gutters["2fixme"][1].group).to.equal("2fixme-cur")
  end)

  it("takes ':' itself as a mark", function()
    local ed = ed_with("a")
    ex.dispatch(ed, "gutter m 1::")
    expect(ed.gutters.m[1].ch).to.equal(":")
  end)

  it("rejects a malformed spec and a comma in a column name", function()
    local ed = ed_with("a")
    expect(select(2, ex.dispatch(ed, "gutter lint nope"))).to.equal("err")
    expect(select(2, ex.dispatch(ed, "gutter a,b 1:X"))).to.equal("err")
  end)
end)

describe("gutter rendering", function()
  it("draws right-aligned line numbers before the text", function()
    local ed = ed_with("hello\nworld", { opts = { gutter = "number" } })
    local f = render.frame(ed)
    expect(f:find("  1 hello", 1, true)).to.exist()
    expect(f:find("  2 world", 1, true)).to.exist()
  end)

  it("relativenumber counts from the cursor and shows it absolutely", function()
    local ed = ed_with("a\nb\nc\nd", { cy = 3, opts = { gutter = "relativenumber" } })
    local f = render.frame(ed)
    expect(f:find("  2 a", 1, true)).to.exist()
    expect(f:find("  1 b", 1, true)).to.exist()
    expect(f:find("  3 c", 1, true)).to.exist()             -- the cursor line: absolute
    expect(f:find("  1 d", 1, true)).to.exist()
  end)

  it("draws a tool column's marks and blanks the unmarked lines", function()
    local ed = ed_with("a\nb\nc", { opts = { gutter = "lint" } })
    ex.dispatch(ed, "gutter lint 2:E")
    local f = render.frame(ed)
    expect(f:find("Eb", 1, true)).to.exist()
    expect(f:find(" a", 1, true)).to.exist()
  end)

  it("styles a mark by its group, like the :hl overlay", function()
    local ed = ed_with("a\nb", { opts = { gutter = "git" } })
    ex.dispatch(ed, "hi GitAdd fg=green")
    ex.dispatch(ed, "gutter git 1:+:GitAdd")
    expect(render.frame(ed):find("\27[32m+", 1, true)).to.exist()
  end)

  it("leaves an un-themed column plain, like an un-themed group", function()
    local ed = ed_with("a\nb", { opts = { gutter = "git" } })
    ex.dispatch(ed, "gutter git 1:+")
    -- clr_eol runs straight into the mark: no SGR opened in between.
    expect(render.frame(ed):find("\27[K+a", 1, true)).to.exist()
  end)

  it("leaves an UNMARKED cell unstyled, so a bg= column is not a solid bar", function()
    local ed = ed_with("a\nb", { opts = { gutter = "lint" } })
    ex.dispatch(ed, "hi lint bg=red")
    ex.dispatch(ed, "gutter lint 1:E")
    local f = render.frame(ed)
    expect(f:find("\27[41mE", 1, true)).to.exist()
    expect(f:find("\27[K b", 1, true)).to.exist()          -- line 2's cell: plain blank
  end)

  it("blanks the gutter on wrapped continuation rows and on ~ fillers", function()
    local ed = ed_with("abcdefghij\nz", { rows = 5, cols = 9,
      opts = { wrap = true, gutter = "number" } })
    local f = render.frame(ed)
    expect(f:find("  1 abcde", 1, true)).to.exist()
    expect(f:find("    fghij", 1, true)).to.exist()         -- continuation: no number
    expect(f:find("    ~", 1, true)).to.exist()             -- filler: no number
  end)

  it("numbers a closed fold's summary row with its head line", function()
    local ed = ed_with("a\nb\nc\nd", { opts = { gutter = "number" } })
    ex.dispatch(ed, "2,3fold")
    expect(render.frame(ed):find("  2 +--", 1, true)).to.exist()
  end)

  it("offsets the cursor's screen column by the gutter width", function()
    local plain = ed_with("hello", { cx = 3 })
    local gut   = ed_with("hello", { cx = 3, opts = { gutter = "git,lint" } })
    local function ccol(f)                       -- the last cursor placement wins
      local c
      for n in f:gmatch("\27%[%d+;(%d+)H") do c = n end
      return tonumber(c)
    end
    expect(ccol(render.frame(gut))).to.equal(ccol(render.frame(plain)) + 2)
  end)
end)

-- The property the spike is really testing. Each case runs the same scenario
-- twice: once on a screen W columns wide with no gutter, once on a screen W+g
-- wide with a g-column gutter. Every view coordinate must come out identical.
describe("a gutter of width g == a screen g columns narrower", function()
  local GUT, G = "a,b,c", 3                    -- three tool columns: a fixed width

  local function pair(text, over)
    local plain = ed_with(text, over)
    local gut = ed_with(text, over)
    gut.opts.gutter = GUT
    gut.cols = plain.cols + G
    expect(gutter.textw(gut)).to.equal(plain.cols)          -- the harness itself
    return plain, gut
  end

  local function same(plain, gut)
    expect(gut.cy).to.equal(plain.cy)
    expect(gut.cx).to.equal(plain.cx)
    expect(gut.top).to.equal(plain.top)
    expect(gut.topsub).to.equal(plain.topsub)
    expect(gut.leftcol).to.equal(plain.leftcol)
  end

  local function both(plain, gut, fn) fn(plain); fn(gut) end

  it("nowrap horizontal scroll lands on the same leftcol", function()
    local plain, gut = pair("0123456789abcdefghij", { cx = 18, cols = 6 })
    both(plain, gut, editor.refresh)
    same(plain, gut)
  end)

  it("wrap scrolls to the same sub-row inside a tall line", function()
    local plain, gut = pair(("x"):rep(40), { cx = 40, rows = 3, cols = 8,
      opts = { wrap = true } })
    both(plain, gut, editor.refresh)
    same(plain, gut)
  end)

  -- The scarred path: a cursor past EOL on an exactly-full row sits on the
  -- phantom edge-wrap row. "Exactly full" is measured against the TEXT width, so
  -- this is precisely where a leaked ed.cols would show up.
  it("agrees on the phantom edge-wrap row (bugs 4/5)", function()
    local t = {}
    for i = 1, 40 do t[i] = (i == 25) and ("x"):rep(10) or "s" end
    local plain, gut = pair(table.concat(t, "\n"), { rows = 12, cols = 10,
      mode = "insert", opts = { wrap = true } })
    both(plain, gut, function(ed) ed.cy, ed.cx, ed.top, ed.topsub = 25, 11, 20, 0 end)
    both(plain, gut, editor.refresh)
    same(plain, gut)
  end)

  it("agrees on the last-row phantom edge-wrap", function()
    local t = {}
    for i = 1, 40 do t[i] = (i == 11) and ("x"):rep(10) or "s" end
    local plain, gut = pair(table.concat(t, "\n"), { rows = 12, cols = 10,
      mode = "insert", opts = { wrap = true } })
    both(plain, gut, function(ed) ed.cy, ed.cx, ed.top, ed.topsub = 11, 11, 1, 0 end)
    both(plain, gut, editor.refresh)
    same(plain, gut)
  end)

  local function feed(ed, s)
    ed.interp = ed.interp or (function()
      local co = coroutine.create(function() normal.loop(ed) end)
      assert(coroutine.resume(co)); return co
    end)()
    for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
    assert(coroutine.resume(ed.interp))
  end

  it("gj steps to the same byte on a wrapped line", function()
    local plain, gut = pair("hello world", { cols = 8, opts = { wrap = true } })
    both(plain, gut, function(ed) feed(ed, "gj") end)
    same(plain, gut)
  end)

  it("gj under linebreak agrees too", function()
    local plain, gut = pair("hello world", { cols = 8,
      opts = { wrap = true, linebreak = true } })
    both(plain, gut, function(ed) feed(ed, "gj") end)
    same(plain, gut)
  end)

  it("Ctrl-D scrolls the same number of screen rows", function()
    local t = {}
    for i = 1, 60 do t[i] = ("y"):rep(i % 17) end
    local plain, gut = pair(table.concat(t, "\n"), { rows = 10, cols = 12,
      opts = { wrap = true } })
    both(plain, gut, function(ed) feed(ed, "\4\4"); editor.refresh(ed) end)
    same(plain, gut)
  end)

  it("Ctrl-E/Ctrl-Y agree with folds in the way", function()
    local t = {}
    for i = 1, 60 do t[i] = ("z"):rep(i % 23) end
    local plain, gut = pair(table.concat(t, "\n"), { rows = 8, cols = 14,
      opts = { wrap = true } })
    both(plain, gut, function(ed)
      ex.dispatch(ed, "10,20fold")
      feed(ed, "\5\5\5\5"); editor.refresh(ed)
    end)
    same(plain, gut)
  end)

  it("H/M/L land on the same line", function()
    local t = {}
    for i = 1, 60 do t[i] = ("w"):rep(i % 31) end
    local plain, gut = pair(table.concat(t, "\n"), { rows = 9, cols = 11,
      opts = { wrap = true } })
    both(plain, gut, function(ed) feed(ed, "\6L"); editor.refresh(ed) end)
    same(plain, gut)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
