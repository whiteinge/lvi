# contrib — the tools that turn lvi into an IDE

lvi keeps a minimal core and pushes everything else out here: small programs that
drive a running editor over its control socket (`lvi -w …`), feeding the `:hl`
overlay and the `:normal` escape hatch. It's an implementation of "UNIX as IDE":
search, syntax highlighting, and quickfix aren't compiled in — they're Unix
tools composed from the outside. Nothing here is privileged; each is a worked
example of what *any* program can do to a live view.

Put this directory on your `PATH`. Then:

- **To switch a feature on**, see *TURNING ON THE IDE* in the
  [manpage](../lvi.1.scd): it lists every tool with the rc line or map that
  enables it, and the themes and bindings to copy are in
  [`lvirc.sample.vim`](lvirc.sample.vim).
- **For a tool's full reference**, run `TOOL -h` — its header comment:
  invocation, every env knob, and bindings.

The rest of this README is implementation detail on the tools below, to guide
you in writing your own (contributions welcome).

## The shared machinery

Every tool below is built from a handful of ideas the core provides — worth
understanding once; they're all *you* need to write your own.

**The `:hl` overlay is the substrate.** One styled overlay (`:hl` paints ranges,
`:hi` themes groups, `pri=N` sets z-order) backs search, quickfix, *and* syntax
highlighting. They only differ in what feeds it: a highlighter emits token
groups, a list emits match groups (search sets a positive `pri` so its matches
draw over syntax). A new visual feature is usually just a new producer of `:hl`.

**Lists are files; list focus is a pointer.** Both live beside the buffer
socket, the state survives across processes and needs no daemon — any
producer writes a list, any stepper reads the focused one. `on bufenter
lvi-list paint` is the glue that repaints the current buffer's matches when
you arrive in it, which is what makes *cross-file* lists (project grep,
a compiler) light up per file.

**Three spawn disciplines** — the reason the bindings differ:

- `:silent !CMD` hands over the terminal (drops to and back from the alt screen).
  Use it only for tools that **prompt** or are otherwise interactive — `/`,
  `lvi-open`'s picker.
- `:bg CMD` runs detached with **no** terminal handover — no alt-screen flash. Use
  it for non-interactive tools fired by a map that may repeat (`map n :bg lvi-list
  next<CR>`). It's the same spawn `:on` hooks use. A leading address range
  (`:L1,L2bg CMD`) arrives as `$LVI_LINE1`/`$LVI_LINE2`, the non-mutating
  counterpart to a `[range]!` filter, so a tool can act on a typed line span
  without a bespoke command (`lvi-diff` moves a partial hunk this way, and
`lvi-stagediff` stages one). The
  `g@` operator is the same spawn driven from a *motion*: `:set operatorfunc=CMD`
  then `g@{motion}` fires `CMD` over the span, adding `$LVI_COL1`/`$LVI_COL2` and
  `$LVI_KIND` so a charwise operator can reach part of a line (`lvi-surround`,
  `lvi-comment`).
- **Self-backgrounding.** A tool that must *read* the buffer (`lvi-highlight`,
  `lvi-search` via `%p`) can't do so synchronously from a `:silent !` child: lvi's
  loop is frozen waiting on that child, so a foreground read would deadlock. They
  double-fork a worker and return at once, letting lvi resume and service the
  worker's socket I/O. `lvi-list` never reads the buffer, so it just fires
  fire-and-forget jumps with `lvi -w --detach`.

…plus **`:wbuf`, the buffer-feeder** for the one case self-backgrounding can't
cover: a tool that needs the terminal **and** the live buffer at once — an
interactive picker built from *unsaved* text (`lvi-tags`). Self-backgrounding
frees the loop but surrenders the tty the picker needs. So the binding snapshots
the buffer to `$LVI_BUFFER` with `:wbuf` *before* handing over the tty, and the
frozen picker reads that file: `map \t :wbuf<CR>:silent !lvi-tags<CR>`. The
manpage's *Shelling out* table lays the verbs side by side.

**Reactive hooks push; nothing polls.** `on change` (the buffer settled), `on
write` (a `:w`), and `on scroll` (a keyboard move of the viewport top) are the
editor's *push* seams — each fires a command with the relevant state in the
environment (`$LVI_FILE`, `$LVI_TOP`, …). They're keyboard-gated, so a tool's own
socket-driven edits and scrolls never re-fire them, and cross-view features can't
ring. The flip side of that gate: if your tool *edits* the buffer over the
socket, `change` consumers (live highlighting) won't hear about it until the
user's next keystroke — send `:fire` after your edits to arm them explicitly
(it rides the same idle debounce a keystroke does). `lvi-diff` is how far the
hook model reaches: diff highlighting, hunk-aware scrollbind, and staging are
*all* just these hooks plus one-shots — no polling, no daemon; the session
lives as hooks and maps inside the two views and ends when a pane closes.

