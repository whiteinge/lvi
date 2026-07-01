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
local VIEW = { "cx", "cy", "top", "topsub", "leftcol", "marks", "highlights" }

local function fresh(buf)
  return { buf = buf, cx = 1, cy = 1, top = 1, topsub = 0, leftcol = 0,
           marks = {}, highlights = {} }
end

local function save(ed)
  local rec = ed.buffers[ed.bufidx]
  rec.buf = ed.buf
  for _, k in ipairs(VIEW) do rec[k] = ed[k] end
end

local function load(ed, i)
  ed.bufidx = i
  local rec = ed.buffers[i]
  ed.buf = rec.buf
  for _, k in ipairs(VIEW) do ed[k] = rec[k] end
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

-- :e path -- switch to the buffer for `path` if resident, else open it.
function M.open(ed, path)
  save(ed)
  for i, rec in ipairs(ed.buffers) do
    if rec.buf.path == path then load(ed, i); return end
  end
  ed.buffers[#ed.buffers + 1] = fresh(buffer.open(path))
  load(ed, #ed.buffers)
end

-- :e (no arg) -- reload the current buffer from disk, resetting the view.
function M.reload(ed)
  if not ed.buf.path then return false end
  ed.buf = buffer.open(ed.buf.path)
  ed.buffers[ed.bufidx].buf = ed.buf
  ed.cx, ed.cy, ed.top, ed.topsub, ed.leftcol = 1, 1, 1, 0, 0
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
  if #ed.buffers == 1 then
    ed.buffers[1] = fresh(buffer.new(""))
    load(ed, 1)
  elseif idx == ed.bufidx then
    table.remove(ed.buffers, idx)          -- current gone: move to a neighbor
    load(ed, math.min(idx, #ed.buffers))
  else
    table.remove(ed.buffers, idx)          -- other buffer: just fix the index
    if ed.bufidx > idx then ed.bufidx = ed.bufidx - 1 end
  end
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
    out[#out + 1] = ("%d\t%s\t%s"):format(i, flags, rec.buf.path or "[No Name]")
  end
  return table.concat(out, "\n")
end

return M
