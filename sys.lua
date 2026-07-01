--- sys.lua -- the entire platform/syscall surface of lvi, quarantined.
--
-- ============================================================================
-- DECISION RECORD (why this file exists and why it looks like this)
-- ============================================================================
--
-- Runtime: LuaJIT.
--   We evaluated PUC Lua 5.4 + a C posix module (luaposix) against LuaJIT +
--   FFI. The deciding values were, in order: (1) extreme minimalism of *our
--   own* code, (2) a clean packaging story, (3) cross-UNIX portability
--   (Linux/macOS/BSD; WSL == Linux). LuaJIT wins because the entire C surface
--   we need lives in this one file with no build step and no external C
--   dependency: ship `luajit` + our .lua files, or bundle a single binary with
--   luastatic. Performance on scan/regex-heavy editor work is a free bonus.
--
-- Why FFI didn't become a portability nightmare:
--   The scary part of binding libc from Lua is termios -- a large struct with
--   divergent layouts and a wall of flag constants that differ per OS. We never
--   bind it. Raw mode is done by shelling out to stty (see raw_mode below),
--   which is pure Lua, zero ABI, and -- pleasingly -- is itself the project
--   philosophy in miniature: lean on the UNIX tools that already exist.
--   With termios gone, the only C surface left is socket + poll, which is tiny
--   and effectively frozen since the 1980s. The one real divergence is
--   `struct sockaddr_un` (macOS/BSD prepend a `sun_len` byte and use a shorter
--   path), handled by a single `ffi.os` branch below.
--
-- Why quarantine everything here:
--   The one genuine risk in betting on LuaJIT is its community-rolling release
--   model. By keeping every FFI call behind this module's small interface
--   (raw_mode/restore, listen/accept, poll, read/write/close, getuid/mkdir/
--   unlink), the PUC-vs-LuaJIT choice stays REVERSIBLE: if LuaJIT ever becomes
--   a liability, swap this single file for a luaposix-backed implementation and
--   nothing else in the codebase notices. This file is the only place in lvi
--   that is allowed to be unsafe or platform-specific.
--
-- Portability notes baked into the code below:
--   * errno values differ across OSes, so we never compare errno numbers.
--     Liveness of a stale socket is decided by try-connect, not by EADDRINUSE.
--   * poll() flag values (POLLIN/ERR/HUP/NVAL) and pollfd layout are uniform
--     across our targets; sockaddr_un is the only struct that branches.
--   * If poll() ever misbehaves on a target, select() belongs here too --
--     invisible to every caller.
--
-- Socket-path POLICY (where the socket lives) is deliberately NOT here. This
-- file only binds/listens on a path it is handed. Path construction
-- (XDG_RUNTIME_DIR -> TMPDIR -> /tmp, the lvi-$uid dir, the $wid view id, and
-- the 0700/ownership hardening) is the driver's job. getuid() and mkdir() are
-- exposed here because they are syscalls; composing them into a path is not.
-- ============================================================================

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
/* LP64 is assumed on every target (Linux/macOS/BSD on 64-bit). */
typedef unsigned int  socklen_t;

int   getuid(void);
int   getpid(void);
int   isatty(int fd);
int   close(int fd);
long  read(int fd, void *buf, unsigned long count);        /* ssize_t/size_t */
long  write(int fd, const void *buf, unsigned long count);
int   unlink(const char *pathname);
int   mkdir(const char *pathname, int mode);               /* mode_t widened */

struct pollfd { int fd; short events; short revents; };
int   poll(struct pollfd *fds, unsigned long nfds, int timeout);

int   socket(int domain, int type, int protocol);
int   bind(int sockfd, const void *addr, socklen_t addrlen);
int   listen(int sockfd, int backlog);
int   accept(int sockfd, void *addr, socklen_t *addrlen);
int   connect(int sockfd, const void *addr, socklen_t addrlen);

struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
int   ioctl(int fd, unsigned long request, void *arg);
]]

-- sockaddr_un: the one struct that diverges. AF_UNIX == 1 and SOCK_STREAM == 1
-- on all targets, so only the layout branches.
if ffi.os == "OSX" or ffi.os == "BSD" then
  ffi.cdef[[
    struct sockaddr_un { unsigned char sun_len; unsigned char sun_family; char sun_path[104]; };
  ]]
else -- Linux (and WSL)
  ffi.cdef[[
    struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
  ]]
end

local M = {}

-- Constants (uniform across Linux/macOS/BSD).
local AF_UNIX     = 1
local SOCK_STREAM = 1
M.POLLIN  = 0x01
M.POLLERR = 0x08
M.POLLHUP = 0x10
M.POLLNVAL= 0x20

--- Identity / filesystem primitives (syscalls; path policy lives in the driver).
function M.getuid() return tonumber(C.getuid()) end
function M.getpid() return tonumber(C.getpid()) end
function M.isatty(fd) return C.isatty(fd) == 1 end

