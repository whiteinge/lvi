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

**`$LVI_PICKER` is one setting, and it may carry flags.** Every tool that picks
reads it (default `fzf`; `fzy` and `sk` work too), and the value is split into
words — so `LVI_PICKER='fzf --height 10'` in your rc reaches all of them. Rows
are built so any of them work: the column a tool reads back sits at the front of
the line, never behind an fzf-only `--with-nth`.

**`--focus` and `--jump` are separate flags, and both are opt-in.** A standing
rule for every producer that takes them. `--focus` aims `n`/`N` at the list.
`--jump` moves the cursor onto an entry. Neither implies the other — a flag named
for one thing doing two is how a vocabulary rots — so all four combinations mean
something, and a bare run only puts the entries, paints, and sets the counter.

That last part is what makes a producer hookable at all. Forgetting a flag on a
key costs you a jump; a hook that focused would yank `n`/`N` away from your
search and move the cursor on every save. So the invocation that fires
unattended, hundreds of times a day, is the safe one, and the rc says out loud
when it wants more. The rc lines in the tool sections below are prescriptive —
they carry the combination you actually want, rather than the minimum that runs:

```
on write lvi-gitchanges                            " keep the margin current
map \gg :bg lvi-gitchanges --focus --jump<CR>       " walk the hunks
map \e  :bg lvi-lint --focus --jump<CR>             " lint, then go to a finding
```

A producer reached *only* by a keypress has nothing to gate and takes no such
flags: `lvi-search` and `lvi-lsp` focus and land as one gesture, because that is
the gesture. The flags exist where a hook can call the same script.

Producers that refresh also seed from the cursor (`put --at-cursor`), so a re-run
mid-walk keeps your place rather than resetting the index to the top — and it is
what makes `--jump` land on the next entry past the cursor rather than always the
first.

**Three spawn disciplines** — the reason the bindings differ:

