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
3. **Fixed: containers are started as systemd units:** pve-container ran
   `systemctl start pve-container@<vmid>` (`src/PVE/LXC.pm:3188`), whose unit
   runs `lxc-start -F` with stderr in `/run/pve/ct-<vmid>.stderr`, and whose
   stop wrapper restarts a container rebooted from within. Without those
   services, `pve-container-supervise` now does the same (pve-container
   `3697063`).
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
5. **Fixed: storage creates systemd mount and import units:** pve-storage's
   disk API wrote `/etc/systemd/system/*.mount` units for directory storages
   (`src/PVE/API2/Disks/Directory.pm`) and enabled `zfs-import@<pool>.service`
   for new ZFS pools (`src/PVE/API2/Disks/ZFS.pm`). Mounts now go through
   pve-common's new `PVE::InitSystem` mount functions, which keep writing the
   same mount units with systemd and use `/etc/fstab` entries otherwise
   (pve-common `86e4060`, pve-storage `c9556f4`); the ZFS import units are only
   touched if the init system has them (pve-storage `0a98c48`).
6. **Fixed: HA shutdown detection reads systemd's job queue:** pve-ha-manager
   decides between shutdown and reboot from `systemctl --full list-jobs`
   (`src/PVE/HA/Env/PVE2.pm:132`). If not booted with systemd, it now uses the
   runlevel the system switches to (0/6), as pve-manager's `pve-guests` init
   script does (pve-ha-manager `a0c7c2c`).

## Repositories

"Calls" counts the files with direct `systemctl`/`journalctl`/`systemd-run`/
`sd_notify`/`PVE::Systemd::` use, excluding tests and upstream sources.

### Need init-system work (units and/or code)

None left: all 9 repositories that needed it are in "Done" below. See
"Remaining gaps" for what's still open beyond them.

### Done

All on their `feature/init-systems-refactoring` branches; built with their
`pkg.*.lsbservice` profiles, they ship LSB init scripts instead of the systemd
units (where they have any), don't call `systemctl` directly anymore, and pass
lintian in both variants. None was built as a real package yet (Proxmox-only
build dependencies); the debhelper wiring and lintian were checked with
packages built from their real debian/rules, init scripts and maintainer
scripts, the boot/shutdown order of all init scripts together with insserv,
and the code paths on Devuan with OpenRC.

