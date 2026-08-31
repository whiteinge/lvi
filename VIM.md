# Migrating from Vim

Most of what your fingers know already works: `dw`, `ci"`, `3dd`, `` y`a ``, `.`,
`qa`…`q`, `:%s/old/new/g`, `u` and `Ctrl-R`, marks, registers, folds. What
changes is everything around the editing. There is no `:help`, no Vimscript, no
plugin runtime, and no `:set` for features that live outside the core. The
features are still here — syntax, quickfix, git hunks, linting — as separate
programs you switch on from the rc file.

Read this once, then use the tables as a lookup. The [manpage](lvi.1.scd) is the
reference; this is the translation.

## Start here

1. Copy [`contrib/lvirc.sample.vim`](contrib/lvirc.sample.vim) to
   `~/.config/lvi/lvirc`. It is the whole keymap, annotated section by section,
   and it is what the docs assume you have. Comment out what you don't want.
2. Install what the tools shell out to. The ones that pay off immediately:
   **fzf** (every picker; `fzy` and `sk` also work), **ctags**, and **Pygments**
   or **bat** for syntax.
3. `export MANPAGER=lvi-man` and `export MANROFFOPT=-c` in your *shell* rc, so
   `man` pages open in lvi with folds and highlighting.

The keymap in that file is one design, not thirty tools each grabbing a
convenient letter. `\` is the only leader; a letter is either a single action
(`\f` open a file, `\t` tags, `\e` lint) or a menu whose most-used action is
that letter doubled (`\gg` git changes, `\ll` switch lists). Keys that mirror a
vim key stay on that key instead: `/`, `*`, `n`, `]c`, `gc`, `z=`, `<C-a>`.

## Three habits to relearn

### `:help` is a manpage

`man lvi` is the complete reference, and with `MANPAGER=lvi-man` you read it in
lvi. For the binding you set up two months ago and have since forgotten, `\c`
([`lvi-cmd`](contrib/lvi-cmd)) is a fuzzy picker over every key you have mapped
and every `lvi-*` tool on `PATH`; picking a binding presses it.

### Long `:` lines go in the command window

The `:` prompt is deliberately minimal: type and Backspace, no completion, no
intra-line cursor. `Ctrl-F` at the prompt (or `:cmdwin`) opens vim's `q:`, a
scratch buffer of recent commands, one per line, edited with the full editor. A
bare `:w` runs the line under the cursor; `:bd` cancels.

### File and path work goes through `:sh`

The prompt has no completion, so build the path in a shell that has one. `:sh`
drops you to `$SHELL` with the view's id in the environment; queue the command
and leave:

```sh
lvi -w "$LVI_WID" -d -- "w $PWD/notes.txt"
exit
```

The `-d` (detach) matters — the editor is parked while the shell runs, so a
synchronous `lvi -w` would wait on it forever.
[`contrib/lvi-shell.sh`](contrib/lvi-shell.sh) wraps the pattern in
`lvi-saveas`, `lvi-mv` and friends (source it from your *shell* rc; `lvi-help`
lists them). There is no `%` or `#` in ex file arguments either: those arguments
go through the shell, so the current file is `$LVI_FILE` and
`:w ${LVI_FILE%.md}.html` works.

## Surprises worth knowing up front

- **No arrow keys.** POSIX vi specifies literal characters and lvi decodes no
  escape sequences. `hjkl`, in every mode.
- **No visual mode.** An edit is an operator plus a range stated in one gesture.
  The manpage's *Without visual mode* section is the full translation table.
