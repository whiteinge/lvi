# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`lvi` is a minimal, POSIX-vi-style modal editor written in Lua, built on the "UNIX as IDE" philosophy: lean on external CLI tools rather than growing features inward. Its defining deviation from POSIX vi is a **per-view control socket** so external tools can drive a running editor. It targets **LuaJIT** on Linux/macOS/BSD (WSL == Linux).

## Commands

```sh
luajit lvi <file>              # launch the editor (interactive; needs a tty)
luajit lvi -l                  # list running views:  <wid>\t<socket-path>
luajit lvi -w <wid> -- <cmds>  # send ex commands to a running view; -w auto = sole view
luajit test/buffer_test.lua    # run one test file
make test                      # run all tests (auto-discovers test/*_test.lua)
```

- `make test` is the way to run the whole suite — it globs `test/*_test.lua`, so new test files are picked up automatically and nothing is missed. Tests use the vendored `lust` framework (`vendor/lust`); each spec calls `os.exit(lust.errors==0 and 0 or 1)`, so a non-zero exit means failures (and `make test` stops on the first failing file). There is no separate lint/build step.
- `lvi -w` is a Unix filter: `ok` payloads go to stdout, errors to stderr, exit code reflects failure. Over the socket, send ex commands **without** the leading `:` (a leading `:` is tolerated/stripped by the client).
- The dev shell runs zsh with `noclobber`; overwrite redirects need `>!` (e.g. `foo >! out`).
- There is no in-process way to test the tty/render path headlessly (no tty in most harnesses); drive behavior over the socket, or unit-test `render.frame(ed)` (pure) and `normal.lua` (feed keys to the coroutine).

## Architecture (the big picture)

Data flows through a few deliberate choke points. Understanding these four is most of the codebase:

1. **`sys.lua` is the *only* place with FFI / platform-specific code.** Everything unsafe or OS-divergent (termios via `stty`, Unix sockets, `poll`, `ioctl` winsize, `sockaddr_un`) is quarantined here behind a small interface, so the LuaJIT-vs-PUC choice stays reversible. Terminal raw mode is done by shelling out to `stty` (no termios struct in-tree); only sockets+`poll`+winsize use FFI, and the one struct that diverges (`sockaddr_un`, plus the winsize ioctl number) branches on `ffi.os`. **Do not add FFI or platform structs anywhere else.** Its header is a decision record — read it.

2. **`ex.dispatch(ed, line) -> payload, status` is the shared command core.** The `:` prompt (in `normal.lua`), the control socket (in `editor.lua`), and the rc file (`config.lua`) all call it, so a command means the same thing on every surface (the tmux-like "identical at CLI and in config" property). Commands live in the `CMDS` table (name → handler, aliases declared beside each command); ex commands are the line-oriented API; `:normal <keys>` is the escape hatch into normal-mode keystrokes. **The config file is literally a file of ex commands** — no separate syntax; `config.lua` just reads it and runs each line through `ex.dispatch` at startup (path: `$LVIRC` → `$XDG_CONFIG_HOME/lvi/lvirc` → `~/.lvirc`; `"` starts a comment). **Any command lvi doesn't implement is delegated to the system `ex`** (`do_ex`, the fallthrough + the non-lvi-address case): write the buffer to a temp file, drive `ex -s` with a preamble that mirrors lvi's marks and cursor line, then the command verbatim, and read back only the changed window (common prefix/suffix trimmed) as one splice. So `:s`/`:g`/`:m`/full addressing come from the real `ex` (`$LVI_EX` to override) — don't reimplement ex. Limits by design: output discarded, errors are a safe no-op (Vim's `ex -s` returns 1 even on success and hides stderr); only ex-unrunnable is caught. **Every name in `CMDS` shadows the system ex's command of that name** — adding one changes the meaning of scripts that reached ex through the fallthrough, so additions must land in the manpage's owned-names note; `:sysex` bypasses the table and pins ex's semantics.

