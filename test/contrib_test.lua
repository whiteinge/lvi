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

-- Presence, not contents: `read` cannot tell an empty flag file (lvi-hl-col's
-- `on` marker is zero bytes) from a missing one.
local function exists(p)
  local f = io.open(p, "rb")
  if not f then return false end
  f:close(); return true
end

-- Run a shell line and return its combined output and exit ok. The env goes
-- in as exports from a wrapper script -- a plain VAR=x prefix would bind only
-- to the first command of a pipeline -- and the status comes from os.execute
-- (LuaJIT's p:close() cannot report it).
-- The scripts here reach for their siblings by NAME (lvi-search calls lvi-list,
-- all three matchers call lvi-bre-locate), so contrib goes on PATH for every
-- run -- otherwise the suite passes only on a machine that already has contrib
-- installed, which is no test at all. A PATH in `env` is PREPENDED to that (a
-- test shadowing sed puts its own directory first) rather than replacing it, so
-- no test has to remember to put contrib back.
local function run(env, cmd)
  local script, outf = os.tmpname(), os.tmpname()
  local path = ((env and env.PATH) and (env.PATH .. ":") or "")
               .. pwd .. "/contrib:" .. os.getenv("PATH")
  local sh = { ("export PATH='%s'"):format(path) }
  for k, v in pairs(env or {}) do
    if k ~= "PATH" then sh[#sh + 1] = ("export %s='%s'"):format(k, v) end
  end
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

    -- lvi-bre-locate is the shared matcher behind lvi-search, lvi-match and
    -- lvi-search --motion. It is where the offset arithmetic lives now, so it is
    -- where the offset arithmetic gets pinned; the callers test their own
    -- policy on top (a zero-width match, the grep fallback) and not this.
    local function locate(flags, pat, text)
      local d = tmpdir()
      write(d .. "/f", text)
      local out = run({}, ("contrib/lvi-bre-locate %s -- %s '%s/f'"):format(flags, pat, d))
      os.execute("rm -rf '" .. d .. "'")
      return out
    end

    it("lvi-bre-locate reports every occurrence as line, byte column, length", function()
      expect(locate("", "foo", "aaa foo bar foo\nnope\nfoo\n"))
        .to.equal("1\t5\t3\n1\t13\t3\n3\t1\t3\n")
    end)

    -- The three that separate a BRE from an ERE: under awk's dialect `foo(` is
    -- an error and the other two silently match something else.
    it("lvi-bre-locate reads a metacharacter the way vi does", function()
      expect(locate("", "'foo('", "x foo(bar)\n")).to.equal("1\t3\t4\n")
      expect(locate("", "'a+b'", "xx a+b yy aab\n")).to.equal("1\t4\t3\n")
      expect(locate("", [['\(o\)\1']], "look\n")).to.equal("1\t2\t2\n")
    end)

    -- A zero-width match has a position and no extent. Reporting LEN 0 rather
    -- than dropping it is what lets each caller pick: lvi-search keeps it as a
    -- bare column, a mark and a motion have nowhere to land and skip it.
    it("lvi-bre-locate gives a zero-width match length 0", function()
      expect(locate("", "'x*'", "ab\n")).to.equal("1\t1\t0\n1\t2\t0\n1\t3\t0\n")
    end)

    -- The marked stream goes to a file precisely so this works: `$(...)` strips
    -- trailing blank lines, and `^` matches on every one of them.
    it("lvi-bre-locate keeps matches on trailing blank lines", function()
      expect(locate("", "'^'", "foo\n\n\n")).to.equal("1\t1\t0\n2\t1\t0\n3\t1\t0\n")
    end)

    it("lvi-bre-locate folds case with -i and keeps whole words with --word", function()
      expect(locate("-i", "FOO", "Foo food\n")).to.equal("1\t1\t3\n1\t5\t3\n")
      expect(locate("--word", "foo", "foo food\n")).to.equal("1\t1\t3\n")
    end)

    -- Each kind of nothing gets its own status, because the callers report them
    -- differently -- a message line, a status notice, a fall back to grep.
    it("lvi-bre-locate distinguishes a bad pattern from a marked buffer", function()
      local d = tmpdir()
      write(d .. "/ok", "hello\n")
      write(d .. "/bin", "bi\1nary\n")
      local function status(cmd)
        local _, ok = run({}, "contrib/lvi-bre-locate " .. cmd .. " 2>/dev/null")
        return ok
      end
      expect(status(("-- foo '%s/ok'"):format(d))).to.equal(true)
      expect(status(([[-- 'a\{2' '%s/ok']]):format(d))).to.equal(false)   -- 2, bad BRE
      expect(status(("-- foo '%s/bin'"):format(d))).to.equal(false)       -- 3, marked buffer
      -- the exact codes, since the callers switch on them
      local out = run({}, ("contrib/lvi-bre-locate -- 'a\\{2' '%s/ok' 2>&1; echo $?"):format(d))
      expect(out:find("\n2\n")).to.exist()
      out = run({}, ("contrib/lvi-bre-locate -- foo '%s/bin' 2>&1; echo $?"):format(d))
      expect(out:find("\n3\n")).to.exist()
      out = run({}, ("contrib/lvi-bre-locate -- \"$(printf 'a\\001b')\" '%s/ok' 2>&1; echo $?"):format(d))
      expect(out:find("\n4\n")).to.exist()
      -- PATTERN /dev/null is the validate-only call the storing tools use
      expect(status("-- foo /dev/null")).to.equal(true)
      expect(status([[-- 'a\{2' /dev/null]])).to.equal(false)
      os.execute("rm -rf '" .. d .. "'")
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

    -- lvi-search --motion is a `:motion` filter, so it is a pure one: argv in, one
    -- line out. Same tier as lvi-reflow, no editor and no socket involved.
    local function msearch(dir, args, count, line, col, arg)
      return (run({ LVI_SOCK = dir .. "/sock" },
        ("contrib/lvi-search --motion %s '%s/buf' %d %d %d '%s'")
          :format(args, dir, count, line, col, arg)))
    end

    it("lvi-search --motion finds the next match past the cursor, exclusive", function()
      local d = stub({ buf = "aaa foo bar\nbaz foo\nlast foo here\n" })
      expect(msearch(d, "", 1, 1, 1, "foo")).to.equal("char 1 5\n")
      expect(msearch(d, "", 1, 1, 5, "foo")).to.equal("char 2 5\n")   -- never where you are
      expect(msearch(d, "", 2, 1, 1, "foo")).to.equal("char 2 5\n")   -- 2/foo
      expect(msearch(d, "-b", 1, 2, 5, "foo")).to.equal("char 1 5\n")
      cleanup(d)
    end)

    -- A motion that stops dead at the end of the buffer is not the motion vi
    -- has, so this one wraps -- vi's wrapscan, unlike lvi-search's list.
    it("lvi-search --motion wraps, in both directions and over the count", function()
      local d = stub({ buf = "one foo\ntwo foo\n" })
      expect(msearch(d, "", 1, 2, 5, "foo")).to.equal("char 1 5\n")   -- past the last
      expect(msearch(d, "-b", 1, 1, 5, "foo")).to.equal("char 2 5\n") -- before the first
      expect(msearch(d, "", 5, 1, 1, "foo")).to.equal("char 1 5\n")   -- 5 of 2 matches
      cleanup(d)
    end)

    it("lvi-search --motion reads the pattern as a BRE, and says why when it cannot", function()
      local d = stub({ buf = "aaa foo(bar)\nxx a+b yy\nlook\n" })
      expect(msearch(d, "", 1, 1, 1, "foo(")).to.equal("char 1 5\n")      -- literal paren
      expect(msearch(d, "", 1, 1, 1, "a+b")).to.equal("char 2 4\n")       -- literal plus
      expect(msearch(d, "", 1, 1, 1, [[\(o\)\1]])).to.equal("char 1 6\n") -- back-reference
      expect(msearch(d, "", 1, 1, 1, "^look")).to.equal("char 3 1\n")     -- anchored
      expect(msearch(d, "", 1, 1, 1, "zzz")).to.equal("err pattern not found\n")
      expect(msearch(d, "", 1, 1, 1, [[a\{2]])).to.equal("err bad pattern: a\\{2\n")
      cleanup(d)
    end)

    -- The last pattern is the tool's to keep: that is what makes `n` re-run the
    -- matcher against the buffer as it is now rather than walk a snapshot.
    it("lvi-search --motion remembers the pattern for --last, and --word takes it off the buffer", function()
      local d = stub({ buf = "foo food\nfoo bar\n" })
      expect(msearch(d, "", 1, 1, 1, "foo")).to.equal("char 1 5\n")   -- inside "food"
      expect(msearch(d, "--last", 1, 1, 5, "")).to.equal("char 2 1\n")
      expect(read(d .. "/sock.search-pat")).to.equal("\n\nfoo\n")
      -- an empty argument reuses it too, the way a bare `/<CR>` does in vi
      expect(msearch(d, "", 1, 1, 5, "")).to.equal("char 2 1\n")
      -- --word: whole words only, and it stays a word search for the next --last
      expect(msearch(d, "--word", 1, 1, 1, "")).to.equal("char 2 1\n") -- skips "food"
      expect(read(d .. "/sock.search-pat")).to.equal("1\n\nfoo\n")
      expect(msearch(d, "--last", 1, 2, 1, "")).to.equal("char 1 1\n") -- wraps, still whole-word
      cleanup(d)
    end)

    -- The store keeps how a search MATCHED, not just what it matched, so a
    -- repeat is exact even after the case policy changes underneath it. The two
    -- shapes share this one file, which is the whole reason they are one script.
    local function msearch_env(dir, env, args, count, line, col, arg)
      env.LVI_SOCK = dir .. "/sock"
      return (run(env, ("contrib/lvi-search --motion %s '%s/buf' %d %d %d '%s'")
        :format(args, dir, count, line, col, arg)))
    end

    it("lvi-search --motion repeats a search as it was made, folding and all", function()
      local d = stub({ buf = "Foo and foo\n" })
      -- smart case: an all-lowercase pattern folds, so both spellings match
      expect(msearch_env(d, { LVI_SEARCH_CASE = "smart" }, "", 1, 1, 1, "foo"))
        .to.equal("char 1 9\n")
      expect(read(d .. "/sock.search-pat")).to.equal("\n1\nfoo\n")
      -- the policy changes; --last still folds, because the store said it did
      expect(msearch_env(d, { LVI_SEARCH_CASE = "sensitive" }, "--last", 1, 1, 9, ""))
        .to.equal("char 1 1\n")
      -- a FRESH sensitive search of the same pattern goes somewhere else, which
      -- is what makes the line above worth asserting
      expect(msearch_env(d, { LVI_SEARCH_CASE = "sensitive" }, "", 1, 1, 9, "foo"))
        .to.equal("char 1 9\n")
      cleanup(d)
    end)

    -- A marker byte in the BUFFER makes every column past it wrong, since one
    -- pass counts it as text and the next as a mark. Only lvi-match used to
    -- check; sharing the matcher gave the other two the check for free.
    it("lvi-search --motion refuses a buffer holding a marker byte", function()
      local d = stub({ buf = "bi\1nary foo\n" })
      expect(msearch(d, "", 1, 1, 1, "foo")).to.equal("err buffer holds a marker byte\n")
      cleanup(d)
    end)

    it("lvi-search --motion skips a zero-width match and reports an empty store", function()
      local d = stub({ buf = "ab\n" })
      -- `z*` matches the empty string everywhere; a width-less match is nowhere
      -- to land, so it is not a match here.
      expect(msearch(d, "", 1, 1, 1, "z*")).to.equal("err pattern not found\n")
      local e = stub({ buf = "ab\n" })          -- fresh: nothing kept yet
      expect(msearch(e, "--last", 1, 1, 1, "")).to.equal("err no previous search\n")
      cleanup(d); cleanup(e)
    end)

    -- A fake ispell -a pipe, so the test needs no aspell: banner, then per input
    -- line a `# WORD OFFSET` for each hit and a blank to close it. OFFSET is
    -- 0-based counting lvi-spell's own `^` escape, which lands on the real line's
    -- 1-based byte column -- the two adjustments cancel.
    -- A file, not an inline command: the env goes into the wrapper as
    -- export VAR='...', so a value with a quote in it would not survive.
    local function fakespell(d)
      local path = d .. "/fakespell"
      write(path, "#!/bin/sh\n" ..
        [[exec awk 'BEGIN{print "@(#) Fake Ispell"} NR==1{next} ]] ..
        [[{ split("brwn jumpd", w, " "); for (i in w) { p = index($0, w[i]); ]] ..
        [[if (p) printf "# %s %d\n", w[i], p - 1 } print "" }']] .. "\n")
      os.execute("chmod +x '" .. path .. "'")
      return path
    end

    -- One list is both views of the scan: the entries carry each misspelling's
    -- extent, and --paint=extent is what marks the words. No second paint, and no
    -- second place the columns are computed.
    it("lvi-spell puts word extents and lets the list paint them", function()
      local d = stub({ buffer = "the quick brwn fox\njumpd over\n", path = "doc.txt\n" })
      write(d .. "/sock.spell", "")                 -- the enabled flag
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
                    LVI_FILE = "doc.txt", LVI_LINE = "1", LVI_COL = "1",
                    LVI_SPELL_CMD = fakespell(d),
                    PATH = pwd .. "/contrib:" .. os.getenv("PATH") }
      run(env, "contrib/lvi-spell --worker")
      expect(read(d .. "/sock.lists/spellbad")).to.equal(
        "doc.txt:1.11-14: brwn\ndoc.txt:2.1-5: jumpd\n")
      expect(read(d .. "/sock.lists/spellbad.paint")).to.equal("extent\n")
      expect(read(d .. "/sock.lists/spellbad.cols")).to.equal("byte\n")
      local log = read(d .. "/log")
      expect(log:find("hl spellbad 1:11%-14 2:1%-5")).to.exist()
      expect(log:find("status spellbad %[0/2%] spellbad")).to.exist()
      -- stepping moves the cursor onto the word and marks that one apart
      run(env, "contrib/lvi-list next spellbad")
      log = read(d .. "/log")
      expect(log:find("\npos 1 11 byte jump\n")).to.exist()
      expect(log:find("\nhl spellbad%-cur 1:11%-14\n")).to.exist()
      cleanup(d)
    end)

    it("lvi-spell off drops the list, which is what clears the marks", function()
      local d = stub({ buffer = "brwn\n", path = "doc.txt\n" })
      write(d .. "/sock.spell", "")
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
                    LVI_FILE = "doc.txt", LVI_LINE = "1", LVI_COL = "1",
                    LVI_SPELL_CMD = fakespell(d),
                    PATH = pwd .. "/contrib:" .. os.getenv("PATH") }
      run(env, "contrib/lvi-spell --worker")
      write(d .. "/log", "")
      run(env, "contrib/lvi-spell off")
      local log = read(d .. "/log")
      expect(log:find("hl spellbad\n")).to.exist()       -- empty paint == cleared
      expect(log:find("hl spellbad%-cur\n")).to.exist()
      expect(log:find("status spellbad\n")).to.exist()
      expect(exists(d .. "/sock.spell")).to.equal(false)  -- and the toggle is off
      cleanup(d)
    end)

    -- A list paints the groups <name> and <name>-cur, so a list NAMED `x-cur`
    -- would be a second writer on `x`'s current-entry group and the two would
    -- take turns erasing each other.
    it("lvi-list refuses a name that collides with a -cur paint group", function()
      local d = stub({})
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" }
      expect(select(2, run(env, "echo 'x:1:y' | lvi-list put foo-cur"))).to.equal(false)
      expect(exists(d .. "/sock.lists/foo-cur")).to.equal(false)
      write(d .. "/saved", "x:1:y\n")
      expect(select(2, run(env, ("lvi-list load '%s/saved' bar-cur"):format(d)))).to.equal(false)
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

    -- THE MATCHER: sed wraps each match in a marker byte and awk counts the
    -- offsets, so entries carry a real extent, one per OCCURRENCE, in vi's own
    -- BRE. grep could do neither; awk alone would have had to speak ERE.
    it("lvi-search puts per-occurrence extents in vi's BRE", function()
      local d = stub({ buffer = "aaa foo(bar) foo\nnothing\n", path = "x.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
                    LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1",
                    PATH = pwd .. "/contrib:" .. os.getenv("PATH") }
      run(env, "contrib/lvi-search --worker -- foo")
      expect(read(d .. "/sock.lists/search")).to.equal(
        "x.txt:1.5-7: aaa foo(bar) foo\nx.txt:1.14-16: aaa foo(bar) foo\n")
      -- the match is what you are looking at, so it lights rather than signs
      expect(read(d .. "/sock.lists/search.paint")).to.equal("extent\n")
      expect(read(d .. "/log"):find("\nhl search 1:5%-7 1:14%-16")).to.exist()
      -- with every match lit, the one you are on needs its own look
      expect(read(d .. "/log"):find("hi search%-cur reverse bold pri=11")).to.exist()
      cleanup(d)
    end)

    -- The three that separate a BRE from an ERE. Under awk's dialect `foo(` is
    -- an error, `a+b` and the back-reference silently match something else.
    it("lvi-search reads a metacharacter the way vi does", function()
      local cases = { { "foo(", "aaa foo(bar)\n", "x.txt:1.5-8: aaa foo(bar)\n" },
                      { "a+b",  "xx a+b yy aab\n", "x.txt:1.4-6: xx a+b yy aab\n" },
                      { "\\(o\\)\\1", "look\n", "x.txt:1.2-3: look\n" },
                      { "^aa",  "aab\nxaa\n",      "x.txt:1.1-2: aab\n" } }
      for _, c in ipairs(cases) do
        local d = stub({ buffer = c[2], path = "x.txt\n" })
        run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
              LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1",
              PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
          ("contrib/lvi-search --worker -- '%s'"):format(c[1]))
        expect(read(d .. "/sock.lists/search")).to.equal(c[3])
        cleanup(d)
      end
    end)

    -- A zero-width match has a position but no extent; dropping it would lose
    -- the match, and inventing a width would light a cell it never covered.
    it("lvi-search gives a zero-width match a column and no range", function()
      local d = stub({ buffer = "ab\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1",
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-search --worker -- 'x*'")
      expect(read(d .. "/sock.lists/search")).to.equal(
        "x.txt:1.1: ab\nx.txt:1.2: ab\nx.txt:1.3: ab\n")
      cleanup(d)
    end)

    -- Same buffer, the other policy: a search still has to answer, so it drops
    -- to `grep -n` and the per-line entries this script emitted before extents.
    it("lvi-search falls back to per-line entries on a marked buffer", function()
      local d = stub({ buffer = "bi\1nary foo\nplain foo\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1" },
        "contrib/lvi-search --worker -- foo")
      expect(read(d .. "/sock.lists/search")).to.equal(
        "x.txt:1:bi\1nary foo\nx.txt:2:plain foo\n")
      cleanup(d)
    end)

    it("lvi-search names a bad BRE without reading the buffer", function()
      local d = stub({ buffer = "haystack\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_FILE = "x.txt" },
        [[contrib/lvi-search --worker -- 'a\{2']])
      local log = read(d .. "/log")
      expect(log:find("msge bad pattern /a")).to.exist()
      expect(log:find("%%p")).to_not.exist()      -- caught before the buffer is read
      cleanup(d)
    end)

    it("lvi-search -i folds case and still lands on the unfolded line", function()
      local d = stub({ buffer = "Foo and foo\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1",
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-search --worker -i -- FOO")
      expect(read(d .. "/sock.lists/search")).to.equal(
        "x.txt:1.1-3: Foo and foo\nx.txt:1.9-11: Foo and foo\n")
      cleanup(d)
    end)

    -- `--word` is what makes `*` behave, and it has to mean the same thing in
    -- both shapes. The list half gets the word from $LVI_CWORD (the motion half
    -- reads it off the buffer, since a :motion filter gets no refreshed env).
    it("lvi-search --word keeps whole words only", function()
      local d = stub({ buffer = "foo food\n", path = "x.txt\n" })
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "x.txt", LVI_LINE = "1", LVI_COL = "1",
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-search --worker --word -- foo")
      expect(read(d .. "/sock.lists/search")).to.equal("x.txt:1.1-3: foo food\n")
      cleanup(d)
    end)

    -- The store is written before the worker forks, so a `d/` pressed the
    -- instant `*` returns cannot race it. LVI=true keeps the forked worker inert.
    it("lvi-search --word stores $LVI_CWORD before backgrounding", function()
      local d = stub({ buffer = "foo\n", path = "x.txt\n" })
      run({ LVI = "true", STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_CWORD = "foo", LVI_FILE = "x.txt" }, "contrib/lvi-search --word")
      expect(read(d .. "/sock.search-pat")).to.equal("1\n\nfoo\n")
      cleanup(d)
    end)

    -- lvi-match: the state file is the documented interface, so the matcher tests
    -- write it and run --worker directly. That keeps the paint deterministic --
    -- `add` backgrounds its own scan, which would race the log.
    local function matchstate(d, lines) write(d .. "/sock.match", lines) end
    local TAB = "\t"

    -- The dialect. Under the old awk `match()` these were an error (`foo(`) or a
    -- silent mismatch (`a+b`); a back-reference had no ERE spelling at all.
    it("lvi-match marks a POSIX BRE, extents and all", function()
      local d = stub({ buffer = "aaa foo(bar) foo\nxx a+b yy\n", path = "x.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" }
      for _, c in ipairs({ { "foo(", "hl g 1:5-8" },
                           { "a+b", "hl g 2:4-6" },
                           { "\\(o\\)\\1", "hl g 1:6-7 1:15-16" },
                           { "^aaa", "hl g 1:1-3" },
                           { "y$", "hl g 2:9-9" } }) do
        write(d .. "/log", "")
        matchstate(d, "1" .. TAB .. "g" .. TAB .. "-" .. TAB .. c[1] .. "\n")
        run(env, "contrib/lvi-match --worker")
        expect(read(d .. "/log"):find(c[2], 1, true)).to.exist()
      end
      cleanup(d)
    end)

    it("lvi-match honors -i and --word, and paints nothing for a zero-width match", function()
      local d = stub({ buffer = "Foo food foo\nxx\n", path = "x.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" }
      matchstate(d, "1" .. TAB .. "g" .. TAB .. "i" .. TAB .. "FOO\n")
      run(env, "contrib/lvi-match --worker")
      expect(read(d .. "/log"):find("hl g 1:1-3 1:5-7 1:10-12", 1, true)).to.exist()
      write(d .. "/log", "")
      matchstate(d, "1" .. TAB .. "g" .. TAB .. "w" .. TAB .. "foo\n")
      run(env, "contrib/lvi-match --worker")
      expect(read(d .. "/log"):find("hl g 1:10-12\n", 1, true)).to.exist()  -- not "food"
      write(d .. "/log", "")
      matchstate(d, "1" .. TAB .. "g" .. TAB .. "-" .. TAB .. "z*\n")
      run(env, "contrib/lvi-match --worker")
      expect(read(d .. "/log"):find("hl g\n", 1, true)).to.exist()          -- empty: clears
      cleanup(d)
    end)

    -- One sed pass per pattern, merged afterwards: two patterns in one group are
    -- one `hl` (a whole-group replace), and a group that has stopped matching
    -- still gets an empty one, which is what clears it.
    it("lvi-match merges a shared group and clears one that stopped matching", function()
      local d = stub({ buffer = "foo bar\n", path = "x.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" }
      matchstate(d, "1" .. TAB .. "g" .. TAB .. "-" .. TAB .. "foo\n"
               .. "2" .. TAB .. "g" .. TAB .. "-" .. TAB .. "bar\n"
               .. "3" .. TAB .. "other" .. TAB .. "-" .. TAB .. "nope\n")
      run(env, "contrib/lvi-match --worker")
      local log = read(d .. "/log")
      expect(log:find("hl g 1:1-3 1:5-7", 1, true)).to.exist()
      expect(log:find("hl other\n", 1, true)).to.exist()
      expect(log:find("status match [match 3: 2]", 1, true)).to.exist()
      cleanup(d)
    end)

    -- sed's `I` flag is GNU/BSD, not POSIX. Shadow sed with one that refuses it
    -- to drive the tr-fold fallback, which must find the same columns: folding is
    -- byte-length preserving, so they still land on the unfolded line.
    it("lvi-match folds case with tr when sed has no I flag", function()
      local d = stub({ buffer = "Foo and foo\n", path = "x.txt\n" })
      write(d .. "/sed", "#!/bin/sh\ncase \"$1\" in *I) exit 1 ;; esac\nexec /bin/sed \"$@\"\n")
      os.execute("chmod +x '" .. d .. "/sed'")
      matchstate(d, "1" .. TAB .. "g" .. TAB .. "i" .. TAB .. "FOO\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            PATH = d .. ":" .. os.getenv("PATH") },
        "contrib/lvi-match --worker")
      expect(read(d .. "/log"):find("hl g 1:1-3 1:9-11", 1, true)).to.exist()
      cleanup(d)
    end)

    it("lvi-match refuses a bad BRE and a pattern holding a marker byte", function()
      local d = stub({ buffer = "x\n", path = "x.txt\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" }
      expect(select(2, run(env, [[contrib/lvi-match add 'a\{2']]))).to.equal(false)
      expect(select(2, run(env, [[contrib/lvi-match add "$(printf 'a\001b')"]]))).to.equal(false)
      expect(exists(d .. "/sock.match")).to.equal(false)   -- neither reached the state
      -- -F escapes the BRE metacharacters and only those: escaping an ERE's `+`
      -- would turn it into GNU BRE's one-or-more operator.
      run(env, [[contrib/lvi-match add -F 'a.b*+c']])
      expect(read(d .. "/sock.match")).to.equal("1\tmatch1\t-\ta\\.b\\*+c\n")
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

    -- A bad LVI_LINT_COLS would reach lvi-list and `die` to a stderr that a :bg
    -- binding discards, so the list would just stop updating with no sign why.
    it("lvi-lint --worker names a bad LVI_LINT_COLS on the status segment", function()
      local d = stub({ buffer = "x\n", path = "x.zz\n" })
      local _, ok = run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                          LVI_EVENT = "change", LVI_LINT_BACKEND = "no-such-linter",
                          LVI_LINT_COLS = "furlongs" },
        "contrib/lvi-lint --worker")
      expect(ok).to.equal(false)
      expect(read(d .. "/log"):find("status lint %[lvi%-lint: LVI_LINT_COLS=")).to.exist()
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
      -- Exact jump, unit named, and jump-class: a step is navigation, so Ctrl-O
      -- walks back out of a walk and `''` returns to where you set off from.
      expect(log:find("\npos 3 9 byte jump\n")).to.exist()
      cleanup(d)
    end)

    -- The GNU error-message format (Coding Standards 4.3) spells a position
    -- two ways and a range three; bison emits every one of them.
    it("lvi-list takes GNU `line.col` and range entries, landing on the start", function()
      local d = stub({ path = "/cur/parse.y\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/parse.y",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/parse.y:12.5-12.20: rule useless\n]] ..
               [[/cur/parse.y:30.7-9: token unused\n]] ..
               [[/cur/parse.y:44-46: spans lines\n' | contrib/lvi-list put gnu --focus]])
      expect(read(d .. "/log"):find("\nstatus gnu %[0/3%] gnu\n")).to.exist()
      run(env, "contrib/lvi-list next")
      expect(read(d .. "/log"):find("\npos 12 5 byte jump\n")).to.exist()
      expect(read(d .. "/log"):find("\nmsg rule useless\n")).to.exist()  -- prefix stripped
      run(env, "contrib/lvi-list next")
      expect(read(d .. "/log"):find("\npos 30 7 byte jump\n")).to.exist()
      run(env, "contrib/lvi-list next")
      expect(read(d .. "/log"):find("\npos 44 1 byte jump\n")).to.exist()     -- no column in that form
      cleanup(d)
    end)

    it("lvi-list --cols declares what a producer's columns count", function()
      local d = stub({ path = "/cur/f.c\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.c",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.c:2:9: E: implicit declaration\n' ]] ..
               [[| contrib/lvi-list put cc --focus --cols=display]])
      run(env, "contrib/lvi-list next")
      expect(read(d .. "/log"):find("\npos 2 9 display jump\n")).to.exist()
      -- The sidecar is not a list: `ls` must not offer it as one to step.
      local out = run(env, "contrib/lvi-list ls")
      expect(out:find("cc%.cols")).to_not.exist()
      expect(select(2, run(env, [[: | contrib/lvi-list put cc --cols=furlongs]]))).to.equal(false)
      cleanup(d)
    end)

    -- PAINT POLICY: what an entry looks like is the producer's declaration, not
    -- a property of the paint call. `sign` is the default for everyone, so a
    -- range entry marks its first cell (and, before the policy existed, mangled
    -- the :hl range doing it -- `12.5-20` reached :hl as a line number).
    it("lvi-list signs a range entry's first cell by default", function()
      local d = stub({ path = "/cur/f.c\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.c",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.c:12.5-20: boom\n' | contrib/lvi-list put qq --focus]])
      local log = read(d .. "/log")
      expect(log:find("hl qq 12:1%-1")).to.exist()
      expect(log:find("12%.5")).to_not.exist()
      cleanup(d)
    end)

    it("lvi-list --paint=extent lights each entry's range, signing the rest", function()
      local d = stub({ path = "/cur/f.c\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.c",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.c:12.5-20: match\n]] ..
               [[/cur/f.c:30:7: col only\n]] ..
               [[/cur/f.c:44: line only\n' | contrib/lvi-list put s --focus --paint=extent]])
      -- the range lights; a bare column and a bare line have no extent to light
      expect(read(d .. "/log"):find("hl s 12:5%-20 30:1%-1 44:1%-1")).to.exist()
      -- the sidecar is not a list
      expect(run(env, "contrib/lvi-list ls"):find("s%.paint")).to_not.exist()
      cleanup(d)
    end)

    it("lvi-list --paint=cur lights only the entry you are on", function()
      local d = stub({ path = "/cur/f.c\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.c",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.c:12.5-20: one\n]] ..
               [[/cur/f.c:30.3-8: two\n' | contrib/lvi-list put s --focus --paint=cur]])
      run(env, "contrib/lvi-list next")
      local log = read(d .. "/log")
      expect(log:find("\nhl s 12:1%-1 30:1%-1")).to.exist()   -- every entry still a sign
      expect(log:find("\nhl s%-cur 12:5%-20\n")).to.exist()  -- ...except the one you are on
      cleanup(d)
    end)

    -- :hl takes byte ranges and never learned units, and lvi-list has no way to
    -- convert (a col-bearing entry's text is a message, not the line). Signing
    -- is the honest degradation; a mispainted extent would be silent.
    it("lvi-list falls back to signs when an extent list is not in bytes", function()
      local d = stub({ path = "/cur/f.c\n" })
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                    LVI_SOCK = d .. "/sock", LVI_FILE = "/cur/f.c",
                    LVI_LINE = "1", LVI_COL = "1" }
      run(env, [[printf '/cur/f.c:12.5-20: match\n' ]] ..
               [[| contrib/lvi-list put s --focus --paint=extent --cols=char]])
      expect(read(d .. "/log"):find("hl s 12:1%-1")).to.exist()
      expect(select(2, run(env, [[: | contrib/lvi-list put s --paint=blink]]))).to.equal(false)
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
      expect(log:find("\npos 4 1 byte jump\n")).to.exist()
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
      expect(log:find("\npos 2 1 byte jump\n")).to.exist()
      expect(log:find("e %-%-")).to_not.exist()   -- absolute entry IS the buffer: no :e
      cleanup(d); cleanup(r)
    end)

    -- lvi-ftype's two entry points: the name (a commit message classifies on
    -- its own) and an explicit word (a .txt draft told it is going into mail).
    it("lvi-ftype reads a commit message by name and projects both regimes", function()
      local d = stub({})
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/home/u/proj/.git/COMMIT_EDITMSG",
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-ftype")
      local log = read(d .. "/log")
      expect(log:find("set fmtprg=lvi%-reflow %-w 72")).to.exist()   -- body wraps at 72
      -- ...and the same limit reaches the overlay, subject rule ahead of it.
      expect(read(d .. "/sock.hlcol.rule")).to.equal("1:50:subjectlong 1:72:subjecterror\n")
      -- A commit's marks are not optional: the arm's mark=on shows them on entry
      -- rather than waiting for \ho.
      expect(exists(d .. "/sock.hlcol")).to.be(true)
      expect(log:find("on change lvi%-hl%-col scan")).to.exist()     -- hooks armed
      cleanup(d)
    end)

    -- An arm with no `col` clears the limit; an arm with no `mark` says nothing
    -- about visibility, so a \ho you pressed survives the switch (the marks
    -- themselves go with the empty rule, through the scan's one total paint).
    it("lvi-ftype clears the limit for a filetype with none, leaving \\ho alone", function()
      local d = stub({ buffer = "package main\n" })
      write(d .. "/sock.hlcol", "")                       -- you pressed \ho
      write(d .. "/sock.hlcol.rule", "1:50:subjectlong 1:72:subjecterror\n")
      write(d .. "/sock.hlcol.painted", "overlong\nsubjectlong\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/home/u/main.go",                 -- no col, no mark
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-ftype")
      expect(exists(d .. "/sock.hlcol")).to.be(true)                 -- yours to hold
      expect(read(d .. "/sock.hlcol.rule")).to.equal("")             -- limit cleared
      expect(read(d .. "/log"):find("msg col")).to_not.exist()  -- silent, every :e
      cleanup(d)
    end)

    it("lvi-ftype takes an explicit filetype word over the buffer's name", function()
      local d = stub({})
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
            LVI_FILE = "/home/u/notes.txt",              -- name says prose (79)
            PATH = pwd .. "/contrib:" .. os.getenv("PATH") },
        "contrib/lvi-ftype mail")                        -- intent says mail (72)
      expect(read(d .. "/log"):find("set fmtprg=lvi%-reflow %-w 72")).to.exist()
      expect(read(d .. "/sock.hlcol.rule")).to.equal("72\n")
      cleanup(d)
    end)

    -- The shipped commit rule: two limits on the subject, each tier stopping
    -- where the next begins, and the body left alone (no catch-all item).
    it("lvi-hl-col --worker tiers one line and leaves the rest unmarked", function()
      local d = stub({ buffer =
        "a subject line of thirty-nine characters\nx\na body line of exactly thirty-one\n" })
      write(d .. "/sock.hlcol", "")                      -- overlay on
      write(d .. "/sock.hlcol.rule", "1:20:subjectlong 1:30:subjecterror\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" },
        "contrib/lvi-hl-col --worker")
      local log = read(d .. "/log")
      expect(log:find("\nhl subjectlong 1:21%-30\n")).to.exist()   -- clipped at the
      expect(log:find("\nhl subjecterror 1:31%-40\n")).to.exist()  -- next tier
      expect(log:find("3:")).to_not.exist()                       -- body: no rule
      cleanup(d)
    end)

    -- A `*` item is the "everything else" arm: it must not double up on a line a
    -- line-specific item already claimed.
    it("lvi-hl-col --worker lets the catch-all cover only unclaimed lines", function()
      local d = stub({ buffer = "a subject line of thirty-nine characters\n"
        .. "x\na body line of exactly thirty-one\n" })
      write(d .. "/sock.hlcol", "")
      write(d .. "/sock.hlcol.rule", "1:20:subjectlong 30\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" },
        "contrib/lvi-hl-col --worker")
      local log = read(d .. "/log")
      expect(log:find("\nhl subjectlong 1:21%-40\n")).to.exist()   -- to end of line
      expect(log:find("\nhl overlong 3:31%-33\n")).to.exist()      -- the body only
      expect(log:find("overlong 1:")).to_not.exist()               -- not line 1
      cleanup(d)
    end)

    -- A typo must say so: an unchecked column reads `seventytwo` as 0 and marks
    -- every line whole. The repeating-condition channel is the status segment.
    it("lvi-hl-col --worker names a bad rule item instead of painting nonsense", function()
      local d = stub({ buffer = "a line of exactly thirty-three ..\n" })
      write(d .. "/sock.hlcol", "")
      write(d .. "/sock.hlcol.rule", "seventytwo 30\n")
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" },
        "contrib/lvi-hl-col --worker")
      local log = read(d .. "/log")
      expect(log:find("status hlcol %[lvi%-hl%-col: bad rule item 'seventytwo'%]")).to.exist()
      expect(log:find("\nhl overlong 1:31%-33\n")).to.exist()      -- the good item still works
      expect(log:find("1:1%-33")).to_not.exist()                   -- and column 0 never happened
      cleanup(d)
    end)

    -- A projection while the overlay is off installs the number and touches the
    -- screen not at all -- the table owns the limit, the toggle owns visibility.
    -- It must not clear from here either: that clear goes out detached and can
    -- land after a newer scan's paint, wiping marks that belong on screen.
    it("lvi-hl-col rule installs the number without painting while off", function()
      local d = stub({ buffer = "short\n" })
      write(d .. "/sock.hlcol.rule", "1:20:subjectlong 30\n")     -- no flag: off
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" },
        "contrib/lvi-hl-col rule 72")
      expect(read(d .. "/sock.hlcol.rule")).to.equal("72\n")
      expect(read(d .. "/log")).to.equal("")
      cleanup(d)
    end)

    -- An arm with no limit sends the empty rule, and `on`'s fallback to
    -- LVI_HL_COL_DEFAULT keys off an EMPTY rule file -- so the empty rule has to
    -- leave zero bytes behind. A bare newline reads as a rule in force, and \ho
    -- then turns the overlay on with a blank number and marks nothing.
    it("lvi-hl-col rule '' leaves an empty rule that `on` falls back from", function()
      local d = stub({ buffer = "short\n" })
      write(d .. "/sock.hlcol.rule", "79\n")
      local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock",
        LVI_HL_COL_DEFAULT = "79" }
      run(env, "contrib/lvi-hl-col rule ''")
      expect(read(d .. "/sock.hlcol.rule")).to.equal("")
      run(env, "contrib/lvi-hl-col on")
      expect(read(d .. "/sock.hlcol.rule")).to.equal("79\n")
      expect(read(d .. "/log"):find("msg col 79\n")).to.exist()
      cleanup(d)
    end)

    -- The clear on rule-change is not enough on its own: on a buffer switch two
    -- scans are in flight (the projection's and the bufenter hook's), and one
    -- can paint the old rule's groups AFTER that clear. So every paint is total
    -- over the groups the last one used, whichever lands last.
    it("lvi-hl-col --worker clears a group the previous paint used", function()
      local d = stub({ buffer = "a line of exactly thirty-three ..\n" })
      write(d .. "/sock.hlcol", "")
      write(d .. "/sock.hlcol.rule", "30\n")
      write(d .. "/sock.hlcol.painted", "overlong\nsubjectlong\n")   -- a commit buffer's
      run({ LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_SOCK = d .. "/sock" },
        "contrib/lvi-hl-col --worker")
      local log = read(d .. "/log")
      expect(log:find("\nhl overlong 1:31%-33\n")).to.exist()
      expect(log:find("\nhl subjectlong\n")).to.exist()              -- gone with the rule
      expect(read(d .. "/sock.hlcol.painted")).to.equal("overlong\n")
      cleanup(d)
    end)

    -- LVI_SOCK is cleared, not just unset: the script trusts an exported socket
    -- over `lvi -l`, so a suite run from inside a live view (`:!make test`)
    -- would resolve the REAL socket -- writing state beside it and testing the
    -- resolved path instead of this one, while still passing.
    it("lvi-hl-col rule is silent with no view to project onto (a hook must not banner)", function()
      local d = stub({})                                 -- no `list`: no views
      local out = run({ LVI = STUB, STUB_DIR = d, LVI_SOCK = "", LVI_HL_COL_DEFAULT = "79" },
        "contrib/lvi-hl-col rule 72")
      expect(out).to.equal("")
      expect(read(d .. "/log")).to.equal("")
      cleanup(d)
    end)

    -- lvi-cmd. The picker itself needs a terminal, so $LVI_PICKER points at a
    -- stub that saves the rows it was offered and echoes back the one matching
    -- $PICK -- which makes both halves assertable: what the tool put in front
    -- of you, and what it sent when you chose.
    describe("lvi-cmd", function()
      local MAPS = "\\ll\t:silent !lvi-list switch<CR>\n"
                .. "n\t:bg lvi-list next<CR>\n"
                .. "<C-a>\t:bg lvi-incr<CR>\n"
                .. "<Space>x\t\"ayy"

      local function picker(d)
        write(d .. "/pick", "#!/bin/sh\ncat > \"$STUB_DIR/rows\"\n"
                         .. "grep -m1 -F -e \"$PICK\" \"$STUB_DIR/rows\"\n")
        os.execute("chmod +x '" .. d .. "/pick'")
        return d .. "/pick"
      end

      local function pick(d, what, extra)
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_MAPS = MAPS,
                      LVI_PICKER = picker(d), PICK = what }
        for k, v in pairs(extra or {}) do env[k] = v end
        run(env, "contrib/lvi-cmd")
        return read(d .. "/log"), read(d .. "/rows")
      end

      it("runs a picked binding by injecting its lhs, not its rhs", function()
        local d = stub({})
        expect(pick(d, "\\ll")).to.equal("normal \\ll\n")
        cleanup(d)
      end)

      -- The lhs travels as key NOTATION and has to land as the raw byte the
      -- keyboard would have produced, or :normal injects five characters.
      it("decodes <C-x> notation back to a control byte", function()
        local d = stub({})
        expect(pick(d, "<C-a>")).to.equal("normal \1\n")
        cleanup(d)
      end)

      -- ex.dispatch trims its argument, so a <Space> leader cannot ride
      -- :normal -- and injecting the trimmed remainder would silently run a
      -- DIFFERENT binding. Refuse it out loud instead.
      it("refuses an lhs that begins with a space rather than mis-running it", function()
        local d = stub({})
        local log = pick(d, "<Space>x")
        expect(log:find("^msge lvi%-cmd:")).to.exist()
        expect(select(2, log:gsub("\n", ""))).to.equal(1)     -- the msge and nothing else
        expect(log:find("\nnormal")).to_not.exist()
        cleanup(d)
      end)

      -- A tool can want a range, arguments, or a different spawn form, so the
      -- pick seeds the ':' prompt and stops -- no <CR>.
      it("seeds the prompt for a tool instead of running it blind", function()
        local d = stub({})
        expect(pick(d, "cmd  lvi-list")).to.equal("normal :silent !lvi-list\n")
        cleanup(d)
      end)

      it("offers the keymap and PATH's lvi-* tools in one list", function()
        local d = stub({})
        local _, rows = pick(d, "n ")
        expect(rows:find("key  \\ll +:silent !lvi%-list switch<CR>")).to.exist()
        expect(rows:find("cmd  lvi%-list +external quickfix/location lists for lvi.")).to.exist()
        expect(rows:find("cmd  lvi%-cmd")).to_not.exist()      -- never offers itself
        cleanup(d)
      end)

      -- The two header shapes in contrib: `name -- purpose` on the synopsis
      -- line, and a synopsis then a blank comment line then a paragraph.
      it("lifts a purpose from either header shape", function()
        local d = stub({})
        local _, rows = pick(d, "n ")
        expect(rows:find("cmd  lvi%-hl%-col +mark text past a column limit.")).to.exist()
        expect(rows:find("cmd  lvi%-search +Search a running lvi from outside it")).to.exist()
        cleanup(d)
      end)

      -- Aimed at another view, lvi is live and $LVI_MAPS is somebody else's, so
      -- the keymap has to come over the socket.
      it("reads the keymap over the socket when given -w", function()
        local d = stub({})
        local env = { LVI = STUB, STUB_DIR = d, LVI_MAPS = MAPS,
                      LVI_PICKER = picker(d), PICK = "cmd  lvi-list" }
        run(env, "contrib/lvi-cmd -w w9")
        expect(read(d .. "/log")).to.equal("map\nnormal :silent !lvi-list\n")
        cleanup(d)
      end)
    end)

    -- lvi-shell.sh is sourced, not run, so these drive its functions from a
    -- shell whose $LVI is the stub. LVI_WID set is the shell-out case (queued,
    -- and $LVI_FILE is the only source for the current file); unset is the
    -- live case, where the file comes back over the socket.
    describe("lvi-shell.sh", function()
      -- The file declares itself zsh/bash/mksh, not POSIX sh: `lvi-mv` is not a
      -- name dash will even parse. So these run under bash, unlike every other
      -- test here. -i for the two that need $- to say interactive, since that
      -- is what gates the prompt tag and the banner.
      local function bash(env, cmd, interactive)
        return run(env, ("bash --norc %s-c '. contrib/lvi-shell.sh; %s'")
                        :format(interactive and "-i " or "", cmd))
      end

      it("lvi-mv moves the file and repoints the buffer with :f", function()
        local d = stub({})
        local dir = tmpdir()
        write(dir .. "/old.txt", "x\n")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = dir .. "/old.txt" }
        local _, ok = bash(env, "lvi-mv " .. dir .. "/new.txt")
        expect(ok).to.be.truthy()
        expect(exists(dir .. "/new.txt")).to.be(true)
        expect(exists(dir .. "/old.txt")).to.be(false)
        -- :f, not :w -- renaming must not decide to save the buffer.
        expect(read(d .. "/log")).to.equal("f -- " .. dir .. "/new.txt\n")
        cleanup(d); cleanup(dir)
      end)

      it("lvi-mv into a directory keeps the basename", function()
        local d = stub({})
        local dir = tmpdir()
        write(dir .. "/doc.txt", "x\n")
        os.execute("mkdir -p '" .. dir .. "/arch'")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = dir .. "/doc.txt" }
        bash(env, "lvi-mv " .. dir .. "/arch")
        expect(exists(dir .. "/arch/doc.txt")).to.be(true)
        expect(read(d .. "/log")).to.equal("f -- " .. dir .. "/arch/doc.txt\n")
        cleanup(d); cleanup(dir)
      end)

      it("lvi-rm deletes the file and always forces the buffer away", function()
        local d = stub({})
        local dir = tmpdir()
        write(dir .. "/gone.txt", "x\n")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = dir .. "/gone.txt" }
        bash(env, "lvi-rm")
        expect(exists(dir .. "/gone.txt")).to.be(false)
        expect(read(d .. "/log")).to.equal("bd!\n")   -- never bare bd
        cleanup(d); cleanup(dir)
      end)

      it("a failed rm sends nothing", function()
        local d = stub({})
        local dir = tmpdir()
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = dir .. "/never-existed" }
        local _, ok = bash(env, "lvi-rm")
        expect(ok).to_not.be.truthy()
        expect(read(d .. "/log")).to.equal("")
        cleanup(d); cleanup(dir)
      end)

      -- Under a shell-out lvi is frozen, so asking it for the path would block
      -- on an editor that is blocked on us. $LVI_FILE is the only source there.
      it("a pathless buffer under a shell-out errors without asking lvi", function()
        local d = stub({ path = "" })
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1", LVI_FILE = "" }
        local out, ok = bash(env, "lvi-mv /tmp/x.txt")
        expect(ok).to_not.be.truthy()
        expect(out:find("no file name", 1, true)).to.exist()
        expect(read(d .. "/log")).to.equal("")
        cleanup(d)
      end)

      it("outside a shell-out the current file comes from :path", function()
        local d = stub({})
        local dir = tmpdir()
        write(dir .. "/live.txt", "x\n")
        write(d .. "/path", dir .. "/live.txt\n")
        write(d .. "/list", "w1\t/sock\t" .. dir .. "/live.txt\n")
        local env = { LVI = STUB, STUB_DIR = d }        -- no LVI_WID: live
        bash(env, "lvi-mv " .. dir .. "/moved.txt")
        expect(exists(dir .. "/moved.txt")).to.be(true)
        expect(read(d .. "/log")).to.equal("path\nf -- " .. dir .. "/moved.txt\n")
        cleanup(d); cleanup(dir)
      end)

      -- sudo itself is stubbed on PATH: what is under test is the pair of
      -- commands queued, and that the password is asked for HERE (sudo -v)
      -- rather than on the editor's screen after the exit.
      it("lvi-sudow primes sudo, then queues the pipe write and a re-read", function()
        local d = stub({})
        local bin = tmpdir()
        write(bin .. "/sudo", "#!/bin/sh\necho \"sudo $*\" >> " .. d .. "/sudo.log\n")
        os.execute("chmod +x '" .. bin .. "/sudo'")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = "/etc/hosts", PATH = bin }
        local _, ok = bash(env, "lvi-sudow")
        expect(ok).to.be.truthy()
        expect(read(d .. "/sudo.log")).to.equal("sudo -v\n")
        -- ONE command: the reload is chained behind the write inside the
        -- editor's shell, so a failed write cannot reach :e! and discard the
        -- unsaved edits it was meant to save.
        expect(read(d .. "/log")).to.equal(
          'w !sudo tee -- "$LVI_FILE" > /dev/null && "${LVI:-lvi}" -w "$LVI_WID" -d -- e! < /dev/null\n')
        cleanup(d); cleanup(bin)
      end)

      it("lvi-sudow sends nothing when sudo is refused", function()
        local d = stub({})
        local bin = tmpdir()
        write(bin .. "/sudo", "#!/bin/sh\nexit 1\n")
        os.execute("chmod +x '" .. bin .. "/sudo'")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = "/etc/hosts", PATH = bin }
        local _, ok = bash(env, "lvi-sudow")
        expect(ok).to_not.be.truthy()
        expect(read(d .. "/log")).to.equal("")
        cleanup(d); cleanup(bin)
      end)

      -- The bug this closes: $LVI_FILE is the path AS OPENED, so `lvi doc.txt`
      -- puts a RELATIVE name in the environment. Resolved against a shell that
      -- has cd'd, that names a different file -- and lvi-rm deleted it.
      it("resolves a relative $LVI_FILE against lvi's cwd, not the shell's", function()
        local d = stub({})
        local dir = tmpdir()
        os.execute("mkdir -p '" .. dir .. "/sub'")
        write(dir .. "/doc.txt", "the editor's file\n")
        write(dir .. "/sub/doc.txt", "an innocent bystander\n")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = "doc.txt", LVI_CWD = dir }
        bash(env, "cd " .. dir .. "/sub && lvi-rm")
        expect(exists(dir .. "/doc.txt")).to.be(false)        -- the right one
        expect(exists(dir .. "/sub/doc.txt")).to.be(true)     -- the bystander
        cleanup(d); cleanup(dir)
      end)

      it("lvi-mv takes its destination from the shell's cwd", function()
        local d = stub({})
        local dir = tmpdir()
        os.execute("mkdir -p '" .. dir .. "/sub'")
        write(dir .. "/doc.txt", "x\n")
        local env = { LVI = STUB, STUB_DIR = d, LVI_WID = "w1",
                      LVI_FILE = "doc.txt", LVI_CWD = dir }
        -- source resolved against lvi's cwd, destination against this shell's
        bash(env, "cd " .. dir .. "/sub && lvi-mv moved.txt")
        expect(exists(dir .. "/sub/moved.txt")).to.be(true)
        expect(read(d .. "/log")).to.equal("f -- " .. dir .. "/sub/moved.txt\n")
        cleanup(d); cleanup(dir)
      end)

      it("captures lvi's cwd at source time, before any cd", function()
        local dir = tmpdir()
        local out = bash({ LVI = STUB, LVI_WID = "w1" },
                         "cd " .. dir .. " && printf %s \"$LVI_CWD\"")
        expect(out).to_not.equal(dir)                        -- not where we cd'd
        expect(out:find("lvi", 1, true)).to.exist()          -- the repo we sourced from
        cleanup(dir)
      end)

      -- Inherited is not the same as right, so the capture is stamped with the
      -- wid it was taken for. A nested SHELL is the same view and must keep the
      -- value; a nested EDITOR -- `lvi other.txt` from a shell-out you had cd'd
      -- in -- has its own cwd and its own wid, and the inherited value would
      -- resolve ITS $LVI_FILE against the outer editor's directory.
      it("keeps an inherited cwd for the same view, re-captures for another", function()
        local dir = tmpdir()
        local read_cwd = function(wid)
          return (bash({ LVI = STUB, LVI_WID = wid, LVI_CWD = "/outer",
                         LVI_CWD_WID = "w1" },
                       "cd " .. dir .. " && printf %s \"$LVI_CWD\""))
        end
        expect(read_cwd("w1")).to.equal("/outer")     -- nested shell: same view
        local other = read_cwd("w2")                  -- nested editor: different view
        expect(other).to_not.equal("/outer")
        expect(other).to_not.equal(dir)               -- source time, before the cd
        cleanup(dir)
      end)

      -- Outside a shell-out there is no LVI_CWD, so a relative path from :path
      -- cannot be resolved. Guessing is what deleted the wrong file, so refuse.
      it("refuses a relative path when lvi's cwd is unknowable", function()
        local d = stub({ path = "doc.txt\n" })
        local env = { LVI = STUB, STUB_DIR = d }             -- no LVI_WID, no LVI_CWD
        local out, ok = bash(env, "lvi-rm")
        expect(ok).to_not.be.truthy()
        expect(out:find("relative path", 1, true)).to.exist()
        expect(read(d .. "/log")).to.equal("path\n")         -- asked, then stopped
        cleanup(d)
      end)

      -- lvi-sudow is exempt: its command leaves "$LVI_FILE" for the editor's
      -- own shell to expand, in the editor's cwd, so relative is already right.
      it("lvi-sudow works with a relative path outside a shell-out", function()
        local d = stub({ path = "doc.txt\n" })
        local bin = tmpdir()
        write(bin .. "/sudo", "#!/bin/sh\nexit 0\n")
        os.execute("chmod +x '" .. bin .. "/sudo'")
        local env = { LVI = STUB, STUB_DIR = d, PATH = bin }   -- no LVI_WID
        local _, ok = bash(env, "lvi-sudow")
        expect(ok).to.be.truthy()
        expect(read(d .. "/log")).to.equal(
          'path\nw !sudo tee -- "$LVI_FILE" > /dev/null && "${LVI:-lvi}" -w "$LVI_WID" -d -- e! < /dev/null\n')
        cleanup(d); cleanup(bin)
      end)

      it("lvi-help lists every command it ships", function()
        local out = bash({ LVI = STUB }, "lvi-help")
        for _, fn in ipairs({ "lvi-e", "lvi-r", "lvi-saveas", "lvi-mv",
                              "lvi-rm", "lvi-sudow", "lvi-help" }) do
          expect(out:find(fn, 1, true)).to.exist()
        end
      end)

      -- The banner is the one thing that says what the prompt tag cannot, so
      -- it fires exactly under a shell-out, and only when not silenced.
      it("the banner fires under a shell-out and LVI_SHELL_BANNER silences it", function()
        local marker = "lvi is stopped"
        local out = bash({ LVI = STUB, LVI_WID = "w1" }, ":", true)
        expect(out:find(marker, 1, true)).to.exist()
        local off = bash({ LVI = STUB, LVI_WID = "w1", LVI_SHELL_BANNER = "" },
                         ":", true)
        expect(off:find(marker, 1, true)).to_not.exist()
        local outside = bash({ LVI = STUB }, ":", true)
        expect(outside:find(marker, 1, true)).to_not.exist()
      end)
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
