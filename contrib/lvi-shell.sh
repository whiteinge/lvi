# lvi-shell.sh -- shell functions that drive a running lvi; source from your rc.
#
# The inverse of the contrib pickers: instead of lvi running a tool that phones
# home over the socket, YOUR SHELL is the tool. Source this file from your
# shell's rc (zsh/bash/mksh -- it uses hyphenated function names and `local`,
# so not strict POSIX sh, and not ksh93, which lacks `local`):
#
#     . /path/to/lvi/contrib/lvi-shell.sh
#
# and every path argument gets your shell's own completion, history, and
# expansion -- the plain-autocompletion answer to wishing :w had <Tab>.
#
#   lvi-saveas [-f] PATH   write the buffer as PATH (-f forces, i.e. :w!)
#   lvi-e FILE             open FILE in the running view
#   lvi-r FILE             read FILE into the buffer after the cursor line
#   lvi-mv DST             move/rename the file AND the buffer in one command
#   lvi-rm [-f]            delete the file and drop the buffer
#   lvi-sudow              write the current file through sudo
#   lvi-help               the cheat sheet, with recipes
#
# lvi-mv, lvi-rm and lvi-sudow exist because each is a sequence with an
# ordering you have to know, and getting it wrong is quiet rather than loud:
#
#   - lvi-mv moves the file, then repoints the BUFFER at the new name with
#     `:f` -- which renames without writing, so unsaved edits stay unsaved and
#     stay yours. Skip the repoint and the buffer still holds the old path,
#     where the next bare :w silently recreates the file you just moved.
#
#   - lvi-rm always sends `bd!`, never `bd`. You just deleted the file;
#     refusing to drop the buffer over unsaved changes would be refusing to
#     finish the job, and a QUEUED refusal is invisible (see below). Its -f is
#     rm's, not lvi's.
#
#   - lvi-sudow runs `sudo -v` at YOUR prompt first, so the password is asked
#     for here where you are typing, then queues `:w !sudo tee` (which pipes
#     the buffer to a command that runs as root) with `:e!` chained BEHIND it,
#     so a failed write cannot reload the file and discard the edits you were
#     saving. Without the priming the prompt appears on the editor's screen
#     after you exit.
#
# Where they work, and how they behave there:
#
#   - Inside the editor's own :sh (or any :! child): LVI_WID is set, and the
#     editor's loop is FROZEN while you are here -- so the command is sent
#     detached and QUEUED; it executes the instant you exit back to lvi. A
#     queued command's response is discarded (nothing is left listening), so a
#     refused write (file changed on disk) is silent -- the buffer simply stays
#     modified and lvi's quit guard still catches it. Use -f when you mean :w!.
#
#   - Any other terminal: LVI_WID is unset; the command goes to the sole
#     running view (`lvi -w auto`) synchronously and you see the real response
#     ("...12L, 264B written", or the refusal). With several views running,
#     auto refuses -- run it from the target view's own :sh instead, where
#     LVI_WID already picks the right one.
#
# Your `cd` in here is process-local: it cannot move lvi's cwd, and nothing in
# this file can read it back afterwards either. So paths get absolutized on
# both sides, against different directories. A path you TYPE is resolved
# against this shell -- you meant where you are standing. The file the view is
# editing is resolved against LVI_CWD, lvi's own directory, because $LVI_FILE
# holds the path AS OPENED and `lvi doc.txt` makes that `doc.txt`: resolving it
# where you have cd'd to would name a different file, or someone else's.
#
# Paths are absolutized before sending (your cd's don't move lvi's cwd) and
# lvi's expansion metacharacters are escaped (your shell already expanded ~
# and $VAR at the prompt; the name must land in lvi verbatim, not expand
# twice).
#
# Sourcing this file also TAGS THE PROMPT of any interactive shell running
# under an lvi view -- `(lvi foo.txt) $` -- because it is easy to forget you
# are in one, and a forgotten :sh holds the editor frozen (and its socket
# backlog filling) until you exit. Restyle or disable with LVI_PS1_TAG (set
# it empty to disable). A prompt framework that rebuilds PS1 every cycle
# (starship, powerlevel10k) will clobber the tag; key a segment on $LVI_WID
# there instead, e.g. starship:
#
#     [env_var.LVI_WID]
#     format = '[lvi ](bold yellow)'
#
# Sourcing it also prints a two-line banner on entering a shell-out, saying
# what the prompt tag cannot: that lvi is frozen, that commands queue, and that
# `lvi-help` exists. Set LVI_SHELL_BANNER empty to silence it.
#
# Config: LVI (the client binary; default `lvi`); LVI_PS1_TAG (prompt marker;
# default `(lvi FILE) `, empty disables); LVI_SHELL_BANNER (empty disables the
# shell-out banner). LVI_CWD and LVI_CWD_WID are SET by this file rather than
# read as config -- lvi's own directory and the view it belongs to, captured at
# source time -- so an inherited pair survives a nested shell but not a nested
# editor.

