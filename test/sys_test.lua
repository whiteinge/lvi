-- Tests for sys.lua's shell-backed helpers (stamp/newer -- the stat(2) dodge).
-- The FFI socket/poll surface is exercised indirectly by proto/editor tests.
-- Run: luajit test/sys_test.lua (from repo root)
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local sys  = require("sys")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function touch_at(p, stamp) -- POSIX touch -t CCYYMMDDhhmm
  os.execute(("touch -t %s '%s'"):format(stamp, p))
end

describe("sys.stamp / sys.newer", function()
  it("a freshly stamped file is not newer than its stamp", function()
    local f, s = os.tmpname(), os.tmpname()
    sys.stamp(s, f)                       -- mirror f's mtime onto s
    expect(sys.newer(f, s)).to.be(false)
    os.remove(f); os.remove(s)
  end)

  it("detects the file moving past its stamp", function()
    local f, s = os.tmpname(), os.tmpname()
    touch_at(f, "202001010000")           -- park f in the past
    sys.stamp(s, f)
    expect(sys.newer(f, s)).to.be(false)
    touch_at(f, "203001010000")           -- another writer touched f
    expect(sys.newer(f, s)).to.be(true)
    os.remove(f); os.remove(s)
  end)

  it("stamp of a missing source creates nothing; a later file reads as changed", function()
    local f, s = os.tmpname(), os.tmpname()
    os.remove(f); os.remove(s)            -- neither exists (a new-file buffer)
    sys.stamp(s, f)
    expect(io.open(s, "r")).to_not.exist()
    expect(sys.newer(f, s)).to.be(false)  -- still no file: no conflict
    touch_at(f, "202001010000")           -- someone else created it since
    expect(sys.newer(f, s)).to.be(true)
    os.remove(f)
  end)

  it("quotes paths with spaces and quotes", function()
    local dir = os.tmpname(); os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    local f = dir .. "/it's a file"
    local s = dir .. "/stamp"
    io.open(f, "w"):close()
    sys.stamp(s, f)
    expect(io.open(s, "r")).to.exist()
    expect(sys.newer(f, s)).to.be(false)
    os.execute("rm -rf '" .. dir .. "'")
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
