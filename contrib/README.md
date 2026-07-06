# contrib — the tools that turn lvi into an IDE

lvi keeps a minimal core and pushes everything else out here: small programs that
drive a running editor over its control socket (`lvi -w …`), feeding the `:hl`
overlay and the `:normal` escape hatch. This is the "UNIX as IDE" bet made
concrete — search, syntax highlighting, and quickfix aren't compiled in, they're
Unix tools composed on from the outside. Nothing here is privileged; each is a
worked example of what *any* program can do to a live view.

Put this directory on your `PATH`. **Each script's header comment is its full
reference** — invocation, every env knob, and copy-paste bindings. This file is
the tour: what each tool is *for*, and the shared machinery they lean on. Copy a
theme and the bindings from [`lvirc.sample`](lvirc.sample).

## The tools

### `lvi-highlight` — syntax highlighting

Pulls the live buffer over the socket, runs an external highlighter, and paints
the tokens through `:hl`. Because it works on the buffer (not the file on disk)
it highlights **unsaved** content, and a still-open string or block comment
colors the rest of the file until you close it. Turn it on in your rc:

    on change   lvi-highlight   " re-highlight a beat after you stop typing
    on bufenter lvi-highlight   " ...and when you switch/open a buffer

Two backends ship, and they *theme* differently:

- **Pygments** (default) is **positional** — it reports token *types* (Keyword,
  String, …) and *you* pick their colors with `:hi` in the rc, one theme across
  every language.
- **bat** is **ANSI** — it has already colored the text with its own theme, and
  lvi reproduces those colors, so you choose the look with `BAT_THEME`, not `:hi`.

Select one with `LVI_HL_BACKEND`; see the `lvi-highlight` header for the rest.

### `lvi-search` + `lvi-list` — search and quickfix

A **list** is a plain file of `file:line[:col]:text` entries — the vim `-q`
format that grep, a compiler, a linter, or `git diff` all speak. lvi knows
nothing about lists: `lvi-list` owns them and drives the view over the socket,
jumping the cursor, painting the `:hl` overlay, and setting a `:status` counter.
Any number of named lists coexist; one is **focused**, and the bare step commands
act on it — so a *single* pair of keys (`n`/`N`) steps search, grep, lint, and
git hunks alike.

**`lvi-search`** is the first producer: it greps the *live* buffer (so it finds
unsaved text), builds the `search` list, focuses it, and jumps to the first
match. Search is just a degenerate quickfix. Bind `/` to prompt and `*` to hunt
the word under the cursor; `n`/`N` do the rest.

Lists live beside the view's socket (auto-cleaned per view); `lvi-list save`/`load`
promote one to any durable path — that's "save this quickfix for later" in a
single file. See the `lvi-list` header for the full verb set.

### `lvi-open` — open a file

A fuzzy-picker (fzf by default) that opens the chosen file in the running view.
Bind it: `map \f :silent !lvi-open<CR>`.

## The shared machinery

Everything above is built from four ideas the core provides — worth
understanding once, because they're all *you* need to write the next tool.

**The `:hl` overlay is the substrate.** One styled overlay (`:hl` paints ranges,
`:hi` themes groups, `pri=N` sets z-order) backs search, quickfix, *and* syntax
highlighting. They only differ in what feeds it: a highlighter emits token
groups, a list emits match groups (search sets a positive `pri` so its matches
draw over syntax). A new visual feature is usually just a new producer of `:hl`.

**Lists are files; focus is a pointer.** Because a list is a file and "which list
is focused" is one more file beside the socket, the state survives across
processes and needs no daemon — any producer writes a list, any stepper reads the
focused one. `on bufenter lvi-list paint` is the glue that repaints the current
buffer's matches when you arrive in it, which is what makes *cross-file* lists
(project grep, a compiler) light up per file.

**Three spawn disciplines** — the reason the bindings differ:

- `:silent !CMD` hands over the terminal (drops to and back from the alt screen).
  Use it only for tools that **prompt** or are otherwise interactive — `/`,
  `lvi-open`'s picker.
- `:bg CMD` runs detached with **no** terminal handover — no alt-screen flash. Use
  it for non-interactive tools fired by a map that may repeat (`map n :bg lvi-list
  next<CR>`). It's the same spawn `:on` hooks use.
- **Self-backgrounding.** A tool that must *read* the buffer (`lvi-highlight`,
  `lvi-search` via `%p`) can't do so synchronously from a `:silent !` child: lvi's
  loop is frozen waiting on that child, so a foreground read would deadlock. They
  double-fork a worker and return at once, letting lvi resume and service the
  worker's socket I/O. `lvi-list` never reads the buffer, so it just fires
  fire-and-forget jumps with `lvi -w --detach`.

**The backend contract** (for adding a highlighter). `lvi-highlight` is a
backend-agnostic harness; a backend is one adapter, `lvi-hl-<name>`, with a
single contract: **buffer text on stdin, filename as `$1`, emit `hl GROUP
L:C1-C2 …` (byte columns) on stdout.** Two shapes ship:

- **Positional** (`lvi-hl-pygments`): walk the tool's token stream, emit named
  groups; style them with `:hi`.
- **ANSI** (`lvi-hl-bat`): pipe the tool's ANSI-colored output through the shared
  `lvi-hl-ansi` parser, which turns each distinct SGR into a `synN` group whose
  style *is* that SGR. `source-highlight`, `tree-sitter highlight`, etc. are thin
  wrappers around `lvi-hl-ansi` (feed it `--wrap=never --tabs=0` so byte columns
  don't desync).