**The dirty flag is a socket primitive.** The buffer's modified state is exposed
through the ordinary `:set` surface — `set modified?` queries it, `set
nomodified` clears it (aligning the undo saved-marker with the current state, as
`:w` does but without the I/O), `set modified` forces it dirty. That is all
`lvi-mirror` needs to keep the clean/dirty indicator honest across panes: it
reads its own flag and pushes `set nomodified` to peers whenever it goes clean.
No new protocol — a piece of view state that happened to have no ex option got
one, and a cross-pane feature fell out.

**Registers can be shell-backed.** `:register NAME read CMD write CMD` wires a
register to external commands: a yank or delete pipes the text out through
*write*, a put reads fresh in through *read*. Backing `+` with the system
clipboard is the idiom — `register + read wl-paste write wl-copy` (or
`pbcopy`/`pbpaste`, `xclip`, a `tmux` buffer) — so `"+y` copies and `"+p`
pastes. This is core config, not a script; [`lvirc.sample.vim`](lvirc.sample.vim) has
the per-platform lines. Backing the **unnamed** register (`register "" write
CMD` — doubled, since a lone `"` in the rc is a comment) is special: since `"`
mirrors every yank and delete, its *write* is the one point they all flow
through, so a history tool needs no key remapping. `lvi-yankring` is built on it.

**The highlighter contract**: `lvi-highlight` is a backend-agnostic harness;
a backend is one adapter, `lvi-hl-<name>`, with a single contract: **buffer
text on stdin, filename as `$1` (optional forced language as `$2`), emit
`hl GROUP L:C1-C2 …` (byte columns) on stdout.** Two shapes ship:

- **Positional** (`lvi-hl-pygments`): walk the tool's token stream, emit named
  groups; style them with `:hi`.