# lvi's working directory, captured while we still know it. A shell-out
# inherits it, so at SOURCE time -- your rc, before you have had the chance to
# cd -- $PWD is lvi's. That is the only chance: cd here is process-local, and
# there is no asking a frozen editor. Exported, so a nested shell keeps lvi's
# directory rather than re-capturing its parent's cd.
#
# Stamped with the wid it was captured for, because inherited and right are not
# the same thing. A nested SHELL is still the same view, and must keep the
# value. A nested EDITOR is not: `lvi other.txt` from a shell-out you had cd'd
# in has its own cwd and its own wid, and the inherited LVI_CWD would resolve
# ITS $LVI_FILE against the outer editor's directory -- the wrong-file
# resolution this variable exists to prevent, one level down. Different wid,
# re-capture. An LVI_CWD with no stamp came from somewhere other than this file
# (core, should it ever export one) and is left alone.
if [ -n "$LVI_WID" ]; then
  if [ -z "$LVI_CWD" ] ||
     { [ -n "$LVI_CWD_WID" ] && [ "$LVI_CWD_WID" != "$LVI_WID" ]; }; then
    LVI_CWD=$PWD
    LVI_CWD_WID=$LVI_WID
  fi
  export LVI_CWD LVI_CWD_WID
fi

# Tag the prompt when this shell lives under an lvi view (see header). The
# ${VAR-default} form (no colon) is deliberate: set-but-empty LVI_PS1_TAG
# disables the tag, unset gets the default. LVI_PS1_TAGGED guards a re-source
# from stacking tags; it is not exported, so a nested shell tags itself anew.
case $- in *i*)
  if [ -n "$LVI_WID" ] && [ -z "$LVI_PS1_TAGGED" ]; then
    LVI_PS1_TAGGED=1
    PS1="${LVI_PS1_TAG-(lvi${LVI_FILE:+ ${LVI_FILE##*/}}) }$PS1"
    # The banner carries what the tag cannot. A marker in the prompt says you
    # are in a shell-out; it has no room to say that the editor is stopped
    # dead behind you, that anything you send waits for your exit, or that
    # there is a help command. That is a once-per-shell fact, so it is said
    # once, on the way in, and never again. ${VAR-x} (no colon) so a
    # set-but-empty LVI_SHELL_BANNER disables it, as LVI_PS1_TAG does.
    if [ -n "${LVI_SHELL_BANNER-x}" ]; then
      cat >&2 <<'LVI_BANNER'
lvi: you are in a shell-out -- lvi is stopped, and its socket backlog filling,
     until you exit.  lvi-* commands queue until then;  lvi-help  lists them.
LVI_BANNER
    fi
  fi ;;
esac

