--- bufs.lua -- the buffer list (multiple resident buffers, Vim "hidden" style).
---
--- Design: the editor keeps using its flat live fields (ed.buf, ed.cx, ed.cy,
--- ed.top, ...) as the view onto the *current* buffer, so normal/ex/render need
--- no changes. Each buffer has a slot holding its buffer object plus the
--- per-buffer VIEW state; switching just saves the live fields into the current
--- slot and loads the target's. The buffer object already carries text / path /
--- modified / undo, so those travel with it -- only the view state is saved here.

local buffer = require("buffer")

local M = {}

-- Per-buffer view state (everything else -- text, path, modified, undo -- lives
-- in the buffer object; the rest of ed is shared across buffers).
local VIEW = { "cx", "cy", "top", "topsub", "leftcol", "marks", "highlights", "folds", "jumps", "changes" }

local function fresh(buf)
  return { buf = buf, cx = 1, cy = 1, top = 1, topsub = 0, leftcol = 0,
           marks = {}, highlights = {}, folds = {}, jumps = { list = {}, idx = 1 },
           changes = { list = {}, idx = 1 } }
end

local function save(ed)
  -- Fire bufleave while the buffer being left is still current, so the hook's
  -- context env vars (LVI_FILE ...) name it. ed.fire_event is injected by the
  -- editor and absent in headless/unit contexts, so guard every call.
  if ed.fire_event then ed.fire_event("bufleave") end
  local rec = ed.buffers[ed.bufidx]
  rec.buf = ed.buf
  for _, k in ipairs(VIEW) do rec[k] = ed[k] end
  ed.altbuf = ed.bufidx     -- the buffer we're leaving becomes the alternate (#)
end

-- Keep ed.altbuf pointing at the same buffer after index `idx` is removed.
local function drop_alt(ed, idx)
  if ed.altbuf == idx then ed.altbuf = nil
  elseif ed.altbuf and ed.altbuf > idx then ed.altbuf = ed.altbuf - 1 end
end

local function load(ed, i)
  ed.bufidx = i
  local rec = ed.buffers[i]
  ed.buf = rec.buf
  -- The current buffer reports its splices so the editor can shift this view's
  -- marks/jumps/changelist (editor.make_splice_hook; absent in headless/unit).
  ed.buf.on_splice = ed.splice_hook
  for _, k in ipairs(VIEW) do ed[k] = rec[k] end
  -- bufenter fires after the entered buffer is current, so the hook (a list
  -- repaint) sees it in LVI_FILE and paints the right buffer's subset.
  if ed.fire_event then ed.fire_event("bufenter") end
end

-- Start the list with one buffer and make it current.
function M.init(ed, buf)
  ed.buffers = { fresh(buf) }
  load(ed, 1)
end

-- Switch to buffer i (saving the current view first). Returns success.
function M.switch(ed, i)
  if i < 1 or i > #ed.buffers or i == ed.bufidx then
    if i == ed.bufidx then return true end
    return false
  end
  save(ed); load(ed, i)
  return true
end