- `:silent !CMD` hands over the terminal (drops to and back from the alt screen).
  Use it only for tools that draw or read on their own — `lvi-open`'s picker,
  `lvi-buf`. A tool that only needs a *line* from the user doesn't need this:
  `:prompt / bg CMD` has the editor read it and pass it in `$LVI_INPUT`.
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
(it rides the same idle debounce a keystroke does). Adding a hook composes, so
removing one is per-item too: `:on! EVENT CMD` retracts the hook whose command is
exactly CMD and leaves the event's others in place. That is what lets a tool arm
a hook for a session and take it back down without clearing the event out from
under everyone else on it (`lvi-send`'s on-write runner). `lvi-diff` is how far the
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

**Seams for tool authors.** A tool asking "what file is this?" uses `:path` —
the path verbatim, empty for a pathless buffer, the same value hooks see in
`$LVI_FILE`. Never parse `:f`: its wording is for humans. Cross-view discovery
is one call: `lvi -l`'s third column carries every view's file (`lvi-mirror`
finds its peers this way). Passing a picked or stored name to a file
command uses the literal spelling `:e -- NAME`: no shell expansion, nothing to
escape. A multi-command edit interleaves `:undojoin` so the whole thing
reverts under one `u` (`lvi-diff`'s hunk moves, `lvi-mirror`'s syncs), and any
delete a tool pushes should name the black-hole buffer (`:d _`) so a
background edit never rotates the user's delete history or feeds a clipboard
backend. `on exit` fires once at a clean quit, the place to save external
state (`lvi-pos`'s last position). But the socket is closing by then, so an
exit hook reads `$LVI_*` and the disk, never calls back. `:hooks` lists what a view has wired,
for debugging; a script never reads hook state to decide anything —
re-registering is idempotent (`:on` drops identical duplicates).

**Errors must land where the user looks.** Every documented binding discards
stderr (`:bg`, hooks) or repaints over it (`:silent !`), so a bare `echo >&2`
is invisible. A one-shot failure goes to the status line with `:msge`. A
condition that repeats on every hook fire — a buffer over the size cap, a
missing adapter — goes in a named `:status` segment that the next successful run
clears, so it neither nags nor outlives the problem. And a missing backend
binary is an error (`command -v` guard, exit 127), never an empty success:
`lint [0/0]` must always mean clean.

**The scripts have headless tests.** `test/contrib_test.lua` (run by `make
test`) checks the pure filters against golden output and the socket-driven
scripts against `test/stub-lvi`: point `LVI=` at the stub and the script's
whole socket conversation lands in a log file to assert on — no editor, no
tty. A new tool should ship a case there; only picker/tty flows stay manual.

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

**The synchronous filter contracts** (for adding a text object or a motion).
These are the odd members of the family: the only tools lvi launches
**synchronously and itself**, not via a map or a hook. When an operator meets
`i`/`a KEY` with no builtin, or a key registered by `:motion` is pressed, lvi
shells the tool out and *blocks* for its answer — the same discipline as a `:s`
sent to the system `ex`, and for the same reason. Because the answer arrives
through the ordinary coroutine path, `c` (change) enters insert mode exactly like
a builtin `ci(`, and `d/foo` gets its range before the command ends. An async,
socket-callback design (the tool phones the edit back in over `lvi -w`) was the
first sketch and was dropped — a non-blocking channel can't cleanly hand you
insert mode mid-edit, a list that arrives *after* the operator is no use to it,
and blocking on a fast local filter is imperceptible. Both take the buffer text
in a private temp file and the cursor 1-based in bytes, and both print one line:

- `:textobj KEY CMD` → **`CMD TMPFILE i|a LINE COL`** → `char L1 C1 L2 C2`
  (charwise, inclusive, byte columns), `line L1 L2` (whole lines), or nothing for
  "no object here" (a clean no-op). `lvi-textobj-tag` implements `it`/`at`; a
  tree-sitter object would be another.
- `:motion KEY [prompt] CMD` → **`CMD TMPFILE COUNT LINE COL ARG`** → `char L C`
  (charwise, byte column, exclusive like vi's search; a trailing `incl` makes it
  inclusive), `line L` (whole lines), `err TEXT` for the message line, or nothing
  for a silent no-op. The key then behaves like any other motion — bare it moves
  (jump-class), after an operator it supplies the range. `prompt` makes the
  EDITOR read a line first under `KEY` as the prompt character, since a filter is
  a child of an editor holding the terminal in raw mode and a `read` of its own
  would take raw keystrokes with no echo. `lvi-search --motion` implements `/ ?
  * #`.

A builtin binding of the same key always wins, so a `:motion` fills unclaimed
keys and never shadows `w`. A `map` on that key doesn't collide with it either:
maps expand only for the **first key of a command**, so a bare press takes the
map and an operator-pending press takes the motion. That is what lets `/` be a
list producer and `d/` a motion at once.

**The BRE locator.** Three tools here need the same unlikely thing: vi's own
regex dialect *and* the column a match landed on. Neither obvious tool has both —
grep speaks BRE but won't say where a match sits, awk reports offsets but in ERE,
where `foo(` errors and `a+b`, `(x)` and `x|y` all quietly mean something else,
and a BRE-to-ERE translator is incomplete by construction since back-references
have no ERE spelling. But *locating* a match is a different job from *finding*
one, and it needs no second dialect — only a BRE engine that reports position.
sed is one: `&` in an `s///g` wraps every leftmost-longest match in a marker byte,
and awk counts the offsets. `lvi-bre-locate` is that, on its own, printing
`LINE⇥COL⇥LEN` per occurrence; `lvi-search` (in both its shapes) and `lvi-match`
shape those into entries, marks or a target. It owns the case-folding
fallback (sed's `I` flag where there is one, `tr` where there isn't) and the
whole-word test, and its exit status separates a bad pattern from a buffer that
holds a marker byte — which each caller reports its own way.

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

A **list** is a plain file of `file:line[:col]:text` entries — the GNU
error-message format (GNU Coding Standards §4.3), which Vim calls the quickfix
format and which grep, a compiler, and a linter all speak. Vim's multi-line
variant works too: each `file:line:` header may carry indented body lines (a
compiler note, a full diagnostic), and `n`/`N` step through the headers while
the bodies are available via `lvi-list preview` to show on demand.

The column is optional **per entry**, so the two shapes mix in one list: a
producer that can't name one (grep reports lines; a diff hunk has none) just
leaves it out. GNU's other spellings work too — `file:line.col`, and the ranges
`line1.col1-line2.col2`, `line1.col1-col2` and `line1-line2`, which bison emits
and which land on their start.

Tools disagree about what a column *counts*. GNU prescribes display cells with
tabs expanded, most linters count characters, and lvi counts bytes; the three
agree on ASCII without tabs, so the mismatch shows up only as a cursor landing
near a complaint instead of on it. A number can't say which it is, so the
producer declares once — `lvi-list put --cols=char|display` — and lvi converts,
since only the editor has the line's bytes to convert with.

A second declaration, `--paint=`, says what the mark *looks* like. A list is
either something you read or something you see, and only the producer knows
which. The default is `gutter` — a glyph in the left-margin column named after
the list, scanned down the edge of the screen. That is right for a linter, whose
lines you read: lighting the offending token would bury the very text you are
scanning. It is wrong for a search, where the match *is* what you are looking at,
so `--paint=extent` lights each entry's own range in place and `--paint=cur`
lights only the one you are standing on.

A margin column costs a screen column, so it needs turning on: `set
gutter=number,lint,todo`, and a column no rc line names draws nothing. In
exchange, a line that is both a lint hit and a todo shows both, each in its own
column — one cell per list rather than one cell shared. It also works where an
extent cannot: an extent needs byte columns, since `:hl` takes byte ranges and
lvi-list cannot convert (a col-bearing entry's text is a message rather than the
line), so a char or display list marks the margin instead of mispainting. The
`lvi-list` header lists who reads a column and who ignores it.

`lvi-list policy NAME POLICY` is the user's say — `put` leaves a stored policy
alone unless the run named one — so one rc line changes how `lvi-lint` or
`lvi-gitchanges` paints without editing either.

**The glyph is the producer's, per line.** `lvi-list marks NAME` takes a second
stream — `FILE:LINE<TAB>GLYPH[<TAB>GROUP]` — stored beside the entries and
replayed on every repaint. `lvi-list` never learns what a glyph *means*, which is
the point: `lvi-lint` sends `E`/`W`, `lvi-gitchanges` sends `+`/`-`/`~`, and no
table inside `lvi-list` could hold both without growing with every producer that
arrives. Each mark also names its own `hi` group, so the rc themes the producer's
vocabulary (`LintError`, `GitAdd`) rather than a list. A producer that sends no
marks gets the single glyph its policy names.

Keyed by line, not by entry, and that buys the interesting case: one git hunk
carries `+` on the lines that were added and `~` on the ones that replaced
something — gitgutter's rendering, out of a plain `git diff`. One mark per line,
so a line bearing both an error and a warning is the *producer's* call to
resolve; `lvi-lint` folds it to the more severe. Entries stay 1:1 with findings
either way, so `n` still steps both and shows both messages. A mark is a per-line
summary of a list, not a rendering of it.

Painting there is also the only way to draw a **multi-line** extent. An entry
spelled as a GNU line range — `f.c:4-9: text` — marks every line it covers,
which is a git hunk as a bar down the margin rather than a mark on its first
line. `:hl` can't express that: one range covers one line, which is why
`lvi-list` read the range's end line and threw it away until there was a margin
to draw it in. `lvi-gitchanges` now emits hunks that way, and nothing is asked
of a producer beyond the spelling GNU already defines.

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
it searches the *live* buffer (so it finds unsaved text), builds the `search`
list, focuses it, and jumps to the first match past the cursor. Search is
simply a degenerate quickfix. Bind `/` and `?` to prompt, `*` and `#` to hunt
the word under the cursor; `n`/`N` do the rest.

```
map / :prompt / bg lvi-search -- "$LVI_INPUT"<CR>
map ? :prompt ? bg lvi-search -b -- "$LVI_INPUT"<CR>
```

The editor reads the pattern (`:prompt`), so the tool never needs a terminal.
The only one it could prompt on is the one `:!` hands over — cooked mode,
primary screen — where the tty's line editor decides what the keys mean.
`:prompt` keeps them lvi's: Esc cancels, Backspace erases a whole character. And
with nothing interactive left to do, the search runs under `:bg`. The pattern
travels in the environment, so a space or a `$(...)` in it is text, not syntax.

Patterns are POSIX BREs, vi's own dialect, and every entry carries the match's
extent, so `n` steps occurrence by occurrence and the match itself lights up
instead of the line getting a margin mark. Neither comes free from the obvious
tools. grep speaks BRE but will not say where a match sits; awk reports offsets
but in ERE, where `a+b` and `x|y` quietly mean something else. sed does both: `&`
in an `s///g` wraps each match in a marker byte and awk counts the offsets, which
is a BRE engine reporting a position rather than a second dialect to learn. The
`lvi-search` header has the mechanics and the two cases it cannot cover.

A search starts where you are, as vi's does — the list is seeded from the
cursor, then stepped once. Three deviations come with search being a list you
walk rather than a motion the editor repeats. It doesn't wrap: `n` stops on
the last match and says `(end)` in the status line, and `lvi-list first` /
`last` are the wrap done by hand. `n` is always forward, since a list
remembers its index but not which way it was seeded, so after a `?` it's `N`
that keeps going back. And `n` walks the buffer as it was when you searched.
All three are the list's; the motion shape below is vi's on every one.

You read an entry two ways. Stepping echoes its text to lvi's **message
line** via `:msg` — ephemeral, cleared by your next motion, so a lint
message is visible as you step. The full entry (header + body) is available
via `lvi-list preview` on stdout; bind it to a `tmux display-popup` to see
the whole multi-line message. That popup key defaults to the **most recent**
stepped list, meaning a custom `]e` map steps `lint` without stealing `n`/`N`'s
focus, yet the preview key still shows the lint entry you just navigated
to. (`:msg`/ `:msge` are the generic in-editor notice mechanism. `:msge`
styles it as an error via the `Error` group.)

Lists are ephemeral and live beside the view's socket (auto-cleaned per
view); use `lvi-list save`/`load` to persist a list to a location that
isn't automatically cleaned. See the `lvi-list` header for all arguments.

### `lvi-search --motion` — search as a *motion*

A list is the wrong shape for `d/foo`. An operator needs its target before the
command finishes, and a list arrives over the socket afterwards, so the list
shape can move you but can never be an operator's range. The `:motion` seam is
the other half — a synchronous filter, run the way `:textobj` is run (see **the
synchronous filter contracts** above), that prints one target and exits. Same
script, one flag:

```
motion / prompt lvi-search --motion       " /pattern
motion ? prompt lvi-search --motion -b    " ?pattern
motion * lvi-search --motion --word       " the word under the cursor
motion # lvi-search --motion --word -b
```

These go *alongside* the maps above, on the same keys. A bare `/` still builds
the list; `d/foo` deletes up to the match, `y?bar` yanks back to one, and every
one of them is jump-class, so `Ctrl-O` and `` ` `` come back. The keys don't
fight because lvi expands maps only for the first key of a command: the press
that follows an operator never sees them.

The editor does the prompting (that's what `prompt` in the rc line asks for),
and the pattern is a POSIX BRE from the same `lvi-bre-locate`. On this side the
search **wraps**, because a motion that stops dead at the end of the buffer is
not the motion vi has, and it re-runs the matcher against the buffer as it is
*now* rather than walking a snapshot, so nothing goes stale as you type.

Both shapes share one stored pattern, beside the socket. It records how the
search matched (whole-word, case folding) and not just what it matched, so a
`/foo` and a later `d/` can never disagree, and an empty pattern repeats the
last one like a bare `/<CR>`. That shared store is why the two are one script.

`n`/`N` stay with the list on purpose. Bare `n` steps whichever list is focused
— lint, spell, git hunks — so a `dn` meaning "the next search match" wouldn't
mirror it. To delete back to a spot you reached by stepping a list, use the
previous-context mark instead: `d` followed by two backticks. Every list step is
jump-class, so the mark is already where you left. `motion n lvi-search --motion
--last` works if you want it anyway.

### `lvi-match` — sticky pattern marks (vim's `matchadd`)

Search answers where the next occurrence is. A match answers where all of them
are while you read: `lvi-match add fox` paints every occurrence in the live
buffer and keeps repainting as you type, until `del` or `clear` takes it away.
Vim's `matchadd()` / `matchdelete()`, as a command.

Each pattern gets its own `:hl` group — `match1`, `match2`, …, colored by
default at `pri=12`, above syntax (0) and search (10) — so the three
identifiers you are tracing through a function read apart at a glance. `-g`
puts several patterns in one group, and one color, when they are one family.
Patterns are POSIX BREs, the same dialect as `/` — a mark needs a column range,
which `lvi-bre-locate` reports without a second dialect to learn.
`-F` takes the pattern literally, `--word` is grep's `-w` (what makes
marking the cursor word behave), `-i` folds case. The first add installs the
`change`/`bufenter` hooks itself, so the rc needs only keys and, if you don't
want the built-in palette, your own `hi match1`… lines.

### `lvi-gitchanges` — step your git diff

The second `lvi-list` producer, and a one-line proof that "any tool that speaks
`file:line:text` is a quickfix": it turns `git diff` into a `gitchanges` list —
one entry per hunk, each carrying that hunk's own diff as its body — so `n`/`N`
walk your uncommitted changes and `lvi-list preview` shows you the diff behind the
one you're on. Unlike `lvi-search` it reads the file on **disk** (or the index),
not the live buffer, so it shows changes since your last `:w` / `git add`.

`--focus` aims `n`/`N` at the hunks and `--jump` lands you on one; bare, it only
puts the entries and paints, which is what makes it usable from `on write` (see
the flag rule above). Painting into a gutter column gives you `+`/`-`/`~`
per line rather than one mark per hunk — gitgutter's rendering, out of the same
`git diff`.

Three flags answer the three questions you have while building a commit, and
they're git's own three diffs:

| flag              | what it shows               | git                     |
| ----------------- | --------------------------- | ----------------------- |
| `--unstaged`      | what's left to stage        | working tree vs index   |
| `--staged`        | what you're about to commit | index vs HEAD           |
| `REF`, `REF..REF` | what was committed          | `git show` / `git diff` |

Bare `lvi-gitchanges` is deliberately none of those: working tree vs HEAD,
everything uncommitted whether staged or not — the view you want when you aren't
mid-stage. Each mode gets its own list (`gitchanges`, `gitunstaged`, `gitstaged`),
so they coexist and you can theme them apart. `--staged` is also the set you'd
pick from to take something back *off* the index, and it pairs with
`lvi-stagediff`: step exactly the hunks you just moved there, folds and all.

It scopes itself to where it was run from. Inside lvi, `$LVI_FILE` is in the
environment, so you get the current file's hunks rather than the repo's; `--repo`
opts out. Deleted files are dropped either way, and the run says how many: a
deletion's hunks have no destination, so an entry for one would land you in a
file that isn't there. Renames are kept, since their line numbers point at the
new path, which does exist.

Run from a shell, it has no view to push into, so it **prints** the list instead
of reaching for `-w auto` and steering whichever session happens to be up. That
makes the outside-in path plain composition rather than a launcher:

```sh
lvi-gitchanges HEAD~3.. > qf && lvi -q qf
```

`lvi -q` is vim's `-q`: it parks the file in `$LVI_QUICKFIX` and fires `ready`,
and the `on ready` line in `lvirc.sample.vim` loads it. That flag is the bridge
for any outside-in producer, not just this one: a compiler run, a `grep -Hn`,
your own script.

Worth an alias, since that is how you will actually reach for it:

```gitconfig
[alias]
	qf = "!f() { t=$(mktemp); trap 'rm -f \"$t\"' EXIT INT TERM; lvi-gitchanges --print \"$@\" > \"$t\" && lvi -q \"$t\"; }; f"
```

`git qf` steps your uncommitted changes, `git qf HEAD~3..` a range, `git qf
--staged` the index. Three details earn their keep. The `f() { ...; }; f`
wrapper is there because git appends the alias's arguments *in addition to* any
`$*` you write, so a bare command sees them twice. `--print` is explicit rather
than implied, so running `git qf` from a `:!` shell inside lvi doesn't push into
that view *and* open a second editor. And the `&&` is what the exit status is
for: no changes, no editor.

A temp file, not `lvi -q <(lvi-gitchanges ...)` — git runs `!` aliases under
`/bin/sh`, where process substitution may not exist at all, and a substitution
has no exit status for the `&&` to read.

### `lvi-lint` — any linter, as a list

The producer behind "a compiler is a quickfix": run a linter over
the **live** buffer (unsaved edits included), normalize its complaints, and step
them like any other list — `on write lvi-lint` re-lints every save, and the
status counter doubles as a pass/fail glance (`[0/0]` = clean).

Vim grew the `errorformat` mini-language to understand output from many
producers, but we've opted to put the onus on the tool itself (or a wrapper
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
editor: one aspell/hunspell pass over the live buffer builds a `spellbad` list
whose entries carry each misspelling's exact extent, and `--paint=extent` makes
that list its own overlay — the words are marked where they sit, and `]s`/`[s`
step them, off one set of positions. It can be toggled on and off. `z=` picks a
correction through your `$LVI_PICKER` choice and splices it in place; `zg` adds
the word to your personal dictionary.

Whole-buffer for simplicity and by design — spell-checking code will
mean some unwanted visual noise so toggle it on and off as needed. See the
`lvi-spell` header for the ispell-protocol details and caveats.

### `lvi-invis` — see invisible characters

Vim's `:set list`, in two halves. The **toggle** paints tab runs, trailing
whitespace, and no-break spaces through three `:hl` groups (`invistab`,
`invistrail`, `invisnbsp`), re-scanning as you type, so a stray tab shows
while you edit next to it. **`page`** pipes the live buffer (unsaved edits
included) through `cat -vet` into less, opened
centered on the cursor line — exact glyph notation for every byte, including
what the overlay can't style (a stray CR, zero-width characters). Theme the
groups or nothing shows — with a `pri=` above your syntax theme, or the
slower repaint takes the cells; the `lvi-invis` header has the bindings and
the byte-column caveats.

### `lvi-hl-col` — mark what runs past a column limit

Vim's `colorcolumn`, as an overlay. While on, whatever runs past the limit takes
a styled mark, re-scanned as you type. It enforces nothing: the marks say a line
is too long and `gq` is what fixes it, which is why a file type's limit and its
reflow width come from the same table row.

A rule is a list of `[LINES:]COL[:GROUP]` items. Line-specific items *compose*
and a `*` catch-all covers the lines none of them claimed, so **one line can
carry two limits**. That is what a git commit subject wants:
`1:50:subjectlong 1:72:subjecterror` marks it amber past the 50 columns git's
docs ask for, red past the 72 where `git log`'s four-space indent stops fitting
an 80-column terminal and forges begin eliding. Each tier stops where the next
begins, so the two paint side by side instead of stacking and leaving `:hl`'s
z-order to break the tie. Vim can't say this: `colorcolumn` takes a list of
columns and paints all of them with one highlight group.

The shipped commit arm marks that subject and nothing else. A commit *body* has
no hard limit — nothing truncates it, the 72 is convention — so marking every
line you hadn't reflowed yet was noise, and `gq` at 72 is still what wraps it. An
item that doesn't parse is named in the status segment and skipped, since an
unchecked column reads a typo as column 0 and marks every line whole.

Set the rule by hand (`:bg lvi-hl-col 72`) or let `lvi-ftype` push it per file
type, where an arm can also ask for the marks to show on entry (`mark=on`, which
commit and mail set: going over is a mistake there, not a preference).
Everywhere else the table sets only the number and `\ho` decides whether it
shows. Theme the groups or nothing appears, with `pri=` above your syntax theme.
A mark can only cover bytes that exist, so this marks the overflow instead of
drawing an empty guide column on a short line — that half would need the
renderer, and the overflow is the half you act on.

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

### `lvi-buf` — switch to an open buffer

`:ls` in the same picker, over the buffers you already have open — pick a row,
the view switches. `bn`/`bp` step cyclically and skip scratch buffers, so this
is how you reach a man page or a `:cmdwin` without knowing its index, and how
you get to the fourth file without pressing `bn` three times. Bind it: `map \b
:silent !lvi-buf<CR>`.

A picker needs the terminal, so it runs under `:silent !` — which freezes the
event loop, so it can't ask for `ls` over the socket any more than `lvi-tags`
can ask for `%p`. It reads the listing out of `$LVI_BUFS` instead, which lvi
puts in every child's environment. Nothing can renumber the buffers while the
picker holds the tty, so the index it picked is still the index it sends.

### `lvi-cmd` — find the binding you forgot

The same picker over your own configuration: every key you have mapped, and
every `lvi-*` tool on your `PATH`, in one flat list. Bind it: `map \c :silent
!lvi-cmd<CR>`.

A binding you press ten times a day needs no help. The one you set up two months
ago has faded, and so has the name of the tool behind it, and the ex prompt has
no completion to jog either. Both are already written down: the keymap inside
the editor, the purpose on the first line of each tool's header. This puts a
fuzzy matcher over the two and sends your choice back to the view.

```
key  \ll              :silent !lvi-list switch<CR>
cmd  lvi-list         external quickfix/location lists for lvi.
```

A `key` row prints its RHS, which is why there is no third row kind saying
"`lvi-list` is bound to these keys": type `lvi-list` and every binding that runs
it comes up beside the tool itself. The picker does that join for free.

Picking a `key` row sends `normal LHS`. The keys go in through the funnel the
keyboard uses and expand there, so it is exactly as if you had pressed them.
Picking a `cmd` row *seeds* the `:` prompt with `silent !NAME` and stops, since
only you know whether that tool wants a range, arguments, or nothing at all.
Under fzf the preview pane runs `NAME --help`: the tool's full reference, beside
its one-line summary.

The keymap comes from `$LVI_MAPS`, the same trick as `lvi-buf`'s `$LVI_BUFS` and
for the same reason — the picker holds the tty, so it cannot ask for `map` over a
frozen socket. The tool half needs no editor at all. It is a `PATH` glob and a
read of each script's header, a few milliseconds with no forks, so it runs fresh
every time and a tool you installed a minute ago is in the list.

It is also why lvi has no command aliases. An alias name fades the way a map
does, and it would squat permanently on a name lvi might later own or the system
`ex` already does. A picker over what is already there costs no namespace.

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

Three more commands act on the file itself rather than on a path argument.
`lvi-mv DST` moves or renames the file and the buffer together, `lvi-rm`
deletes it and drops the buffer, and `lvi-sudow` writes it as root when you
opened it without sudo. Each is a short sequence whose order matters and whose
failure is quiet: move the file without repointing the buffer and the next `:w`
silently recreates it at the old path. `lvi-mv` repoints with `:f`, which
renames the buffer without writing it, so unsaved edits stay unsaved. That is
the difference from `lvi-saveas`, which saves as part of renaming.

`lvi-help` prints the whole set with recipes, and entering a shell-out prints a
two-line banner pointing at it. The prompt tag has room to say you are in one
but not what that costs: lvi is stopped behind you, and anything you send waits
for your exit. Set `LVI_SHELL_BANNER` empty to silence the banner.

This will change the shell prompt to denote you're in an lvi shell and
the file you were editing `(lvi foo.txt) $`.

### `lvi-tags` — jump around / outline the current file

A `ctags` picker: lists every tag defined in the current file, in file order,
and jumps to the one you pick. Because each row shows the tag's own definition
line, scrolling the picker *is* a structural overview of the buffer — "jump
to a function" or "what's in this file". It re-tags the **live buffer**,
not from an on-disk`tags` file, so it reflects your unsaved, in-progress
edits. Bind it: `map \t :wbuf<CR>:silent !lvi-tags<CR>` (`:wbuf` snapshots
the buffer so the picker can read it — see the spawn disciplines above; keep
the `:wbuf` prefix, or the picker tags a stale earlier snapshot).

There is no `readtags` in the pipeline: `readtags` indexes and queries an
on-disk `tags` file, but here ctags' own stdout *is* the query result —
every tag comes from this one buffer by construction, so there is nothing
to filter and nothing for a `tags` file to add.

### `lvi-lsp` — definition and references, from a language server

Two questions a language server answers better than `ctags` can: `def` jumps to
where the symbol under the cursor is defined, `refs` lists every use. Both land
as `lvi-list` lists, so stepping, painting and the counter come from the shared
machinery, and `def` jumps to its first hit rather than assuming there is only
one.

```
map <C-]> :bg lvi-lsp def<CR>          " vi's tag jump
map \u    :bg lvi-lsp refs<CR>         " usages
map ]u :bg lvi-list next refs<CR>
map [u :bg lvi-list prev refs<CR>
hi def bg=22 pri=12                    " un-themed = invisible, so theme it
hi refs bg=22 pri=12
```

Where ctags matches names, a server resolves *imports*: on a project whose
modules re-export through a barrel file, `def` on `core.lanesFromLanes` follows
the alias and the re-export to the line that defines it, and `refs` scopes its
hits instead of finding the word in a comment. That is the reason to want one.

**`def` is complete; `refs` is as complete as the graph.** A definition lies
along an edge leading *out* of the file you are in — the import you can see — so
a server handed that one file can always follow it. References point the other
way, and a one-shot server knows only the modules the open file reaches. In the
project the example above comes from, asking for the uses of `lanesFromLanes`
from a file that consumes it answers with ten or eleven; asking from the file
that *defines* it answers with none, because nothing points in yet. `refs` names
the graph it searched when it comes back empty, so the surprise is explained
where it happens. That asymmetry, not the second of latency, is the strongest
argument for a resident server.

**One-shot, by design.** The server is spawned, asked one question, and killed.
The cost is real: a server does its project load lazily on the first query, so a
press costs a second or two where a warm one would answer in tens of
milliseconds. What it buys is no daemon to manage and no synchronization to get
wrong — the buffer text goes over with the question (`didOpen`), so the answer is
about the buffer as it is now, unsaved edits included, and no mirror can drift.
If you decide you want the warm one, the client is the same either way; only
where the process lives would change.

The adapter contract is `lvi-lint`'s, cut down: an executable `lvi-lsp-<name>`
beside the script gets the buffer's filename and prints how to run the server,
the LSP `languageId` for that file, and the `initializationOptions`.

```
cmd=deno lsp
languageid=javascriptreact
init={"enable":true,"lint":true,"config":"/path/to/deno.json"}
```

`deno lsp` ships as `lvi-lsp-deno`. `$LVI_LSP_CMD` names a server directly, for
trying one before writing its adapter — which is also how the tests drive a
canned server with nothing installed.

Positions are the fiddly part if you write an adapter. LSP counts lines from 0
and columns in **UTF-16 code units**; lvi counts lines from 1 and columns in
bytes. Both conversions here walk the actual bytes of the line in question, so
they are exact rather than only right on ASCII: a hit on a line with multibyte
text before it still lands on its symbol, and the entries carry byte columns,
which is what lets a list light the extent instead of falling back to a margin
mark.

It is written in LuaJIT — lvi's own runtime, so no new dependency — with two
FIFOs carrying JSON-RPC and a small JSON reader inline. `$LVI_LSP_DEBUG` names a
file for the transcript and the server's stderr, which is where to start when a
server answers nothing: several treat a missing option as "this project is not
mine" and reply `null` with no error at all (Deno wants `enable`, and an import
map needs `config`).

What it leaves alone: hover, rename, and diagnostics. Diagnostics already have a
tool that needs no server (`lvi-lint`), and the other two want somewhere to put
the answer that a list is not.

### `lvi-fold` — collapse the buffer by structure

lvi ships the fold *mechanism* — a closed fold collapses its lines to one
summary row and `j`/`k`/scroll skip over it (`zf`/`zo`/`zc`/`zR`; see the
manpage) — but no fold policy. `lvi-fold` is the policy half. It reads
the live buffer over the socket and pushes the ranges back as `:foldset`,
the same read-compute-paint loop `lvi-highlight` runs against `:hl`. We
ship with three fold methods (contributions welcome): `marker` (vim's `{{{
… }}}`, nested by a stack; the pair is `$LVI_FOLD_MARKER`), `indent`
(each block indented under its parent), and `man` (each rendered-manpage
section under its heading — see `lvi-man`). It replaces the view's folds each
run, so re-running it (by marker or `indent` mode, or `on bufenter` to auto-fold
on open) re-folds after edits — and because `:foldset` keeps the open/closed
state of any range that survives the replacement, a re-run never re-closes
the folds you opened.

It reads the buffer, so it self-backgrounds (or bind it with `:bg`) for the same
reason `lvi-highlight`/`lvi-search` do — see **Self-backgrounding** above. Any
other fold policy (by syntax, by diff hunk, by `git` conflict markers) is the
same shape: emit `L1,L2` pairs, hand them to `:foldset`.

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

### `lvi-complete` — insert-mode word and path completion

Insert-mode Ctrl-N/Ctrl-P completion is drawn from **all open buffers**
and invokes your choice of fuzzy-finder.  `on complete CMD` registers a
completer, and the keypress runs it synchronously — handing it the token
you're typing (plus the line's left context) and every open buffer's text,
then splicing its stdout in over the token.

`lvi-complete` is the shipped completer (other contributions welcome). Turn it
on with `on complete lvi-complete`; set `LVI_COMPL_POPUP=1` under tmux to draw
the picker in a `display-popup` over the editor instead of taking the whole
screen. It splits in two: a **source** produces candidates, and `lvi-complete`
runs the picker over them. `lvi-complete-word` is the source that ships — it
de-dupes the buffers' words, current buffer first.

A source is a `lvi-complete-<name>` script that reads the same stdin and
environment and prints candidates, one per line, best first. Each candidate is
a whole replacement for the token, since that is what lvi splices. Sources run
no picker of their own: that lives in `lvi-complete`, so `$LVI_PICKER` and the
popup are configured once and every source gets both. (The `lvi-hl-<name>` and
`lvi-lint-<name>` adapters each finish their job alone; here the picker is the
shared part.)

Two sources ship. `lvi-complete-word` reads the buffers; `lvi-complete-path`
lists file names under the path you're typing, one directory level per press —
pick a directory and the token ends in `/`, so the next press lists inside it.
Walking down a path is repeated presses, not a loop.

Which source runs is either inferred or forced. A token holding a `/` or opening
with `~` is a path; anything else is a word. That reads the intent right nearly
always, because a path token says so lexically. The case it can't call is the
bare name, where `READ` is both a word in some buffer and the head of
`README.md`. `Ctrl-X f` forces the path source for exactly that case, and lvi
passes the `f` through without interpreting it (see `LVI_COMPL_KIND` in the
manpage). A whole-line or `readtags` symbol source is another script and one
more line in the dispatcher — no change to lvi.

### `lvi-pos` — remember where you were (viminfo's `` `" ``)

Reopen a file and land where you left off. vim keeps this in its `viminfo`
database; lvi keeps it in a **plain-text store** — one tab-delimited
`path⇥line⇥col` line per file under `$XDG_STATE_HOME` — that you can `grep`,
edit, or delete by hand.

No core support was needed: the whole feature is a handful of `:on` hooks
pointed at one script. `save` (on `change`/`write`/ `bufleave`) records the
cursor; `restore` (on `ready`/`bufenter`) looks the file up and drops the
`` `" `` mark at the exact line and column — without moving the cursor, so
you open fresh at the top and `` `" `` carries you back when you ask.

Prefer to resume automatically? `restore -j` also jumps there. Keep `-j` on
`ready` only: bound to `bufenter` it would land after — and steal — a list
tool's cross-file jump. `restore` only touches a buffer sitting at line 1 (a
fresh read), so binding it to every `bufenter` never clobbers the live cursor
of a buffer you're revisiting — lvi already keeps that in memory.

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
walk older/newer, `\yy` picks any entry through `$LVI_PICKER`.

