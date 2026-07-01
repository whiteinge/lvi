-- Tests for disp.lua (display geometry). Run: luajit test/disp_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local disp = require("disp")
local describe, it, expect = lust.describe, lust.it, lust.expect

local E = "\195\169"       -- 'é' U+00E9, 2 bytes, width 1
local CJK = "\228\184\150" -- '世' U+4E16, 3 bytes, width 2

describe("disp", function()
  it("expands tabs to the next tab stop", function()
    expect(disp.expand("a\tb", 4)).to.equal("a   b") -- 'a' at 0, tab -> col 4
    expect(disp.expand("\tx", 4)).to.equal("    x")
    expect(disp.expand("abc", 4)).to.equal("abc")    -- untouched when no tab
  end)

  it("computes the display column of a byte (dispcol)", function()
    expect(disp.dispcol("a\tb", 4, 3)).to.equal(4)   -- 'b' sits at col 4
    expect(disp.dispcol("abc", 8, 1)).to.equal(0)
    expect(disp.dispcol("abc", 8, 3)).to.equal(2)
  end)

  it("wraps into segments no wider than W", function()
    expect(disp.segments("abcdef", 3, 8)).to.equal({ "abc", "def" })
    expect(disp.segments("ab", 5, 8)).to.equal({ "ab" })
    expect(disp.segments("", 3, 8)).to.equal({ "" })
  end)

  it("counts segments (nsegs)", function()
    expect(disp.nsegs("abcdef", 3, 8)).to.equal(2)
    expect(disp.nsegs("", 3, 8)).to.equal(1)
    expect(disp.nsegs("abcd", 4, 8)).to.equal(1)
  end)

  it("locates a byte's (sub-row, col) under wrapping", function()
    local s1, c1 = disp.locate("abcdef", 3, 8, 4) -- 'd' starts row 1
    expect(s1).to.equal(1); expect(c1).to.equal(0)
    local s2, c2 = disp.locate("abcdef", 3, 8, 1)
    expect(s2).to.equal(0); expect(c2).to.equal(0)
    local s3 = select(1, disp.locate("abc", 3, 8, 4)) -- cursor past a full row
    expect(s3).to.equal(1)
  end)

  it("finds the byte at a display column (tab-aware)", function()
    expect(disp.byte_at_dispcol("abc", 8, 0)).to.equal(1)
    expect(disp.byte_at_dispcol("abc", 8, 2)).to.equal(3)
    expect(disp.byte_at_dispcol("a\tb", 8, 4)).to.equal(2) -- inside the tab
    expect(disp.byte_at_dispcol("a\tb", 8, 8)).to.equal(3) -- 'b' after the tab
  end)

  it("maps a visual position back to a byte (byteat, inverse of locate)", function()
    expect(disp.byteat("abcdef", 3, 8, 1, 0)).to.equal(4) -- row 1, col 0 -> 'd'
    expect(disp.byteat("abcdef", 3, 8, 0, 1)).to.equal(2) -- 'b'
    expect(disp.byteat("abcdef", 3, 8, 1, 5)).to.equal(6) -- past row -> last ('f')
    expect(disp.byteat("", 3, 8, 0, 0)).to.equal(1)
  end)

  describe("UTF-8", function()
    it("measures display width (narrow vs wide)", function()
      expect(disp.width(E, 8)).to.equal(1)          -- 'é' 2 bytes, 1 cell
      expect(disp.width(CJK, 8)).to.equal(2)        -- '世' 3 bytes, 2 cells
      expect(disp.width("a" .. E .. "b", 8)).to.equal(3)
    end)
    it("navigates by character", function()
      local s = "a" .. E .. "b"                     -- bytes: a=1, é=2..3, b=4
      expect(disp.next_char(s, 1)).to.equal(2)
      expect(disp.next_char(s, 2)).to.equal(4)
      expect(disp.prev_char(s, 4)).to.equal(2)
      expect(disp.last_char(s)).to.equal(4)
    end)
    it("dispcol / byte_at_dispcol account for wide chars", function()
      local s = "a" .. CJK .. "b"                   -- a@0, 世@1(w2), b@3
      expect(disp.dispcol(s, 8, 5)).to.equal(3)     -- 'b' is byte 5, col 3
      expect(disp.byte_at_dispcol(s, 8, 1)).to.equal(2) -- col 1 -> 世
      expect(disp.byte_at_dispcol(s, 8, 3)).to.equal(5) -- col 3 -> b
    end)
    it("wrapping keeps multibyte chars whole", function()
      local segs = disp.segments(E .. E .. E, 2, 8) -- three 1-cell chars, W=2
      expect(#segs).to.equal(2)
      expect(segs[1]).to.equal(E .. E)
      expect(segs[2]).to.equal(E)
    end)
  end)

  describe("slice highlight overlay", function()
    it("leaves a styleless interval as plain text (un-themed = invisible)", function()
      local out = disp.slice("hello", 8, 0, 20, { { 0, 3 } })   -- cols 0..2, no sgr
      expect(out).to.equal("hello")
    end)
    it("uses a group's SGR params when the interval carries them", function()
      local out = disp.slice("hello", 8, 0, 20, { { 0, 3, "38;5;2;1" } })
      expect(out).to.equal("\27[38;5;2;1mhel\27[0mlo")
    end)
    it("resets and re-opens between touching intervals of different styles", function()
      local out = disp.slice("abcd", 8, 0, 20, { { 0, 2, "31" }, { 2, 4, "32" } })
      expect(out).to.equal("\27[31mab\27[0m\27[32mcd\27[0m")
    end)
    it("emits nothing extra with no intervals", function()
      expect(disp.slice("hello", 8, 0, 20, nil)).to.equal("hello")
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
