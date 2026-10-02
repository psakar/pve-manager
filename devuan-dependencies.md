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
   closure no longer contains `systemd`. This only makes the packages
   installable; their LSB init scripts and `systemctl` replacements are still
   open (see the table below).
2. **Regression on the pve-common `feature/init-systems-refactoring` branch,
   independent of Devuan:** commit `007a738` ("Extract PVE::InitSystem facade")
   removed `PVE::Systemd::systemd_call`. qemu-server still calls it
   (`src/PVE/QemuServer/CGroup.pm:25`, `set_unit_properties`, used to change a
   running VM's CPU limit/units over D-Bus), which now dies with "Undefined
   subroutine", **under systemd too**. Fix: restore it in `PVE::Systemd` as a
   wrapper around `PVE::InitSystem::Systemd::systemd_call`, and give qemu-server
   a facade-based way to change scope properties.
3. **Containers are started as systemd units:** pve-container runs
   `systemctl start pve-container@<vmid>` (`src/PVE/LXC.pm:3188`). The unit
   runs `lxc-start -F` with `Delegate=yes`, `KillMode=mixed` and stderr
   redirected to `/run/pve/ct-<vmid>.stderr`. Under LSB this needs a
   replacement, e.g. running `lxc-start` daemonized directly, with a cgroup set
   up like the LSBService scopes.
4. **VM processes rely on systemd scopes and units beyond the facade:**
   qemu-server stops `<vmid>.scope` and `pve-dbus-vmstate@<vmid>.service` via
   `systemctl` (`src/PVE/QemuServer.pm:5704-5712`), and starts the D-Bus VM
   state helper as a `Type=notify` unit that is `PartOf=` the VM's scope
   (`src/PVE/QemuServer/DBusVMState.pm:71`). The scope creation itself already
   goes through `PVE::Systemd::enter_systemd_scope` and thus the facade.
5. **Storage creates systemd mount and import units:** pve-storage's disk API
   writes `/etc/systemd/system/*.mount` units for directory storages and
   enables them (`src/PVE/API2/Disks/Directory.pm:216-401`), and enables
   `zfs-import@<pool>.service` for new ZFS pools (`src/PVE/API2/Disks/ZFS.pm:513-625`).
   Under LSB these would need `/etc/fstab` entries and ZFS's own import
   mechanism (`zfs-import-cache`/`zfs-import-scan` init scripts) instead.
6. **HA shutdown detection reads systemd's job queue:** pve-ha-manager decides
   between shutdown and reboot from `systemctl --full list-jobs`
   (`src/PVE/HA/Env/PVE2.pm:132`). Under sysvinit it can use the runlevel (0/6),
   as pve-manager's `pve-guests` init script does.

## Repositories

"Calls" counts the files with direct `systemctl`/`journalctl`/`systemd-run`/
`sd_notify`/`PVE::Systemd::` use, excluding tests and upstream sources.

### Need init-system work (units and/or code)

| Repo | Needed packages (required by) | systemd units shipped | Direct systemd use | Work |
|---|---|---|---|---|
| **pve-cluster** | `pve-cluster`, `libpve-cluster-perl`, `libpve-cluster-api-perl`, `libpve-notify-perl` (most PVE packages) | `pve-cluster.service` (pmxcfs; before corosync and cron, `Conflicts=shutdown.target`) | `pvecm`, `Cluster/Setup.pm`, `API2/ClusterConfig.pm`: `systemctl restart/stop/start corosync pve-cluster` | profile done (blocker 1); init script for pmxcfs, facade calls |
| **pve-ha-manager** | `pve-ha-manager` (pve-manager, pve-container, qemu-server) | `pve-ha-crm.service`, `pve-ha-lrm.service`, `watchdog-mux.service` | `Env/PVE2.pm` (`list-jobs`, see 6) | profile done (blocker 1); 3 init scripts, shutdown detection |
| **pve-container** | `pve-container` (pve-manager, pve-ha-manager) | `pve-container@.service`, `pve-container-debug@.service` (templated, one per CT) | `LXC.pm` (start via unit), `LXC/Setup.pm` (`PVE::Systemd::get_timezone`, already a facade wrapper) | **blocker 3** |
| **qemu-server** | `qemu-server` (pve-manager, pve-ha-manager) | `qmeventd.service`, `pve-query-machine-capabilities.service`, `pve-dbus-vmstate@.service` | `QemuServer.pm`, `CGroup.pm`, `DBusVMState.pm`, `CPUConfig.pm` | **regression 2**, **blocker 4**; init script for qmeventd, one-shot for machine capabilities |
| **pve-storage** | `libpve-storage-perl` (most PVE packages) | — | `API2/Disks/Directory.pm`, `API2/Disks/ZFS.pm` (mount/import units) | **blocker 5** (only the disk-management API; using existing storages is unaffected) |
| **pve-firewall** | `pve-firewall` (pve-manager, pve-container, qemu-server, libpve-network-api-perl) | `pve-firewall.service`, `pvefw-logger.service` | `debian/postinst` (deb-systemd-*), `Firewall.pm` (reload pvefw-logger) | profile, 2 init scripts, postinst, facade call |
| **pve-network** | `libpve-network-perl`, `libpve-network-api-perl` (pve-manager, pve-firewall) | drop-in `dnsmasq@.service.d/00-dnsmasq-after-networking.conf` | `SDN/Frr.pm`, `SDN/Dhcp/Dnsmasq.pm` (per-zone `dnsmasq@<zone>` instances), `SDN/Controllers/FaucetPlugin.pm` | facade calls; dnsmasq instances need an init-script equivalent (only with SDN DHCP) |
| **pve-lxc-syscalld** | `pve-lxc-syscalld` (pve-container) | `pve-lxc-syscalld.service` (from `.service.in`, `Type=notify`, `RuntimeDirectory=`) | `src/main.rs`: `sd_notify` | init script creating `/run/pve-lxc-syscalld`; `sd_notify` without `NOTIFY_SOCKET` should be a no-op, to verify |
| **lxc** (lxc-pve) | `lxc-pve` (pve-container) | upstream lxc's `lxc.service`, `lxc-monitord.service`, `lxc-net.service` (installed via `dh_installsystemd` in `debian/rules`) | upstream (submodule, not analysed) | ship upstream lxc's sysvinit scripts (`config/init/sysvinit/`), like Debian's `lxc` package does |

### Packaging/UI only, or no init-system dependency

| Repo | Needed packages | Notes |
|---|---|---|
| pve-common | `libpve-common-perl` | done: lsbservice profile (this branch) |
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

1. Fix the pve-common regression (2): restore `PVE::Systemd::systemd_call`.
2. Build the 26 repos without init-system work, all of them but the 9 in the first table; pve-common and proxmox-perl-rs are already done.
3. pve-cluster and pve-ha-manager: build them with their lsbservice profiles
   (blocker 1, done), then add their init scripts; without them nothing
   installs or starts.
4. pve-firewall, pve-lxc-syscalld, lxc-pve: services needed at boot.
5. qemu-server (4) and pve-container (3): running guests.
6. pve-storage (5), pve-network SDN, pve-ha-manager shutdown detection (6).

## Limitations

- Shallow clones of the current `master` branches; versions in the Proxmox
  repos may be newer than released packages.
- Devuan packages satisfying a dependency were taken as-is; their own
  dependencies weren't checked again (they're Devuan-consistent by
  definition).
- lxc-pve's and pve-qemu's upstream sources (submodules) weren't analysed
  for init-system use; only their packaging was.
- Build dependencies aren't covered.
