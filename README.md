# lvi — Lua vi

**A tiny, POSIX-style modal editor that any program can drive.** `lvi` is a vi
clone in the spirit of "UNIX as IDE": instead of growing features inward, it
stays small and leans on the tools you already have — and it opens a door the
original vi never did. Every running editor exposes a **control socket**, so a
shell script, a `Makefile`, a linter, or a five-line client in any language can
send it commands and read back its state.

It runs on **just LuaJIT** — no compiler, no build step, no C dependency to
install — on Linux, macOS, BSD, and WSL.

## Why lvi?

- **Scriptable from the outside.** vi has always been great at calling *out* to
  shell tools (`!`, `:r !`, filters). `lvi` adds the missing half: tools can call
  *in*. `echo`-simple to automate, and it composes with pipes.
- **One command language, everywhere.** What you type at `:` is what a script
  sends over the socket is what your config file contains — the same ex commands,
  with no second "scripting language" to learn. (There is no Vimscript here. The
  shell *is* the scripting language.)
- **Full editor power over the wire.** ex commands cover line-oriented work;
  `:normal` sends literal keystrokes, so an external tool can do *anything* you
  can do at the keyboard — `2dw`, `ci"`, a recorded macro — not just line edits.
- **Small and legible.** The whole editor is a few small Lua files (~1.5k lines)
  with the platform-specific and unsafe parts quarantined to one of them.
- **Modal editing you already know.** Motions, operators, counts, registers,
  insert mode, `.` repeat, macros, undo/redo, and marks.

## What this project is

- **A small modal editor core plus a control socket.** The interesting surface
  isn't the vi commands — it's that the editor is *driveable from outside*, so
  capabilities compose in rather than being coded in.
- **A wager on "UNIX as IDE."** Search, syntax highlighting, and the bulk of the
  ex command set are provided by composing existing programs (grep, an external
  highlighter, the system `ex`) that talk to the editor over the socket — not by
  engines living inside it.
- **Dependency-light and reversible.** LuaJIT only; no compiler, no build step,
  no C dependency. Everything unsafe or platform-specific is quarantined to one
  file, so the runtime choice stays swappable.
- **POSIX vi in feel.** Familiar motions, operators, counts, registers, macros,
  undo/redo, and marks; the modal muscle memory carries over.

## What this project isn't (out of scope)

These are deliberate non-goals — useful as a guardrail for future additions:

- **Not a Vim/Neovim replacement.** No Vimscript, no plugin runtime, no
  in-process extension language. Extensibility is external: the socket plus the
  shell. State and logic live in other programs, across a process boundary.
- **Not a reimplementation of ex.** lvi delegates unrecognized ex commands to the
  system `ex` rather than growing its own `:s`/`:g`/`:m`/… A real `ex` ships on
  every system lvi targets; duplicating it inward is exactly what we avoid.
- **No native search engine.** `/` is not built in; searching means grepping the
  live buffer from outside and feeding the highlight overlay.
- **No native syntax-highlighting engine.** Highlighting is an external tool
  feeding the overlay; lvi ships no lexers or grammars.
- **UNIX only.** It assumes a POSIX environment and standard CLI tools; Windows
  outside WSL is out of scope.
- **Not feature-maximal.** Where POSIX vi/ex or a common CLI tool already does a
  job well, lvi composes with it instead of reimplementing it.

## Quick start

```sh
luajit lvi notes.txt          # edit a file (h j k l, i/a/o, dd, yy, p, u, :w, :q …)
```

Then, from another terminal, drive that same editor:

```sh
lvi -l                              # list running views: <wid>  <socket>
lvi -w auto -- '%p'                 # print the whole buffer to stdout
lvi -w auto -- 'normal ggdG'        # send normal-mode keystrokes (here: clear buffer)
lvi -w auto -- '120'                # jump to line 120
lvi -w auto -- 'w'                  # save
```

Because `lvi -w` is a normal Unix filter (data on stdout, errors on stderr,
meaningful exit codes), it drops straight into shell plumbing:

