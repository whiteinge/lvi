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

_operator_*i*_object_, _operator_*a*_object_
	Text objects: in place of a motion an operator may take an _object_ around
	the cursor, with *i* for the inner object and *a* for the "a"/around form
	(delimiters, or a trailing blank, included). Objects are *w* *W*
	(word/WORD), *p* (paragraph, linewise), the bracket pairs *(* *)* *b* and
	*{* *}* *B* and *[* *]* and *<* *>*, and the quoted strings *"* *'* *`*
	(single-line). So *diw* deletes a word, *ci(* changes inside the
	parentheses, *ya"* yanks a string with its quotes, and *dap* deletes a
	paragraph. Unlike a motion, an object does not depend on where within it the
	cursor sits. This is a vi extension; with no visual mode an object is
	meaningful only after an operator.

*>* *<*
	Shift lines right/left by one *shiftwidth* (see *set*). Always linewise,
	even over a charwise motion; doubled (*>>* *<<*) they shift the current
	line.

*gu* *gU* *g~*
	Lowercase, uppercase, toggle case over a motion or text object (*guiw*,
	*gU$*, *g~ip*); doubled (*guu* *gUU* *g~~*) they act on the current line.

*!*
	Filter the lines a motion spans through a shell command: *!*_motion_ opens
	the *:* prompt seeded with the address range and a *!*, so you type the
	command and press Enter (*!ip sort*, *!G column -t*); *!!* filters the
	current line. It rides ex's *:*_range_*!*_cmd_ delegation. This is the
	normal-mode face of "UNIX as IDE": any range, any tool. It composes with
	text objects, so *!ap awk '{print NR". "$0}'* numbers a list -- the job you
	might reach for a visual block to do.

*gq*
	Reflow the lines a motion or text object spans by filtering them through
	the *fmtprg* option (default *fmt*(1), seeded from *$LVI_FMT*; see *set*).
	*gqq* reflows the current line. Just *!* with a fixed command, so *gqip*
	is *!ip fmt*.

*g@*
	Hand the span of a motion or text object to the external *operatorfunc*
	command (see *set*), spawned in the background as *:bg* does. Where *!* and
	*gq* filter the lines through a command and splice its output back, *g@*
	exports the span through the environment and lets the tool edit over the
	socket, so it can reach part of a line. *g@@* acts on the current line
	(*3g@@* on three). Nothing happens until *operatorfunc* is set; then it is
	the seam an external operator plugs into. This is the motion-driven sibling
	of *:*_range_*bg*: *contrib* ships *lvi-surround* and *lvi-comment* on it,
	and *lvi-stagediff* arms it for motion-scoped staging.

*x* *r*_x_ *p* *P*
	Delete character, replace character with _x_, put after/before.

*i* *a* *A* *I* *o* *O*
	Enter insert mode: before/after cursor, end/first-non-blank of line, open
	line below/above.

*m*_m_
	Set mark _m_ at the cursor. Marks are per-buffer; *:marks* lists them.

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

A delete or change with no named register also feeds the automatic delete
registers, as in vi: a whole-line or multi-line delete shifts the numbered stack
*"1* to *"9* down one and lands in *"1* (so *"1* is the most recent, *"2* the one
before it); a delete of less than a line goes to the small-delete register *"-*.
Naming a register (*"a*) leaves both untouched, and yanks never touch them.

A register may instead be backed by shell commands with *register* (below): a
yank or delete into it pipes the text out and a put reads fresh in. Backing *+*
with the system clipboard tools is the idiom, so *"+y* copies and *"+p* pastes.
Backing the unnamed register (") instead fires its *write* on every yank and
delete, since ") mirrors them all, giving an external history or clipboard tool
one capture point to hang off without remapping keys. In an rc file name it *""*
(doubled): a lone *"* there begins a comment, so *register "" write* _cmd_ backs
it without being truncated. *contrib/lvi-yankring* is built on exactly this.

*registers* (*reg*) lists every register and its contents (map it for a quick
glance, e.g. *map \\r :registers<CR>*).

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

## Folding

A fold collapses a range of lines to a single summary row (*+-- N lines: ...*);
the lines are only hidden, never altered, so *:w* and every ex command still see
the whole buffer. Folds are per-view and transient (they are not saved). *j*/*k*
and the scroll commands treat a closed fold as one row, so navigation skips its
interior; the cursor never rests on a hidden line (a motion or *`*_mark_ that
lands inside a closed fold snaps to its head). The summary row is themed by the
*Folded* highlight group when set (*:hi Folded fg=cyan italic*), otherwise it
draws as plain text.

Nothing folds automatically: lvi ships the fold *mechanism* only. A tool
computes *where* the folds go and pushes *:fold* over the socket, exactly as
external search feeds *:hl* -- see *contrib/lvi-fold* (by marker or by indent).

*zf*_motion_
	Create a closed fold over the lines the _motion_ spans (e.g. *zf3j*, *zfG*,
	*zf}*). Also available as *:fold* (see *EX COMMANDS*).

*zo* *zc* *za*
	Open, close, or toggle the innermost fold at the cursor.

*zd*
	Delete (remove) the fold at the cursor, leaving its lines unfolded.

*zR* *zM* *zE*
	Open all folds, close all folds, or eliminate every fold in the view.

*zj* *zk*
	Move to the start of the next fold, or the end of the previous fold.

## Other

*:*
	Begin an ex command (see *EX COMMANDS*). At the prompt, *Ctrl-P* and *Ctrl-N*
	step back and forward through command history, and *Ctrl-F* opens the command
	window (*:cmdwin*), carrying any half-typed line in. The prompt itself stays
	deliberately minimal (type and Backspace); reach for the command window when a
	command grows long enough to want real editing.

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
serves both. At the interactive *:* prompt, *Ctrl-P*/*Ctrl-N* step through
command history and *Ctrl-F* opens the command window; see the *:* command under
*NORMAL MODE*. A leading address or _a_,_b_ range may precede a command. An
address is a line number, *.* (current), *$* (last), or *'*_x_ (mark _x_), with
optional *+*_n_ / *-*_n_ offsets (a bare *+*/*-* is one line); *%* is shorthand
for *1,$*. Two addresses join with *,* or *;* (*;* reads the second relative to
the first). A bare address moves the cursor there. Addresses lvi cannot resolve
itself, notably */re/* search addresses, go to the system *ex* along with the
command.

Any command lvi does not implement itself is delegated to the system *ex*(1)
(override with *$LVI_EX*) -- that is where *s*, *g*, *m*, *t*, *j* and the rest of
the address grammar come from. The command names documented in this section are the
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

*cmdwin*
	Open the command window: a scratch buffer holding recent command history, one
	command per line, with the cursor on a blank last line. Edit any line with the
	full editor (motions, operators, undo, your own *:s*), then run the line under
	the cursor with a bare *:w*; *:bd* cancels without running anything. Only that
	bare *:w* is special (the buffer is otherwise ordinary), so *:w* _file_ still
	writes the list to disk. Also reachable with *Ctrl-F* at the *:* prompt.

*d* [_buffer_], *p*
	Delete or print the addressed lines. *d* saves the deleted lines to a
	register, like the *d* operator: the unnamed register (") always, plus
	_buffer_ when a single-letter name follows. (A mark or search address makes
	the line fall through to the system ex, whose registers lvi cannot see.)

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
	_contrib/lvi-shell.sh_ wraps that pattern in ready-made functions
	(*lvi-saveas*, and friends) and tags the shell prompt -- *(lvi foo.txt)* --
	so the parked editor is never forgotten.

\[_range_]*bg* _cmd_
	Run a shell _cmd_ detached, output discarded, WITHOUT handing over the
	terminal -- so, unlike *!*/*silent !*, no alt-screen flash. For
	non-interactive tools driven by a map that may fire repeatedly (e.g.
	*map n :bg lvi-list next<CR>*); a _cmd_ needing the tty must use *!*. A
	leading address range is resolved and exported as *LVI_LINE1*/*LVI_LINE2*
	(the non-mutating counterpart to the *!* filter), so a tool can act on a
	typed line span; without a range both are empty.

*normal* _keys_
	Feed _keys_ as normal-mode keystrokes -- the escape hatch that gives the
	socket full editing power (e.g. *normal 2dw*). With an address range
	(*:%normal A;*, *:2,5normal @a*) the keys run once per line, top to bottom
	(vi's line-wise order), each line positioned first and any open insert
	auto-closed at its end. Keys that add or delete lines are the caller's
	responsibility -- *:normal* is for per-line edits; use *:g*/*:d*/*:m* to
	change the line count. Trailing spaces are stripped from _keys_, so prefix a
	line via *:s* (*:%s/^/# /*) rather than *:normal I*. Over the socket, _keys_
	run immediately only when the interpreter is parked between commands; if
	they arrive mid-command (an operator awaiting its motion, insert mode, a
	prompt) they are held and replayed at the next command boundary, so a
	background tool can never turn a half-typed *d* into *dG*.

*u*, *redo*
	Undo, redo.

*set* _option_...
	Set editor options. A boolean toggles with a *!* suffix and reports with a
	*?* suffix (*set wrap!*, *set wrap?*); a numeric or string option takes
	*=*_value_ and reports with *?*. One *set* may list several options, except
	the space-bearing string options (*fmtprg*, *operatorfunc*), which take the
	rest of the line and want a *set* to themselves. The options:

	*wrap*, *nowrap*
		Soft-wrap long lines onto the next screen row, or truncate them at the
		right edge. Either way *lvi* draws buffer text from the left edge with
		no gutter: no line-number, sign, or fold column. *Ctrl-G* (or *:.=*)
		reports the current line, and the ruler carries line:column.
	*linebreak*, *nolinebreak* (*lbr*, *nolbr*)
		When wrapping, break at the last whitespace that fits instead of
		mid-word; a single word wider than the screen still breaks mid-word.
	*tabstop*=_N_ (*ts*)
		How many columns a literal tab renders as.
	*shiftwidth*=_N_ (*sw*)
		The indent step for *>>*/*<<* (and *>*/*<*).
	*expandtab*, *noexpandtab* (*et*, *noet*)
		Indent with spaces, one *shiftwidth*, instead of a tab for *>>* and the
		insert-mode *<Tab>* key; *tabstop* then only sets how wide a literal tab
		renders.
	*autoindent*, *noautoindent* (*ai*, *noai*)
		A new line from *o*/*O*/*<CR>* copies the current line's leading
		whitespace; a line left holding only that auto-indent is trimmed back to
		empty.
	*fmtprg*=_command_ (*fp*)
		The filter *gq* reflows through: default *fmt*(1), seeded from *$LVI_FMT*
		at startup but live-settable here, so *set fmtprg=fmt -w 72* rewraps at
		72. Point it at *lvi-reflow*(_contrib_) to reflow lists, marker and
		hanging indent kept.
	*operatorfunc*=_command_ (*opfunc*)
		The shell command *g@*_motion_ spawns over the span (empty by default,
		so *g@* is a no-op until set). Run detached like *:bg*, with the span in
		the environment: *$LVI_LINE1* and *$LVI_LINE2* (the line span, always),
		plus *$LVI_COL1*/*$LVI_COL2* (1-based byte columns, inclusive) and
		*$LVI_KIND* (*char* or *line*) for a charwise motion. The value runs
		through the shell, so quote a special character (*set opfunc=lvi-surround
		'('*). Usually bound: *map s( :set opfunc=lvi-surround paren<CR>g@*.
	*scratch*, *noscratch*
		Mark the current buffer ephemeral: it never counts as modified, so
		*q*/*bd* never nag, *wa* skips it, and a crash does not preserve it.
		Per-buffer, unlike the others (like a command window's buffer).

*map* _lhs_ _rhs_, *unmap* _lhs_
	Map/unmap keys. Notation: *<CR>* *<Esc>* *<Space>* *<Tab>* *<Bar>*
	*<Bslash>* *<lt>* and *<C-x>* for control keys. There is no wait-for-more
	timeout: a _lhs_ fires the instant it completes, so one mapping cannot be a
	prefix of another (map *gc* and *gcc* is unreachable) -- give the longer one
	a distinct key.

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

*fold*
	With an address range, create a closed fold over it (*:3,6fold*). With no
	range, _args_ may carry one or more _L1_,_L2_ specs
	(*:fold 1,2 5,7*) -- the form an external tool uses to push many folds in one
	command. Folds hide lines only in this view; the buffer is unchanged. See
	*Folding* in *NORMAL MODE* for the *z* keys.

*foldopen*, *foldclose*, *foldclear*
	Open every fold, close every fold, or remove all folds (the tool-facing
	spellings of *zR* / *zM* / *zE*).

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

*textobj* _key_ [_cmd_]
	Register a custom text object on the single character _key_, used after
	*i*/*a* in operator-pending mode (*di*_key_, *ca*_key_); no _cmd_
	unregisters it, and a builtin object of the same key always wins. _cmd_ is a
	filter lvi runs synchronously -- the same blocking discipline as a *s* sent
	to the system ex -- so the operator (including *c*, which enters insert
	mode) applies through the ordinary path, exactly like a builtin object. It
	is invoked *cmd TMPFILE i|a LINE COL* (buffer text in a private temp file,
	cursor 1-based in bytes) and prints one line: *char L1 C1 L2 C2* for a
	charwise inclusive byte range, *line L1 L2* for whole lines, or nothing for
	no object. *contrib/lvi-textobj-tag* implements HTML *it*/*at* this way,
	teaching lvi no HTML; see *contrib/README.md*.

*register* _name_ [*read* _cmd_] [*write* _cmd_]
	Back the single-character register _name_ with shell commands: a yank or
	delete into it also pipes the register text to the *write* command, and a put
	reads fresh from the *read* command instead of the in-memory copy. This is the
	system-clipboard seam -- *register + read wl-paste write wl-copy* (or
	*pbpaste*/*pbcopy*, or *xclip*) makes *"+y*/*"+p* copy and paste, and lvi
	learns nothing about clipboards: which command is pure config, and any
	register name may be backed. _name_ with no clause clears the backend; the two
	directions are independent, set on one line or two in either order (a later
	call merges them). Each command runs to the other keyword or end of line, so it
	may hold spaces and pipes. The shell-out is synchronous and tty-free (a
	clipboard tool returns instantly); a put of text carrying newlines pastes
	linewise.

*registers* [_names_], *reg*, *display*
	List registers and their contents, one line each as _type_ *"*_name_
	_value_: _type_ is *l* (linewise) or *c* (charwise), and a command-backed
	register (above) appends its *{read .., write ..}* spec so you can confirm
	the clipboard is wired. Control bytes show in caret notation (*^J* a newline,
	*^[* an escape), so a linewise register or a recorded macro stays on one
	line. With no argument every non-empty (or backed) register is listed --
	unnamed first, then _a_-_z_; give register names to restrict it (*reg a "*,
	each character one name). Multi-line output pages like *%p* at the *:*
	prompt, and is the read side of the register API over the socket. Note the
	split: *register* (singular) configures one register, *registers* (*reg*)
	displays them, as in *vi*.

*marks* [_names_]
	List marks, one line each as _mark_ _line_ _col_ _text_ (_text_ is the
	marked line with leading blanks stripped; _col_ is the 1-based byte column,
	as *pos* reports). No argument lists every set mark -- _a_-_z_, then the
	automatic *.* (last change) and any others (*m* accepts any character); give
	mark names to restrict it (*marks a .*). Marks are PER-BUFFER (bufs swaps
	them with the rest of the view state), so this lists the current buffer's
	set: lvi has no global or file marks, and even *mA* is buffer-local, so there
	is no file column. Multi-line output pages like *%p* at the prompt.

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

*f*, *pos* [_line_ [_col_]], *echo* _text_, *silent* _cmd_
	Show the file name and line count; with no argument report the cursor as
	_line_<TAB>_col_, or with arguments move it there (_col_ is a byte column,
	clamped into the buffer, and unlike a motion it leaves no jumplist entry);
	echo _text_; run _cmd_ suppressing its interactive prompt.

*msg* _text_, *msge* _text_
	Write _text_ to this view's one-line message (status line, left half).
	Unlike *echo*, which returns text to the caller (the human at the *:* prompt,
	or a socket tool in its response frame), *msg* always targets the human at
	this view -- a preview/notice channel a socket tool drives (e.g. a list
	surfacing the entry you stepped onto). *msge* is the error variant, styled by
	the *Error* group (*hi Error ...*); plain if unthemed. Newlines collapse; the
	message clears on the next normal-mode key.

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

# WITHOUT VISUAL MODE

lvi has no visual mode. Visual mode is selecting first then editing --
highlight a range, then act on it -- a new mode, on-screen state, and a
second set of keys to grow and shrink the highlight bring real complexity.
vi's model is simpler yet provides functional alternatives: an edit already
*is* an operator plus a range, stated in one gesture -- *d* with a motion or
text object. What follows maps the visual operations you know onto that model,
and onto the ex commands and the *!* filter that handle the multi-line and
column edits.

## In place of a character or line selection

*viwc*, *vt)d*
	*ciw*, *dt)*. Operator plus motion or text object; the word or span is found
	wherever the cursor sits (see the text-object list under NORMAL MODE).
*Vjj>*, *Vipd*
	*>ip* and *dip*, or a line count -- *3>>*, *3dd*. Doubled operators and
	linewise motions already act on whole lines.
*vipU*, *vipgq*
	*gUip*, *gqip*. The *gu*/*gU*/*g~* and *gq* operators take the same objects.
*vip!sort*
	*!ip sort*. The *!* filter pipes the object's lines through any command.

## Naming the range first

vi names the range *before* the action, so what stands in for visual mode is
describing a range without dragging a highlight across it. Most directly,
a motion or text object already *is* one: *dip* takes the paragraph, *dt)* runs
to the next *)*, *ci(* the brackets. A search is an address too -- *d/foo* deletes
up to the next _foo_, and at the *:* prompt an address may be a pattern, so
*:.,/END/d* deletes from here to the next line matching _END_.

*Marks* are the tool for a range you assemble by moving around, and they best
make up for not having a drawn selection. Drop one with *m*_a_, then travel
freely -- search, scroll, jump to a matching bracket with *%* -- and act from the
far end: *d`a*, *y`a*, *c`a* reach charwise to the exact spot, *d'a* is linewise,
and at the *:* prompt *:'a,'b* is the range for any ex command. So *:'a,'b t .*
copies those lines, *:'a,'b m 0* moves them to the top, *:'a,'b !sort* filters
them, *:'a,'b >* indents them. A mark rides along with edits made between the two
ends, so the range you named stays the range you meant.

Relative and absolute addresses cover nearby ranges with no mark at all: *:.,+5d*
is this line and five more, *:.,$d* runs to the end of the file, *:1,.d* deletes
from the top down to here. *Ctrl-G* (or *:.=*) reports the current line number
when you need one to build such a range. And *.* plus macros stretch one edit
over many places: make the change once with a text object and tap *.* on each
next target, or record *q*_a_ ... *q* and replay it with a count -- *5@a* runs it
down five lines.

## In place of a block selection or "multiple cursors"

The line-oriented commands do what a block selection or multiple cursors are
reached for, taking a named range in place of a drawn rectangle:

*:[range]normal* _keys_
	Run any normal-mode _keys_ on each line of the range -- the nearest thing to
	multiple cursors. *:%normal A;* appends *;* to every line. For an edit too
	fiddly to type inline, record it once on a sample line with *q*_a_ ... *q*,
	then stamp that macro across a range: *:2,5normal @a* replays macro _a_ on
	lines 2-5, *:%normal @a* on the whole buffer. lvi's own keys work here (its
	macros, text objects, *!*/*gq*); lines run top to bottom, so keep the keys
	per-line and reach for *:g//d* / *:d* / *:m* when you mean to change the line
	count.
*:%s/$/;/*, *:%s/^/# /*
	Append or prepend text on every line; unlike *:normal*, *:s* keeps a trailing
	space, so it is the way to indent-with-a-space across lines.
*:g/re/d*, *:v/re/d*
	Delete the lines matching, or (with *v*) not matching, a pattern.
*:g/re/normal* _keys_
	Run _keys_ on each _matching_ (so possibly non-contiguous) line. This one
	delegates to the system *ex* ($*LVI_EX*), so only its normal mode is
	available; lvi-specific keys do not apply. For those, use *:[range]normal*
	over a contiguous range, or narrow with *:g//s*.
*:'a,'b t .*, *:'a,'b m 0*
	Copy or move a line range -- a visual yank-and-put without the selection.
*:%!column -t*, *:1,5!sort*
	Pipe a line range through a tool to align or sort (the *!* operator, from the
	*:* prompt).

## Numbering and arithmetic (the visual "g Ctrl-A")

Number or renumber a list, or do column arithmetic, with a filter -- no
selection, no built-in feature, just a tool you already have:

*!ip awk '{print NR". " $0}'*
	Number each line of the paragraph: *1.*, *2.*, .... *!ip nl -ba* does the
	same through *nl*(1).
*!ip lvi-incr*, *!ip lvi-incr -b 1*
	*contrib/lvi-incr* packages this: it bumps each line's first number by its
	index (vim's *g Ctrl-A*), or with *-b* renumbers to *1*, *2*, *3*. Bound to
	*<C-a>* on one line it stands in for *Ctrl-A*; see *contrib/README.md*.

## When the range is computed, drive it over the socket

For a selection no motion describes -- every function's opening line, columns
lifted from a report -- an external tool computes the spans and applies the
edits over the control socket (*lvi -w*), the way *:hl* overlays, lists, and
*:textobj* filters already do. The socket is lvi's answer to the irregular
selection.

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
of *hi* lines, live syntax highlighting is one *on change* line, and the system
clipboard is one *register* line (e.g. *register + read wl-paste write wl-copy*).
See *contrib/README.md* and *contrib/lvirc.sample*.

# TURNING ON THE IDE

Much of what feels built into other editors is, in *lvi*, a small external
program that drives the view over the socket -- so it lives *outside* the core
and you switch it on from the rc file. No language engine, search engine, or
quickfix machinery lives in *lvi* itself. Each tool that ships in _contrib_ is
below, with the happy-path rc lines that turn it on:

*lvi-highlight* -- syntax highlighting
	An external highlighter (Pygments or bat) repaints the live buffer, unsaved
	content and all, through the *:hl* overlay. Repaint as you type and on each
	buffer switch:

	```
	on change   lvi-highlight
	on bufenter lvi-highlight
	```

	Color the token groups with *hi* lines, or seed them from a Pygments style:

	```
	on ready LVI_PYGMENTS_STYLE=monokai lvi-highlight --theme
	```

	Toggle at runtime with its *off*/*on*/*toggle* subcommands (a *:syntax off*),
	or force the language with *lang* _name_ when detection guesses wrong.

*lvi-search* + *lvi-list* -- search and quickfix
	*lvi-search* greps the live (unsaved) buffer into a *lvi-list* list; every
	list (search, grep, lint, git hunks) shares one pair of step keys, acting on
	whichever is _focused_:

	```
	map / :silent !lvi-search<CR>
	map * :bg lvi-search "$LVI_CWORD"<CR>
	map n :bg lvi-list next<CR>
	map N :bg lvi-list prev<CR>
	on bufenter lvi-list paint
	```

*lvi-gitchanges* -- step your git diff
	Turn *git diff* for the current file into a steppable list of hunks:

	```
	map \\g :bg lvi-gitchanges<CR>
	```

*lvi-lint* -- any linter, as a list
	Lint the live buffer (ruff, shellcheck, *deno lint* ship; one small adapter
	per tool) into a steppable list; the status counter doubles as the pass/fail
	glance:

	```
	on write lvi-lint
	map \\e :bg lvi-lint --focus<CR>
	map ]e :bg lvi-list next lint<CR>
	map [e :bg lvi-list prev lint<CR>
	```

*lvi-spell* -- spell check, as a toggle
	Toggle spell check; while on, misspellings are marked in place and stepped,
	with a suggestion picker and a dictionary add:

	```
	map \\s :bg lvi-spell<CR>
	map ]s :bg lvi-list next spell<CR>
	map [s :bg lvi-list prev spell<CR>
	map z= :silent !lvi-spell fix<CR>
	map zg :bg lvi-spell add<CR>
	```

*lvi-fmt* -- format the buffer
	Run the file's formatter over the live buffer and splice back only the changed
	window (cursor stays put, one undo reverts, already-formatted is a no-op):

	```
	map \\= :bg lvi-fmt<CR>
	```

*lvi-open* -- open a file
	Fuzzy-pick a file and open it in the running view:

	```
	map \\f :silent !lvi-open<CR>
	```

*lvi-shell.sh* -- drive lvi from your shell
	Shell functions (*lvi-saveas*, *lvi-e*, *lvi-r*) that drive the running view
	from *sh* or any terminal, with your shell's own path completion. Source it
	from your shell's rc, not lvi's:

	```
	. lvi-shell.sh
	```

*lvi-tags* -- jump to / outline symbols
	Fuzzy-pick the current file's ctags tags -- a jump-to-symbol and a file
	outline in one key. *:wbuf* snapshots the live buffer for the picker to read:

	```
	map \\t :wbuf<CR>:silent !lvi-tags<CR>
	```

*lvi-fold* -- fold by structure
	The core ships the fold mechanism (*zf*/*zo*/*zc*/*zR*); *lvi-fold* supplies
	the policy, folding by *marker* or *indent*:

	```
	map zi :bg lvi-fold<CR>
	map zI :bg lvi-fold indent<CR>
	on bufenter lvi-fold
	```

*lvi-complete* -- insert-mode completion
	Complete the word before the cursor from every open buffer, on insert-mode
	*Ctrl-N*/*Ctrl-P*:

	```
	on complete lvi-complete
	```

*lvi-pos* -- position memory
	Remember where you were in each file across sessions (viminfo's *`"*), in a
	plain-text store:

	```
	on change   lvi-pos save
	on write    lvi-pos save
	on bufleave lvi-pos save
	on ready    lvi-pos restore
	on bufenter lvi-pos restore
	```

*lvi-diff* / *lvi-stagediff* -- diff and staging
	A two-way vimdiff of two panes: highlighted, scrollbound, hunks moved with
	*\\p*/*\\o* and jumped with *]c*/*[c*. *lvi-stagediff* layers *git add -p* on
	top. These are commands, not rc lines:

	```
	lvi-diff                 " the sole pair of live panes
	lvi-diff old new         " two files, in a new tmux window
	lvi-stagediff file       " git add -p, side by side
	```

*lvi-textobj-tag* -- HTML/XML tag object
	Add Vim's tag object (*it*/*at*) so *cit*/*dat*/*yat* act on the enclosing
	element, with no HTML parser in the core:

	```
	textobj t lvi-textobj-tag
	```

*lvi-incr* -- increment / renumber
	Rewrite the first number on each piped line through the *!* filter (recovering
	Ctrl-A / g-Ctrl-A, which the core has no built-in for):

	```
	map <C-a> :.!lvi-incr<CR>
	map <C-x> :.!lvi-incr -s -1<CR>
	```

*lvi-surround* -- wrap a span in a delimiter pair
	The surround reflex on the *g@* operator: arm it, then *g@*_motion_ wraps the
	span. Bind a key per pair (*s(iw*, *s"$*):

	```
	map s( :set opfunc=lvi-surround paren<CR>g@
	map s" :set opfunc=lvi-surround dquote<CR>g@
	```

*lvi-comment* -- toggle line comments
	Comment or un-comment the lines a motion spans, also on *g@*; the style comes
	from the file's extension or an argument (*gcip*, *gcj*):

	```
	map gc :set opfunc=lvi-comment<CR>g@
	map gC :set opfunc=lvi-comment<CR>g@@
	```

	(*gcc* can't be a map: with no *map* timeout, *gc* fires at once, so use *gC*
	or *gc@* for the current line.)

*lvi-reflow* -- reflow a list
	Rewrap a bulleted or numbered list through *gq*, keeping each item's marker
	and hanging the wrapped lines under its text -- the *formatlistpat* job
	*fmt*(1) can't do (ordered, roman, letter, and bullet markers; nested lists
	nest). Point *fmtprg* at it and *gqip* / *gqq* reflow lists:

	```
	set fmtprg=lvi-reflow -w 79
	```

*lvi-ftype* -- per-filetype options
	Set *sw*, *et*, *fmtprg* and the rest from the file's name on entry (vim's
	ftplugin as two shell *case*s): Python at *sw=4* with *ruff format*, shell at
	*sw=2* with *shfmt*. With *lvi-detect-indent* alongside it, the file's own
	indentation overrides the name. It ships as a template; copy it, edit the
	table, and aim the hook at your own copy:

	```
	on bufenter lvi-ftype
	```

The lines above are the happy path. *contrib/lvirc.sample* has the full annotated
set -- every binding, theme, and variant -- and each tool's *-h* (or
*contrib/README.md*) explains what it does and how it works.

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
