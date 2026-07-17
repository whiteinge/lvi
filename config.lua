--- config.lua -- startup configuration: an rc file of ex commands.
---
--- This is the payoff of the "ex is the config language" decision (see the design
--- notes and README): there is NO separate config syntax. The rc file is just ex
--- commands -- exactly what you type at ':' and what a script sends over the
--- socket -- run once at startup through the same ex.dispatch. So `map`, `set`,
--- `hl`, even `e` all just work, and anything the ex vocabulary grows becomes
--- configurable for free. Comments are ex-style (a line whose first non-blank
--- char is '"'); blank lines are ignored.
---
--- This module is POLICY only (where the rc file lives + how to run it), matching
--- path.lua's split from sys.lua; it does no I/O beyond reading the one file.

local ex = require("ex")

local M = {}

local function readable(p)
  local f = p and io.open(p, "r")
  if f then f:close(); return p end
  return nil
end

-- Strip an ex-style comment and surrounding blanks from an rc line. The comment
-- char is '"', but a '"' occurs legitimately mid-command -- a register (`"ayy`),
-- a search or substitute (`/"/`), an `:echo "text"` -- so we cannot just cut at
-- the first one. A comment begins at a '"' that is EITHER preceded only by
-- whitespace (a full-line comment, `"like this`) OR "lone" mid-line: preceded by
-- whitespace and followed by whitespace or end-of-line. That leaves `"a`, `/"/`,
-- and `"str"` untouched (their '"' abuts a non-blank) while catching a trailing
-- `   " comment`. Both ends are then trimmed, so a stripped comment can't leave
-- dangling spaces that would be fed as stray keystrokes into a map's RHS.
local function strip_comment(line)
  for i = 1, #line do
    if line:sub(i, i) == '"' then
      local at_start = line:sub(1, i - 1):match("^%s*$") ~= nil
      local prev_ws  = i == 1 or line:sub(i - 1, i - 1):match("%s") ~= nil
      local next_ws  = i == #line or line:sub(i + 1, i + 1):match("%s") ~= nil
      if at_start or (prev_ws and next_ws) then line = line:sub(1, i - 1); break end
    end
  end
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Resolve the rc file path, or nil to load none. Precedence:
--   $LVIRC                       explicit override ("" or "NONE" disables config)
--   $XDG_CONFIG_HOME/lvi/lvirc   (default $HOME/.config/lvi/lvirc)
--   $HOME/.lvirc                 (the plain-vi location)
-- For auto-discovery the first *existing* file wins (XDG preferred). An explicit
-- $LVIRC is returned as-is so a bad path surfaces as a load error, not silence.
function M.rc_path()
  local override = os.getenv("LVIRC")
  if override ~= nil then
    if override == "" or override == "NONE" then return nil end
    return override
  end
  return M.user_rc_path()
end

-- The auto-discovery half alone, IGNORING $LVIRC -- what a bare :source loads.
-- The caller there is usually an alternate rc that $LVIRC itself names (e.g.
-- contrib/lvirc-man pulling the user's own config in before overriding it for
-- the pager), so honoring the override would source the file into itself.
function M.user_rc_path()
  local home = os.getenv("HOME")
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if (not xdg or xdg == "") and home then xdg = home .. "/.config" end
  return readable(xdg and (xdg .. "/lvi/lvirc"))
      or readable(home and (home .. "/.lvirc"))
end

-- Run a file of ex commands through ex.dispatch -- the one loop behind both
-- the startup rc and :source. Blank lines and '"' comments (whole-line or
-- trailing; see strip_comment) are skipped. A failing command does NOT abort
-- the rest; it is collected. Returns a list of { lnum = N, line = "...",
-- err = "..." } for the caller to surface, or nil when the file cannot be
-- opened.
function M.run(ed, path)
  local f = io.open(path, "r")
  if not f then return nil end
  local errs, lnum = {}, 0
  for line in f:lines() do
    lnum = lnum + 1
    local cmd = strip_comment(line)
    if cmd ~= "" then
      local payload, status = ex.dispatch(ed, cmd)
      if status == "err" then
        errs[#errs + 1] = { lnum = lnum, line = cmd, err = payload }
      end
    end
  end
  f:close()
  return errs
end

-- One-line failure report for a run's error list: the first few in full --
-- the first is usually the root cause (later ones often cascade from it) --
-- then a count. Shared by the startup banner and :source's payload.
function M.summary(path, errs)
  local parts = {}
  for i = 1, math.min(#errs, 3) do
    parts[#parts + 1] = ("line %d: %s"):format(errs[i].lnum, errs[i].err)
  end
  if #errs > 3 then parts[#parts + 1] = ("+%d more"):format(#errs - 3) end
  return ("%s: %d error%s -- %s"):format(
    path, #errs, #errs > 1 and "s" or "", table.concat(parts, "; "))
end

-- Load and run the rc file (if any). Returns the path loaded (or nil if none)
-- and M.run's error list.
function M.load(ed)
  local path = M.rc_path()
  if not path then return nil, {} end
  local errs = M.run(ed, path)
  if not errs then return path, { { lnum = 0, err = "cannot open " .. path } } end
  return path, errs
end

return M
