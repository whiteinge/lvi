-- Tests for config.lua. Run: luajit test/config_test.lua (from repo root)
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local sys    = require("sys")
local buffer = require("buffer")
local config = require("config")
local describe, it, expect = lust.describe, lust.it, lust.expect

-- A minimal editor state: enough for the ex commands the rc file exercises.
local function fake_ed()
  return { opts = { wrap = true, tabstop = 8 }, buf = buffer.new("a\nb\nc"),
           cy = 1, cx = 1, inject = {}, maps = {} }
end

local function writerc(text)
  local p = os.tmpname()
  local f = io.open(p, "w"); f:write(text); f:close()
  return p
end

describe("config", function()
  describe("rc_path", function()
    it("honors $LVIRC as an explicit override", function()
      sys.setenv("LVIRC", "/some/where/lvirc")
      expect(config.rc_path()).to.equal("/some/where/lvirc")
    end)
    it("treats LVIRC='' and 'NONE' as disabled", function()
      sys.setenv("LVIRC", "")
      expect(config.rc_path()).to_not.exist()
      sys.setenv("LVIRC", "NONE")
      expect(config.rc_path()).to_not.exist()
    end)
  end)

  describe("load", function()
    it("runs ex commands, skipping blanks and \" comments", function()
      local p = writerc('" my config\n\nset nowrap\nmap ; :w<CR>\n')
      sys.setenv("LVIRC", p)
      local ed = fake_ed()
      local loaded, errs = config.load(ed)
      expect(loaded).to.equal(p)
      expect(#errs).to.equal(0)
      expect(ed.opts.wrap).to.be(false)
      expect(ed.maps[";"]).to.exist()
      os.remove(p)
    end)

    it("strips a trailing comment, incl. after a map whose RHS ends in <CR>", function()
      -- Regression: a trailing '"' comment used to be left on the line, so the
      -- map RHS swallowed it -- the keys after <CR> (`" step...`) ran as normal
      -- mode and dropped the editor into insert. The RHS must be exactly the
      -- command plus the <CR>, with no comment text and no trailing space keys.
      local p = writerc('map n :silent !lvi-list next<CR>        " step the list\n')
      sys.setenv("LVIRC", p)
      local ed = fake_ed()
      local _, errs = config.load(ed)
      expect(#errs).to.equal(0)
      expect(ed.maps["n"]).to.equal(":silent !lvi-list next\r")
      os.remove(p)
    end)

    it("leaves a '\"' inside a command alone (register, not a comment)", function()
      -- A '"' abutting a non-blank (a register ref) is not a comment, even with
      -- a trailing comment also present on the line.
      local p = writerc('map Q "ayy        " yank the line into register a\n')
      sys.setenv("LVIRC", p)
      local ed = fake_ed()
      local _, errs = config.load(ed)
      expect(#errs).to.equal(0)
      expect(ed.maps["Q"]).to.equal('"ayy')
      os.remove(p)
    end)

    it("collects errors without aborting later lines", function()
      -- Use a natively-failing command (a bad :set option); an unknown command
      -- word is delegated to ex, not treated as an error.
      local p = writerc("set nowrap\nset bogusopt\nset ts=4\n")
      sys.setenv("LVIRC", p)
      local ed = fake_ed()
      local _, errs = config.load(ed)
      expect(#errs).to.equal(1)
      expect(errs[1].lnum).to.equal(2)
      expect(ed.opts.wrap).to.be(false)     -- line before the error still ran
      expect(ed.opts.tabstop).to.equal(4)   -- line after the error still ran
      os.remove(p)
    end)

    it("reports a bad explicit $LVIRC path as a load error", function()
      sys.setenv("LVIRC", "/no/such/lvirc/file")
      local loaded, errs = config.load(fake_ed())
      expect(loaded).to.equal("/no/such/lvirc/file")
      expect(#errs).to.equal(1)
    end)

    it("is a no-op when config is disabled", function()
      sys.setenv("LVIRC", "NONE")
      local loaded, errs = config.load(fake_ed())
      expect(loaded).to_not.exist()
      expect(#errs).to.equal(0)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1) -- non-zero exit on any failure (for CI)
