--- buffer.lua -- the text buffer: an array of immutable line-strings.
---
--- Representation (see the design notes): the buffer is a 1-based Lua array of
--- lines, each a string WITHOUT its trailing newline. This is chosen because vi
--- is line-oriented -- "give me line N" is O(1) -- and because LuaJIT's
--- immutable, interned strings make the undo log cheap: every mutation goes
--- through splice(), which records an inverse storing only the changed lines
--- (shared, not copied). Undo/redo + grouping live here (see the undo section).
---
--- This module is deliberately a thin, line-oriented INTERFACE so the
--- representation stays swappable (a line-gap array for huge line counts, or a
--- rope for large-file mode) without the rest of the editor noticing -- the
--- same quarantine trick as sys.lua. Intra-line character surgery is the
--- caller's job (get the line, transform the string, set it back); display
--- concerns (wrap, viewport, highlighting) live entirely in the renderer.
---
--- Invariants:
---   * a buffer always has at least one line (an empty file is {""}),
---   * a line never contains a newline (enforced by set/insert),
---   * noeol records whether the source file lacked a final newline, so
---     read/write round-trips byte-for-byte.

local M = {}

local Buffer = {}
Buffer.__index = Buffer

-- Split raw text into a list of lines on '\n'. Every '\n' is a separator; no
-- trailing-newline interpretation here (that is new()'s concern). Useful for
-- turning pasted/yanked multi-line text into lines for insert().
function M.split(text)
  local lines = {}
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then lines[#lines + 1] = text:sub(pos); break end
    lines[#lines + 1] = text:sub(pos, nl - 1)
    pos = nl + 1
  end
  return lines
end

-- Build a buffer from raw text. A single trailing newline is treated as the
-- final line's terminator (noeol=false); its absence sets noeol=true. An empty
-- string is the empty file: one empty line, no final newline.
function M.new(text)
  text = text or ""
  local self = setmetatable({ modified = false, path = nil,
    _undo = { done = {}, undone = {}, group = nil, sink = nil,
              seq = 0, now = 0, saved = 0 } }, Buffer)
  if text == "" then
    self.lines, self.noeol = { "" }, true
    return self
  end
  if text:sub(-1) == "\n" then
    self.noeol = false
    text = text:sub(1, -2)          -- drop the single terminating newline
  else
    self.noeol = true
  end
  self.lines = M.split(text)
  return self
end

-- Open a file into a new buffer. A missing file yields an empty buffer bound to
-- that path (editing a new file), mirroring vi. Read in binary mode so we never
-- let a runtime mangle newlines.
function M.open(path)
  local f = io.open(path, "rb")
  local buf
  if f then
    local text = f:read("*a") or ""
    f:close()
    buf = M.new(text)
  else
    buf = M.new("")
  end
  buf.path = path
  return buf
end

-- ---- queries ----------------------------------------------------------------

function Buffer:nlines() return #self.lines end

-- Line n (1-based), without trailing newline. nil if out of range -- callers
-- bound with nlines().
function Buffer:line(n) return self.lines[n] end

-- A fresh list of lines a..b inclusive (defaults: whole buffer).
function Buffer:get(a, b)
  a = a or 1
  b = b or #self.lines
  assert(a >= 1 and b <= #self.lines and a <= b, "get: range out of bounds")
  local out = {}
  for i = a, b do out[#out + 1] = self.lines[i] end
  return out
end

-- The whole buffer as raw text, honoring noeol (inverse of new()).
function Buffer:text()
  local body = table.concat(self.lines, "\n")
  if not self.noeol then body = body .. "\n" end
  return body
end

-- ---- mutations --------------------------------------------------------------

local function no_newline(s)
  assert(type(s) == "string", "line must be a string")
  assert(not s:find("\n", 1, true), "a line may not contain a newline")
  return s
end

-- ---- undo log ---------------------------------------------------------------
-- Every mutation goes through splice(), which records an inverse splice, so undo
-- is automatic and complete -- no call site can forget. Records are grouped into
-- user-level changes by undo_checkpoint(); undo/redo move a whole group between
-- the done/undone stacks. While applying an undo/redo the resulting inverse is
-- captured into the opposite stack (that is what makes redo work), so recording
-- is redirected to u.sink; a fresh edit instead lands in the open group and
-- invalidates the redo stack. Multi-level, vim-style (POSIX's u is a single-
-- level toggle; that would be a one-line change here if ever wanted).
--
-- `modified` is derived, not sticky: each change group gets a monotonic id;
-- `now` is the id of the current state (top of `done`, or 0 = original), `saved`
-- is `now` at the last write. modified = now ~= saved, so undoing back to the
-- saved state clears the flag and redoing past it sets it again.
local function record(self, inv)
  local u = self._undo
  if u.sink then
    u.sink[#u.sink + 1] = inv
  else
    if not u.group then
      u.seq = u.seq + 1
      u.group = { id = u.seq } -- new user change: fresh id, becomes current state
      u.now = u.seq
      u.undone = {}            -- a new edit invalidates redo
    end
    u.group[#u.group + 1] = inv
  end
end

local function update_modified(self)
  self.modified = self._undo.now ~= self._undo.saved
end

-- The single fundamental mutator: at line `start`, remove `ndel` lines and
-- insert the list `ins`, atomically. Atomicity matters: the >=1-line invariant
-- is applied once, at the end, so undoing a whole-buffer delete round-trips.
function Buffer:splice(start, ndel, ins)
  local lines = self.lines
  local old = {}
  for i = start, start + ndel - 1 do old[#old + 1] = lines[i] end
  local nins = #ins
  if ndel == nins then
    for i = 1, nins do lines[start + i - 1] = ins[i] end -- in-place; O(1) for set()
  else
    local delta = nins - ndel
    local n = #lines
    if delta > 0 then
      for i = n, start + ndel, -1 do lines[i + delta] = lines[i] end
    else
      for i = start + ndel, n do lines[i + delta] = lines[i] end
      for i = n + delta + 1, n do lines[i] = nil end
    end
    for i = 1, nins do lines[start + i - 1] = ins[i] end
  end
  local guard = false
  if #lines == 0 then lines[1] = ""; guard = true end
  -- Inverse: replace the region now holding `ins` with `old`. If the guard
  -- fired, that region is the single guard line at 1.
  record(self, { start = guard and 1 or start, ndel = guard and 1 or nins, ins = old })
  update_modified(self)
end

-- Replace line n.
function Buffer:set(n, s)
  assert(n >= 1 and n <= #self.lines, "set: line out of range")
  self:splice(n, 1, { no_newline(s) })
end

-- Insert the list of lines BEFORE line n (n == nlines()+1 appends).
function Buffer:insert(n, lst)
  assert(n >= 1 and n <= #self.lines + 1, "insert: line out of range")
  if #lst == 0 then return end
  for j = 1, #lst do no_newline(lst[j]) end
  self:splice(n, 0, lst)
end

-- Delete lines a..b inclusive. Emptying the buffer leaves a single empty line.
function Buffer:delete(a, b)
  local n = #self.lines
  a = a or 1; b = b or n
  assert(a >= 1 and b <= n and a <= b, "delete: range out of bounds")
  self:splice(a, b - a + 1, {})
end

-- Close the current change group (start a fresh one). Called at command
-- boundaries so one undo reverts one user-level change.
function Buffer:undo_checkpoint()
  local u = self._undo
  if u.group and #u.group > 0 then u.done[#u.done + 1] = u.group end
  u.group = nil
end

-- Apply a group's inverse splices in reverse; returns the first affected line.
local function apply_group(self, g)
  local firstline
  for i = #g, 1, -1 do
    firstline = g[i].start
    self:splice(g[i].start, g[i].ndel, g[i].ins)
  end
  return firstline
end

-- Undo the last change group; returns the affected line, or nil if none.
function Buffer:undo()
  local u = self._undo
  self:undo_checkpoint()
  local g = table.remove(u.done)
  if not g then return nil end
  u.sink = {}
  local line = apply_group(self, g)
  u.sink.id = g.id                                    -- redo restores state g.id
  u.undone[#u.undone + 1] = u.sink
  u.sink = nil
  u.now = (#u.done > 0) and u.done[#u.done].id or 0   -- back to the prior state
  update_modified(self)
  return line
end

-- Redo the last undone group; returns the affected line, or nil if none.
function Buffer:redo()
  local u = self._undo
  local g = table.remove(u.undone)
  if not g then return nil end
  u.sink = {}
  local line = apply_group(self, g)
  u.sink.id = g.id
  u.done[#u.done + 1] = u.sink
  u.sink = nil
  u.now = g.id
  update_modified(self)
  return line
end

-- ---- persistence ------------------------------------------------------------

-- Write to path (default: the buffer's own path). Clears modified. Returns the
-- number of bytes written.
function Buffer:write(path)
  path = path or self.path
  assert(path, "write: no path")
  local body = self:text()
  local f = assert(io.open(path, "wb"))
  f:write(body)
  f:close()
  self.path = path
  self:undo_checkpoint()                 -- close the open group so the next edit is new
  self._undo.saved = self._undo.now      -- mark this state as saved
  self.modified = false
  return #body
end

return M
