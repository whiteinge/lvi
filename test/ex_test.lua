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
    it("resolves a mark range ('a,'b)", function()
      local ed = ed_with("a\nb\nc\nd\ne")
      ed.marks["a"] = { 2, 1 }
      ed.marks["b"] = { 4, 1 }
      expect((ex.dispatch(ed, "'a,'bp"))).to.equal("b\nc\nd")
    end)
    it("folds +/- offsets (bare +/- is +/-1, and they chain)", function()
      local ed = ed_with("a\nb\nc\nd\ne\nf"); ed.cy = 2
      expect((ex.dispatch(ed, ".+2p"))).to.equal("d")   -- 2 + 2 = 4
      expect((ex.dispatch(ed, "$-1p"))).to.equal("e")   -- 6 - 1 = 5
      expect((ex.dispatch(ed, ".+3-1p"))).to.equal("d") -- 2 + 3 - 1 = 4
    end)
    it("a leading offset counts from the current line (:+p)", function()
      local ed = ed_with("a\nb\nc\nd"); ed.cy = 2
      expect((ex.dispatch(ed, "+p"))).to.equal("c")     -- next line
      expect((ex.dispatch(ed, "-p"))).to.equal("a")     -- previous line
    end)
    it("';' evaluates the second address from the first, ',' from the cursor", function()
      local ed = ed_with("a\nb\nc\nd\ne\nf"); ed.cy = 5
      expect((ex.dispatch(ed, "1;+2p"))).to.equal("a\nb\nc")       -- +2 from line 1
      expect((ex.dispatch(ed, "1,+2p"))).to.equal("a\nb\nc\nd\ne\nf") -- +2 from cursor (5) -> clamped $
    end)
    it("defers an unset mark to the system ex without mutating (safe no-op)", function()
      local ed = ed_with("a\nb\nc")
      local _, s = ex.dispatch(ed, "'z,'yd")   -- marks never set -> falls through to ex
      expect(ed.buf:get()).to.equal({ "a", "b", "c" })
      expect(s).to.equal("ok")                 -- ex-unrunnable is a safe no-op by design
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
    it("a mark-addressed delete now fills the unnamed register", function()
      local ed = ed_with("a\nb\nc\nd\ne")
      ed.marks["a"] = { 2, 1 }
      ed.marks["b"] = { 4, 1 }
      ex.dispatch(ed, "'a,'bd")
      expect(ed.buf:get()).to.equal({ "a", "e" })
      expect(ed.regs['"'].text).to.equal("b\nc\nd\n")
      expect(ed.regs['"'].linewise).to.equal(true)
    end)
    it("populates the numbered stack, shifting on each :d", function()
      local ed = ed_with("a\nb\nc\nd")
      ex.dispatch(ed, "1d")
      expect(ed.regs["1"].text).to.equal("a\n")
      ex.dispatch(ed, "1d")                      -- delete "b"; "a" shifts to "2
      expect(ed.regs["1"].text).to.equal("b\n")
      expect(ed.regs["2"].text).to.equal("a\n")
    end)
    it(":d _ (black-hole) deletes without touching any register", function()
      local ed = ed_with("a\nb\nc")
      ex.dispatch(ed, "1d")                      -- seed '"' and "1 with "a"
      local _, s = ex.dispatch(ed, "1d _")
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "c" })
      expect(ed.regs['"'].text).to.equal("a\n")  -- untouched by the black-hole
      expect(ed.regs["1"].text).to.equal("a\n")
      expect(ed.regs["2"]).to.equal(nil)
    end)
    it("set_reg to _ is a no-op on every surface (normal-mode \"_)", function()
      local ed = ed_with("x")
      ex.set_reg(ed, "_", "gone", false)
      expect(ed.regs["_"]).to.equal(nil)
      expect(ed.regs['"']).to.equal(nil)
    end)
    it(":undojoin makes the next command join the last undo group", function()
      local ed = ed_with("a\nb\nc")
      -- Mimic the socket loop: a checkpoint before each dispatch.
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "undojoin")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ex.dispatch(ed, "u")
      expect(ed.buf:get()).to.equal({ "a", "b", "c" })   -- ONE undo reverts both
    end)
    it("without :undojoin the same sequence is two undo steps", function()
      local ed = ed_with("a\nb\nc")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ex.dispatch(ed, "u")
      expect(ed.buf:get()).to.equal({ "b", "c" })        -- only the second came back
    end)
    it(":undojoin keeps a joined post-save edit reading as modified", function()
      local ed = ed_with("a\nb\nc")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ed.buf:undo_checkpoint()
      ed.buf._undo.saved = ed.buf._undo.now              -- as :w records it
      ed.buf.modified = false
      ex.dispatch(ed, "undojoin")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      expect(ed.buf.modified).to.equal(true)             -- joined edit past the save
    end)
    it(":undojoin right after an undo is declined (redo stays intact)", function()
      local ed = ed_with("a\nb\nc")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")
      ex.dispatch(ed, "u")
      ex.dispatch(ed, "undojoin")
      ed.buf:undo_checkpoint(); ex.dispatch(ed, "1d")    -- a fresh change
      expect(ed.buf:get()).to.equal({ "b", "c" })
      ex.dispatch(ed, "u")
      expect(ed.buf:get()).to.equal({ "a", "b", "c" })   -- undone separately
    end)
  end)

  describe("path", function()
    it("prints the buffer's path verbatim", function()
      local ed = ed_with("x")
      ed.buf.path = "/tmp/some dir/foo.txt"
      expect((ex.dispatch(ed, "path"))).to.equal("/tmp/some dir/foo.txt")
    end)
    it("prints empty for a pathless buffer (display names stay out)", function()
      local ed = ed_with("x")
      ed.buf.name = "[stdin]"
      local p, s = ex.dispatch(ed, "path")
      expect(s).to.equal("ok")
      expect(p).to.equal("")
    end)
  end)

  -- POSIX `file [file]`: repoint the buffer without writing it. The move that
  -- follows an external rename, where `:w NAME` would be wrong (it saves).
  describe("file (:f)", function()
    it("reports the current path", function()
      local ed = ed_with("a\nb")
      ed.buf.path = "/tmp/foo.txt"
      local p, s = ex.dispatch(ed, "f")
      expect(s).to.equal("ok")
      expect(p).to.equal('"/tmp/foo.txt" 2 lines')
    end)

    it("sets the path without writing or dirtying the buffer", function()
      local ed = ed_with("a\n")
      ed.buf.path = "/tmp/old.txt"
      local stamped = 0
      ed.stamp = function() stamped = stamped + 1 end
      local p, s = ex.dispatch(ed, "f /tmp/new.txt")
      expect(s).to.equal("ok")
      expect(ed.buf.path).to.equal("/tmp/new.txt")
      expect(ed.buf.modified).to.be(false)           -- POSIX: renaming is not an edit
      expect(stamped).to.equal(1)                    -- re-stamped against the new file
      expect(p).to.equal('"/tmp/new.txt" 1 lines')
      expect((ex.dispatch(ed, "path"))).to.equal("/tmp/new.txt")
    end)

    it("fires bufenter, but only when the name actually moves", function()
      local ed = ed_with("a\n")
      ed.buf.path = "/tmp/old.txt"
      local fired = {}
      ed.fire_event = function(e) fired[#fired + 1] = e end
      ex.dispatch(ed, "f /tmp/new.txt")
      expect(fired).to.equal({ "bufenter" })
      fired = {}
      ex.dispatch(ed, "f /tmp/new.txt")                -- same name again
      expect(fired).to.equal({})
      fired = {}
      ex.dispatch(ed, "f")                             -- the report form
      expect(fired).to.equal({})
    end)

    it("names a pathless buffer", function()
      local ed = ed_with("x")
      ed.buf.name = "[stdin]"
      ex.dispatch(ed, "f /tmp/named.txt")
      expect(ed.buf.path).to.equal("/tmp/named.txt")
    end)

    it("takes -- NAME literally, like every other file command", function()
      local ed = ed_with("x")
      local _, s = ex.dispatch(ed, "f -- /tmp/a $b.txt")
      expect(s).to.equal("ok")
      expect(ed.buf.path).to.equal("/tmp/a $b.txt")
    end)
  end)

  describe("set_del_reg classifier", function()
    it("a linewise delete is large (-> \"1)", function()
      local ed = ed_with("x")
      ex.set_del_reg(ed, nil, "line\n", true)
      expect(ed.regs["1"].text).to.equal("line\n")
      expect(ed.regs["-"]).to.equal(nil)
    end)
    it("a charwise delete spanning a newline is large (-> \"1)", function()
      local ed = ed_with("x")
      ex.set_del_reg(ed, nil, "abc\ndef", false)
      expect(ed.regs["1"].text).to.equal("abc\ndef")
      expect(ed.regs["-"]).to.equal(nil)
    end)
    it("a charwise single-line delete is small (-> \"-)", function()
      local ed = ed_with("x")
      ex.set_del_reg(ed, nil, "abc", false)
      expect(ed.regs["-"].text).to.equal("abc")
      expect(ed.regs["1"]).to.equal(nil)
    end)
    it("a named register skips numbered/small bookkeeping", function()
      local ed = ed_with("x")
      ex.set_del_reg(ed, nil, "first\n", true)   -- seeds "1
      ex.set_del_reg(ed, "a", "second\n", true)  -- into "a; "1 must not shift
      expect(ed.regs["a"].text).to.equal("second\n")
      expect(ed.regs['"'].text).to.equal("second\n")
      expect(ed.regs["1"].text).to.equal("first\n")
      expect(ed.regs["2"]).to.equal(nil)
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

    it("readonly blocks :w to the buffer's own file unless forced", function()
      local tmp = os.tmpname()
      local ed = ed_with("a\n")
      ed.buf.path = tmp
      ex.dispatch(ed, "set readonly")
      local p, s = ex.dispatch(ed, "w")              -- own path: refused
      expect(s).to.equal("err")
      expect(p:find("readonly", 1, true)).to.exist()
      local _, s2 = ex.dispatch(ed, "w!")            -- forced: writes anyway
      expect(s2).to.equal("ok")
      os.remove(tmp)
    end)

    it("readonly still allows a save-as to a different path", function()
      local tmp, other = os.tmpname(), os.tmpname()
      local ed = ed_with("a\n")
      ed.buf.path = tmp
      ex.dispatch(ed, "set readonly")
      local _, s = ex.dispatch(ed, "w " .. other)    -- different target: allowed
      expect(s).to.equal("ok")
      os.remove(tmp); os.remove(other)
    end)
  end)

  -- POSIX's other two write forms, plus the range every form takes. Only a
  -- whole-buffer write to a file is the buffer saving itself; the rest write
  -- FROM the buffer and must leave its name and dirty state alone.
  describe("ranged / append / pipe writes", function()
    local function slurp(p)
      local f = io.open(p, "rb"); local body = f:read("*a"); f:close(); return body
    end

    it("writes only the addressed range, leaving the buffer modified", function()
      local ed = ed_with("a\nb\nc\nd\n")
      local tmp = os.tmpname()
      ed.buf.path = "/nonexistent/original"
      ed.buf.modified = true
      local p, s = ex.dispatch(ed, "2,3w " .. tmp)
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("b\nc\n")
      expect(p:find("2L", 1, true)).to.exist()
      expect(ed.buf.path).to.equal("/nonexistent/original")   -- no repoint
      expect(ed.buf.modified).to.be(true)                     -- partial: still dirty
      os.remove(tmp)
    end)

    it("a whole-buffer write is still a save-as: repoints and cleans", function()
      local ed = ed_with("a\nb\n")
      local tmp = os.tmpname()
      local _, s = ex.dispatch(ed, "1,2w " .. tmp)   -- addressed, but the whole buffer
      expect(s).to.equal("ok")
      expect(ed.buf.path).to.equal(tmp)
      expect(ed.buf.modified).to.be(false)
      os.remove(tmp)
    end)

    it("appends with >> instead of replacing", function()
      local ed = ed_with("c\nd\n")
      local tmp = os.tmpname()
      local f = io.open(tmp, "wb"); f:write("a\nb\n"); f:close()
      ed.buf.modified = true
      local p, s = ex.dispatch(ed, "w >>" .. tmp)
      expect(s).to.equal("ok")
      expect(p:find("appended", 1, true)).to.exist()
      expect(slurp(tmp)).to.equal("a\nb\nc\nd\n")
      expect(ed.buf.path).to.be(nil)                 -- an append names no identity
      expect(ed.buf.modified).to.be(true)
      os.remove(tmp)
    end)

    it("appends only the addressed range", function()
      local ed = ed_with("a\nb\nc\n")
      local tmp = os.tmpname()
      local f = io.open(tmp, "wb"); f:write("x\n"); f:close()
      local _, s = ex.dispatch(ed, "3w >> " .. tmp)
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("x\nc\n")
      os.remove(tmp)
    end)

    it("an interior slice of a noeol buffer still ends newline-terminated", function()
      local ed = ed_with("a\nb")                     -- no final newline
      expect(ed.buf.noeol).to.be(true)
      local tmp = os.tmpname()
      ex.dispatch(ed, "1w " .. tmp)
      expect(slurp(tmp)).to.equal("a\n")            -- interior: terminated
      ex.dispatch(ed, "2w " .. tmp)
      expect(slurp(tmp)).to.equal("b")               -- reaches the end: noeol honored
      os.remove(tmp)
    end)

    it("pipes the range to a command with :w !cmd", function()
      local ed = ed_with("a\nb\nc\n")
      local tmp = os.tmpname()
      ed.buf.modified = true
      local _, s = ex.dispatch(ed, "2,3w !cat > " .. tmp)
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("b\nc\n")
      expect(ed.buf.modified).to.be(true)            -- a pipe is not a save
      os.remove(tmp)
    end)

    it("feeds the whole pipeline, not just its last stage", function()
      local ed = ed_with("b\na\n")
      local tmp = os.tmpname()
      local _, s = ex.dispatch(ed, "w !sort | cat > " .. tmp)
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("a\nb\n")
      os.remove(tmp)
    end)

    it("reports a failing :w !cmd", function()
      local ed = ed_with("a\n")
      local _, s = ex.dispatch(ed, "w !exit 3")
      expect(s).to.equal("err")
    end)

    -- The .lvi~ copy is about the bytes already in the file, not the buffer's
    -- identity: `:1,2w` with no name REPLACES the buffer's own file, and a
    -- write cut short there would leave neither the old text nor the new.
    it("a partial write reaps its .lvi~ safety copy", function()
      local ed = ed_with("a\nb\nc\n")
      local tmp = os.tmpname()
      ed.buf.path = tmp
      local _, s = ex.dispatch(ed, "1,2w " .. tmp)   -- replaces our OWN file
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("a\nb\n")
      expect(io.open(tmp .. ".lvi~", "rb")).to_not.exist()   -- removed on success
      os.remove(tmp)
    end)

    -- A directory: the sibling copy opens fine, the target cannot -- so this is
    -- the branch that has a copy on disk and has to reap it.
    it("a partial write that cannot open the target reaps the copy anyway", function()
      local ed = ed_with("a\nb\nc\n")
      local dir = os.tmpname(); os.remove(dir)
      os.execute("mkdir -p '" .. dir .. "'")
      local _, s = ex.dispatch(ed, "1,2w " .. dir)
      expect(s).to.equal("err")
      expect(io.open(dir .. ".lvi~", "rb")).to_not.exist()   -- no stray copy
      os.execute("rmdir '" .. dir .. "'")
    end)

    -- A save-as changes which file the buffer IS, so everything keyed to the
    -- name is stale: the socket sidecar lvi -l reads, an `on bufenter` hook
    -- that picks settings off the extension.
    it("a save-as fires bufenter, a write to the same path does not", function()
      local ed = ed_with("a\n")
      local tmp = os.tmpname()
      local fired = {}
      ed.fire_event = function(e) fired[#fired + 1] = e end
      ex.dispatch(ed, "w " .. tmp)
      expect(fired).to.equal({ "bufenter", "write" })  -- identity, then the write
      fired = {}
      ex.dispatch(ed, "w")                             -- same path: no repoint
      expect(fired).to.equal({ "write" })
      os.remove(tmp)
    end)

    it("w! before a name is still a forced file write, not a pipe", function()
      local ed = ed_with("a\n")
      local tmp = os.tmpname()
      ed.buf.path = tmp
      ed.file_changed = function() return true end
      local _, s = ex.dispatch(ed, "w!")             -- bang, no args: forced write
      expect(s).to.equal("ok")
      expect(slurp(tmp)).to.equal("a\n")
      os.remove(tmp)
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

    it("`-- NAME` takes the name literally, metacharacters and all", function()
      local dir = tmpdir()
      local name = dir .. "/we $ird `x'.txt"
      local f = io.open(name, "wb"); f:write("LITERAL\n"); f:close()
      local ed = ed_with("a")
      local _, s = ex.dispatch(ed, "r -- " .. name)
      expect(s).to.equal("ok")
      expect(ed.buf:get()).to.equal({ "a", "LITERAL" })
      os.execute("rm -rf '" .. dir .. "'")
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
    -- :w's other two forms are write-only, and `>` and `!` are not
    -- metacharacters expand_file expands -- so left to fall through they became
    -- literal file names: `:wq !cat` created `!cat`, repointed the buffer at it
    -- and quit. Refuse them instead.
    it(":wq and :x refuse >> and !cmd instead of taking them as a name", function()
      for _, cmd in ipairs({ "wq >>log", "wq !cat", "x >>log", "x !cat" }) do
        local ed = ed_with("a\nb\n")
        ed.buf.path = "/nonexistent/original"
        local msg, s = ex.dispatch(ed, cmd)
        expect(s).to.equal("err")
        expect(msg:find("file name only", 1, true)).to.exist()
        expect(ed.running).to.be(true)                       -- and did NOT quit
        expect(ed.buf.path).to.equal("/nonexistent/original")  -- nor repoint
      end
    end)
    it("wq! before a name is still a forced write, not a rejected form", function()
      local ed = ed_with("a\n")
      local target = os.tmpname()
      ed.file_changed = function() return true end
      local _, s = ex.dispatch(ed, "wq! " .. target)
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      os.remove(target)
    end)
    -- The range :wq shares with :w, and vim's E140 rule for it: the lines
    -- outside a partial range are not written, so quitting on one discards
    -- them. Forced, that is your call to make.
    it(":wq refuses a partial range unless forced, then honors it", function()
      local ed = ed_with("a\nb\nc\nd\n")
      local target = os.tmpname()
      ed.buf.path = target
      local msg, s = ex.dispatch(ed, "1,2wq")
      expect(s).to.equal("err")
      expect(msg:find("partial buffer", 1, true)).to.exist()
      expect(ed.running).to.be(true)

      local _, s2 = ex.dispatch(ed, "1,2wq!")
      expect(s2).to.equal("ok")
      expect(ed.running).to.be(false)
      local f = io.open(target, "rb"); local body = f:read("*a"); f:close()
      expect(body).to.equal("a\nb\n")               -- the range, not the buffer
      os.remove(target)
    end)
    it(":x with a whole-buffer range still skips a clean write", function()
      local ed = ed_with("a\nb\n")
      local target = os.tmpname(); os.remove(target)
      ed.buf.path = target
      local _, s = ex.dispatch(ed, "1,2x")
      expect(s).to.equal("ok")
      expect(ed.running).to.be(false)
      local f = io.open(target, "rb")
      expect(f).to_not.exist()                       -- clean: never written
      if f then f:close(); os.remove(target) end
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
    it("sets fmtprg to a space-bearing rest-of-line value (and fp alias/query)", function()
      local ed = ed_with("x")
      expect((ex.dispatch(ed, "set fmtprg?"))).to.equal("fmtprg=fmt")   -- default seed
      ex.dispatch(ed, "set fmtprg=fmt -w 72")                           -- value keeps its spaces
      expect(ed.opts.fmtprg).to.equal("fmt -w 72")
      expect((ex.dispatch(ed, "set fp?"))).to.equal("fmtprg=fmt -w 72")
      ex.dispatch(ed, "set fp=par 40")                                  -- the fp alias also sets
      expect(ed.opts.fmtprg).to.equal("par 40")
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
    it("marks a buffer scratch, querying and toggling it", function()
      local ed = ed_with("abc")
      expect((ex.dispatch(ed, "set scratch?"))).to.equal("noscratch")
      ex.dispatch(ed, "set scratch")
      expect(ed.buf.scratch).to.be(true)
      expect((ex.dispatch(ed, "set scratch?"))).to.equal("scratch")
      ex.dispatch(ed, "set scratch!")                 -- toggle back off
      expect((ex.dispatch(ed, "set scratch?"))).to.equal("noscratch")
    end)
    it("marks a buffer readonly, querying and toggling it (ro/noro aliases)", function()
      local ed = ed_with("abc")
      expect((ex.dispatch(ed, "set readonly?"))).to.equal("noreadonly")
      ex.dispatch(ed, "set ro")                        -- alias sets it
      expect(ed.buf.readonly).to.be(true)
      expect((ex.dispatch(ed, "set ro?"))).to.equal("readonly")
      ex.dispatch(ed, "set readonly!")                 -- toggle back off
      expect((ex.dispatch(ed, "set readonly?"))).to.equal("noreadonly")
    end)
    it("scratch clears modified immediately, and noscratch restores it", function()
      local ed = ed_with("abc")
      ed.buf:set(1, "X")                              -- dirty the buffer
      expect(ed.buf.modified).to.be(true)
      ex.dispatch(ed, "set scratch")                  -- must clear modified now, not next edit
      expect(ed.buf.modified).to.be(false)
      ex.dispatch(ed, "set noscratch")                -- underlying edit is still unsaved
      expect(ed.buf.modified).to.be(true)
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
    it(":on dedups an identical re-register (wiring scripts are re-runnable)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on change lvi-highlight")
      local _, s = ex.dispatch(ed, "on change lvi-highlight")
      expect(s).to.equal("ok")
      expect(ed.hooks.change).to.equal({ "lvi-highlight" })
    end)
    it(":on! retracts one hook and leaves the event's others alone", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on write lvi-lint")
      ex.dispatch(ed, "on write lvi-send hook")
      ex.dispatch(ed, "on write lvi-pos save")
      expect(select(2, ex.dispatch(ed, "on! write lvi-send hook"))).to.equal("ok")
      expect(ed.hooks.write).to.equal({ "lvi-lint", "lvi-pos save" })
    end)
    it(":on! drops the event once its last hook goes (absent, not empty)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on write lvi-send hook")
      ex.dispatch(ed, "on! write lvi-send hook")
      expect(ed.hooks.write).to_not.exist()
      expect((ex.dispatch(ed, "hooks"))).to.equal("no hooks")
    end)
    it(":on! is a silent no-op on a hook that was never registered", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on write lvi-lint")
      expect(select(2, ex.dispatch(ed, "on! write lvi-send hook"))).to.equal("ok")
      expect(select(2, ex.dispatch(ed, "on! change lvi-send hook"))).to.equal("ok")
      expect(ed.hooks.write).to.equal({ "lvi-lint" })
    end)
    it(":on! with no command is an error, not a clear-all", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "on write lvi-lint")
      expect(select(2, ex.dispatch(ed, "on! write"))).to.equal("err")
      expect(ed.hooks.write).to.equal({ "lvi-lint" })
    end)
    it(":on rejects an unknown event", function()
      expect(select(2, ex.dispatch(ed_with("x"), "on save foo"))).to.equal("err")
    end)
    it(":on exit registers a shutdown hook", function()
      local ed = ed_with("x")
      expect(select(2, ex.dispatch(ed, "on exit lvi-pos save"))).to.equal("ok")
      expect(ed.hooks.exit).to.equal({ "lvi-pos save" })
    end)
    it(":hooks lists registered hooks, filterable by event", function()
      local ed = ed_with("x")
      expect((ex.dispatch(ed, "hooks"))).to.equal("no hooks")
      ex.dispatch(ed, "on change lvi-highlight")
      ex.dispatch(ed, "on change lvi-mirror")
      ex.dispatch(ed, "on write lvi-lint")
      expect((ex.dispatch(ed, "hooks"))).to.equal(
        "change\tlvi-highlight\nchange\tlvi-mirror\nwrite\tlvi-lint")
      expect((ex.dispatch(ed, "hooks write"))).to.equal("write\tlvi-lint")
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
    it(":pos LINE COL sets the cursor to an exact byte column", function()
      local ed = ed_with("hello\nworld\nagain")
      local _, s = ex.dispatch(ed, "pos 2 3")
      expect(s).to.equal("ok")
      expect(ed.cy).to.equal(2)
      expect(ed.cx).to.equal(3)                 -- byte column, not first non-blank
      expect((ex.dispatch(ed, "pos"))).to.equal("2\t3")
    end)
    it(":pos LINE (no col) sets column 1", function()
      local ed = ed_with("hello\nworld"); ed.cx = 4
      ex.dispatch(ed, "pos 2")
      expect(ed.cy).to.equal(2)
      expect(ed.cx).to.equal(1)
    end)
    it(":pos clamps a stale line and column into the buffer", function()
      local ed = ed_with("hello\nhi")
      ex.dispatch(ed, "pos 99 99")
      expect(ed.cy).to.equal(2)                 -- last line
      expect(ed.cx).to.equal(2)                 -- last byte of "hi"
    end)
    it(":pos rejects a non-numeric argument", function()
      expect(select(2, ex.dispatch(ed_with("x"), "pos foo"))).to.equal("err")
    end)
    -- The three units a producer may have counted in. A tab-indented line is
    -- where a GNU/gcc display column diverges (tab stops at 8), and a multibyte
    -- line is where a linter's character column does.
    it(":pos UNIT converts a display column to a byte", function()
      local ed = ed_with("\tundefined_thing();")
      ex.dispatch(ed, "pos 1 9 display")        -- gcc's column for the token
      expect(ed.cx).to.equal(2)                 -- the byte after the tab
    end)
    it(":pos UNIT converts a character column to a byte", function()
      local ed = ed_with("na\195\175ve caf\195\169 tail")
      ex.dispatch(ed, "pos 1 7 char")           -- the 7th character, `c`
      expect(ed.cx).to.equal(8)
      ex.dispatch(ed, "pos 1 7 byte")           -- same number, other unit
      expect(ed.cx).to.equal(7)
    end)
    it(":pos UNIT byte is the default, and an unknown unit errors", function()
      local ed = ed_with("\tabc")
      ex.dispatch(ed, "pos 1 2 byte")
      expect(ed.cx).to.equal(2)
      ex.dispatch(ed, "pos 1 2")
      expect(ed.cx).to.equal(2)
      expect(select(2, ex.dispatch(ed, "pos 1 2 furlongs"))).to.equal("err")
      expect(ed.cx).to.equal(2)                 -- and does not move the cursor
    end)
    -- Navigation over the socket -- a list step, a tag jump, the next diff hunk
    -- -- is a jump in vi, so the tool that means one says `jump` and gets the
    -- jumplist and both previous-context marks. A restore (contrib/lvi-pos) says
    -- nothing and stays silent, as before.
    it(":pos jump records the departure, plain :pos does not", function()
      local ed = ed_with("a\nb\nc\nd\ne"); ed.cy, ed.cx = 2, 1
      ex.dispatch(ed, "pos 5 1")
      expect(#ed.jumps.list).to.equal(0)
      expect(ed.marks["'"]).to_not.exist()
      ed.cy, ed.cx = 2, 1
      local _, st = ex.dispatch(ed, "pos 5 1 jump")
      expect(st).to.equal("ok")
      expect(ed.cy).to.equal(5)
      expect(#ed.jumps.list).to.equal(1)
      expect(ed.jumps.list[1][1]).to.equal(2)   -- where we left from
      expect(ed.marks["'"][1]).to.equal(2)      -- '' and `` both come back
      expect(ed.marks["`"][1]).to.equal(2)
    end)
    it(":pos jump takes a unit, and a no-op jump records nothing", function()
      local ed = ed_with("na\195\175ve caf\195\169 tail\nbb")
      ex.dispatch(ed, "pos 2 1 jump")
      expect(#ed.jumps.list).to.equal(1)
      -- Landing where you already stand is not a jump: a list re-jumping you to
      -- the entry you are on must not cost you the entry Ctrl-O would return to.
      -- (A push here would ADD line 2, which the list does not hold yet.)
      ex.dispatch(ed, "pos 2 1 jump")
      expect(#ed.jumps.list).to.equal(1)
      -- The unit converts before the comparison, so the recorded column is the
      -- byte one, whatever the caller counted in.
      ex.dispatch(ed, "pos 1 7 char jump")      -- the 7th character, `c`
      expect(ed.cx).to.equal(8)
      expect(#ed.jumps.list).to.equal(2)
      expect(ed.jumps.list[2][1]).to.equal(2)
    end)
    -- The move that only LOOKS like one: a byte column inside (or past) the
    -- line's last character folds back onto where the cursor already stood, so
    -- the test has to run after the clamp -- as do_motion's does -- or a
    -- restore-shaped no-op would cost you the entry Ctrl-O was going to.
    it(":pos jump ignores a column the clamp folds back onto the cursor", function()
      local ed = ed_with("ab\195\169")           -- "abe-acute": 4 bytes, 3 chars
      ex.dispatch(ed, "pos 1 3")                 -- on the multibyte char's first byte
      expect(ed.cx).to.equal(3)
      ex.dispatch(ed, "pos 1 4 jump")            -- its continuation byte: clamped back to 3
      expect(ed.cx).to.equal(3)
      expect(#ed.jumps.list).to.equal(0)
    end)

    -- :motion registers an external motion on a key; ex.motion_target is the
    -- filter call. The parse is what the contract is made of, so pin each form.
    it(":motion registers, validates, and unregisters a key", function()
      local ed = ed_with("a")
      expect(select(2, ex.dispatch(ed, "motion / prompt echo"))).to.equal("ok")
      expect(ed.motion_cmds[("/"):byte()].cmd).to.equal("echo")
      expect(ed.motion_cmds[("/"):byte()].prompt).to.equal(true)
      ex.dispatch(ed, "motion * lvi-search --motion --word")
      expect(ed.motion_cmds[("*"):byte()].cmd).to.equal("lvi-search --motion --word")
      expect(ed.motion_cmds[("*"):byte()].prompt).to.equal(false)
      ex.dispatch(ed, "motion *")                    -- bare KEY unregisters
      expect(ed.motion_cmds[("*"):byte()]).to_not.exist()
      expect(select(2, ex.dispatch(ed, "motion"))).to.equal("err")
      expect(select(2, ex.dispatch(ed, "motion ab echo"))).to.equal("err")
      expect(select(2, ex.dispatch(ed, "motion / prompt"))).to.equal("err")
    end)

    it("ex.motion_target reads each output form the contract allows", function()
      local ed = ed_with("hello\nworld\nthird")
      local l, c, kind, inc = ex.motion_target(ed, "sh -c 'echo char 2 3'", 1, "")
      expect({ l, c, kind, inc }).to.equal({ 2, 3, "char", false })
      l, c, kind, inc = ex.motion_target(ed, "sh -c 'echo char 2 3 incl'", 1, "")
      expect({ l, c, kind, inc }).to.equal({ 2, 3, "char", true })
      l, c, kind = ex.motion_target(ed, "sh -c 'echo line 3'", 1, "")
      expect({ l, c, kind }).to.equal({ 3, 1, "line" })
      -- no target, with and without something to say
      local nl, msg = ex.motion_target(ed, "sh -c 'echo err nope'", 1, "")
      expect(nl).to_not.exist(); expect(msg).to.equal("nope")
      expect((ex.motion_target(ed, "true", 1, ""))).to_not.exist()
      expect((ex.motion_target(ed, "sh -c 'echo garbage here'", 1, ""))).to_not.exist()
    end)

    -- The filter gets the buffer as it stands (unsaved edits included), the
    -- count, the cursor, and the prompted argument -- in that order.
    it("ex.motion_target hands the filter the buffer, count, cursor and argument", function()
      local ed = ed_with("alpha\nbeta\n")
      ed.cy, ed.cx = 2, 3
      local probe = "sh -c 'printf \"err %s|%s|%s|%s\\n\" \"$1\" \"$2\" \"$3\" $(wc -l < \"$0\")'"
      local _, msg = ex.motion_target(ed, probe, 7, "pat tern")
      expect(msg).to.equal("7|2|3|2")   -- count, line, col, and the buffer's lines
      -- the argument survives a shell metacharacter
      local probe2 = "sh -c 'printf \"err [%s]\\n\" \"$4\"'"
      local _, m2 = ex.motion_target(ed, probe2, 1, "a b; rm -rf $HOME")
      expect(m2).to.equal("[a b; rm -rf $HOME]")
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

  describe("msg / msge", function()
    it(":msg sets the message line with the Message group", function()
      local ed = ed_with("x")
      local _, s = ex.dispatch(ed, "msg hello there")
      expect(s).to.equal("ok")
      expect(ed.message).to.equal("hello there")
      expect(ed.message_hl).to.equal("Message")
    end)
    it(":msge sets the message with the Error group", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "msge boom")
      expect(ed.message).to.equal("boom")
      expect(ed.message_hl).to.equal("Error")
    end)
    it("a later :msg drops a prior error's group", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "msge boom")
      ex.dispatch(ed, "msg fine now")
      expect(ed.message_hl).to.equal("Message")
    end)
    it("collapses newlines (the status line is one row)", function()
      local ed = ed_with("x")
      ex.dispatch(ed, "msg one\ntwo")
      expect(ed.message).to.equal("one two")
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
    it(":[range]bg resolves the address and hands the bounds to spawn_bg", function()
      -- editor.lua's spawn_bg stamps these into $LVI_LINE1/$LVI_LINE2; that setenv
      -- lives in the tty/socket path (editor.new), so here we verify ex.lua's half:
      -- the range it resolves and passes. Stub spawn_bg to capture the args.
      local ed = ed_with("a\nb\nc\nd\ne"); local args
      ed.spawn_bg = function(cmd, buf, l1, l2) args = { cmd = cmd, l1 = l1, l2 = l2 } end
      ex.dispatch(ed, "bg tool")
      expect(args.l1).to.equal(nil)                     -- no address -> no bounds
      ex.dispatch(ed, "2,4bg tool")
      expect(args.l1).to.equal(2); expect(args.l2).to.equal(4)
      ex.dispatch(ed, "3bg tool")                       -- single address -> L1==L2
      expect(args.l1).to.equal(3); expect(args.l2).to.equal(3)
      ed.cy = 5; ex.dispatch(ed, "%bg tool")            -- whole buffer
      expect(args.l1).to.equal(1); expect(args.l2).to.equal(5)
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

  describe(":map listing", function()
    local function mapped(ed, lines)
      for _, l in ipairs(lines) do
        expect(select(2, ex.dispatch(ed, l))).to.equal("ok")
      end
      return ed
    end

    it("reports nothing when nothing is bound", function()
      expect(ex.dispatch(ed_with("a"), "map")).to.equal("no mappings")
    end)

    it("lists lhs<TAB>rhs, sorted by the raw lhs", function()
      local ed = mapped(ed_with("a"), {
        [[map n :bg lvi-list next<CR>]],
        [[map \ll :silent !lvi-list switch<CR>]],
        [[map Q "ayy]],
      })
      expect(ex.dispatch(ed, "map")).to.equal(
        'Q\t"ayy\n' ..
        "\\ll\t:silent !lvi-list switch<CR>\n" ..
        "n\t:bg lvi-list next<CR>")
    end)

    it("shows one binding when given an lhs, and says so when there is none", function()
      local ed = mapped(ed_with("a"), { [[map \w :w<CR>]] })
      expect(ex.dispatch(ed, [[map \w]])).to.equal("\\w\t:w<CR>")
      expect(ex.dispatch(ed, "map zz")).to.equal("no mapping for zz")
    end)

    -- The lhs query takes key NOTATION, not the raw bytes it parses to, so the
    -- spelling you bound with is the spelling you ask with.
    it("takes the lhs query in key notation", function()
      local ed = mapped(ed_with("a"), { [[map <C-a> :bg lvi-incr<CR>]] })
      expect(ex.dispatch(ed, "map <C-a>")).to.equal("<C-a>\t:bg lvi-incr<CR>")
    end)

    -- Every row must survive a round trip back through :map -- that is what
    -- makes the listing pasteable into an rc, and what lvi-cmd relies on to
    -- hand an lhs back to :normal.
    it("renders rows that parse back to the same bindings", function()
      local src = { [[map <C-a> :bg lvi-incr<CR>]], [[map <Space>x "ayy]],
                    [[map \gs :silent !lvi-gitchanges<CR>]], [[map Q <lt>literal]] }
      local ed = mapped(ed_with("a"), src)
      local again = ed_with("a")
      for row in (ex.dispatch(ed, "map") .. "\n"):gmatch("(.-)\n") do
        expect(select(2, ex.dispatch(again, "map " .. row:gsub("\t", " ")))).to.equal("ok")
      end
      expect(again.maps).to.equal(ed.maps)
    end)

    it("still binds when both arguments are present", function()
      local ed = mapped(ed_with("a"), { [[map \q :q<CR>]] })
      expect(ed.maps["\\q"]).to.equal(":q\r")
    end)
  end)

  describe(":marks", function()
    it("reports nothing when no marks are set", function()
      local ed = ed_with("a\nb\nc")
      expect(ex.dispatch(ed, "marks")).to.equal("no marks")
    end)
    it("lists marks as mark/line/col/text, a-z then extras", function()
      local ed = ed_with("first\n  indented\nthird")
      ed.marks = { b = { 2, 3 }, a = { 1, 1 }, ["."] = { 3, 2 } }
      expect(ex.dispatch(ed, "marks")).to.equal(
        "a      1    1  first\n" ..
        "b      2    3  indented\n" ..     -- leading blanks stripped from the text
        ".      3    2  third")
    end)
    it("restricts the list to named marks", function()
      local ed = ed_with("one\ntwo\nthree")
      ed.marks = { a = { 1, 1 }, b = { 2, 1 }, ["."] = { 3, 1 } }
      expect(ex.dispatch(ed, "marks b .")).to.equal(
        "b      2    1  two\n" ..
        ".      3    1  three")
    end)
    it("survives a mark pointing past the buffer (clamped read)", function()
      local ed = ed_with("only")
      ed.marks = { a = { 9, 1 } }                 -- stale line number
      expect(ex.dispatch(ed, "marks a")).to.equal("a      9    1  only")
    end)
  end)

  describe(":jumps / :changes", function()
    it("report nothing when the lists are empty", function()
      local ed = ed_with("a\nb\nc")
      expect(ex.dispatch(ed, "jumps")).to.equal("no jumps")
      expect(ex.dispatch(ed, "changes")).to.equal("no changes")
    end)
    it("list positions oldest-first with > on the current one", function()
      local ed = ed_with("first\n  indented\nthird")
      ed.changes = { list = { { 1, 1 }, { 3, 2 } }, idx = 2 }  -- idx sits on line 3
      expect(ex.dispatch(ed, "changes")).to.equal(
        "      1    1  first\n" ..
        ">     3    2  third")                     -- leading blanks stripped
    end)
    it("marks a trailing > when idx is at the resting edge", function()
      local ed = ed_with("a\nb\nc")
      ed.jumps = { list = { { 2, 1 } }, idx = 2 }  -- idx == #list+1: not navigating
      expect(ex.dispatch(ed, "jumps")).to.equal(
        "      2    1  b\n" ..
        ">")
    end)
  end)

  describe(":mark / :k (set a mark without moving the cursor)", function()
    it("sets a lowercase mark byte-exactly at an explicit LINE COL", function()
      local ed = ed_with("aaaa\nbbbb\ncccc"); ed.cy, ed.cx = 1, 2
      expect(ex.dispatch(ed, "mark a 3 4")).to.equal("")   -- ok payload is empty
      expect(ed.marks["a"]).to.exist()
      expect(ed.marks["a"][1]).to.equal(3)
      expect(ed.marks["a"][2]).to.equal(4)
      expect(ed.cy).to.equal(1); expect(ed.cx).to.equal(2) -- cursor unmoved
    end)
    it("sets the `\" mark (lvi-pos's use), not just a-z", function()
      local ed = ed_with("a\nbb\nccc")
      ex.dispatch(ed, 'mark " 2 2')
      expect(ed.marks['"'][1]).to.equal(2); expect(ed.marks['"'][2]).to.equal(2)
    end)
    it("defaults to the cursor with no LINE/COL", function()
      local ed = ed_with("a\nbb\nccc"); ed.cy, ed.cx = 3, 2
      ex.dispatch(ed, "mark z")
      expect(ed.marks["z"][1]).to.equal(3); expect(ed.marks["z"][2]).to.equal(2)
    end)
    it("takes the line from a leading ex address (POSIX form), col 1", function()
      local ed = ed_with("a\nbb\nccc\ndddd"); ed.cy = 1
      ex.dispatch(ed, "3k m")                                -- :3k m
      expect(ed.marks["m"][1]).to.equal(3); expect(ed.marks["m"][2]).to.equal(1)
      expect(ed.cy).to.equal(1)                             -- cursor unmoved
    end)
    it("clamps a stale LINE/COL into the buffer, like :pos", function()
      local ed = ed_with("a\nbb")
      ex.dispatch(ed, "mark a 99 99")
      expect(ed.marks["a"][1]).to.equal(2)                  -- last line
      expect(ed.marks["a"][2]).to.equal(2)                  -- last col of "bb"
    end)
    it("routes an uppercase mark through the markset seam at the cursor", function()
      local ed = ed_with("a\nbb\nccc"); ed.cy, ed.cx = 2, 1
      local fired, seen_mark = {}, nil
      ed.hooks.markset = { "lvi-gmark" }
      ed.fire_event = function(ev) fired[#fired + 1] = ev; seen_mark = ed.event_mark end
      expect(select(2, ex.dispatch(ed, "mark A"))).to.equal("ok")
      expect(#fired).to.equal(1); expect(fired[1]).to.equal("markset")
      expect(seen_mark).to.equal("A")                       -- LVI_MARK would carry it
      expect(ed.marks["A"]).to_not.exist()                  -- delegated, not buffer-local
    end)
    it("degrades an uppercase mark to buffer-local with no gmark hook", function()
      local ed = ed_with("a\nbb\nccc"); ed.cy, ed.cx = 2, 1
      ex.dispatch(ed, "mark A")                              -- no markset hook registered
      expect(ed.marks["A"][1]).to.equal(2); expect(ed.marks["A"][2]).to.equal(1)
    end)
    it("refuses an uppercase mark with an explicit line/col (seam carries the cursor)", function()
      local ed = ed_with("a\nbb\nccc")
      local _, s = ex.dispatch(ed, "mark A 3 1")
      expect(s).to.equal("err")
      expect(ed.marks["A"]).to_not.exist()
    end)
    it("rejects a malformed argument", function()
      local ed = ed_with("a\nbb")
      expect(select(2, ex.dispatch(ed, "mark"))).to.equal("err")     -- no char
      expect(select(2, ex.dispatch(ed, "mark a bogus"))).to.equal("err")
    end)
  end)

  describe(":source", function()
    local function writefile(text)
      local p = os.tmpname()
      local f = io.open(p, "w"); f:write(text); f:close()
      return p
    end
    it("runs a file of ex commands, skipping blanks and \" comments", function()
      local ed = ed_with("a\nb\nc\nd")
      local p = writefile('" a comment\n\n3\nmark x\n')
      local _, s = ex.dispatch(ed, "source " .. p)
      expect(s).to.equal("ok")
      expect(ed.cy).to.equal(3)
      expect(ed.marks["x"][1]).to.equal(3)
      os.remove(p)
    end)
    it("reports a failing line but runs the rest", function()
      local ed = ed_with("a\nb\nc")
      local p = writefile("mark\n2\n")                 -- bad line, then a good one
      local payload, s = ex.dispatch(ed, "source " .. p)
      expect(s).to.equal("err")
      expect(payload:find("line 1", 1, true)).to.exist()
      expect(ed.cy).to.equal(2)                        -- the good line still ran
      os.remove(p)
    end)
    it("errors on a file it cannot open", function()
      local ed = ed_with("a")
      local payload, s = ex.dispatch(ed, "source /nonexistent/lvirc")
      expect(s).to.equal("err")
      expect(payload:find("cannot open", 1, true)).to.exist()
    end)
    it("caps nesting, so a file sourcing itself terminates", function()
      local ed = ed_with("a")
      local p = os.tmpname()
      local f = io.open(p, "w"); f:write("so " .. p .. "\n"); f:close()
      local payload, s = ex.dispatch(ed, "source " .. p)
      expect(s).to.equal("err")
      expect(payload:find("nested too deeply", 1, true)).to.exist()
      expect(ed.source_depth).to.equal(0)              -- unwound cleanly
      os.remove(p)
    end)
    it("bare :source loads the user rc, ignoring $LVIRC", function()
      local home, xdg, lvirc =
        os.getenv("HOME"), os.getenv("XDG_CONFIG_HOME"), os.getenv("LVIRC")
      local dir = os.tmpname(); os.remove(dir)
      os.execute("mkdir -p " .. dir)
      local f = io.open(dir .. "/.lvirc", "w"); f:write("2\n"); f:close()
      sys.setenv("HOME", dir)
      sys.setenv("XDG_CONFIG_HOME", dir .. "/no-such")
      sys.setenv("LVIRC", dir .. "/.lvirc")            -- must NOT recurse through this
      local ed = ed_with("a\nb\nc")
      local _, s = ex.dispatch(ed, "source")
      expect(s).to.equal("ok")
      expect(ed.cy).to.equal(2)
      sys.setenv("HOME", home or "")
      sys.setenv("XDG_CONFIG_HOME", xdg or "")
      if lvirc then sys.setenv("LVIRC", lvirc) else sys.setenv("LVIRC", "") end
      os.execute("rm -rf " .. dir)
    end)
    it("bare :source with no user rc is a quiet no-op", function()
      local home, xdg = os.getenv("HOME"), os.getenv("XDG_CONFIG_HOME")
      local dir = os.tmpname(); os.remove(dir)
      os.execute("mkdir -p " .. dir)
      sys.setenv("HOME", dir)
      sys.setenv("XDG_CONFIG_HOME", dir .. "/no-such")
      local ed = ed_with("a\nb")
      local payload, s = ex.dispatch(ed, "source")
      expect(s).to.equal("ok")
      expect(payload).to.equal("")
      sys.setenv("HOME", home or "")
      sys.setenv("XDG_CONFIG_HOME", xdg or "")
      os.execute("rm -rf " .. dir)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