- **ANSI** (`lvi-hl-bat`): pipe the tool's ANSI-colored output through the shared
  `lvi-hl-ansi` parser, which turns each distinct SGR into a `synN` group whose
  style *is* that SGR. `source-highlight`, `tree-sitter highlight`, etc. are thin
  wrappers around `lvi-hl-ansi` (feed it `--wrap=never --tabs=0` so byte columns
  don't desync).

The same contract shape drives the linter: `lvi-lint-<name>` takes the buffer
on stdin and the filename as `$1`, and emits list entries instead of `hl`
lines. One adapter idiom, two harnesses.

**The text-object filter contract** (for adding an object like `it`). This one is
the odd member of the family: it is the only tool lvi launches **synchronously and
itself**, not via a map or a hook. `:textobj KEY CMD` binds a custom object; when
an operator meets `i`/`a KEY` with no builtin, lvi shells `CMD` out and *blocks*
for its answer — the same discipline as a `:s` sent to the system `ex`, and for
the same reason: because the operator applies through the ordinary coroutine path,
`c` (change) enters insert mode exactly like a builtin `ci(`. An async, socket-
callback design (the tool phones the edit back in over `lvi -w`) was the first
sketch and was dropped — a non-blocking channel can't cleanly hand you insert mode
mid-edit, and blocking on a fast local filter is imperceptible. The contract:
**invoked `CMD TMPFILE i|a LINE COL`** (buffer text in a private temp file, cursor
1-based in bytes), **print one line** — `char L1 C1 L2 C2` (charwise, inclusive,
byte columns), `line L1 L2` (whole lines), or nothing for "no object here" (a clean
no-op). That's the whole surface; `lvi-textobj-tag` is one implementation of it,
and a tree-sitter object would be another.

## The tools

Each is a worked example of the machinery above — read the one nearest what you
want to build. To *use* them, see the manpage's *TURNING ON THE IDE*.

### `lvi-highlight` — syntax highlighting

Pulls the live buffer over the socket, runs an external highlighter, and paints
the tokens through `:hl`. Because it works on the buffer (not the file on disk)
it highlights **unsaved** content, and a still-open string or block comment
colors the rest of the file until you close it.

Two backends ship (more contributions welcome), and they *theme* differently:

- **Pygments** (default) is **positional** — it reports token *types* (Keyword,
  String, …) and *you* pick their colors with `:hi` in the rc, one theme across
  every language.
- **bat** is **ANSI** — it has already colored the text with its own theme, and
  lvi reproduces those colors, so you choose the look with `BAT_THEME`, not `:hi`.

Select one with `LVI_HL_BACKEND`; see the `lvi-highlight` header for the rest.

Turn highlighting off and on at runtime with `lvi-highlight off`/`on`/`toggle`
(a `:syntax off`), and when detection guesses wrong force the language with
`lvi-highlight lang NAME` (bare `lang` clears it). Both are per-view; run them
from inside lvi (`lvi-highlight -h` covers the state files and the caveat).

### `lvi-search` + `lvi-list` — search and quickfix

A **list** is a plain file of `file:line[:col]:text` entries — the Vim quickfix
format that grep, a compiler, a linter, or `git diff` all speak. Vim's
multi-line variant works too: each `file:line:` header may carry indented body
lines (a compiler note, a full diagnostic), and `n`/`N` step through the
headers while the bodies are available via `lvi-list preview` to show on
demand.

lvi knows nothing about lists: `lvi-list` owns them and drives the view over
the socket, jumping the cursor, painting the `:hl` overlay, and setting a
`:status` counter.

Any number of named lists can coexist but only one is **focused** at a
time. The bare step commands act on the focused list — so a *single*
pair of keys (`n`/`N`) can step search, grep, lint, or git hunks alike.
Focus can be changed to another list at will (`lvi-list focus NAME` or
pick from a menu with `lvi-list switch`), and non-focused lists can be
stepped with list-specific key mappings. E.g., `map ]c :bg lvi-list next
gitchanges<CR>` steps git hunks without touching what `n`/`N` point at.

**`lvi-search`** is the first producer for the generic `lvi-list` interface:
it greps the *live* buffer (so it finds unsaved text), builds the `search`
list, focuses it, and jumps to the first match. Search is simply a degenerate
quickfix. Bind `/` to prompt and `*` to hunt the word under the cursor;
`n`/`N` do the rest.

You read an entry two ways. Stepping echoes its text to lvi's **message
line** via `:msg` — ephemeral, cleared by your next motion, so a lint
message is visible as you step. The full entry (header + body) is available
via `lvi-list preview` on stdout; bind it to a `tmux display-popup` to see
the whole multi-line message. That popup key defaults to the **most recent**
stepped list meaning a custom `]e` map steps `lint` without stealing `n`/`N`'s
focus, yet the preview key still shows the lint entry you just navigated
to. (`:msg`/ `:msge` are the generic in-editor notice mechanism. `:msge`
styles it as an error via the `Error` group.)

Lists are ephemeral and live beside the view's socket (auto-cleaned per
view); use `lvi-list save`/`load` to ��persist a list to a location that
isn't automatically cleaned See the `lvi-list` header for all arguments.

### `lvi-gitchanges` — step your git diff

The second `lvi-list` producer, and a one-line proof that "any tool that speaks
`file:line:text` is a quickfix": it turns the `git diff` for the current buffer
into a `gitchanges` list — one entry per hunk — and jumps to the first, so `n`/`N`
walk your uncommitted changes. `lvi-gitchanges HEAD~3..` steps a commit range,
`lvi-gitchanges <commit>` a single commit, and `lvi-gitchanges --staged` steps
what you've *staged* (a separate `gitstaged` list — handy for reviewing the hunks
you moved onto the index in `lvi-stagediff`, folds and all). Unlike `lvi-search`
it reads the file on **disk** (or the index), not the live buffer, so it shows
changes since your last `:w` / `git add`.

### `lvi-lint` — any linter, as a list

The producer behind "a compiler is a quickfix": run a linter over
the **live** buffer (unsaved edits included), normalize its complaints, and step
them like any other list — `on write lvi-lint` re-lints every save, and the
status counter doubles as a pass/fail glance (`[0/0]` = clean).

Vim grew the `errorformat` mini-language to understand output from many
producers, but we've opted put the onus on the tool itself (or a wraper
script) to produce the standard quickfix format. `lvi-lint` uses **backend
adapters** (`lvi-lint-<name>`, picked by file extension or `LVI_LINT_BACKEND`)
to normalize each tool's output with a few lines of awk. It follows the
same pattern as the highlight backends — buffer on stdin, real filename
as `$1`, entries on stdout.  Accepts stdin via `--stdin-filename` for
live-buffer linting, or the on-disk path can be used on-write (useful for
config resolution, like ruff finding your `pyproject.toml`, etc).

Look for the `lvi-lint-<name>` contrib scripts to see what we currently ship
and more contributions are welcome; the next tool is a dozen-line adapter.

