--- proto.lua -- the socket wire framing.
---
--- Design (see the commit history / design notes): responses are self-
--- delimiting, tagged, line-oriented messages so a single connection can carry
--- many request/response exchanges today and unsolicited %event notifications
--- later WITHOUT breaking existing clients. We lock this envelope now because
--- framing is the one part that is not additive; %event, subscribe, and the
--- event vocabulary are all deferred and can be bolted on later. Modeled on
--- tmux control mode (%begin/%end/%error + %-tagged notifications).
---
--- A response frame:
---   %begin <id>\n
---   %data <N>\n<N raw bytes>        (repeatable; omitted when payload empty)
---   %end <id> <status>\n
---
--- Payload travels as length-delimited %data chunks, never sentinel- or close-
--- terminated, so raw buffer text -- including a line that literally reads
--- "%end 1 ok" -- can never corrupt the frame. Reading text out (`:%p`) is a
--- first-class use case, so the wire must be binary-safe.
---
--- The REQUEST side: a connection starts as bare newline-delimited command
--- lines (which therefore cannot carry a newline in any argument). A client
--- that needs more sends the version handshake "%hello 1"; a server that
--- understands it replies with payload "lvi <ver>" and thereafter also accepts
---   %cmd <N>\n<N raw bytes>
--- carrying ONE command that may contain any byte, newlines included (e.g.
--- `:normal` inserting multi-line text). An old server treats the hello as an
--- ordinary line and no-ops it through the ex fallthrough with an EMPTY
--- payload -- which is exactly how a client detects it must stay on bare
--- lines. Bare lines remain valid forever, on every connection, handshake or
--- not: existing clients and the `echo ':w' > socket` idiom never break. The
--- handshake is gated (rather than %cmd being recognized unconditionally)
--- because a bare line reading "%cmd 5" is today a legal ex range command,
--- and only a client that asked for the new grammar should have it re-read.

local sys = require("sys")

local M = {}

-- The request-side handshake line and the framed-request builder (see header).
M.HELLO = "%hello 1\n"
function M.request(cmd)
  return "%cmd " .. #cmd .. "\n" .. cmd
end

-- Build the bytes of a framed response.
function M.response(id, payload, status)
  local out = { "%begin ", id, "\n" }
  if payload and #payload > 0 then
    out[#out + 1] = "%data " .. #payload .. "\n"
    out[#out + 1] = payload
  end
  out[#out + 1] = "%end " .. id .. " " .. (status or "ok") .. "\n"
  return table.concat(out)
end

-- Serialize and write a framed response to a connection fd.
function M.send_response(fd, id, payload, status)
  return sys.write(fd, M.response(id, payload, status))
end

-- ---- reading ----------------------------------------------------------------
-- A buffered frame reader. Construct with a read function that returns more
-- bytes (or nil at EOF); :response() parses exactly one frame and returns
-- payload, status, leaving any surplus buffered for the next call. Keeping I/O
-- injected (rather than hard-wiring sys.read) makes the parser unit-testable and
-- lets any transport reuse it.
local Reader = {}
Reader.__index = Reader

function M.reader(readfn)
  return setmetatable({ read = readfn, buf = "" }, Reader)
end

function Reader:_fill()
  local d = self.read()
  if not d then error("connection closed mid-frame") end
  self.buf = self.buf .. d
end

function Reader:_line()
  while not self.buf:find("\n", 1, true) do self:_fill() end
  local line, rest = self.buf:match("^(.-)\n(.*)$")
  self.buf = rest
  return line
end

function Reader:_take(n)
  while #self.buf < n do self:_fill() end
  local s = self.buf:sub(1, n)
  self.buf = self.buf:sub(n + 1)
  return s
end

function Reader:response()
  local begin = self:_line()
  if not begin:match("^%%begin %d+$") then
    error("malformed frame (expected %begin): " .. begin)
  end
  local payload = {}
  while true do
    local line = self:_line()
    local n = line:match("^%%data (%d+)$")
    if n then
      payload[#payload + 1] = self:_take(tonumber(n))
    else
      local _, status = line:match("^%%end (%d+) (%S+)$")
      if not status then error("malformed frame: " .. line) end
      return table.concat(payload), status
    end
  end
end

return M
