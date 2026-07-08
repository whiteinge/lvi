--- editor.lua -- the driver: view state + the poll loop that drives rendering,
--- the normal-mode coroutine interpreter, and the control socket.
---
--- Keyboard bytes are appended to ed.inject and the interpreter coroutine
--- (normal.lua) is resumed to consume them; it parks (yields) between keys via
--- getkey, so the poll loop is free to service the socket while a multi-key
--- command is half-typed. The ':' prompt and socket both still run ex.dispatch,
--- so a command behaves identically on every surface.

local sys    = require("sys")
local path   = require("path")
local proto  = require("proto")
local buffer = require("buffer")
local render = require("render")
local term   = require("term")
local ex     = require("ex")
local normal = require("normal")
local disp   = require("disp")
local bufs   = require("bufs")
local config = require("config")

local M = {}

-- Resume the interpreter coroutine so it consumes whatever is queued in
-- ed.inject (keyboard bytes, or keys pushed by ':normal'/'.'). It parks again
-- when the queue drains or a command needs more input.
local function pump(ed)
  local ok, err = coroutine.resume(ed.interp)
  if not ok then error("interpreter: " .. tostring(err)) end
end

-- ---- connection state -------------------------------------------------------
local function new_conn(fd) return { fd = fd, inbuf = "", next_id = 1 } end

