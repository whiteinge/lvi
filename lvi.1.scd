lvi(1)

; EDITING TRAP: never let a wrapped continuation line start with `-` -- scdoc
; parses it as a list entry and the build breaks ("Expected space before start
; of list entry"). Rewrap so `--` sits mid-line or at a line's end. Check your
; work with `scdoc < lvi.1.scd > /dev/null`.

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
	Jump to mark _m_ (exact position / first non-blank of its line). The mark
	*`.* is set automatically to the position of your last change, so *`.*
	returns to where you were typing. (*contrib/lvi-pos* adds a cross-session
	*`"* -- where you last were when the file was closed.)

*Ctrl-O* *Ctrl-I*
	Go to an older / newer position in the jumplist -- a per-buffer rolling
	record of where each _jump-class_ motion left from. A jump is any motion
	that can move far: *G*, *%*, the mark jumps (*`* *'*), paragraph/section
	(*{* *}* *[[* *]]*), sentence (*(* *)*), and the screen positions (*H* *M*
	*L*). Plain moves (*h j k l*, *w*, *f*) are not jumps. *Ctrl-I* is *Tab*.

## Operators and edits

*d* *c* *y*
	Delete, change, yank over a motion (e.g. *dw*, *c$*, *y`a*). Doubled
	(*dd* *cc* *yy*) they act on whole lines.

*>* *<*
	Shift lines right/left by one *shiftwidth* (see *set*). Always linewise,
	even over a charwise motion; doubled (*>>* *<<*) they shift the current
	line.

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

*Ctrl-N*, *Ctrl-P*
	Complete the word before the cursor. Both run the command registered with
	*on complete* (nothing happens if none is), handing it the token and every
	open buffer's text and splicing its choice in; *contrib/lvi-complete* is the
	shipped completer (a fuzzy pick of the buffers' words). *Ctrl-N*/*Ctrl-P*
	pass a forward/backward hint the completer may use.

# EX COMMANDS

Typed at the *:* prompt and sent over the socket alike -- the same dispatcher
serves both. A leading address or _a_,_b_ range may precede a command; atoms are
a line number, *.* (current), *$* (last), and *%* (whole buffer). A bare address
moves the cursor to that line.

Any command lvi does not implement itself is delegated to the system *ex*(1)
(override with *$LVI_EX*) -- that is where *s*, *g*, *m*, *t*, *j* and full
address syntax come from. The command names documented in this section are the
ones lvi OWNS: for these, lvi's semantics apply, shadowing ex's command of the
same name (lvi's *d* is not ex's *d*). A future lvi release may claim further
names; a script that must have the system ex's reading of a line regardless
should pin it with *sysex*.

In any command that names a _file_ (*e*, *w*, *wq*, *x*, *r*), an argument
containing one of *~ { [ \* ? $ " ' ` \\* is expanded by the shell, as POSIX ex
specifies: lvi hands it to the shell to expand and reprint, so tilde,
variables, and globs mean exactly what *sh*(1) says. The cursor context is in
that shell's environment, so *:w $LVI_FILE.bak* and *:w ${LVI_FILE%.md}.html*
work -- lvi's substitute for ex's *%* and *#* (see *ENVIRONMENT*). The
expansion must yield exactly one name; the reprint is one word per line
(*printf '%s\\n'* rather than the spec's *echo*, whose XSI backslash handling
would mangle names), so quoting protects whitespace -- *:w "foo bar.txt"*
works. And it is the shell: *:w $(cmd)* executes _cmd_ -- the same power *!*
already grants, but a script splicing picked names into a command line must
backslash-escape the metacharacters (as _contrib/lvi-open_ and
_contrib/lvi-shell.sh_ do).

*w*[*!*] [_file_], *wq*, *x*
	Write (to _file_ or the current path); write and quit; write and quit but
	only if the buffer is modified (so *x* leaves an unchanged file's timestamp
	untouched). *ZZ* is *x*. If the file on disk changed since lvi last read or
	wrote it (another writer), the write is refused; *w!* overrides. During the
	write the full new text sits in a sibling _file.lvi~_ safety copy, removed
	when the write completes -- a surviving _.lvi~_ means the write was cut
	short and holds the intended contents.

*wa*[*!*], *xa*[*!*]
	Write every modified buffer to its own path (*wa*, alias *wall*), or write
	them all and then quit (*xa*, aliases *xall* *wqa* *wqall*). Changed-only,
	like *x*: a clean buffer's file is left untouched. A modified buffer with no
	name, or a file changed on disk since last read (see *w!*), is an error and
	no quit happens; *!* forces past changed-on-disk files.

*wbuf*
	Snapshot the live buffer (unsaved edits and all) to *$LVI_BUFFER*, a per-view
	scratch file in the child environment. Leaves the buffer's own file and
	modified state untouched -- it just hands the current text to a child. The
	companion to *silent !* for a tool that needs both the terminal and the live
	buffer; see *Shelling out* below and *contrib/lvi-tags*.

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

*sh*
	Run an interactive shell (*$SHELL*, else *sh*; alias *shell*); exit it to
	return to the editor. Because the view's id is in the environment, this
	doubles as the path-completion escape hatch: build a path with your shell's
	own completion and history, queue a write for the editor you came from --
	*lvi -w "$LVI_WID" -d -- "w $PWD/notes.txt"* -- and *exit*; it executes
	the moment you return. The *-d* (detach) matters: like every terminal
	shell-out, *sh* freezes the event loop while it runs, so a synchronous
	*lvi -w* would sit waiting on an editor that answers only after you exit.

*bg* _cmd_
	Run a shell _cmd_ detached, output discarded, WITHOUT handing over the
	terminal -- so, unlike *!*/*silent !*, no alt-screen flash. For
	non-interactive tools driven by a map that may fire repeatedly (e.g.
	*map n :bg lvi-list next<CR>*); a _cmd_ needing the tty must use *!*.

*normal* _keys_
	Feed _keys_ as normal-mode keystrokes -- the escape hatch that gives the
	socket full editing power (e.g. *normal 2dw*). Over the socket, _keys_
	run immediately only when the interpreter is parked between commands; if
	they arrive mid-command (an operator awaiting its motion, insert mode, a
	prompt) they are held and replayed at the next command boundary, so a
	background tool can never turn a half-typed *d* into *dG*.

*u*, *redo*
	Undo, redo.

*set* _option_...
	Set options: *wrap*/*nowrap* (and *wrap!* to toggle, *wrap?* to query),
	*tabstop*=_N_ (alias *ts*), *shiftwidth*=_N_ (alias *sw*, the *>>*/*<<*
	indent step), and *expandtab*/*noexpandtab* (alias *et*/*noet*; whether
	*>>* indents with spaces or tabs). Numeric options answer *?*; *expandtab*
	also toggles with *!*.

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
	highlighting), *write* (after a successful *w*/*wq*/*x*), *scroll* (a keyboard
	action moved the viewport top -- fired at once, undebounced, with the new top
	line in *LVI_TOP*; the seam an external tool uses to mirror one view's scroll
	onto another, see *contrib/lvi-diff*), *ready* (once at startup, socket live
	and rc loaded -- the analog of vim's *VimEnter*, e.g. to load a *-q* list), or
	*bufenter*/*bufleave*/*bufdelete* (buffer switches, with that buffer's path in
	*LVI_FILE* -- the glue for repainting per-buffer list overlays; see
	*contrib/lvi-list*). *complete* is special: not auto-fired but run
	synchronously by insert-mode *Ctrl-N*/*Ctrl-P* (above), and is a single
	completer that replaces on re-register instead of composing. Socket-driven
	changes never fire *change*/*scroll* (only keyboard input does), so a hook's
	own edits or a scroll pushed onto a view can't loop back.

*fire* [_event_]
	Raise _event_ (default *change*) by hand. Because socket-driven edits never
	fire *change* (the anti-loop gate above), a tool that edits over the
	socket -- a formatter, a diff-hunk applier -- leaves *change* consumers
	such as live highlighting stale until the next keystroke; sending *fire*
	after its edits is the explicit opt-in. *change* rides the normal idle
	debounce; any other event runs its hooks immediately.

*status* _name_ [_text_]
	Set (or clear, if _text_ is empty) a named segment shown in the status line;
	segments render in _name_ order. Generic -- an external tool drives it (a
	list's *[3/57]* counter, a git branch), the way *hl* drives highlights.

*f*, *pos*, *echo* _text_, *silent* _cmd_
	Show the file name and line count; report the cursor as _line_<TAB>_col_;
	echo _text_; run _cmd_ suppressing its interactive prompt.

*sysex* _ex-line_
	Hand _ex-line_ to the system *ex*(1) verbatim, bypassing lvi's own command
	table -- the pin for scripts that need ex's semantics for a name lvi also
	owns (e.g. *sysex 2d* is ex's delete with ex's addressing), immune to lvi
	claiming more names later. Same limits as all delegation: output is
	discarded, and a failing command is a safe no-op.

## Shelling out -- which verb

```
COMMAND        TERMINAL   LVI BLOCKED   typical use
!cmd           yes        yes           run and watch it (:!make, :!git log)
[range]!cmd    yes        yes           filter lines through cmd (:%!sort)
sh             yes        yes           a full shell; exit to return
bg cmd         no         no            detached; drives the view back as it runs

silent !cmd    yes        yes           like !, for a picker -- output dropped
wbuf           --         --            snapshot the buffer for a picker to read
```

(*wbuf* is not a shell-out -- it prepares the buffer for one, hence the dashes.)

Two questions pick the verb. First: does it need the terminal -- a prompt, a
picker (fzf), a pager, or you just want to watch its output? Then *!*, or
*silent !* when it is a picker whose choice matters and not its output; either
way lvi is blocked until it exits. Second: does it instead reach back to change
the view as it runs -- move the cursor, set a highlight, update a list? Then
*bg*, which never blocks (so those updates land at once, with no full-screen
flash) but gets no terminal.

When it needs both at once -- an interactive picker built from your *unsaved*
text (see *contrib/lvi-tags*) -- the terminal verbs block lvi, so the tool
cannot ask for the buffer back. Snapshot it to a file first, then let the
blocked tool read the file:

	map \t :wbuf<CR>:silent !lvi-tags<CR>

*wbuf* writes the live buffer (unsaved edits and all) to *$LVI_BUFFER*, a
scratch path in the tool's environment.

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
launched from *:!* -- or you, from a *:sh* shell -- can drive the same view back
(see *contrib/lvi-open*).

On the wire, a connection carries newline-delimited command lines; responses
come back length-framed and binary-safe (so *%p* output can never corrupt the
stream). A client may upgrade the connection by sending the *%hello 1*
handshake, after which *%cmd <N>* followed by _N_ raw bytes carries one command
that may itself contain newlines -- how *lvi -w* sends e.g. a multi-line
*normal* insertion. Bare lines stay valid forever, handshake or not, so
_echo ':w' > $LVI_SOCK_ keeps working. The full grammar is specified in
_proto.lua_.

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
  (the vim *-q* format), file-backed and steppable; any number coexist, one is
  _focused_, and the bare step keys act on it.
- *lvi-gitchanges* -- step the current file's *git diff* hunks with *n*/*N*.
- *lvi-lint* -- lint the live buffer into a steppable list, on demand or on
  every *:w* (ruff, shellcheck, *deno lint* ship; one small adapter per tool).
- *lvi-spell* -- toggleable spell check: misspelled words marked in place and
  steppable, with a *z=* suggestion picker and *zg* dictionary add.
- *lvi-fmt* -- run the file's formatter (ruff format, gofmt, *deno fmt*, ...)
  over the live buffer and splice back only the changed window: the cursor
  stays put, one undo reverts it, already-formatted is a no-op.
- *lvi-open* -- fuzzy-pick a file and open it in the running view.
- *lvi-shell.sh* -- functions to source in your shell rc (*lvi-saveas*,
  *lvi-e*, *lvi-r*): drive the running view from *sh* or any terminal, with
  your shell's own path completion.
- *lvi-tags* -- fuzzy-pick / outline the current file's ctags tags and jump.
- *lvi-complete* -- insert-mode word completion from the open buffers
  (*on complete lvi-complete*).
- *lvi-pos* -- remember your position in each file across sessions (viminfo's
  *`"*), as a plain-text store driven by *on* hooks.
- *lvi-diff* / *lvi-stagediff* -- a two-way vimdiff of two panes (highlight,
  scrollbind, move hunks with *\\p*/*\\o*, jump with *]c*/*[c*) and, atop it,
  *git add -p* as a side-by-side diff you stage from with *\\s*.

This is only a taste. For what each tool does, its configuration, and
ready-to-copy bindings and themes, see *contrib/README.md* and
*contrib/lvirc.sample* -- and the header comment of each script for its full
reference.

# ENVIRONMENT

*LVIRC*, *XDG_CONFIG_HOME*
	Locate the rc file (see *CONFIGURATION*).

*LVI_WID*, *LVI_SOCK*, *LVI_BUFFER*
	The current view's id, socket path, and *wbuf* scratch path, exported to
	child processes (static for the life of the view). *LVI_BUFFER* names where
	*:wbuf* snapshots the live buffer for a *silent !* tool to read (see
	*Shelling out* under *EX COMMANDS*).

*LVI_QUICKFIX*
	The _errorfile_ given with *-q*, exported for the *ready* hook to load (see
	*-q*). Unset when *-q* was not given.

*LVI_FILE*, *LVI_LINE*, *LVI_COL*, *LVI_TOP*, *LVI_CWORD*
	The cursor's world -- current file path, 1-based line and byte column,
	viewport top line (*LVI_TOP*, for *on scroll*), and the word under the
	cursor -- refreshed into the environment before every shell-out (*:!*
	commands and *:on* hooks). A command can read them inline with no wrapper,
	and a POSIX shell slices them further, e.g.
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

_file.lvi~_
	Transient safety copy of the new text during a write (see *w*). Present
	only while a write is in flight -- or after one that failed part-way, in
	which case it holds the complete text the write intended.

_file.lvi-recover_
	Crash salvage: if the editor dies from an internal error, every modified
	buffer is dumped beside its file (nameless buffers land beside the socket)
	and the paths are reported on stderr.

# EXIT STATUS

In client mode (*-w*), the exit status is non-zero if any sent command failed.

# SEE ALSO

*ex*(1), *vi*(1), *scdoc*(5)

# AUTHORS

Maintained by Seth House. lvi is a personal project exploring vi as a socket-
driven, composable Unix tool.
