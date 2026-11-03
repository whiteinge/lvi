-- Tests for client.lua's deadlock check. Run: luajit test/client_test.lua
--
-- A view blocked running one of its own children cannot answer that child, so
-- `lvi -w` from a `:silent !` child of the view would wait forever. The view
-- marks such a spawn (editor.blocking): the child's $LVI_BUSY token sits in the
-- `.busy` file beside the socket until the spawn returns. A client that finds
-- its own token still there fails instead of hanging. The listener in the
-- frozen case never accepts, which is what a frozen view looks like from
-- outside. The last test runs the real thing: a headless view, blocked in
-- `:r !`, whose child calls back.
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

local function write(p, s) local f = assert(io.open(p, "w")); f:write(s); f:close() end
local function read(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local function wait_for(test)
  for _ = 1, 50 do
    if test() then return true end
    os.execute("sleep 0.1")
  end
  return false
end

-- A fake view: listens, sleeps SLEEP seconds, acts on the busy file (`remove`,
-- or nothing), then answers the handshake and one framed command with PAYLOAD.
-- Returns a teardown that kills it (it sits in accept() if the client never
-- came) and removes its files.
local SERVER = [[
package.path = "./?.lua;" .. package.path
local sys, proto = require("sys"), require("proto")
local sock, sleep, busy, act, payload = arg[1], tonumber(arg[2]), arg[3], arg[4], arg[5]
local l = sys.listen(sock)
if sleep > 0 then os.execute("sleep " .. sleep) end
if act == "remove" then os.remove(busy) end
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
proto.send_response(c, 2, payload, "ok")
sys.close(c); sys.close(l)
]]

local function server(sock, sleep, act, payload)
  local script = path.tmp()
  write(script, SERVER)
  local p = io.popen(("luajit '%s' '%s' %d '%s' %s %s >/dev/null 2>&1 & echo $!")
    :format(script, sock, sleep, path.busy(sock), act, payload))
  local pid = p:read("*l"); p:close()
  wait_for(function() return os.execute("test -S '" .. sock .. "'") == 0 end)
  return function()
    os.execute("kill " .. pid .. " 2>/dev/null")
    sys.unlink(sock); os.remove(script); os.remove(path.busy(sock))
  end
end

describe("client deadlock check", function()
  local n = 0
  -- A fresh view identity, and we are its child: our socket is its socket.
  local function fixture()
    n = n + 1
    local wid = ("clienttest-%d-%d"):format(sys.getpid(), n)
    local sock = path.socket(wid)
    sys.setenv("LVI_SOCK", sock)
    return wid, sock
  end

  it("fails, instead of hanging, when its own view never answers", function()
    local wid, sock = fixture()
    local lfd = sys.listen(sock)                    -- never accepts: frozen
    write(path.busy(sock), "v.1\n")
    sys.setenv("LVI_BUSY", "v.1")
    local t0 = os.time()
    local res, err = client.send(wid, { "f" })
    local took = os.time() - t0
    local left = read(path.busy(sock))
    sys.close(lfd); sys.unlink(sock); os.remove(path.busy(sock))
    expect(res).to_not.exist()
    expect(err:find("cannot answer", 1, true)).to.exist()
    expect(err:find(":bg", 1, true)).to.exist()
    expect(took <= 4).to.equal(true)
    -- The reason is left after the token, for the view's status line.
    expect(left:match("^v%.1\nlvi %-w: .*refused.*:bg\n$")).to.exist()
  end)

  -- A worker a `:!` child left behind calls back as its parent exits; the
  -- file goes a moment later, and the client proceeds.
  it("proceeds once the view's busy file moves on", function()
    local wid, sock = fixture()
    write(path.busy(sock), "v.2\n")
    sys.setenv("LVI_BUSY", "v.2")
    local stop = server(sock, 1, "remove", "released")
    local res, err = client.send(wid, { "f" })
    stop()
    expect(err).to_not.exist()
    expect(res[1].payload).to.equal("released")
  end)

  it("ignores a token that is not the file's", function()
    local wid, sock = fixture()
    write(path.busy(sock), "v.9\n")                 -- a later spawn's token
    sys.setenv("LVI_BUSY", "v.3")                   -- ours, from an earlier one
    local stop = server(sock, 0, "keep", "stale")
    local res, err = client.send(wid, { "f" })
    stop()
    expect(err).to_not.exist()
    expect(res[1].payload).to.equal("stale")
  end)

  -- A detached `:bg` child carries no token, so it waits out a slow view
  -- (here: one that answers only after the 2 s window).
  it("waits past the window for a :bg child", function()
    local wid, sock = fixture()
    write(path.busy(sock), "v.4\n")                 -- the view IS busy...
    sys.setenv("LVI_BUSY", "")                      -- ...but not on us
    local stop = server(sock, 3, "keep", "late")
    local res, err = client.send(wid, { "f" })
    stop()
    expect(err).to_not.exist()
    expect(res[1].payload).to.equal("late")
  end)
end)

describe("busy marker in a live view", function()
  it("marks a :r ! child, refuses its callback, and leaves :bg children alone", function()
    local file = path.tmp()
    write(file, "x\n")
    local p = io.popen(("luajit lvi '%s' </dev/null >/dev/null 2>&1 & echo $!"):format(file))
    local wid = p:read("*l"); p:close()
    local sock = path.socket(wid)
    wait_for(function() return os.execute("test -S '" .. sock .. "'") == 0 end)
    sys.setenv("LVI_SOCK", ""); sys.setenv("LVI_BUSY", "")   -- we are an outsider
    -- The child sees its token in both places...
    local r1 = client.send(wid, {
      [[r !printf 'env=%s file=%s' "$LVI_BUSY" "$(cat "$LVI_SOCK.busy")"]], "%p" })
    -- ...and calling back from it is refused, with the fix, not a hang.
    local r2 = client.send(wid, { [[r !luajit lvi -w "$LVI_WID" -- f]] })
    -- A detached child sees neither: the marker is gone once the spawn returns.
    local out = path.tmp()
    client.send(wid, { ([[bg printf 'env=%%s file=%%s' "$LVI_BUSY" ]]
      .. [["$(test -e "$LVI_SOCK.busy" && echo yes || echo no)" > '%s']]):format(out) })
    wait_for(function() return read(out) ~= nil end)
    local bg = read(out)
    client.send(wid, { "q!" })
    os.execute("kill " .. wid .. " 2>/dev/null"); os.remove(file); os.remove(out)
    local env, fil = (r1 and r1[2].payload or ""):match("env=(%S+) file=(%S+)")
    expect(env).to.exist()
    expect(env).to.equal(fil)
    expect(env:match("^" .. wid .. "%.%d+$")).to.exist()
    expect(r2 and r2[1].status).to.equal("err")
    expect(r2[1].payload:find(":bg", 1, true)).to.exist()
    expect(bg).to.equal("env= file=no")
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
