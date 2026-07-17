-- Tests for the contrib scripts. Run: luajit test/contrib_test.lua
--
-- Two tiers, no editor involved in either:
--   * pure filters (lvi-reflow, lvi-incr, lvi-hl-ansi, lvi-textobj-tag,
--     lvi-detect-indent) are golden-file checks over stdin/stdout;
--   * socket-driven scripts run against test/stub-lvi (LVI= points there),
--     which serves canned %p/path/pos payloads and logs every command it
--     receives -- the assertion target is the recorded conversation.
-- Picker/tty flows (lvi-open, z= fixes, tmux modes) stay manual: they need a
-- real terminal, and the logic under them is what these tests pin.
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust = require("lust")
local describe, it, expect = lust.describe, lust.it, lust.expect

local pwd = io.popen("pwd"):read("*l")
local STUB = pwd .. "/test/stub-lvi"

local function tmpdir()
  local d = os.tmpname()
  os.remove(d)
  os.execute("mkdir -p '" .. d .. "'")
  return d
end

local function write(p, s)
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end

local function read(p)
  local f = io.open(p, "rb")
  if not f then return "" end
  local s = f:read("*a"); f:close()
  return s
end

-- Run a shell line and return its combined output and exit ok. The env goes
-- in as exports from a wrapper script -- a plain VAR=x prefix would bind only
-- to the first command of a pipeline -- and the status comes from os.execute
-- (LuaJIT's p:close() cannot report it).
local function run(env, cmd)
  local script, outf = os.tmpname(), os.tmpname()
  local sh = {}
  for k, v in pairs(env or {}) do sh[#sh + 1] = ("export %s='%s'"):format(k, v) end
  sh[#sh + 1] = cmd
  write(script, table.concat(sh, "\n") .. "\n")
  local rc = os.execute("sh '" .. script .. "' >'" .. outf .. "' 2>&1")
  local out = read(outf)
  os.remove(script); os.remove(outf)
  return out, rc == 0
end

describe("contrib", function()
  describe("pure filters", function()
    it("lvi-reflow hangs a wrapped bullet under its text", function()
      local out = run({}, "printf -- '- alpha beta gamma delta epsilon zeta\\n'"
        .. " | contrib/lvi-reflow -w 20")
      expect(out).to.equal("- alpha beta gamma\n  delta epsilon zeta\n")
    end)

    it("lvi-reflow handles the unicode bullet (the POSIX-awk marker path)", function()
      local out = run({}, [[printf -- '\342\200\242 aa bb cc dd ee\n' | contrib/lvi-reflow -w 8]])
      expect(out).to.equal("\226\128\162 aa bb\n  cc dd\n  ee\n")
    end)

    it("lvi-incr ramps by STEP down the selection", function()
      local out = run({}, "printf '1\\n1\\n1\\n' | contrib/lvi-incr -s 5")
      expect(out).to.equal("6\n11\n16\n")
    end)

    it("lvi-incr rejects a bare operand and a non-numeric STEP", function()
      local _, ok = run({}, "contrib/lvi-incr 5 </dev/null")
      expect(ok).to.equal(false)
      local _, ok2 = run({}, "contrib/lvi-incr -s x </dev/null")
      expect(ok2).to.equal(false)
    end)

    it("lvi-hl-ansi turns an SGR span into hi/hl at byte columns", function()
      local out = run({}, [[printf 'x \033[31mred\033[0m y\n' | contrib/lvi-hl-ansi | head -2]])
      expect(out).to.equal("hi syn0 sgr=31\nhl syn0 1:3-5\n")
    end)

    it("lvi-textobj-tag finds the inner range of the enclosing tag", function()
      local d = tmpdir()
      write(d .. "/b.html", "<b>hi</b>\n")
      local out = run({}, "contrib/lvi-textobj-tag '" .. d .. "/b.html' i 1 5")
      expect(out).to.equal("char 1 4 1 5\n")
      os.execute("rm -rf '" .. d .. "'")
    end)

    it("lvi-detect-indent sniffs a 2-space file from stdin", function()
      local out = run({},
        "printf 'a:\\n  b\\n  c:\\n    d\\n  e\\nf:\\n  g\\n' | contrib/lvi-detect-indent -")
      expect(out).to.equal("et sw=2\n")
    end)
  end)

  describe("socket scripts against the stub", function()
    -- Fresh stub dir per test; env carries LVI (the stub) plus whatever the
    -- script reads. The log file is the conversation, in arrival order.
    local function stub(files)
      local d = tmpdir()
      for name, content in pairs(files or {}) do write(d .. "/" .. name, content) end
      return d
    end
    local function cleanup(d) os.execute("rm -rf '" .. d .. "'") end

    it("lvi-fold --worker pushes one atomic foldset", function()
      local d = stub({ buffer = "a {{{\nb\nc }}}\nd\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1" },
        "contrib/lvi-fold --worker marker")
      expect(read(d .. "/log")).to.equal("%p\nfoldset 1,3\n")
      cleanup(d)
    end)

    it("lvi-fmt --worker splices, restores the cursor, clears, fires", function()
      local d = stub({ buffer = "b\na\n", path = "x.txt\n", pos = "2\t1\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_SOCK = d .. "/sock",
            LVI_FMT_CMD = "sort", LVI_LINE = "2", LVI_COL = "1" },
        "contrib/lvi-fmt --worker")
      local log = read(d .. "/log")
      expect(log:find("^%%p\npath\n")).to.exist()       -- read buffer, then name
      expect(log:find("!sed %-n '1,2p'")).to.exist()    -- the changed-window splice
      expect(log:find("\npos 1 1\n")).to.exist()        -- cursor followed its line
      expect(log:find("\nstatus fmt\nfire\n$")).to.exist()
      cleanup(d)
    end)

    it("lvi-fmt --worker is a no-op on an already-formatted buffer", function()
      local d = stub({ buffer = "a\nb\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_SOCK = d .. "/sock", LVI_FMT_CMD = "sort" },
        "contrib/lvi-fmt --worker")
      expect(read(d .. "/log"):find("status fmt")).to.exist()  -- clears any old failure
      expect(read(d .. "/log"):find("fire")).to_not.exist()    -- but no edit, no fire
      cleanup(d)
    end)

    it("lvi-search --worker reports no-match via msge and clears the paint", function()
      local d = stub({ buffer = "haystack\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_FILE = "x.txt" },
        "contrib/lvi-search --worker -- zzz")
      expect(read(d .. "/log")).to.equal(
        "%p\nhl search\nhl search-cur\nstatus search\nmsge /zzz/ no match\n")
      cleanup(d)
    end)

    it("lvi-lint --worker reports a missing backend, never a clean [0/0]", function()
      local d = stub({ buffer = "x\n", path = "x.zz\n" })
      local _, ok = run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                          LVI_LINT_BACKEND = "no-such-linter" },
        "contrib/lvi-lint --worker")
      expect(ok).to.equal(false)
      expect(read(d .. "/log"):find("msge lvi%-lint:")).to.exist()
      expect(read(d .. "/log"):find("%[0/0%]")).to_not.exist()
      cleanup(d)
    end)

    it("lvi-lint --worker under a hook skips an unconfigured buffer in silence", function()
      local d = stub({ buffer = "x\n", path = "x.zz\n" })   -- no backend for .zz
      local _, ok = run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                          LVI_EVENT = "change" },
        "contrib/lvi-lint --worker")
      expect(ok).to.equal(true)
      expect(read(d .. "/log")).to.equal("path\n")          -- looked, said nothing
      cleanup(d)
    end)

    it("lvi-lint --worker under a hook posts broken-setup to the status segment", function()
      local d = stub({ buffer = "x\n", path = "x.zz\n" })
      local _, ok = run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                          LVI_EVENT = "change", LVI_LINT_BACKEND = "no-such-linter" },
        "contrib/lvi-lint --worker")
      expect(ok).to.equal(false)
      expect(read(d .. "/log"):find("status lint %[lvi%-lint:")).to.exist()
      expect(read(d .. "/log"):find("msge")).to_not.exist()
      cleanup(d)
    end)

    -- lvi-mirror's env: LVI_WID names the view, LVI_SOCK puts the temp/state
    -- files in the stub dir, LVI_FILE skips the `path` round-trip. The stub
    -- serves per-view buffers (buffer.WID) so two views can diverge.
    it("lvi-mirror --worker pushes a diff to the peer and records the push", function()
      local d = stub({ ["buffer.w1"] = "a\nb\n", ["buffer.w2"] = "a\n" })
      write(d .. "/list", "w1\t" .. d .. "/sock\t/lvi-mirror-test/f\n"
                       .. "w2\t" .. d .. "/sock\t/lvi-mirror-test/f\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/lvi-mirror-test/f" },
        "contrib/lvi-mirror --worker")
      local log = read(d .. "/log")
      expect(log:find("r !sed %-n 1,2p")).to_not.exist()   -- no whole-buffer ship...
      expect(log:find("1 r !sed %-n 2,2p")).to.exist()     -- ...just the new line
      expect(log:find("\nfire\n")).to.exist()
      local sum = io.popen("cksum < '" .. d .. "/buffer.w1'"):read("*l")
      expect(read(d .. "/lvi-mirror.pushed.w2")).to.equal(sum .. "\n")
      cleanup(d)
    end)

    it("lvi-mirror --worker replaces a whole-buffer change read-first (no phantom line)", function()
      local d = stub({ ["buffer.w1"] = "NEW\n", ["buffer.w2"] = "OLD\n" })
      write(d .. "/list", "w1\t" .. d .. "/sock\t/lvi-mirror-test/f\n"
                       .. "w2\t" .. d .. "/sock\t/lvi-mirror-test/f\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/lvi-mirror-test/f" },
        "contrib/lvi-mirror --worker")
      -- Read the new line in ABOVE, then delete the old at its shifted
      -- address -- delete-first would empty the buffer and the >=1-line clamp
      -- would leave a phantom blank the read does not replace.
      expect(read(d .. "/log"):find("0 r !sed %-n 1,1p[^\n]*\nundojoin\n2,2d _\n")).to.exist()
      cleanup(d)
    end)

    it("lvi-mirror --worker suppresses a dirty echo before reading any peer", function()
      local d = stub({ ["buffer.w1"] = "a\nb\n" })
      local sum = io.popen("cksum < '" .. d .. "/buffer.w1'"):read("*l")
      write(d .. "/lvi-mirror.pushed.w1", sum .. "\n")     -- this content WAS a push
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/lvi-mirror-test/f" },
        "contrib/lvi-mirror --worker")
      expect(read(d .. "/log")).to.equal("%p\nset modified?\n")
      cleanup(d)
    end)

    it("lvi-mirror --worker: a clean echo flag-syncs in-step peers, pushes nothing", function()
      local d = stub({ ["buffer.w1"] = "a\nb\n", ["buffer.w2"] = "a\nb\n",
                       ["buffer.w3"] = "a\nTYPED AHEAD\n", modified = "nomodified\n" })
      local sum = io.popen("cksum < '" .. d .. "/buffer.w1'"):read("*l")
      write(d .. "/lvi-mirror.pushed.w1", sum .. "\n")
      write(d .. "/list", "w1\t" .. d .. "/sock\t/lvi-mirror-test/f\n"
                       .. "w2\t" .. d .. "/sock\t/lvi-mirror-test/f\n"
                       .. "w3\t" .. d .. "/sock\t/lvi-mirror-test/f\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/lvi-mirror-test/f" },
        "contrib/lvi-mirror --worker")
      local log = read(d .. "/log")
      expect(log:find("set nomodified")).to.exist()        -- w2 (in step) got the flag
      expect(log:find("sed")).to_not.exist()               -- w3 (diverged) got NOTHING
      expect(log:find("fire")).to_not.exist()
      cleanup(d)
    end)

    it("lvi-pos save/restore round-trips through the store", function()
      local d = stub({})
      -- Not under /tmp: lvi-pos deliberately skips volatile paths there.
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_POS_FILE = d .. "/store", LVI_FILE = "/data/proj/f.txt" }
      env.LVI_LINE = "7"; env.LVI_COL = "3"
      run(env, "contrib/lvi-pos save")
      expect(read(d .. "/store")).to.equal("/data/proj/f.txt\t7\t3\n")
      env.LVI_LINE = "1"; env.LVI_COL = "1"                -- a fresh read
      run(env, "contrib/lvi-pos restore")
      expect(read(d .. "/log")).to.equal('mark " 7 3\n')   -- mark-only, no move
      cleanup(d)
    end)

    it("lvi-pos save skips line 1 (a glance must not clobber the store)", function()
      local d = stub({})
      write(d .. "/store", "/data/proj/f.txt\t7\t3\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_POS_FILE = d .. "/store",
            LVI_FILE = "/data/proj/f.txt", LVI_LINE = "1", LVI_COL = "1" },
        "contrib/lvi-pos save")
      expect(read(d .. "/store")).to.equal("/data/proj/f.txt\t7\t3\n")
      cleanup(d)
    end)

    it("lvi-list put paints, counts, and jump uses `e --` + :pos", function()
      local d = stub({ path = "/cur/file.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/file.txt",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/oth/we $ird.txt:3:9: boom\n' | contrib/lvi-list put qq --focus]])
      local log = read(d .. "/log")
      expect(log:find("\nstatus qq %[0/1%] qq\n")).to.exist()
      run(env, "contrib/lvi-list next")
      log = read(d .. "/log")
      expect(log:find("\ne %-%- /oth/we %$ird%.txt\n")).to.exist()  -- literal splice
      expect(log:find("\npos 3 9\n")).to.exist()                    -- byte-exact jump
      cleanup(d)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
