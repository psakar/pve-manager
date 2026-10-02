# systemd usage in pve-manager

Analysis of where pve-manager depends on systemd, and what that means for
building, installing and running it on a systemd-free Debian derivative
(Devuan 6 "excalibur", trixie-based, sysvinit as PID 1 with OpenRC as the rc
system).

Analysed at commit `58350116` (fix #6735: api: pci: allow mdevscan access via
mapping permissions). This is the pve-manager counterpart to
`proxmox-rs/systemd-usage-analysis.md`.

## Context

- pve-common (branch `feature/init-systems-refactoring`) now has the
  `PVE::InitSystem` facade. Its `Systemd` and `LSBService` backends are
  selected at build time by the `pkg.pve-common.lsbservice` build profile, and
  the LSBService backend was runtime-tested against OpenRC on Devuan.
- That facade currently covers `start_service`, `stop_service`,
  `restart_service`, `enter_systemd_scope`, `wait_for_unit_removed`,
  `is_unit_active` (scope cgroups only) and the timezone functions.
  pve-manager needs more than that; see the "gaps" section below.
- pve-manager calls `systemctl` directly almost everywhere. It doesn't go
  through `PVE::Systemd` or `PVE::InitSystem`, with the timezone code as the
  only exception.

## Package availability on Devuan excalibur

| Package | Available | Notes |
|---|---|---|
| `systemd` | **no** | pve-manager has a hard `Depends: systemd` (`debian/control:101`), so it **cannot be installed** as is. |
| `systemd-standalone-tmpfiles` | yes (257.13) | Could replace `systemd-tmpfiles` for `debian/tmpfiles`. |
| `proxmox-mini-journalreader` | no (Proxmox repo only) | It reads the systemd journal, and there's no journal on Devuan. |
| `init-system-helpers` (`deb-systemd-helper`, `deb-systemd-invoke`, `service`, `update-rc.d`, `invoke-rc.d`) | yes | `deb-systemd-invoke` does nothing when systemd isn't running. |
| `eudev` (installed instead of systemd-udevd) | yes (3.2.14) | Doesn't apply systemd `.link` files (`net_setup_link`). |

## Findings

### 1. Packaging (`debian/`, `services/`, `defines.mk`)

| Location | What | Effect on Devuan |
|---|---|---|
| `debian/control:101` | `Depends: systemd` | **Install blocker.** |
| `debian/control:86` | `Depends: proxmox-mini-journalreader (>= 1.7)` | Installable from the Proxmox repo, but useless without a journal (see 3.3). |
| `services/*.service`, `*.timer`, `*.target`, installed to `/usr/lib/systemd/system` (`defines.mk:10`, `services/Makefile`) | Only systemd units ship. There are no `/etc/init.d` scripts. | **No PVE daemon starts at boot.** |
| `services/ceph-after-pve-cluster.conf` | Drop-ins for `ceph-{mon,mgr,osd,volume,mds}@.service.d` | No equivalent. Dead files on Devuan. |
| `debian/postinst:150-166` | Enables units by hand with `deb-systemd-helper unmask/enable/update-state` | Creates symlinks under `/etc/systemd/system` that nothing uses. Harmless but pointless. |
| `debian/postinst:120-124, 188-198`, `update_ceph_conf` | `deb-systemd-invoke reload-or-try-restart/start/restart` on install, upgrade and the `pve-api-updates` trigger, plus `systemctl -q is-enabled` | **Silently does nothing** when systemd isn't running: daemons aren't (re)started after install or upgrade, and an upgrade keeps running the old code. `systemctl is-enabled` fails, so the start loop is skipped. |
| `debian/postinst:146` | `systemctl --system daemon-reload` | Fails, but is guarded with `|| true`. |
| `debian/postinst:104-108` + `debian/tmpfiles` | `systemd-tmpfiles --create` for `/run/pve` (0750 root:www-data) | Guarded by `command -v`, so it's skipped, and nothing recreates `/run/pve` after a reboot (`/run` is a tmpfs). |
| `debian/lintian-overrides:5` | Override for `pvebanner.service` | Only relevant to the systemd variant. |

#### Unit inventory (what an LSB/OpenRC variant has to replace)

