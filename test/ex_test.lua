-- Tests for ex.lua (the shared dispatcher). Run: luajit test/ex_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local ex     = require("ex")
local editor = require("editor")
local sys    = require("sys")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- All ed state comes from the one constructor (editor.new_ed), so these tests
-- exercise dispatch against exactly the fields a real session has.
local function ed_with(text)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  return ed
end

describe("ex.dispatch", function()
  describe("addresses", function()
    it("a bare address moves the cursor", function()
      local ed = ed_with("a\nb\nc\nd")
      local _, s = ex.dispatch(ed, "3")
      expect(s).to.equal("ok")
      expect(ed.cy).to.equal(3)
    end)
    it("clamps an out-of-range address", function()
      local ed = ed_with("a\nb\nc")
      ex.dispatch(ed, "99")
      expect(ed.cy).to.equal(3)
    end)
  end)

  describe("print", function()
    it("prints a range", function()
      local ed = ed_with("a\nb\nc\nd")
      local p, s = ex.dispatch(ed, "2,3p")
      expect(s).to.equal("ok")
      expect(p).to.equal("b\nc")
    end)
    it("% prints the whole buffer", function()
      local ed = ed_with("a\nb\nc")
      expect((ex.dispatch(ed, "%p"))).to.equal("a\nb\nc")
    end)
    it("defaults to the current line", function()
      local ed = ed_with("a\nb\nc"); ed.cy = 2
      expect((ex.dispatch(ed, "p"))).to.equal("b")
    end)
  end)

  describe("delete", function()
    it("deletes a range and repositions the cursor", function()
      local ed = ed_with("a\nb\nc\nd")
      local _, s = ex.dispatch(ed, "2,3d")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "a", "d" })
      expect(ed.cy).to.equal(2)
    end)
    it("defaults to the current line", function()
      local ed = ed_with("a\nb\nc"); ed.cy = 1
      ex.dispatch(ed, "d")
      expect(ed.buf:get()).to.equal({ "b", "c" })
    end)
  end)

  describe("quit", function()
    it("refuses when modified, unless forced", function()
      local ed = ed_with("a\nb")
      ed.buf:set(1, "X")                       -- make it modified
      local _, s = ex.dispatch(ed, "q")
      expect(s).to.equal("err")
      expect(ed.running).to.be(true)
      local _, s2 = ex.dispatch(ed, "q!")
      expect(s2).to.equal("ok")
      expect(ed.running).to.be(false)
    end)
    it("quits a clean buffer", function()
      local ed = ed_with("a")
      local _, s = ex.dispatch(ed, "q")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
    end)
    it(":cq quits a modified buffer unconditionally, exit code 1", function()
      local ed = ed_with("a\nb")
      ed.buf:set(1, "X")                       -- make it modified
      local _, s = ex.dispatch(ed, "cq")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      expect(ed.exit_code).to.equal(1)
    end)
    it(":cq N exits with code N", function()
      local ed = ed_with("a")
      local _, s = ex.dispatch(ed, "cq 7")
      expect(s).to.equal("ok")
      expect(ed.exit_code).to.equal(7)
    end)
  end)

  describe("write", function()
    it("writes to a path and reports bytes", function()
      local ed = ed_with("a\nb\n")
      local tmp = os.tmpname()
      local p, s = ex.dispatch(ed, "w " .. tmp)
      expect(s).to.equal("ok")
      expect(p:find("written", 1, true)).to.exist()
      expect(ed.buf.modified).to.be(false)
      local f = io.open(tmp, "rb"); local body = f:read("*a"); f:close()
      expect(body).to.equal("a\nb\n")
      os.remove(tmp)
    end)
    it("errors without a file name", function()
      local ed = ed_with("a")
      local _, s = ex.dispatch(ed, "w")
      expect(s).to.equal("err")
    end)

    it("refuses to clobber a file changed since last read, unless forced", function()
      local tmp = os.tmpname()
      local ed = ed_with("a\n")
      ed.buf.path = tmp
      ed.file_changed = function() return true end   -- stamp says: file moved
      local stamped = {}
      ed.stamp = function(buf) stamped[#stamped + 1] = buf end
      local p, s = ex.dispatch(ed, "w")
      expect(s).to.equal("err")
      expect(p:find("changed", 1, true)).to.exist()
      local _, s2 = ex.dispatch(ed, "w!")            -- forced: writes and re-stamps
      expect(s2).to.equal("ok")
      expect(#stamped).to.equal(1)
      os.remove(tmp)
    end)

    it("does not treat a save-as to another path as a conflict", function()
      local tmp, other = os.tmpname(), os.tmpname()
      local ed = ed_with("a\n")
      ed.buf.path = tmp
      ed.file_changed = function() return true end
      local _, s = ex.dispatch(ed, "w " .. other)    -- explicit different target
      expect(s).to.equal("ok")
      os.remove(tmp); os.remove(other)
    end)
  end)

  -- File arguments are shell-expanded per POSIX (expand_file in ex.lua): an
  -- arg containing a metacharacter round-trips through `sh -c 'echo <arg>'`,
  -- so ~, $VAR, and globs mean whatever sh says. Plain names (every other
  -- test in this file) never touch the shell.
  describe("file-argument expansion", function()
    local function tmpdir()
      local d = os.tmpname()
      os.remove(d); os.execute("mkdir -p " .. d)
      return d
    end

    it("expands ~ against $HOME in :w", function()
      local dir, home = tmpdir(), os.getenv("HOME")
      sys.setenv("HOME", dir)
      local ed = ed_with("a\n")
      local _, s = ex.dispatch(ed, "w ~/out.txt")
      sys.setenv("HOME", home)
      expect(s).to.equal("ok")
      local f = io.open(dir .. "/out.txt", "rb")
      expect(f).to.exist()
      expect(f:read("*a")).to.equal("a\n"); f:close()
      os.execute("rm -rf " .. dir)
    end)

    it("expands $VAR in :r", function()
      local dir = tmpdir()
      local f = io.open(dir .. "/in.txt", "wb"); f:write("INSERTED\n"); f:close()
      sys.setenv("LVI_TEST_DIR", dir)
      local ed = ed_with("a\nb")
      local _, s = ex.dispatch(ed, "r $LVI_TEST_DIR/in.txt")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "a", "INSERTED", "b" })
      os.execute("rm -rf " .. dir)
    end)

    it("expands a glob that names exactly one file", function()
      local dir = tmpdir()
      local f = io.open(dir .. "/only.txt", "wb"); f:write("GLOBBED\n"); f:close()
      local ed = ed_with("a")
      local _, s = ex.dispatch(ed, "r " .. dir .. "/on*.txt")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "a", "GLOBBED" })
      os.execute("rm -rf " .. dir)
    end)

    it("rejects an expansion to several words", function()
      local dir = tmpdir()
      for _, n in ipairs({ "g1.txt", "g2.txt" }) do
        local f = io.open(dir .. "/" .. n, "wb"); f:write("x"); f:close()
      end
      local ed = ed_with("a")
      local p, s = ex.dispatch(ed, "r " .. dir .. "/g*.txt")
      expect(s).to.equal("err")
      expect(p:find("ambiguous", 1, true)).to.exist()
      os.execute("rm -rf " .. dir)
    end)

    it("rejects an expansion to nothing", function()
      local ed = ed_with("a")
      local p, s = ex.dispatch(ed, "w $LVI_TEST_SURELY_UNSET_")
      expect(s).to.equal("err")
      expect(p:find("no file name", 1, true)).to.exist()
    end)

    it("a quoted name keeps its spaces", function()
      local dir = tmpdir()
      local ed = ed_with("a\n")
      local _, s = ex.dispatch(ed, 'w "' .. dir .. '/sp ace.txt"')
      expect(s).to.equal("ok")
      local f = io.open(dir .. "/sp ace.txt", "rb")
      expect(f).to.exist()
      f:close()
      os.execute('rm -rf "' .. dir .. '"')
    end)

    -- The reason the reprint verb is printf, not the spec's echo: XSI echo
    -- interprets backslash sequences, so this name would come back mangled.
    it("an escaped backslash survives the round trip", function()
      local dir = tmpdir()
      local ed = ed_with("a\n")
      local _, s = ex.dispatch(ed, "w " .. dir .. "/back\\\\slash.txt")
      expect(s).to.equal("ok")
      local f = io.open(dir .. "/back\\slash.txt", "rb")
      expect(f).to.exist()
      f:close()
      os.execute("rm -rf " .. dir)
    end)
  end)

  describe("wbuf", function()
    it("snapshots to the scratch path without touching file/modified", function()
      local ed = ed_with("x\ny\n")
      ed.buffer_scratch = os.tmpname()
      ed.buf:set(1, "EDITED")                        -- make it modified
      local _, s = ex.dispatch(ed, "wbuf")
      expect(s).to.equal("ok")
      local f = io.open(ed.buffer_scratch, "rb"); local body = f:read("*a"); f:close()
      expect(body).to.equal("EDITED\ny\n")           -- live, unsaved content
      expect(ed.buf.path).to_not.exist()             -- not repointed, unlike :w FILE
      expect(ed.buf.modified).to.be(true)            -- still dirty; :wbuf is not a save
      os.remove(ed.buffer_scratch)
    end)
    it("errors when no scratch path is set", function()
      local ed = ed_with("a")                        -- no ed.buffer_scratch
      local _, s = ex.dispatch(ed, "wbuf")
      expect(s).to.equal("err")
    end)
  end)

  describe("write and quit (:wq / :x)", function()
    it(":x on a clean buffer quits WITHOUT writing (leaves mtime alone)", function()
      local ed = ed_with("a\nb\n")
      local target = os.tmpname(); os.remove(target)   -- a path that must stay absent
      ed.buf.path = target
      local fired = {}
      ed.fire_event = function(e) fired[#fired + 1] = e end
      local _, s = ex.dispatch(ed, "x")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      local fh = io.open(target, "rb")
      expect(fh).to_not.exist()                          -- never written
      if fh then fh:close(); os.remove(target) end
      expect(fired).to.equal({})                          -- and no write event
    end)
    it(":x on a modified buffer writes, quits, clears modified, fires write", function()
      local ed = ed_with("a\nb\n")
      local target = os.tmpname()
      ed.buf.path = target
      ed.buf:set(1, "X")                                  -- dirty it
      local fired = {}
      ed.fire_event = function(e) fired[#fired + 1] = e end
      local _, s = ex.dispatch(ed, "x")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      expect(ed.buf.modified).to.be(false)
      expect(fired).to.equal({ "write" })
      local f = io.open(target, "rb"); local body = f:read("*a"); f:close()
      expect(body).to.equal("X\nb\n")
      os.remove(target)
    end)
    it(":x on a modified unnamed buffer errors (no file name)", function()
      local ed = ed_with("a")
      ed.buf:set(1, "X")
      local _, s = ex.dispatch(ed, "x")
      expect(s).to.equal("err")
      expect(ed.running).to.be(true)
    end)
    it(":wq writes even when the buffer is clean (unlike :x)", function()
      local ed = ed_with("a\nb\n")
      local target = os.tmpname(); os.remove(target)
      ed.buf.path = target
      local _, s = ex.dispatch(ed, "wq")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      local f = io.open(target, "rb")
      expect(f).to.exist()                                -- :wq always writes
      if f then f:close() end
      os.remove(target)
    end)
    it(":wa in a headless single-buffer ed writes the lone buffer", function()
      local ed = ed_with("a\nb\n")               -- no ed.buffers -> fallback path
      local target = os.tmpname()
      ed.buf.path = target
      ed.buf:set(1, "X")
      local p, s = ex.dispatch(ed, "wa")
      expect(s).to.equal("ok")
      expect(p).to.equal("1 buffer written")
      local f = io.open(target, "rb"); local body = f:read("*a"); f:close()
      expect(body).to.equal("X\nb\n")
      os.remove(target)
    end)
    it(":wa fires the write event with each written buffer, not the current one", function()
      local buffer_ = require("buffer")
      local ed = ed_with("cur\n")
      local other = buffer_.new("oth\n")
      ed.buf.path, other.path = os.tmpname(), os.tmpname()
      ed.buf:set(1, "CUR"); other:set(1, "OTH")     -- both modified
      ed.buffers = { { buf = ed.buf }, { buf = other } }
      local fired = {}
      ed.fire_event = function(ev, buf) fired[#fired + 1] = { ev, buf } end
      local _, s = ex.dispatch(ed, "wa")
      expect(s).to.equal("ok")
      expect(#fired).to.equal(2)
      expect(fired[1][2]).to.be(ed.buf)             -- each event names its buffer
      expect(fired[2][2]).to.be(other)
      os.remove(ed.buf.path); os.remove(other.path)
    end)
  end)

  describe("set", function()
    it("toggles wrap and queries it", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "set nowrap")
      expect((ex.dispatch(ed, "set wrap?"))).to.equal("nowrap")
      ex.dispatch(ed, "set wrap")
      expect((ex.dispatch(ed, "set wrap?"))).to.equal("wrap")
    end)
    it("toggles a boolean with a trailing !", function()
      local ed = ed_with("x")                    -- wrap defaults on
      ex.dispatch(ed, "set wrap!")
      expect((ex.dispatch(ed, "set wrap?"))).to.equal("nowrap")
      ex.dispatch(ed, "set wrap!")
      expect((ex.dispatch(ed, "set wrap?"))).to.equal("wrap")
    end)
    it("errors toggling a non-boolean", function()
      local _, s = ex.dispatch(ed_with("x"), "set tabstop!")
      expect(s).to.equal("err")
    end)
    it("sets a numeric option", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "set tabstop=4")
      expect((ex.dispatch(ed, "set tabstop?"))).to.equal("tabstop=4")
    end)
    it("sets shiftwidth (and its sw alias)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "set sw=2")
      expect((ex.dispatch(ed, "set shiftwidth?"))).to.equal("shiftwidth=2")
    end)
    it("rejects a zero, negative, or non-numeric tabstop/shiftwidth", function()
      local ed = ed_with("x")
      for _, bad in ipairs({ "set ts=0", "set ts=-4", "set ts=abc", "set sw=0" }) do
        local _, s = ex.dispatch(ed, bad)
        expect(s).to.equal("err")
      end
      expect(ed.opts.tabstop).to.equal(8)          -- untouched by the rejects
      ex.dispatch(ed, "set ts=4.9")                -- fractional: floored
      expect(ed.opts.tabstop).to.equal(4)
    end)
    it("toggles expandtab and queries it", function()
      local ed = ed_with("x")
      expect((ex.dispatch(ed, "set expandtab?"))).to.equal("noexpandtab")
      ex.dispatch(ed, "set et")
      expect((ex.dispatch(ed, "set expandtab?"))).to.equal("expandtab")
      ex.dispatch(ed, "set expandtab!")
      expect((ex.dispatch(ed, "set et?"))).to.equal("noexpandtab")
    end)
    it("errors on an unknown option", function()
      local _, s = ex.dispatch(ed_with("x"), "set bogus")
      expect(s).to.equal("err")
    end)
    it("queries, clears, and forces the modified flag", function()
      local ed = ed_with("abc")
      expect((ex.dispatch(ed, "set modified?"))).to.equal("nomodified")
      ed.buf:set(1, "X")                              -- an edit dirties the buffer
      expect((ex.dispatch(ed, "set mod?"))).to.equal("modified")
      ex.dispatch(ed, "set nomodified")               -- clear: align the saved-marker
      expect((ex.dispatch(ed, "set modified?"))).to.equal("nomodified")
      ed.buf:undo_checkpoint()                        -- a command boundary (new change group)
      ed.buf:set(1, "Y")                              -- a later edit still dirties: not sticky
      expect((ex.dispatch(ed, "set modified?"))).to.equal("modified")
      ex.dispatch(ed, "set nomod")                    -- alias clears again
      ex.dispatch(ed, "set mod")                      -- and force it dirty
      expect((ex.dispatch(ed, "set modified?"))).to.equal("modified")
    end)
  end)

  describe("highlights and position", function()
    it("sets and clears named highlight groups", function()
      local ed = ed_with("hello\nworld")
      ex.dispatch(ed, "hl search 1:1-3 2:1")
      expect(ed.highlights.search[1]).to.equal({ line = 1, c1 = 1, c2 = 3 })
      expect(ed.highlights.search[2]).to.equal({ line = 2, c1 = 1, c2 = 1 })
      ex.dispatch(ed, "nohl")
      expect(next(ed.highlights)).to_not.exist()
    end)
    it("rejects a bad highlight spec", function()
      local _, s = ex.dispatch(ed_with("x"), "hl g nonsense")
      expect(s).to.equal("err")
    end)
    it(":hi defines a group's SGR style (name colors, 256, attrs)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "hi Keyword fg=blue bold")
      expect(ed.hlstyles.Keyword).to.equal("34;1")
      ex.dispatch(ed, "hi String fg=34 bg=235 underline")
      expect(ed.hlstyles.String).to.equal("38;5;34;48;5;235;4")
    end)
    it(":hi accepts a raw sgr= passthrough (ANSI backends, truecolor)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "hi syn0 sgr=38;2;255;0;255")
      expect(ed.hlstyles.syn0).to.equal("38;2;255;0;255")
      ex.dispatch(ed, "hi syn1 sgr=1;31")
      expect(ed.hlstyles.syn1).to.equal("1;31")
    end)
    it(":hi with no spec (or NONE) clears the style", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "hi Keyword fg=red")
      ex.dispatch(ed, "hi Keyword")
      expect(ed.hlstyles.Keyword).to_not.exist()
    end)
    it(":hi rejects a bad color or attribute", function()
      local ed = ed_with("x")
      expect(select(2, ex.dispatch(ed, "hi X fg=chartreuse"))).to.equal("err")
      expect(select(2, ex.dispatch(ed, "hi X fg=999"))).to.equal("err")
      expect(select(2, ex.dispatch(ed, "hi X sparkle"))).to.equal("err")
    end)
    it(":hl still sets ranges (not styles)", function()
      local ed = ed_with("hello")
      ex.dispatch(ed, "hl search 1:1-3")
      expect(ed.highlights.search[1]).to.equal({ line = 1, c1 = 1, c2 = 3 })
    end)
    it(":on registers, appends, and clears change hooks", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on change lvi-highlight")
      ex.dispatch(ed, "on change echo hi")
      expect(ed.hooks.change).to.equal({ "lvi-highlight", "echo hi" })
      ex.dispatch(ed, "on change")            -- no command clears
      expect(ed.hooks.change).to_not.exist()
    end)
    it(":on rejects an unknown event", function()
      expect(select(2, ex.dispatch(ed_with("x"), "on save foo"))).to.equal("err")
    end)
    it(":on complete replaces (single completer) rather than appending", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on complete echo one")
      ex.dispatch(ed, "on complete lvi-complete")   -- replaces, does not append
      expect(ed.hooks.complete).to.equal({ "lvi-complete" })
      ex.dispatch(ed, "on complete")                -- no command clears
      expect(ed.hooks.complete).to_not.exist()
    end)
    it(":on ready registers a startup hook", function()
      local ed = ed_with("x")
      expect(select(2, ex.dispatch(ed, [[on ready lvi-list load "$LVI_QUICKFIX" quickfix]]))).to.equal("ok")
      expect(ed.hooks.ready).to.equal({ [[lvi-list load "$LVI_QUICKFIX" quickfix]] })
    end)
    it(":on registers the buffer events", function()
      local ed = ed_with("x")
      for _, e in ipairs({ "bufenter", "bufleave", "bufdelete" }) do
        expect(select(2, ex.dispatch(ed, "on " .. e .. " lvi-list paint"))).to.equal("ok")
        expect(ed.hooks[e]).to.equal({ "lvi-list paint" })
      end
    end)
    it(":on write registers a hook", function()
      local ed = ed_with("x")
      expect(select(2, ex.dispatch(ed, "on write lvi-mirror"))).to.equal("ok")
      expect(ed.hooks.write).to.equal({ "lvi-mirror" })
    end)
    it(":w fires the write event (and clears modified)", function()
      local fired = {}
      local ed = ed_with("hello")
      ed.fire_event = function(e) fired[#fired + 1] = e end
      ed.buf.path = os.tmpname()
      ed.buf:set(1, "changed")                        -- dirty, so :w actually writes
      local _, s = ex.dispatch(ed, "w")
      os.remove(ed.buf.path)
      expect(s).to.equal("ok")
      expect(fired).to.equal({ "write" })
      expect(ed.buf.modified).to.be(false)
    end)
    it(":pos reports the cursor as line<TAB>col", function()
      local ed = ed_with("a\nb\nc")
      ex.dispatch(ed, "3")
      expect((ex.dispatch(ed, "pos"))).to.equal("3\t1")
    end)
    it(":top reports the viewport top line", function()
      local ed = ed_with("a\nb\nc\nd"); ed.top = 2
      expect((ex.dispatch(ed, "top"))).to.equal("2")
    end)
    it(":top N scrolls line N to the top and parks the cursor there", function()
      local ed = ed_with("a\nb\nc\nd\ne")
      local _, s = ex.dispatch(ed, "top 3")
      expect(s).to.equal("ok")
      expect(ed.top).to.equal(3)
      expect(ed.cy).to.equal(3)   -- cursor at top so refresh() holds the scroll
      expect(ed.cx).to.equal(1)
    end)
    it(":top N clamps an out-of-range line", function()
      local ed = ed_with("a\nb\nc")
      ex.dispatch(ed, "top 99")
      expect(ed.top).to.equal(3)
      expect(ed.cy).to.equal(3)
    end)
    it(":status sets and clears named segments", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "status list [3/57] search")
      expect(ed.status.list).to.equal("[3/57] search")
      ex.dispatch(ed, "status list")               -- empty text clears
      expect(ed.status.list).to_not.exist()
    end)
  end)

  describe("shelling out", function()
    it(":!cmd captures output (no tty -> capture path)", function()
      local out, s = ex.dispatch(ed_with("x"), "!echo hello")
      expect(s).to.equal("ok")
      expect(out).to.equal("hello\n")
    end)
    it(":[range]!cmd filters lines through a command", function()
      local ed = ed_with("banana\napple\ncherry")
      local _, s = ex.dispatch(ed, "%!sort")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "apple", "banana", "cherry" })
    end)
    it("a filter is one undo", function()
      local ed = ed_with("b\na")
      ex.dispatch(ed, "%!sort")
      expect(ed.buf:get()).to.equal({ "a", "b" })
      ed.buf:undo()
      expect(ed.buf:get()).to.equal({ "b", "a" })
    end)
    it(":r !cmd reads command output into the buffer", function()
      local ed = ed_with("one\ntwo")
      ex.dispatch(ed, "r !printf 'A\\nB\\n'")
      expect(ed.buf:get()).to.equal({ "one", "A", "B", "two" })
    end)
    it(":r file reads a file", function()
      local p = os.tmpname(); local f = io.open(p, "wb"); f:write("X\nY\n"); f:close()
      local ed = ed_with("top")
      ex.dispatch(ed, "r " .. p)
      expect(ed.buf:get()).to.equal({ "top", "X", "Y" })
      os.remove(p)
    end)
    it(":silent runs the sub-command (capture path)", function()
      expect((ex.dispatch(ed_with("x"), "silent !echo hi"))).to.equal("hi\n")
    end)
    it(":fire arms the change debounce; :fire EVENT fires immediately", function()
      local ed = ed_with("x")
      local _, s = ex.dispatch(ed, "fire")
      expect(s).to.equal("ok")
      expect(ed.change_pending).to.be(true)          -- rides the idle debounce
      local fired = {}
      ed.fire_event = function(ev) fired[#fired + 1] = ev end
      ex.dispatch(ed, "fire write")
      expect(fired).to.equal({ "write" })            -- non-change: immediate
      local _, s2 = ex.dispatch(ed, "fire bogus")
      expect(s2).to.equal("err")
    end)
    it(":silent clears its flag even when the sub-command throws", function()
      local ed = ed_with("x")
      local real = ex.dispatch
      ex.dispatch = function(e, l)                      -- silent recurses via the
        if l == "BOOM" then error("boom") end           -- module table, so this
        return real(e, l)                               -- wrapper intercepts it
      end
      local ok = pcall(ex.dispatch, ed, "silent BOOM")
      ex.dispatch = real
      expect(ok).to.be(false)                           -- error still propagates
      expect(ed._silent).to_not.exist()                 -- ...but the flag is clear
    end)
    it("a failed filter preserves the buffer and reports the exit code", function()
      local ed = ed_with("keep\nthis\ntext")
      local _, s = ex.dispatch(ed, "%!false")           -- false exits 1
      expect(s).to.equal("err")
      expect(ed.buf:get()).to.equal({ "keep", "this", "text" })
    end)
    it(":!cmd reports a non-zero exit", function()
      local _, s = ex.dispatch(ed_with("x"), "!false")
      expect(s).to.equal("err")
    end)
    it(":bg spawns detached via spawn_bg (no tty handover)", function()
      local ed = ed_with("x"); local got
      ed.spawn_bg = function(cmd) got = cmd end
      local _, s = ex.dispatch(ed, "bg lvi-list next")
      expect(s).to.equal("ok")
      expect(got).to.equal("lvi-list next")            -- ran through spawn_bg, not with_tty
      expect(select(2, ex.dispatch(ed, "bg"))).to.equal("err")   -- empty command
    end)
    it("stamps the cursor context into a spawned command's environment", function()
      local sys = require("sys")
      local normal = require("normal")
      local ed = ed_with("alpha beta"); ed.buf.path = "dir/file.txt"; ed.cy, ed.cx = 1, 7
      ed.export_context = function()                     -- as editor.lua wires it
        sys.setenv("LVI_FILE", ed.buf.path or "")
        sys.setenv("LVI_LINE", ed.cy); sys.setenv("LVI_COL", ed.cx)
        sys.setenv("LVI_CWORD", normal.cword(ed))
      end
      local out = (ex.dispatch(ed, [[!printf '%s\n' "$LVI_LINE:$LVI_COL $LVI_CWORD ${LVI_FILE##*/}"]]))
      expect(out).to.equal("1:7 beta file.txt\n")        -- col 7 is inside 'beta'
    end)
    it("a failed :r !cmd inserts nothing", function()
      local ed = ed_with("a\nb")
      local _, s = ex.dispatch(ed, "r !false")
      expect(s).to.equal("err")
      expect(ed.buf:get()).to.equal({ "a", "b" })
    end)
  end)

  -- Commands lvi does not implement are delegated to the system ex. These
  -- shell out, so they only run where an `ex` is installed; skip otherwise so
  -- the suite stays dependency-free.
  describe("delegation to /bin/ex", function()
    local have_ex = os.execute("command -v '" .. (os.getenv("LVI_EX") or "ex")
                               .. "' >/dev/null 2>&1") == 0

    it("runs :s (substitute) through ex", function()
      if not have_ex then return end
      local ed = ed_with("foo one\nfoo two\nbar")
      local _, s = ex.dispatch(ed, "%s/foo/X/")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "X one", "X two", "bar" })
    end)

    it("runs :g (global) through ex", function()
      if not have_ex then return end
      local ed = ed_with("keep\ndrop me\nkeep2\ndrop again")
      ex.dispatch(ed, "g/drop/d")
      expect(ed.buf:get()).to.equal({ "keep", "keep2" })
    end)

    it("injects lvi marks so a mark-addressed range resolves", function()
      if not have_ex then return end
      local ed = ed_with("a\nb\nc\nd")
      ed.marks = { a = { 2, 1 } }
      ex.dispatch(ed, "'a,$s/^/> /")
      expect(ed.buf:get()).to.equal({ "a", "> b", "> c", "> d" })
    end)

    it("leaves the buffer untouched on a bogus command (safe no-op)", function()
      if not have_ex then return end
      local ed = ed_with("x\ny\nz")
      local _, s = ex.dispatch(ed, "totalgibberish")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "x", "y", "z" })
    end)

    it("splices only the changed window, so distant marks survive", function()
      if not have_ex then return end
      local editor = require("editor")
      local ed = ed_with("aaa\nbbb\nccc\nddd\neee")
      ed.marks = { m = { 5, 1 } }
      ed.splice_hook = editor.make_splice_hook(ed)
      ed.buf.on_splice = ed.splice_hook
      ex.dispatch(ed, "2s/bbb/BBB/")             -- one-line edit far above the mark
      expect(ed.buf:line(2)).to.equal("BBB")
      expect(ed.marks.m).to.equal({ 5, 1 })      -- whole-buffer splice would clamp to 1
      ex.dispatch(ed, "1d")                      -- a deletion above shifts it
      expect(ed.marks.m).to.equal({ 4, 1 })
    end)

    it(":sysex hands the line to the system ex verbatim (bypasses lvi's table)", function()
      if not have_ex then return end
      local ed = ed_with("a\nb\nc")
      local _, s = ex.dispatch(ed, "sysex 2d")     -- ex's :d, not lvi's
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "a", "c" })
      local _, s2 = ex.dispatch(ed, "sysex")
      expect(s2).to.equal("err")                   -- usage error when empty
    end)

    it("trims to a small splice: one :s produces a one-line undo record", function()
      if not have_ex then return end
      local ed = ed_with("aaa\nbbb\nccc")
      ed.buf:undo_checkpoint()
      ex.dispatch(ed, "2s/bbb/BBB/")
      local l = ed.buf:undo()
      expect(l).to.equal(2)                      -- inverse lands on line 2, not line 1
      expect(ed.buf:get()).to.equal({ "aaa", "bbb", "ccc" })
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