There is **one ring, shared by every view** — a yank in any pane is available in
every other, which is most of what a ring is worth once you have more than one
lvi open, and within a single pane the named registers already hold anything you
meant to keep. It lives beside the sockets, so it is session-scoped rather than a
store that accumulates deleted text across reboots. Only the *cycle cursor* is
per view: "undo my last paste, put the next entry" is view-local state, and
sharing it would pull every other pane out of its cycle mid-press. Entries carry the wid
that yanked them, which `\yy` shows. The ring rides the unnamed register, so it
replaces neither the numbered registers nor the `+` clipboard — `"+` still
carries text out of lvi entirely; this moves it around inside.

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
scrollbind aligned. A diff that opened its own panes (file mode,
`lvi-stagediff`) starts folded; attaching to views you already had open leaves
your folds alone until you press `zx`, since those folds are yours.
`LVI_DIFF_FOLD` overrides the start state either way, `LVI_DIFF_FOLDCTX` sets
the context.

For implementors: the first cut of scrollbind was a polling daemon reading
each view's `:top` ~10×/s, which flickered (lvi repaints on every socket
event) and starved the idle `on change` hook. The `on scroll` hook inverted
it — the editor gained one generic "the viewport moved to line N"
notification, and all the diff-specific logic stayed in the script.

