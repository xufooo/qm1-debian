#!/usr/bin/env bash
# Verify real unit files in the target tree, rather than relying on units
# that the analyzer happened to cache while traversing another dependency.
set -euo pipefail
ROOT="$(cd "${1:?usage: verify-systemd-units.sh ROOTFS}" && pwd)"
units=(
    /etc/systemd/system/qm1-ssh-hostkeys.service
    /usr/lib/systemd/system/ssh.service
    /etc/systemd/system/qm1-firstboot.service
    /etc/systemd/system/qm1-bluetooth.service
    /etc/systemd/system/qm1-hardware-fixups.service
    /etc/systemd/system/qm1-selftest.service
    /etc/systemd/system/qm1-selftest.timer
    /etc/systemd/system/qm1-health-collect.service
    /etc/systemd/system/qm1-health-collect.timer
)
for unit in "${units[@]}" /etc/systemd/system/qm1-wifi@.service \
            /usr/lib/systemd/system/user@.service; do
    [ -f "$ROOT$unit" ] || { echo "missing unit: $unit" >&2; exit 1; }
done

# The packaged tree deliberately has an empty /dev. Mask resolution still
# needs /dev/null while checking it; remove only the node we create here.
created_null=0
cleanup() { if [ "$created_null" = 1 ]; then rm -f "$ROOT/dev/null"; fi; }
trap cleanup EXIT
if [ ! -e "$ROOT/dev/null" ] && [ ! -L "$ROOT/dev/null" ]; then
    mknod -m 666 "$ROOT/dev/null" c 1 3
    created_null=1
fi

chroot "$ROOT" systemd-analyze --man=no verify "${units[@]}"
# These templates need different instances. The file argument is the
# existing template, not an instance filename that does not exist.
chroot "$ROOT" systemd-analyze --man=no --instance=wlan0 verify \
    /etc/systemd/system/qm1-wifi@.service
chroot "$ROOT" systemd-analyze --man=no --instance=1000 verify \
    /usr/lib/systemd/system/user@.service
