lvi(1)

# NAME

lvi - a minimal, POSIX-vi-style modal editor with a control socket

# SYNOPSIS

*lvi* [*-q* _errorfile_] [_file_...]++
*lvi* *-w* _wid_ [*-d*] *--* _command_...++
*lvi* *-l*

# DESCRIPTION

*lvi* is a small modal text editor in the spirit of "UNIX as IDE": rather than
growing features inward, it stays lean and leans on the command-line tools you
already have. Its one deliberate deviation from POSIX vi is a per-view *control
socket*, so any program -- a shell script, a Makefile, a linter -- can drive a
running editor and read back its state.

It runs on LuaJIT alone: no compiler, no build step, and no C dependency to
install, on Linux, macOS, BSD, and WSL.

Invoked with file arguments (or none), *lvi* starts the interactive editor; the
first file becomes the current buffer. Invoked with *-w* it is instead a client
that sends ex commands to an already-running view (see *THE CONTROL SOCKET*).

# OPTIONS

*-w*, *--wid* _wid_
	Client mode: send the ex commands given after *--* to the view whose id is
	_wid_. The special id *auto* selects the sole running view. Payloads print
	to standard output, errors to standard error.

*-d*, *--detach*
	Client mode: send without waiting for replies (fire-and-forget). Use this
	when a command driven from inside the same editor would otherwise deadlock
	the single-threaded loop.

*-l*, *--list*
	List running views as _wid_<TAB>_socket-path_, one per line, and exit.

*-q*, *--quickfix* _errorfile_
	Editor mode: export _errorfile_ as *LVI_QUICKFIX* and fire the *ready* event
	at startup (see *on*). *lvi* itself does nothing more with it -- the core has
	no list machinery. An rc hook turns it into a loaded quickfix list; the one
	in *contrib/lvirc.sample* runs *lvi-list load "$LVI_QUICKFIX" quickfix* when
	*LVI_QUICKFIX* is set (see *contrib/lvi-list*). _errorfile_ is not opened as a
	buffer.

# NORMAL MODE

Commands are literal characters (POSIX vi specifies no arrow keys). Most accept a
leading count, e.g. *3dw*.

## Motions

*h* *j* *k* *l*
	Left, down, up, right (character- and line-wise).

*0* *^* *$*
	First column, first non-blank, end of line.

*w* *b* *e*
	Next word, previous word, end of word (cross line boundaries).

*f*_x_ *t*_x_ *F*_x_ *T*_x_ *;* *,*
	Find _x_ forward/backward on the line; *;* and *,* repeat it.

*G* *gg*
	Last line, first line (or line _count_ with a count).

*gj* *gk*
	Down/up one screen row (within a wrapped line).

*N|*
	Go to display column _N_.

*`*_m_ *'*_m_
	Jump to mark _m_ (exact position / first non-blank of its line).

## Operators and edits

*d* *c* *y*
	Delete, change, yank over a motion (e.g. *dw*, *c$*, *y`a*). Doubled
	(*dd* *cc* *yy*) they act on whole lines.

*x* *r*_x_ *p* *P*
	Delete character, replace character with _x_, put after/before.

*i* *a* *A* *I* *o* *O*
	Enter insert mode: before/after cursor, end/first-non-blank of line, open
	line below/above.

*m*_m_
	Set mark _m_ at the cursor.

*u* *Ctrl-R*
	Undo, redo (multi-level).

*.*
	Repeat the last change.

*q*_r_ *@*_r_ *@@*
	Record keystrokes into register _r_ until *q*; replay register _r_; replay
	the last replayed register.

## Registers