Severity rides an `E:`/`W:` prefix in the entry text. See the `lvi-lint`
header for the contract.

### `lvi-spell` — spell checking as a toggle

Vim's `:set spell` but as an external script. It reads-from then writes-to the
editor: one aspell/hunspell pass over the live buffer feeds exact word extents
to a `spellbad` `:hl` group to show misspellings visually, and a `spell`
list via `]s`/`[s` to step through the list. It can be toggled on and off.
`z=` picks a correction through your `$LVI_PICKER` choice and splices it in
place; `zg` adds the word to your personal dictionary.

Whole-buffer for simplicity and by design — spell-checking code will
mean some unwanted visual noise so toggle it on and off as needed. See the
`lvi-spell` header for the ispell-protocol details and caveats.

### `lvi-fmt` — format the buffer, minimally

`:%!ruff format -` works today — the ex filter is one splice, one undo — but it
parks the cursor at line 1, dirties the buffer even when nothing changed, and
makes you remember each tool's stdin incantation. `lvi-fmt` formats **outside**
the buffer and only then edits: it runs the extension-matched formatter
(`ruff format`, `shfmt`, `gofmt`, `stylua`, `deno fmt`; `LVI_FMT_CMD`
overrides) over the live buffer, diffs, and replaces just the changed window —
so one `u` reverts the whole format, the cursor stays put (shifted by the
line-delta of changes above it, `lvi-mirror`'s arithmetic), an
already-formatted buffer is a true no-op that stays clean, and a formatter
that chokes on a syntax error is a no-op (the failure lands in the `fmt`
status segment). Bind `map \= :bg lvi-fmt<CR>` — vim's `=`, writ whole-buffer.
Deliberately not an `on write` hook: that fires *after* the write, so it would
re-dirty the buffer on every save. Format, then `:w`.

### `lvi-open` — open a file

A fuzzy-picker (fzf by default) that opens the chosen file in the running view.
Bind it: `map \f :silent !lvi-open<CR>`.

### `lvi-shell.sh` — drive lvi from your shell (save-as with real completion)

This is not a tool that lvi runs, but rather a script you source in your
shell startup scripts. This gives you some helpers when you drop into an
interactive shell via `:shell`/`:sh`. lvi sets various environment variables
that refer to the buffer you came from for interactive reference. `lvi-saveas
PATH`, `lvi-e FILE`, and `lvi-r FILE` send the matching ex command to the
running view, so every path argument gets your shell's own tab completion.
This avoids bloating the editor with file and directory tab completion
and allows you to use already-familiar shell tools, shortcuts, and path
traversal. Note: the editor is frozen while you're in the shell, so the
command lands after you exit.

This will change the shell prompt ��to denote you're in an lvi shell and
the file you were editing `(lvi foo.txt) $`.

### `lvi-tags` — jump around / outline the current file

A `ctags` picker: lists every tag defined in the current file, in file order,
and jumps to the one you pick. Because each row shows the tag's own definition
line, scrolling the picker *is* a structural overview of the buffer — "jump
to a function" or "what's in this file". It re-tags the **live buffer**,
not from an on-disk`tags` file, so it reflects your unsaved, in-progress
edits. Bind it: `map \t :wbuf<CR>:silent !lvi-tags<CR>` (`:wbuf` snapshots
the buffer so the picker can read it — see the spawn disciplines above).

### `lvi-fold` — collapse the buffer by structure

lvi ships the fold *mechanism* — a closed fold collapses its lines to one
summary row and `j`/`k`/scroll skip over it (`zf`/`zo`/`zc`/`zR`; see the
manpage) — but no fold policy. `lvi-fold` is the policy half. It reads
the live buffer over the socket and pushes the ranges back as `:fold`,
the same read-compute-paint loop `lvi-highlight` runs against `:hl`. We
ship with three fold methods (contributions welcome): `marker` (vim's `{{{
… }}}`, nested by a stack; the pair is `$LVI_FOLD_MARKER`), `indent`
(each block indented under its parent), and `man` (each rendered-manpage
section under its heading — see `lvi-man`). It replaces the view's folds each
run, so re-running it (by marker or `indent` mode, or `on bufenter` to auto-fold
on open) re-folds after edits.

It reads the buffer, so it self-backgrounds (or bind it with `:bg`) for the same
reason `lvi-highlight`/`lvi-search` do — see **Self-backgrounding** above. Any
other fold policy (by syntax, by diff hunk, by `git` conflict markers) is the
same shape: emit `L1,L2` pairs, hand them to `:fold`.

### `lvi-man` — read manpages in lvi

Set `MANPAGER=lvi-man` and `man` opens the page in a running lvi, with section
folds, syntax highlighting, and vi motions to move around. man pipes its
formatted output in; `lvi-man` strips the overstrike bold/underline with `col
-bx` (lvi is not a terminal-escape pager) and opens the result via `lvi -`.

No core support: it composes existing seams under a dedicated rc (`lvirc-man`,
loaded through `$LVIRC` so none of your normal hooks fire on a throwaway page).
`set scratch` makes `:q` painless — the page came off a pipe, so there's no file
to protect and read-only would buy nothing. `on ready lvi-fold man` folds each
section body under its heading into a table of contents you step with `zj`/`zk`
(NAME and SYNOPSIS stay open, via `$LVI_FOLD_MANKEEP`), and `on ready
lvi-highlight lang man` colors it through the bat backend. lvi has no built-in
search, so the rc maps `/` (and `*`) to `lvi-search`. Set `MANROFFOPT=-c` so
groff's overstrike stays clean for `col`.

Caveats: bat's manpage grammar is coarse (headings, options, some emphasis), and
it's a full editor per page — the cost your `$MANPAGER` already pays under vim.
Copy `lvirc-man` and point `$LVI_MAN_RC` at it to tune the pager environment.

### `lvi-complete` — insert-mode word completion

Insert-mode Ctrl-N/Ctrl-P completion is drawn from **all open buffers**
and invokes your choice of fuzzy-finder.  `on complete CMD` registers a
completer, and the keypress runs it synchronously — handing it the token
you're typing (plus the line's left context) and every open buffer's text,
then splicing its stdout in over the token.

`lvi-complete` is the shipped completer (other contributions welcome): it
de-dupes the buffers' words (current buffer first), fuzzy-picks with your
`$LVI_PICKER` seeded by the token, and prints the choice. Turn it on with `on
complete lvi-complete`; set `LVI_COMPL_POPUP=1` under tmux to draw the picker
in a `display-popup` over the editor instead of taking the whole screen.

Because the funnel is generic — token + left-context + buffers in, one word out —
the *kind* of completion is just which command you register: a file-path, whole-
line, or `readtags` symbol completer is the same contract, and a dispatcher can
pick one by context (a `/` in the token → paths, etc.) with no menu.

### `lvi-pos` — remember where you were (viminfo's `` `" ``)

