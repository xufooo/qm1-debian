#!/bin/sh
# Debian-Installer late_command: install board packages into /target. Account
# creation, partition confirmation and EFI installation stay with upstream d-i.
set -eu
TARGET=/target
MEDIA=/cdrom
grep -qs " $TARGET " /proc/mounts || { echo 'target root is not mounted' >&2; exit 1; }
test -f "$MEDIA/qm1/installer-version" || exit 1
mkdir -p "$TARGET/media/qm1-installer"
mount --bind "$MEDIA" "$TARGET/media/qm1-installer"
cleanup() {
    rm -f "$TARGET/etc/apt/sources.list.d/qm1-installer-local.list"
    umount "$TARGET/media/qm1-installer"
}
trap cleanup EXIT
printf 'deb [trusted=yes] file:/media/qm1-installer/qm1/packages ./\n' \
    > "$TARGET/etc/apt/sources.list.d/qm1-installer-local.list"
in-target --pass-stdout apt-get -o Dir::Etc::sourcelist=sources.list.d/qm1-installer-local.list \
    -o Dir::Etc::sourceparts=- update
in-target --pass-stdout env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
    -o Dir::Etc::sourcelist=sources.list.d/qm1-installer-local.list \
    -o Dir::Etc::sourceparts=- install qm1-board-support
printf 'source=Debian-Installer\n' > "$TARGET/etc/qm1-installation"
echo 'QM1 board support installed through Debian-Installer'
