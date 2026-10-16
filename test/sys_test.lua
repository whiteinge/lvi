-- Tests for sys.lua's shell-backed helpers (stamp/newer -- the stat(2) dodge).
-- The FFI socket/poll surface is exercised indirectly by proto/editor tests,
-- apart from the close-on-exec flag on its sockets, which is checked here.
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

-- Every socket lvi opens is close-on-exec. Without it, each child lvi spawns
-- (a :bg tool, a :! command, a hook) holds a copy of the listening socket and
-- of the connection that ran the command, so if lvi dies first, its socket
-- still accepts connections nobody will answer, and `lvi -w` waits forever.
describe("sockets are close-on-exec", function()
  local function setup()
    local dir = os.tmpname(); os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    return dir, dir .. "/sock"
  end
  -- A background child of the shell that os.execute runs: it inherits every
  -- fd not marked close-on-exec, and outlives the call.
  local function spawn_child() os.execute("sleep 3 </dev/null >/dev/null 2>&1 &") end

  it("a child does not keep a closed listener answering", function()
    local dir, path = setup()
    local lfd = sys.listen(path)
    spawn_child()
    sys.close(lfd)
    local fd = sys.connect(path)
    expect(fd).to_not.exist()
    if fd then sys.close(fd) end
    os.execute("rm -rf '" .. dir .. "'")
  end)

  it("a child does not hold an accepted connection open", function()
    local dir, path = setup()
    local lfd = sys.listen(path)
    local client = sys.connect(path)
    local conn = sys.accept(lfd)
    spawn_child()
    sys.close(conn)
    sys.set_nonblock(client)
    expect(sys.read(client)).to_not.exist()   -- EOF (nil), not would-block ("")
    sys.close(client); sys.close(lfd)
    os.execute("rm -rf '" .. dir .. "'")
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
