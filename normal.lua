--- normal.lua -- the normal-mode command interpreter, as a coroutine.
---
--- The whole grammar is written as straight-line code that *pulls* keys via
--- getkey() (which yields until the driver feeds a key), so counts, operators,
--- and motions compose without a hand-rolled state machine. The design:
---   * a MOTION returns a target (line,col) plus kind (char/line) + inclusive;
---   * an OPERATOR (d/c/y) consumes the range from the cursor to that target;
---   * a standalone motion just moves; a doubled operator (dd) is linewise.
--- Add a motion and it works with every operator for free, and vice versa.
---
--- Input funnel: getkey pops from ed.inject (fed by the driver from the
--- keyboard now; later also '.', macros, and the socket ':normal' hatch -- all
--- just "append keys to ed.inject"). getkey logs every key into ed.keylog so a
--- change can be saved as ed.last_change for a future '.' repeat.

local ex = require("ex")
local disp = require("disp")

local M = {}

local b = string.byte

-- ---- key input --------------------------------------------------------------
local function getkey(ed)
  while #ed.inject == 0 do coroutine.yield() end
  local k = table.remove(ed.inject, 1)
  ed.keylog[#ed.keylog + 1] = k
  if ed.recording then ed.macro_buf[#ed.macro_buf + 1] = k end
  return k
end

-- optional leading count: 1-9 then 0-9 ('0' alone is the ^0 motion, not a count)
local function read_count(ed, k)
  if k < b("1") or k > b("9") then return nil, k end
  local n = k - b("0")
  while true do
    local d = getkey(ed)
    if d >= b("0") and d <= b("9") then n = n * 10 + (d - b("0"))
    else return n, d end
  end
end

local function combine(a, c) -- count1 * count2 with nils
  if a and c then return a * c elseif a then return a else return c end
end

-- ---- buffer/cursor helpers --------------------------------------------------
local function line(ed, l) return ed.buf:line(l) or "" end

local function first_nonblank(s)
  return (s:find("%S")) or 1
end

local function clamp(ed)
  local nl = ed.buf:nlines()
  ed.cy = math.max(1, math.min(ed.cy, nl))
  local s = line(ed, ed.cy)
  local maxc = (ed.mode == "insert") and (#s + 1) or disp.last_char(s) -- char-aware cap
  ed.cx = math.max(1, math.min(ed.cx, maxc))
end

local function char_class(c)
  if not c or c == "" then return "none" end
  if c:match("%s") then return "blank" end
  local b = c:byte(1)
  if (b and b >= 128) or c:match("[%w_]") then return "word" end -- multibyte = word
  return "punct"
end

-- ---- registers --------------------------------------------------------------
-- A register is { text = string, linewise = bool }. The unnamed register '"'
-- always mirrors the last delete/yank; a named register also updates it.
local function set_reg(ed, name, text, linewise)
  local r = { text = text, linewise = linewise }
  if name then ed.regs[name] = r end
  ed.regs['"'] = r
end
local function get_reg(ed, name) return ed.regs[name or '"'] end

-- ---- insert mode (also a coroutine loop) ------------------------------------
local function insert_char(ed, byte_)
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(1, ed.cx - 1) .. string.char(byte_) .. s:sub(ed.cx))
  ed.cx = ed.cx + 1
end

local function split_line(ed) -- <CR> in insert mode
  local s = line(ed, ed.cy)
  ed.buf:set(ed.cy, s:sub(1, ed.cx - 1))
  ed.buf:insert(ed.cy + 1, { s:sub(ed.cx) })
  ed.cy = ed.cy + 1
  ed.cx = 1
end

local function backspace(ed)
  if ed.cx > 1 then
    local s = line(ed, ed.cy)
    local pc = disp.prev_char(s, ed.cx)          -- delete the whole char before cursor
    ed.buf:set(ed.cy, s:sub(1, pc - 1) .. s:sub(ed.cx))
    ed.cx = pc
  elseif ed.cy > 1 then -- join with previous line
    local prev, cur = line(ed, ed.cy - 1), line(ed, ed.cy)
    ed.cx = #prev + 1
    ed.buf:set(ed.cy - 1, prev .. cur)
    ed.buf:delete(ed.cy, ed.cy)
    ed.cy = ed.cy - 1
  end
end

local function insert_mode(ed)
  ed.changed = true
  ed.mode = "insert"
  ed.message = "-- INSERT --"
  clamp(ed)
  while true do
    local k = getkey(ed)
    if k == 27 then break                              -- ESC
    elseif k == 13 or k == 10 then split_line(ed)      -- CR
    elseif k == 127 or k == 8 then backspace(ed)       -- Backspace
    elseif k == 9 or (k >= 32 and k ~= 127) then insert_char(ed, k) -- printable + UTF-8 bytes
    end
    clamp(ed)
  end
  ed.mode = "normal"
  ed.message = nil
  ed.cx = math.max(1, ed.cx - 1) -- vi steps left on leaving insert
  clamp(ed)
end

-- ---- operators over ranges --------------------------------------------------
local function op_lines(ed, op, a, c, reg)
  a = math.max(1, a); c = math.min(c, ed.buf:nlines())
  if a > c then return end
  local text = table.concat(ed.buf:get(a, c), "\n") .. "\n" -- linewise regs end in \n
  set_reg(ed, reg, text, true)
  if op == "y" then
    ed.cy = a
  elseif op == "d" then
    ed.buf:delete(a, c); ed.cy = a; ed.changed = true
  elseif op == "c" then
    ed.buf:delete(a, c); ed.buf:insert(a, { "" })
    ed.cy = a; ed.cx = 1; ed.changed = true
    insert_mode(ed)
  end
  clamp(ed)
end

local function pos_le(l1, c1, l2, c2)
  return l1 < l2 or (l1 == l2 and c1 <= c2)
end

-- Charwise operator over a (possibly multi-line) range from (sl,sc) to (tl,tc).
-- `inclusive` keeps the char at the far end; exclusive drops it (stepping back a
-- line if that lands before column 1 -- which is what makes `dw` on the last
-- word of a line stop at the newline instead of joining, matching vi).
local function op_chars_range(ed, op, sl, sc, tl, tc, inclusive, reg)
  if not pos_le(sl, sc, tl, tc) then sl, sc, tl, tc = tl, tc, sl, sc end
  local el, ec = tl, tc
  if not inclusive then
    ec = ec - 1
    while ec < 1 and el > sl do el = el - 1; ec = #line(ed, el) end
  end
  if el < sl or (el == sl and ec < sc) then return end -- empty range
  local first, last = line(ed, sl), line(ed, el)
  ec = math.min(ec, #last)
  local text
  if sl == el then
    text = first:sub(sc, ec)
  else
    local t = { first:sub(sc) }
    for i = sl + 1, el - 1 do t[#t + 1] = line(ed, i) end
    t[#t + 1] = last:sub(1, ec)
    text = table.concat(t, "\n")
  end
  set_reg(ed, reg, text, false)
  if op == "y" then
    ed.cy, ed.cx = sl, sc
  else
    ed.buf:splice(sl, el - sl + 1, { first:sub(1, sc - 1) .. last:sub(ec + 1) })
    ed.cy, ed.cx = sl, sc
    ed.changed = true
    if op == "c" then insert_mode(ed) end
  end
  clamp(ed)
end

-- ---- motions ----------------------------------------------------------------
-- Each: { kind = "char"|"line", inclusive = bool, move = fn(ed,count)->(l,c[,inc]) }.
-- Word motions cross line boundaries and stop on empty lines (POSIX-ish).
local function word_forward(ed, count)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    local s = line(ed, l)
    if #s > 0 and c <= #s and char_class(s:sub(c, c)) ~= "blank" then
      local cls = char_class(s:sub(c, c))
      while c <= #s and char_class(s:sub(c, c)) == cls do c = c + 1 end
    end
    while true do
      s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
        if #line(ed, l) == 0 then return end -- empty line is a word stop
      elseif char_class(s:sub(c, c)) == "blank" then c = c + 1
      else return end
    end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.min(c, math.max(1, #line(ed, l)))
end

local function word_back(ed, count)
  local l, c = ed.cy, ed.cx
  local function step()
    c = c - 1
    while true do
      if c < 1 then
        if l <= 1 then c = 1; return end
        l = l - 1; c = #line(ed, l)
        if c == 0 then c = 1; return end   -- empty line is a word stop
      else
        local s = line(ed, l)
        if char_class(s:sub(c, c)) == "blank" then c = c - 1 else break end
      end
    end
    local s = line(ed, l)
    local cls = char_class(s:sub(c, c))
    while c > 1 and char_class(s:sub(c - 1, c - 1)) == cls do c = c - 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

local function word_end(ed, count)
  local N, l, c = ed.buf:nlines(), ed.cy, ed.cx
  local function step()
    c = c + 1
    while true do
      local s = line(ed, l)
      if c > #s then
        if l >= N then c = math.max(1, #s); return end
        l, c = l + 1, 1
      elseif char_class(s:sub(c, c)) == "blank" then c = c + 1
      else break end
    end
    local s = line(ed, l)
    local cls = char_class(s:sub(c, c))
    while c < #s and char_class(s:sub(c + 1, c + 1)) == cls do c = c + 1 end
  end
  for _ = 1, (count or 1) do step() end
  return l, math.max(1, c)
end

-- f/t/F/T within-line char search, shared by the motions and by ;/,. Returns the
-- target column, or nil if not found.
local function do_find(ed, kind, ch, count)
  local s, c = line(ed, ed.cy), ed.cx
  for _ = 1, (count or 1) do
    if kind == "f" then
      local i = s:find(ch, c + 1, true); if not i then return nil end; c = i
    elseif kind == "t" then
      local from = (s:sub(c + 1, c + 1) == ch) and c + 2 or c + 1
      local i = s:find(ch, from, true); if not i then return nil end; c = i - 1
    elseif kind == "F" then
      local i; for j = c - 1, 1, -1 do if s:sub(j, j) == ch then i = j; break end end
      if not i then return nil end; c = i
    elseif kind == "T" then
      local from = (s:sub(c - 1, c - 1) == ch) and c - 2 or c - 1
      local i; for j = from, 1, -1 do if s:sub(j, j) == ch then i = j; break end end
      if not i then return nil end; c = i + 1
    end
  end
  return c
end

-- f/t are forward+inclusive; F/T are backward (exclusive of the origin in our
-- range model). Each records ed.last_find so ;/, can repeat it.
local function find_motion(kind, inclusive)
  return { kind = "char", inclusive = inclusive, move = function(ed, count)
    ed.last_find = { kind = kind, char = string.char(getkey(ed)) }
    local c = do_find(ed, kind, ed.last_find.char, count)
    return ed.cy, c or ed.cx
  end }
end

local flip = { f = "F", F = "f", t = "T", T = "t" }

local motions = {
  [b("h")] = { kind = "char", move = function(ed, n)
    local s, c = line(ed, ed.cy), ed.cx
    for _ = 1, (n or 1) do c = disp.prev_char(s, c) end
    return ed.cy, c
  end },
  [b("l")] = { kind = "char", move = function(ed, n)
    local s, c = line(ed, ed.cy), ed.cx
    for _ = 1, (n or 1) do if c <= #s then c = disp.next_char(s, c) end end
    return ed.cy, c
  end },
  [b("0")] = { kind = "char", move = function(ed) return ed.cy, 1 end },
  [b("^")] = { kind = "char", move = function(ed) return ed.cy, first_nonblank(line(ed, ed.cy)) end },
  [b("$")] = { kind = "char", inclusive = true, move = function(ed) return ed.cy, math.max(1, #line(ed, ed.cy)) end },
  [b("w")] = { kind = "char", move = word_forward },
  [b("b")] = { kind = "char", move = word_back },
  [b("e")] = { kind = "char", inclusive = true, move = word_end },
  [b("f")] = find_motion("f", true),
  [b("t")] = find_motion("t", true),
  [b("F")] = find_motion("F", false),
  [b("T")] = find_motion("T", false),
  [b(";")] = { kind = "char", move = function(ed, count)
    local lf = ed.last_find; if not lf then return ed.cy, ed.cx, false end
    return ed.cy, do_find(ed, lf.kind, lf.char, count) or ed.cx, (lf.kind == "f" or lf.kind == "t")
  end },
  [b(",")] = { kind = "char", move = function(ed, count)
    local lf = ed.last_find; if not lf then return ed.cy, ed.cx, false end
    local k = flip[lf.kind]
    return ed.cy, do_find(ed, k, lf.char, count) or ed.cx, (k == "f" or k == "t")
  end },
  [b("g")] = { kind = "line", move = function(ed, count) -- gg / gj / gk
    local k2 = getkey(ed)
    if k2 == b("g") then
      local t = math.max(1, math.min(count or 1, ed.buf:nlines()))
      return t, first_nonblank(line(ed, t))
    end
    if k2 ~= b("j") and k2 ~= b("k") then return ed.cy, ed.cx end
    local down, n = (k2 == b("j")), (count or 1)
    if not (ed.opts and ed.opts.wrap) then           -- no wrapping: gj == j
      return ed.cy + (down and n or -n), ed.cx
    end
    -- Move by screen (display) rows, holding the current visual column.
    local W, ts = ed.cols or 80, ed.opts.tabstop or 8
    local N, l = ed.buf:nlines(), ed.cy
    local sub, ccol = disp.locate(line(ed, l), W, ts, ed.cx)
    for _ = 1, n do
      if down then
        if sub + 1 < disp.nsegs(line(ed, l), W, ts) then sub = sub + 1
        elseif l < N then l, sub = l + 1, 0 else break end
      else
        if sub > 0 then sub = sub - 1
        elseif l > 1 then l = l - 1; sub = disp.nsegs(line(ed, l), W, ts) - 1
        else break end
      end
    end
    return l, disp.byteat(line(ed, l), W, ts, sub, ccol)
  end },
  [96] = { kind = "char", move = function(ed) -- `{mark}: exact position
    local m = ed.marks and ed.marks[string.char(getkey(ed))]
    if not m then return ed.cy, ed.cx end
    return m[1], m[2]
  end },
  [39] = { kind = "line", move = function(ed) -- '{mark}: mark's line
    local m = ed.marks and ed.marks[string.char(getkey(ed))]
    if not m then return ed.cy, ed.cx end
    local l = math.max(1, math.min(m[1], ed.buf:nlines()))
    return l, first_nonblank(line(ed, l))
  end },
  [124] = { kind = "char", move = function(ed, count) -- N| : goto display column N
    local ts = (ed.opts and ed.opts.tabstop) or 8
    return ed.cy, disp.byte_at_dispcol(line(ed, ed.cy), ts, (count or 1) - 1)
  end },
  [b("j")] = { kind = "line", move = function(ed, n) return ed.cy + (n or 1), ed.cx end },
  [b("k")] = { kind = "line", move = function(ed, n) return ed.cy - (n or 1), ed.cx end },
  [b("G")] = { kind = "line", move = function(ed, n)
    local t = n or ed.buf:nlines()
    t = math.max(1, math.min(t, ed.buf:nlines()))
    return t, first_nonblank(line(ed, t))
  end },
}

local function do_motion(ed, m, count)
  local tl, tc = m.move(ed, count)
  ed.cy, ed.cx = tl, tc
  clamp(ed)
end

local function apply_operator(ed, op, m, count, reg)
  local tl, tc, inc = m.move(ed, count)
  if inc == nil then inc = m.inclusive end
  if m.kind == "line" then
    local a, c = ed.cy, tl
    if a > c then a, c = c, a end
    op_lines(ed, op, a, c, reg)
  else
    op_chars_range(ed, op, ed.cy, ed.cx, tl, tc, inc, reg)
  end
end

-- ---- single-key actions -----------------------------------------------------
local function do_put(ed, after, reg)
  local r = get_reg(ed, reg)
  if not r or r.text == "" then return end
  if r.linewise then
    local lines = {}
    for ln in r.text:gmatch("(.-)\n") do lines[#lines + 1] = ln end
    local at = after and ed.cy + 1 or ed.cy
    ed.buf:insert(at, lines)
    ed.cy, ed.cx = at, 1
  else
    local s = line(ed, ed.cy)
    local at = ed.cx + ((after and #s > 0) and 1 or 0)
    ed.buf:set(ed.cy, s:sub(1, at - 1) .. r.text .. s:sub(at))
    ed.cx = at + #r.text - 1
  end
  ed.changed = true
  clamp(ed)
end

local actions
actions = {
  [b("x")] = function(ed, count, reg)
    local s = line(ed, ed.cy)
    if #s == 0 then return end
    local a, endb = ed.cx, ed.cx
    for _ = 1, (count or 1) do if endb <= #s then endb = disp.next_char(s, endb) end end
    set_reg(ed, reg, s:sub(a, endb - 1), false)
    ed.buf:set(ed.cy, s:sub(1, a - 1) .. s:sub(endb))
    ed.changed = true
    clamp(ed)
  end,
  [b("r")] = function(ed, count)
    local ch = string.char(getkey(ed))
    local s, a, n = line(ed, ed.cy), ed.cx, (count or 1)
    local endb, k = a, 0
    while k < n and endb <= #s do endb = disp.next_char(s, endb); k = k + 1 end
    if k < n then return end                       -- not enough chars on the line
    ed.buf:set(ed.cy, s:sub(1, a - 1) .. string.rep(ch, n) .. s:sub(endb))
    ed.cx = a + n - 1
    ed.changed = true
  end,
  [b("p")] = function(ed, _, reg) do_put(ed, true, reg) end,
  [b("P")] = function(ed, _, reg) do_put(ed, false, reg) end,
  [b("m")] = function(ed) -- m{mark}: set a mark at the cursor
    ed.marks = ed.marks or {}
    ed.marks[string.char(getkey(ed))] = { ed.cy, ed.cx }
  end,
  [b("u")] = function(ed)
    local l = ed.buf:undo()
    if l then ed.cy, ed.cx = l, 1; clamp(ed) else ed.message = "Already at oldest change" end
  end,
  [18] = function(ed) -- Ctrl-R: redo
    local l = ed.buf:redo()
    if l then ed.cy, ed.cx = l, 1; clamp(ed) else ed.message = "Already at newest change" end
  end,
  -- q{reg} starts recording keys into a register; q again stops. Recording
  -- reuses getkey's capture; the trailing 'q' that stops it is dropped. A macro
  -- is just register text, so a yanked register can be run as one too (like vi).
  [b("q")] = function(ed)
    if ed.recording then
      table.remove(ed.macro_buf) -- drop the trailing 'q' that triggered the stop
      local chars = {}
      for i = 1, #ed.macro_buf do chars[i] = string.char(ed.macro_buf[i]) end
      ed.regs[ed.recording] = { text = table.concat(chars), linewise = false }
      ed.recording, ed.macro_buf = nil, nil
    else
      ed.recording = string.char(getkey(ed))
      ed.macro_buf = {}
    end
  end,
  -- @{reg} replays a register's keys (count times); @@ replays the last one.
  [b("@")] = function(ed, count)
    local rc = getkey(ed)
    local reg = (rc == b("@")) and ed.last_macro or string.char(rc)
    if not reg then return end
    local r = ed.regs[reg]
    if not r or r.text == "" then return end
    ed.last_macro = reg
    local merged = {}
    for _ = 1, (count or 1) do
      for i = 1, #r.text do merged[#merged + 1] = r.text:byte(i) end
    end
    for i = 1, #ed.inject do merged[#merged + 1] = ed.inject[i] end
    ed.inject = merged
  end,
  [b("i")] = function(ed) insert_mode(ed) end,
  [b("a")] = function(ed)
    if #line(ed, ed.cy) > 0 then ed.cx = ed.cx + 1 end
    insert_mode(ed)
  end,
  [b("A")] = function(ed) ed.cx = #line(ed, ed.cy) + 1; insert_mode(ed) end,
  [b("I")] = function(ed) ed.cx = first_nonblank(line(ed, ed.cy)); insert_mode(ed) end,
  [b("o")] = function(ed) ed.buf:insert(ed.cy + 1, { "" }); ed.cy = ed.cy + 1; ed.cx = 1; insert_mode(ed) end,
  [b("O")] = function(ed) ed.buf:insert(ed.cy, { "" }); ed.cx = 1; insert_mode(ed) end,
  -- '.' repeats the last change by replaying its recorded keys: prepend them to
  -- the funnel so they run as the next command(s). '.' itself makes no change,
  -- so it never overwrites last_change (no recursion).
  [b(".")] = function(ed)
    if not ed.last_change then return end
    local merged = {}
    for i = 1, #ed.last_change do merged[#merged + 1] = ed.last_change[i] end
    for i = 1, #ed.inject do merged[#merged + 1] = ed.inject[i] end
    ed.inject = merged
  end,
  [b(":")] = function(ed)
    ed.mode = "command"; ed.cmdline = ""
    while true do
      local k = getkey(ed)
      if k == 13 or k == 10 then
        local cmd = ed.cmdline
        ed.mode = "normal"; ed.cmdline = ""
        local payload, status = ex.dispatch(ed, cmd)
        if status == "err" or (payload and payload ~= "") then
          ed.message = payload:gsub("\n", " ")
        end
        return
      elseif k == 27 then ed.mode = "normal"; ed.cmdline = ""; return
      elseif k == 127 or k == 8 then
        if #ed.cmdline == 0 then ed.mode = "normal"; return end
        ed.cmdline = ed.cmdline:sub(1, -2)
      elseif k >= 32 and k < 127 then ed.cmdline = ed.cmdline .. string.char(k) end
    end
  end,
}

local operators = { [b("d")] = "d", [b("c")] = "c", [b("y")] = "y" }

-- ---- the command loop -------------------------------------------------------
local function command(ed)
  ed.buf:undo_checkpoint() -- one undo reverts one user-level command
  ed.keylog = {}
  ed.changed = false
  ed.message = nil
  local reg
  local k = getkey(ed)
  if k == b('"') then reg = string.char(getkey(ed)); k = getkey(ed) end
  local count1
  count1, k = read_count(ed, k)
  local op = operators[k]
  if op then
    local k2 = getkey(ed)
    local count2
    count2, k2 = read_count(ed, k2)
    local total = combine(count1, count2)
    if k2 == k then -- dd / yy / cc
      op_lines(ed, op, ed.cy, ed.cy + (total or 1) - 1, reg)
    else
      local m = motions[k2]
      if m then apply_operator(ed, op, m, total, reg) end
    end
  elseif motions[k] then
    do_motion(ed, motions[k], count1)
  elseif actions[k] then
    actions[k](ed, count1, reg)
  end
end

-- The coroutine body: parse commands forever. Quit is the driver noticing
-- ed.running == false; this loop never has to return.
function M.loop(ed)
  while true do
    command(ed)
    if ed.changed then
      ed.last_change = {}
      for i = 1, #ed.keylog do ed.last_change[i] = ed.keylog[i] end
    end
  end
end

return M