Reopen a file and land where you left off. vim keeps this in its `viminfo`
database; lvi keeps it in a **plain-text store** — one tab-delimited
`path⇥line⇥col` line per file under `$XDG_STATE_HOME` — that you can `grep`,
edit, or delete by hand.

No core support was needed: the whole feature is a handful of `:on` hooks
pointed at one script. `save` (on `change`/`write`/ `bufleave`) records the
cursor; `restore` (on `ready`/`bufenter`) looks the file up, jumps to the
exact line and column, and drops the `` `" `` mark so `` `" `` takes you
back after you wander.

Prefer to open fresh at the top? `restore -n` sets the `` `" `` mark but
leaves the cursor at line 1, so you reach for `` `" `` only when you want it.
`restore` only touches a buffer sitting at line 1 (a fresh read), so binding
it to every `bufenter` never clobbers the live cursor of a buffer you're
revisiting — lvi already keeps that in memory.

The one piece that *is* in the core is the `` `. `` mark, set to your last
change as you type, so `` `. `` returns to the last edit within a session. (A
hook can't set that mark safely — `on change` can fire mid-insert, where
the keystrokes would land as text — so the core stamps it directly;
the tool owns only the cross-session `` `" ``.)

### `lvi-gmark` — global (cross-file) marks, `A`–`Z`

vi's uppercase marks remember a *file* as well as a position, so `` `A `` jumps
to that file from any buffer or any later session — where lowercase `a`–`z` are
local to one buffer. lvi's core marks are all per-buffer `(line, col)` with no
path; `lvi-gmark` adds the global layer as a **plain-text store** (one
`mark⇥path⇥line⇥col` line under `$XDG_STATE_HOME`, naturally capped at one slot
per letter, so nothing to prune) plus two `:on` hooks.

The seam is in the core; the storage isn't. Pressing `m<A-Z>` fires a `markset`
event and `` `<A-Z> ``/`'<A-Z>` fires `markjump`, each handing the letter to the
hook in `$LVI_MARK`. `set` (on `markset`) records the file and position; `go` (on
`markjump`) opens that file and moves there over the socket. The jump is
asynchronous, which is why the core leaves the cursor put and adds no jumplist
entry for it. With the hooks unset, uppercase marks stay ordinary buffer-local
marks, so turning this on is purely additive.

### `lvi-yankring` — cycle through yank/delete history at paste time

vim's YankRing / yanky.nvim: every yank and delete is remembered, and after a
paste you walk that paste back through older entries instead of hunting for the
right numbered register. The numbered delete registers (`"1`–`"9`) live in the
core and stay addressable; this is the *ergonomic* on top, where you never type
a register name — you paste, then cycle.

No core support beyond one seam: backing the unnamed register's *write* (see
above) hands the script every yank and delete, so it needs no key remapping to
capture. A second register (`~`) is `read`-backed with the ring's current entry,
and each cycle key is one `:bg` map that steps the cursor and sends `u"~p` (undo
the paste, put the stepped entry), replacing the pasted text in place. `\yp`/`\yn`
walk older/newer, `\yy` picks any entry through `$LVI_PICKER`. The ring is
per-view beside the socket (point `LVI_YANKRING_DIR` at a shared path to carry
one across views); it rides the unnamed register, so it replaces neither the
numbered registers nor the `+` clipboard.