| Unit | Type | Ordering / dependencies | Notes for an init-script equivalent |
|---|---|---|---|
| `pvenetcommit.service` | oneshot | `DefaultDependencies=no`, after `local-fs`, **before `sysinit`** | Moves `/etc/network/interfaces.new` into place and removes the OVS db. Must run **before `networking`** (`X-Start-Before: networking`). |
| `pvebanner.service` | oneshot | after `local-fs`, before `console-getty`, `WantedBy=getty.target` | Writes `/etc/issue`. On sysvinit, getty is started from inittab after rc 2, so starting it in rc 2 is enough. |
| `pvedaemon.service` | forking, `PIDFile=/run/pvedaemon.pid`, `Restart=on-failure` | wants/after `corosync`, `pve-cluster` | `pvedaemon start/stop/restart` already daemonizes itself (`PVE::Daemon`), so the init script is just a thin wrapper. |
| `pveproxy.service` | forking, `PIDFile=/run/pveproxy/pveproxy.pid`, `Restart=on-failure` | wants/after `pve-cluster`, `pvedaemon`, `ssh`, `pve-storage.target` | `ExecStartPre=pvecm updatecerts --silent`, `ExecStartPost=pveupdate` (if `/var/log/pveam.log` is missing). |
| `spiceproxy.service` | forking, `PIDFile=/run/pveproxy/spiceproxy.pid` | wants/after `pveproxy` | |
| `pvestatd.service` | forking, `PIDFile=/run/pvestatd.pid` | after `pve-cluster`, `pvenetcommit` | |
| `pvescheduler.service` | forking, `PIDFile=/run/pvescheduler.pid`, `KillMode=process` | after `pve-cluster`, `pve-guests`, `pve-storage.target` | `KillMode=process` means a stop must not kill running jobs (worker children). A pidfile-based stop already behaves that way. |
| `pve-guests.service` | oneshot, `RemainAfterExit`, `TimeoutSec=infinity`, `RefuseManualStart/Stop` | after `pveproxy`, `pvestatd`, `spiceproxy`, `pve-firewall`, `lxc`, `pve-ha-{crm,lrm}`; alias `pve-manager.service` | **Most critical.** Start: `pve-startall-delay` + `pvesh create /nodes/localhost/startall`. Stop: `vzdump -stop` + `stopall`. Its stop has to run before its dependencies stop at shutdown. |
| `pve-sdn-commit.service` | oneshot | after `frr`, `network`, `corosync`; wants `pve-cluster` | |
| `pve-firewall-commit.service` | oneshot | after `corosync`; wants `pve-cluster` | |
| `pve-storage.target` | target | after `remote-fs`, `ceph*.target`, `glusterd`, `open-iscsi` | No LSB targets. Fold into `Should-Start: $remote_fs open-iscsi glusterd ceph` of the dependants. |
| `pve-daily-update.timer` → `.service` | timer, `OnCalendar=1:00`, `RandomizedDelaySec=5h`, `Persistent=true` | after `network-online`, `pve-cluster` | Replace with a cron job (`/etc/cron.d`) with a random sleep. `postrm` still removes an old `/etc/cron.d/pveupdate`, which shows this used to be cron-based. `Persistent=` needs anacron or `cron.daily`. |

### 2. Service control from Perl code: direct `systemctl`

