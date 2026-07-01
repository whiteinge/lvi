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

## Search

`lvi-search WID PATTERN` — greps the live buffer, highlights matches, jumps to
the first. No search engine in the editor; the results also live in your shell.

## Open a file

`lvi-open` — a fuzzy-picker (fzf by default; `LVI_PICKER` to change) that opens
the chosen file in the running view. Bind it: `map \f :silent !lvi-open<CR>`.
