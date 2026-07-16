" lvirc.sample.vim -- a starting ~/.lvirc for external syntax highlighting.
" Copy the parts you want into $XDG_CONFIG_HOME/lvi/lvirc or ~/.lvirc.
" The rc file is just ex commands (see :hi / :map); " begins a comment.
" (Named .vim so GitHub/bat/Pygments highlight it as Vim script -- the syntax is
" close enough: " comments, and map/set/hi keywords. Each section is wrapped in
" fold markers so `on bufenter lvi-fold` folds this rc into a table of contents
" -- see the folding section below.)

" ---- the keymap, and why it is shaped this way ------------------------ {{{

" Each contrib tool is a standalone concept, so its maps could each grab a
" convenient letter and collide with the next tool's. Instead the maps below are
" ONE coherent keymap -- copy the whole file and nothing steps on anything else.
" Deviate as you like; these are the defaults the docs assume.
"
" \ is the only leader (vim's default). The mapper has NO timeout: a sequence
" fires the instant it equals a complete map, even if a longer map also starts
" with it (see `first_key` in normal.lua). So a two-key map \XY is reachable ONLY
" if \X is not itself bound -- every leader letter is either a LEAF (one action)
" or a MENU prefix (\X does nothing; the action is the second key), never both.
" That single rule is the whole scheme:
"
"   * LEAF -- a tool with one action gets one letter, mnemonic where vim has an
"     equivalent:  \= format (vim =), \f find/open, \t tags, \r registers,
"     \m marks, \e errors/lint, \s spell, \w wrap-toggle.
"   * MENU -- a tool with several actions gets a prefix, and its most-used action
"     is that letter DOUBLED (a leaf-like two-key press for the common case):
"       \g  git      \gg changes   \gs staged   \gp stage-hunks (git add -p)
"       \l  lists     \ll switch    \lg goto   \lc current   \lh hide   \lp preview
"       \h  highlight \hh refresh   \ht toggle
"       \y  yankring  \yy pick      \yp older  \yn newer
"       \d  diff      \dp put       \do obtain          (installed by lvi-diff)
"
" Motions/operators that mirror a vim key stay OFF the leader and on that key: /
" and * (search), n/N (step the focused list), the ]x/[x pairs (step list x),
" the z-prefix (folds, spell fix/add), <C-a>/<C-x> (increment), gc (comment),
" s( s{ s" (surround). They shadow the builtin only where lvi left it free (lvi
" has no search, so / n N * are yours; s only shadows the four surround follows).

" }}}
" ---- editor defaults --------------------------------------------------- {{{

" Plain core options -- a starting point, tune to taste. If you enable lvi-ftype
" (below) it re-projects sw/et/fmtprg per file type on every buffer switch, so
" set your real per-language values there and treat these as the fallback.
set expandtab
set shiftwidth=4
set autoindent
set wrap linebreak                    " soft-wrap long lines at word boundaries
map \w :set wrap!<CR>                  " toggle wrapping (the \w leaf)

" }}}
" ---- theme (Pygments backend) ------------------------------------------ {{{

" These :hi lines color the token groups the Pygments backend emits. They do
" NOT apply to the bat backend, which brings its own theme (set BAT_THEME or
" `bat --theme`); with bat you can skip this whole section.
"
" A group with NO style renders as plain text (un-themed = invisible), so style
" the ones you want. Colors: 8 names (black red green yellow blue magenta cyan
" white) or a 0-255 256-color index; attrs bold dim italic underline reverse.
hi Comment  fg=cyan italic
hi String   fg=green
hi Number   fg=magenta
hi Keyword  fg=blue bold
hi Operator fg=red
hi Function fg=yellow
hi Type     fg=cyan
hi Builtin  fg=yellow
hi Constant fg=magenta
hi Preproc  fg=red
" Markup/prose/diff groups (Markdown headings, **bold**, diff +/- lines, ...):
hi Heading  fg=yellow bold
hi Strong   bold
hi Emph     italic
hi Inserted fg=green
hi Deleted  fg=red
"
" ...or skip the hand-written block above and seed the groups from a Pygments
" built-in style (truecolor). `--theme` pushes the `hi` lines once at startup;
" any `hi` you set after this line still overrides it, group by group. Styles:
" `pygmentize -L styles` (monokai, solarized-dark, gruvbox-dark, nord, ...).
"   on ready LVI_PYGMENTS_STYLE=monokai lvi-highlight --theme
" LVI_PYGMENTS_DEPTH constrains the seed's colors: truecolor (default), 256,
" 16, or 8 (low depths follow your terminal palette). E.g. for a 256-color term:
"   on ready LVI_PYGMENTS_STYLE=gruvbox-dark LVI_PYGMENTS_DEPTH=256 lvi-highlight --theme

" }}}
" ---- trigger ----------------------------------------------------------- {{{

" Re-highlight automatically a moment after you stop typing. `on change` runs the
" command (detached, output discarded) when a KEYBOARD edit settles -- a hook's
" own socket edits never retrigger it, so no loops. Put lvi-highlight (and
" lvi-hl-pygments) on your PATH, or set LVI_HL_BACKEND / LVI in its env.
on change lvi-highlight

" `change` is keyboard-only, so a socket-driven :e (e.g. lvi-open jumping to a
" file) never arms it -- the new buffer would open unhighlighted. `bufenter`
" fires on every buffer switch on any surface, so pair it with `change` to
" re-highlight whenever you land in a buffer.
on bufenter lvi-highlight

" highlight MENU (\h): \hh forces a refresh now, \ht toggles syntax off/on.
map \hh :silent !lvi-highlight<CR>          " re-highlight on demand
map \ht :bg lvi-highlight toggle<CR>        " :syntax off / on

" }}}
" ---- message line ------------------------------------------------------ {{{

" :msg writes the message line and tags its text with the `Message` group; :msge
" (the error variant) uses `Error` instead, so a tool can flag a message as an
" error and real ex errors (`:w` on a changed file, ...) show the same way.
" Un-themed both are plain but legible; these give them emphasis. lvi-list uses
" :msg to preview the entry you step onto.
hi Message reverse
hi Error   fg=red bold

" }}}
" ---- search & lists (quickfix/location) -------------------------------- {{{

" lvi has no built-in search; lvi-search greps the live buffer into a `lvi-list`
" list and lvi-list steps it. Every list works the same way, so ONE navigation
" model serves search, grep, lint, spell, git hunks -- whichever list is *focused*:
"   n / N       step the FOCUSED list forward / back (vim's search-repeat keys)
"   ]x / [x     step a PINNED list x without changing focus (]e lint, ]s spell,
"               ]c git -- see each section below; the letter is the list's initial)
"   \l...       manage lists (switch focus, jump within, re-center, hide, preview)
" / prompts and \lg/\ll run pickers, so they need the terminal (:silent !). The
" rest touch no tty, so they use :bg -- a detached spawn with NO terminal
" handover, which avoids the alt-screen flash that :! causes when you hold down n/N.
map / :silent !lvi-search<CR>                 " prompt for a pattern, then focus it
map * :bg lvi-search "$LVI_CWORD"<CR>         " search the word under the cursor
map n :bg lvi-list next<CR>                   " step the focused list...
map N :bg lvi-list prev<CR>                   " ...forward / back
" list MENU (\l): switch focus / goto within / re-center / hide / preview.
map \ll :silent !lvi-list switch<CR>          " re-aim n/N: pick the focused list
map \lg :silent !lvi-list goto<CR>            " pick+jump to an entry in the focused list
map \lc :bg lvi-list current<CR>              " re-jump to the current entry (vim :cc);
"                                               recall it after opening a fold n/N landed in
map \lh :bg lvi-list hide<CR>                 " :nohl-style -- hide it; next n/N re-shows
" \lp pops the FULL entry (header + any multi-line body) in a tmux popup. Needs
" tmux. Pass -w: the popup runs under the tmux server and does NOT inherit lvi's
" $LVI_WID env.
map \lp :silent !tmux display-popup -E "lvi-list -w $LVI_WID preview | less -R"<CR>

" Repaint the current buffer's matches when you switch into it (the glue that
" makes cross-file lists -- project grep, a compiler -- highlight per file).
on bufenter lvi-list paint

" `lvi -q FILE` (vim's quickfix flag): the core only parks FILE in $LVI_QUICKFIX
" and fires `ready` once at startup -- it knows nothing about lists. This hook is
" what turns it into a loaded list: the shell guard keeps it inert on a plain
" `lvi`, and only bites when -q was passed. Loads + paints (cursor stays put);
" press n to step to the first entry. Drop `--focus` to keep your current focus.
on ready [ -n "$LVI_QUICKFIX" ] && lvi-list load "$LVI_QUICKFIX" quickfix --focus

" }}}
" ---- insert-mode completion -------------------------------------------- {{{

" Ctrl-N/Ctrl-P in insert mode complete the word before the cursor from all open
" buffers. `on complete` names the completer; core hands it the token + buffers
" and splices its choice back. lvi-complete fuzzy-picks with $LVI_PICKER; set
" LVI_COMPL_POPUP=1 (under tmux) to draw it in a popup over the editor.
on complete lvi-complete
"   on complete LVI_COMPL_POPUP=1 lvi-complete   " ...as a tmux popup instead

" }}}
" ---- system clipboard -------------------------------------------------- {{{

" `register` backs a register with shell commands: a yank/delete into it pipes
" the text out, a put reads fresh in. Wire `+` to your platform's clipboard and
" "+y / "+p (and "+d, "+dd, "+yiw, ...) copy and paste through it. Pick ONE line:
register + read wl-paste write wl-copy              " Wayland (wl-clipboard)
"   register + read xclip -selection clipboard -o write xclip -selection clipboard   " X11
"   register + read pbpaste write pbcopy            " macOS
"   register + read tmux save-buffer - write tmux load-buffer -   " tmux buffer
" Any register name works; `+` just follows Vim's convention. `register +` alone
" clears it.
"
" :registers (alias :reg -- Vim's :reg) lists every register and its contents;
" a command-backed register also shows its read/write spec. Map it for a glance:
map \r :registers<CR>

