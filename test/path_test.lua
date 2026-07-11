-- Tests for path.lua's namespace cleanup: reap_sidecars and the list_sockets GC.
-- Redirects XDG_RUNTIME_DIR at a throwaway scratch dir so nothing here can touch
-- the real per-uid runtime directory (or a live editing session's files).
-- Run: luajit test/path_test.lua (from repo root)
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local sys  = require("sys")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- A fresh, unique scratch dir as the runtime base, made active via XDG_RUNTIME_DIR.
-- (path.lua reads the env on every call, so this fully reroutes it.) require path
-- AFTER setting the env is unnecessary -- base_dir() is not cached -- but we still
-- rebuild the dir per test for isolation.
local base = os.tmpname()                    -- a unique name in /tmp...
os.remove(base)                              -- ...claim it as a directory instead
sys.setenv("XDG_RUNTIME_DIR", base)
sys.setenv("TMPDIR", "")                     -- force the XDG branch of base_dir
local path = require("path")

local function reset_dir()
  -- Recreate the parent (real XDG_RUNTIME_DIR always exists; path.dir()'s mkdir
  -- is non-recursive, so it only makes the lvi-<uid> level).
  os.execute(("rm -rf -- '%s' && mkdir -p '%s'"):format(base, base))
  return path.dir()                          -- mkdir base/lvi-<uid> at 0700, return it
end
local function touch(p) local f = io.open(p, "w"); if f then f:close() end end
local function exists(p) return sys.newer(p, "/nonexistent-xyz") == true end  -- a exists, b doesn't -> true

describe("path.reap_sidecars", function()
  it("removes the whole <sockpath>.* namespace (files and dirs) but not the bare socket", function()
    local dir = reset_dir()
    local sock = dir .. "/4242"
    touch(sock)                              -- the bare socket name (no dot)
    touch(dir .. "/4242.buf")
    touch(dir .. "/4242.stamp.1")
    touch(dir .. "/4242.focus")
    os.execute(("mkdir -p '%s' && : > '%s'"):format(dir .. "/4242.lists", dir .. "/4242.lists/search"))
    touch(dir .. "/9999.focus")              -- a bystander wid: must survive

    path.reap_sidecars(sock)

    expect(exists(dir .. "/4242.buf")).to.be(false)
    expect(exists(dir .. "/4242.stamp.1")).to.be(false)
    expect(exists(dir .. "/4242.focus")).to.be(false)
    expect(exists(dir .. "/4242.lists/search")).to.be(false)
    expect(exists(sock)).to.be(true)         -- bare socket path is NOT matched by .*
    expect(exists(dir .. "/9999.focus")).to.be(true)  -- other wid untouched
    os.execute(("rm -rf -- '%s'"):format(base))
  end)
end)

describe("path.list_sockets GC", function()
  it("reaps dead numeric wids' sidecars, preserves live views and the tmp namespace", function()
    local dir = reset_dir()

    -- A live view: a real listening socket plus a sidecar that must be protected.
    local live = dir .. "/" .. tostring(sys.getpid())
    local lfd = sys.listen(live)
    expect(lfd).to_not.equal(nil)
    touch(live .. ".focus")

    -- A dead view: sidecars with no answering socket (the orphan case).
    touch(dir .. "/70001.focus")
    os.execute(("mkdir -p '%s'"):format(dir .. "/70001.lists"))
    touch(dir .. "/70001.stamp.1")

    -- A path.tmp() file: a different, caller-managed namespace, must survive.
    touch(dir .. "/tmp." .. tostring(sys.getpid()) .. ".1")

    local views = path.list_sockets()

    -- Only the live view is returned, and its files survive.
    expect(#views).to.equal(1)
    expect(views[1].wid).to.equal(tostring(sys.getpid()))
    expect(exists(live)).to.be(true)
    expect(exists(live .. ".focus")).to.be(true)
    -- The dead wid's whole namespace is gone.
    expect(exists(dir .. "/70001.focus")).to.be(false)
    expect(exists(dir .. "/70001.lists")).to.be(false)
    expect(exists(dir .. "/70001.stamp.1")).to.be(false)
    -- The tmp namespace is left alone.
    expect(exists(dir .. "/tmp." .. tostring(sys.getpid()) .. ".1")).to.be(true)

    sys.close(lfd)
    os.execute(("rm -rf -- '%s'"):format(base))
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
