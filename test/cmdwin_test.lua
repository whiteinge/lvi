-- Tests for the command window and ':' prompt history. Run:
--   luajit test/cmdwin_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local bufs   = require("bufs")
local ex     = require("ex")
local normal = require("normal")
local editor = require("editor")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- A full ed with a resident buffer list (the command window switches buffers,
-- so it needs bufs, unlike the bare ex.dispatch tests).
local function make(text)
  local ed = editor.new_ed()
  bufs.init(ed, buffer.new(text or ""))
  return ed
end

-- Live interpreter coroutine, primed to getkey (mirrors normal_test).
local function interp(ed)
  ed.interp = coroutine.create(function() normal.loop(ed) end)
  assert(coroutine.resume(ed.interp))
  return ed
end

-- Feed raw key bytes and let the coroutine drain them.
local function feed(ed, s)
  for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
  assert(coroutine.resume(ed.interp))
  return ed
end

local ESC, CTRL_P, CTRL_N, CTRL_F = "\27", "\16", "\14", "\6"

describe("command-line history", function()
  it("records submitted commands, consecutive-deduped", function()
    local ed = make()
    ex.record_history(ed, "w")
    ex.record_history(ed, "w")     -- immediate repeat collapses
    ex.record_history(ed, "42")
    ex.record_history(ed, "")      -- empty ignored
    expect(#ed.cmdhist).to.equal(2)
    expect(ed.cmdhist[1]).to.equal("w")
    expect(ed.cmdhist[2]).to.equal("42")
  end)

  it("caps the history at a rolling maximum", function()
    local ed = make()
    for i = 1, 150 do ex.record_history(ed, "cmd" .. i) end
    expect(#ed.cmdhist).to.equal(100)
    expect(ed.cmdhist[1]).to.equal("cmd51")     -- oldest 50 rolled off
    expect(ed.cmdhist[100]).to.equal("cmd150")
  end)
end)

describe("scratch buffers", function()
  it("never count as modified even after edits", function()
    local buf = buffer.new("")
    buf.scratch = true
    buf:insert(1, { "one", "two" })
    expect(buf.modified).to.equal(false)
  end)

  it("show their name in :ls in place of a path", function()
    local ed = make("orig")
    bufs.scratch(ed, "[Command Line]")
    expect(bufs.list(ed):find("[Command Line]", 1, true)).to.be.truthy()
  end)
end)

describe("command window", function()
  it("opens a scratch buffer seeded from history + a trailing blank", function()
    local ed = make("orig text")
    ed.cmdhist = { "w", "42" }
    ex.dispatch(ed, "cmdwin")
    expect(ed.buf.name).to.equal("[Command Line]")
    expect(ed.buf.scratch).to.equal(true)
    expect(ed.buf.cmdwin_origin).to.exist()
    expect(ed.buf:nlines()).to.equal(3)        -- w, 42, ""
    expect(ed.buf:line(1)).to.equal("w")
    expect(ed.buf:line(3)).to.equal("")        -- trailing blank
    expect(ed.cy).to.equal(3)                  -- cursor parked on it
  end)

  it("runs the line under the cursor on bare :w, against the origin buffer", function()
    local ed = make("hello world")
    local origin = ed.buf
    ex.dispatch(ed, "cmdwin")
    ed.buf:set(ed.cy, "s/hello/goodbye/")      -- type a command on the blank line
    local _, status = ex.dispatch(ed, "w")     -- execute it
    expect(status).to.equal("ok")
    expect(ed.buf).to.equal(origin)            -- popped back to origin
    expect(origin:line(1)).to.equal("goodbye world")
    expect(ed.cmdhist[#ed.cmdhist]).to.equal("s/hello/goodbye/")  -- recorded
    -- The scratch window is gone.
    for _, rec in ipairs(ed.buffers) do
      expect(rec.buf.cmdwin_origin).to_not.exist()
    end
  end)

  it("runs the line the cursor sits on, not necessarily the last", function()
    local ed = make("aaa")
    ed.cmdhist = { "s/aaa/first/", "s/aaa/second/" }
    ex.dispatch(ed, "cmdwin")
    ed.cy = 1                                   -- move to the older command
    ex.dispatch(ed, "w")
    expect(ed.buf:line(1)).to.equal("first")
  end)

  it("a blank current line just leaves without running anything", function()
    local ed = make("untouched")
    local origin = ed.buf
    ex.dispatch(ed, "cmdwin")                   -- cursor on the blank trailing line
    local _, status = ex.dispatch(ed, "w")
    expect(status).to.equal("ok")
    expect(ed.buf).to.equal(origin)
    expect(origin:line(1)).to.equal("untouched")
  end)

  it(":w <file> in the window still writes instead of executing", function()
    local ed = make("body")
    ex.dispatch(ed, "cmdwin")
    ed.buf:set(ed.cy, "some command")
    local p = os.tmpname()
    local _, status = ex.dispatch(ed, "w " .. p)
    expect(status).to.equal("ok")
    local f = io.open(p, "rb"); local got = f:read("*a"); f:close(); os.remove(p)
    expect(got:find("some command", 1, true)).to.be.truthy()
    expect(ed.buf.cmdwin_origin).to.exist()     -- still the window; did not execute
  end)

  it(":bd cancels the window without running anything (no modified nag)", function()
    local ed = make("keep me")
    local origin = ed.buf
    ex.dispatch(ed, "cmdwin")
    ed.buf:set(ed.cy, "s/keep/drop/")           -- typed but never executed
    local _, status = ex.dispatch(ed, "bd")     -- no bang needed: scratch is never dirty
    expect(status).to.equal("ok")
    expect(origin:line(1)).to.equal("keep me")
  end)

  it("reuses a resident window rather than stacking a second", function()
    local ed = make("x")
    ex.dispatch(ed, "cmdwin")
    local n = #ed.buffers
    ex.dispatch(ed, "cmdwin")                   -- already in it: no-op
    expect(#ed.buffers).to.equal(n)
  end)
end)

describe("':' prompt history and Ctrl-F", function()
  it("Ctrl-P walks back through history, Ctrl-N forward", function()
    local ed = make("body"); ed.cmdhist = { "one", "two", "three" }
    interp(ed)
    feed(ed, ":")
    expect(ed.mode).to.equal("command")
    feed(ed, CTRL_P); expect(ed.cmdline).to.equal("three")   -- newest first
    feed(ed, CTRL_P); expect(ed.cmdline).to.equal("two")
    feed(ed, CTRL_P); expect(ed.cmdline).to.equal("one")     -- oldest
    feed(ed, CTRL_P); expect(ed.cmdline).to.equal("one")     -- clamps at the top
    feed(ed, CTRL_N); expect(ed.cmdline).to.equal("two")
    feed(ed, ESC)
  end)

  it("Ctrl-N past the newest restores the half-typed line", function()
    local ed = make("body"); ed.cmdhist = { "old" }
    interp(ed)
    feed(ed, ":ne")                                          -- start typing "ne..."
    feed(ed, CTRL_P); expect(ed.cmdline).to.equal("old")     -- stashes "ne"
    feed(ed, CTRL_N); expect(ed.cmdline).to.equal("ne")      -- brought back
    feed(ed, ESC)
  end)

  it("a submitted command lands in history", function()
    local ed = make("body")
    interp(ed)
    feed(ed, ":42\r")
    expect(ed.cmdhist[#ed.cmdhist]).to.equal("42")
  end)

  it("Ctrl-F leaves the prompt and opens the command window, seeding the line", function()
    local ed = make("body"); ed.cmdhist = { "prev" }
    interp(ed)
    feed(ed, ":s/a/b/")
    feed(ed, CTRL_F)
    expect(ed.mode).to.equal("normal")
    expect(ed.buf.name).to.equal("[Command Line]")
    expect(ed.buf:line(ed.buf:nlines())).to.equal("s/a/b/")  -- half-typed line carried in
    expect(ed.buf:line(1)).to.equal("prev")                  -- history above it
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
