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

-- A private temp-file path. os.tmpname points at world-readable /tmp with a
-- predictable name -- unacceptable for what the editor writes out through temp
-- files (whole buffer contents: ex delegation, filters, completion), and the
-- classic symlink-race target besides. These live in the same 0700 per-uid dir
-- as the sockets instead. Uniqueness is pid + counter (single-threaded, one
-- process); callers os.remove() them when done, and the dir is per-user so a
-- crash leaves at worst private litter.
local tmp_n = 0
function M.tmp()
  tmp_n = tmp_n + 1
  return ("%s/tmp.%d.%d"):format(M.dir(), sys.getpid(), tmp_n)
end

-- Reap a view's sidecar files: everything sharing its socket-path prefix. Core's
-- own per-view litter (sockpath.buf, sockpath.stamp.N) lives there, and contrib
-- tools park their per-view state at $LVI_SOCK.<suffix> by convention (lvi-list's
-- .lists/ + .focus, lvi-spell's .spell, lvi-fmt's .last, ...). None of it is
-- reaped by unlinking the socket alone, so once the socket goes those siblings
-- are orphaned forever -- hence this sweep, run both on clean exit (editor
-- cleanup) and lazily when list_sockets() reaps a dead socket, mirroring how the
-- socket itself is handled. Both files and directories go, so rm -rf, not unlink.
-- The bare socket path (no dot) is NOT matched, so callers unlink it separately.
-- The prefix is quoted as one word with an unquoted ".*" so a base dir with
-- spaces is safe; a no-match leaves the literal glob, which -f silently ignores.
function M.reap_sidecars(sockpath)
  os.execute(("rm -rf -- %s.* 2>/dev/null"):format(sys.shq(sockpath)))
end

-- Discover live view sockets and GC dead ones. Globs EVERY entry in the per-uid
-- dir (not just sockets) with a builtins-only shell loop -- no dependency on `ls`
-- (which the user may have shadowed on PATH) and no divergent struct dirent in
-- our tree. Returns { wid = ..., path = ... } for the LIVE views only.
--
-- Liveness is decided by try-connect -- the same test sys.listen uses, and for
-- the same reason: a crashed view leaves its socket file behind, and errno is not
-- portable, so "does someone answer?" is the reliable signal. Connect succeeds
-- only on a live listener, and it is race-free against a starting view (connect
-- fails only when no one is listening, and a view mid-bind has no file yet or
-- rebinds its own stale path). A wid whose socket answers is live and protects
-- its whole `<wid>.*` sidecar namespace; every other numeric wid is dead, so its
-- stale socket and all sidecars are reaped (see reap_sidecars). Reaping by wid
-- namespace -- not just beside a dead socket we happen to probe -- is what clears
-- the orphans a view leaves when its socket was already reaped in a prior run.
-- Only numeric wids (pids) are GC'd, so path.tmp()'s `tmp.<pid>.<n>` files (a
-- different, caller-managed namespace) are left untouched. Both callers -- `-l`
-- and `auto` resolution -- want live views, so the filtering lives here.
function M.list_sockets()
  local dir = M.socket_dir()
  local cmd = ('for f in "%s"/*; do [ -e "$f" ] && printf "%%s\\n" "$f"; done')
              :format(dir)
  local p = io.popen(cmd)
  if not p then return {} end
  local entries = {}
  for line in p:lines() do entries[#entries + 1] = line end -- drain before probing
  p:close()
  local out, live_wid, dead_wid = {}, {}, {}
  for _, f in ipairs(entries) do
    local wid = f:match("([^/]+)$"):match("^([^.]*)")  -- basename up to first dot
    local fd = sys.connect(f)                          -- liveness probe (try-connect)
    if fd then
      sys.close(fd)                                    -- alive: a live socket
      live_wid[wid] = true
      out[#out + 1] = { wid = wid, path = f }
    elseif wid:match("^%d+$") then
      dead_wid[wid] = true                             -- a view wid, socket not answering
    end
  end
  for wid in pairs(dead_wid) do
    if not live_wid[wid] then                          -- guard: a sibling socket may be live
      sys.unlink(dir .. "/" .. wid)                    -- the stale socket, if this wid had one
      M.reap_sidecars(dir .. "/" .. wid)               -- ...and its orphaned sidecars
    end
  end
  return out
end

return M