" }}}
" ---- yank ring (YankRing / yanky.nvim-style history) ------------------- {{{

" Backing the UNNAMED register's write fires on every yank and delete, so it is
" the one capture point a history tool hangs off. lvi-yankring keeps a per-view
" ring of them; you paste normally, then walk the paste back through older
" entries. Register ~ (a name you will not yank into) reads the ring's current
" entry, and the cycle keys undo the paste and re-put the next one. (`""` is the
" unnamed register spelled comment-safely -- a lone `"` here would be a comment.)
" Both register lines are required: `""` write feeds the ring; `~` read is what
" p-cycling and pick put through. The maps below do nothing without both.
register "" write lvi-yankring push
register ~ read lvi-yankring get
" yankring MENU (\y). Press \yp/\yn RIGHT AFTER a p/P -- the undo assumes the
" last change was a paste:
map \yp :bg lvi-yankring cycle prev<CR>    " ...replace it with the older entry
map \yn :bg lvi-yankring cycle next<CR>    " ...or the newer one
map \yy :silent !lvi-yankring pick<CR>     " or pick any entry through $LVI_PICKER
" The ring rides the unnamed register, so it sits alongside the numbered delete
" registers ("1.."9, "-) and the "+ clipboard above -- it replaces neither. Point
" LVI_YANKRING_DIR at a shared path to carry one ring across views.

" }}}
" ---- tags -------------------------------------------------------------- {{{

" lvi-tags lists this file's ctags tags in file order through your picker and
" jumps to the one you choose -- a jump-to-symbol and a file outline in one key.
" It tags the live buffer (your unsaved edits included) -- no `tags` file needed.
" It needs the picker's tty (:silent !), which freezes lvi, so it can't read the
" buffer back over the socket -- :wbuf snapshots it to $LVI_BUFFER first, then
" the frozen picker reads that. (See `Shelling out` in lvi.1.scd.)
map \t :wbuf<CR>:silent !lvi-tags<CR>

" }}}
" ---- git changes ------------------------------------------------------- {{{

" git MENU (\g). lvi-gitchanges turns `git diff` for the current file into a
" `gitchanges` list and jumps to the first hunk; n/N then step it like any other
" list. It reads the file on disk, so it reflects your last :w. (git is
" non-interactive -> :bg.) \gg is the common case (working-tree changes); \gs
" does the same for what's already STAGED.
map \gg :bg lvi-gitchanges<CR>                 " working-tree changes + focus
map \gs :bg lvi-gitchanges --staged<CR>        " staged changes + focus
" Or give the list its own step keys so it never steals focus from search:
map ]c :bg lvi-list next gitchanges<CR>
map [c :bg lvi-list prev gitchanges<CR>
" A group with no style is invisible; lvi-search styles `search` itself, but you
" can theme any list's group (and its -cur current-entry group), e.g.:
"   hi gitchanges bg=22 pri=10  " pri lifts the mark above syntax (which sits at 0)
"
" Staging hunks (git add -p, side-by-side) is lvi-stagediff -- it stands on
" lvi-diff and is launched, not a rc default; run it by hand or from a key:
"   map \gp :silent !lvi-stagediff<CR>          " "git add -p" the current file

" }}}
" ---- linting ----------------------------------------------------------- {{{

" lvi-lint runs a linter over the LIVE buffer (unsaved edits included) into a
" `lint` list; the backend is picked by the file's extension (ruff / shellcheck
" / deno lint ship -- see lvi-lint's header for the tiny adapter contract).
" Findings step like any list, and the status counter doubles as the pass/fail
" glance: [0/0] after a run means clean.
on write lvi-lint                      " re-lint on every save...
" on change lvi-lint                   " ...or as you type
map \e :bg lvi-lint --focus<CR>        " lint now and aim n/N at the findings
map ]e :bg lvi-list next lint<CR>      " ...or step them with pinned keys
map [e :bg lvi-list prev lint<CR>
hi lint     bg=52 pri=10               " theme the marks (un-themed = invisible)
hi lint-cur bg=124 pri=11

" }}}
" ---- spell check ------------------------------------------------------- {{{

" lvi-spell is a toggle (vim's :set spell): while on, the buffer re-checks as
" you type -- misspelled words get exact-extent `spellbad` marks plus a `spell`
" list to step. The toggle installs its own change/bufenter hooks once per
" view, so do NOT add them here; everything below is keys and theme. Fix/add
" keep vim's native z-keys (z=, zg); the toggle is the one leader leaf (\s).
map \s :bg lvi-spell<CR>               " toggle
map ]s :bg lvi-list next spell<CR>     " step misspellings
map [s :bg lvi-list prev spell<CR>
map z= :silent !lvi-spell fix<CR>      " pick a suggestion for the word under
map zg :bg lvi-spell add<CR>           " the cursor / add it to the dictionary
hi spellbad underline pri=20           " the word marks themselves

" }}}
" ---- formatting -------------------------------------------------------- {{{

" lvi-fmt formats the LIVE buffer through the file's formatter (ruff format /
" shfmt / gofmt / stylua / deno fmt by extension; LVI_FMT_CMD overrides) and
" splices back only the changed window -- the cursor stays put, one undo
" reverts the whole format, and an already-formatted buffer is untouched.
" Format, then :w (an `on write` format would re-dirty the buffer after every
" save, so there is deliberately no hook here). \= mirrors vim's = operator.
map \= :bg lvi-fmt<CR>
"
" That is CODE formatting. For PROSE, gq reflows a motion/text object through the
" `fmtprg` option (default fmt(1)); gqip reflows a paragraph, gqq the line. fmtprg
" seeds from $LVI_FMT but is live, so re-set it per file type -- 72 for an email,
" 80 for Markdown -- from a key or a hook. It takes the rest of the line, so keep
" it on its own :set. A \q menu (q for gq) makes the width switch a two-key press:
"   set fmtprg=fmt -w 72                " a startup default width
"   map \qe :set fmtprg=fmt -w 72<CR>   " switch to email width on demand
"   map \qm :set fmtprg=fmt -w 80<CR>   " ...or Markdown width
"
" fmt(1) drops a list's hanging indent. lvi-reflow is a drop-in fmtprg that keeps
" each item's marker and hangs the wrapped lines under its text (ordered, roman,
" letter, and bullet markers; nested lists nest). Then gqip/gqq reflow lists too:
"   set fmtprg=lvi-reflow -w 79

" }}}
" ---- filetype settings (vim's ftplugin) -------------------------------- {{{

" The per-file-type fmtprg above, generalized. lvi-ftype reads $LVI_FILE on every
" buffer entry and sets sw/et/fmtprg/... from the name: Python at sw=4 with `ruff
" format`, shell at sw=2 with shfmt. It ships as a TEMPLATE -- copy it to your
" config dir, edit its CONFIGURE table, and point the hook at your copy (on takes
" a shell line, so an absolute path works and the name is free):
"   on bufenter ~/.config/lvi/lvi-ftype
" With lvi-detect-indent on your PATH it also matches the file's actual indent (a
" 2-space file over a 4-space default); without it, indent keys off the name.
" It owns fmtprg -- set your global gq default in the script's default_fmt, since
" a bare `set fmtprg=...` in the rc no longer sticks once the hook re-projects it.
" Options are view-global, not per-buffer, so the table is re-applied on every
" switch and a manual :set lasts only until you switch away. Use one such hook,
" not several: two would race.
on bufenter lvi-ftype

