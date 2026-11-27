#!/bin/sh
# Debian-Installer late_command: install board packages into /target. Account
# creation, partition confirmation and EFI installation stay with upstream d-i.
set -eu
TARGET=/target
MEDIA=/cdrom
mountpoint -q "$TARGET" || { echo 'target root is not mounted' >&2; exit 1; }
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
in-target apt-get -o Dir::Etc::sourcelist=sources.list.d/qm1-installer-local.list \
    -o Dir::Etc::sourceparts=- update
in-target env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
    -o Dir::Etc::sourcelist=sources.list.d/qm1-installer-local.list \
    -o Dir::Etc::sourceparts=- install qm1-board-support
if [ -s "$MEDIA/qm1/private/authorized_keys" ]; then
    user="$(cat "$MEDIA/qm1/private/ssh_user")"
    home="$(chroot "$TARGET" getent passwd "$user" | cut -d: -f6)"
    case "$home" in /home/*) ;; *) echo 'unexpected target login home' >&2; exit 1 ;; esac
    install -d -m 0700 "$TARGET$home/.ssh"
    install -m 0600 "$MEDIA/qm1/private/authorized_keys" "$TARGET$home/.ssh/authorized_keys"
    in-target chown -R "$user:" "$home/.ssh"
    printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\n' \
        > "$TARGET/etc/ssh/sshd_config.d/qm1-private.conf"
fi
printf 'source=Debian-Installer\n' > "$TARGET/etc/qm1-installation"
echo 'QM1 board support installed through Debian-Installer'