Launch it on two live views — `lvi-diff` (auto-picks the sole pair) or
`lvi-diff WID_A WID_B`. Or hand it **two files** — `lvi-diff old new` — and
it opens them in a **new tmux window**, wires the same diff, and blocks
until you quit the left one: a `vimdiff foo bar` for lvi. That file mode is
also what makes it a git mergetool (below).

### `lvi-stagediff` — `git add -p`, as a diff you edit

A side-by-side `git add -p` (concept borrowed from Fugitive). It opens a split:
**left is the git index** (`git show :file`), **right is the working tree**, so the
diff between them is exactly your *unstaged* changes. It's `lvi-diff` plus two git
pieces, so the highlighting, scrollbind, and hunk maps come free.

The mental model: **the index pane's text is the staged content.** Move a hunk
onto it with `\dp`, pull one back off with `\do`, move a motion's span with
`\dx{motion}` or `g@` — or that same operator typed with a range,
`:L1,L2bg lvi-diff --xfer-range …` — to split two changes `diff` merged into one
hunk. Those are ordinary buffer edits: `u` backs a move out, and nothing touches
git yet. **`:w` on the index pane is what stages** — it hashes
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

It does `par`(1)'s job too, where `par`(1) is the right answer. When every
non-blank line in the range opens with the same leader — `# `, `> `, `// `,
nested `> > ` — the leader comes off, the contents reflow, and it goes back on
each output line. The strip happens first, so a list inside a comment block
still hangs under its own marker. A bullet is never a leader: `- ` on every line
is a list, and the list wins. If one line breaks the pattern the range reflows
unprefixed and says nothing, because a filter's stdout is the buffer. `-p` names
a prefix a block can't declare for itself, `* ` C comments being the case that
needs it.

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