```sh
# Pull the buffer through an external formatter and diff it — your editor as one
# stage in a pipeline:
lvi -w auto -- '%p' | gofmt | diff - original.go

# Batch an edit across every open view:
for wid in $(lvi -l | cut -f1); do lvi -w "$wid" -- 'normal ggdd' 'w'; done
```

Any language can speak the protocol; `lvi -w` is just the bundled convenience
client.

## What works today

Modal editing: motions `h j k l 0 ^ $ w b e f t F T ; , G gg` and marks
`` m ` ' ``; operators `d c y` with full motion composition (`dw`, `cf.`, `dgg`,
`` y`a ``) plus `dd`/`yy`/`cc` and counts (`2d3w`); `x r p P i a o A I O`;
registers `a`–`z` and the unnamed register; `.` repeat; macros `q`/`@`/`@@`;
multi-level undo/redo (`u` / `Ctrl-R`); scrolling `Ctrl-F`/`Ctrl-B` (page),
`Ctrl-D`/`Ctrl-U` (half), `Ctrl-E`/`Ctrl-Y` (line); insert-mode `Ctrl-W`/`Ctrl-U`
and `Ctrl-A`/`Ctrl-E`. An ex layer (`:w`, `:d`, ranges, `:%p`, `:normal`,
`:u`/`:redo`, `:q`, and line-number goto) shared by the `:` prompt and the
socket — and **any ex command lvi doesn't implement is delegated to the system
`ex`**, so `:s`, `:g`, `:m`, `:t`, `:j`, and the full address grammar work
against whatever `ex` is installed (marks and the cursor line are mirrored in, so
`` :'a,'bs/… `` resolves). A **config file** — just a file of those same ex commands, run at
startup (`$LVIRC` → `$XDG_CONFIG_HOME/lvi/lvirc` → `~/.lvirc`; `"` begins a
comment) — so `:map` and `:set` persist. A **styled highlight overlay**: `:hl`
paints named groups of ranges, `:hi GROUP fg=… bg=… bold underline` (or a raw
`sgr=…`) gives a group a color; an un-themed group renders as plain text.
**Change hooks**: `:on change <cmd>` runs an external command a beat after you
stop typing (debounced, non-blocking, loop-safe).

**Syntax highlighting**, built entirely from those pieces — no language engine
in the editor. `contrib/lvi-highlight` pulls the live buffer over the socket,
runs an external highlighter, and paints the tokens through `:hl`; `on change
lvi-highlight` in your rc keeps it live. Two backends ship: **Pygments**
(positional — you theme token types with `:hi`) and **bat** (brings its own
theme). See `contrib/README.md`.

**Search** is external in the same spirit (see *What this project isn't*):
`contrib/lvi-search` greps the live buffer and feeds matches to `:hl` over the
socket.

## Requirements

- **LuaJIT** (2.1). That's the whole runtime.
- A POSIX terminal with `stty` (used for raw mode — see below).

No C toolchain, no `luarocks`, no external modules: `argparse` (CLI) and `lust`
(tests) are vendored. Ship the `luajit` binary plus the `.lua` files, or bundle a
single executable with `luastatic`.

Optional, and only for the features that lean on them: a system **`ex`** (for
delegated ex commands like `:s`/`:g` — present on essentially every UNIX),
**`scdoc`** (to build the manpage), and a highlighter such as **Pygments** or
**bat** (for `contrib/lvi-highlight`).

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

The interesting part of `lvi` isn't the vi commands — it's a handful of design
decisions that turned out to be unusually clean, and reinforce each other.

### The platform layer is quarantined to one file

Everything unsafe or OS-specific lives in `sys.lua` and nowhere else: Unix
sockets, `poll`, terminal size, and the couple of structs that differ across
UNIXes. The scary part of binding libc from a scripting language is `termios` — a
large struct with divergent layouts per OS — so `lvi` never binds it: **raw mode
is done by shelling out to `stty`**, which is pure Lua, zero ABI, and is itself
the project philosophy in miniature (lean on the tool that already exists). What
remains needing the FFI is just sockets + `poll` + a window-size `ioctl` — tiny,
stable surface, with the one divergent struct (`sockaddr_un`) branching on
`ffi.os`.

*Implication:* there is **no build step and no C dependency**, and because the
entire unsafe surface is one small, auditable file behind a plain interface, the
choice of LuaJIT stays **reversible** — swap `sys.lua` for a PUC-Lua + `luaposix`
version and nothing else in the codebase notices.

### One command dispatcher, three front doors

`ex.dispatch(command) → payload, status` is the single core that executes ex
commands. The `:` prompt, the control socket, and the config file all call it. This is the property that makes `tmux` so pleasant — the same tight
vocabulary at the CLI, in the config, and at the command prompt — and vi already
*had* that vocabulary in the form of ex.

*Implication:* `lvi` needs **no embedded scripting language.** The pressures that
grew Vimscript don't apply here: `lvi` is UNIX-only (so it can assume `sort`,
`awk`, `sed` exist rather than reimplementing them), and it deliberately has no
in-process plugin runtime. Extensibility comes from three cheap things — any
language can be a client, the ex vocabulary can grow, the protocol stays stable —
while *state and logic live in external programs*, on the far side of a process
boundary. That boundary is the firewall that keeps the core from drifting.

