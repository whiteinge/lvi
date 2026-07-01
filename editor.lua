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

local function feed_conn(ed, c, data)
  c.inbuf = c.inbuf .. data
  while true do
    local line, rest = c.inbuf:match("^(.-)\n(.*)$")
    if not line then break end
    c.inbuf = rest
    local id = c.next_id
    c.next_id = id + 1
    ed.buf:undo_checkpoint() -- each socket command is its own undo unit
    local payload, status = ex.dispatch(ed, line)
    -- A ':normal' pushes keys onto ed.inject; drive the coroutine to consume
    -- them now, so a following command in this batch sees the result.
    if #ed.inject > 0 then pump(ed) end
    proto.send_response(c.fd, id, payload, status)
  end
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
    inject = {}, keylog = {}, regs = {},
    opts = { wrap = true, tabstop = 8 },
  }
  -- Per-buffer view state (buf, cx/cy, top/topsub, leftcol, marks, highlights)
  -- is set up here and swapped by bufs on :e / buffer switch. Positional files
  -- open as buffers; the first is current.
  local files = opts.files or (opts.filename and { opts.filename }) or {}
  bufs.init(ed, files[1] and buffer.open(files[1]) or buffer.new(""))
  for i = 2, #files do bufs.open(ed, files[i]) end
  if #ed.buffers > 1 then bufs.switch(ed, 1) end
  ed.wid = opts.wid or tostring(sys.getpid())
  ed.sock_path = path.socket(ed.wid)
  local lfd = sys.listen(ed.sock_path)
  -- Export the view id/socket so external programs (`:!`, pickers) can drive
  -- this view back over the socket (`lvi -w "$LVI_WID" -- ...`).
  sys.setenv("LVI_WID", ed.wid)
  sys.setenv("LVI_SOCK", ed.sock_path)

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
    ed.with_tty = function(fn)
      sys.restore(saved)
      sys.write(1, term.alt_off .. term.show)
      local r = fn()
      sys.write(1, term.alt_on)
      saved = sys.raw_mode()
      return r
    end
    -- Run an external command interactively. `prompt` true adds "Press ENTER"
    -- (to read line output); false = seamless resume (:silent, for full-screen
    -- programs that restore the screen themselves).
    ed.shell = function(cmd, prompt)
      ed.with_tty(function()
        os.execute(cmd)
        if prompt then
          sys.write(1, "\r\n\27[7m-- Press ENTER to continue --\27[0m")
          sys.read(0)
        end
      end)
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
    if tty then sys.write(1, term.show .. term.alt_off) end
    if saved ~= nil then sys.restore(saved) end
  end

  local ok, err = pcall(function()
    while ed.running do
      local fds = { lfd }
      for fd in pairs(conns) do fds[#fds + 1] = fd end
      if tty then fds[#fds + 1] = 0 end

      local ready = sys.poll(fds, -1)

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
      if tty and ready[0] then
        local data = sys.read(0)
        if not data then ed.running = false else feed(data) end
      end

      refresh(ed)
      if tty and ed.running then sys.write(1, render.frame(ed)) end
    end
  end)

  cleanup()
  if not ok then error(err) end
  return ed
end

return M
