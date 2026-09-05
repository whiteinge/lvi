-- Tests for buffer.lua. Run: luajit test/buffer_test.lua (from repo root)
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local describe, it, expect = lust.describe, lust.it, lust.expect

describe("buffer", function()
  describe("new / parsing", function()
    it("splits lines and detects a final newline (eol)", function()
      local b = buffer.new("a\nb\nc\n")
      expect(b:nlines()).to.equal(3)
      expect(b:get()).to.equal({ "a", "b", "c" })
      expect(b.noeol).to.be(false)
    end)

    it("detects a missing final newline (noeol)", function()
      local b = buffer.new("a\nb\nc")
      expect(b:nlines()).to.equal(3)
      expect(b.noeol).to.be(true)
    end)

    it("treats the empty string as the empty file", function()
      local b = buffer.new("")
      expect(b:nlines()).to.equal(1)
      expect(b:line(1)).to.equal("")
      expect(b.noeol).to.be(true)
    end)

    it("preserves interior blank lines", function()
      local b = buffer.new("a\n\nb\n")
      expect(b:get()).to.equal({ "a", "", "b" })
    end)

    it("handles a lone newline as one empty line with eol", function()
      local b = buffer.new("\n")
      expect(b:get()).to.equal({ "" })
      expect(b.noeol).to.be(false)
    end)

    -- On an empty buffer noeol is vi's "0 lines" state, not a line missing its
    -- terminator, so it has to move when the buffer crosses that boundary --
    -- otherwise typing into a new (or 0-byte) file writes it back without a
    -- final newline. Checked against vim: `vim new; ihello; :wq` -> "hello\n",
    -- and `:%d` + `:w` on any file -> zero bytes.
    it("gives a new/empty file's first typed line a final newline", function()
      local b = buffer.new("")                  -- editing a file that does not exist
      expect(b:text()).to.equal("")             -- untouched: still the empty file
      b:set(1, "hello")
      expect(b.noeol).to.be(false)
      expect(b:text()).to.equal("hello\n")
    end)

    it("re-empties to the empty file when every line is deleted", function()
      local b = buffer.new("a\nb\n")
      b:delete()
      expect(b:nlines()).to.equal(1)
      expect(b.noeol).to.be(true)
      expect(b:text()).to.equal("")
    end)

    it("restores the empty file's zero bytes on undo", function()
      local b = buffer.new("")
      b:undo_checkpoint()
      b:set(1, "hello")
      b:undo_checkpoint()
      b:undo()
      expect(b.noeol).to.be(true)
      expect(b:text()).to.equal("")
    end)

    it("keeps noeol on a genuinely unterminated file across edits", function()
      local b = buffer.new("a\nb")
      b:set(2, "bb")
      expect(b.noeol).to.be(true)
      expect(b:text()).to.equal("a\nbb")
    end)

    -- The flip is one-directional, so replaying the lines alone does not put
    -- noeol back: the inverse record has to carry it. Without that, a file that
    -- is exactly "\n" comes back from `dd` + `u` reading as zero lines, and the
    -- next :w truncates it to zero bytes.
    it("restores a blank-line file's newline on undo (and drops it on redo)", function()
      local b = buffer.new("\n")
      b:undo_checkpoint()
      b:delete()                                -- dd on the only line
      b:undo_checkpoint()
      expect(b.noeol).to.be(true)               -- zero lines: zero bytes
      expect(b:text()).to.equal("")
      b:undo()
      expect(b.noeol).to.be(false)              -- back to one blank line
      expect(b:text()).to.equal("\n")
      b:redo()
      expect(b:text()).to.equal("")             -- symmetric the other way
      b:undo()
      expect(b:text()).to.equal("\n")
    end)

    it("restores an unterminated file's noeol on undo", function()
      local b = buffer.new("abc")
      b:undo_checkpoint()
      b:delete()
      b:undo_checkpoint()
      b:undo()
      expect(b.noeol).to.be(true)
      expect(b:text()).to.equal("abc")          -- still unterminated, as opened
    end)

    it("round-trips text() for both eol and noeol", function()
      for _, s in ipairs({ "a\nb\nc\n", "a\nb\nc", "", "\n", "x" }) do
        expect(buffer.new(s):text()).to.equal(s)
      end
    end)
  end)

  describe("queries", function()
    it("returns nil for out-of-range line()", function()
      local b = buffer.new("a\nb")
      expect(b:line(0)).to_not.exist()
      expect(b:line(3)).to_not.exist()
    end)

    it("get() returns an independent copy", function()
      local b = buffer.new("a\nb\nc")
      local g = b:get(1, 2)
      g[1] = "MUT"
      expect(b:line(1)).to.equal("a")
    end)

    it("get() rejects a bad range", function()
      local b = buffer.new("a\nb")
      expect(function() b:get(1, 9) end).to.fail()
    end)
  end)

  describe("set", function()
    it("replaces a line and marks modified", function()
      local b = buffer.new("a\nb\nc")
      expect(b.modified).to.be(false)
      b:set(2, "B")
      expect(b:get()).to.equal({ "a", "B", "c" })
      expect(b.modified).to.be(true)
    end)

    it("rejects a newline in a line", function()
      local b = buffer.new("a")
      expect(function() b:set(1, "x\ny") end).to.fail()
    end)

    it("rejects an out-of-range line", function()
      local b = buffer.new("a")
      expect(function() b:set(2, "x") end).to.fail()
    end)
  end)

  describe("insert", function()
    it("inserts before a line", function()
      local b = buffer.new("a\nb\nc")
      b:insert(2, { "X", "Y" })
      expect(b:get()).to.equal({ "a", "X", "Y", "b", "c" })
    end)

    it("prepends at line 1", function()
      local b = buffer.new("a\nb")
      b:insert(1, { "P" })
      expect(b:get()).to.equal({ "P", "a", "b" })
    end)

    it("appends at nlines()+1", function()
      local b = buffer.new("a\nb")
      b:insert(3, { "Z" })
      expect(b:get()).to.equal({ "a", "b", "Z" })
    end)

    it("rejects out-of-range and newline-bearing inserts", function()
      local b = buffer.new("a")
      expect(function() b:insert(5, { "x" }) end).to.fail()
      expect(function() b:insert(1, { "x\ny" }) end).to.fail()
    end)
  end)

  describe("delete", function()
    it("removes an interior range", function()
      local b = buffer.new("a\nb\nc\nd")
      b:delete(2, 3)
      expect(b:get()).to.equal({ "a", "d" })
    end)

    it("keeps one empty line when emptied", function()
      local b = buffer.new("a\nb\nc")
      b:delete(1, 3)
      expect(b:nlines()).to.equal(1)
      expect(b:line(1)).to.equal("")
    end)

    it("rejects a bad range", function()
      local b = buffer.new("a\nb")
      expect(function() b:delete(1, 5) end).to.fail()
    end)
  end)

  describe("open / write round-trip", function()
    it("writes and reads back byte-for-byte, honoring noeol", function()
      for _, s in ipairs({ "a\nb\nc\n", "a\nb\nc", "" }) do
        local tmp = os.tmpname()
        local b = buffer.new(s)
        b:write(tmp)
        local b2 = buffer.open(tmp)
        expect(b2:text()).to.equal(s)
        expect(b2.noeol).to.be(b.noeol)
        expect(b2.modified).to.be(false)
        os.remove(tmp)
      end
    end)

    it("opens a missing file as an empty buffer bound to the path", function()
      local p = os.tmpname(); os.remove(p) -- ensure it does not exist
      local b = buffer.open(p)
      expect(b:nlines()).to.equal(1)
      expect(b.path).to.equal(p)
    end)

    it("removes the .lvi~ safety copy after a completed write", function()
      local tmp = os.tmpname()
      local b = buffer.new("one\ntwo\n")
      b:write(tmp)
      local bak = io.open(tmp .. ".lvi~", "rb")
      expect(bak).to_not.exist()              -- completed write reaps the copy
      expect(buffer.open(tmp):text()).to.equal("one\ntwo\n")
      os.remove(tmp)
    end)

    it("removes the safety copy when the target cannot even be opened", function()
      local dir = os.tmpname(); os.remove(dir)
      local target = dir .. "/nope"            -- parent dir does not exist
      local b = buffer.new("x\n")
      local ok = pcall(b.write, b, target)
      expect(ok).to.be(false)
      expect(io.open(target .. ".lvi~", "rb")).to_not.exist()
    end)
  end)

  describe("undo / redo", function()
    it("undoes a set, insert, and delete", function()
      local b = buffer.new("a\nb\nc")
      b:set(2, "X"); b:undo(); expect(b:get()).to.equal({ "a", "b", "c" })
      b:insert(2, { "N" }); b:undo(); expect(b:get()).to.equal({ "a", "b", "c" })
      b:delete(2, 2); b:undo(); expect(b:get()).to.equal({ "a", "b", "c" })
    end)
    it("undoes a whole-buffer delete (the guard case)", function()
      local b = buffer.new("a\nb\nc")
      b:delete(1, 3)
      expect(b:get()).to.equal({ "" })
      b:undo()
      expect(b:get()).to.equal({ "a", "b", "c" })
    end)
    it("redoes an undone change", function()
      local b = buffer.new("x")
      b:set(1, "y"); b:undo(); expect(b:line(1)).to.equal("x")
      b:redo(); expect(b:line(1)).to.equal("y")
    end)
    it("groups changes by checkpoint (multi-level)", function()
      local b = buffer.new("a")
      b:set(1, "b"); b:undo_checkpoint()
      b:set(1, "c")
      b:undo(); expect(b:line(1)).to.equal("b")
      b:undo(); expect(b:line(1)).to.equal("a")
    end)
    it("a fresh edit invalidates the redo stack", function()
      local b = buffer.new("a")
      b:set(1, "b"); b:undo()          -- back to "a", "b" is redoable
      b:set(1, "c")                    -- new edit clears redo
      expect(b:redo()).to_not.exist()
      expect(b:line(1)).to.equal("c")
    end)
    it("returns nil with nothing to undo", function()
      expect(buffer.new("a"):undo()).to_not.exist()
    end)
    it("returns the affected line AND the change column (bug 1)", function()
      -- Change a byte mid-line; undo/redo report where it diverged, so the
      -- editor can put the cursor on the edit, not column 1.
      local b = buffer.new("the quick brown")
      b:set(1, "the qXick brown")               -- 'u' -> 'X' at byte 6
      local ul, uc = b:undo()
      expect(ul).to.equal(1); expect(uc).to.equal(6)
      local rl, rc = b:redo()
      expect(rl).to.equal(1); expect(rc).to.equal(6)
    end)
    it("reports column 1 for a whole-line change (bug 1)", function()
      local b = buffer.new("a\nb\nc")
      b:delete(2, 2)                             -- remove line 2
      local _, uc = b:undo()                     -- re-inserts "b" at line 2
      expect(uc).to.equal(1)
    end)
  end)

  describe("rev counter", function()
    it("starts at 0 and bumps on every mutation (incl. undo/redo)", function()
      local b = buffer.new("a\nb")
      expect(b.rev).to.equal(0)
      b:set(1, "X"); expect(b.rev).to.equal(1)
      b:insert(2, { "Y" }); expect(b.rev).to.equal(2)
      local r = b.rev
      b:undo(); expect(b.rev > r).to.be(true)   -- undo is a mutation too
    end)
  end)

  -- The bounded log of line-moving splices an external producer replays to bring
  -- stored line numbers forward; see THE LINE JOURNAL in buffer.lua.
  describe("line journal", function()
    local function triples(b)
      local out = {}
      for i, e in ipairs(b.journal) do out[i] = { e.rev, e.start, e.ndel, e.nins } end
      return out
    end

    it("records an insert and a delete, with the rev that made them", function()
      local b = buffer.new("a\nb\nc")
      b:insert(1, { "z" })
      b:delete(3, 3)
      expect(triples(b)).to.equal({ { 1, 1, 0, 1 }, { 2, 3, 1, 0 } })
    end)

    it("ignores a one-for-one splice: typing moves no line", function()
      local b = buffer.new("a\nb\nc")
      b:set(2, "typed")
      b:splice(1, 2, { "x", "y" })              -- multi-line, still one-for-one
      expect(#b.journal).to.equal(0)
      expect(b.rev).to.equal(2)                 -- ...but they are mutations
    end)

    it("records undo's inverse splice, so the pair composes to identity", function()
      local b = buffer.new("a\nb\nc")
      b:undo_checkpoint()
      b:insert(1, { "z" })
      b:undo()
      local j = triples(b)
      expect(#j).to.equal(2)
      expect(j[1][2] .. "/" .. j[1][3] .. "/" .. j[1][4]).to.equal("1/0/1")
      expect(j[2][2] .. "/" .. j[2][3] .. "/" .. j[2][4]).to.equal("1/1/0")
    end)

    it("drops the oldest past the cap and raises the answerable base", function()
      local b = buffer.new("a")
      expect(b.jbase).to.equal(0)
      for _ = 1, 600 do b:insert(1, { "x" }) end
      expect(#b.journal).to.equal(512)
      expect(b.jbase).to.equal(88)              -- 600 - 512, the last rev dropped
      expect(b.journal[1].rev).to.equal(89)     -- ...and the oldest still held
    end)

    it("gives each buffer its own id, so a stale stamp is detectable", function()
      local a, b = buffer.new("x"), buffer.new("y")
      expect(a.id == b.id).to.be(false)
      expect(b.rev).to.equal(0)                 -- rev restarts; the id does not
    end)
  end)

  describe("modified flag", function()
    it("is false on a fresh buffer, true after an edit", function()
      local b = buffer.new("a")
      expect(b.modified).to.be(false)
      b:set(1, "b")
      expect(b.modified).to.be(true)
    end)
    it("clears when undoing back to the original, sets again on redo", function()
      local b = buffer.new("a")
      b:set(1, "b")
      b:undo(); expect(b.modified).to.be(false)
      b:redo(); expect(b.modified).to.be(true)
    end)
    it("tracks the last-saved state across undo/redo", function()
      local tmp = os.tmpname()
      local b = buffer.new("a\nb")
      b:set(1, "X"); b:write(tmp)         -- save at this state
      expect(b.modified).to.be(false)
      b:set(2, "Y")                       -- edit past the saved point
      expect(b.modified).to.be(true)
      b:undo(); expect(b.modified).to.be(false)  -- back to saved -> clean
      b:undo(); expect(b.modified).to.be(true)   -- before saved -> dirty
      os.remove(tmp)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1) -- non-zero exit on any failure (for CI)