3. **`ed.inject` is the single input funnel.** `normal.lua` is a persistent coroutine whose `getkey()` yields until the driver feeds a key. The keyboard, `.` (repeat), macros (`@`), and `:normal` all work by *appending keys to `ed.inject`* and resuming the coroutine — one mechanism, four sources. `getkey` also logs to `ed.keylog` (→ `ed.last_change` for `.`) and to `ed.macro_buf` while recording. Because the coroutine parks between keys, the `poll` loop in `editor.lua` keeps servicing the socket even mid-command. Two guards protect the funnel: **socket-injected keys run only at a command boundary** (`ed.at_boundary`; mid-command arrivals defer to `ed.inject_deferred` and replay when the boundary returns, and the per-socket-command undo checkpoint is skipped mid-command so an insert isn't split), and **a per-pump key budget** (`ed.key_budget`, reset in `pump`) aborts a self-feeding macro (`@a` containing `@a`) instead of hanging the editor. All ed fields are born in `editor.new_ed()` — the one constructor/field registry; never lazy-init a field at a use site.

4. **The socket is a per-view control channel with a framed request/response protocol** (`proto.lua`). Response frame: `%begin <id>\n` then repeatable `%data <N>\n<N raw bytes>` then `%end <id> <status>\n`. Payloads are length-delimited so raw buffer text (e.g. `:%p` output) can never corrupt the frame. Requests are bare newline-delimited command lines, plus an opt-in upgrade: a `%hello 1` handshake (server greets `lvi 1`) enables `%cmd <N>\n<N bytes>` framed requests whose one command may contain newlines — bare lines stay valid forever (old clients, `echo ':w' > socket`); `lvi -w` upgrades automatically. Connection writes are non-blocking with a per-conn outbuf drained via `POLLOUT`, so a stalled client can never freeze the editor (it gets dropped past 32 MB undrained). The `%event` tag is reserved for a future subscribe/push channel — the envelope is locked, notifications are additive. Socket path policy (`path.lua`): `$XDG_RUNTIME_DIR` → `$TMPDIR` → `/tmp`, then `lvi-$uid/$wid`; buffer-bearing temp files come from `path.tmp()` in that same private dir, never `os.tmpname()`.

### Module map

`editor.lua` is the driver (view state + the `poll` loop; creates/primes the coroutine; routes keyboard→`ed.inject` and socket→`ex.dispatch`; repaints after every event). `normal.lua` is the coroutine interpreter (motions/operators/insert mode; the **motion/operator model**: a motion returns target+kind(char/line)+inclusive, an operator consumes the cursor→target range, so motions×operators compose for free; the scroll commands `Ctrl-F/B/D/U/E/Y` invert this — the window drives and the cursor follows — measured in screen rows so they work in both wrap and nowrap). `buffer.lua` is an array of immutable line-strings behind a thin line-oriented interface, with the undo log (see below). `render.lua` is the viewport-bounded renderer (`render.frame(ed)` is pure → testable). `config.lua` resolves and runs the rc file through `ex.dispatch`. `ex.lua`, `proto.lua`, `path.lua`, `client.lua`, `term.lua`, `sys.lua` as described. `lvi` is the dual-role entry point (editor vs `-w` client) via vendored `argparse`.

### Key invariants and conventions

- **Buffer**: always ≥1 line; a line never contains `\n`; `noeol` makes read/write round-trip byte-for-byte. All mutations funnel through `buffer.lua`'s `splice(start, ndel, ins)` (atomic remove+insert; in-place O(1) when `ndel==nins`, e.g. per-keystroke `set`). splice records an inverse into the undo log automatically — **no mutation can escape undo** — and fires the optional `on_splice` callback, which the editor wires per-buffer to shift the current view's marks/jumplist by the edit delta (undo/redo un-adjust symmetrically for free). Undo is multi-level (`u` / Ctrl-R); `undo_checkpoint()` (called at each `command()` start and before each *boundary-safe* socket `ex.dispatch`) groups records into one user-level change. The undo-state field is `_undo` (avoids colliding with the `:undo()` method).
- **Data safety**: `Buffer:write` is backup-then-write — the full new text lands in `PATH.lvi~` first, then the target is rewritten in place (preserving symlinks/hardlinks/mode); a surviving `.lvi~` means an interrupted write. `:w` refuses when the file changed on disk since the last read/write (`w!` overrides) via per-buffer stamp files beside the socket (`touch -r` + `test -nt`, the stat(2) dodge in `sys.lua`). A crashed session dumps every modified buffer to `PATH.lvi-recover` (`editor.preserve`) before re-raising.
- **Rendering** is viewport-bounded (touch only visible lines/cols), nowrap for now. See design notes for wrap/long-line/huge-file/highlighting strategy.
- **Registers** live in `ed.regs` (`a`-`z` + unnamed `"`); a macro is just register text (a yanked register can be run with `@`).
- **Highlight overlay**: `ed.highlights` = named groups → byte ranges (`:hl GROUP L:C1-C2 …`, transient); `ed.hlstyles` = group → SGR params (`:hi GROUP fg=… bg=… bold …`, theme, set in the rc, survives `:nohl`). `render` buckets ranges by line and `disp.slice` folds each group's SGR in (a group with no style draws as plain text — un-themed = invisible; a tool that wants to be seen without a theme sets its own, e.g. `:hi search reverse`, which `lvi-search` does). This one overlay is the substrate for external search, quickfix, and syntax highlighting — all just feed `:hl` over the socket.
- **Change hooks** (`:on change CMD`): the generic "run an external tool when the buffer settles" mechanism (so features like syntax highlighting need no daemon — `on change lvi-highlight` in the rc). The `poll` loop arms a 150 ms idle timeout only while a *keyboard* edit is pending (tracked via `buffer.rev`), then fires each hook through `ed.spawn_bg` (detached, output-discarded, non-blocking). Only keyboard edits arm a hook — a hook's own edits return over the *socket* (a different source), so they can never retrigger it and loop. `%event`/subscribe (proto.lua) stays reserved for a future stateful push consumer.
- Comments explain *why* (design rationale), matching the existing dense-header style; several files carry decision records worth reading before changing them.

## Documentation (who each doc is for)

Four docs, four audiences — keep content in its lane and don't duplicate across them:

- **`lvi.1.scd` (the manpage)** — source of truth for day-to-day editor use: normal-mode commands, ex commands, config, environment. GitHub renders `.scd` inline, so it doubles as browsable reference. It mentions the `contrib` tools only as a brief "this exists, turn it on" teaser with headliners, then links out.
- **contrib script header comments** — the verbose per-script operator reference: purpose, invocation/synopsis, every env knob, binding snippets, debug flags. Self-contained when you open the file. Env knobs live *here only*.
- **`contrib/README.md`** — the tour/pitch: what each tool is *for*, and the cross-cutting machinery no single script owns (the `:hl` overlay substrate, file-backed lists + focus, the three spawn disciplines, the backend contract). Points *into* the headers rather than re-listing knobs.
- **`README.md`** — overview and sales pitch, cascading high→low: the pitch, quick start, a short "what you get" teaser (defers to the manpage for the full reference), then the "Design & implementation" rationale near the end. Prominent links to the manpage and `contrib/` sit up top.

## POSIX references

`RESOURCES/MANPAGE-vi.txt` and `RESOURCES/MANPAGE-ex.txt` are the POSIX vi/ex specs — consult them for exact command/addressing semantics rather than guessing. Note POSIX vi specifies no arrow keys (commands are literal characters); escape-sequence decoding is intentionally deferred.
