#!/usr/bin/env bash
# Model verify's FILE contract: reject bare unit names or invented instance
# paths, even when some other dependency might previously have cached them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/root/dev" "$WORK/root/etc/systemd/system" \
         "$WORK/root/usr/lib/systemd/system"
for unit in qm1-ssh-hostkeys.service qm1-firstboot.service qm1-bluetooth.service \
            qm1-hardware-fixups.service qm1-selftest.service qm1-selftest.timer \
            qm1-health-collect.service qm1-health-collect.timer qm1-wifi@.service; do
    : > "$WORK/root/etc/systemd/system/$unit"
done
: > "$WORK/root/usr/lib/systemd/system/ssh.service"
: > "$WORK/root/usr/lib/systemd/system/user@.service"
cat > "$WORK/bin/mknod" <<'SH'
#!/bin/sh
# Parser fixture only: no actual device creation or access.
touch "$3"
SH
cat > "$WORK/bin/chroot" <<'SH'
#!/bin/sh
root=$1
shift
[ "$1" = systemd-analyze ] || exit 10
shift
instance=""
for arg in "$@"; do
    case "$arg" in
        --instance=*) instance=${arg#*=} ;;
        --man=no|verify) ;;
        /*)
            [ -f "$root$arg" ] || exit 11
            case "$arg" in
                *qm1-wifi@.service) [ "$instance" = wlan0 ] || exit 12 ;;
                *user@.service) [ "$instance" = 1000 ] || exit 13 ;;
            esac ;;
        *) exit 14 ;;
    esac
done
if [ "${FIXTURE_VERIFY_FAIL:-0}" = 1 ]; then exit 7; fi
SH
chmod +x "$WORK/bin/mknod" "$WORK/bin/chroot"
PATH="$WORK/bin:$PATH" bash "$SCRIPT_DIR/verify-systemd-units.sh" "$WORK/root"
[ ! -e "$WORK/root/dev/null" ]
if PATH="$WORK/bin:$PATH" FIXTURE_VERIFY_FAIL=1 \
    bash "$SCRIPT_DIR/verify-systemd-units.sh" "$WORK/root"; then
    echo 'FAIL verifier hid a unit verification error'; exit 1
fi
[ ! -e "$WORK/root/dev/null" ]
echo 'PASS real unit paths, distinct template instances, failure propagation and device cleanup'