# Absolutize one path argument for splicing into an ex command, emitted in the
# literal `-- NAME` spelling (no shell expansion, so nothing to escape).
lvi__path() {
  case $1 in /*) ;; *) set -- "$PWD/$1" ;; esac
  printf -- '-- %s\n' "$1"
}

# Send one ex command: queued-detached under the editor, live otherwise.
lvi__send() {
  if [ -n "$LVI_WID" ]; then
    "${LVI:-lvi}" -w "$LVI_WID" -d -- "$1" &&
      echo "${2:-lvi}: queued -- runs when you exit to lvi" >&2
  else
    "${LVI:-lvi}" -w auto -- "$1"
  fi
}

lvi-saveas() {
  local force=
  [ "$1" = -f ] && { force='!'; shift; }
  [ $# -eq 1 ] || { echo "usage: lvi-saveas [-f] PATH" >&2; return 2; }
  lvi__send "w$force $(lvi__path "$1")" lvi-saveas
}

lvi-e() {
  [ $# -eq 1 ] || { echo "usage: lvi-e FILE" >&2; return 2; }
  lvi__send "e $(lvi__path "$1")" lvi-e
}

lvi-r() {
  [ $# -eq 1 ] || { echo "usage: lvi-r FILE" >&2; return 2; }
  lvi__send "r $(lvi__path "$1")" lvi-r
}

# The file the view is editing. Empty means a buffer with no name (a scratch
# view, `lvi` with no file), which none of the callers below can act on.
#
# The two branches are not interchangeable. Under a shell-out lvi is frozen, so
# asking it anything would block until we exit -- and we would be waiting on an
# editor that is waiting on us. $LVI_FILE is the only source there, and empty
# means empty. Anywhere else the socket answers, so ask: `:path` is the
# machine-readable spelling of `:f`, exactly the path and nothing else.
lvi__file() {
  local f
  if [ -n "$LVI_WID" ]; then
    f=$LVI_FILE
  else
    f=$("${LVI:-lvi}" -w auto -- path) || return 1
  fi
  if [ -z "$f" ]; then
    echo "${1:-lvi}: the buffer has no file name" >&2
    return 1
  fi
  # Resolve against LVI_CWD, never this shell's -- see the header. Outside a
  # shell-out there is no LVI_CWD to resolve against, and guessing is how you
  # delete the wrong file, so a relative path is refused rather than resolved.
  # `raw` (a second argument) skips all of that, for the one caller that hands
  # the name straight back to the EDITOR's shell, where relative is correct.
  case $f in
    /*) ;;
    *)  if [ "$2" = raw ]; then :                  # caller hands it back to lvi
        elif [ -n "$LVI_CWD" ]; then f=$LVI_CWD/$f
        else
          echo "${1:-lvi}: lvi opened '$f' by a relative path, and only its own" \
               ":sh knows what it is relative to -- run this from there" >&2
          return 1
        fi ;;
  esac
  printf '%s\n' "$f"
}

# Move or rename the file and the buffer together. DST may be a directory, as
# mv's may. The repoint is `:f`, not `:w`: renaming a buffer should not decide
# to save it, and if you are mid-edit the write would be one you did not ask
# for. The file moves now, the buffer follows on your exit -- in between, the
# view names a path that is gone, which matters only if you run something else
# against it in that window.
lvi-mv() {
  [ $# -eq 1 ] || { echo "usage: lvi-mv DST" >&2; return 2; }
  local src dst
  src=$(lvi__file lvi-mv) || return 1
  dst=$1
  [ -d "$dst" ] && dst="${dst%/}/${src##*/}"
  mv -- "$src" "$dst" || return 1
  lvi__send "f $(lvi__path "$dst")" lvi-mv
}

