#!/bin/sh
# Fail if Perl code talks to the init system directly instead of going through
# pve-common's PVE::InitSystem, which keeps pve-manager working with both its
# systemd and its LSBService backend (see init-system-rework.md).
#
# Not yet converted, see "What can be left out for now" in init-system-rework.md:
# - Ceph management, as Ceph itself only ships systemd units
# - pve8to9, which only checks PVE 8 to 9 upgrades
# Intended uses:
# - the journal API endpoint, which is systemd-only by nature and refuses to
#   work without mini-journalreader
# - APT.pm's list of packages to report versions for
set -eu

cd "$(dirname "$0")/.."

ALLOWED='^(PVE/Ceph/|PVE/API2/Ceph/|bin/pve-cephx-rotate-service-keys|PVE/CLI/pve8to9\.pm|PVE/API2/Nodes\.pm:.*mini-journalreader|PVE/API2/APT\.pm:.*proxmox-mini-journalreader)'

found=$(grep -rnE "systemctl|journalctl|mini-journalreader|PVE::Systemd::(get|set)_timezone|PVE::Tools::dump_journal" PVE bin \
    | grep -vE "$ALLOWED" || true)

if [ -n "$found" ]; then
    echo "direct init-system calls found, use PVE::InitSystem instead:" >&2
    echo "$found" >&2
    exit 1
fi

echo "no direct init-system calls found"
