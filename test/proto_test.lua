-- Tests for proto.lua framing (build + read round-trip). Run: luajit test/proto_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust  = require("lust")
local proto = require("proto")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- A reader fed from a fixed string in tiny chunks, to exercise buffering across
-- read boundaries (the real transport delivers arbitrary chunk sizes).
local function chunk_reader(s, size)
  local pos = 1
  return proto.reader(function()
    if pos > #s then return nil end
    local c = s:sub(pos, pos + size - 1)
    pos = pos + size
    return c
  end)
end

describe("proto framing", function()
  it("round-trips a multi-line payload", function()
    local r = chunk_reader(proto.response(1, "alpha\nbravo", "ok"), 3)
    local p, s = r:response()
    expect(p).to.equal("alpha\nbravo")
    expect(s).to.equal("ok")
  end)

  it("round-trips an empty payload with a non-ok status", function()
    local r = chunk_reader(proto.response(2, "", "err"), 4)
    local p, s = r:response()
    expect(p).to.equal("")
    expect(s).to.equal("err")
  end)

  it("is binary-safe against payloads that mimic the terminator", function()
    local evil = "%end 1 ok"                      -- looks exactly like a frame end
    local r = chunk_reader(proto.response(1, evil, "ok"), 5)
    local p, s = r:response()
    expect(p).to.equal(evil)
    expect(s).to.equal("ok")
  end)

  it("reads several frames from one stream in order", function()
    local stream = proto.response(1, "one", "ok") .. proto.response(2, "two", "ok")
    local r = chunk_reader(stream, 2)
    local p1 = r:response(); local p2 = r:response()
    expect(p1).to.equal("one")
    expect(p2).to.equal("two")
  end)

  it("errors on a truncated frame", function()
    local r = chunk_reader("%begin 1\n%data 10\nshort", 7)  -- promises 10, gives 5
    expect(function() r:response() end).to.fail()
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