| Location | Call | Purpose | Facade equivalent needed |
|---|---|---|---|
| `PVE/API2/Services.pm:68` | `systemctl show <svc>` (parses `Description`, `SubState`, `ActiveState`, `UnitFileState`, `LoadState`, `Type`, `Result`) | **Node → System** service list and state in the GUI and API | New: `service_status($name)` returning `{desc, state, active-state, unit-state}` |
| `PVE/API2/Services.pm:111` | `systemctl start/stop/restart/reload/try-reload-or-restart <svc>` | Service start/stop/restart buttons | `start/stop/restart_service` exist. Add `reload_service` and `try_reload_or_restart_service`. |
| `PVE/API2/Services.pm:20-43` | Service list includes `systemd-journald` and `systemd-timesyncd`; `sshd`/`syslog` are systemd aliases | | Needs a backend-specific list (e.g. `rsyslog`, `ssh`, `ntpsec`/`chrony`), or filtering out services that don't exist. |
| `PVE/API2/Certificates.pm:152,201`, `PVE/API2/ACME.pm:220,303,378`, `bin/pveupdate:133` | `systemctl reload-or-restart pveproxy` | Reload pveproxy after certificate changes | `restart_service('pveproxy', 1)` (reload, fall back to restart) already exists |
| `PVE/CLI/pveceph.pm:310` | `systemctl try-reload-or-restart pvedaemon.service pveproxy.service` | After Ceph install | New: `try_reload_or_restart_service` |
| `configs/pve.logrotate:11-12` | `/bin/systemctl try-reload-or-restart pveproxy.service / spiceproxy.service` | logrotate postrotate | Shell, so it needs a variant file or `invoke-rc.d <svc> reload` |
| `PVE/Ceph/Services.pm:139-148` (`ceph_service_cmd`) | `systemctl enable/disable/start/stop/restart ceph-<type>@<id>` / `ceph-<type>.target` / `ceph.target` | Create/destroy/start/stop of Ceph MON/MGR/MDS/OSD | New: `enable_service/disable_service`, plus templated instances (`@`) and targets, which LSB lacks |
| `PVE/Ceph/Services.pm:19-38` | Scans `/etc/systemd/system/ceph-<type>.target.wants` and `/run/systemd/system/...` | Detects locally enabled Ceph daemons | Needs a backend function: "list enabled instances of a template" |
| `PVE/API2/Ceph/OSD.pm:779` | `systemctl show ceph-osd@N --property MainPID` | OSD details (PID) | New: `service_main_pid` |
| `PVE/API2/Ceph/OSD.pm:1089` | `systemctl disable --runtime ceph-osd@N` | OSD destroy | Same as above |
| `bin/pve-cephx-rotate-service-keys:3278-4671` | `systemctl reset-failed/restart/stop/start ceph-*@*` on **remote nodes** over ssh | Ceph key rotation | Has to run the right command per remote node's init system |
| `PVE/CLI/pve8to9.pm:125-150, 433-434, 1552-1580, 2224-2227` | `systemctl is-enabled/is-active` | 8→9 upgrade checker | Irrelevant for a Devuan port |

### 3. Logging: journal readers

| Location | Mechanism | Effect on Devuan |
|---|---|---|
| `PVE/API2/Nodes.pm:884-972` (`GET /nodes/{node}/syslog`) → **pve-common** `PVE::Tools::dump_journal` (`src/PVE/Tools.pm:841`) | `journalctl -o short --no-pager [--unit] [--since] [--until]` | **Broken**: `journalctl` comes from the `systemd` package, which isn't installable. Used by the GUI **Syslog** panel and service log views. |
| `PVE/API2/Nodes.pm:975-1125` (`GET /nodes/{node}/journal`) | `/usr/bin/mini-journalreader -j/-J [...] -u <unit>`, piped through gzip | **Broken**: no journal exists. Used by the GUI journal view (`www/manager6/node/Config.js:178,257`). Unit aliases (`postfix@-`, `ssh`) are systemd-specific. |
| `PVE/API2/APT.pm:892` | Lists `proxmox-mini-journalreader` in the package-version report | Cosmetic |

Note that `PVE::Tools::dump_journal` lives in **pve-common** but isn't part of
the `PVE::InitSystem` facade yet.

### 4. Timezone

| Location | Call | Status |
|---|---|---|
| `PVE/API2/Nodes.pm:1695, 1729` | `PVE::Systemd::get_timezone` / `set_timezone` | **Already works.** `PVE::Systemd` delegates to `PVE::InitSystem`, and the LSBService implementation was runtime-tested on Devuan (`/etc/localtime` based). |

### 5. Networking: systemd `.link` files (udev)

| Location | What | Effect on Devuan with eudev |
|---|---|---|
| `configs/proxmox-ve-default.link` → `/usr/lib/systemd/network/99-default.link.d/proxmox-mac-address-policy.conf` | `MACAddressPolicy=none` for all interfaces, so bridges inherit the first port's MAC | **Ignored** (eudev has no `net_setup_link`). eudev doesn't generate random MACs for bridges the way systemd-udevd does, so it's likely unnecessary. Needs verifying. |
| `PVE/CLI/pve_network_interface_pinning.pm:177,485` (`pve-network-interface-pinning`) | Writes `/usr/local/lib/systemd/network/50-pve-<iface>.link` to pin NIC names | **Doesn't work** with eudev. Would need udev rules (`/etc/udev/rules.d/70-persistent-net.rules`-style `NAME=`) instead. |
| `configs/virtual-function-pinning-helper` + `.rules` | udev helper that looks for the `.link` files above | Udev rules work under eudev, but the helper depends on the `.link`-based pinning above. |

