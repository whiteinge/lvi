--- term.lua -- ANSI/VT escape sequences for the renderer.
---
--- Pure string builders: no state and no I/O (the caller writes the bytes via
--- sys.write). We roll our own tiny set rather than depend on a terminal library
--- -- the sequences are few and stable, and owning them keeps the core minimal
--- and dependency-light, consistent with how the rest of lvi is built.

local ESC = string.char(27)

local M = {
  clear   = ESC .. "[2J",   -- clear whole screen
  home    = ESC .. "[H",    -- cursor to top-left
  clr_eol = ESC .. "[K",    -- clear from cursor to end of line
  hide    = ESC .. "[?25l", -- hide cursor (during redraw, to avoid flicker)
  show    = ESC .. "[?25h", -- show cursor
  alt_on  = ESC .. "[?1049h", -- enter alternate screen (preserves user's shell)
  alt_off = ESC .. "[?1049l", -- leave alternate screen
}

-- Move the cursor to (row, col), 1-based.
function M.move(row, col) return ESC .. "[" .. row .. ";" .. col .. "H" end

return M
