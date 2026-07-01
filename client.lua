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
function M.send(wid, commands, detach)
  local sock, err = resolve(wid)
  if not sock then return nil, err end
  local fd = sys.connect(sock)
  if not fd then return nil, "cannot connect to " .. sock end

  local reader = (not detach) and proto.reader(function() return sys.read(fd) end)
  local results = {}
  local ok, ferr = pcall(function()
    for _, cmd in ipairs(commands) do
      sys.write(fd, (cmd:gsub("^:", "")) .. "\n")
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
