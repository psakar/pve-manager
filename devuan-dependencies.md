# pve-manager on Devuan: dependency closure and init-system footprint

Which packages are needed to install pve-manager (built with the
`pkg.pve-manager.lsbservice` profile) on Devuan 6 "excalibur", which source
repositories they come from, and how much init-system work each of those
repositories needs. Companion to `systemd-usage-analysis.md` and
`init-system-rework.md`.

Analysed on 2026-10-02 from shallow clones of all repositories on
git.proxmox.com (except the `mirror_*` upstream mirrors), against the Devuan
excalibur package lists.

## Method

- Parse every `debian/control` (or `debian/control.in` where there's no
  `control`) in all repositories into a map of binary package → source repo,
  including `Provides`.
- Starting from pve-manager's `Depends` (lsbservice profile), resolve
  recursively. A dependency counts as satisfied by Devuan if Devuan has a
  version meeting the version constraint. Otherwise it's taken from the
  Proxmox repo building that package, whose own `Pre-Depends`/`Depends` are
  then resolved too. The first satisfiable alternative of an `a | b`
  dependency is used.
- Only **runtime** dependencies (`Pre-Depends`, `Depends`). `Recommends` are
  listed separately. Build dependencies aren't included; building these
  packages will pull in more, e.g. the `librust-*-dev` crates for the Rust
  packages, see the proxmox-perl-rs build in this session.

## Result

- **45 Proxmox packages from 35 source repositories** are needed, with
  pve-cluster and pve-ha-manager built with their `pkg.*.lsbservice` profiles
  (see blocker 1). Without those profiles, a 46th package is pulled in: a
  `systemd` rebuild from Proxmox's `systemd` repository.
- **116 dependencies** are satisfied by Devuan packages.
- **Nothing unresolved.**
- 4 of the 45 are already built and installed on the analysis machine:
  `libpve-common-perl` (lsbservice), `libpve-rs-perl`, `libproxmox-rs-perl`,
  `libproxmox-acme-perl`. `libproxmox-acme-plugins` is built but not yet
  installed.

## Blockers and regressions

1. **Fixed: hard `Depends: systemd`** in **pve-cluster** (`debian/control:39`)
   and **pve-ha-manager** (`debian/control:31`). Devuan has no installable
   `systemd`, so the resolver had to fall back to Proxmox's `systemd` rebuild.
   Both repos now have a build profile dropping the dependency, on their
   `feature/init-systems-refactoring` branches:
   `pkg.pve-cluster.lsbservice` (pve-cluster `9bf237a`) and
   `pkg.pve-ha-manager.lsbservice` (pve-ha-manager `36c292f`). With them, the
   closure no longer contains `systemd`. Both repos are now done, see the
   "Done" table below.
