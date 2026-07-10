-- Tests for command-backed registers (:register + normal-mode yank/put).
-- Run: luajit test/register_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local normal = require("normal")
local editor = require("editor")
local ex     = require("ex")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- An editor with a live interpreter and STUB backend I/O: reg_write appends
-- {cmd, text} to `writes`, reg_read returns whatever `clip` currently holds for
-- the command. No real shell-out, so the register logic is tested in isolation.
local function make(text)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.writes = {}
  ed.clip = {}                                  -- cmd -> stdout the stub read returns
  ed.reg_write = function(cmd, t) ed.writes[#ed.writes + 1] = { cmd = cmd, text = t } end
  ed.reg_read  = function(cmd) return ed.clip[cmd] or "" end
  ed.interp = coroutine.create(function() normal.loop(ed) end)
  assert(coroutine.resume(ed.interp))
  return ed
end

local function feed(ed, s)
  for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
  assert(coroutine.resume(ed.interp))
  return ed
end

describe("command-backed registers", function()
  describe(":register parsing", function()
    it("binds read and write on one line, either order", function()
      local ed = make("x")
      expect(select(2, ex.dispatch(ed, "register + read paste write copy"))).to.equal("ok")
      expect(ed.reg_backends["+"].read).to.equal("paste")
      expect(ed.reg_backends["+"].write).to.equal("copy")

      ex.dispatch(ed, "register * write wl-copy read wl-paste")
      expect(ed.reg_backends["*"].read).to.equal("wl-paste")
      expect(ed.reg_backends["*"].write).to.equal("wl-copy")
    end)
    it("merges a read-only then a write-only call", function()
      local ed = make("x")
      ex.dispatch(ed, "register + read pbpaste")
      ex.dispatch(ed, "register + write pbcopy")
      expect(ed.reg_backends["+"].read).to.equal("pbpaste")
      expect(ed.reg_backends["+"].write).to.equal("pbcopy")
    end)
    it("keeps spaces and pipes inside a command", function()
      local ed = make("x")
      ex.dispatch(ed, "register + read xclip -selection clipboard -o")
      expect(ed.reg_backends["+"].read).to.equal("xclip -selection clipboard -o")
    end)
    it("NAME alone clears the backend", function()
      local ed = make("x")
      ex.dispatch(ed, "register + read paste write copy")
      ex.dispatch(ed, "register +")
      expect(ed.reg_backends["+"]).to.equal(nil)
    end)
    it("rejects a multi-char name", function()
      local ed = make("x")
      expect(select(2, ex.dispatch(ed, "register ++ read paste"))).to.equal("err")
    end)
  end)

  describe("yank / delete write-through", function()
    it("pipes a linewise yank to the write command", function()
      local ed = make("hello\nworld")
      ex.dispatch(ed, "register + write copy")
      feed(ed, '"+yy')
      expect(#ed.writes).to.equal(1)
      expect(ed.writes[1].cmd).to.equal("copy")
      expect(ed.writes[1].text).to.equal("hello\n")
      expect(ed.regs["+"].text).to.equal("hello\n")   -- still mirrored in memory
    end)
    it("pipes a charwise delete to the write command", function()
      local ed = make("abc")
      ex.dispatch(ed, "register + write copy")
      feed(ed, '"+x')
      expect(ed.writes[1].text).to.equal("a")
      expect(ed.buf:line(1)).to.equal("bc")
    end)
    it("a plain yank into an unbacked register writes nothing", function()
      local ed = make("abc")
      ex.dispatch(ed, "register + write copy")
      feed(ed, "yy")                                    -- no "+ prefix
      expect(#ed.writes).to.equal(0)
    end)
  end)

  describe("put reads fresh from the backend", function()
    it("charwise clipboard pastes inline", function()
      local ed = make("XY")
      ex.dispatch(ed, "register + read paste")
      ed.clip["paste"] = "Z"
      feed(ed, '"+p')                                   -- put after col 1
      expect(ed.buf:line(1)).to.equal("XZY")
    end)
    it("multi-line clipboard pastes linewise (invariant-safe)", function()
      local ed = make("one\ntwo")
      ex.dispatch(ed, "register + read paste")
      ed.clip["paste"] = "A\nB\n"
      feed(ed, '"+p')                                   -- linewise put below line 1
      expect(ed.buf:get()).to.equal({ "one", "A", "B", "two" })
    end)
    it("multi-line without a trailing newline is still linewise", function()
      local ed = make("one")
      ex.dispatch(ed, "register + read paste")
      ed.clip["paste"] = "A\nB"                          -- no trailing \n
      feed(ed, '"+p')
      expect(ed.buf:get()).to.equal({ "one", "A", "B" })
    end)
    it("an empty clipboard is a no-op put", function()
      local ed = make("one")
      ex.dispatch(ed, "register + read paste")
      ed.clip["paste"] = ""
      feed(ed, '"+p')
      expect(ed.buf:get()).to.equal({ "one" })
    end)
    it("read is fresh each put (reflects an external change)", function()
      local ed = make("x")
      ex.dispatch(ed, "register + read paste")
      ed.clip["paste"] = "1"
      feed(ed, '"+p')
      ed.clip["paste"] = "2"                             -- clipboard changed under us
      feed(ed, '$"+p')
      expect(ed.buf:line(1)).to.equal("x12")
    end)
  end)

  describe(":registers listing", function()
    it("reports nothing on a fresh editor", function()
      local ed = make("x")
      expect(ex.dispatch(ed, "registers")).to.equal("no registers")
    end)
    it("lists contents with type and name, unnamed first", function()
      local ed = make("hello\nworld")
      feed(ed, '"ayy')          -- linewise 'hello' into a (and the unnamed mirror)
      local out = ex.dispatch(ed, "reg")
      expect(out).to.equal('l  ""  hello^J\n' ..    -- ^J = the linewise trailing newline
                           'l  "a  hello^J')
    end)
    it("shows control bytes (a macro) in caret notation", function()
      local ed = make("abc")
      feed(ed, "qaciwX\27q")    -- record ciwX<Esc> into register a
      local out = ex.dispatch(ed, "reg a")
      expect(out).to.equal('c  "a  ciwX^[')
    end)
    it("annotates a command-backed register with its spec", function()
      local ed = make("x")
      ex.dispatch(ed, "register + read wl-paste write wl-copy")
      expect(ex.dispatch(ed, "reg +")).to.equal('   "+  {read wl-paste, write wl-copy}')
      feed(ed, '"+yy')          -- now it also has an in-memory value
      expect(ex.dispatch(ed, "reg +")).to.equal('l  "+  x^J  {read wl-paste, write wl-copy}')
    end)
    it("restricts the list to named registers", function()
      local ed = make("one\ntwo")
      feed(ed, '"ayy')
      feed(ed, 'j"byy')
      expect(ex.dispatch(ed, "reg b")).to.equal('l  "b  two^J')
    end)
  end)

  it("round-trips through an unbacked register normally (no regression)", function()
    local ed = make("keep\ntoss")
    feed(ed, '"ayy')
    expect(ed.regs["a"].text).to.equal("keep\n")
    feed(ed, 'j"ap')
    expect(ed.buf:get()).to.equal({ "keep", "toss", "keep" })
    expect(#ed.writes).to.equal(0)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
