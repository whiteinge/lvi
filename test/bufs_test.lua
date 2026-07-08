-- Tests for bufs.lua (multiple buffers). Run: luajit test/bufs_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local bufs   = require("bufs")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

local editor = require("editor")

-- Full ed state from the one constructor (bufs swaps several of its fields).
local function make_ed()
  return editor.new_ed()
end

local function tmpfile(text)
  local p = os.tmpname()
  local f = io.open(p, "wb"); f:write(text); f:close()
  return p
end

describe("bufs", function()
  it("initializes with one current buffer", function()
    local ed = make_ed()
    bufs.init(ed, buffer.new("one\ntwo"))
    expect(#ed.buffers).to.equal(1)
    expect(ed.bufidx).to.equal(1)
    expect(ed.buf:line(1)).to.equal("one")
  end)

  it("opens a new buffer and switches to it", function()
    local ed = make_ed(); bufs.init(ed, buffer.new("start"))
    local p = tmpfile("AAA\nBBB")
    bufs.open(ed, p)
    expect(#ed.buffers).to.equal(2)
    expect(ed.bufidx).to.equal(2)
    expect(ed.buf:line(1)).to.equal("AAA")
    os.remove(p)
  end)

  it("preserves each buffer's cursor across switches", function()
    local ed = make_ed(); bufs.init(ed, buffer.new("one\ntwo\nthree"))
    local p = tmpfile("AAA\nBBB\nCCC"); bufs.open(ed, p)
    ed.cy = 3                          -- move in buffer 2
    bufs.switch(ed, 1)
    expect(ed.buf:line(1)).to.equal("one"); expect(ed.cy).to.equal(1)
    bufs.switch(ed, 2)
    expect(ed.cy).to.equal(3)          -- buffer 2's cursor restored
    os.remove(p)
  end)

  it("re-opening a resident path switches instead of duplicating", function()
    local ed = make_ed(); bufs.init(ed, buffer.new(""))
    local p = tmpfile("x"); bufs.open(ed, p)
    bufs.switch(ed, 1)
    bufs.open(ed, p)
    expect(#ed.buffers).to.equal(2)
    expect(ed.bufidx).to.equal(2)
    os.remove(p)
  end)

  it("cycles with next/prev", function()
    local ed = make_ed(); bufs.init(ed, buffer.new("a"))
    local p = tmpfile("b"); bufs.open(ed, p)   -- now at 2 of 2
    bufs.next(ed); expect(ed.bufidx).to.equal(1)
    bufs.prev(ed); expect(ed.bufidx).to.equal(2)
    os.remove(p)
  end)

  describe("event firing", function()
    -- Record (event, reported-path) as bufs fires through the injected hook.
    local function traced_ed(text)
      local ed = make_ed(); bufs.init(ed, buffer.new(text))
      local ev = {}
      ed.fire_event = function(event, buf)
        ev[#ev + 1] = { event, buf and buf.path or "current" }
      end
      return ed, ev
    end
    it("fires bufleave then bufenter on a switch", function()
      local ed, ev = traced_ed("A")
      local p = tmpfile("B"); bufs.open(ed, p)          -- leave A, enter B
      expect(ev[1]).to.equal({ "bufleave", "current" })
      expect(ev[2]).to.equal({ "bufenter", "current" })
      os.remove(p)
    end)
    it("fires bufdelete with the closed (non-current) buffer's path", function()
      local pa = tmpfile("A"); local ed, ev = make_ed(), nil
      bufs.init(ed, buffer.open(pa)); ev = {}
      ed.fire_event = function(event, buf) ev[#ev + 1] = { event, buf and buf.path } end
      local pb = tmpfile("B"); bufs.open(ed, pb)         -- current is now pb (idx 2)
      for i = #ev, 1, -1 do ev[i] = nil end              -- drop the switch events
      bufs.close(ed, false, 1)                           -- close pa, which is NOT current
      expect(ev[1][1]).to.equal("bufdelete")             -- fired before removal
      expect(ev[1][2]).to.equal(pa)                      -- carries the deleted buffer's path
      os.remove(pa); os.remove(pb)
    end)
  end)

  describe("alternate buffer (#)", function()
    it("toggles between the two most recent buffers", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p = tmpfile("B"); bufs.open(ed, p)          -- 1=A 2=B, current 2
      expect(ed.altbuf).to.equal(1)                     -- leaving A made it the alternate
      expect(bufs.alt(ed)).to.be.truthy()
      expect(ed.bufidx).to.equal(1)                     -- back to A
      expect(ed.altbuf).to.equal(2)                     -- B is now the alternate
      bufs.alt(ed)
      expect(ed.bufidx).to.equal(2)                     -- ping-pong back to B
      os.remove(p)
    end)
    it("has no alternate for a lone buffer", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("only"))
      expect(ed.altbuf).to_not.exist()
      expect(bufs.alt(ed)).to.be(false)
    end)
    it("clears the alternate when it is closed", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p = tmpfile("B"); bufs.open(ed, p)          -- current 2, alt 1
      bufs.close(ed, false, 1)                          -- close the alternate (A)
      expect(ed.altbuf).to_not.exist()
      expect(bufs.alt(ed)).to.be(false)
      os.remove(p)
    end)
    it(":e # and :b # reach the alternate", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p = tmpfile("B"); bufs.open(ed, p)
      local _, s = ex.dispatch(ed, "e #")
      expect(s).to.equal("ok"); expect(ed.buf:line(1)).to.equal("A")
      local _, s2 = ex.dispatch(ed, "b #")
      expect(s2).to.equal("ok"); expect(ed.buf:line(1)).to.equal("B")
      os.remove(p)
    end)
    it(":b # errors with no alternate", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("solo"))
      local _, s = ex.dispatch(ed, "b #")
      expect(s).to.equal("err")
    end)
    it(":e <current-file> is a no-op that preserves the alternate", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p = tmpfile("B"); bufs.open(ed, p)          -- current 2 (B), alt 1 (A)
      bufs.open(ed, p)                                  -- :e the file already current
      expect(ed.bufidx).to.equal(2)
      expect(ed.altbuf).to.equal(1)                     -- used to become 2 (itself)
      expect(bufs.alt(ed)).to.be.truthy()               -- Ctrl-^ still works
      expect(ed.buf:line(1)).to.equal("A")
      os.remove(p)
    end)
  end)

  describe("close (:bd)", function()
    it("closes the current buffer, switching to a neighbor", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p = tmpfile("B"); bufs.open(ed, p)      -- 2 buffers, current = 2
      expect(bufs.close(ed)).to.be.truthy()
      expect(#ed.buffers).to.equal(1)
      expect(ed.buf:line(1)).to.equal("A")
      os.remove(p)
    end)
    it("refuses a modified buffer without force", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("x"))
      ed.buf:set(1, "y")
      expect(bufs.close(ed)).to.be(false)
      expect(bufs.close(ed, true)).to.be.truthy()   -- forced
    end)
    it("closing the last buffer leaves an empty [No Name]", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("only"))
      bufs.close(ed)
      expect(#ed.buffers).to.equal(1)
      expect(ed.buf:line(1)).to.equal("")
      expect(ed.buf.path).to_not.exist()
    end)
    it("closes a non-current buffer and fixes the index", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("A"))
      local p1 = tmpfile("B"); bufs.open(ed, p1)    -- 1=A 2=B, current 2
      local p2 = tmpfile("C"); bufs.open(ed, p2)    -- 1=A 2=B 3=C, current 3
      bufs.close(ed, false, 1)                      -- close A
      expect(#ed.buffers).to.equal(2)
      expect(ed.bufidx).to.equal(2)                 -- was 3, shifted to 2
      expect(ed.buf:line(1)).to.equal("C")
      os.remove(p1); os.remove(p2)
    end)
  end)

  describe("ex wiring", function()
    it(":e opens/switches and :ls lists", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("orig"))
      local p = tmpfile("hello")
      local _, s = ex.dispatch(ed, "e " .. p)
      expect(s).to.equal("ok")
      expect(ed.buf:line(1)).to.equal("hello")
      local list, ls = ex.dispatch(ed, "ls")
      expect(ls).to.equal("ok")
      expect(list:find("2\t%%")).to.exist() -- buffer 2 flagged current (%)
      os.remove(p)
    end)
    it(":b switches by number; unknown errors", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("a"))
      local p = tmpfile("b"); bufs.open(ed, p)
      ex.dispatch(ed, "b 1"); expect(ed.bufidx).to.equal(1)
      local _, s = ex.dispatch(ed, "b 9")
      expect(s).to.equal("err")
      os.remove(p)
    end)
    it(":bd closes; :qa checks every buffer", function()
      local ed = make_ed(); bufs.init(ed, buffer.new("a"))
      local p = tmpfile("b"); bufs.open(ed, p)
      ex.dispatch(ed, "bd")                    -- close current (b) -> back to a
      expect(#ed.buffers).to.equal(1)
      ed.buf:set(1, "z")                        -- now modified
      local _, s = ex.dispatch(ed, "qa")
      expect(s).to.equal("err"); expect(ed.running).to.be(true)
      ex.dispatch(ed, "qa!")
      expect(ed.running).to.be(false)
      os.remove(p)
    end)
    it(":wa writes every modified buffer, skipping clean ones", function()
      local ed = make_ed()
      local pa, pb = tmpfile("a"), tmpfile("b")
      bufs.init(ed, buffer.open(pa)); bufs.open(ed, pb)
      ed.buf:set(1, "B2")                       -- dirty the current buffer (b)
      bufs.switch(ed, 1); ed.buf:set(1, "A2")   -- dirty the other buffer (a) too
      local fired = {}
      ed.fire_event = function(e) fired[#fired + 1] = e end
      local p, s = ex.dispatch(ed, "wa")
      expect(s).to.equal("ok")
      expect(p).to.equal("2 buffers written")
      expect(fired).to.equal({ "write", "write" })   -- one per buffer written
      expect(io.open(pa):read("*a")).to.equal("A2")
      expect(io.open(pb):read("*a")).to.equal("B2")
      -- a second :wa now writes nothing -- both are clean
      fired = {}
      expect((ex.dispatch(ed, "wa"))).to.equal("0 buffers written")
      expect(fired).to.equal({})
      os.remove(pa); os.remove(pb)
    end)
    it(":xa writes all changed buffers, then quits", function()
      local ed = make_ed()
      local pa, pb = tmpfile("a"), tmpfile("b")
      bufs.init(ed, buffer.open(pa)); bufs.open(ed, pb)
      ed.buf:set(1, "B2")
      local _, s = ex.dispatch(ed, "xa")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      expect(io.open(pb):read("*a")).to.equal("B2")
      os.remove(pa); os.remove(pb)
    end)
    it(":wa errors on a modified unnamed buffer, without quitting", function()
      local ed = make_ed()
      bufs.init(ed, buffer.new("named-later"))   -- no path
      ed.buf:set(1, "dirty")
      local _, s = ex.dispatch(ed, "wa")
      expect(s).to.equal("err")
      local _, s2 = ex.dispatch(ed, "xa")        -- xa likewise refuses, stays running
      expect(s2).to.equal("err")
      expect(ed.running).to.be(true)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
