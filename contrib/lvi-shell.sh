# lvi-shell.sh -- shell functions that drive a running lvi; source from your rc.
#
# The inverse of the contrib pickers: instead of lvi running a tool that phones
# home over the socket, YOUR SHELL is the tool. Source this file from your
# shell's rc (zsh/bash/ksh -- it uses hyphenated function names and `local`,
# so not strict POSIX sh):
#
#     . /path/to/lvi/contrib/lvi-shell.sh
#
# and every path argument gets your shell's own completion, history, and
# expansion -- the plain-autocompletion answer to wishing :w had <Tab>.
#
#   lvi-saveas [-f] PATH   write the buffer as PATH (-f forces, i.e. :w!)
#   lvi-e FILE             open FILE in the running view
#   lvi-r FILE             read FILE into the buffer after the cursor line
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
# Config: LVI (the client binary; default `lvi`); LVI_PS1_TAG (prompt marker;
# default `(lvi FILE) `, empty disables).

# Tag the prompt when this shell lives under an lvi view (see header). The
# ${VAR-default} form (no colon) is deliberate: set-but-empty LVI_PS1_TAG
# disables the tag, unset gets the default. LVI_PS1_TAGGED guards a re-source
# from stacking tags; it is not exported, so a nested shell tags itself anew.
case $- in *i*)
  if [ -n "$LVI_WID" ] && [ -z "$LVI_PS1_TAGGED" ]; then
    LVI_PS1_TAGGED=1
    PS1="${LVI_PS1_TAG-(lvi${LVI_FILE:+ ${LVI_FILE##*/}}) }$PS1"
  fi ;;
esac

# Absolutize and escape one path argument for splicing into an ex command.
lvi__path() {
  case $1 in /*) ;; *) set -- "$PWD/$1" ;; esac
  printf '%s\n' "$1" | sed 's/[~{[*?$"'\''`\\]/\\&/g'
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