Registers *a*-*z* and the unnamed register (") hold deletes and yanks. A macro is
just register text, so a yanked register can be replayed with *@*.

## Scrolling

*Ctrl-F* *Ctrl-B*
	Forward/backward one page.

*Ctrl-D* *Ctrl-U*
	Down/up half a page (a count sets the scroll size).

*Ctrl-E* *Ctrl-Y*
	Scroll one line down/up, keeping the cursor in view.

*z*_CR_ *z.* *z-*
	Reposition the window so the current line (or line _count_) sits at the top,
	center, or bottom, moving the cursor to that line's first non-blank.

*zt* *zz* *zb*
	Like *z*_CR_ / *z.* / *z-*, but leave the cursor in its current column.

## Other

*:*
	Begin an ex command (see *EX COMMANDS*).

*Ctrl-^*
	Switch to the alternate buffer -- the one edited before the current (same as
	*:b #*).

*ZZ* *ZQ*
	Write (if modified) and quit; quit without writing. Same as *:x* and *:q!*.

*Ctrl-Z*
	Suspend the editor to the shell (resume with fg).

# INSERT MODE

Typed characters are inserted; *Esc* returns to normal mode. Line editing:

*Ctrl-H*, Backspace
	Erase the character before the cursor.

*Ctrl-W*
	Erase the word before the cursor.

*Ctrl-U*
	Erase from the cursor to the start of the line.

*Ctrl-A*, *Ctrl-E*
	Move to the start / end of the line (a readline convenience; not POSIX vi).

# EX COMMANDS

Typed at the *:* prompt and sent over the socket alike -- the same dispatcher
serves both. A leading address or _a_,_b_ range may precede a command; atoms are
a line number, *.* (current), *$* (last), and *%* (whole buffer). A bare address
moves the cursor to that line.

*w* [_file_], *wq*, *x*
	Write (to _file_ or the current path); write and quit; write and quit but
	only if the buffer is modified (so *x* leaves an unchanged file's timestamp
	untouched). *ZZ* is *x*.

*q*, *q!*, *qa*[*!*]
	Quit (current view / all views); *!* discards unsaved changes.

*cq* [_N_]
	Quit unconditionally (discarding changes) and exit with a non-zero status
	(_N_, default 1). Lets a script driving lvi as its editor -- *git commit*,
	and the like -- signal "abort": a non-zero editor cancels the operation.

*e*[*!*] [_file_|*#*]
	Edit _file_, reload the current one (no argument), or switch to the alternate
	buffer (*#*).

*bn*, *bp*, *b* {_N_|_name_|*#*}, *ls*, *bd*[*!*]
	Next/previous buffer, switch to buffer _N_, by name, or the alternate (*#*),
	list buffers, delete the current buffer.

*d*, *p*
	Delete, print the addressed lines.

*r* {_file_|*!*_cmd_}
	Read a file, or the output of a shell _cmd_, after the addressed line.

\[_range_]*!*_cmd_
	Filter the range through shell _cmd_, replacing it with the output.

*!*_cmd_
	Run a shell _cmd_ with the terminal (interactive programs work). The
	cursor's context is in the environment (*LVI_FILE*/*LINE*/*COL*/*CWORD*; see
	*ENVIRONMENT*), so e.g. *!grep -n "$LVI_CWORD" "$LVI_FILE"*.

*bg* _cmd_
	Run a shell _cmd_ detached, output discarded, WITHOUT handing over the
	terminal -- so, unlike *!*/*silent !*, no alt-screen flash. For
	non-interactive tools driven by a map that may fire repeatedly (e.g.
	*map n :bg lvi-list next<CR>*); a _cmd_ needing the tty must use *!*.

*normal* _keys_
	Feed _keys_ as normal-mode keystrokes -- the escape hatch that gives the
	socket full editing power (e.g. *normal 2dw*).

*u*, *redo*
	Undo, redo.

*set* _option_...
	Set options: *wrap*/*nowrap* (and *wrap!* to toggle, *wrap?* to query),
	*tabstop*=_N_ (alias *ts*).

*map* _lhs_ _rhs_, *unmap* _lhs_
	Map/unmap keys. Notation: *<CR>* *<Esc>* *<Space>* *<Tab>* *<Bar>*
	*<Bslash>* *<lt>* and *<C-x>* for control keys.

*hl* _group_ [_L_:_C1_-_C2_ ...]
	Paint _group_ over the given byte ranges (bare _L_ = whole line); no ranges
	clears it. The overlay external search and syntax highlighting build on.

*hi* _group_ [_spec_...]
	Give _group_ a color. _spec_ is *fg*=_color_, *bg*=_color_ (an 8-color name
	or a 0-255 index), attributes *bold* *dim* *italic* *underline* *reverse*,
	*sgr*=_params_ (raw SGR), or *pri*=_N_. No spec renders the group as plain
	text. *pri* sets the group's z-order (default 0): where two groups cover the
	same cell the higher _pri_ draws on top, so an overlay that must show through
	syntax highlighting (which sits at 0) sets a positive _pri_ -- search uses 10.

*nohl*
	Clear all highlight ranges (styles set by *hi* persist).

*on* _event_ [_cmd_]
	Run shell _cmd_ when _event_ fires (debounced/non-blocking); no _cmd_ clears
	that event's hooks. _event_ is *change* (a keyboard edit settled -- for live
	highlighting), *ready* (once at startup, socket live and rc loaded -- the
	analog of vim's *VimEnter*, e.g. to load a *-q* list), or
	*bufenter*/*bufleave*/*bufdelete* (buffer switches, with that buffer's path in
	*LVI_FILE* -- the glue for repainting per-buffer list overlays; see
	*contrib/lvi-list*).

*status* _name_ [_text_]
	Set (or clear, if _text_ is empty) a named segment shown in the status line;
	segments render in _name_ order. Generic -- an external tool drives it (a
	list's *[3/57]* counter, a git branch), the way *hl* drives highlights.

*f*, *pos*, *echo* _text_, *silent* _cmd_
	Show the file name and line count; report the cursor as _line_<TAB>_col_;
	echo _text_; run _cmd_ suppressing its interactive prompt.

# THE CONTROL SOCKET

Each view listens on a Unix-domain socket; the path itself is the selector, so
one view is addressed with no protocol beyond writing to it. *lvi -w* is the
bundled client and behaves as an ordinary Unix filter -- ok payloads to standard
output, errors to standard error, a non-zero exit if any command failed:

```
lvi -l                              # list views: <wid>  <socket>
lvi -w auto -- '%p' | gofmt         # pipe the live buffer through a tool
lvi -w auto -- 'normal ggdG'        # drive it with keystrokes
```

Over the socket, ex commands are sent *without* the leading colon. A running
editor exports *LVI_WID* and *LVI_SOCK* into its child environment, so a program
launched from *:!* can drive the same view back (see *contrib/lvi-open*).

# CONFIGURATION

At startup *lvi* reads an rc file -- simply a file of ex commands, one per line,
run through the same dispatcher; there is no separate configuration language. A
*"* begins a comment when it stands alone -- at the start of a line, or mid-line
with whitespace on both sides -- so a *"* inside a command (a register like
_"ayy_, a _/"/_ search, an _:echo "text"_) is left intact. The first rc file that
exists is used:

- *$LVIRC* (an empty value or *NONE* disables the rc file)
- *$XDG_CONFIG_HOME/lvi/lvirc* (default _~/.config/lvi/lvirc_)
- _~/.lvirc_

So *map* and *set* persist by putting them in the rc file; a color theme is a set
of *hi* lines, and live syntax highlighting is one *on change* line. See
*contrib/README.md* and *contrib/lvirc.sample*.

# TURNING ON THE IDE

Much of what feels built into other editors is, in *lvi*, a small external
program that drives the view over the socket -- so it lives *outside* the core
and you switch it on from the rc file. No language engine, search engine, or
quickfix machinery lives in *lvi* itself. The headliners that ship in _contrib_:

- *lvi-highlight* -- syntax highlighting via an external highlighter (Pygments or
  bat); turn it on with *on change lvi-highlight*.
- *lvi-search* -- grep the live (unsaved) buffer and step matches with *n*/*N*.
- *lvi-list* -- quickfix/location lists from any grep/compiler/linter output
  (the vim *-q* format), file-backed and steppable.
- *lvi-gitchanges* -- step the current file's *git diff* hunks with *n*/*N*.
- *lvi-open* -- fuzzy-pick a file and open it in the running view.

This is only a taste. For what each tool does, its configuration, and
ready-to-copy bindings and themes, see *contrib/README.md* and
*contrib/lvirc.sample* -- and the header comment of each script for its full
reference.

# ENVIRONMENT

*LVIRC*, *XDG_CONFIG_HOME*
	Locate the rc file (see *CONFIGURATION*).

*LVI_WID*, *LVI_SOCK*
	The current view's id and socket path, exported to child processes (static
	for the life of the view).

*LVI_QUICKFIX*
	The _errorfile_ given with *-q*, exported for the *ready* hook to load (see
	*-q*). Unset when *-q* was not given.

*LVI_FILE*, *LVI_LINE*, *LVI_COL*, *LVI_CWORD*
	The cursor's world -- current file path, 1-based line and byte column, and
	the word under the cursor -- refreshed into the environment before every
	shell-out (*:!* commands and *:on* hooks). A command can read them inline
	with no wrapper, and a POSIX shell slices them further, e.g.
	*:!ctags* _--_ *"${LVI_FILE%/\*}"* for the directory or *"${LVI_FILE##\*/}"*
	for the basename. *LVI_CWORD* uses the same word definition as *w*/*b*/*e*
	and is empty when the cursor is not on a word character.

*XDG_RUNTIME_DIR*, *TMPDIR*
	Preferred locations for the socket directory (else _/tmp_).

*LVI_HL_BACKEND*, *LVI_HL_MAXBYTES*, *BAT_THEME*, *LVI_PICKER*, ...
	Knobs for the _contrib_ tools; each script's header comment documents its
	own. See *contrib/README.md*.

# FILES

_~/.lvirc_, _$XDG_CONFIG_HOME/lvi/lvirc_
	The rc file.

_$XDG_RUNTIME_DIR/lvi-$uid/$wid_
	A view's control socket.

# EXIT STATUS

In client mode (*-w*), the exit status is non-zero if any sent command failed.

# SEE ALSO

*ex*(1), *vi*(1), *scdoc*(5)

# AUTHORS

Maintained by Seth House. lvi is a personal project exploring vi as a socket-
driven, composable Unix tool.
