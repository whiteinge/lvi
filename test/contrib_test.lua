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

    it("lvi-reflow strips a common prefix, reflows, and puts it back", function()
      local out = run({}, "printf '# alpha beta gamma delta epsilon zeta eta\\n# theta iota\\n'"
        .. " | contrib/lvi-reflow -w 24")
      expect(out).to.equal("# alpha beta gamma delta\n# epsilon zeta eta theta\n# iota\n")
    end)

    it("lvi-reflow hangs a list nested inside a comment block", function()
      local out = run({}, "printf '# - alpha beta gamma delta\\n#   epsilon\\n'"
        .. " | contrib/lvi-reflow -w 20")
      expect(out).to.equal("# - alpha beta gamma\n#   delta epsilon\n")
    end)

    -- The collision that makes a naive longest-common-prefix wrong: every line
    -- of a bullet list shares `- `, and repeating it would destroy the hang.
    it("lvi-reflow treats a shared bullet as a list, not a prefix", function()
      local out = run({}, "printf -- '- alpha beta gamma delta epsilon\\n- zeta eta\\n'"
        .. " | contrib/lvi-reflow -w 20")
      expect(out).to.equal("- alpha beta gamma\n  delta epsilon\n- zeta eta\n")
    end)

    it("lvi-reflow keeps a bare quote line inside a nested quote", function()
      local out = run({}, "printf '> > aa bb cc dd ee ff\\n> >\\n> > gg hh\\n'"
        .. " | contrib/lvi-reflow -w 14")
      expect(out).to.equal("> > aa bb cc\n> > dd ee ff\n> >\n> > gg hh\n")
    end)

    it("lvi-reflow falls back when one line lacks the prefix", function()
      local out = run({}, "printf '# alpha beta\\noops gamma\\n# delta\\n'"
        .. " | contrib/lvi-reflow -w 40")
      expect(out).to.equal("# alpha beta oops gamma # delta\n")
    end)

    -- A leader must be blank-terminated, or ordinary prose that happens to open
    -- with the same punctuation gets torn apart.
    it("lvi-reflow does not treat a shared quote character as a prefix", function()
      local out = run({}, [[printf '"Hello," she said.\n"Bye," he replied.\n']]
        .. " | contrib/lvi-reflow -w 60")
      expect(out).to.equal('"Hello," she said. "Bye," he replied.\n')
    end)

    it("lvi-reflow -p forces the prefix an ambiguous '* ' block can't declare", function()
      local out = run({}, "printf ' * alpha beta gamma delta epsilon\\n * zeta\\n'"
        .. " | contrib/lvi-reflow -w 22 -p ' *'")
      expect(out).to.equal(" * alpha beta gamma\n * delta epsilon zeta\n")
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

    -- jq's wording moves between versions, so pin the shape the list parser
    -- needs, not the message. Skipped where jq is absent (the adapter's own
    -- 127 guard is what lvi-lint turns into a status-line failure there).
    it("lvi-lint-jq normalizes a jq parse error to FILE:LINE:COL: E:", function()
      local out = run({}, "command -v jq >/dev/null 2>&1 || { echo SKIP; exit 0; }\n"
        .. [[printf '{\n  "a": 1,\n}\n' | contrib/lvi-lint-jq conf.json]])
      if not out:find("SKIP") then
        expect(out:find("^conf%.json:3:1: E: %S")).to.exist()
        expect(out:find("\n.")).to_not.exist()        -- one entry: jq stops at the first
      end
    end)

    it("lvi-lint-jq says nothing about valid json (the clean [0/0])", function()
      local out = run({}, "command -v jq >/dev/null 2>&1 || exit 0\n"
        .. [[printf '{"a":[1,2,{"b":null}]}\n' | contrib/lvi-lint-jq conf.json]])
      expect(out).to.equal("")
    end)

    it("lvi-lint-xmlstarlet drops libxml2's source/caret context lines", function()
      local out = run({}, "command -v xmlstarlet >/dev/null 2>&1 || { echo SKIP; exit 0; }\n"
        .. [[printf '<a>\n  <b>x</c>\n</a>\n' | contrib/lvi-lint-xmlstarlet a.xml]])
      if not out:find("SKIP") then
        expect(out:find("^a%.xml:2:11: E: Opening and ending tag mismatch")).to.exist()
        expect(out:find("%^")).to_not.exist()          -- the caret line is not an entry
      end
    end)

    it("lvi-lint-xmlstarlet says nothing about well-formed xml", function()
      local out = run({}, "command -v xmlstarlet >/dev/null 2>&1 || exit 0\n"
        .. [[printf '<svg><rect/></svg>\n' | contrib/lvi-lint-xmlstarlet i.svg]])
      expect(out).to.equal("")
    end)

    -- Forced --show-warnings/--show-errors on the command line: a ~/.tidyrc
    -- with `show-warnings: no` would otherwise make every buffer read clean.
    it("lvi-lint-tidy folds tidy's severities in and drops repeats", function()
      local out = run({}, "command -v tidy >/dev/null 2>&1 || { echo SKIP; exit 0; }\n"
        .. [[printf '<html><body><p>hi</body>\n<foo/>\n</html>\n' ]]
        .. [[| contrib/lvi-lint-tidy p.html]])
      if not out:find("SKIP") then
        expect(out:find("p%.html:1:1: W: missing <!DOCTYPE> declaration")).to.exist()
        expect(out:find("p%.html:2:1: E: <foo> is not recognized!")).to.exist()
        local n = select(2, out:gsub("content occurs after end of body", ""))
        expect(n).to.equal(1)                        -- tidy reports it twice
      end
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

    -- A throwaway repo for the git-backed producers, holding one of each shape
    -- lvi-gitchanges has to tell apart: a modified file in a SUBDIRECTORY (so
    -- git's repo-top-relative naming can go wrong), a DELETED file (no
    -- destination to jump to), and a RENAMED one that also changed (a new
    -- destination that does exist).
    local function gitrepo()
      local d = tmpdir()
      assert(os.execute(([[
        cd '%s' && git init -q . &&
        git config user.email t@t && git config user.name t &&
        mkdir -p sub other &&
        printf 'a\nb\nc\nd\ne\n' > sub/f.txt &&
        printf '1\n2\n3\n' > other/g.txt &&
        printf 'gone\n' > doomed.txt &&
        git add -A && git commit -qm init &&
        printf 'a\nB\nc\nd\ne\n' > sub/f.txt &&
        rm doomed.txt && git mv other/g.txt other/renamed.txt &&
        printf '1\n2\n3\n4\n' > other/renamed.txt
      ]]):format(d)))
      return d
    end
    -- A repo caught mid-commit: one STAGED edit and one UNSTAGED edit, in the
    -- same file on different lines, so the three modes have to partition.
    local function gitrepo_staging()
      local d = tmpdir()
      assert(os.execute(([[
        cd '%s' && git init -q . &&
        git config user.email t@t && git config user.name t &&
        printf 'a\nb\nc\nd\n' > f.txt && git add -A && git commit -qm init &&
        printf 'a\nSTAGED\nc\nd\n' > f.txt && git add f.txt &&
        printf 'a\nSTAGED\nc\nWORK\n' > f.txt
      ]]):format(d)))
      return d
    end
    local GC = pwd .. "/contrib/lvi-gitchanges"

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

    it("lvi-diff --xfer moves a whole-buffer hunk read-first (no phantom line)", function()
      local d = stub({ ["buffer.w1"] = "NEW\n", ["buffer.w2"] = "OLD\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_SOCK = d .. "/sock",
            LVI_WID = "w1", LVI_LINE = "1" },
        "contrib/lvi-diff --xfer put w2 w2 w1")
      -- Read the new line in ABOVE, then delete the old at its shifted
      -- address -- delete-first would empty the destination and the >=1-line
      -- clamp would leave a phantom blank the read does not replace.
      expect(read(d .. "/log"):find("0 r !sed %-n '1,1p'[^\n]*\nundojoin\n2,2d _\n")).to.exist()
      expect(read(d .. "/log"):find("\nfire\n")).to.exist()
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

    it("lvi-list matches an entry to the buffer across path spellings", function()
      -- The cross-file case: a producer names the file relative to the repo top
      -- (`sub/f.txt`) while lvi calls the buffer by an absolute, un-normalised
      -- path. Same file -- so no :e, and paint lights the line.
      local d = stub({ path = pwd .. "/./sub/f.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = pwd .. "/./sub/f.txt",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf 'sub/f.txt:4:1: boom\n' | contrib/lvi-list put qq --focus]])
      expect(read(d .. "/log"):find("^hl qq 4:1%-1 \n")).to.exist()    -- painted, not skipped
      run(env, "contrib/lvi-list next")
      local log = read(d .. "/log")
      expect(log:find("\npos 4 1\n")).to.exist()
      expect(log:find("\ne %-%-")).to_not.exist()                     -- already there: no :e
      cleanup(d)
    end)

    it("lvi-list still treats a genuinely different file as different", function()
      local d = stub({ path = pwd .. "/sub/f.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = pwd .. "/sub/f.txt",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf 'sub/../other/g.txt:2:1: boom\n' | contrib/lvi-list put qq --focus]])
      expect(read(d .. "/log"):find("^hl qq\n")).to.exist()           -- nothing to paint here
      run(env, "contrib/lvi-list next")
      expect(read(d .. "/log"):find("\ne %-%- sub/%.%./other/g%.txt\n")).to.exist()
      cleanup(d)
    end)

    it("lvi-list does not read an indented body line as a new entry", function()
      -- The body of a diff hunk can carry `-foo:12: bar`, which has a header's
      -- shape. Only the leading blank tells them apart, so one entry with a
      -- two-line body must count as 1, not 3.
      local d = stub({ path = "/cur/f.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.txt",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.txt:2:+1 -1\n -foo:12: bar\n +foo:99: baz\n']]
        .. [[ | contrib/lvi-list put qq --focus]])
      expect(read(d .. "/log"):find("status qq %[0/1%] qq")).to.exist()
      run(env, "contrib/lvi-list preview qq")
      -- ...and the body still belongs to it: preview prints header + both lines.
      local out = run(env, "contrib/lvi-list next && contrib/lvi-list preview qq")
      expect(out:find("/cur/f%.txt:2:%+1 %-1\n %-foo:12: bar\n %+foo:99: baz\n")).to.exist()
      cleanup(d)
    end)

    it("lvi-gitchanges emits absolute entries with bodies, minus deletions", function()
      local r = gitrepo()
      -- Run from a SUBDIRECTORY: git names files relative to the repo top, so
      -- only an absolute entry path is right to jump to from here.
      local out = run({}, ("cd '%s/sub' && %s 2>&1"):format(r, GC))
      expect(out:sub(1, 1)).to.equal("/")                  -- entries are absolute paths
      expect(out:find("/sub/f%.txt:2:%+1 %-1  a\n")).to.exist()
      expect(out:find("\n %-b\n %+B\n")).to.exist()      -- the hunk, indented into a body
      expect(out:find("/other/renamed%.txt:")).to.exist()  -- rename: a real destination, kept
      expect(out:find("doomed")).to_not.exist()            -- deletion: nowhere to go, skipped
      expect(out:find("1 deleted file%(s%) skipped")).to.exist()   -- ...and said so
      cleanup(r)
    end)

    it("lvi-gitchanges narrows to $LVI_FILE, and --repo opts back out", function()
      local r = gitrepo()
      local narrow = run({ LVI_FILE = r .. "/sub/f.txt" }, ("cd '%s' && %s"):format(r, GC))
      expect(narrow:find("/sub/f%.txt:")).to.exist()
      expect(narrow:find("renamed")).to_not.exist()        -- scoped to the buffer
      local wide = run({ LVI_FILE = r .. "/sub/f.txt" }, ("cd '%s' && %s --repo"):format(r, GC))
      expect(wide:find("renamed")).to.exist()
      cleanup(r)
    end)

    it("lvi-gitchanges partitions unstaged, staged, and everything", function()
      local r = gitrepo_staging()
      -- The line each hunk points at identifies which edit it found: the staged
      -- one is on line 2, the unstaged one on line 4.
      local function lines(flag)
        local got = {}
        for l in run({}, ("cd '%s' && %s %s"):format(r, GC, flag)):gmatch("[^\n]+") do
          if l:sub(1, 1) == "/" then got[#got + 1] = l:match(":(%d+):") end
        end
        return table.concat(got, ",")
      end
      expect(lines("--unstaged")).to.equal("4")     -- working tree vs index
      expect(lines("--staged")).to.equal("2")       -- index vs HEAD
      expect(lines("")).to.equal("2,4")             -- default: both, vs HEAD
      -- --unstaged already spends the "compared against" slot on the index.
      local out, ok = run({}, ("cd '%s' && %s --unstaged HEAD 2>&1"):format(r, GC))
      expect(ok).to.equal(false)
      expect(out:find("takes no REF")).to.exist()
      -- Its own list, so all three can coexist and be themed apart.
      local d = stub({ path = r .. "/f.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_LINE = "1", LVI_COL = "1", PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        ("cd '%s' && %s --unstaged"):format(r, GC))
      expect(read(d .. "/log"):find("status gitunstaged ")).to.exist()
      cleanup(d); cleanup(r)
    end)

    it("lvi-gitchanges prints without a view and pushes with one", function()
      local r = gitrepo()
      local d = stub({ path = r .. "/sub/f.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_SOCK = d .. "/sock",
                    LVI_FILE = r .. "/sub/f.txt", LVI_LINE = "1", LVI_COL = "1",
                    PATH = pwd .. "/contrib:" .. os.getenv("PATH") }
      -- No $LVI_WID and no -w: a bare shell run must never reach for `-w auto`
      -- and mutate whatever session happens to be up.
      local out = run(env, ("cd '%s' && %s"):format(r, GC))
      expect(out:find("/sub/f%.txt:2:")).to.exist()
      expect(read(d .. "/log")).to.equal("")
      env.LVI_WID = "w1"                                   -- now there is a view
      run(env, ("cd '%s' && %s"):format(r, GC))
      local log = read(d .. "/log")
      expect(log:find("\npos 2 1\n")).to.exist()
      expect(log:find("e %-%-")).to_not.exist()   -- absolute entry IS the buffer: no :e
      cleanup(d); cleanup(r)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