### 6. Process model: not a problem

- `pvedaemon`, `pveproxy`, `spiceproxy`, `pvestatd` and `pvescheduler` use
  `PVE::Daemon`. They daemonize themselves, write pidfiles, and implement
  `start`/`stop`/`restart` (re-exec) as CLI commands, so they don't depend on
  systemd. LSB scripts can call `<daemon> start|stop|restart` directly.
- `PVE::Daemon`'s `$init_ppid` check (`getppid() == 1`) is also true under
  sysvinit.
- Restarting crashed daemons (`Restart=on-failure` for pvedaemon and pveproxy)
  **doesn't happen** under sysvinit. OpenRC's `supervise-daemon` could do it,
  but needs the daemon in the foreground (`start --debug` currently also
  enables debug output).
- Guest processes: qemu-server and pve-container use
  `PVE::Systemd::enter_systemd_scope`, which already goes through
  `PVE::InitSystem` (cgroup-based in LSBService, runtime-tested). That's not
  pve-manager code, but the `startall` from `pve-guests` relies on it.

### 7. Not systemd dependencies (false positives)

- "journal" in Ceph code (`journal_disks`, `ceph/OSD.js`) refers to Ceph OSD
  journals.
- `PVE::CalendarEvent` and the "systemd calendar event" schema descriptions
  (`Job/Registry.pm`) are only a syntax.
- `/sbin/reboot` / `/sbin/poweroff` in `PVE/API2/Nodes.pm:706-709` (node power
  API) work under sysvinit as they are.
- `PVE::SafeSyslog` writes to syslog (`/dev/log`), which works with rsyslog.

## Dependencies outside pve-manager

A working PVE node on Devuan also needs init scripts or Devuan equivalents for
the services pve-manager orders against or lists in the Services API. These
come from other source packages and are out of scope here, but they block an
end-to-end setup:

- Proxmox packages: `pve-cluster` (pmxcfs), `pve-firewall`, `pvefw-logger`,
  `proxmox-firewall`, `pve-ha-crm`/`pve-ha-lrm` (pve-ha-manager), `qmeventd`
  (qemu-server), `pve-lxc-syscalld` (pve-container), `lxc` (Proxmox build),
  `proxmox-mail-forward`.
- Debian packages (usually with Devuan init scripts already): `corosync`,
  `lxcfs`, `chrony`, `cron`, `ssh`, `postfix`, `rsyslog`, `frr`,
  `open-iscsi`, `glusterd`.
- Ceph: Debian/Proxmox Ceph packages only ship systemd units (templated
  `ceph-*@.service`, `ceph*.target`). Ceph management in pve-manager
  (`PVE/Ceph/*`, `pveceph`, `pve-cephx-rotate-service-keys`) is the most
  systemd-entangled area.

## Summary by impact

| Area | Status on Devuan | Severity |
|---|---|---|
| `Depends: systemd` | Can't install | **blocker** |
| No init scripts for the PVE daemons | Nothing starts at boot | **blocker** |
| postinst restarts via `deb-systemd-invoke` | Silently skipped on install, upgrade and API-update trigger | high |
| `/run/pve` via systemd-tmpfiles | Missing after reboot | high |
| Daily update timer | Never runs | medium |
| Services API/GUI (`systemctl show`/start/stop) | Broken | high |
| pveproxy reload after cert/ACME changes, logrotate | Broken (new cert not loaded, log reopen fails) | high |
| Syslog/journal API and GUI | Broken | medium |
| Ceph management | Broken | high, but Ceph itself is systemd-only |
| NIC name pinning (`.link` files) | Broken | low/medium |
| Timezone API | Works (via `PVE::InitSystem`) | none |
| Node reboot/shutdown | Works | none |
| Daemon process model (`PVE::Daemon`) | Works, but no auto-restart on crash | low |
| pve8to9 checker | Irrelevant | none |

See `init-system-rework.md` for the plan.
