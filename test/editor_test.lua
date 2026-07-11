-- Tests for editor.refresh (cursor clamp + scroll). Run: luajit test/editor_test.lua
package.path = "vendor/lust/?.lua;./?.lua;" .. package.path

local lust   = require("lust")
local buffer = require("buffer")
local editor = require("editor")
local normal = require("normal")
local describe, it, expect = lust.describe, lust.it, lust.expect

local function ed_with(text, over)
  local ed = editor.new_ed()
  ed.buf = buffer.new(text)
  ed.rows, ed.cols = 3, 4
  ed.opts.wrap = false
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

    -- Bugs 4/5: an insert-mode cursor past EOL on an exactly-full row lands on
    -- the phantom edge-wrap row (disp.locate returns csub == segment count). The
    -- visibility walk must count that row, or it wrongly decides the on-screen
    -- cursor is off-screen and slams its line to the bottom (mid) / scrolls
    -- prematurely (bottom). rows=12 -> textrows=11, wrap width = 10.
    local function forty_lines_one_full(fullidx)
      local t = {}
      for i = 1, 40 do t[i] = (i == fullidx) and ("x"):rep(10) or "s" end
      local ed = editor.new_ed()
      ed.buf = buffer.new(table.concat(t, "\n"))
      ed.rows, ed.cols = 12, 10
      ed.opts.wrap = true
      ed.mode = "insert"                       -- so cx may sit at #line+1 (past EOL)
      return ed
    end
    it("keeps a mid-viewport line put on a phantom edge-wrap (bug 5)", function()
      local ed = forty_lines_one_full(25)
      ed.cy, ed.cx, ed.top, ed.topsub = 25, 11, 20, 0   -- line 25 at row 5, cursor past EOL
      editor.refresh(ed)
      expect(ed.top).to.equal(20)                       -- did NOT jump the line to the bottom
      expect(ed.topsub).to.equal(0)
    end)
    it("scrolls at most one row for a phantom edge-wrap on the last row (bug 4)", function()
      local ed = forty_lines_one_full(11)
      ed.cy, ed.cx, ed.top, ed.topsub = 11, 11, 1, 0    -- line 11 on the last text row
      editor.refresh(ed)
      expect(ed.top).to.equal(2)                        -- one gentle row, not a leap
      expect(ed.topsub).to.equal(0)
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
    local ed = editor.new_ed()
    ed.buf = buffer.new(table.concat(t, "\n"))
    ed.rows = 12
    ed.opts.wrap = wrap
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
    local ed = editor.new_ed()
    ed.buf = buffer.new(text)
    ed.rows = 12
    ed.opts.wrap = false
    ed.hooks.change = { "lvi-highlight" }
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

describe("socket-key boundary discipline", function()
  local function ed_live(text)
    local ed = editor.new_ed()
    ed.buf = buffer.new(text)
    ed.rows = 12
    ed.opts.wrap = false
    ed.interp = coroutine.create(function() normal.loop(ed) end)
    assert(coroutine.resume(ed.interp))
    return ed
  end
  local function keys(ed, s)
    for i = 1, #s do ed.inject[#ed.inject + 1] = s:byte(i) end
    assert(coroutine.resume(ed.interp))
  end

  it("defers socket keys that arrive while a command is half-typed", function()
    local ed = ed_live("aaa bbb\nccc")
    expect(ed.at_boundary).to.be(true)               -- parked between commands
    keys(ed, "d")                                    -- half a command: awaiting a motion
    expect(ed.at_boundary).to.be(false)
    editor.handle_socket_command(ed, "normal j")     -- a hook fires mid-command
    expect(ed.buf:line(1)).to.equal("aaa bbb")       -- j was NOT consumed as d's motion
    expect(#ed.inject_deferred).to.equal(1)
    keys(ed, "w")                                    -- the user completes dw
    expect(ed.buf:line(1)).to.equal("bbb")
    editor.flush_deferred(ed)                        -- driver replays the deferred j
    expect(ed.cy).to.equal(2)
  end)

  it("a socket command mid-insert does not split the undo group", function()
    local ed = ed_live("x")
    keys(ed, "iab")                                  -- typing, still in insert mode
    editor.handle_socket_command(ed, "echo hi")      -- must not checkpoint here
    keys(ed, "c\27")                                 -- finish the insert
    expect(ed.buf:line(1)).to.equal("abcx")
    ed.buf:undo()
    expect(ed.buf:line(1)).to.equal("x")             -- one insert == one undo unit
  end)

  it("pumps immediately when parked between commands (unchanged fast path)", function()
    local ed = ed_live("one\ntwo")
    editor.handle_socket_command(ed, "normal j")
    expect(ed.cy).to.equal(2)                        -- ran at once, nothing deferred
    expect(ed.inject_deferred).to_not.exist()
  end)

  it("aborts a self-referencing macro instead of hanging forever", function()
    local ed = ed_live("hello")
    ed.regs.a = { text = "@a", linewise = false }    -- @a replays itself
    editor.handle_socket_command(ed, "normal @a")    -- would never return unbudgeted
    expect(ed.message).to.equal("runaway key replay aborted (recursive macro?)")
    expect(#ed.inject).to.equal(0)                   -- queues cleared
    editor.handle_socket_command(ed, "normal x")     -- and the editor still works
    expect(ed.buf:line(1)).to.equal("ello")
  end)
end)

describe("mark/jumplist adjustment across edits (make_splice_hook)", function()
  local function ed_marked(text)
    local ed = editor.new_ed()
    ed.buf = buffer.new(text)
    ed.marks = { a = { 5, 2 }, b = { 2, 1 } }
    ed.jumps = { list = { { 4, 1 } }, idx = 2 }
    ed.splice_hook = editor.make_splice_hook(ed)
    ed.buf.on_splice = ed.splice_hook
    return ed
  end

  it("shifts marks and jumps below a deletion, leaves those above alone", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    ed.buf:delete(3, 3)                        -- one line gone above mark a
    expect(ed.marks.a).to.equal({ 4, 2 })      -- slid up
    expect(ed.marks.b).to.equal({ 2, 1 })      -- above the edit: untouched
    expect(ed.jumps.list[1]).to.equal({ 3, 1 })
  end)

  it("shifts marks below an insertion", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    ed.buf:insert(2, { "x", "y" })
    expect(ed.marks.a).to.equal({ 7, 2 })
    expect(ed.marks.b).to.equal({ 4, 1 })      -- at the insert point: pushed down
  end)

  it("clamps a mark inside the replaced region to its start", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    ed.buf:splice(4, 3, { "only" })            -- lines 4-6 -> one line
    expect(ed.marks.a).to.equal({ 4, 2 })      -- was line 5, inside the region
  end)

  it("in-place single-line set (typing) moves nothing", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    ed.buf:set(5, "edited")
    expect(ed.marks.a).to.equal({ 5, 2 })
  end)

  it("undo replays the inverse splice and un-adjusts", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    ed.buf:undo_checkpoint()
    ed.buf:delete(1, 2)
    expect(ed.marks.a).to.equal({ 3, 2 })
    ed.buf:undo()
    expect(ed.marks.a).to.equal({ 5, 2 })      -- restored with the lines
  end)

  it("ignores splices on a non-current buffer (stale hook)", function()
    local ed = ed_marked("1\n2\n3\n4\n5\n6")
    local old = ed.buf
    ed.buf = buffer.new("other")               -- switched away; hook still on old
    old:delete(1, 1)
    expect(ed.marks.a).to.equal({ 5, 2 })      -- current view's marks untouched
  end)
end)

describe("framed requests (%hello / %cmd)", function()
  local sys, proto, vpath = require("sys"), require("proto"), require("path")

  -- A real fd pair via a throwaway listening socket, so feed_conn's responses
  -- travel an actual wire and are parsed by the real client-side reader.
  local function harness(text)
    local ed = editor.new_ed()
    ed.buf = buffer.new(text)
    ed.interp = coroutine.create(function() normal.loop(ed) end)
    assert(coroutine.resume(ed.interp))
    local sp = vpath.tmp()
    local lfd = sys.listen(sp)
    local cfd = sys.connect(sp)
    local afd = sys.accept(lfd)
    local c = editor.new_conn(afd)
    local reader = proto.reader(function() return sys.read(cfd) end)
    local function close()
      sys.close(cfd); sys.close(afd); sys.close(lfd); sys.unlink(sp)
    end
    return ed, c, reader, close
  end

  it("bare lines keep working with no handshake", function()
    local ed, c, reader, close = harness("one\ntwo")
    editor.feed_conn(ed, c, "pos\n")
    local payload, status = reader:response()
    expect(status).to.equal("ok")
    expect(payload).to.equal("1\t1")
    close()
  end)

  it("handshake greets back and %cmd carries newlines", function()
    local ed, c, reader, close = harness("x")
    editor.feed_conn(ed, c, proto.HELLO)
    expect((reader:response())).to.equal("lvi 1")
    local cmd = "normal ihello\nworld\27"           -- multi-line insert
    editor.feed_conn(ed, c, proto.request(cmd))
    local _, status = reader:response()
    expect(status).to.equal("ok")
    expect(ed.buf:get()).to.equal({ "hello", "worldx" })
    close()
  end)

  it("a framed body split across reads reassembles", function()
    local ed, c, reader, close = harness("abc")
    editor.feed_conn(ed, c, proto.HELLO)
    reader:response()
    local req = proto.request("normal x")
    editor.feed_conn(ed, c, req:sub(1, 10))         -- header + partial body
    editor.feed_conn(ed, c, req:sub(11))
    local _, status = reader:response()
    expect(status).to.equal("ok")
    expect(ed.buf:line(1)).to.equal("bc")
    close()
  end)

  it("without the handshake, '%cmd 5' stays an ordinary ex line", function()
    local ed, c, reader, close = harness("x")
    editor.feed_conn(ed, c, "%cmd 5\n")             -- legal ex range command today
    local _, status = reader:response()             -- safe no-op via do_ex
    expect(status).to.equal("ok")
    expect(c.need).to_not.exist()                   -- did NOT switch to body mode
    close()
  end)
end)

describe("editor.preserve (crash salvage)", function()
  it("dumps each modified buffer beside its file", function()
    local tmp = os.tmpname()
    local buf = buffer.new("hello\n"); buf.path = tmp
    buf:set(1, "edited")                        -- modified, unsaved
    local clean = buffer.new("x\n"); clean.path = tmp .. ".other"
    local ed = { buffers = { { buf = buf }, { buf = clean } }, buf = buf }
    local notes = editor.preserve(ed)
    expect(#notes).to.equal(1)                  -- clean buffer skipped
    local f = io.open(tmp .. ".lvi-recover", "rb")
    expect(f).to.exist()
    expect(f:read("*a")).to.equal("edited\n")
    f:close()
    os.remove(tmp); os.remove(tmp .. ".lvi-recover")
  end)

  it("parks a nameless modified buffer beside the socket path", function()
    local tmp = os.tmpname()
    local buf = buffer.new("")
    buf:set(1, "scratch work")                  -- modified, no path
    local ed = { buf = buf, sock_path = tmp }   -- no ed.buffers: lone-buf fallback
    local notes = editor.preserve(ed)
    expect(#notes).to.equal(1)
    local f = io.open(tmp .. ".recover.1", "rb")
    expect(f).to.exist()
    expect(f:read("*a")).to.equal("scratch work")
    f:close()
    os.remove(tmp); os.remove(tmp .. ".recover.1")
  end)
end)

os.exit(lust.errors == 0 and 0 or 1)
