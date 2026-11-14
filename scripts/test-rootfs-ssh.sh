#!/usr/bin/env bash
# CI-only real key login and sudo authentication inside a disposable rootfs.
set -euo pipefail
ROOT="$(cd "${1:?usage: test-rootfs-ssh.sh ROOTFS}" && pwd)"
if [ "${2:-}" != --mount-namespace ]; then
    exec unshare --mount --propagation private "$BASH" "$0" "$ROOT" --mount-namespace
fi
[ "$(id -u)" = 0 ] || { echo 'requires root' >&2; exit 1; }
WORK="$(mktemp -d)"
TARGET="$WORK/root"
SSHD_PID=""
proc_mounted=0
pts_mounted=0
cleanup() {
    if [ -n "$SSHD_PID" ]; then
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
    fi
    if [ "$pts_mounted" = 1 ]; then umount "$TARGET/dev/pts" || return 1; fi
    if [ "$proc_mounted" = 1 ]; then umount "$TARGET/proc" || return 1; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir "$TARGET"
cp -a --reflink=auto "$ROOT/." "$TARGET/"
mkdir -p "$TARGET"/{proc,dev/pts,run/sshd,tmp/qm1-bootstrap,etc/qm1/provision}
for pair in null:3 zero:5 random:8 urandom:9; do
    mknod -m 666 "$TARGET/dev/${pair%%:*}" c 1 "${pair#*:}"
done
mount -t proc -o nosuid,nodev,noexec proc "$TARGET/proc"
proc_mounted=1
mount -t devpts -o newinstance,ptmxmode=0666,mode=0620,gid=5 devpts "$TARGET/dev/pts"
pts_mounted=1
ln -s pts/ptmx "$TARGET/dev/ptmx"
ln -s /proc/self/fd "$TARGET/dev/fd"
chroot "$TARGET" ssh-keygen -q -t ed25519 -N '' -f /tmp/qm1-bootstrap/client
cp "$TARGET/tmp/qm1-bootstrap/client.pub" "$TARGET/etc/qm1/provision/authorized_keys"
printf 'qm1\n' > "$TARGET/etc/qm1/provision/ssh_user"
: > "$TARGET/etc/qm1/provision/ssh"
# Public CI fixture only; never put this configuration into the build root.
FIXTURE_PASSWORD='qm1-ci-bootstrap-fixture'
printf '%s\n' "$FIXTURE_PASSWORD" | chroot "$TARGET" openssl passwd -6 -stdin \
    > "$TARGET/etc/qm1/provision/ssh_password_hash"
chroot "$TARGET" /usr/local/sbin/qm1-firstboot --force
chroot "$TARGET" ssh-keygen -q -t ed25519 -N '' -f /tmp/qm1-bootstrap/host
PORT=22279
chroot "$TARGET" /usr/sbin/sshd -D -e -p "$PORT" \
    -o ListenAddress=127.0.0.1 -o HostKey=/tmp/qm1-bootstrap/host \
    -o PidFile=/run/qm1-bootstrap.pid > "$WORK/sshd.log" 2>&1 &
SSHD_PID=$!
ssh_command=(chroot "$TARGET" ssh -F /dev/null -T -p "$PORT"
    -i /tmp/qm1-bootstrap/client -o BatchMode=yes -o ConnectTimeout=2
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/qm1-bootstrap/known_hosts
    qm1@127.0.0.1)
ready=0
for ((attempt=0; attempt<20; attempt++)); do
    if "${ssh_command[@]}" 'id -un' > "$WORK/login" 2> "$WORK/client.log"; then
        ready=1; break
    fi
    kill -0 "$SSHD_PID" 2>/dev/null || break
    sleep 1
done
if [ "$ready" != 1 ]; then
    cat "$WORK/sshd.log" "$WORK/client.log" >&2
    echo 'FAIL private key could not log into the built rootfs'; exit 1
fi
grep -qx qm1 "$WORK/login"
printf '%s\n' "$FIXTURE_PASSWORD" | "${ssh_command[@]}" 'sudo -S -p "" id -u' > "$WORK/sudo"
grep -qx 0 "$WORK/sudo"
# Prove that test keys and password did not escape the disposable copy.
[ ! -e "$ROOT/etc/qm1/provision/authorized_keys" ]
[ ! -e "$ROOT/etc/qm1/provision/ssh_password_hash" ]
echo 'PASS real SSH public-key login and password-authenticated sudo in isolated rootfs; production tree untouched'