2. **Fixed: regression on the pve-common `feature/init-systems-refactoring`
   branch, independent of Devuan:** commit `007a738` ("Extract PVE::InitSystem
   facade") removed `PVE::Systemd::systemd_call`. qemu-server still calls it
   (`src/PVE/QemuServer/CGroup.pm:25`, `set_unit_properties`, used to change a
   running VM's CPU limit/units over D-Bus), which died with "Undefined
   subroutine", under systemd too. pve-common `af6e7d7` restores it as a
   wrapper around `PVE::InitSystem::Systemd::systemd_call`; with the
   LSBService backend it dies with a clear error instead. qemu-server no
   longer uses it: it changes a running VM's CPU limit and weight via the new
   `PVE::InitSystem::set_scope_properties` (pve-common `b5de93e`, qemu-server
   `545872a`), which also works without systemd.
   The same facade commit also broke `PVE::Systemd::wait_for_unit_removed`
   and `is_unit_active`, again under systemd too: they passed the number of
   arguments instead of the arguments (prototype), so qemu-server didn't
   wait for a VM's old scope to be gone. Fixed in pve-common `e7b30ff`.
3. **Containers are started as systemd units:** pve-container runs
   `systemctl start pve-container@<vmid>` (`src/PVE/LXC.pm:3188`). The unit
   runs `lxc-start -F` with `Delegate=yes`, `KillMode=mixed` and stderr
   redirected to `/run/pve/ct-<vmid>.stderr`. Under LSB this needs a
   replacement, e.g. running `lxc-start` daemonized directly, with a cgroup set
   up like the LSBService scopes.
4. **Fixed: VM processes rely on systemd scopes and units beyond the facade:**
   qemu-server stopped `<vmid>.scope` and reset `pve-dbus-vmstate@<vmid>.service`
   via `systemctl` (`src/PVE/QemuServer.pm:5704-5712`), and started the D-Bus
   VM state helper as a `Type=notify` unit (`src/PVE/QemuServer/DBusVMState.pm:71`).
   Now: the LSBService backend honors the scope's `Slice=qemu.slice`
   (pve-common `cfababb`); changing a VM's CPU limit/weight (see 2) and
   cleaning up a leftover scope go through the facade (`set_scope_properties`,
   `reset_failed`, `stop_scope`: pve-common `b5de93e`, `6f414bb`); without the
   `pve-dbus-vmstate@` service, the helper is started directly in its own
   scope in `qemu.slice`, waiting for its `READY=1` on a notify socket of
   qemu-server's (qemu-server `0806802`).
5. **Storage creates systemd mount and import units:** pve-storage's disk API
   writes `/etc/systemd/system/*.mount` units for directory storages and
   enables them (`src/PVE/API2/Disks/Directory.pm:216-401`), and enables
   `zfs-import@<pool>.service` for new ZFS pools (`src/PVE/API2/Disks/ZFS.pm:513-625`).
   Under LSB these would need `/etc/fstab` entries and ZFS's own import
   mechanism (`zfs-import-cache`/`zfs-import-scan` init scripts) instead.
6. **Fixed: HA shutdown detection reads systemd's job queue:** pve-ha-manager
   decides between shutdown and reboot from `systemctl --full list-jobs`
   (`src/PVE/HA/Env/PVE2.pm:132`). If not booted with systemd, it now uses the
   runlevel the system switches to (0/6), as pve-manager's `pve-guests` init
   script does (pve-ha-manager `a0c7c2c`).

## Repositories

"Calls" counts the files with direct `systemctl`/`journalctl`/`systemd-run`/
`sd_notify`/`PVE::Systemd::` use, excluding tests and upstream sources.

### Need init-system work (units and/or code)

6 repositories left; pve-cluster, pve-ha-manager and qemu-server moved to "Done"
below.

| Repo | Needed packages (required by) | systemd units shipped | Direct systemd use | Work |
|---|---|---|---|---|
| **pve-container** | `pve-container` (pve-manager, pve-ha-manager) | `pve-container@.service`, `pve-container-debug@.service` (templated, one per CT) | `LXC.pm` (start via unit), `LXC/Setup.pm` (`PVE::Systemd::get_timezone`, already a facade wrapper) | **blocker 3** |
| **pve-storage** | `libpve-storage-perl` (most PVE packages) | — | `API2/Disks/Directory.pm`, `API2/Disks/ZFS.pm` (mount/import units) | **blocker 5** (only the disk-management API; using existing storages is unaffected) |
| **pve-firewall** | `pve-firewall` (pve-manager, pve-container, qemu-server, libpve-network-api-perl) | `pve-firewall.service`, `pvefw-logger.service` | `debian/postinst` (deb-systemd-*), `Firewall.pm` (reload pvefw-logger) | profile, 2 init scripts, postinst, facade call |
| **pve-network** | `libpve-network-perl`, `libpve-network-api-perl` (pve-manager, pve-firewall) | drop-in `dnsmasq@.service.d/00-dnsmasq-after-networking.conf` | `SDN/Frr.pm`, `SDN/Dhcp/Dnsmasq.pm` (per-zone `dnsmasq@<zone>` instances), `SDN/Controllers/FaucetPlugin.pm` | facade calls; dnsmasq instances need an init-script equivalent (only with SDN DHCP) |
| **pve-lxc-syscalld** | `pve-lxc-syscalld` (pve-container) | `pve-lxc-syscalld.service` (from `.service.in`, `Type=notify`, `RuntimeDirectory=`) | `src/main.rs`: `sd_notify` | init script creating `/run/pve-lxc-syscalld`; `sd_notify` without `NOTIFY_SOCKET` should be a no-op, to verify |
| **lxc** (lxc-pve) | `lxc-pve` (pve-container) | upstream lxc's `lxc.service`, `lxc-monitord.service`, `lxc-net.service` (installed via `dh_installsystemd` in `debian/rules`) | upstream (submodule, not analysed) | ship upstream lxc's sysvinit scripts (`config/init/sysvinit/`), like Debian's `lxc` package does |

### Done

All on their `feature/init-systems-refactoring` branches; built with their
`pkg.*.lsbservice` profiles, they ship LSB init scripts instead of the systemd
units and don't call `systemctl` directly anymore. None was built as a real
package yet (Proxmox-only build dependencies); the debhelper wiring was checked
with dummy packages, the boot/shutdown order with insserv, and the code paths
on Devuan with OpenRC.

| Repo | Needed packages | Init scripts (replacing units) | systemd use replaced | Commits |
|---|---|---|---|---|
| **pve-cluster** | `pve-cluster`, `libpve-cluster-perl`, `libpve-cluster-api-perl`, `libpve-notify-perl` | `pve-cluster` (pmxcfs; before corosync and cron, stops after corosync) | cluster create/join and service reloads via `PVE::InitSystem`; `pvecm` QDevice commands on remote nodes check for systemd themselves, `service`/`update-rc.d` otherwise | `9bf237a` profile, `176a7e3` init script, `ecbaca1` systemctl, `17590fe` libpve-common-perl (>= 9.2.3) |
| **pve-ha-manager** | `pve-ha-manager` | `watchdog-mux` (backgrounded, output to `/var/log/watchdog-mux.log` with logrotate `copytruncate`, OOM score -1000), `pve-ha-crm`, `pve-ha-lrm` (`PVE_INIT_SCRIPT` marker) | shutdown/reboot detection via runlevel (blocker 6); watchdog-mux falls back to `sync()` without `journalctl --sync`; trigger restarts via `invoke-rc.d` | `36c292f` profile, `bccf1cd` init scripts, `a0c7c2c` systemd tools, `2f870f4` libpve-common-perl (>= 9.2.3), `3431f27` logrotate |
| **qemu-server** | `qemu-server` | `qmeventd` (found by executable, no pid file; stops after pve-ha-lrm/pve-guests), `pve-query-machine-capabilities` (one-shot at boot, also creates `/run/qemu-server`); no `pve-dbus-vmstate@` unit | VM CPU limit/weight via `set_scope_properties`; leftover scope cleanup via `reset_failed`/`stop_scope`; dbus-vmstate helper started directly in its own scope with `Type=notify`-style readiness; units only installed for systemd (`PVE_INIT_SYSTEM`) | `545872a` CPU limit/weight + libpve-common-perl (>= 9.2.3), `17a759e` scope cleanup, `0806802` dbus-vmstate helper, `0fdd2f2` profile + init scripts |

libpve-common-perl was bumped to 9.2.3 on its branch (`b935615`) for these
versioned dependencies; pve-manager depends on it too (`a2253108`). 9.2.3 is a
local version number, an upstream 9.2.3 without these changes would satisfy
the dependencies as well.

### Packaging/UI only, or no init-system dependency

| Repo | Needed packages | Notes |
|---|---|---|
| pve-common | `libpve-common-perl` | done: lsbservice profile, PVE::InitSystem (version 9.2.3 on its branch) |
| proxmox-perl-rs | `libpve-rs-perl`, `libproxmox-rs-perl` | built; links `libsystemd.so.0` (available on Devuan), see proxmox-rs analysis |
| proxmox-acme | `libproxmox-acme-perl`, `libproxmox-acme-plugins` | built; `systemctl` only in acme.sh deploy hooks for third-party services (haproxy, lighttpd, unifi), not used by PVE |
| proxmox-backup | `proxmox-backup-client`, `proxmox-backup-file-restore` (libpve-storage-perl, pve-container) | systemd units and `systemctl`/`journalctl` are only in the **server** part; building the repo builds the server too, unless limited to the client packages |
| proxmox-firewall | `proxmox-firewall-data` (pve-firewall) | data only; the `proxmox-firewall` daemon (unit, `systemctl` in `firewall.rs`) is only recommended |
| ui | `pve-yew-mobile-gui` (pve-manager) | journal view uses the journal API, which returns 501 in the lsbservice variant (same UI follow-up as the web UI) |
| pve-access-control | `libpve-access-control` | — |
| pve-apiclient | `libpve-apiclient-perl` | — |
| pve-guest-common | `libpve-guest-common-perl` | — |
| pve-http-server | `libpve-http-server-perl` | — |
| librados2-perl | `librados2-perl` | `debian/control.in` |
| pve-qemu | `pve-qemu-kvm` (qemu-server, spiceterm) | — |
| pve-edk2-firmware | `pve-edk2-firmware-ovmf`, `pve-edk2-firmware-legacy` (qemu-server) | — |
| proxmox-websocket-tunnel | `proxmox-websocket-tunnel` (qemu-server, libpve-guest-common-perl) | — |
| pve-xtermjs | `pve-xtermjs`, `proxmox-termproxy` | — |
| vncterm, spiceterm | `vncterm`, `spiceterm` | — |
| proxmox-mail-forward | `proxmox-mail-forward` | — |
| proxmox-widget-toolkit | `proxmox-widget-toolkit` | — |
| proxmox-i18n | `pve-i18n`, `pve-yew-mobile-i18n` | — |
| pve-docs | `pve-docs` | — |
| extjs, libjs-qrcodejs, fonts-font-logos, novnc-pve | `libjs-extjs`, `libjs-qrcodejs`, `fonts-font-logos`, `novnc-pve` | web assets; Devuan's versions are missing or too old |
| proxmox-enterprise-support | `proxmox-enterprise-support-keyring` | — |

### Not to build

| Repo | Package | Why |
|---|---|---|
| systemd | `systemd` | Was only pulled in by the hard dependencies of pve-cluster and pve-ha-manager (blocker 1, fixed with their lsbservice profiles). |

### Recommended by pve-manager (optional)

`proxmox-firewall` (daemon with a systemd unit), `proxmox-offline-mirror-helper`,
`pve-nvidia-vgpu-helper`, all Proxmox-only; `skopeo` is in Devuan.

## Suggested order

1. Fix the pve-common regression (2): done, `PVE::Systemd::systemd_call` is restored.
2. Build the 26 repos without init-system work (the "Packaging/UI only" table); pve-common and proxmox-perl-rs are already done.
3. pve-cluster and pve-ha-manager (blocker 1): done, build them with their
   lsbservice profiles.
4. pve-firewall, pve-lxc-syscalld, lxc-pve: services needed at boot.
5. qemu-server (4): done; pve-container (3): running containers.
6. pve-storage (5), pve-network SDN.

## Limitations

- Shallow clones of the current `master` branches; versions in the Proxmox
  repos may be newer than released packages.
- Devuan packages satisfying a dependency were taken as-is; their own
  dependencies weren't checked again (they're Devuan-consistent by
  definition).
- lxc-pve's and pve-qemu's upstream sources (submodules) weren't analysed
  for init-system use; only their packaging was.
- Build dependencies aren't covered.