| Repo | Needed packages | Init scripts (replacing units) | systemd use replaced | Commits |
|---|---|---|---|---|
| **pve-cluster** | `pve-cluster`, `libpve-cluster-perl`, `libpve-cluster-api-perl`, `libpve-notify-perl` | `pve-cluster` (pmxcfs; before corosync and cron, stops after corosync) | cluster create/join and service reloads via `PVE::InitSystem`; `pvecm` QDevice commands on remote nodes check for systemd themselves, `service`/`update-rc.d` otherwise | `9bf237a` profile, `176a7e3` init script, `ecbaca1` systemctl, `17590fe` libpve-common-perl (>= 9.2.3) |
| **pve-ha-manager** | `pve-ha-manager` | `watchdog-mux` (backgrounded, output to `/var/log/watchdog-mux.log` with logrotate `copytruncate`, OOM score -1000), `pve-ha-crm`, `pve-ha-lrm` (`PVE_INIT_SCRIPT` marker) | shutdown/reboot detection via runlevel (blocker 6); watchdog-mux falls back to `sync()` without `journalctl --sync`; trigger restarts via `invoke-rc.d` | `36c292f` profile, `bccf1cd` init scripts, `a0c7c2c` systemd tools, `2f870f4` libpve-common-perl (>= 9.2.3), `3431f27` logrotate |
| **qemu-server** | `qemu-server` | `qmeventd` (found by executable, no pid file; stops after pve-ha-lrm/pve-guests), `pve-query-machine-capabilities` (one-shot at boot, also creates `/run/qemu-server`); no `pve-dbus-vmstate@` unit | VM CPU limit/weight via `set_scope_properties`; leftover scope cleanup via `reset_failed`/`stop_scope`; dbus-vmstate helper started directly in its own scope with `Type=notify`-style readiness; units only installed for systemd (`PVE_INIT_SYSTEM`) | `545872a` CPU limit/weight + libpve-common-perl (>= 9.2.3), `17a759e` scope cleanup, `0806802` dbus-vmstate helper, `0fdd2f2` profile + init scripts |
| **pve-container** | `pve-container` | none needed; no pve-container@ units | containers started by `pve-container-supervise` (detached `lxc-start -F`, stderr to `/run/pve/ct-<vmid>.stderr`, restart on reboot from within) where there's no pve-container@ service | `3697063` supervisor + libpve-common-perl (>= 9.2.3), `ba78f1a` profile |
| **pve-storage** | `libpve-storage-perl` | none | directory storage mounts via `PVE::InitSystem` (mount units or `/etc/fstab`), CephFS via `mount_runtime`; `zfs-import@` only if the init system has it; ESXi FUSE scope stopped via `stop_scope` | `c9556f4` mounts + libpve-common-perl (>= 9.2.3), `0a98c48` ZFS, `9704bf9` ESXi |
| **pve-firewall** | `pve-firewall` | `pve-firewall` (`PVE_INIT_SCRIPT` marker, legacy iptables alternatives, honors `START_FIREWALL`), `pvefw-logger` | pvefw-logger reload via `try_reload_or_restart_service`; postinst reload on upgrades via invoke-rc.d | `a9faa3d` facade + libpve-common-perl (>= 9.2.3), `f3fdc85` profile + init scripts, `da5c317` lintian |
| **pve-network** | `libpve-network-perl`, `libpve-network-api-perl` | none; no dnsmasq@ drop-in | frr and faucet via `PVE::InitSystem` (frrinit.sh directly if there's no frr service); per-zone `dnsmasq@<zone>` instances via `PVE::InitSystem`, run by Debian's dnsmasq init script with the zone as instance argument, enabled ones started at boot by pve-common's `pve-service-instances` | `6d8fc74` frr/faucet + libpve-common-perl (>= 9.2.3), `71f11d3` dnsmasq, `aae4068` profile |
| **pve-lxc-syscalld** | `pve-lxc-syscalld` | `pve-lxc-syscalld` (generated from `.init.in` like the unit; returns once the socket listens, creates/removes `/run/pve-lxc-syscalld`) | none needed: `sd_notify` without `NOTIFY_SOCKET` is a no-op | `845e751` profile + init script |
| **lxc** (lxc-pve) | `lxc-pve` | `lxc` (also loads the AppArmor profiles, unlike upstream's sysvinit script), `lxc-net`, `lxc-monitord` (backgrounded) | none (helpers in `/usr/libexec/lxc` as with systemd) | `c597683` profile + init scripts |

libpve-common-perl was bumped to 9.2.3 on its branch (`b935615`) for these
versioned dependencies; pve-manager depends on it too (`a2253108`). 9.2.3 is a
local version number, an upstream 9.2.3 without these changes would satisfy
the dependencies as well. Its `PVE::InitSystem` gained, along the way: scope
placement in the requested slice (`cfababb`), `set_scope_properties`
(`b5de93e`), `stop_scope`/`reset_failed` (`6f414bb`), mount management
(`86e4060`), template service instances with the `pve-service-instances`
boot script (`683877a`), and a `force-reload` fallback for init scripts
without `reload` (`99f9770`).

Follow-ups in repositories done earlier: lintian overrides for the init
scripts without units, as lintian errors would fail the lsbservice builds,
plus the `${misc:Pre-Depends}` substvar where it was missing (pve-cluster
`fa1d281`, pve-ha-manager `70fb528`, qemu-server `ec58e7d`, pve-manager
`970115ef`), and exiting with the helpers' status in one-shot init scripts
(pve-manager `a711b25c`, qemu-server `15bd67d`).

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

## Remaining gaps

- **FRR at boot:** Debian's (and Devuan's) `frr` package ships only systemd
  units, not their `frrinit.sh` as an init script. Without systemd, pve-network
  restarts FRR via `frrinit.sh` directly and warns, but nothing starts FRR at
  boot. That's for the `frr` packaging (Proxmox ships its own frr build).
- **Journal views:** the web UI's and mobile UI's journal views need the
  journal API, which returns 501 without systemd; they should fall back to the
  syslog API.
- **Ceph:** Ceph's packages only ship systemd units; pve-manager's Ceph
  management still uses `systemctl`.
- **Upstream LXC lock collision:** `/usr/libexec/lxc/lxc-containers` uses
  `/var/lock/lxc` as lock file if `/var/lock/subsys` doesn't exist, which
  fails if liblxc already created a directory of that name. That's upstream
  behavior, `lxc.service` runs the same helper; at boot the directory doesn't
  exist yet.
- **Not built for real yet:** the lsbservice variants of all these packages
  still need to be built for real, in dependency order, and tested together
  on a Devuan VM (VM and container start/stop/reboot, HA, SDN with DHCP,
  directory storage creation).
- **No automatic restart:** none of the init scripts restarts a crashed
  daemon, which `Restart=on-failure` units do (could use OpenRC's
  supervise-daemon).

## Limitations

- Shallow clones of the current `master` branches; versions in the Proxmox
  repos may be newer than released packages.
- Devuan packages satisfying a dependency were taken as-is; their own
  dependencies weren't checked again (they're Devuan-consistent by
  definition).
- lxc-pve's and pve-qemu's upstream sources (submodules) weren't analysed
  for init-system use; only their packaging was.
- Build dependencies aren't covered.
