include ../defines.mk

all:

SERVICES=			\
	pvebanner.service 	\
	pvenetcommit.service 	\
	pvestatd.service 	\
	pve-guests.service 	\
	pvedaemon.service  	\
	pveproxy.service 	\
	spiceproxy.service	\
	pve-storage.target	\
	pve-daily-update.service\
	pve-daily-update.timer	\
	pvescheduler.service	\
	pve-sdn-commit.service	\
	pve-firewall-commit.service

.PHONY: install
install: install-$(PVE_INIT_SYSTEM)
	install -d $(DESTDIR)/usr/share/doc/$(PACKAGE)/examples/

.PHONY: install-systemd
install-systemd: $(SERVICES)
	install -d $(SERVICEDIR)
	install -m 0644 $(SERVICES) $(SERVICEDIR)
	install -d $(SERVICEDIR)/ceph-mon@.service.d
	install -m 0644 ceph-after-pve-cluster.conf $(SERVICEDIR)/ceph-mon@.service.d
	install -d $(SERVICEDIR)/ceph-mgr@.service.d
	install -m 0644 ceph-after-pve-cluster.conf $(SERVICEDIR)/ceph-mgr@.service.d
	install -d $(SERVICEDIR)/ceph-osd@.service.d
	install -m 0644 ceph-after-pve-cluster.conf $(SERVICEDIR)/ceph-osd@.service.d
	install -d $(SERVICEDIR)/ceph-volume@.service.d
	install -m 0644 ceph-after-pve-cluster.conf $(SERVICEDIR)/ceph-volume@.service.d
	install -d $(SERVICEDIR)/ceph-mds@.service.d
	install -m 0644 ceph-after-pve-cluster.conf $(SERVICEDIR)/ceph-mds@.service.d

INIT_SCRIPTS=			\
	pvebanner		\
	pvenetcommit		\
	pvestatd		\
	pve-guests		\
	pvedaemon		\
	pveproxy		\
	spiceproxy		\
	pvescheduler		\
	pve-sdn-commit		\
	pve-firewall-commit

# LSB init scripts (sysvinit, OpenRC) and a cron job replacing the timer
.PHONY: install-lsbservice
install-lsbservice: $(addprefix init.d/,$(INIT_SCRIPTS)) pve-daily-update.cron
	install -d $(INITDBINDIR)
	install -m 0755 $(addprefix init.d/,$(INIT_SCRIPTS)) $(INITDBINDIR)
	install -D -m 0644 pve-daily-update.cron $(CRONDIR)/pve-daily-update

.PHONY: clean
clean:
	rm -rf *~
