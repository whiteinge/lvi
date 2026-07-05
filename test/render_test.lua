-- Tests for render.lua. Run: luajit test/render_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local render = require("render")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function ed_with(text, over)
  local ed = { buf = buffer.new(text), cx = 1, cy = 1, top = 1, topsub = 0,
               leftcol = 0, mode = "normal", cmdline = "", rows = 5, cols = 12,
               opts = { wrap = false, tabstop = 8 } }
  for k, v in pairs(over or {}) do ed[k] = v end
  return ed
end

describe("render.frame", function()
  it("draws visible lines and ~ past end-of-buffer", function()
    local f = render.frame(ed_with("hello\nworld\n"))  -- 5 rows, 2 lines + ~
    expect(f:find("hello", 1, true)).to.exist()
    expect(f:find("world", 1, true)).to.exist()
    expect(f:find("~", 1, true)).to.exist()
  end)

  it("shows [No Name] in the status line", function()
    expect(render.frame(ed_with("x")):find("[No Name]", 1, true)).to.exist()
  end)

  it("marks a modified buffer with [+]", function()
    local ed = ed_with("x", { cols = 40 }); ed.buf.modified = true
    expect(render.frame(ed):find("%[%+%]")).to.exist()
  end)

  it("shows :status segments in name order in the status line", function()
    local ed = ed_with("x", { cols = 60, status = { zeb = "Z", abc = "A" } })
    local f = render.frame(ed)
    local ia, iz = f:find("A", 1, true), f:find("Z", 1, true)
    expect(ia).to.exist(); expect(iz).to.exist()
    expect(ia < iz).to.be.truthy()                 -- abc's "A" before zeb's "Z"
  end)

  it("truncates long lines to the width (nowrap)", function()
    local f = render.frame(ed_with("0123456789ABCDEF"))  -- cols = 12
    expect(f:find("012345678", 1, true)).to.exist()
    expect(f:find("ABCDEF", 1, true)).to_not.exist()      -- past the width
  end)

  it("renders the command line while typing ':'", function()
    local f = render.frame(ed_with("x", { mode = "command", cmdline = "wq" }))
    expect(f:find(":wq", 1, true)).to.exist()
  end)

  it("wraps a long line across rows when wrap is on", function()
    local f = render.frame(ed_with("abcdefgh", { opts = { wrap = true, tabstop = 8 }, cols = 4 }))
    expect(f:find("abcd", 1, true)).to.exist()
    expect(f:find("efgh", 1, true)).to.exist()
  end)

  it("scrolls horizontally by leftcol when nowrap", function()
    local f = render.frame(ed_with("0123456789", { cols = 4, leftcol = 4 }))
    expect(f:find("4567", 1, true)).to.exist()
    expect(f:find("0123", 1, true)).to_not.exist()
  end)

  it("expands tabs to the tab stop", function()
    local f = render.frame(ed_with("a\tb", { cols = 20, opts = { wrap = false, tabstop = 4 } }))
    expect(f:find("a   b", 1, true)).to.exist()
  end)

  it("draws a reverse-styled overlay group (e.g. search)", function()
    local f = render.frame(ed_with("hello world", { cols = 20,
      highlights = { search = { { line = 1, c1 = 1, c2 = 5 } } },
      hlstyles = { search = "7" } }))                          -- reverse video
    expect(f:find("\27[7mhello\27[0m", 1, true)).to.exist() -- 'hello' reversed
  end)

  it("leaves an un-themed highlight group as plain text", function()
    local f = render.frame(ed_with("hello world",
      { cols = 20, highlights = { search = { { line = 1, c1 = 1, c2 = 5 } } } }))
    expect(f:find("\27[7m", 1, true)).to_not.exist()        -- no reverse fallback
    expect(f:find("hello world", 1, true)).to.exist()
  end)

  it("draws a styled group with its SGR color instead of reverse video", function()
    local f = render.frame(ed_with("hello world", { cols = 20,
      highlights = { kw = { { line = 1, c1 = 1, c2 = 5 } } },
      hlstyles = { kw = "38;5;4;1" } }))          -- blue, bold
    expect(f:find("\27[38;5;4;1mhello\27[0m", 1, true)).to.exist()
  end)

  it("highlights a span offset within the line (tab-aware columns)", function()
    local f = render.frame(ed_with("ab cd ef",
      { cols = 20, highlights = { m = { { line = 1, c1 = 4, c2 = 5 } } },
        hlstyles = { m = "7" } }))
    expect(f:find("\27[7mcd\27[0m", 1, true)).to.exist()
  end)

  it("draws a higher-pri group over a lower-pri one on the same cell", function()
    -- syn (pri 0) and search (pri 10) both cover column 1; search must win.
    local f = render.frame(ed_with("1. item", { cols = 20,
      highlights = { syn = { { line = 1, c1 = 1, c2 = 1 } },
                     search = { { line = 1, c1 = 1, c2 = 1 } } },
      hlstyles = { syn = "38;5;4", search = "7" },
      hlpri = { search = 10 } }))
    expect(f:find("\27[7m1\27[0m", 1, true)).to.exist()      -- '1' reversed (search)
    expect(f:find("\27[38;5;4m1", 1, true)).to_not.exist()   -- not blue (syn lost)
  end)

  it("renders multibyte whole and highlights the right char", function()
    local E = "\195\169"                    -- 'é' at bytes 2-3, display col 1
    local f = render.frame(ed_with("a" .. E .. "b",
      { cols = 20, highlights = { m = { { line = 1, c1 = 2, c2 = 3 } } },
        hlstyles = { m = "7" } }))
    expect(f:find("\27[7m" .. E .. "\27[0m", 1, true)).to.exist()
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
