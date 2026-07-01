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
  local home = os.getenv("HOME")
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if (not xdg or xdg == "") and home then xdg = home .. "/.config" end
  return readable(xdg and (xdg .. "/lvi/lvirc"))
      or readable(home and (home .. "/.lvirc"))
end

-- Load and run the rc file (if any) through ex.dispatch. Blank lines and '"'
-- comment lines are skipped. A failing command does NOT abort the rest; instead
-- it is collected. Returns the path loaded (or nil if none) and a list of
-- { lnum = N, line = "...", err = "..." } for the caller to surface.
function M.load(ed)
  local path = M.rc_path()
  if not path then return nil, {} end
  local f = io.open(path, "r")
  if not f then return path, { { lnum = 0, err = "cannot open " .. path } } end
  local errs, lnum = {}, 0
  for line in f:lines() do
    lnum = lnum + 1
    local trimmed = line:gsub("^%s+", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= '"' then
      local payload, status = ex.dispatch(ed, trimmed)
      if status == "err" then
        errs[#errs + 1] = { lnum = lnum, line = trimmed, err = payload }
      end
    end
  end
  f:close()
  return path, errs
end

return M
