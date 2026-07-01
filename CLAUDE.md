# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`lvi` is a minimal, POSIX-vi-style modal editor written in Lua, built on the "UNIX as IDE" philosophy: lean on external CLI tools rather than growing features inward. Its defining deviation from POSIX vi is a **per-view control socket** so external tools can drive a running editor. It targets **LuaJIT** on Linux/macOS/BSD (WSL == Linux).

## Commands

```sh
luajit lvi <file>              # launch the editor (interactive; needs a tty)
luajit lvi -l                  # list running views:  <wid>\t<socket-path>
luajit lvi -w <wid> -- <cmds>  # send ex commands to a running view; -w auto = sole view
luajit test/buffer_test.lua    # run one test file (repeat per file)
for t in buffer ex render proto normal; do luajit test/${t}_test.lua; done   # all tests
```

- Tests use the vendored `lust` framework (`vendor/lust`); each spec calls `os.exit(lust.errors==0 and 0 or 1)`, so a non-zero exit means failures. There is no separate lint/build step.
- `lvi -w` is a Unix filter: `ok` payloads go to stdout, errors to stderr, exit code reflects failure. Over the socket, send ex commands **without** the leading `:` (a leading `:` is tolerated/stripped by the client).
- The dev shell runs zsh with `noclobber`; overwrite redirects need `>!` (e.g. `foo >! out`).
- There is no in-process way to test the tty/render path headlessly (no tty in most harnesses); drive behavior over the socket, or unit-test `render.frame(ed)` (pure) and `normal.lua` (feed keys to the coroutine).

## Architecture (the big picture)

Data flows through a few deliberate choke points. Understanding these four is most of the codebase:

1. **`sys.lua` is the *only* place with FFI / platform-specific code.** Everything unsafe or OS-divergent (termios via `stty`, Unix sockets, `poll`, `ioctl` winsize, `sockaddr_un`) is quarantined here behind a small interface, so the LuaJIT-vs-PUC choice stays reversible. Terminal raw mode is done by shelling out to `stty` (no termios struct in-tree); only sockets+`poll`+winsize use FFI, and the one struct that diverges (`sockaddr_un`, plus the winsize ioctl number) branches on `ffi.os`. **Do not add FFI or platform structs anywhere else.** Its header is a decision record — read it.

2. **`ex.dispatch(ed, line) -> payload, status` is the shared command core.** The `:` prompt (in `normal.lua`), the control socket (in `editor.lua`), and the rc file (`config.lua`) all call it, so a command means the same thing on every surface (the tmux-like "identical at CLI and in config" property). ex commands are the line-oriented API; `:normal <keys>` is the escape hatch into normal-mode keystrokes. **The config file is literally a file of ex commands** — no separate syntax; `config.lua` just reads it and runs each line through `ex.dispatch` at startup (path: `$LVIRC` → `$XDG_CONFIG_HOME/lvi/lvirc` → `~/.lvirc`; `"` starts a comment).

3. **`ed.inject` is the single input funnel.** `normal.lua` is a persistent coroutine whose `getkey()` yields until the driver feeds a key. The keyboard, `.` (repeat), macros (`@`), and `:normal` all work by *appending keys to `ed.inject`* and resuming the coroutine — one mechanism, four sources. `getkey` also logs to `ed.keylog` (→ `ed.last_change` for `.`) and to `ed.macro_buf` while recording. Because the coroutine parks between keys, the `poll` loop in `editor.lua` keeps servicing the socket even mid-command.

4. **The socket is a per-view control channel with a framed request/response protocol** (`proto.lua`). Frame: `%begin <id>\n` then repeatable `%data <N>\n<N raw bytes>` then `%end <id> <status>\n`. Payloads are length-delimited so raw buffer text (e.g. `:%p` output) can never corrupt the frame. The `%event` tag is reserved for a future subscribe/push channel — the envelope is locked, notifications are additive. Socket path policy (`path.lua`): `$XDG_RUNTIME_DIR` → `$TMPDIR` → `/tmp`, then `lvi-$uid/$wid`.

### Module map

`editor.lua` is the driver (view state + the `poll` loop; creates/primes the coroutine; routes keyboard→`ed.inject` and socket→`ex.dispatch`; repaints after every event). `normal.lua` is the coroutine interpreter (motions/operators/insert mode; the **motion/operator model**: a motion returns target+kind(char/line)+inclusive, an operator consumes the cursor→target range, so motions×operators compose for free). `buffer.lua` is an array of immutable line-strings behind a thin line-oriented interface, with the undo log (see below). `render.lua` is the viewport-bounded renderer (`render.frame(ed)` is pure → testable). `config.lua` resolves and runs the rc file through `ex.dispatch`. `ex.lua`, `proto.lua`, `path.lua`, `client.lua`, `term.lua`, `sys.lua` as described. `lvi` is the dual-role entry point (editor vs `-w` client) via vendored `argparse`.

### Key invariants and conventions

- **Buffer**: always ≥1 line; a line never contains `\n`; `noeol` makes read/write round-trip byte-for-byte. All mutations funnel through `buffer.lua`'s `splice(start, ndel, ins)` (atomic remove+insert; in-place O(1) when `ndel==nins`, e.g. per-keystroke `set`). splice records an inverse into the undo log automatically — **no mutation can escape undo**. Undo is multi-level (`u` / Ctrl-R); `undo_checkpoint()` (called at each `command()` start and before each socket `ex.dispatch`) groups records into one user-level change. The undo-state field is `_undo` (avoids colliding with the `:undo()` method).
- **Rendering** is viewport-bounded (touch only visible lines/cols), nowrap for now. See design notes for wrap/long-line/huge-file/highlighting strategy.
- **Registers** live in `ed.regs` (`a`-`z` + unnamed `"`); a macro is just register text (a yanked register can be run with `@`).
- Comments explain *why* (design rationale), matching the existing dense-header style; several files carry decision records worth reading before changing them.

## POSIX references

`MANPAGE-vi.txt` and `MANPAGE-ex.txt` (repo root) are the POSIX vi/ex specs — consult them for exact command/addressing semantics rather than guessing. Note POSIX vi specifies no arrow keys (commands are literal characters); escape-sequence decoding is intentionally deferred.