### `lvi-mirror` — live-share a buffer across panes

lvi has no in-editor split; an external multiplexer owns and organizes
multiple instances, so if you edit the same file in multiple lvi instances
(`lvi thefile`) this script this script is the live connection between them.

It pulls the **live** buffer over the control socket (so *unsaved* edits
propagate, which a file-watch + `:e` never could) and diffs it into every
other view open on the same file, applying only the changed hunks so each
peer keeps its marks, highlights, and scroll. Turn it on in **every** pane
with two rc lines — `on change lvi-mirror` (propagate edits as they settle)
and `on write lvi-mirror` (propagate the saved/clean state on `:w`). The
mesh is stable by construction: a peer receives the push over its socket,
and socket-sourced edits never re-arm the `change` hook, so A→B never
rings back B→A. It also carries the dirty flag across panes via the
`set modified?` / `set nomodified` primitive (see above).

### `lvi-diff` — two-way diff of two panes

Vimdiff equivalent. Two files, two panes, side by side: highlight the
differences, **scrollbind** the views so they scroll together, and move
hunks between them. Uses an external multiplexer like with `lvi-mirror`
— no in-editor split; two `lvi` processes, two sockets, this script the
connection between.

This diffs the buffers, paints DiffChange/DiffAdd/DiffDelete through `:hl`, writes a
line-map cache, and installs the maps and hooks — then exits. What happens after
is lvi firing those hooks. `]c`/`[c` jump to the next/prev hunk (top-anchoring
*both* panes); `\dp`/`\do` put/obtain the hunk under the cursor (vim's diff-mode
`dp`/`do`, on the `\` leader so they don't shadow `d`).

Note, hunk navigation is *not* an `lvi-list` because a list jump moves one
view's cursor, but a diff jump must move both panes in step (a socket-driven
move never fires the peer's scroll hook, by design) — though from
the fingers it's the same "pinned keys, never focused" posture, and `]c`
matching vim's diff-mode is no accident. Scrollbind rides the `on scroll`
hook: when a pane's viewport moves, its top is translated through the diff
map and pushed to the peer, so they stay aligned even across a lopsided hunk.
`zx` folds the **unchanged regions** away (vimdiff's `foldmethod=diff`),
leaving only the hunks and their context — built on lvi's core `:fold`
overlay, from the same diff the map comes from. Because matched regions have
identical line counts on both sides, folding them symmetrically keeps the
scrollbind aligned; it's off by default (`LVI_DIFF_FOLD=1` to start folded,
`LVI_DIFF_FOLDCTX` for context).  Launch it on two live views — `lvi-diff`
(auto-picks the sole pair) or `lvi-diff WID_A WID_B`. Or hand it **two files**
— `lvi-diff old new` — and it opens them in a **new tmux window**, wires
the same diff, and blocks until you quit the left one: a `vimdiff foo bar`
for lvi. That file mode is also what makes it a git mergetool (below).

### `lvi-stagediff` — `git add -p`, as a diff you edit

A side-by-side `git add -p` (concept borrowed from Fugitive). It opens a split:
**left is the git index** (`git show :file`), **right is the working tree**, so the
diff between them is exactly your *unstaged* changes. It's `lvi-diff` plus two git
pieces, so the highlighting, scrollbind, and hunk maps come free.

The mental model: **the index pane's text is the staged content.** Move a hunk
onto it with `\dp`, pull one back off with `\do`, move a motion's span with
`g@{motion}` (or `:L1,L2bg lvi-stagediff --xfer-range …`) to split two changes
`diff` merged into one hunk. Those are ordinary buffer edits: `u` backs a move out,
and nothing touches git yet. **`:w` on the index pane is what stages** — it hashes
the pane into a blob and points the index at it (`git hash-object -w` + `git
update-index`), the whole buffer at once, so there's no partial-patch fuzz to
misapply. Shuffle and edit until the pane reads the way you want it staged, then
write.

So each pane's `:w` consummates its own side: the index pane stages, the working
pane saves the file. To restore a working-tree hunk from the index, `\do` it back.
Unstaging to HEAD isn't a keystroke yet: edit the index pane to the version you
want and `:w`, or `git reset`. Run `lvi-stagediff FILE` inside a new tmux window.

### Git mergetool

`lvi-diff`'s file mode drops into git's mergetool protocol — paired with
**`hideResolved`**, it's a genuinely pleasant conflict resolver. `hideResolved`
pre-resolves everything both sides agree on and rewrites LOCAL/REMOTE so only the
*real* conflicts differ, markers gone — so the two-way diff shows exactly the
hunks you must decide. You resolve them the way you'd move any hunk (`\do` to take
theirs into the left pane, or hand-edit), then `:x` to accept or `:cq` to abort.
In `~/.gitconfig`:

    [merge]
        tool = lvi
    [mergetool "lvi"]
        cmd = lvi-diff "$LOCAL" "$REMOTE" "$MERGED"
        hideResolved = true
        trustExitCode = true

Then `git mergetool` (inside tmux) steps you through each conflict. `trustExitCode`
maps lvi's exit straight through: `:x`/`:wq` (0) stages your resolution, `:cq`
(non-zero) leaves the conflict for later. The `$MERGED` argument is there because
Git stages `$MERGED`, not LOCAL — it does not reassemble the result from your
edited LOCAL — so on accept the tool copies your resolved left pane onto it.

### `lvi-textobj-tag` — an HTML tag text object, from outside the core

lvi's builtin text objects (`iw`, `i(`, `i"`, `ip`) stop where a POSIX-vi-simple
scanner stops: nothing language-aware. `it`/`at` — Vim's *tag* object — means
an HTML parser so this option allows us to implement that parsing externally:

        textobj t lvi-textobj-tag

`cit` changes inside the enclosing element, `dat` deletes the whole tag,
`yit` yanks its contents.

The script is a **tolerant angle-bracket balancer, not a
validator** — the buffer you're editing is usually not well-formed, so it has to
be: it skips `<!-- comments -->` and `<!doctype>`, treats void elements (`<br>`)
and self-closing `<foo/>` as opening no scope, ignores `<`/`>` inside quoted
attributes, and balances nested same-name tags. A strict parser would fail on the
half-typed markup that is the normal case. It's ~80 lines of `awk`; a
tree-sitter-backed `if` (function) or `ia` (argument) object would slot in the
same way (see the filter contract above), trading startup cost for _real_ grammar.

### `lvi-incr` — increment / renumber, since there's no Ctrl-A

lvi has no `Ctrl-A`/`Ctrl-X`, and doesn't need them: the `!` operator already
pipes a line range through any command, so incrementing is just a filter you pipe
*to*. `lvi-incr` reads lines and rewrites the first number on each, with one rule
that covers both the point and the visual cases — line *i* of the input gets
`i × step` added:

```
!!lvi-incr           +1 on this line              (point Ctrl-A)
!ip lvi-incr         a 0/0/0 column → 1/2/3       (visual g Ctrl-A)
!ip lvi-incr -s -1   the same, downward           (g Ctrl-X)
!ip lvi-incr -b 1    renumber to 1,2,3,…           (fix a reordered list)
```

Leading zeros are preserved (`007`→`008`) and numberless lines pass through. Two
`map <C-a> :.!lvi-incr<CR>` / `map <C-x> :.!lvi-incr -s -1<CR>` bindings put the
old reflex back on one line. It's the clearest demonstration of the point — a
whole editor feature that ships as a filter because the operator already exists.

### `lvi-reflow` — reflow a list, hanging indent and all

`gq` and `!` reflow a range through a filter, and `fmt`(1) does the job until the
range is a list: it won't keep the bullet on line one and hang the wrapped
continuation under the item's text. `par`(1) repeats the prefix — right for `> `
quotes, wrong for `- ` bullets — and `pandoc`(1) only knows Markdown.
`lvi-reflow` reads the selected lines, rewraps each item under its own marker,
nests deeper items, and wraps a plain paragraph at its own indent:

```
!ip lvi-reflow -w 72     reflow this paragraph/list at 72
set fmtprg=lvi-reflow    then gqip / gqq reflow lists (vim's gq)
```

It knows ordered, roman, and single-letter markers (`1.`, `(iv)`, `a)`, `[3]`),
the bullets `- + o * – •`, and an optional opening bracket: a port of a
hand-tuned vim `formatlistpat`, embedded as one regex you can edit. Reflowing
twice is a fixpoint. Like that pattern, a paragraph-leading `e.g. ` reads as a
list item — tighten the regex if it bites.

### `lvi-surround` — wrap a span in a delimiter pair

Where `lvi-incr` and `lvi-reflow` ride the `!` filter, these two ride `g@` — the
operator whose action is an external command over the motion's span (`:set
operatorfunc=…`, then `g@{motion}`). `!` splices a filter's stdout back over
whole lines; `g@` hands the span to the tool through the environment and lets it
edit over the socket, so it reaches *part* of a line — a charwise motion carries
byte columns, not just line numbers. That is what surround needs: `g@iw` wraps
the inner word, `g@$` to end of line, `g@@` a whole line (delimiters on their own
lines). One argument names the pair — a shell-safe alias, or the literal quoted:

```
map s( :set opfunc=lvi-surround paren<CR>g@
map s" :set opfunc=lvi-surround dquote<CR>g@
map s* :set opfunc=lvi-surround star<CR>g@
```

Now `s(iw` parenthesizes the word and `s*ip` emphasizes a paragraph. Pairs:
`( [ { <`, the quotes `" ' \``, and `* _`. `.` repeats the last one.

### `lvi-comment` — toggle line comments

Also on `g@`, and a *toggle*: if every non-blank line in the span is already
commented it strips the comment, otherwise it adds one — so the same key does
both. `g@ip` toggles a paragraph, `g@G` to end of file. The syntax comes from an
argument (`//`, `#`, `:`, `/* */`, `<!-- -->`, or a shell-safe alias like `hash`
/ `cblock` / `html`) or, with none, from the file's extension:

```
map gc :set opfunc=lvi-comment<CR>g@
map gC :set opfunc=lvi-comment<CR>g@@
```

So `gcip` toggles a paragraph and `gC` the current line. Note vim's `gcc` can't
be a map: lvi's mapper has no timeout, so `gc` fires the moment it's typed and a
`gcc` map is unreachable — for the current line use `gc@` (the `@` is `g@`'s
doubled key) or the distinct `gC`. Commenting is line-wise, so a charwise motion
still toggles the whole lines it touches.

### `lvi-ftype` — per-filetype options

vim keeps filetype settings in `ftplugin/`; lvi keeps them in two shell `case`s.
On `on bufenter` the script maps `$LVI_FILE` to a filetype word — by extension,
or a shebang for the extensionless — then maps that word to options it sets over
the socket: Python at `sw=4` with `ruff format -`, shell at `sw=2` with `shfmt`.
Splitting classify from configure keeps each filetype's settings in one place;
the extension and shebang lists are just two detectors feeding the same word.

```
on bufenter lvi-ftype
```

It ships as a template, since options are personal: copy it to your config dir,
edit the configure table, and point the hook at your copy (`on` takes a shell
line, so `on bufenter ~/.config/lvi/lvi-ftype` works and the name is free).
Options are view-global, not per-buffer, so each rule is total — it sets
everything it cares about and a `*)` default resets the rest, re-run on every
switch so no buffer inherits the last one's. The corollary: a manual `:set`
mid-session lasts only until the next switch, so edit the table for a lasting
change.

One optional line hands the file to `lvi-detect-indent` (below), whose reading
of the actual indentation overrides the table's `et`/`sw` — so a 2-space file
isn't edited at your 4-space default. Content beats name; comment the line out
to key indent off the name alone.

### `lvi-detect-indent` — infer indentation from content

The companion to `lvi-ftype`'s name-based projection: read a file and emit the
`set`-tokens for its established indentation (`et sw=2`, `noet`, or nothing when
it can't tell). vim-sleuth as a filter. If `editorconfig`(1) is installed and a
`.editorconfig` applies, its ruling wins; otherwise it sniffs the head — leading
tabs against spaces, and for spaces the most common indent step as the unit. It
reads the file on disk, not the live buffer, since indentation is a property of
the saved file and a disk read needs no socket (an unsaved or new buffer reads
as inconclusive, leaving the caller's default). Runnable by hand
(`lvi-detect-indent foo.py`) or piped (`… | lvi-detect-indent -`); `lvi-ftype`
calls it as its indent stage.