-- Process one socket command line: dispatch it and drive any ':normal' keys it
-- queued (so a following command in the same batch sees the result). Split out
-- so the poll loop and tests share it. It deliberately does NOT touch
-- ed.change_pending: socket-sourced edits must never schedule a `change` hook,
-- or a hook's own edits (which come back over the socket) would retrigger it and
-- loop. Only keyboard input schedules a fire, via note_keyboard_change.
--
-- Boundary discipline: the interpreter is only safe to feed when it is parked
-- BETWEEN commands (ed.at_boundary, set by normal.lua; nil in headless tests ==
-- safe). Parked mid-command -- the user has typed `d` and a hook fires -- keys
-- pumped now would be consumed as that d's motion; parked in insert they would
-- land as text. So mid-command we (a) skip the undo checkpoint (closing the
-- open group would split the user's insert into two undo units) and (b) defer
-- injected keys to ed.inject_deferred, which flush_deferred replays the moment
-- the interpreter is back between commands.
local function handle_socket_command(ed, line)
  local safe = ed.at_boundary ~= false
  if safe then ed.buf:undo_checkpoint() end -- each socket command is its own undo unit
  local payload, status = ex.dispatch(ed, line)
  if #ed.inject > 0 then
    if safe then
      pump(ed)
    else
      ed.inject_deferred = ed.inject_deferred or {}
      for i = 1, #ed.inject do ed.inject_deferred[#ed.inject_deferred + 1] = ed.inject[i] end
      ed.inject = {}
    end
  end
  return payload, status
end
M.handle_socket_command = handle_socket_command

-- Replay keys that arrived over the socket while the interpreter was parked
-- mid-command, now that it is back at a boundary. Called by the poll loop after
-- keyboard input (the only thing that can complete the pending command).
local function flush_deferred(ed)
  if ed.at_boundary ~= false and ed.inject_deferred and #ed.inject_deferred > 0 then
    for i = 1, #ed.inject_deferred do ed.inject[#ed.inject + 1] = ed.inject_deferred[i] end
    ed.inject_deferred = nil
    pump(ed)
  end
end
M.flush_deferred = flush_deferred

local function feed_conn(ed, c, data)
  c.inbuf = c.inbuf .. data
  while true do
    local line, rest = c.inbuf:match("^(.-)\n(.*)$")
    if not line then break end
    c.inbuf = rest
    local id = c.next_id
    c.next_id = id + 1
    local payload, status = handle_socket_command(ed, line)
    proto.send_response(c.fd, id, payload, status)
  end
end

-- ---- change hooks (`:on change`) --------------------------------------------
local IDLE_MS = 150 -- debounce: fire change hooks this long after the last key

-- Called after a KEYBOARD pump: if it changed the buffer (a mutation bumps
-- buf.rev; :e/:bn swaps the buffer object), arm the `change` hooks. Attributing
-- to the keyboard is what keeps a hook's socket-driven edits from looping.
-- Also stamp the `.` mark (last-change position, vi's `` `. ``) so `` `. `` / `'.`
-- jump back to where you last typed -- but only on a same-buffer rev bump (a real
-- edit), not on the object swap of a buffer switch. This is the ONLY safe place
-- to set it: an `on change` hook can fire mid-insert (you paused typing), where
-- an injected `m.` would land as literal text; here it runs in the driver,
-- mode-agnostic. Marks are per-buffer (bufs swaps ed.marks), so it lands in the
-- edited buffer's set.
function M.note_keyboard_change(ed, prev_buf, prev_rev)
  if ed.buf ~= prev_buf or ed.buf.rev ~= prev_rev then
    ed.change_pending = true
    if ed.buf == prev_buf then
      ed.marks = ed.marks or {}
      ed.marks["."] = { ed.cy, ed.cx }
    end
  end
end

-- Fire every hook registered for an event, each detached. `buf` (optional)
-- overrides the buffer reported in the context env vars (for bufdelete). The
-- generic firer behind both the idle `change` hook and the buffer events; bufs
-- calls it through the injected ed.fire_event so it needn't require editor.
function M.fire(ed, event, buf)
  local hooks = ed.hooks and ed.hooks[event]
  if not hooks then return end
  for _, cmd in ipairs(hooks) do ed.spawn_bg(cmd, buf) end
end

-- Called when the poll loop goes idle: run each registered `change` hook once,
-- detached, then disarm until the next keyboard change.
function M.on_idle(ed)
  local hooks = ed.change_pending and ed.hooks and ed.hooks.change
  if not hooks or #hooks == 0 then return end
  ed.change_pending = false
  M.fire(ed, "change")
end

-- ---- crash salvage ------------------------------------------------------------
-- Last-ditch preserve: a Lua error anywhere -- a motion, a command handler, the
-- driver itself -- unwinds to run()'s pcall with the session unrecoverable (a
-- dead coroutine cannot be resumed). Losing the session must not lose the work,
-- so every modified buffer is dumped: next to its file as PATH.lvi-recover, or
-- beside the socket for a nameless buffer. Bytes are written directly (not via
-- buf:write, which would repoint path/modified -- the report should name the
-- real files). Returns one human-readable line per buffer for stderr, printed
-- by run() after the terminal is restored.
function M.preserve(ed)
  local notes = {}
  for i, rec in ipairs(ed.buffers or { { buf = ed.buf } }) do
    local buf = rec.buf
    if buf and buf.modified then
      local target = buf.path and (buf.path .. ".lvi-recover")
                     or ((ed.sock_path or "lvi") .. ".recover." .. i)
      local ok = pcall(function()
        local f = assert(io.open(target, "wb"))
        f:write(buf:text())
        f:close()
      end)
      notes[#notes + 1] = ok
        and ("lvi: modified buffer preserved in " .. target)
        or  ("lvi: FAILED to preserve " .. (buf.path or "[No Name]"))
    end
  end
  return notes
end

-- ---- cursor / scroll invariants ---------------------------------------------
-- Runs after any mutation or motion (keyboard OR socket). The interpreter also
-- clamps the cursor itself; this additionally handles the socket path and does
-- the vertical scroll to keep the cursor on screen.
local function refresh(ed)
  local nl = ed.buf:nlines()
  ed.cy = math.max(1, math.min(ed.cy, nl))
  local curline = ed.buf:line(ed.cy) or ""
  local maxc = (ed.mode == "insert") and (#curline + 1) or disp.last_char(curline)
  ed.cx = math.max(1, math.min(ed.cx, maxc))

  local textrows = ed.rows - 1
  local W = ed.cols
  local ts = (ed.opts and ed.opts.tabstop) or 8

  if ed.opts and ed.opts.wrap then
    ed.leftcol = 0
    ed.topsub = ed.topsub or 0
    local csub = select(1, disp.locate(curline, W, ts, ed.cx))
    if ed.cy < ed.top or (ed.cy == ed.top and csub < ed.topsub) then
      ed.top, ed.topsub = ed.cy, csub                 -- cursor above top: scroll up
    else
      -- Is the cursor in view? Walk forward from the top, bounded by textrows.
      local l, sub, count, visible = ed.top, ed.topsub, 0, false
      while count < textrows do
        if l == ed.cy and sub == csub then visible = true; break end
        if l > nl then break end
        local ns = disp.nsegs(ed.buf:line(l) or "", W, ts)
        if sub + 1 < ns then sub = sub + 1 else l, sub = l + 1, 0 end
        count = count + 1
      end
      if not visible then
        -- Put the cursor on the last visible row: walk back textrows-1 rows.
        local l2, sub2 = ed.cy, csub
        for _ = 1, textrows - 1 do
          if sub2 > 0 then sub2 = sub2 - 1
          elseif l2 > 1 then l2 = l2 - 1; sub2 = disp.nsegs(ed.buf:line(l2) or "", W, ts) - 1
          else break end
        end
        ed.top, ed.topsub = l2, sub2
      end
    end
    local ns = disp.nsegs(ed.buf:line(ed.top) or "", W, ts)
    if ed.topsub >= ns then ed.topsub = ns - 1 end
    if ed.topsub < 0 then ed.topsub = 0 end
    if ed.top < 1 then ed.top = 1 end
  else
    ed.topsub = 0
    if ed.cy < ed.top then ed.top = ed.cy end
    if ed.cy > ed.top + textrows - 1 then ed.top = ed.cy - textrows + 1 end
    if ed.top < 1 then ed.top = 1 end
    local dc = disp.dispcol(curline, ts, ed.cx)
    ed.leftcol = ed.leftcol or 0
    if dc < ed.leftcol then ed.leftcol = dc end
    if dc > ed.leftcol + W - 1 then ed.leftcol = dc - W + 1 end
    if ed.leftcol < 0 then ed.leftcol = 0 end
  end
end
M.refresh = refresh -- exposed for tests

-- ---- main loop --------------------------------------------------------------
function M.run(opts)
  opts = opts or {}
  local ed = {
    running = true,
    mode = "normal", cmdline = "", message = nil,
    inject = {}, pending = {}, keylog = {}, regs = {},
    opts = { wrap = true, tabstop = 8, shiftwidth = 8, expandtab = false },
    hooks = {}, change_pending = true, -- seed one fire so an opened file highlights
  }
  -- Refresh the per-spawn context env vars, so a child (a `:!` command, a hook)
  -- reads the cursor's world straight from its environment -- no expansion
  -- mini-language in the editor, just values a POSIX shell can slice
  -- (`${LVI_FILE##*/}` etc.). LVI_WID/LVI_SOCK are set once (static per view);
  -- these change with the cursor, so they're stamped right before each spawn.
  -- `buf` overrides the buffer whose path is reported (line/col/cword only make
  -- sense for the current buffer, so they blank out for an override -- used by
  -- the bufdelete hook, which fires about a buffer that is NOT current).
  ed.export_context = function(buf)
    buf = buf or ed.buf
    sys.setenv("LVI_FILE", buf.path or "")
    sys.setenv("LVI_LINE", ed.cy)
    sys.setenv("LVI_COL", ed.cx)
    sys.setenv("LVI_TOP", ed.top or 1)          -- viewport top line, for `on scroll`
    sys.setenv("LVI_CWORD", (buf == ed.buf) and normal.cword(ed) or "")
  end
  -- Spawn a shell command detached and non-blocking, with its output discarded
  -- (a hook must not write to the tty or block the poll loop). Used to fire
  -- event hooks; the subshell backgrounds so os.execute returns at once.
  ed.spawn_bg = function(cmd, buf) ed.export_context(buf); os.execute("(" .. cmd .. ") >/dev/null 2>&1 &") end
  -- Per-buffer view state (buf, cx/cy, top/topsub, leftcol, marks, highlights)
  -- is set up here and swapped by bufs on :e / buffer switch. Positional files
  -- open as buffers; the first is current.
  local files = opts.files or (opts.filename and { opts.filename }) or {}
  bufs.init(ed, files[1] and buffer.open(files[1]) or buffer.new(""))
  for i = 2, #files do bufs.open(ed, files[i]) end
  if #ed.buffers > 1 then bufs.switch(ed, 1) end
  sys.ignore_sigpipe() -- a disconnected client (e.g. --detach) must not kill us
  ed.wid = opts.wid or tostring(sys.getpid())
  ed.sock_path = path.socket(ed.wid)
  local lfd = sys.listen(ed.sock_path)
  -- A per-view scratch path (beside the socket, in the same private dir) where
  -- `:wbuf` snapshots the live buffer for a `:silent !` tool to read -- the one
  -- way to hand the *unsaved* buffer to a child that needs the tty, since the
  -- tty verbs freeze the poll loop and a `%p` read would deadlock. Reaped on
  -- exit like the socket.
  ed.buffer_scratch = ed.sock_path .. ".buf"
  -- File-conflict stamps. Each file-backed buffer gets a stamp file beside the
  -- socket whose mtime mirrors the file's as of our last read/write (touch -r,
  -- so clock skew can't lie). ex's :w asks file_changed -- `[ file -nt stamp ]`
  -- -- to catch another writer having touched the file since, and refuses
  -- without `!`. Policy lives here; the two shell-outs live in sys. Buffers are
  -- re-stamped by bufs on open/reload and by ex after each write. The initial
  -- buffers (built above, before sock_path existed) are stamped below.
  local stamp_n = 0
  ed.stamp = function(buf)
    if not buf.path then return end
    if not buf._stamp then
      stamp_n = stamp_n + 1
      buf._stamp = ed.sock_path .. ".stamp." .. stamp_n
    end
    sys.stamp(buf._stamp, buf.path)
  end
  ed.file_changed = function(buf)
    return (buf.path and buf._stamp and sys.newer(buf.path, buf._stamp)) or false
  end
  for _, rec in ipairs(ed.buffers) do ed.stamp(rec.buf) end
  -- Export the view id/socket so external programs (`:!`, pickers) can drive
  -- this view back over the socket (`lvi -w "$LVI_WID" -- ...`); LVI_BUFFER is
  -- the scratch path above.
  sys.setenv("LVI_WID", ed.wid)
  sys.setenv("LVI_SOCK", ed.sock_path)
  sys.setenv("LVI_BUFFER", ed.buffer_scratch)
  -- `lvi -q FILE` parks the errorfile path here for a `ready` hook to consume
  -- (e.g. `on ready ... lvi-list load "$LVI_QUICKFIX" ...` in the rc). The core
  -- stays list-agnostic -- this is just one more value in the child environment,
  -- like LVI_FILE; the rc owns what to do with it.
  if opts.quickfix then sys.setenv("LVI_QUICKFIX", opts.quickfix) end

  -- The interpreter coroutine. Prime it to the first getkey() yield.
  ed.interp = coroutine.create(function() normal.loop(ed) end)
  local ok0, e0 = coroutine.resume(ed.interp)
  if not ok0 then error("interpreter init: " .. tostring(e0)) end

  -- Feed live keyboard bytes into the funnel and let the coroutine drain them.
  local function feed(data)
    for i = 1, #data do ed.inject[#ed.inject + 1] = data:byte(i) end
    pump(ed)
  end

  local tty = sys.isatty(0)

  -- Load the rc file: a file of ex commands, run once through the shared
  -- dispatcher (the payoff of "ex is the config language"). Done here -- ed is
  -- fully built, but before the first paint -- so `:set`/`:map`/... take effect
  -- immediately. (ed.shell isn't wired yet, so an interactive `:!` in the rc
  -- would run headless; the rc is not the place for interactive shell-outs.)
  do
    local rc, errs = config.load(ed)
    if #ed.inject > 0 then pump(ed) end          -- config may queue :normal keys
    if #errs > 0 then
      local last = errs[#errs]
      local msg = ("%s: %d error%s (line %d: %s)"):format(
        rc, #errs, #errs > 1 and "s" or "", last.lnum, last.err)
      if tty then ed.message = msg else io.stderr:write("lvi: " .. msg .. "\n") end
    end
  end

  -- Now that ed is fully built and the rc has registered any hooks, arm buffer
  -- events. Doing it here keeps startup buffer construction (and rc-time :e)
  -- silent; from now on every switch fires bufleave/bufenter through bufs. One
  -- initial bufenter lets lists paint the starting buffer.
  ed.fire_event = function(event, buf) M.fire(ed, event, buf) end
  ed.fire_event("bufenter")
  -- One-shot startup event: the view is fully live (socket up, rc loaded). Fired
  -- once here, before the poll loop, like the initial bufenter above -- a hook's
  -- socket callbacks queue and are serviced the instant the loop starts.
  ed.fire_event("ready")

  local saved
  if tty then
    ed.rows, ed.cols = sys.winsize(1)
    if not ed.rows or ed.rows == 0 then ed.rows, ed.cols = 24, 80 end
    saved = sys.raw_mode()
    sys.write(1, term.alt_on)
    -- Show multi-line command output on a cleared page WITHIN the alt screen, so
    -- the normal terminal is never touched (clean exit) and each invocation
    -- shows only the current output. Wait for a key; the main loop repaints
    -- after. (Long output that truly needs scrolling can defer to $PAGER later.)
    ed.suspend = function(text)
      local lines = {}
      for ln in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = ln end
      local rows, cols, ts = ed.rows, ed.cols, ed.opts.tabstop
      local out = { term.clear, term.show }
      for i = 1, math.min(#lines, rows - 1) do
        out[#out + 1] = term.move(i, 1) .. disp.expand(lines[i], ts):sub(1, cols)
      end
      local extra = (#lines > rows - 1) and (" +" .. (#lines - rows + 1) .. " more") or ""
      out[#out + 1] = term.move(rows, 1) .. "\27[7m-- Press any key" .. extra .. " --\27[0m"
      sys.write(1, table.concat(out))
      sys.read(0)                                     -- any key
    end
    -- Hand the real terminal to a child (interactive programs: fzf/fzy, vim,
    -- git commit): drop to cooked mode, leave the alt screen, run fn (which may
    -- capture output via a pipe while the child's UI uses the tty), then resume.
    -- `keep` (completion): stay ON the alt screen so an interactive picker/popup
    -- draws OVER the current frame instead of flashing the shell underneath; the
    -- caller repaints after (force_clear). The default swaps to the primary
    -- screen -- right for :! / vim / git that own the whole terminal.
    ed.with_tty = function(fn, keep)
      sys.restore(saved)
      sys.write(1, (keep and "" or term.alt_off) .. term.show)
      local r = fn()
      if not keep then sys.write(1, term.alt_on) end
      saved = sys.raw_mode()
      return r
    end
    -- Run an external command interactively; returns its exit code. `prompt`
    -- true adds "Press ENTER" (to read line output, with the code on failure);
    -- false = seamless resume (:silent, for full-screen programs).
    ed.shell = function(cmd, prompt)
      ed.export_context()
      return ed.with_tty(function()
        local st = os.execute(cmd)
        local code = (type(st) == "number") and math.floor(st / 256) or (st and 0 or 1)
        if prompt then
          local note = (code ~= 0) and (" [exit " .. code .. "]") or ""
          sys.write(1, "\r\n\27[7m-- Press ENTER to continue" .. note .. " --\27[0m")
          sys.read(0)
        end
        return code
      end)
    end
    -- Ctrl-Z: suspend to the shell (reusing the tty dance); execution continues
    -- after `raise(SIGTSTP)` when the user runs `fg`.
    ed.suspend_self = function() ed.with_tty(sys.suspend) end
    -- Insert-mode completion (Ctrl-P/Ctrl-N -> the `on complete` command). We run
    -- the completer synchronously, handing it the real terminal (keep=true, so a
    -- picker/popup draws over our frame), which freezes the poll loop -- so the
    -- completer can't read us back over the socket. We therefore feed it
    -- everything up front: the token being completed and the line's left context
    -- in the env, and ALL buffers' text (current first) on stdin. Its stdout is
    -- the replacement text. normal.lua splices it in over the token. Cross-buffer
    -- words work because the current view's other buffers live only in memory
    -- here, not on any socket the frozen loop could answer.
    ed.complete_run = function(cmd, token, left, dir)
      ed.export_context()
      sys.setenv("LVI_COMPL_TOKEN", token or "")
      sys.setenv("LVI_COMPL_LINE", left or "")
      sys.setenv("LVI_COMPL_DIR", dir or "")
      local tmp = path.tmp()                          -- all buffers' text: keep it private
      local f = io.open(tmp, "wb")
      if f then
        f:write(ed.buf:text())                          -- current buffer first
        for i = 1, #ed.buffers do
          if i ~= ed.bufidx then f:write(ed.buffers[i].buf:text()) end
        end
        f:close()
      end
      local sel = ed.with_tty(function()
        local p = io.popen(cmd .. " < " .. tmp, "r")    -- picker UI on /dev/tty
        local o = p and p:read("*a") or ""
        if p then p:close() end
        return o
      end, true)
      os.remove(tmp)
      ed.force_clear = true                             -- repaint over the picker
      return (sel or ""):match("^[^\r\n]*")             -- first line only (a line has no \n)
    end
    refresh(ed)
    sys.write(1, render.frame(ed))
  else
    ed.rows, ed.cols = 24, 80
    io.stderr:write("lvi: listening at " .. ed.sock_path .. "\n")
  end

  local conns = {}
  local function cleanup()
    for fd in pairs(conns) do sys.close(fd) end
    sys.close(lfd)
    sys.unlink(ed.sock_path)
    os.remove(ed.buffer_scratch)                 -- reap the :wbuf snapshot, if any
    for _, rec in ipairs(ed.buffers or {}) do    -- reap the conflict stamps
      if rec.buf._stamp then os.remove(rec.buf._stamp) end
    end
    if tty then sys.write(1, term.show .. term.alt_off) end
    if saved ~= nil then sys.restore(saved) end
  end

  local ok, err = pcall(function()
    while ed.running do
      local fds = { lfd }
      for fd in pairs(conns) do fds[#fds + 1] = fd end
      if tty then fds[#fds + 1] = 0 end

      -- Only arm the idle timeout when a keyboard change is waiting for its
      -- `change` hooks; otherwise block indefinitely (no idle wakeups).
      local ch = ed.hooks.change
      local armed = ed.change_pending and ch and #ch > 0
      local ready = sys.poll(fds, armed and IDLE_MS or -1)

      if not next(ready) then M.on_idle(ed) end -- poll timed out: idle

      -- Terminal resize handling without SIGWINCH. The alternative -- a signal
      -- handler -- is a poor fit under LuaJIT (an FFI callback reentering the VM
      -- from a signal is unsafe; the safe self-pipe trick needs a native handler
      -- we can't express as a cdef; signal() restart semantics diverge). Instead
      -- we re-read the winsize on every wakeup: it's one cheap ioctl, and since
      -- the loop already wakes and repaints on every key/socket event, the view
      -- follows a resize on the next event. The renderer is viewport-bounded and
      -- clr_eol's every row it paints, so updating rows/cols is the whole fix;
      -- the force_clear discards any reflow artifacts the terminal left behind.
      -- The idle gap (resized while nothing arrives) is closed by Ctrl-L, which
      -- is itself an event. :redraw does the same over the socket.
      if tty then
        local r, c = sys.winsize(1)
        if r and r > 0 and (r ~= ed.rows or c ~= ed.cols) then
          ed.rows, ed.cols = r, c
          ed.force_clear = true
        end
      end

      if ready[lfd] then
        local cfd = sys.accept(lfd)
        if cfd then conns[cfd] = new_conn(cfd) end
      end
      for fd, c in pairs(conns) do
        if ready[fd] then
          local data = sys.read(fd)
          if data then feed_conn(ed, c, data)
          else sys.close(fd); conns[fd] = nil end
        end
      end
      local ptop, psub, kbd = ed.top, ed.topsub or 0, false
      if tty and ready[0] then
        local data = sys.read(0)
        if not data then
          ed.running = false
        else
          local pb, pr = ed.buf, ed.buf.rev
          kbd = true
          feed(data)
          M.note_keyboard_change(ed, pb, pr)
        end
      end
      -- Keyboard input may have completed the command a socket key-injection
      -- arrived in the middle of; replay the deferred keys now. After
      -- note_keyboard_change so their edits stay socket-attributed (no hook).
      flush_deferred(ed)

      refresh(ed)
      -- `on scroll` fires the instant a KEYBOARD action moved the viewport top
      -- (checked after refresh, where scroll settles). Socket-driven top changes
      -- -- e.g. a scrollbind peer's :top -- happen in the conns branch with kbd
      -- false, so they never re-fire: that's the anti-echo gate, same discipline
      -- as note_keyboard_change. Undebounced (unlike `change`) so a bound peer
      -- tracks promptly. spawn_bg is non-blocking, so the pump stays responsive.
      if kbd and ed.running and (ed.top ~= ptop or (ed.topsub or 0) ~= psub) then
        M.fire(ed, "scroll")
      end
      if tty and ed.running then
        -- A full clear precedes the frame only when something requested it (a
        -- resize, Ctrl-L, or :redraw); normal repaints stay incremental via the
        -- renderer's per-row clr_eol.
        local pre = ed.force_clear and term.clear or ""
        ed.force_clear = false
        sys.write(1, pre .. render.frame(ed))
      end
    end
  end)

  cleanup()
  if not ok then
    -- The session is dead; salvage unsaved work before re-raising. Reported on
    -- stderr, which the now-restored terminal shows beneath the error.
    for _, note in ipairs(M.preserve(ed)) do io.stderr:write(note .. "\n") end
    error(err)
  end
  return ed
end

return M