-- Switch to the alternate buffer (#, the last one visited). Returns success.
function M.alt(ed)
  return (ed.altbuf and M.switch(ed, ed.altbuf)) or false
end

-- :e path -- switch to the buffer for `path` if resident, else open it.
function M.open(ed, path)
  for i, rec in ipairs(ed.buffers) do
    if rec.buf.path == path then
      -- Already resident. Current? Then nothing to do -- crucially, no save():
      -- save() repoints the alternate at the buffer being left, and pointing
      -- the alternate at itself would destroy it (:e <current-file> used to
      -- eat Ctrl-^). A real switch saves as usual.
      if i ~= ed.bufidx then save(ed); load(ed, i) end
      return
    end
  end
  save(ed)
  local buf = buffer.open(path)
  if ed.stamp then ed.stamp(buf) end        -- read-stamp for :w conflict checks
  ed.buffers[#ed.buffers + 1] = fresh(buf)
  load(ed, #ed.buffers)
end

-- Open a fresh scratch buffer (no path, never dirty) named `name`, switch to
-- it, and return it. Used for ephemeral, editor-backed UIs like the command
-- window: the buffer IS a real editable buffer, so all of vi drives it.
function M.scratch(ed, name)
  save(ed)
  local buf = buffer.new("")
  buf.scratch = true
  buf.name = name
  ed.buffers[#ed.buffers + 1] = fresh(buf)
  load(ed, #ed.buffers)
  return buf
end

-- Index of the slot holding buffer object `buf`, or nil. Lets a caller that
-- captured a buffer (not an index) switch/close it after the list has shifted.
function M.index_of(ed, buf)
  for i, rec in ipairs(ed.buffers) do
    if rec.buf == buf then return i end
  end
end

-- :e (no arg) -- reload the current buffer from disk, resetting the view.
function M.reload(ed)
  if not ed.buf.path then return false end
  ed.buf = buffer.open(ed.buf.path)
  if ed.stamp then ed.stamp(ed.buf) end     -- fresh read: reset the conflict stamp
  ed.buf.on_splice = ed.splice_hook         -- new object: re-attach the position hook
  ed.buffers[ed.bufidx].buf = ed.buf
  ed.cx, ed.cy, ed.top, ed.topsub, ed.leftcol = 1, 1, 1, 0, 0
  ed.folds = {}                             -- transient view state; the reloaded
                                            -- text may not match the old ranges
  return true
end

-- Close a buffer (default: current). Refuses a modified buffer unless force.
-- Closing the last buffer leaves a fresh empty [No Name]. Returns ok, err.
function M.close(ed, force, idx)
  idx = idx or ed.bufidx
  if idx < 1 or idx > #ed.buffers then return false, "no such buffer: " .. tostring(idx) end
  if ed.buffers[idx].buf.modified and not force then
    return false, "No write since last change (add ! to override)"
  end
  -- bufdelete fires before the buffer goes, carrying its path (not the current
  -- one's -- :bd N deletes a buffer that may not be current) so a hook can drop
  -- the list tied to that file.
  if ed.fire_event then ed.fire_event("bufdelete", ed.buffers[idx].buf) end
  if #ed.buffers == 1 then
    ed.buffers[1] = fresh(buffer.new(""))
    load(ed, 1)
    ed.altbuf = nil
  elseif idx == ed.bufidx then
    table.remove(ed.buffers, idx)          -- current gone: move to a neighbor
    drop_alt(ed, idx)
    load(ed, math.min(idx, #ed.buffers))
  else
    table.remove(ed.buffers, idx)          -- other buffer: just fix the index
    if ed.bufidx > idx then ed.bufidx = ed.bufidx - 1 end
    drop_alt(ed, idx)
  end
  if ed.altbuf == ed.bufidx then ed.altbuf = nil end
  return true
end

function M.next(ed) M.switch(ed, ed.bufidx % #ed.buffers + 1) end
function M.prev(ed) M.switch(ed, (ed.bufidx - 2) % #ed.buffers + 1) end

-- Index of the first buffer whose path contains `substr` (for :b <name>).
function M.find(ed, substr)
  for i, rec in ipairs(ed.buffers) do
    if rec.buf.path and rec.buf.path:find(substr, 1, true) then return i end
  end
end

-- Machine-parseable listing: index<TAB>flags<TAB>path (flags: % current, + modified).
function M.list(ed)
  local out = {}
  for i, rec in ipairs(ed.buffers) do
    local flags = ((i == ed.bufidx) and "%" or " ") .. (rec.buf.modified and "+" or " ")
    out[#out + 1] = ("%d\t%s\t%s"):format(i, flags, rec.buf.path or rec.buf.name or "[No Name]")
  end
  return table.concat(out, "\n")
end

return M
