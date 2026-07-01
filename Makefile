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
DESTDIR ?=

LUAJIT  ?= luajit
SCDOC   ?= scdoc
INSTALL ?= install

APPDIR  = $(LIBDIR)/lvi
MODULES = buffer.lua bufs.lua client.lua config.lua disp.lua editor.lua \
          ex.lua normal.lua path.lua proto.lua render.lua sys.lua term.lua
CONTRIB = contrib/lvi-highlight contrib/lvi-hl-pygments contrib/lvi-hl-bat \
          contrib/lvi-hl-ansi contrib/lvi-search contrib/lvi-open
TESTS   = $(wildcard test/*_test.lua)

.PHONY: all man test clean install uninstall

all: man

man: lvi.1

lvi.1: lvi.1.scd
	$(SCDOC) < lvi.1.scd > $@

test:
	@for t in $(TESTS); do echo "== $$t"; $(LUAJIT) $$t || exit 1; done

clean:
	rm -f lvi.1

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
	# Manpage.
	$(INSTALL) -d $(DESTDIR)$(MANDIR)/man1
	$(INSTALL) -m 0644 lvi.1 $(DESTDIR)$(MANDIR)/man1/lvi.1

uninstall:
	rm -rf $(DESTDIR)$(APPDIR)
	rm -f $(DESTDIR)$(BINDIR)/lvi
	for f in $(CONTRIB); do rm -f $(DESTDIR)$(BINDIR)/$$(basename $$f); done
	rm -f $(DESTDIR)$(MANDIR)/man1/lvi.1
