# lvi — Lua vi

**A tiny, POSIX-style modal editor that any program can drive.**

vi has always been great at calling *out* to the shell (`!`, `:r !`,
filters). `lvi` adds a **control socket**, so a shell script, a `Makefile`,
a linter, or a five-line client in any language can call *in* — send it
commands and read back its state.

It runs on **just LuaJIT** — no compiler, no build step, no C dependency — on
Linux, macOS, BSD, and WSL.

- 📖 **[The manpage — `lvi.1`](lvi.1.scd)** is the complete command,
  ex, and configuration reference.
- 🧰 **[`contrib/`](contrib#readme)** is where search, syntax
  highlighting, quickfix, completion, diffing, multi-pane editing, folding,
  linting, formatting and many more live — the external tools that turn
  lvi into an IDE.

## Why lvi?

- **Scriptable from the outside.** Tools can drive the editor, not just the other
  way round. `echo`-easy to automate, and it composes with pipes.
- **One command language, everywhere.** `:ex` commands are what you type in
  the editor, and what a script sends over the socket, and what your config
  file contains — the same ex commands, no second "scripting language." (No
  Vimscript. The shell *is* the extension language.)
- **Full editor power over the wire.** ex commands cover line work; `:normal`
  sends literal keystrokes, so a tool can do *anything* you can at the keyboard —
  `2dw`, `ci"`, a recorded macro — not just line edits.
- **UNIX as IDE.** Search, syntax highlighting, and the bulk of the ex command
  set come from composing programs you already have (grep, a highlighter, the
  system `ex`) over the socket — not from engines living inside the editor.
- **Small and legible.** The whole editor is a dozen small Lua files, with
  everything unsafe or platform-specific quarantined.
- **Modal editing you already know.** Motions, operators, counts, registers,
  insert mode, `.` repeat, macros, undo/redo, and marks.

## What it isn't (non-goals)

- **A Vim/Neovim clone.** No Vimscript, no plugin runtime, no in-process
  extension language. The extensibility comes from external tools: the
  socket plus the shell; the editor process keeps state and logic, then
  farms functionality out via a few hooks and documented APIs.
- **Not a reimplementation of ex.** Unrecognized ex commands are delegated to the
  system `ex` rather than growing lvi's own `:s`/`:g`/`:m`/… A real `ex` ships on
  every system lvi targets.
- **No native search or syntax engine.** Both are external tools feeding the
  highlight overlay; lvi ships no lexers, grammars, or search engine. (See
  [`contrib/`](contrib/) for the ready-made bolt-ons that provide them.)
- **No visual mode.** The operator + motion + text-object model, the `!` filter,
  and the line-oriented ex commands cover its uses and avoid complicating
  the editor; the manual's *Without visual mode* section is the translation
  table.
- **No splits or windows.** One process edits one view; run several side by side
  under whatever multiplexer you already use — tmux, screen, Zellij, or a tiling
  window manager. The socket allows cross-view coordination via scripts
  (see [`contrib/lvi-diff`](contrib/)). (Multiple buffers *within* a view
  are supported; on-screen splits are not.)
- **UNIX only.** POSIX environment and standard CLI tools assumed; Windows
  outside WSL is out of scope.

## Quick start

```sh
lvi notes.txt                 # edit a file (h j k l, i/a/o, dd, yy, p, u, :w, :q …)
```

Then, from another terminal, drive that same editor:

```sh
lvi -l                              # list running views: <wid>  <socket>
lvi -w auto -- '%p'                 # print the whole buffer to stdout
lvi -w auto -- 'normal ggdG'        # send normal-mode keystrokes (here: clear buffer)
lvi -w auto -- '120'                # jump to line 120
lvi -w auto -- 'w'                  # save
```

`lvi -w` is a normal Unix filter (data on stdout, errors on stderr,
meaningful exit codes) so it drops straight into a regular shell pipeline:

```sh
# Pull the live buffer through a formatter and diff it:
lvi -w auto -- '%p' | gofmt | diff - original.go

# Batch an edit across every open view:
for wid in $(lvi -l | cut -f1); do lvi -w "$wid" -- 'normal ggdd' 'w'; done
```

Any language can speak the protocol; `lvi -w` is just a convenience client
for locating the socket file.

## What you get

Real modal editing — motions, operators with full composition (`dw`, `cf.`,
`` y`a ``, `2d3w`), registers, `.` repeat, macros, multi-level undo/redo, marks,
**folds** (`zf`/`zo`/`zc`/`zR`, or `:fold` from a tool), and the
scrolling/positioning commands. An ex layer shared by the `:` prompt and
the socket, with **anything lvi doesn't implement delegated to the system `ex`**
(so `:s`, `:g`, `:m`, and the full address grammar just work). A **config file**
that's simply a list of those ex commands. A **styled highlight overlay** (`:hl`
+ `:hi`) and **change hooks** (`:on change …`) — the two primitives that let
external tools paint syntax, search, and quickfix into the view.

Turn those on and you get syntax highlighting, live-buffer search, quickfix
lists, linting, formatting, toggleable spell check, fuzzy file-open — and even
a **two-way vimdiff with scrollbind and a `git add -p` staging UI** — all as
[`contrib/`](contrib/) tools and *none* of it compiled into the core.

👉 **The [manpage](lvi.1.scd) is the full command and configuration reference.**

## Requirements

- **LuaJIT** (2.1) — the whole runtime.
- A POSIX terminal with `stty` (used for raw mode).

No C toolchain, no `luarocks`, no external modules: `argparse` (CLI) and `lust`
(tests) are vendored. Ship the `luajit` binary plus the `.lua` files, or bundle a
single executable with `luastatic`.

Optional, only for the features that lean on them: a system **`ex`** (delegated
ex commands — present on every UNIX), **`scdoc`** (to build the manpage),
and a highlighter like **Pygments** or **bat** (`contrib/lvi-highlight`).

## Building and installing

```sh
make man       # render lvi.1 from lvi.1.scd (needs scdoc)
make test      # run the test suite
make install   # PREFIX=/usr/local by default; honors PREFIX and DESTDIR
```

`make install` puts the runtime tree under `$(PREFIX)/lib/lvi`, a launcher and
the `contrib` helpers on `PATH`, and the manpage under `$(PREFIX)/share/man`.

---

## Design & implementation

A few design decisions shape `lvi`. Each is small; together they're why it
needs no build step, no plugin runtime, and no embedded scripting language.

### The platform layer is quarantined to one file

Everything unsafe or OS-specific lives in `sys.lua` and nowhere else: Unix
sockets, `poll`, terminal size, and the couple of structs that differ across
UNIXes. The hard part of binding libc from a scripting language is `termios` — a
large struct with divergent layouts per OS — so `lvi` never binds it: **raw mode
shells out to `stty`**, pure Lua, zero ABI. What remains needing the FFI is just
sockets + `poll` + a window-size `ioctl`: a tiny, stable surface, with the one
divergent struct (`sockaddr_un`) branching on `ffi.os`.

*Implication:* there is **no build step and no C dependency**, and because the
entire unsafe surface is one small, auditable file behind a plain interface, the
choice of LuaJIT stays **reversible** — swap `sys.lua` for a PUC-Lua + `luaposix`
version and nothing else notices.

### One command dispatcher, three entry points

`ex.dispatch(command) → payload, status` is the single core that executes ex
commands. The `:` prompt, the control socket, and the config file all call it —
the property that makes `tmux` so pleasant (the same tight vocabulary at the CLI,
in the config, and at the command prompt), and vi already *had* that vocabulary
in the form of ex.

*Implication:* `lvi` needs **no embedded scripting language.** The pressures that
bloated Vimscript don't apply: `lvi` is UNIX-only (it can assume `sort`, `awk`,
`sed` exist) and has no in-process plugin runtime. Extensibility comes from three
cheap things — any language can be a client, the ex vocabulary can grow, the
protocol stays stable — while *state and logic live in external programs*, across
a process boundary that keeps the core from drifting.

The dispatcher also has a **fourth exit point**: any command lvi doesn't recognize
is handed to the system `ex`. lvi writes the buffer to a temp file, drives
`ex -s` with a short script (a preamble that mirrors lvi's marks and cursor line,
then the command verbatim), and reads the result back as one undoable change. So
the whole of ex's line editing — `:s`, `:g`, `:m`, addressing — is available
Without lvi trying to faithfully reimplement the whole thing.

### A single input funnel — so `.`, macros, and remote keystrokes are one thing

The normal-mode interpreter is a **coroutine**. Its `getkey()` doesn't read
input; it *yields*, and the main loop feeds it keys by appending to one queue
(`ed.inject`) and resuming. Writing the grammar this way means vi's stateful
commands read as ordinary straight-line code — `2d3w`, `f{char}`, `ci"` — instead
of a hand-rolled state machine, and each motion composes with every operator for
free (a motion returns a target; an operator consumes the range to it).

Because *one* queue is the sole way keys enter the interpreter, four features
collapse into "append keys to the queue":

- **`.` repeat** — replay the last change's recorded keys.
- **Macros** (`q`/`@`) — record keys into a register, replay them.
- **`:normal`** — the socket's normal-mode escape hatch.
- The live keyboard.

Each cost almost nothing to add because the plumbing was shared from the start.
And because the coroutine *parks* between keystrokes, the editor keeps answering
the socket even while you're halfway through a multi-key command.

### A framed, binary-safe control protocol with room to grow

Socket messages are line-tagged and self-delimiting (`%begin` / `%data` /
`%end`), modeled on `tmux`'s control mode. Payloads are **length-delimited**, so
a buffer line that happens to read `%end 1 ok` can't corrupt the frame; dumping
raw buffer text out is always safe. One connection carries
many request/response exchanges, and a `%event` tag is reserved (not yet used)
for a future push/subscribe channel: the *envelope* is locked now so
notifications can be added later without breaking a single existing client.

### The buffer, undo, and rendering

The buffer is an **array of immutable line-strings** — the right fit for a
line-oriented editor, where "give me line N" is O(1). (So the largest
file you can open is bounded by available RAM, and opening is O(file size)
up front, not incremental.) LuaJIT interns strings, so immutability becomes
an asset: every mutation flows through one atomic primitive,
`splice()`, which records an **inverse splice** into an undo log. Undo is
therefore automatic and complete — no edit path can forget to be undoable —
multi-level, and cheap (an inverse stores only the changed lines, shared not
copied). Rendering is **viewport-bounded**: it only ever touches the lines and
columns on screen, so cost is independent of file size.

### Testing

Behavior is covered by tests (`test/`, vendored `lust`): the buffer and its
undo log, the ex dispatcher, the wire protocol (including binary-safety and
chunk-boundary cases), the renderer (a pure function of editor state), and the
coroutine interpreter (driven by feeding it keys). The socket path is exercised
end-to-end by driving a headless editor over its socket.

## License

See [LICENSE](LICENSE).
