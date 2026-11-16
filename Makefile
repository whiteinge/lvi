# lvi -- build the manpage, run tests, install.
#
# Install layout: lvi is a LuaJIT script that loads sibling .lua modules and the
# vendored argparse, so the runtime tree goes under $(APPDIR) and a tiny launcher
# on $(PATH) execs it. Contrib helpers and the manpage install alongside.
#
# Override PREFIX (or the individual dirs) to relocate; set DESTDIR for staged /
# packaged installs (it is prepended to every path but never baked into files).
#
# `make static` is the alternative to that tree: one self-contained build/lvi
# (see the target for how and why).

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib
MANDIR  ?= $(PREFIX)/share/man
DOCDIR  ?= $(PREFIX)/share/doc/lvi
DESTDIR ?=

LUAJIT  ?= luajit
SCDOC   ?= scdoc
INSTALL ?= install
# luastatic is a single Lua script; point this at it however it is installed,
# e.g. LUASTATIC='luajit /path/to/luastatic.lua'.
LUASTATIC ?= luastatic
LUAJIT_PC ?= luajit
LUAJIT_A  ?= $(shell pkg-config --variable=libdir $(LUAJIT_PC))/libluajit-5.1.a
LUAJIT_CFLAGS ?= $(shell pkg-config --cflags $(LUAJIT_PC))

APPDIR  = $(LIBDIR)/lvi
MODULES = buffer.lua bufs.lua client.lua config.lua disp.lua editor.lua \
          ex.lua normal.lua path.lua proto.lua render.lua sys.lua term.lua
# Vendored runtime modules, each installed at its repo-relative path. Mirrors
# the vendor entry in lvi's package.path (lvi:12) -- change the two together.
VENDOR  = vendor/argparse/src/argparse.lua
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

.PHONY: all man test static clean install install-static install-common uninstall

all: man

# The manpage lands under man1/ (gitignored) so the repo root can go straight on
# MANPATH -- man searches each MANPATH entry for a manN/ subdir, finds man1/lvi.1.
man: man1/lvi.1

man1/lvi.1: lvi.1.scd
	$(INSTALL) -d man1
	$(SCDOC) < lvi.1.scd > $@

# One binary with LuaJIT and every module linked in, so it runs with no luajit
# on the host. luastatic names each embedded module by its path (dir/x.lua ->
# require "dir.x") and writes its output beside its input, named after the main
# script -- so everything is staged flat into a scratch dir (argparse included,
# making require "argparse" resolve), and the main script goes in as lvi.lua so
# the binary it emits never lands on the repo's `lvi`. The bundled modules are
# found through package.preload, which require consults before the
# package.path lvi builds from arg[0], so that path setup is harmless here.
# libc stays dynamic on purpose: sys.lua's FFI resolves socket/poll/ioctl
# through ffi.C, i.e. dlsym in the running image, which a -static link breaks.
# Contrib is untouched -- it is shell (plus the luajit/python helpers, which
# still need their interpreters) and reaches this binary as `lvi` on PATH.
static: build/lvi

build/lvi: lvi $(MODULES) $(VENDOR)
	rm -rf build/static
	$(INSTALL) -d build/static
	cp $(MODULES) $(VENDOR) build/static/
	cp lvi build/static/lvi.lua
	cd build/static && $(LUASTATIC) lvi.lua $(MODULES) $(notdir $(VENDOR)) $(LUAJIT_A) $(LUAJIT_CFLAGS)
	mv build/static/lvi $@
	rm -rf build/static

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
	rm -rf man1 build

install: install-common
	# Runtime tree: the script, its modules, and just the vendored modules
	# (at the paths lvi's package.path expects, minus the repo's docs/specs).
	$(INSTALL) -d $(DESTDIR)$(APPDIR)
	$(INSTALL) -m 0644 $(MODULES) $(DESTDIR)$(APPDIR)/
	$(INSTALL) -m 0755 lvi $(DESTDIR)$(APPDIR)/lvi
	for f in $(VENDOR); do \
	  $(INSTALL) -d $(DESTDIR)$(APPDIR)/$$(dirname $$f) && \
	  $(INSTALL) -m 0644 $$f $(DESTDIR)$(APPDIR)/$$f || exit 1; \
	done
	# Launcher on PATH (references the real runtime path, not DESTDIR).
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
	printf '#!/bin/sh\nexec %s %s/lvi "$$@"\n' '$(LUAJIT)' '$(APPDIR)' > $(DESTDIR)$(BINDIR)/lvi
	chmod 0755 $(DESTDIR)$(BINDIR)/lvi

# The static binary takes the launcher's place on PATH; no runtime tree. A tree
# left by an earlier `make install` is left alone (nothing runs it; `make
# uninstall` first to clear it), and `make install` later simply overwrites the
# binary with the launcher again.
install-static: static install-common
	$(INSTALL) -m 0755 build/lvi $(DESTDIR)$(BINDIR)/lvi

# Everything both installs share: contrib, docs, manpage.
install-common: man
	# Contrib helpers on PATH (they find each other and lvi there).
	$(INSTALL) -d $(DESTDIR)$(BINDIR)
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
