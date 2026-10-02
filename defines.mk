PACKAGE=pve-manager

BINDIR=$(DESTDIR)/usr/bin
LIBEXECDIR=$(DESTDIR)/usr/libexec/proxmox
PERLLIBDIR=$(DESTDIR)/usr/share/perl5
MAN1DIR=$(DESTDIR)/usr/share/man/man1
MAN8DIR=$(DESTDIR)/usr/share/man/man8
CRONDAILYDIR=$(DESTDIR)/etc/cron.daily
INITDBINDIR=$(DESTDIR)/etc/init.d
SERVICEDIR=$(DESTDIR)/usr/lib/systemd/system
CRONDIR=$(DESTDIR)/etc/cron.d
BASHCOMPLDIR=$(DESTDIR)/usr/share/bash-completion/completions/
ZSHCOMPLDIR=$(DESTDIR)/usr/share/zsh/vendor-completions/
HARADIR=$(DESTDIR)/usr/share/cluster
DOCDIR=$(DESTDIR)/usr/share/doc/$(PACKAGE)
PODDIR=$(DESTDIR)/usr/share/doc/$(PACKAGE)/pod
USRSHARE=$(DESTDIR)/usr/share/$(PACKAGE)
WWWBASEDIR=$(DESTDIR)/usr/share/$(PACKAGE)
WWWIMAGEDIR=$(WWWBASEDIR)/images
WWWTOUCHDIR=$(WWWBASEDIR)/touch
WWWCSSDIR=$(WWWBASEDIR)/css
WWWFONTSDIR=$(WWWBASEDIR)/css/fonts
WWWJSDIR=$(WWWBASEDIR)/js

# Which init system the services are integrated with: 'systemd' installs the
# systemd units, 'lsbservice' LSB init scripts (as used by sysvinit and
# OpenRC). Can be overridden on the command line, e.g. by debian/rules
# depending on which Debian build profile is active (see debian/control's
# pkg.pve-manager.lsbservice profile). Perl code isn't affected, it goes
# through pve-common's PVE::InitSystem, whose backend is selected when
# building pve-common.
PVE_INIT_SYSTEM ?= systemd

ifeq ($(filter $(PVE_INIT_SYSTEM),systemd lsbservice),)
$(error unsupported PVE_INIT_SYSTEM '$(PVE_INIT_SYSTEM)' (expected 'systemd' or 'lsbservice'))
endif