-- Terminal size of fd (default stdout). struct winsize is uniform; only the
-- request number diverges (Linux vs the BSD _IOR encoding macOS/*BSD share).
local TIOCGWINSZ = (ffi.os == "Linux") and 0x5413 or 0x40087468
function M.winsize(fd)
  local ws = ffi.new("struct winsize")
  if C.ioctl(fd or 1, TIOCGWINSZ, ws) ~= 0 then return nil end
  return ws.ws_row, ws.ws_col
end
function M.unlink(path) return C.unlink(path) == 0 end

--- Create a directory. Returns true on success. EEXIST and friends surface as
--- false; the driver is responsible for the lstat/owner 0700 verification when
--- it falls back to a shared /tmp.
function M.mkdir(path, mode) return C.mkdir(path, mode or 0x1c0) == 0 end -- 0700

--- Build a filled-in sockaddr_un for `path`. Internal.
local function sockaddr(path)
  assert(#path < 104, "socket path too long: " .. path)
  local addr = ffi.new("struct sockaddr_un")
  addr.sun_family = AF_UNIX
  if ffi.os == "OSX" or ffi.os == "BSD" then
    addr.sun_len = ffi.sizeof("struct sockaddr_un")
  end
  ffi.copy(addr.sun_path, path)
  return addr, ffi.sizeof("struct sockaddr_un")
end

--- Listen on a Unix-domain socket at `path`. Handles crash leftovers without
--- comparing errno: probe the path; if someone answers, the view is alive and
--- we refuse; otherwise the file is stale, so unlink and bind. Returns the
--- listening fd.
function M.listen(path, backlog)
  local addr, len = sockaddr(path)

  -- Liveness probe (try-connect, not errno).
  local probe = C.socket(AF_UNIX, SOCK_STREAM, 0)
  if probe >= 0 then
    local alive = C.connect(probe, addr, len) == 0
    C.close(probe)
    if alive then error("lvi already listening at " .. path) end
  end
  C.unlink(path) -- remove stale file if present (no-op otherwise)

  local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 then error("socket() failed for " .. path) end
  if C.bind(fd, addr, len) ~= 0 then C.close(fd); error("bind() failed for " .. path) end
  if C.listen(fd, backlog or 8) ~= 0 then C.close(fd); error("listen() failed for " .. path) end
  return fd
end

--- Accept one pending connection on a listening fd. Returns the connection fd,
--- or nil if none is ready. Client address is discarded (path is the selector).
function M.accept(fd)
  local conn = C.accept(fd, nil, nil)
  if conn < 0 then return nil end
  return conn
end

--- Connect to a Unix-domain socket at `path`. Returns the connected fd, or nil
--- on failure (e.g. nothing listening). The client side of M.listen.
function M.connect(path)
  local addr, len = sockaddr(path)
  local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd < 0 then return nil end
  if C.connect(fd, addr, len) ~= 0 then C.close(fd); return nil end
  return fd
end

--- Poll a list of fds for readability (and error/hangup). `fds` is an array of
--- integer fds. Returns a table mapping ready fd -> revents bitmask.
function M.poll(fds, timeout_ms)
  local n = #fds
  local pfds = ffi.new("struct pollfd[?]", n)
  for i = 1, n do
    pfds[i - 1].fd = fds[i]
    pfds[i - 1].events = M.POLLIN
    pfds[i - 1].revents = 0
  end
  local rc = C.poll(pfds, n, timeout_ms or -1)
  local ready = {}
  if rc <= 0 then return ready end -- timeout or error: nothing ready
  for i = 1, n do
    local re = pfds[i - 1].revents
    if re ~= 0 then ready[pfds[i - 1].fd] = re end
  end
  return ready
end

--- Read up to `n` bytes from `fd`. Returns a string, or nil on EOF/error.
local RBUF_MAX = 4096
function M.read(fd, n)
  n = n or RBUF_MAX
  local buf = ffi.new("char[?]", n)
  local r = tonumber(C.read(fd, buf, n))
  if r <= 0 then return nil end
  return ffi.string(buf, r)
end

--- Write the whole string `s` to `fd`, looping over partial writes. Returns
--- true on success, nil on error.
function M.write(fd, s)
  local p, len = ffi.cast("const char *", s), #s
  local off = 0
  while off < len do
    local w = tonumber(C.write(fd, p + off, len - off))
    if w <= 0 then return nil end
    off = off + w
  end
  return true
end

function M.close(fd) return C.close(fd) == 0 end

--- Raw mode via stty -- no termios struct in our tree. Save the current
--- settings (stty -g returns an opaque, restorable blob), then drop canonical
--- mode and echo. restore() replays the saved blob. Both shell out once, at
--- startup/shutdown; the cost is irrelevant and the philosophy is on-brand.
function M.raw_mode()
  local f = io.popen("stty -g 2>/dev/null")
  local saved = f and f:read("*l") or nil
  f:close()
  os.execute("stty raw -echo 2>/dev/null")
  return saved -- hand this back to restore()
end

function M.restore(saved)
  if saved then os.execute("stty " .. saved .. " 2>/dev/null")
  else os.execute("stty sane 2>/dev/null") end
end

return M
