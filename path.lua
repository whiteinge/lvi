--- path.lua -- socket-location POLICY. The syscall layer lives in sys.lua;
--- this module only decides *where* a view's socket goes and makes sure the
--- containing directory exists safely. Per the design: one socket per view, and
--- the path itself is the selector (`echo ':w' > .../$wid`).

local sys = require("sys")

local M = {}

-- Resolve the runtime base directory. We prefer a system-provided, per-user
-- private dir -- XDG_RUNTIME_DIR on Linux (/run/user/$uid, mode 0700) or TMPDIR
-- on macOS (/var/folders/.../T, also private) -- because those are owned by us
-- and unwritable by others, so there is no /tmp squatting risk. Bare /tmp is
-- the last resort (e.g. a stripped BSD with neither set). Returns dir, safe.
local function base_dir()
  local d = os.getenv("XDG_RUNTIME_DIR")
  if d and d ~= "" then return (d:gsub("/+$", "")), true end
  d = os.getenv("TMPDIR")
  if d and d ~= "" then return (d:gsub("/+$", "")), true end
  return "/tmp", false
end

-- Ensure the per-uid lvi directory exists at 0700 and return its path.
--
-- mkdir(0700) is atomic: if it succeeds we created the dir, so we own it, it is
-- a real directory (not a pre-planted symlink), and it is private. If it fails
-- it is almost certainly EEXIST. When the parent is a system-private dir,
-- reusing an existing dir is safe. On the bare-/tmp fallback we REFUSE to reuse
-- a pre-existing directory rather than bind a socket somewhere we cannot prove
-- we own -- that is the classic /tmp hijack, where an attacker pre-creates the
-- path and then reads (and can inject `:!`-bearing commands into) our socket.
--
-- Deliberate MVP simplification: owner-verified reuse needs stat(2), whose
-- struct is as platform-divergent as termios, so we keep it out of the tree for
-- now (see sys.lua's decision record). The overwhelming majority of users have
-- XDG_RUNTIME_DIR or TMPDIR and never touch this branch; a bare-BSD user with a
-- crash leftover gets an actionable message instead of a silent security hole.
-- The per-uid socket directory path, WITHOUT creating it. For clients and
-- discovery, which must not have the side effect of making the dir.
function M.socket_dir()
  return (base_dir()) .. "/lvi-" .. sys.getuid()
end

function M.dir()
  local _, safe = base_dir()
  local dir = M.socket_dir()
  if sys.mkdir(dir, 0x1c0) then return dir end -- 0700; created fresh and owned
  if safe then return dir end                   -- private parent: safe to reuse
  error("refusing to reuse shared-/tmp dir " .. dir ..
        "; remove it, or set XDG_RUNTIME_DIR/TMPDIR")
end

-- Absolute socket path for a view id (server side; ensures the dir exists).
function M.socket(wid)
  return M.dir() .. "/" .. wid
end

-- Discover existing view sockets. Uses a POSIX shell glob with only builtins
-- (for / [ / printf) so there is no dependency on `ls` (which the user may have
-- shadowed on PATH) and no divergent struct dirent in our tree. Returns a list
-- of { wid = ..., path = ... } for the LIVE views only.
--
-- Each candidate is liveness-probed by try-connect -- the same test sys.listen
-- uses, and for the same reason: a crashed view leaves its socket file behind,
-- and errno is not portable, so "does someone answer?" is the reliable signal.
-- A socket nothing answers on is stale garbage, so we reap it (unlink) as we go.
-- This is race-free against a starting view: connect only fails when no one is
-- listening, and a view mid-bind has no file yet (or will unlink+rebind its own
-- stale path anyway). Both callers -- `-l` and `auto` resolution -- want live
-- views, so the filtering lives here rather than being duplicated in each.
function M.list_sockets()
  local cmd = ('for f in "%s"/*; do [ -S "$f" ] && printf "%%s\\n" "$f"; done')
              :format(M.socket_dir())
  local p = io.popen(cmd)
  if not p then return {} end
  local paths = {}
  for line in p:lines() do paths[#paths + 1] = line end -- drain before probing
  p:close()
  local out = {}
  for _, sock in ipairs(paths) do
    local fd = sys.connect(sock)                   -- liveness probe (try-connect)
    if fd then
      sys.close(fd)                                -- alive: keep it
      out[#out + 1] = { wid = sock:match("([^/]+)$"), path = sock }
    else
      sys.unlink(sock)                             -- dead: reap the stale socket
    end
  end
  return out
end

return M