" }}}
" ---- folding ----------------------------------------------------------- {{{

" lvi has the fold MECHANISM (collapse a range to one row, z-keys to navigate);
" lvi-fold computes the POLICY from the live buffer and pushes :fold commands, the
" way lvi-highlight pushes :hl. `zi` folds by marker (this rc wraps each section
" in a marker pair, so it folds into a table of contents), `zI` by indent. Folds
" arrive CLOSED; open with zo/zR. Marker mode needs a matching close per open (it
" nests by a stack, and ignores a trailing level digit on the open marker).
hi Folded fg=cyan italic               " the summary bar (un-themed = plain)
map zi :bg lvi-fold<CR>                " (re)fold by marker
map zI :bg lvi-fold indent<CR>         " (re)fold by indent
" on bufenter lvi-fold                 " ...or auto-fold every marked file on entry

" }}}
" ---- position memory (viminfo's `") ------------------------------------ {{{

" lvi-pos remembers where you were in each file across sessions, in a plain-text
" store under $XDG_STATE_HOME (LVI_POS_FILE to move it). `save` records the spot;
" `restore` drops the `" mark there WITHOUT moving the cursor, so you open a file
" fresh (at the top) and press `" to jump to where you left off. Because it moves
" nothing, restore is safe on every buffer switch -- it can't fight a list jump
" (lvi-gitchanges/-search) for the cursor. (The in-session last-change mark `. needs
" no tool -- the core sets it as you edit.)
on change   lvi-pos save        " after an edit settles...
on write    lvi-pos save        " ...on :w...
on bufleave lvi-pos save        " ...and when you leave a buffer
on bufenter lvi-pos restore     " set `" on every file you open (no cursor move)
on ready    lvi-pos restore     " ...same for the file(s) opened at startup
" Prefer to land AT your old spot automatically? Add -j (jump) -- but only on
" `ready`. On `bufenter` a jump lands after a cross-file list step and steals it,
" so keep the auto-jump to startup:
"     on ready    lvi-pos restore -j

" }}}
" ---- global marks (vi's uppercase file marks A-Z) ---------------------- {{{

" Lowercase marks a-z are per-buffer and built in; uppercase A-Z remember a FILE
" too, so `A jumps to that file from anywhere. lvi-gmark stores them (one
" mark/path/line/col line under $XDG_STATE_HOME, LVI_GMARK_FILE to move it). The
" core fires markset when you press m<A-Z> and markjump on `<A-Z>/'<A-Z>, handing
" the letter to the hook; with these two lines gone, uppercase marks fall back to
" ordinary buffer-local ones.
on markset  lvi-gmark set
on markjump lvi-gmark go
" List them any time (\m -- the marks leaf); or from a shell: !lvi-gmark list
map \m :!lvi-gmark list<CR>

" }}}
" ---- multiple instances editing one file (lvi-mirror) ------------------ {{{

" One process is one view, so the same file open in two panes has two buffers
" that don't know about each other. lvi-mirror keeps them in sync: bound on
" change and write, it pushes an edited buffer's text to every OTHER view showing
" the same file. Put both lines in EVERY pane's rc (i.e. here). Off by default --
" you only want it if you routinely open one file in several panes:
"   on change lvi-mirror
"   on write  lvi-mirror

" }}}
" ---- custom text objects ----------------------------------------------- {{{

" Builtin objects (iw, i(, i", ip, ...) are in the core; language-aware ones are
" a `:textobj KEY CMD` filter -- lvi shells CMD out synchronously and applies the
" operator itself, so cit/dat/yit behave like builtins (c even enters insert).
" lvi-textobj-tag adds Vim's tag object for HTML/XML, with no HTML in the core.
textobj t lvi-textobj-tag       " dit/cit/dat/yat on the enclosing tag

" }}}
" ---- increment / decrement (no Ctrl-A in the core; the ! filter is enough) {{{

" lvi-incr rewrites the first number on each piped line (line i gets i*step), so
" one filter is both point Ctrl-A and visual g-Ctrl-A. These map the old reflex
" onto the current line; over a range, use it directly: !ip lvi-incr (ramp) or
" !ip lvi-incr -b 1 (renumber a list).
map <C-a> :.!lvi-incr<CR>            " increment the number on this line
map <C-x> :.!lvi-incr -s -1<CR>      " decrement it

" }}}
" ---- surround & comment (g@ operators) --------------------------------- {{{

" g@{motion} runs the `operatorfunc` command over the span (like :bg, but driven
" by a motion). Each map sets operatorfunc, then presses g@, so it waits for a
" motion -- vim's <expr>-map trick as a plain key sequence. surround takes a pair
" (a shell-safe alias, or a quoted literal); comment auto-detects the syntax from
" the file, or takes one (//, hash, colon, cblock, html). surround lives on the
" s-prefix (mnemonic, and it only shadows the builtin `s` for these follows).
map s( :set opfunc=lvi-surround paren<CR>g@    " s(iw -> (word), s($ to line end
map s{ :set opfunc=lvi-surround brace<CR>g@
map s[ :set opfunc=lvi-surround bracket<CR>g@
map s< :set opfunc=lvi-surround angle<CR>g@
map s" :set opfunc=lvi-surround dquote<CR>g@
map s' :set opfunc=lvi-surround squote<CR>g@
map s` :set opfunc=lvi-surround tick<CR>g@
map s* :set opfunc=lvi-surround star<CR>g@     " s*iw -> *word* (Markdown)
map gc :set opfunc=lvi-comment<CR>g@           " gcip toggles a paragraph, gcj 2 lines
map gC :set opfunc=lvi-comment<CR>g@@          " gC toggles the current line
" (No map timeout in lvi: `gc` fires the instant it's typed, so a vim-style `gcc`
" map is unreachable -- gC above, or `gc@`, comments the current line instead.)

" }}}
" ---- diff (lvi-diff / lvi-stagediff) ----------------------------------- {{{

" lvi-diff is launched by hand over two live views (lvi-diff WID_A WID_B) and
" installs its own maps INTO those panes -- they are not rc defaults, but they
" follow the same scheme so they read the same:
"   ]c / [c   next / prev hunk (shared with git changes -- same concept)
"   zx        toggle the fold over the surrounding unchanged region (z = folds)
"   \d MENU   \dp put the hunk across to the peer, \do obtain it from the peer
"             (vim's diff-mode dp / do, on the leader so they don't shadow d).

" }}}
