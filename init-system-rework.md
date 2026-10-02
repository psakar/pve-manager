# Plan: init-system support for pve-manager

Goal: let pve-manager be built, installed and run on Devuan (sysvinit +
OpenRC), reusing the `PVE::InitSystem` facade and build-profile approach from
pve-common (branch `feature/init-systems-refactoring`). Findings this plan is
based on are in `systemd-usage-analysis.md`.

## Design (mirrors pve-common)

| pve-common | pve-manager equivalent |
|---|---|
| `PVE::InitSystem` facade, backends `Systemd` / `LSBService` | **Reuse it.** pve-manager gets no backend modules of its own; all service and journal operations go through `PVE::InitSystem`, which gets extended in pve-common (step 1). |
| Build profile `pkg.pve-common.lsbservice` → `PVE_INIT_SYSTEM=lsbservice` | Build profile **`pkg.pve-manager.lsbservice`** in `debian/control` / `debian/rules`. It only affects **packaging** (what gets installed, dependencies, maintainer scripts), since the Perl code is backend-agnostic through the facade. |
| `libnet-dbus-perl <!pkg.pve-common.lsbservice>` | `systemd <!pkg.pve-manager.lsbservice>`, `proxmox-mini-journalreader <!pkg.pve-manager.lsbservice>` |
| "Callers must not reference a backend module directly" | pve-manager must not call `systemctl`, `journalctl`, `mini-journalreader` or `deb-systemd-*` directly. Enforce this with a grep check in `make check` (step 4). |

The profile names stay per source package, as in pve-common. A Devuan build
then uses `-Ppkg.pve-common.lsbservice` for pve-common and
`-Ppkg.pve-manager.lsbservice` for pve-manager.

## Steps

### Step 1: extend `PVE::InitSystem` (in pve-common)

Add to the fixed `@interface` in `src/PVE/InitSystem.pm`, implemented in both
backends:

| New function | Systemd backend | LSBService backend |
|---|---|---|
| `service_status($name)` → `{desc, state, active_state, unit_state}` | `systemctl show` (move the parser from `PVE/API2/Services.pm`) | `service <name> status` exit code (LSB: 0 running, 3 stopped, 4 unknown); description from the `Short-Description:` LSB header; enabled = `S??<name>` link in `/etc/rc[2-5].d` or OpenRC runlevel membership |
| `reload_service($name)` | `systemctl reload` | `service <name> reload` |
| `try_reload_or_restart_service($name)` | `systemctl try-reload-or-restart` | only if running: reload, falling back to restart |
| `enable_service($name, %opts)` / `disable_service($name, %opts)` (`runtime => 1`) | `systemctl enable/disable [--runtime]` | `update-rc.d <name> enable/disable` (Devuan's `update-rc.d` also drives OpenRC). `runtime` isn't supported, so treat it as persistent or die. |
| `service_main_pid($name)` | `systemctl show -p MainPID` | pidfile from the init script / `/run/<name>.pid`, or `pidof` |
| `dump_syslog($start, $limit, $since, $until, $service)` | move `PVE::Tools::dump_journal` here unchanged (`journalctl`) | read `/var/log/syslog*` (rsyslog), filter by time and by the program tag for `$service` |
| `service_alias($name)` | `sshd → ssh`, `postfix → postfix@-` | identity, or `sshd → ssh` |

- Keep `PVE::Tools::dump_journal` as a thin wrapper around
  `PVE::InitSystem::dump_syslog` for API compatibility, as was done for
  `PVE::Systemd`.
- Add unit tests per backend (mocked `run_command`) and extend the OpenRC
  runtime test with `service_status`/`enable`/`disable` for a throwaway
  service.

### Step 2: build profile and dependencies (`debian/control`, `debian/rules`)

- `debian/control`:
  - `systemd <!pkg.pve-manager.lsbservice>`
  - `proxmox-mini-journalreader (>= 1.7) <!pkg.pve-manager.lsbservice>`
  - for the lsbservice variant: `rsyslog | system-log-daemon`, `cron`, and
    `systemd-standalone-tmpfiles` (or create `/run/pve` from an init script,
    see step 3)
  - a versioned dependency on a `libpve-common-perl` that has the step 1
    functions
- `debian/rules`: `ifneq (,$(filter pkg.pve-manager.lsbservice,$(DEB_BUILD_PROFILES)))`
  → export `PVE_INIT_SYSTEM=lsbservice` to `make install`, with the same
  documentation comment as pve-common's `debian/rules`.
- `defines.mk` / `services/Makefile`: install `services/*.service` only for
  `systemd`, and LSB scripts (step 3) only for `lsbservice`.

### Step 3: LSB init scripts and cron job (`services/init.d/`, `configs/`)

One `/etc/init.d` script per unit, using `/lib/lsb/init-functions`. The
dependency-ordering headers mirror the units (see the unit inventory in the
analysis):

| Script | Required-Start | Should-Start | X-Start-Before | Default-Start | Body |
|---|---|---|---|---|---|
| `pvenetcommit` | `$local_fs` | | `networking` | `S` | the `mv interfaces.new` + `rm conf.db` logic |
| `pvebanner` | `$local_fs` | | | `2 3 4 5` | `pvebanner` |
| `pvedaemon` | `$remote_fs $network $syslog pve-cluster` | `corosync` | | `2 3 4 5` | `pvedaemon start/stop/restart`, `status` via the pidfile |
| `pveproxy` | `$remote_fs $network pve-cluster pvedaemon` | `ssh open-iscsi glusterd ceph` | | `2 3 4 5` | `pvecm updatecerts --silent` before start, then `pveproxy start…`, then `pveupdate` if `/var/log/pveam.log` is missing |
| `spiceproxy` | `pveproxy` | | | `2 3 4 5` | |
| `pvestatd` | `pve-cluster pvenetcommit` | | | `2 3 4 5` | |
| `pve-guests` | `pveproxy pvestatd spiceproxy` | `pve-firewall lxc pve-ha-crm pve-ha-lrm` | | `2 3 4 5` | start: `pve-startall-delay`; `pvesh --nooutput create /nodes/localhost/startall`; stop: `vzdump -stop`; `pvesh … stopall` |
| `pvescheduler` | `pve-cluster pve-guests` | `$remote_fs` | | `2 3 4 5` | |
| `pve-sdn-commit` | `pve-cluster $network` | `frr corosync` | | `2 3 4 5` | |
| `pve-firewall-commit` | `pve-cluster` | `corosync` | | `2 3 4 5` | |

- Mount points provided by `pve-storage.target` are folded into the
  `Should-Start` lines above (`$remote_fs open-iscsi glusterd ceph`).
- `/run/pve`: create it in the `pvedaemon` script's start (`install -d -m 0750
  -o root -g www-data /run/pve`), or depend on `systemd-standalone-tmpfiles`
  and run it from an early boot script.
- The daily update replaces `pve-daily-update.timer` with
  `/etc/cron.d/pve-daily-update`: `0 1 * * * root sleep $(shuf -i 0-18000 -n 1); /usr/bin/pveupdate`.
  Name it differently from the legacy `/etc/cron.d/pveupdate` that `postrm`
  removes.
- `configs/pve.logrotate`: install a variant for the lsbservice build that
  uses `invoke-rc.d pveproxy reload` / `invoke-rc.d spiceproxy reload`.
- `debian/lintian-overrides`: make the `pvebanner.service` override
  systemd-only. Expect new lintian tags for init scripts and add overrides as
  needed.

### Step 4: replace direct `systemctl` / journal calls in Perl code

| File | Change |
|---|---|
| `PVE/API2/Services.pm` | `$get_full_service_state` → `PVE::InitSystem::service_status`; `$service_cmd` → `start/stop/restart/reload/try_reload_or_restart_service`. Build the service list per backend (drop `systemd-journald`/`systemd-timesyncd`, add `rsyslog`; keep listing only services that exist, which the code already does via `Description`). |
| `PVE/API2/Certificates.pm`, `PVE/API2/ACME.pm`, `bin/pveupdate` | `systemctl reload-or-restart pveproxy` → `PVE::InitSystem::restart_service('pveproxy', 1)` |
| `PVE/CLI/pveceph.pm:310` | → `try_reload_or_restart_service` for both daemons |
| `PVE/API2/Nodes.pm` (`syslog`) | `PVE::Tools::dump_journal` → `PVE::InitSystem::dump_syslog`, with aliases via `service_alias` |
| `PVE/API2/Nodes.pm` (`journal`) | Under lsbservice, return a clear "not supported, use syslog" error (HTTP 501), or serve syslog lines in the same JSON shape; the GUI journal view needs to handle that (`www/manager6/node/Config.js`). |
| `PVE/API2/Nodes.pm` (timezone) | `PVE::Systemd::get/set_timezone` → `PVE::InitSystem::*` (cosmetic, it already works) |
| `Makefile` / `test/` | Add a check that fails if `git grep -nE "systemctl|journalctl|mini-journalreader"` finds anything in `PVE/` or `bin/` outside an allow-list (Ceph until step 7, pve8to9). |

### Step 5: maintainer scripts (`debian/postinst`)

- Wrap the systemd-only blocks (`deb-systemd-helper` enable loop,
  `daemon-reload`, `deb-systemd-invoke` start/reload) so they're generated
  only for the systemd variant. Either let debhelper do it (`dh_installinit`
  for `debian/*.init`, `dh_installsystemd` for units; it then emits the right
  `#DEBHELPER#` snippets per profile), or branch at runtime on
  `[ -d /run/systemd/system ]` and use `invoke-rc.d`/`update-rc.d` otherwise.
  Prefer debhelper. The hand-written code in postinst is already "copied
  from dh_systemd_*".
- The `triggered` (`pve-api-updates`) branch: `invoke-rc.d <svc> reload` for
  pvedaemon, pvestatd, pveproxy, spiceproxy and pvescheduler, so API updates
  are actually picked up.
- `update_ceph_conf`: skip the `ceph-crash.service` restart under
  lsbservice.

### Step 6: network interface pinning under eudev

- `pve-network-interface-pinning`: under lsbservice, write udev rules
  (`/etc/udev/rules.d/50-pve-<iface>.rules`,
  `SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="…", NAME="…"`) instead
  of `.link` files. Teach `virtual-function-pinning-helper` about that
  location.
- `proxmox-ve-default.link` (`MACAddressPolicy=none`): check whether eudev
  needs an equivalent at all. eudev doesn't assign persistent random MACs to
  bridges, so it's likely not needed. Don't install it in the lsbservice
  variant.

### Step 7: Ceph

- Extend the facade with template-instance and "target" handling
  (`enable_service('ceph-mon@ID')`, list enabled instances), or add a
  dedicated `PVE::Ceph::Services` backend switch.
- This depends on Ceph itself having non-systemd service management on Devuan
  (`/etc/init.d/ceph` was dropped upstream), so it's effectively a Ceph
  packaging project.
- `pve-cephx-rotate-service-keys` runs `systemctl` on remote nodes, so it
  needs per-node init-system detection.

### Step 8: supervision (optional)

- Make OpenRC-native scripts (`#!/sbin/openrc-run` with
  `supervisor=supervise-daemon`) for pvedaemon and pveproxy, to get back the
  automatic restart that `Restart=on-failure` provides. This needs a
  foreground mode in `PVE::Daemon` that doesn't also turn on debug output,
  which is a pve-common change.

### Step 9: tests

- Build both variants: `dpkg-buildpackage -b` and
  `dpkg-buildpackage -b -Ppkg.pve-manager.lsbservice`. lintian must pass for
  both.
- Runtime on a Devuan VM:
  - boot and check the start order (pvenetcommit before networking, all
    daemons up)
  - reboot with a running guest (pve-guests stopall/startall)
  - `pvesh get /nodes/<node>/services`, then start/stop/restart via the API
  - upload a certificate or run an ACME renewal, and check pveproxy picks
    it up
  - check the syslog API returns data
  - check the cron job runs `pveupdate`

## What can be left out for now

| Step | Defer? | Reason |
|---|---|---|
| 1 (except `dump_syslog`) | **do now** | Everything in pve-manager builds on it, and it's mostly moving existing code into the facade. |
| 2 | **do now** | `Depends: systemd` is an install blocker. |
| 3 (daemons, pve-guests, pvenetcommit, `/run/pve`) | **do now** | Without these nothing starts at boot. |
| 3 (pvebanner, pve-sdn-commit, pve-firewall-commit) | early, but lower priority | Cosmetic (banner) or only needed with SDN/firewall configured. |
| 3 (cron replacement for daily update) | early | Small. Without it there are no subscription/apt/appliance-index updates. |
| 4: Services API, cert/ACME reload, logrotate | **do now** | Otherwise the new certificate isn't loaded and logrotate breaks pveproxy logging. |
| 4: syslog API (`dump_syslog`) | soon | Only affects the GUI log views. |
| 4: journal API | defer | Return "not supported" under lsbservice and let the GUI use syslog. A real implementation isn't worth it. |
| 5 | **do now** | Otherwise upgrades silently keep running old code. |
| 6 | defer | Only needed when NIC name pinning is used. |
| 7: Ceph | defer, probably indefinitely | Blocked on Ceph having non-systemd service management on Devuan. Mark Ceph as unsupported in the lsbservice variant (e.g. hide or reject `pveceph install`). |
| 8 | defer | Quality of life. sysvinit has never had automatic restarts either. |
| `pve8to9` | skip | Only for PVE 8 → 9 upgrades. Not relevant to a Devuan port. |
| 9 | together with each step | |

Minimum to have an installable, bootable PVE node UI on Devuan from
pve-manager's side: steps 1 (without `dump_syslog`), 2, 3 (core scripts), 4
(Services, cert reload, logrotate), 5 and 9. It also needs the
other-package init scripts listed under "Dependencies outside pve-manager" in
the analysis (pve-cluster, pve-firewall, pve-ha-manager, qemu-server,
pve-container, lxc), each following the same pattern as this plan.