### `lvi-send` — run this line in the pane next door

Buffer text into another terminal pane, and a command re-run there on every
write. Both are the same act: putting a string into the pane you are not typing
in. lvi has no splits and no terminal emulator, so the pane is a real one owned
by your multiplexer and this drives it from outside.

`gs` is the operator, next to `gc` for comment. `gsip` sends a paragraph, `gsG`
to the end of the file, and a charwise motion is trimmed to its columns, so
`gsi(` sends what is inside the parens rather than the lines around it. `gS` is
the current line, and a typed range needs no map at all (`:15,40bg lvi-send`).
The text is the live buffer, so a line you have not saved still runs.

```
map gs :set opfunc=lvi-send<CR>g@
map gS :bg lvi-send<CR>
```

The pane is picked once and remembered beside the socket, which keeps it
per-view. A pane id outliving its pane would send your buffer somewhere
arbitrary. Usually there is nothing to pick. With one other pane in the session
that pane *is* the target; with several, a send stops and says to pick one
instead of guessing.

`lvi-send watch` is the other half. It asks for a command and runs it in that
pane on every `:w`: a test suite on save, with no file watcher and no daemon,
since the editor already knows when you saved. `on write bg tmux send-keys -t
%3 'make test' Enter` is the whole feature, so why isn't it an rc line? The pane
id is different every session, which is the one thing an rc cannot hold. What
you want is per-session and ad hoc: this pane, this command, starting now.
`\xx` re-runs it without saving, `\xq` stops.

