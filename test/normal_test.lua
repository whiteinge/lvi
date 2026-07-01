-- Tests for normal.lua (the coroutine interpreter). Run: luajit test/normal_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local normal = require("normal")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- Build an editor state with a live interpreter coroutine, primed to getkey.
local function make(text)
  local ed = { buf = buffer.new(text), cx = 1, cy = 1, top = 1, rows = 24,
    cols = 80, mode = "normal", cmdline = "", message = nil,
    inject = {}, pending = {}, keylog = {}, regs = {}, marks = {}, running = true }
  ed.interp = coroutine.create(function() normal.loop(ed) end)
  assert(coroutine.resume(ed.interp))
  return ed
end

-- Feed a string of keys and let the coroutine drain them.
local function feed(ed, s)
  for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
  assert(coroutine.resume(ed.interp))
  return ed
end

local ESC = "\27"

describe("normal-mode interpreter", function()
  describe("motions", function()
    it("h j k l 0 $ move the cursor", function()
      local ed = make("abc\ndef")
      feed(ed, "ll"); expect(ed.cx).to.equal(3)
      feed(ed, "0");  expect(ed.cx).to.equal(1)
      feed(ed, "$");  expect(ed.cx).to.equal(3)
      feed(ed, "j");  expect(ed.cy).to.equal(2)
      feed(ed, "k");  expect(ed.cy).to.equal(1)
    end)
    it("honors a count", function()
      local ed = make("abcdef")
      feed(ed, "3l"); expect(ed.cx).to.equal(4)
    end)
    it("G goes to a line or the last line", function()
      local ed = make("a\nb\nc\nd")
      feed(ed, "G");  expect(ed.cy).to.equal(4)
      feed(ed, "2G"); expect(ed.cy).to.equal(2)
    end)
    it("w b e move by word within a line", function()
      local ed = make("foo bar baz")
      feed(ed, "w"); expect(ed.cx).to.equal(5)   -- start of 'bar'
      feed(ed, "e"); expect(ed.cx).to.equal(7)   -- end of 'bar'
      feed(ed, "b"); expect(ed.cx).to.equal(5)   -- back to start of 'bar'
    end)
  end)

  describe("find motions f t F T ; ,", function()
    it("f moves to the char; ; and , repeat", function()
      local ed = make("a.b.c")
      feed(ed, "f."); expect(ed.cx).to.equal(2)
      feed(ed, ";"); expect(ed.cx).to.equal(4)
      feed(ed, ","); expect(ed.cx).to.equal(2)
    end)
    it("t moves till before the char", function()
      local ed = make("xxx.y")
      feed(ed, "t."); expect(ed.cx).to.equal(3)
    end)
    it("F searches backward", function()
      local ed = make("a.b.c")
      feed(ed, "$F."); expect(ed.cx).to.equal(4)
    end)
    it("df deletes through the char (inclusive)", function()
      local ed = make("hello")
      feed(ed, "dfl"); expect(ed.buf:line(1)).to.equal("lo")
    end)
  end)

  describe("gg and marks", function()
    it("G then gg", function()
      local ed = make("a\nb\nc\nd")
      feed(ed, "G"); expect(ed.cy).to.equal(4)
      feed(ed, "gg"); expect(ed.cy).to.equal(1)
    end)
    it("dgg deletes to the first line (linewise)", function()
      local ed = make("a\nb\nc")
      feed(ed, "jdgg")                       -- from line 2, delete lines 1..2
      expect(ed.buf:get()).to.equal({ "c" })
    end)
    it("sets and jumps to a mark exactly (`)", function()
      local ed = make("hello\nworld")
      feed(ed, "ma"); feed(ed, "jl")
      expect(ed.cy).to.equal(2)
      feed(ed, "`a")
      expect(ed.cy).to.equal(1); expect(ed.cx).to.equal(1)
    end)
    it("'mark jumps to the mark's line", function()
      local ed = make("one\ntwo\nthree")
      feed(ed, "jma"); feed(ed, "G")         -- mark a at line 2, cursor to line 3
      feed(ed, "'a"); expect(ed.cy).to.equal(2)
    end)
  end)

  describe("UTF-8", function()
    local E = "\195\169" -- 'é', 2 bytes, 1 cell
    it("h and l move by character across multibyte", function()
      local ed = make("a" .. E .. "b")
      feed(ed, "l"); expect(ed.cx).to.equal(2)   -- onto é
      feed(ed, "l"); expect(ed.cx).to.equal(4)   -- skipped é's 2 bytes, onto b
      feed(ed, "h"); expect(ed.cx).to.equal(2)   -- back onto é
    end)
    it("x deletes a whole multibyte char", function()
      local ed = make("a" .. E .. "b")
      feed(ed, "lx")
      expect(ed.buf:line(1)).to.equal("ab")
    end)
    it("inserts a multibyte char typed as its bytes", function()
      local ed = make("ab")
      feed(ed, "i" .. E .. "\27")
      expect(ed.buf:line(1)).to.equal(E .. "ab")
    end)
  end)

  describe("| (goto column)", function()
    it("moves to a display column", function()
      local ed = make("abcdef")
      feed(ed, "4|"); expect(ed.cx).to.equal(4)
      feed(ed, "|"); expect(ed.cx).to.equal(1)   -- no count -> column 1
    end)
  end)

  describe("gj / gk (screen-line motion)", function()
    it("gj == j when wrap is off", function()
      local ed = make("a\nb\nc")               -- no opts -> nowrap
      feed(ed, "gj"); expect(ed.cy).to.equal(2)
    end)
    it("gj/gk move by sub-row within a wrapped line", function()
      local ed = make("abcdefgh\nxyz")
      ed.opts = { wrap = true, tabstop = 8 }; ed.cols = 4  -- "abcdefgh" -> abcd/efgh
      feed(ed, "gj")                                       -- into the 2nd sub-row
      expect(ed.cy).to.equal(1); expect(ed.cx).to.equal(5) -- 'e'
      feed(ed, "gj")                                       -- across to the next line
      expect(ed.cy).to.equal(2); expect(ed.cx).to.equal(1)
      feed(ed, "gk")                                       -- back up one screen row
      expect(ed.cy).to.equal(1); expect(ed.cx).to.equal(5)
    end)
  end)

  describe("cross-line word motion", function()
    it("w crosses to the next line", function()
      local ed = make("foo\nbar")
      feed(ed, "w"); expect(ed.cy).to.equal(2); expect(ed.cx).to.equal(1)
    end)
    it("b crosses to the previous line", function()
      local ed = make("foo\nbar")
      feed(ed, "j0b"); expect(ed.cy).to.equal(1)
    end)
    it("dw on the last word of a line stops at the newline", function()
      local ed = make("foo\nbar")
      feed(ed, "dw"); expect(ed.buf:get()).to.equal({ "", "bar" })
    end)
  end)

  describe("operator + motion composition", function()
    it("dw deletes to the next word", function()
      local ed = make("foo bar")
      feed(ed, "dw")
      expect(ed.buf:line(1)).to.equal("bar")
      expect(ed.regs['"'].text).to.equal("foo ")
    end)
    it("d$ deletes to end of line (inclusive)", function()
      local ed = make("hello")
      feed(ed, "lld$")                            -- from col 3
      expect(ed.buf:line(1)).to.equal("he")
    end)
    it("dd / 2dd delete whole lines (linewise)", function()
      local ed = make("a\nb\nc\nd")
      feed(ed, "dd")
      expect(ed.buf:get()).to.equal({ "b", "c", "d" })
      feed(ed, "2dd")
      expect(ed.buf:get()).to.equal({ "d" })
      expect(ed.regs['"'].linewise).to.be(true)
    end)
  end)

  describe("edit + registers + put", function()
    it("x deletes the char under the cursor", function()
      local ed = make("abc")
      feed(ed, "x")
      expect(ed.buf:line(1)).to.equal("bc")
      expect(ed.regs['"'].text).to.equal("a")
    end)
    it("yy then p duplicates a line below", function()
      local ed = make("a\nb")
      feed(ed, "yyp")
      expect(ed.buf:get()).to.equal({ "a", "a", "b" })
      expect(ed.cy).to.equal(2)
    end)
    it("uses a named register", function()
      local ed = make("keep\ntoss")
      feed(ed, '"ayy')
      expect(ed.regs['a'].text).to.equal("keep\n")
      feed(ed, 'j"ap')                            -- put reg a below line 2
      expect(ed.buf:get()).to.equal({ "keep", "toss", "keep" })
    end)
  end)

  describe("insert mode", function()
    it("i inserts before the cursor", function()
      local ed = make("bc")
      feed(ed, "iA" .. ESC)
      expect(ed.buf:line(1)).to.equal("Abc")
      expect(ed.mode).to.equal("normal")
    end)
    it("a appends after the cursor", function()
      local ed = make("ac")
      feed(ed, "ab" .. ESC)
      expect(ed.buf:line(1)).to.equal("abc")
    end)
    it("o opens a line below and inserts", function()
      local ed = make("a\nc")
      feed(ed, "ob" .. ESC)
      expect(ed.buf:get()).to.equal({ "a", "b", "c" })
    end)
    it("<CR> in insert mode splits the line", function()
      local ed = make("ab")
      feed(ed, "i" .. "\r" .. ESC)
      expect(ed.buf:get()).to.equal({ "", "ab" })
    end)
    it("cc changes a whole line", function()
      local ed = make("old\nkeep")
      feed(ed, "ccnew" .. ESC)
      expect(ed.buf:get()).to.equal({ "new", "keep" })
    end)
    it("records the last change for a future '.'", function()
      local ed = make("x")
      feed(ed, "iZ" .. ESC)
      expect(ed.last_change).to.exist()
    end)
  end)

  describe("'.' repeat", function()
    it("repeats the last change (delete)", function()
      local ed = make("abcde")
      feed(ed, "x")                       -- delete 'a' -> "bcde"
      feed(ed, ".")                       -- repeat -> "cde"
      expect(ed.buf:line(1)).to.equal("cde")
    end)
    it("repeats an insertion", function()
      local ed = make("Z")
      feed(ed, "ix" .. ESC)               -- "xZ", cursor on 'x'
      feed(ed, ".")                       -- insert 'x' again before cursor
      expect(ed.buf:line(1)).to.equal("xxZ")
    end)
  end)

  describe("maps", function()
    it("expands a leader map to its RHS", function()
      local ed = make("a\nb\nc")
      ex.dispatch(ed, "map \\d dd")            -- \d -> delete line
      feed(ed, "\\d")
      expect(ed.buf:get()).to.equal({ "b", "c" })
    end)
    it("is non-recursive (RHS keys are not re-mapped)", function()
      local ed = make("abc\ndef")
      ex.dispatch(ed, "map d x")                -- d -> x (delete char)
      ex.dispatch(ed, "map x dd")              -- x -> dd (should NOT fire from d's RHS)
      feed(ed, "d")
      expect(ed.buf:line(1)).to.equal("bc")    -- one char deleted, not the line
      expect(ed.buf:nlines()).to.equal(2)
    end)
    it("parses <...> notation and unmaps", function()
      local ed = make("hello")
      ex.dispatch(ed, "map <Space>x x")         -- <Space>x -> delete char (proves <Space> parse)
      feed(ed, " x")
      expect(ed.buf:line(1)).to.equal("ello")
      ex.dispatch(ed, "unmap <Space>x")
      expect(ed.maps[" x"]).to_not.exist()      -- map removed
    end)
    it("a map RHS can drive an ex command", function()
      local ed = make("x\ny\nz")
      ex.dispatch(ed, "map \\l :2d<CR>")        -- \l -> :2d
      feed(ed, "\\l")
      expect(ed.buf:get()).to.equal({ "x", "z" })
    end)
  end)

  describe("undo / redo", function()
    it("u undoes the last change; Ctrl-R redoes it", function()
      local ed = make("abc")
      feed(ed, "x"); expect(ed.buf:line(1)).to.equal("bc")
      feed(ed, "u"); expect(ed.buf:line(1)).to.equal("abc")
      feed(ed, "\18"); expect(ed.buf:line(1)).to.equal("bc")  -- Ctrl-R
    end)
    it("undoes a whole insert session as one change", function()
      local ed = make("x")
      feed(ed, "iAB" .. ESC); expect(ed.buf:line(1)).to.equal("ABx")
      feed(ed, "u"); expect(ed.buf:line(1)).to.equal("x")
    end)
    it("undoes commands one at a time", function()
      local ed = make("abc")
      feed(ed, "xx"); expect(ed.buf:line(1)).to.equal("c")
      feed(ed, "u"); expect(ed.buf:line(1)).to.equal("bc")
      feed(ed, "u"); expect(ed.buf:line(1)).to.equal("abc")
    end)
    it("undoes a dd", function()
      local ed = make("a\nb\nc")
      feed(ed, "dd"); expect(ed.buf:get()).to.equal({ "b", "c" })
      feed(ed, "u"); expect(ed.buf:get()).to.equal({ "a", "b", "c" })
    end)
    it("a status message survives until the next command's key", function()
      local ed = make("a")
      feed(ed, "u")                              -- nothing to undo -> sets a message
      expect(ed.message).to.equal("Already at oldest change")
      feed(ed, "j")                              -- next command clears it
      expect(ed.message).to_not.exist()
    end)
  end)

  describe("macros", function()
    it("records into a register and replays with @", function()
      local ed = make("a\nb\nc\nd")
      feed(ed, "qaddq")                    -- record 'dd' into reg a (deletes 'a')
      expect(ed.regs['a'].text).to.equal("dd")
      expect(ed.buf:get()).to.equal({ "b", "c", "d" })
      feed(ed, "@a")                       -- replay -> deletes 'b'
      expect(ed.buf:get()).to.equal({ "c", "d" })
    end)
    it("honors a count on @", function()
      local ed = make("1\n2\n3\n4\n5")
      feed(ed, "qxddq")                    -- reg x = 'dd', deletes '1'
      feed(ed, "2@x")                      -- delete two more lines
      expect(ed.buf:get()).to.equal({ "4", "5" })
    end)
    it("@@ repeats the last macro", function()
      local ed = make("1\n2\n3\n4")
      feed(ed, "qaddq")                    -- {2,3,4}
      feed(ed, "@a")                       -- {3,4}
      feed(ed, "@@")                       -- {4}
      expect(ed.buf:get()).to.equal({ "4" })
    end)
    it("records a multi-key edit macro", function()
      local ed = make("x\nx\nx")
      feed(ed, "qbA!" .. ESC .. "jq")      -- append '!' to a line, go down; reg b
      expect(ed.regs['b'].text).to.equal("A!" .. ESC .. "j")
      feed(ed, "@b@b")                      -- apply to the next two lines
      expect(ed.buf:get()).to.equal({ "x!", "x!", "x!" })
    end)
  end)

  describe(":normal send-keys", function()
    it("runs normal-mode keys given at the ':' prompt", function()
      local ed = make("foo bar")
      feed(ed, ":normal dw\r")            -- dw over the send-keys hatch
      expect(ed.buf:line(1)).to.equal("bar")
    end)
    it("leaves last_change set so '.' can repeat send-keys", function()
      local ed = make("one two three")
      feed(ed, ":normal dw\r")            -- "two three"
      feed(ed, ".")                       -- dw again -> "three"
      expect(ed.buf:line(1)).to.equal("three")
    end)
  end)

  describe("scrolling (Ctrl-F/B/D/U/E/Y)", function()
    -- A tall nowrap window: 100 short lines, rows=12 -> textrows=11, half=5,
    -- page=9 (11-2 overlap). One buffer line == one screen row, so top/cursor
    -- math is exact.
    local function tall()
      local t = {}
      for i = 1, 100 do t[i] = "line " .. i end
      local ed = make(table.concat(t, "\n"))
      ed.opts = { wrap = false, tabstop = 8 }
      ed.rows = 12
      return ed
    end
    local CF, CB, CD, CU, CE, CY = "\6", "\2", "\4", "\21", "\5", "\25"

    it("Ctrl-F/Ctrl-B page down and up (cursor keeps its screen row)", function()
      local ed = tall()
      feed(ed, CF); expect(ed.top).to.equal(10); expect(ed.cy).to.equal(10)
      feed(ed, CF); expect(ed.top).to.equal(19); expect(ed.cy).to.equal(19)
      feed(ed, CB); expect(ed.top).to.equal(10); expect(ed.cy).to.equal(10)
    end)

    it("Ctrl-D/Ctrl-U scroll half a page", function()
      local ed = tall()
      feed(ed, CD); expect(ed.top).to.equal(6);  expect(ed.cy).to.equal(6)
      feed(ed, CD); expect(ed.top).to.equal(11); expect(ed.cy).to.equal(11)
      feed(ed, CU); expect(ed.top).to.equal(6);  expect(ed.cy).to.equal(6)
    end)

    it("a count sets the scroll size for Ctrl-D", function()
      local ed = tall()
      feed(ed, "3" .. CD); expect(ed.top).to.equal(4); expect(ed.cy).to.equal(4)
    end)

    it("Ctrl-E reveals a lower line, keeping the cursor put until it scrolls off", function()
      local ed = tall()
      feed(ed, "4j"); expect(ed.cy).to.equal(5)     -- cursor mid-screen (row offset 4)
      feed(ed, CE); expect(ed.top).to.equal(2); expect(ed.cy).to.equal(5)  -- line kept
      feed(ed, CE .. CE .. CE)                       -- top climbs to the cursor's line
      expect(ed.top).to.equal(5); expect(ed.cy).to.equal(5)
      feed(ed, CE); expect(ed.top).to.equal(6); expect(ed.cy).to.equal(6)  -- now dragged
    end)

    it("Ctrl-Y reveals a higher line, keeping the cursor put mid-screen", function()
      local ed = tall()
      feed(ed, CD); expect(ed.top).to.equal(6); expect(ed.cy).to.equal(6) -- cursor on top row
      feed(ed, CY); expect(ed.top).to.equal(5); expect(ed.cy).to.equal(6) -- line kept, window up
    end)

    it("Ctrl-Y drags the cursor up when it sits on the bottom edge", function()
      local ed = tall()
      feed(ed, CD);       expect(ed.top).to.equal(6)  -- top=6
      feed(ed, "10j");    expect(ed.cy).to.equal(16)  -- cursor on the bottom row (offset 10)
      feed(ed, CY); expect(ed.top).to.equal(5); expect(ed.cy).to.equal(15) -- dragged up one
    end)

    it("does not scroll past the top of the buffer", function()
      local ed = tall()
      feed(ed, CB); expect(ed.top).to.equal(1); expect(ed.cy).to.equal(1)
      feed(ed, CY); expect(ed.top).to.equal(1)
    end)

    it("advances the sub-row when the top line wraps (wrap mode)", function()
      local long = string.rep("x", 200)            -- 200 cols / W=80 -> 3 sub-rows
      local ed = make(long .. "\na\nb\nc")
      ed.opts = { wrap = true, tabstop = 8 }
      ed.rows = 12; ed.cols = 80; ed.top = 1; ed.topsub = 0
      feed(ed, "\5")                                -- Ctrl-E: reveal one screen row
      expect(ed.top).to.equal(1); expect(ed.topsub).to.equal(1)
    end)
  end)

  describe("the ':' prompt shares ex.dispatch", function()
    it("runs an ex command typed at ':'", function()
      local ed = make("a\nb\nc")
      feed(ed, ":2d\r")
      expect(ed.buf:get()).to.equal({ "a", "c" })
      expect(ed.mode).to.equal("normal")
    end)
    it(":q sets running=false", function()
      local ed = make("a")
      feed(ed, ":q\r")
      expect(ed.running).to.be(false)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
