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
end)

os.exit(lust.errors == 0 and 0 or 1)