The dispatcher also has a **fourth door out**: any command lvi doesn't recognize
is handed to the system `ex`. lvi writes the buffer to a temp file, drives
`ex -s` with a short script (a preamble that mirrors lvi's marks and cursor line
into ex, then the command verbatim), and reads the result back as one undoable
change. So the whole of ex's line editing — `:s`, `:g`, `:m`, addressing — is
available without lvi reimplementing a line of it. It's the same "don't rebuild
what UNIX ships" bet as search and highlighting, applied to ex itself.

### A single input funnel — so `.`, macros, and remote keystrokes are the same thing

The normal-mode interpreter is written as a **coroutine**. Its `getkey()` doesn't
read input; it *yields*, and the main loop feeds it keys by appending to one
queue (`ed.inject`) and resuming. Writing the grammar this way means vi's stateful
commands read as ordinary straight-line code — `2d3w`, `f{char}`, `ci"` — instead
of a hand-rolled state machine, and each motion composes with every operator for
free (a motion returns a target; an operator consumes the range to it).

The quiet win is the funnel itself. Once *one* queue is the sole way keys enter
the interpreter, four features collapse into the same mechanism — "append keys to
the queue":

- **`.` repeat** — replay the last change's recorded keys.
- **Macros** (`q`/`@`) — record keys into a register, replay them.
- **`:normal`** — the socket's normal-mode escape hatch: literal keystrokes from
  an external tool.
- The live keyboard.

Each of these cost almost nothing to add because the plumbing was shared from the
start. And because the coroutine *parks* between keystrokes, the editor keeps
answering the socket even while you're halfway through typing a multi-key command.

### A framed, binary-safe control protocol with room to grow

Socket messages are line-tagged and self-delimiting (`%begin` / `%data` /
`%end`), modeled on `tmux`'s control mode. Payloads are **length-delimited**, so a
buffer line that happens to read `%end 1 ok` can't corrupt the frame — dumping raw
text out of the editor is a first-class operation. One connection can carry many
request/response exchanges, and a `%event` tag is reserved (but not yet used) for
a future push/subscribe channel: the *envelope* is locked now so notifications
can be added later without breaking a single existing client.

### The buffer, undo, and rendering

The buffer is an **array of immutable line-strings** — the right fit for a
line-oriented editor, where "give me line N" is O(1). LuaJIT interns strings, so
this turns immutability from a liability into an asset: every mutation flows
through one atomic primitive, `splice()`, which records an **inverse splice** into
an undo log. Undo is therefore automatic and complete — no edit path can forget to
be undoable — multi-level, and cheap (an inverse stores only the changed lines,
shared not copied). Rendering is **viewport-bounded**: it only ever touches the
lines and columns on screen, so cost is independent of file size.

### Testing

Behavior is covered by ~90 tests (`test/`, using the vendored `lust`): the
buffer and its undo log, the ex dispatcher, the wire protocol (including the
binary-safety and chunk-boundary cases), the renderer (which is a pure function of
editor state), and the coroutine interpreter (driven by feeding it keys). The
socket path is exercised end-to-end by driving a headless editor over its socket.

## License

See [LICENSE](LICENSE).