# Delete the file and drop the buffer. `bd!` unconditionally: the file is gone
# by the time it runs, so the unsaved changes it would refuse over have nothing
# left to be saved to -- and queued, that refusal would be silent anyway. -f is
# rm's (a write-protected file, a missing one), not lvi's.
lvi-rm() {
  local rmflag=
  [ "$1" = -f ] && { rmflag=-f; shift; }
  [ $# -eq 0 ] || { echo "usage: lvi-rm [-f]" >&2; return 2; }
  local src
  src=$(lvi__file lvi-rm) || return 1
  rm $rmflag -- "$src" || return 1
  lvi__send 'bd!' lvi-rm
}

# Write the current file as root, for when you opened it without sudo. `:w
# !cmd` pipes the buffer to a command's stdin, so tee writing as root needs no
# temp file of ours; `$LVI_FILE` is left for the EDITOR's shell to expand, so
# the name never passes through our quoting. `:e!` then re-reads it -- the pipe
# is opaque, so lvi cannot know its own file was written and would otherwise
# hold a stale conflict stamp and a modified flag.
#
# `sudo -v` runs first so the password is asked for at your prompt, on this
# terminal, rather than on the editor's screen once you exit. Both commands are
# sent detached even outside a shell-out: a synchronous send would sit blocking
# this terminal while the editor's terminal owns the interaction.
lvi-sudow() {
  [ $# -eq 0 ] || { echo "usage: lvi-sudow" >&2; return 2; }
  lvi__file lvi-sudow raw > /dev/null || return 1   # only: does it have a name
  sudo -v || return 1
  local wid=${LVI_WID:-auto}
  # ONE queued command, with the reload chained inside the editor's own shell
  # rather than queued beside it. Two separate sends would both run whatever
  # happened, and `:e!` after a FAILED write re-reads the file and throws your
  # unsaved edits away -- exactly the work you were trying to save, gone with no
  # undo (:e! builds a new buffer). Chained, the reload happens only if tee did.
  # The callback reaches back over the socket while the editor is still inside
  # the shell-out; that connect just waits in the listen backlog and is served
  # the moment the shell-out returns.
  #
  # So the buffer's own modified flag is the receipt: [+] gone means it was
  # written, [+] still there means it was not.
  "${LVI:-lvi}" -w "$wid" -d -- \
    'w !sudo tee -- "$LVI_FILE" > /dev/null && "${LVI:-lvi}" -w "$LVI_WID" -d -- e! < /dev/null' &&
    if [ -n "$LVI_WID" ]; then
      echo "lvi-sudow: queued -- writes when you exit to lvi" >&2
    else
      echo "lvi-sudow: sent -- tee runs on the editor's terminal" >&2
    fi
}

lvi-help() {
  cat <<'LVI_HELP'
lvi shell commands. These drive the lvi view you are inside -- or, outside a
shell-out, the one running view. Inside one they QUEUE: lvi is stopped while
this shell runs, so they execute the moment you exit.

  lvi-e FILE           open FILE in the view
  lvi-r FILE           read FILE into the buffer after the cursor line
  lvi-saveas [-f] P    write the buffer as P and keep editing it there
  lvi-mv DST           move or rename the file and the buffer together
  lvi-rm [-f]          delete the file and drop the buffer, saved or not
  lvi-sudow            write the current file as root ([+] gone = it worked)
  lvi-help             this

Recipes

  rename what you are editing       lvi-mv notes-2026.md
  move it somewhere else            lvi-mv ~/archive/
  throw it away and start clean     lvi-rm
  save it as root                   lvi-sudow
  anything else, by hand            lvi -w "$LVI_WID" -d -- 'set wrap'

Three things that bite

  Quote an ex command in SINGLE quotes. A `!` inside double quotes is history
  expansion, so `"bd!"` strands your prompt at `dquote>` instead of reaching
  lvi.

  Your `cd` in here is yours alone; it never moves lvi. So a path you type is
  resolved where you are standing, and the file lvi is editing is resolved
  where lvi is standing.

  A queued command's reply is thrown away, so a refusal is silent. lvi-saveas
  onto a file that changed on disk just leaves the buffer modified, with
  nothing printed; pass -f when you mean :w!. Outside a shell-out the same
  commands run live and you see the real answer.
LVI_HELP
}
