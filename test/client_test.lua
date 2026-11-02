-- Tests for client.lua's deadlock check. Run: luajit test/client_test.lua
--
-- A view blocked running one of its own children cannot answer that child, so
-- `lvi -w` from a `:silent !` child of the view would wait forever. The client
-- spots it -- our socket is $LVI_SOCK, no $LVI_BG, and the %hello goes
-- unanswered -- and fails instead. The listener here never accepts, which is
-- exactly what a frozen view looks like from the client's side: the connect
-- lands in the backlog and nothing reads it.
--
-- Each test tears its fixture down before asserting: a failed expect() leaves
-- the `it` body, and the socket names here are not numeric wids, so nothing
-- else would ever reap them.
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect
local sys    = require("sys")
local path   = require("path")
local client = require("client")

describe("client deadlock check", function()
  it("fails, instead of hanging, when its own view never answers", function()
    local wid = "clienttest-" .. sys.getpid()
    local sock = path.socket(wid)
    local lfd = sys.listen(sock)
    sys.setenv("LVI_SOCK", sock)
    sys.setenv("LVI_BG", "")
    local t0 = os.time()
    local res, err = client.send(wid, { "f" })
    local took = os.time() - t0
    sys.close(lfd); sys.unlink(sock)
    expect(res).to_not.exist()
    expect(err:find("cannot answer", 1, true)).to.exist()
    expect(err:find(":bg", 1, true)).to.exist()
    expect(took <= 4).to.equal(true)
  end)

  -- A detached `:bg` child is never what the view is blocked on, so it waits
  -- out a slow view (here: one that answers only after the 2 s window).
  it("waits past the window for a :bg child", function()
    local wid = "clienttest-bg-" .. sys.getpid()
    local sock = path.socket(wid)
    local script = path.tmp()
    local f = assert(io.open(script, "w"))
    f:write([[
package.path = "./?.lua;" .. package.path
local sys, proto = require("sys"), require("proto")
local l = sys.listen(arg[1])
os.execute("sleep 3")
local c = sys.accept(l)
local buf = ""
local function need(pat)
  while not buf:find(pat) do
    local chunk = sys.read(c)
    if not chunk then os.exit(1) end   -- client gone: do not spin on EOF
    buf = buf .. chunk
  end
end
need("\n"); buf = buf:gsub("^[^\n]*\n", "")
proto.send_response(c, 1, "lvi 1", "ok")
need("^%%cmd (%d+)\n")
local n = tonumber(buf:match("^%%cmd (%d+)\n"))
need("^%%cmd %d+\n" .. ("."):rep(n))
proto.send_response(c, 2, "late", "ok")
sys.close(c); sys.close(l)
]])
    f:close()
    local p = io.popen("luajit '" .. script .. "' '" .. sock .. "' >/dev/null 2>&1 & echo $!")
    local pid = p:read("*l"); p:close()
    for _ = 1, 50 do
      if os.execute("test -S '" .. sock .. "'") == 0 then break end
      os.execute("sleep 0.1")
    end
    sys.setenv("LVI_SOCK", sock)
    sys.setenv("LVI_BG", "1")
    local res, err = client.send(wid, { "f" })
    os.execute("kill " .. pid .. " 2>/dev/null")   -- still in accept() if we failed
    sys.unlink(sock); os.remove(script)
    expect(err).to_not.exist()
    expect(res[1].payload).to.equal("late")
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