- **Patterns are POSIX BRE.** `\(foo\)`, not `(foo)`. `:s` and `:g` are handed
  to the system `ex`, so on that side you get whatever dialect it speaks (on
  Linux that is usually vim's).
- **`/` builds a list rather than repeating a motion.** It doesn't wrap, `n` is
  always forward (after `?`, `N` keeps going back), and `n`/`N` step whichever
  list is focused — search, lint, git hunks. The operator form is separate:
  `d/foo` works once `motion / prompt lvi-search --motion` is in your rc, and it
  does wrap.
- **Maps have no wait-for-more timeout.** A mapping fires the instant it
  completes, so one cannot be a prefix of another: with `gc` mapped, `gcc` is
  unreachable (the sample rc uses `gC`).
- **`:set` covers core options only.** Per-filetype settings are a hook, not a
  runtime directory — see [`lvi-ftype`](contrib/lvi-ftype).

## Rosetta: the editor

The third column names what an answer comes from. Where it is an rc line, the
same few spellings recur, and most have no vim equivalent:

- **`:bg CMD`** runs a command detached, with no terminal handover and no
  alt-screen flash. It is what a map fires for a tool that needs no terminal, and
  the reason most bindings below read `:bg something`.
- **`:silent !CMD`** hands the terminal over, for a tool that draws its own
  screen — every picker. This one is vim's.
- **`:prompt / CMD`** reads a line first, under the given prompt, and runs `CMD`
  with it in `$LVI_INPUT`. It is how `/` asks for a pattern: the editor's own
  line editor handles the keys, so the tool stays a `:bg` spawn.
- **`on EVENT CMD`** is a change hook: run a tool when something happens
  (`change`, `write`, `bufenter`, `ready`). This is what replaces an autocmd,
  and there are only a handful of events.
- **A list is *focused*.** Search hits, lint findings and git hunks are all
  `lvi-list` lists; `n`/`N` step whichever one was aimed last, which is why
  several tools also bind a pinned `]x`/`[x` pair that only ever steps theirs.

### Command line and reference

| Vim | lvi | Comes from |
| --- | --- | --- |
| `:help x` | `man lvi`, `MANPAGER=lvi-man` | core, `lvi-man` |
| `q:` (command-line window) | `Ctrl-F` at the `:` prompt, `:cmdwin` | core |
| `Q` (ex mode), `:open` | neither exists: `:cmdwin` for a run of commands, `:sysex` for one, or `ex` from `:sh` | core |
| `:e` with tab completion | `\f` picker, or `:sh` and your own shell | `lvi-open` |
| `%` / `#` in a `:w` argument | `$LVI_FILE`, `:b #`, `Ctrl-^` | core |
| `:!`, `:r !`, `:%!cmd` | identical | core |
| `:terminal` | `:sh`, or send lines to the next pane with `gs` | core, `lvi-send` |

### Editing and selection

| Vim | lvi | Comes from |
| --- | --- | --- |
| `viwc`, `vt)d` | `ciw`, `dt)` | core |
| `Vjj>`, `Vipd` | `3>>`, `dip` | core |
| `Ctrl-V` block edit | `:[range]normal keys`, or a `!` filter over the range | core |
| `!{motion}`, `!!`, `:%!cmd` | identical — `!ip sort` filters the paragraph, `!G column -t` to end of file. `gq` is `!` with a fixed command | core |
| multiple cursors | `:%normal @a` — record once, stamp across a range | core |
| `gv` (reselect) | marks: `ma`, then `d'a` or `:'a,'b …` | core |
| `Ctrl-A` / `Ctrl-X` | `map <C-a> :.!lvi-incr<CR>` | `lvi-incr` |
| `g Ctrl-A` (renumber) | `!ip lvi-incr -b 1` — the paragraph, through the filter | `lvi-incr` |
| `:set textwidth` + `gq` | `set fmtprg=…` and `gq` (default `fmt`) | core |
| `:earlier`, `:undolist` | `u` / `Ctrl-R`, `g;` / `g,`, `:changes` (no undo tree) | core |
| `:registers` | `:registers`, mapped to `\r` | core |
| `"+y` with `clipboard=unnamedplus` | `register + read wl-paste write wl-copy` | core |

### Search, lists, and jumps

| Vim | lvi | Comes from |
| --- | --- | --- |
| `/`, `?`, `*`, `#` | same keys, as a list you step | `lvi-search` |
| `n` / `N` | step the *focused* list (search, lint, git, spell alike) | `lvi-list` |
| `:vimgrep`, `:grep` | any grep loaded as a list | `lvi-list load` |
| quickfix window | `\lg` picks an entry, `\lp` previews, `\ll` switches lists | `lvi-list` |
| `:cn`, `:cp`, `:cfirst`, `:cnfile` | `\l]` `\l[` `\lf` `\lF`, or `n`/`N` | `lvi-list` |
| `:make` + errorformat | `lvi -q errorfile`, or lint on write | `lvi-list`, `lvi-lint` |
| `:nohlsearch` | `\lh` hides the focused list's marks; the next `n` re-shows them (`:nohl` clears *every* overlay, syntax included) | `lvi-list` |
| `matchadd()` | `\hm` marks the word under the cursor | `lvi-match` |
| `Ctrl-]`, `:tag` | `<C-]>` asks a language server; with no server, `\t` outlines the *current* file (there is no tags file) | `lvi-lsp`, `lvi-tags` |
| global marks `A`–`Z` | same keys, once `on markset`/`on markjump` are wired | `lvi-gmark` |
| `` `" `` (viminfo position) | `on ready lvi-pos restore` | `lvi-pos` |
| `Ctrl-O` / `Ctrl-I`, `g;` | identical | core |

### Windows, buffers, and files

| Vim | lvi | Comes from |
| --- | --- | --- |
| `:sp`, `:vs`, `Ctrl-W` | tmux panes (or screen, Zellij, a tiling WM) | your multiplexer |
| two panes on one file | `lvi-mirror` — live buffer, unsaved edits included | `lvi-mirror` |
| `vimdiff` | `lvi-diff` — highlighted, scrollbound, `]c`/`[c`, `\dp`/`\do` | `lvi-diff` |
| `:tabnew` | buffers (`:ls`, `:bn`, `Ctrl-^`, `\b`) plus tmux windows | core, `lvi-buf` |
| `:ls`, `:b#`, `:bd` | identical | core |
| netrw, NERDTree | `\f` picker, or `:sh` | `lvi-open` |
| `:Sudow`, `:Move`, `:Delete` | `lvi-sudow`, `lvi-mv`, `lvi-rm` from `:sh` | `lvi-shell.sh` |

### Options you `:set` in vim

| Vim | lvi | Comes from |
| --- | --- | --- |
| `number`, `relativenumber` | same names, and `set gutter=number` says it the long way | core |
| `signcolumn` | `set gutter=git,lint` — a named column per tool, no priorities to lose a fight over | core |
| `syntax on` | `on change lvi-highlight` | `lvi-highlight` |
| `colorscheme` | `hi` lines in the rc, or `lvi-highlight --theme` from a Pygments style | core |
| `spell` | `\s` toggles; `]s`/`[s` step, `z=` fixes, `zg` adds | `lvi-spell` |
| `list` / `listchars` | `\ii` toggles the overlay, `\ip` pages exact bytes | `lvi-invis` |
| `colorcolumn` | `\ho`, and per-filetype limits | `lvi-hl-col` |
| `foldmethod=marker` / `=indent` | `zx` / `zX`, or `on bufenter lvi-fold` | `lvi-fold` |
| `wrap`, `linebreak`, `ts`, `sw`, `et`, `ai`, `readonly` | identical `:set` names | core |
| ftplugin / `after/ftplugin` | `on bufenter lvi-ftype` — one shell `case` you edit | `lvi-ftype` |
| `statusline` / airline | `:status NAME TEXT` segments, driven by tools | core |

## Rosetta: the plugins

None of these are installed into lvi: each row is a program on `PATH`, turned on
by the key or rc line beside it. The tool's own header comment (or
[`contrib/README.md`](contrib#readme)) has the rest — every variant, flag, and
env knob.

### Editing

| Plugin | lvi | Key or rc line |
| --- | --- | --- |
| vim-surround, vim-sandwich | `lvi-surround` on the `g@` operator; `.` repeats | `map s( :set opfunc=lvi-surround paren<CR>g@` |
| vim-commentary, NERDCommenter | `lvi-comment`, a toggle over any motion | `map gc :set opfunc=lvi-comment<CR>g@` |
| vim-repeat | already there — `.` repeats a `g@` operator | core |
| tabular, vim-easy-align | `!ip column -t` — the `!` filter, no plugin involved | core |
| yankring, vim-yankstack | `lvi-yankring` — `\yp`/`\yn` cycle at paste time | `register "" write lvi-yankring push` |
| vim-peekaboo | `:registers` | `map \r :registers<CR>` |
| vim-slime | `lvi-send` — `gsip` runs a paragraph in the next pane | `map gs :set operatorfunc=lvi-send<CR>g@` |
| UltiSnips, vim-snippets | nothing ships. Nearest: `:r !`, a macro in a register, or your own `on complete` tool | — |

### Search and navigation

| Plugin | lvi | Key or rc line |
| --- | --- | --- |
| fzf.vim, ctrlp | `lvi-open`, `lvi-buf`, `lvi-cmd` — `$LVI_PICKER` aims them all | `map \f :silent !lvi-open<CR>` |
| Tagbar, vista | `lvi-tags` — the current file's tags in a picker, so jump and outline are one key (`:wbuf` snapshots the buffer for it to read) | `map \t :wbuf<CR>:silent !lvi-tags<CR>` |
| vim-unimpaired | the `]x`/`[x` pairs in the sample rc: `]c` hunks, `]e` lint, `]s` spelling | `map ]e :bg lvi-list next lint<CR>` |
| vim-illuminate, interestingwords | `lvi-match` — sticky pattern marks, one color apiece | `map \hm :bg lvi-match add --word -F "$LVI_CWORD"<CR>` |
| vim-searchindex | the list's `[3/57]` counter in the status line | `lvi-list` |

### Git

| Plugin | lvi | Key or rc line |
| --- | --- | --- |
| gitgutter, vim-signify | `lvi-gitchanges` — hunks as a steppable list, and a change bar with `lvi-list policy gitchanges gutter:│` | `map \gg :bg lvi-gitchanges<CR>` |
| fugitive `:Gdiff` | `lvi-diff`, two panes | `lvi-diff old new` |
| fugitive `:Gstatus` staging | `lvi-stagediff` — `git add -p` as a diff you edit, `:w` stages | `lvi-stagediff file` |
| `git mergetool` | `lvi-diff` as git's mergetool: with `hideResolved`, only the real conflicts differ; `\do` takes theirs, `:x` accepts | `cmd = lvi-diff "$LOCAL" "$REMOTE" "$MERGED"` |
| fugitive `:Gblame`, `:Gcommit` | plain `git` in a tmux pane or `:sh` | — |

### Diagnostics and language

| Plugin | lvi | Key or rc line |
| --- | --- | --- |
| ALE, Syntastic, neomake | `lvi-lint` — one small adapter per linter, findings as a list | `on write lvi-lint` |
| coc.nvim, vim-lsp, nvim-lspconfig | `lvi-lsp` — `def` jumps to the definition, `refs` lists the uses, both as lists; the server is spawned per press, so there is no daemon. Hover and rename have no equivalent | `map <C-]> :bg lvi-lsp def<CR>`, and `\u` for `refs` |
| vim-polyglot and friends (syntax) | `lvi-highlight` — Pygments or bat lexers over the live buffer | `on change lvi-highlight` |
| neoformat, vim-autoformat | `lvi-fmt` — splices back only the changed window | `map \= :bg lvi-fmt<CR>` |
| vim-sleuth, editorconfig-vim | `lvi-detect-indent` (delegates to `editorconfig`(1) when present) | called by `lvi-ftype` |
| supertab, completion plugins | `lvi-complete` on insert-mode `Ctrl-N`/`Ctrl-P`, `Ctrl-X f` for paths | `on complete lvi-complete` |
| emmet, vim-ragtag (tag objects) | `lvi-textobj-tag` — `cit`, `dat`, `yat` | `textobj t lvi-textobj-tag` |

### Look and housekeeping

| Plugin | lvi | Key or rc line |
| --- | --- | --- |
| airline, lightline | `:status` segments; tools push their own | core |
| vim-startify, vim-obsession | `lvi-pos` restores your position per file; there is no session file | `on ready lvi-pos restore` |
| undotree, mundo | `g;` / `g,` and `:changes` | core |
| vim-rooter, per-project vimrc | `direnv` sets `$LVIRC`; the rc starts with a bare `source` to layer | see *Per-project settings* in the manpage |

## What isn't coming back

**Splits and windows.** tmux owns the panes. One lvi process edits one view, and
cross-pane work is a script over the socket: `lvi-mirror` keeps two panes on one
file in sync, `lvi-diff` binds two into a scrollbound diff. On-screen splits are
out of scope, not unimplemented.

**A plugin runtime.** No Vimscript, no `runtimepath`, no in-process extension
language. The shell is the extension language and the socket is the API: a tool
sends ex commands to a running view and reads its state back. Every row above is
a program you can also run from a terminal, and turning one on is one line in
the rc, which is itself a file of ex commands.

**A full LSP client.** `lvi-lsp` asks a language server for a definition or a
list of references, the part ctags can't resolve; it spawns the server per press
and kills it, so there is no resident process and nothing to keep in sync.
Diagnostics come from `lvi-lint` and need no server at all, formatting from
`lvi-fmt`, completion from buffer words and paths. Hover, project-wide rename,
and call hierarchy are not written. Nothing structural is in the way: a client
is just a program driving the socket.

**A faithful reimplementation of ex.** `:s`, `:g`, `:m`, `:t` and the full
address grammar are handed to the system `ex`, which ships on every UNIX lvi
targets. lvi owns the command names documented in the manpage and delegates the
rest.

The reasoning behind each of these is in the README's
[non-goals](README.md#what-it-isnt-non-goals).
