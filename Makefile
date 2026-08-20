# lvi -- build the manpage, run tests, install.
#
# Install layout: lvi is a LuaJIT script that loads sibling .lua modules and the
# vendored argparse, so the runtime tree goes under $(APPDIR) and a tiny launcher
# on $(PATH) execs it. Contrib helpers and the manpage install alongside.
#
# Override PREFIX (or the individual dirs) to relocate; set DESTDIR for staged /
# packaged installs (it is prepended to every path but never baked into files).

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib
MANDIR  ?= $(PREFIX)/share/man
DOCDIR  ?= $(PREFIX)/share/doc/lvi
DESTDIR ?=

LUAJIT  ?= luajit
SCDOC   ?= scdoc
INSTALL ?= install

APPDIR  = $(LIBDIR)/lvi
MODULES = buffer.lua bufs.lua client.lua config.lua disp.lua editor.lua \
          ex.lua normal.lua path.lua proto.lua render.lua sys.lua term.lua
# Contrib is globbed, not listed: a hand-written list went stale for 30-odd
# scripts, and going missing is not a soft failure here -- the dispatchers
# resolve their adapters and each other through $DIR, which is BINDIR once
# installed, so a helper left behind breaks its caller rather than merely being
# absent. lvirc-man is data ($DIR/lvirc-man, read by lvi-man) so it installs
# beside the scripts but unexecutable; the sample rc and the shell functions are
# read/sourced by the user, so they go to DOCDIR instead.
CONTRIB      = $(filter-out %.md %.sh %.vim contrib/lvirc-man,$(wildcard contrib/lvi*))
CONTRIB_DATA = contrib/lvirc-man
CONTRIB_DOC  = contrib/lvirc.sample.vim contrib/lvi-shell.sh
TESTS   = $(wildcard test/*_test.lua)

.PHONY: all man test clean install uninstall

all: man

# The manpage lands under man1/ (gitignored) so the repo root can go straight on
# MANPATH -- man searches each MANPATH entry for a manN/ subdir, finds man1/lvi.1.
man: man1/lvi.1

man1/lvi.1: lvi.1.scd
	$(INSTALL) -d man1
	$(SCDOC) < lvi.1.scd > $@

test:
	@for t in $(TESTS); do echo "== $$t"; $(LUAJIT) $$t || exit 1; done

# Release-notes SLOC: core (the .lua modules + the lvi entry point) vs contrib
# vs tests, counted from the git index so it tracks what actually ships (vendor
# excluded). --script-lang=Lua,luajit makes the extensionless `lvi` script (and
# the one luajit contrib helper) count as Lua instead of vanishing from cloc's
# extension/shebang detection. --csv drops cloc's rules/titles/version banner;
# awk then tags each row with its group, reorders to group,language,files,…, and
# skips cloc's per-run header + SUM row; column aligns the merged runs into one
# table (drop the `column` pipe for raw CSV). Out of .PHONY: on-demand.
sloc:
	@{ printf 'group,language,files,blank,comment,code\n'; \
	   for g in \
	     "CORE:$$(git ls-files -- '*.lua' lvi ':!:test' ':!:vendor')" \
	     "CONTRIB:$$(git ls-files -- contrib ':!:*.md' ':!:*.sample' ':!:*.sample.vim')" \
	     "TESTS:$$(git ls-files -- test)"; do \
	       printf '%s\n' "$${g#*:}" | tr ' ' '\n' | \
	         cloc --script-lang=Lua,luajit --quiet --hide-rate --csv --list-file=- | \
	         awk -F, -v grp="$${g%%:*}" \
	           'NR>1 && $$2!="SUM"{print grp","$$2","$$1","$$3","$$4","$$5}'; \
	   done; } | column -t -s,

clean:
	rm -rf man1

install: man
	# Runtime tree: the script, its modules, and just the vendored argparse
	# module (the path lvi's package.path expects, minus the repo's docs/specs).
	$(INSTALL) -d $(DESTDIR)$(APPDIR)
	$(INSTALL) -m 0644 $(MODULES) $(DESTDIR)$(APPDIR)/
	$(INSTALL) -m 0755 lvi $(DESTDIR)$(APPDIR)/lvi
	$(INSTALL) -d $(DESTDIR)$(APPDIR)/vendor/argparse/src
	$(INSTALL) -m 0644 vendor/argparse/src/argparse.lua $(DESTDIR)$(APPDIR)/vendor/argparse/src/
	# Launcher on PATH (references the real runtime path, not DESTDIR).
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	printf '#!/bin/sh\nexec %s %s/lvi "$$@"\n' '$(LUAJIT)' '$(APPDIR)' > $(DESTDIR)$(BINDIR)/lvi
	chmod 0755 $(DESTDIR)$(BINDIR)/lvi
	# Contrib helpers on PATH (they find each other and the launcher there).
	$(INSTALL) -m 0755 $(CONTRIB) $(DESTDIR)$(BINDIR)/
	$(INSTALL) -m 0644 $(CONTRIB_DATA) $(DESTDIR)$(BINDIR)/
	# Sample rc and shell functions, for the user to copy and source.
	$(INSTALL) -d $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 0644 $(CONTRIB_DOC) $(DESTDIR)$(DOCDIR)/
	# Manpage.
	$(INSTALL) -d $(DESTDIR)$(MANDIR)/man1
	$(INSTALL) -m 0644 man1/lvi.1 $(DESTDIR)$(MANDIR)/man1/lvi.1

uninstall:
	rm -rf $(DESTDIR)$(APPDIR)
	rm -f $(DESTDIR)$(BINDIR)/lvi
	for f in $(CONTRIB) $(CONTRIB_DATA); do rm -f $(DESTDIR)$(BINDIR)/$$(basename $$f); done
	rm -rf $(DESTDIR)$(DOCDIR)
	rm -f $(DESTDIR)$(MANDIR)/man1/lvi.1
