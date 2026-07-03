# contrib — external tools that drive lvi

These are small programs that talk to a running lvi over its control socket
(`lvi -w …`). They live *outside* the editor on purpose: lvi stays a minimal
core, and features like search and syntax highlighting are provided by composing
Unix tools that feed the editor's `:hl` overlay and `:normal` hatch. Put this
directory on your `PATH`.

## Syntax highlighting

`lvi-highlight [WID]` — pulls the live buffer, runs an external highlighter, and
paints the tokens through `:hl`. It works on unsaved content, and a still-open
string or block comment colors the rest of the file. Enable it in your rc:

    on change lvi-highlight        " re-highlight a beat after you stop typing
    map \h :silent !lvi-highlight<CR>   " ...and/or force it on a key

Pick a backend with `LVI_HL_BACKEND` (default `pygments`):

| backend    | `LVI_HL_BACKEND` | needs                   | theming                     |
|------------|------------------|-------------------------|-----------------------------|
| Pygments   | `pygments`       | `python3-pygments`      | you, via `:hi` (see below)  |
| bat        | `bat`            | `bat` (binary `batcat`) | bat's own theme (`BAT_THEME`) |

The two theme differently. **Pygments is positional**: it reports token *types*
(Keyword, String, …) and *you* choose their colors with `:hi` in the rc — one
theme across every file. **bat is ANSI**: it has already colored the text with
its own theme, and lvi reproduces those colors, so you pick the look with
`BAT_THEME` / `bat --theme`, not `:hi`.

Config knobs (env): `LVI` (client, default `lvi`), `LVI_HL_MAXBYTES` (skip
buffers larger than this; default 256K), `LVI_HL_DEBUG` (capture a run's stderr).

A Pygments theme + trigger to copy into `~/.lvirc` is in `lvirc.sample`.

### Adding a backend

`lvi-highlight` is a backend-agnostic harness; a backend is one adapter script,
`lvi-hl-<name>`, with a single contract: **buffer text on stdin, filename as
`$1`, emit `hl GROUP L:C1-C2 …` (byte columns) on stdout.** Two shapes ship:

- **Positional** (`lvi-hl-pygments`): walk the tool's token stream, emit named
  groups. Style them with `:hi`.
- **ANSI** (`lvi-hl-bat`): pipe the tool's ANSI-colored output through the shared
  `lvi-hl-ansi` parser, which turns each distinct SGR into a `synN` group whose
  style is that SGR. `source-highlight`, `tree-sitter highlight`, etc. are thin
  wrappers around `lvi-hl-ansi`.

## Lists (quickfix / location) and search

A **list** is a plain file of `file:line[:col]:text` entries — grep, a compiler,
a linter, or `git diff` output (the `vim -q` format). lvi knows nothing about
lists: `lvi-list` owns them and drives lvi over the socket — jumping the cursor,
painting the `:hl` overlay, and setting a `:status` counter. Any number of named
lists coexist; one is **focused**, and the bare step commands act on it, so a
single pair of keys (`n`/`N`) steps search, grep, lint, and git hunks alike.

    producer | lvi-list put NAME [--focus]   # grep-style entries on stdin → a list
    lvi-list next|prev|nfile|pfile [NAME]     # step (NAME defaults to focused)
    lvi-list here|goto|switch|focus|ls|paint  # jump-at-cursor / fzf / focus / list / repaint
    lvi-list save NAME PATH | load PATH [NAME] [--focus] | drop NAME | clear NAME

Lists live beside the view's socket (derived from `$LVI_SOCK`, so per-view and
auto-cleaned); `save`/`load` promote one to any durable path — that's `vim -q`
and "save this quickfix for later" in one file. Run from inside lvi (a map) and
it reads `$LVI_WID`/`$LVI_SOCK` from the env; from another terminal pass
`-w auto|WID`. Bind `:on bufenter lvi-list paint` so cross-file lists repaint the
current buffer's matches on arrival.

**`lvi-search`** is the first producer: it greps the live buffer (so it searches
*unsaved* content) into the `search` list, focuses it, and jumps to the first
match — `n`/`N` do the rest. Bind `/` to prompt and `*` to search the word under
the cursor:

    map / :silent !lvi-search<CR>
    map * :bg lvi-search "$LVI_CWORD"<CR>
    map n :bg lvi-list next<CR>
    map N :bg lvi-list prev<CR>

The step keys use **`:bg`**, not `:silent !`. `:bg CMD` runs a command detached
with no terminal handover; `:!`/`:silent !` drop out of and back into the alt
screen around every run, which flashes when you hold down `n`/`N`. `:bg` is for
non-interactive tools (it's the same spawn `:on` hooks use); only `/`, which
*prompts*, needs the terminal and so stays `:silent !`.

Like `lvi-highlight`, `lvi-search` self-backgrounds (reading the buffer needs
lvi's event loop); set `LVI_SEARCH_DEBUG` to see a worker's errors. `lvi-list`
never reads the buffer, so it fires jumps with `lvi -w --detach`. Copy the
search/list bindings from `lvirc.sample`.

## Open a file

`lvi-open` — a fuzzy-picker (fzf by default; `LVI_PICKER` to change) that opens
the chosen file in the running view. Bind it: `map \f :silent !lvi-open<CR>`.