Disarming is the part that needed a core change. `:on EVENT` with no command
clears *every* hook on that event, so retracting one would take your linter's
`on write` down with it; `:on!` (above) removes just the one. lvi-send registers
the constant string `lvi-send hook` and keeps the pane and command in a file
beside the socket, so it retracts a string it already knows rather than reading
`:hooks` back to find it.

The pane itself is reached through an adapter, `lvi-send-<name>`, the same shape
as `lvi-hl-<name>` and `lvi-lint-<name>`. tmux is the one that ships. The
contract is three calls — `--check`, `--list`, and `TARGET` with the text on
stdin — so kitty, wezterm or screen is a short script rather than a change here.
`lvi-send-tmux`'s header covers the fiddly part: a multi-line block pasted into a
REPL needs bracketed paste, or a Python prompt auto-indents each line as it
arrives and your indentation comes out doubled.

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

For prose the width you write to is a property of where the text is going, and
names give most of it away: `git commit` hands the editor `COMMIT_EDITMSG`, a
rebase hands it `git-rebase-todo` (where `gq` must not touch a thing — `cat` is
the identity `fmtprg` that makes it a no-op), and an MUA hands it a compose file,
so each arrives at its own width with nothing to press. What a name can't say is
that the `notes.txt` you're drafting in is bound for an email, so a filetype word
as `$1` skips detection and projects by intent — `:bg lvi-ftype mail`, then `:bg
lvi-ftype prose` to go back. Same table, two entry points, and no key for it:
naming the type is the exception, not the routine. It holds until the next buffer
switch re-projects from the name, the same rule as a manual `:set`.

Each arm also carries a `col`, the column limit handed to `lvi-hl-col` (above) —
one limit seen two ways, `gq` wrapping at it and the overlay marking what isn't
wrapped — and `mark=on` where those marks should show without being asked for.

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

