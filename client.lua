--- client.lua -- the `lvi -w` side: connect to a view's control socket, send ex
--- commands, collect the framed replies. This is the durable, ergonomic front
--- door to the socket interface (replacing the throwaway tclient). It is just a
--- convenience client -- any language can speak the protocol; nothing here is
--- privileged over the socket.

local sys   = require("sys")
local path  = require("path")
local proto = require("proto")

local M = {}

-- Resolve a target socket path. An explicit wid selects that view; "auto" (or
-- nil) targets the sole running view, erroring if there are zero or several.
local function resolve(wid)
  if wid and wid ~= "auto" then return path.socket_dir() .. "/" .. wid end
  local views = path.list_sockets()
  if #views == 0 then return nil, "no running lvi views found" end
  if #views > 1 then
    local ids = {}
    for _, v in ipairs(views) do ids[#ids + 1] = v.wid end
    return nil, "multiple views (" .. table.concat(ids, " ") .. "); use -w <wid>"
  end
  return views[1].path
end

-- Send a list of ex command strings to the target. Returns a list of
-- { cmd, status, payload }, or nil, err. A leading ':' is tolerated and
-- stripped so both `w` and `:w` work. With detach=true, fire-and-forget: send
-- without awaiting replies (results is empty) -- required for a callback from a
-- program the editor is blocked running, which would otherwise deadlock.
--
-- Framing: the client opens with the %hello handshake and, when the server
-- greets back ("lvi <ver>"; an old server no-ops the hello through the ex
-- fallthrough instead), sends each command length-framed -- which lets a command
-- argument contain newlines (e.g. `normal` inserting multi-line text). Against
-- an old server it falls back to bare lines and refuses a newline-bearing
-- command rather than let the server mis-split it. Detached mode can't read
-- the handshake reply, so it upgrades blindly only when a command actually
-- needs framing -- plain commands stay bare lines, byte-identical to the old
-- wire, whatever the server.
--
-- The one deadlock the client can see coming: a program the view is blocked
-- running (`:!`, `:silent !`, a register backend, `:sh` and the shell it gives
-- you) calls back into THAT view and waits for a reply. The view is waiting on
-- the program, so no reply ever comes, and a mis-bound map would freeze the
-- editor for good. A view that is running answers the %hello at once, so when
-- we are the view's own child (our socket is $LVI_SOCK) and it was not a
-- detached `:bg` spawn (no $LVI_BG), an unanswered hello past HELLO_WAIT_MS is
-- that deadlock: fail with an error saying how to fix it instead of hanging.
-- Everyone else still waits indefinitely -- a `:bg` hook whose view is busy in
-- a long `:!make` is not deadlocked, only early. A self-backgrounding worker
-- forked from a `:!` child keeps the suspicion, which is harmless: its parent
-- returns at once and the view answers well inside the window. The check runs
-- after connect(), so a view frozen long enough for its listen backlog to fill
-- (sys.listen) blocks the connect itself, before any of this, and that client
-- hangs as before.
local HELLO_WAIT_MS = 2000

local function frozen_on_us(sock, fd)
  if (os.getenv("LVI_BG") or "") ~= "" or os.getenv("LVI_SOCK") ~= sock then return false end
  -- One poll for the whole window. nil is EINTR (a resize, job control), not
  -- time passed, so the window restarts: a signal can only make us wait longer,
  -- never call a slow view frozen.
  local ready
  repeat ready = sys.poll({ fd }, HELLO_WAIT_MS) until ready ~= nil
  return next(ready) == nil
end

function M.send(wid, commands, detach)
  local sock, err = resolve(wid)
  if not sock then return nil, err end
  local fd = sys.connect(sock)
  if not fd then return nil, "cannot connect to " .. sock end

  local multiline = false
  for _, cmd in ipairs(commands) do
    if cmd:find("\n", 1, true) then multiline = true; break end
  end

  local reader = (not detach) and proto.reader(function() return sys.read(fd) end)
  local results = {}
  local ok, ferr = pcall(function()
    local framed = false
    if not detach then
      sys.write(fd, proto.HELLO)
      if frozen_on_us(sock, fd) then
        -- Our stderr is gone under `:silent !`, so also leave the reason on the
        -- connection: the view reads it once it resumes and shows it on the
        -- status line. (A bare line, valid with or without the handshake.)
        sys.write(fd, "msge lvi -w: a command lvi was waiting on called back"
          .. " into it and was refused; run it with :bg\n")
        error("view " .. (os.getenv("LVI_WID") or "?") .. " is waiting for this"
          .. " command to exit, so it cannot answer; run it with :bg, or send"
          .. " with lvi -w --detach", 0)
      end
      local payload = reader:response()
      framed = payload:match("^lvi %d") ~= nil      -- old server: empty or an ex error
      if multiline and not framed then
        error("this lvi does not support multi-line commands (upgrade the view)", 0)
      end
    elseif multiline then
      sys.write(fd, proto.HELLO)                    -- blind upgrade (reply unread)
      framed = true
    end
    for _, cmd in ipairs(commands) do
      local body = (cmd:gsub("^:", ""))
      sys.write(fd, framed and proto.request(body) or (body .. "\n"))
      if not detach then
        local payload, status = reader:response()
        results[#results + 1] = { cmd = cmd, status = status, payload = payload }
      end
    end
  end)
  sys.close(fd)
  if not ok then return nil, tostring(ferr) end
  return results
end

return M
