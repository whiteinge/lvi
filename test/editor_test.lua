-- Tests for editor.refresh (cursor clamp + scroll). Run: luajit test/editor_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local editor = require("editor")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function ed_with(text, over)
  local ed = { buf = buffer.new(text), cx = 1, cy = 1, top = 1, topsub = 0,
    leftcol = 0, mode = "normal", rows = 3, cols = 4,
    opts = { wrap = false, tabstop = 8 } }
  for k, v in pairs(over or {}) do ed[k] = v end
  return ed
end

describe("editor.refresh scrolling", function()
  describe("nowrap", function()
    it("scrolls vertically to keep the cursor on screen", function()
      local ed = ed_with("1\n2\n3\n4\n5\n6\n7\n8", { cy = 5 })  -- textrows = 2
      editor.refresh(ed)
      expect(ed.top).to.equal(4)                                -- cy on last row
    end)
    it("scrolls horizontally by display column", function()
      local ed = ed_with("0123456789", { cx = 8, cols = 4 })    -- dispcol 7
      editor.refresh(ed)
      expect(ed.leftcol).to.equal(4)                            -- 7 - 4 + 1
    end)
  end)

  describe("wrap", function()
    it("scrolls whole short lines", function()
      local ed = ed_with("a\nb\nc\nd\ne", { opts = { wrap = true, tabstop = 8 }, cy = 5 })
      editor.refresh(ed)
      expect(ed.top).to.equal(4); expect(ed.topsub).to.equal(0)
    end)
    it("scrolls within a single line taller than the screen (sub-row)", function()
      -- 12 chars at width 4 = 3 sub-rows; screen shows 1 text row.
      local ed = ed_with("abcdefghijkl", { opts = { wrap = true, tabstop = 8 },
        cx = 12, rows = 2, cols = 4 })
      editor.refresh(ed)
      expect(ed.top).to.equal(1); expect(ed.topsub).to.equal(2) -- cursor's sub-row
    end)
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
