-- Tests for editor.refresh (cursor clamp + scroll). Run: luajit test/editor_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local editor = require("editor")
local normal = require("normal")
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

-- The scroll commands (normal.lua) move the window while keeping the cursor on
-- screen; editor.refresh() must then leave the window PUT (it only re-scrolls
-- when the cursor is off-screen). This guards that interaction, which the pure
-- interpreter tests can't see because they never run refresh().
describe("editor.refresh does not fight a scroll", function()
  local function live_tall(wrap)
    local t = {}
    for i = 1, 100 do t[i] = "line " .. i end
    local ed = { buf = buffer.new(table.concat(t, "\n")), cx = 1, cy = 1,
      top = 1, topsub = 0, leftcol = 0, mode = "normal", rows = 12, cols = 80,
      opts = { wrap = wrap, tabstop = 8 }, inject = {}, pending = {},
      keylog = {}, regs = {}, marks = {}, running = true }
    ed.interp = coroutine.create(function() normal.loop(ed) end)
    assert(coroutine.resume(ed.interp))
    return ed
  end
  local function feed(ed, s)
    for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
    assert(coroutine.resume(ed.interp))
  end

  for _, wrap in ipairs({ false, true }) do
    it(("keeps top after Ctrl-F/Ctrl-D (wrap=%s)"):format(tostring(wrap)), function()
      for _, key in ipairs({ "\6", "\4" }) do          -- Ctrl-F, Ctrl-D
        local ed = live_tall(wrap)
        feed(ed, key)
        local top, topsub, cy = ed.top, ed.topsub, ed.cy
        editor.refresh(ed)
        expect(ed.top).to.equal(top)
        expect(ed.topsub).to.equal(topsub)
        expect(ed.cy).to.equal(cy)
      end
    end)
  end
end)

-- The `change` hook must fire only for KEYBOARD edits, so a hook's own
-- socket-driven edits can't retrigger it and loop.
describe("change-hook attribution and firing", function()
  local function ed_hooked(text)
    local ed = { buf = buffer.new(text), cx = 1, cy = 1, top = 1, topsub = 0,
      leftcol = 0, mode = "normal", cmdline = "", rows = 12, cols = 80,
      opts = { wrap = false, tabstop = 8 }, inject = {}, pending = {},
      keylog = {}, regs = {}, marks = {}, running = true,
      hooks = { change = { "lvi-highlight" } }, change_pending = false }
    ed.interp = coroutine.create(function() normal.loop(ed) end)
    assert(coroutine.resume(ed.interp))              -- prime to first getkey
    local spawned = {}
    ed.spawn_bg = function(cmd) spawned[#spawned + 1] = cmd end
    return ed, spawned
  end

  it("note_keyboard_change arms only when the buffer actually changed", function()
    local ed = ed_hooked("hello")
    local pb, pr = ed.buf, ed.buf.rev
    editor.note_keyboard_change(ed, pb, pr)          -- nothing changed
    expect(ed.change_pending).to_not.be(true)
    ed.buf:set(1, "world")                           -- a mutation bumps rev
    editor.note_keyboard_change(ed, pb, pr)
    expect(ed.change_pending).to.be(true)
  end)

  it("on_idle fires each change hook once, then disarms", function()
    local ed, spawned = ed_hooked("x")
    ed.change_pending = true
    editor.on_idle(ed)
    expect(spawned).to.equal({ "lvi-highlight" })
    expect(ed.change_pending).to.be(false)
    editor.on_idle(ed)                               -- disarmed: no re-fire
    expect(#spawned).to.equal(1)
  end)

  it("M.fire runs each hook for an event, passing the buf override through", function()
    local ed, spawned = ed_hooked("x")
    ed.hooks.bufdelete = { "lvi-list drop" }
    local got_buf
    ed.spawn_bg = function(cmd, buf) spawned[#spawned + 1] = cmd; got_buf = buf end
    editor.fire(ed, "bufdelete", { path = "gone.txt" })
    expect(spawned).to.equal({ "lvi-list drop" })
    expect(got_buf.path).to.equal("gone.txt")           -- buf threaded to spawn_bg -> export_context
    editor.fire(ed, "bufenter")                          -- no hooks registered -> no-op
    expect(#spawned).to.equal(1)
  end)

  it("a socket-sourced edit does NOT arm the hook (no loop)", function()
    local ed, spawned = ed_hooked("hello world")
    editor.handle_socket_command(ed, "normal dw")    -- edit via the socket path
    expect(ed.buf:line(1)).to.equal("world")         -- it really edited
    expect(ed.change_pending).to_not.be(true)        -- but did not arm
    editor.on_idle(ed)
    expect(#spawned).to.equal(0)                      -- so nothing fires
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
