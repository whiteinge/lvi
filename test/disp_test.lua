-- Tests for disp.lua (display geometry). Run: luajit test/disp_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local disp = require("disp")
local describe, it, expect = lust.describe, lust.it, lust.expect

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

  it("maps a visual position back to a byte (byteat, inverse of locate)", function()
    expect(disp.byteat("abcdef", 3, 8, 1, 0)).to.equal(4) -- row 1, col 0 -> 'd'
    expect(disp.byteat("abcdef", 3, 8, 0, 1)).to.equal(2) -- 'b'
    expect(disp.byteat("abcdef", 3, 8, 1, 5)).to.equal(6) -- past row -> last ('f')
    expect(disp.byteat("", 3, 8, 0, 0)).to.equal(1)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
