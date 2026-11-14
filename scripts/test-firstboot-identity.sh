#!/usr/bin/env bash
# Execute firstboot against isolated paths; verify access as a different UID.
# No real user/password or service configuration is changed.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'SKIP: root required for ownership fixture'; exit 77; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 0755 "$WORK"
export FIXTURE_HOME="$WORK/root/login-home"
FIXTURE_USER_UID="$(id -u nobody)"
FIXTURE_USER_GID="$(id -g nobody)"
export FIXTURE_USER_UID FIXTURE_USER_GID
export FIXTURE_CHPASSWD_LOG="$WORK/chpasswd.log"
mkdir -p "$WORK/root/etc/qm1/provision" "$WORK/bin" "$FIXTURE_HOME"
PROV="$WORK/root/etc/qm1/provision"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnly firstboot-fixture\n' > "$PROV/authorized_keys"
printf 'nobody\n' > "$PROV/ssh_user"
: > "$PROV/ssh"
cat > "$WORK/bin/getent" <<'SH'
#!/bin/sh
[ "$1" = passwd ] && [ "$2" = nobody ] || exit 1
printf 'nobody:x:%s:%s::%s:/usr/sbin/nologin\n' "$FIXTURE_USER_UID" "$FIXTURE_USER_GID" "$FIXTURE_HOME"
SH
cat > "$WORK/bin/chpasswd" <<'SH'
#!/bin/sh
[ "$1" = --encrypted ] || exit 1
cat > "$FIXTURE_CHPASSWD_LOG"
SH
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/systemctl"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/mountpoint"
chmod +x "$WORK/bin/"*
python3 - "$SCRIPT_DIR/../overlay/usr/local/sbin/qm1-firstboot" "$WORK" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
for prefix in ['/etc/', '/root/', '/run/', '/var/lib/']:
    text=text.replace(prefix, sys.argv[2]+'/root'+prefix)
Path(sys.argv[2]+'/firstboot').write_text(text)
PY
export PATH="$WORK/bin:$PATH"
bash "$WORK/firstboot" > "$WORK/output"
runuser -u nobody -- cat "$FIXTURE_HOME/.ssh/authorized_keys" > "$WORK/readback"
cmp "$PROV/authorized_keys" "$WORK/readback"
[ "$(stat -c%u "$FIXTURE_HOME/.ssh")" = "$FIXTURE_USER_UID" ]
[ "$(stat -c%a "$FIXTURE_HOME/.ssh")" = 700 ]
[ "$(stat -c%a "$FIXTURE_HOME/.ssh/authorized_keys")" = 600 ]
printf 'fixture-local-password\n' | openssl passwd -6 -stdin > "$PROV/ssh_password_hash"
bash "$WORK/firstboot" --force > "$WORK/output"
printf 'nobody:%s\n' "$(cat "$PROV/ssh_password_hash")" > "$WORK/expected"
cmp "$WORK/expected" "$FIXTURE_CHPASSWD_LOG"
if grep -qF "$(cat "$PROV/ssh_password_hash")" "$WORK/output"; then
    echo 'FAIL password hash leaked to logs'; exit 1
fi
printf 'invalid-hash\n' > "$PROV/ssh_password_hash"
if bash "$WORK/firstboot" --force > "$WORK/output" 2>&1; then
    echo 'FAIL invalid password hash accepted'; exit 1
fi
[ ! -e "$WORK/root/var/lib/qm1/firstboot-done" ]
rm "$PROV/ssh_password_hash"
: > "$PROV/authorized_keys"
if bash "$WORK/firstboot" --force > "$WORK/output" 2>&1; then
    echo 'FAIL empty key file accepted'; exit 1
fi
[ ! -e "$WORK/root/var/lib/qm1/firstboot-done" ]
cp "$WORK/readback" "$PROV/authorized_keys"
printf 'qm1-no-such-fixture-user\n' > "$PROV/ssh_user"
if bash "$WORK/firstboot" --force > "$WORK/output" 2>&1; then
    echo 'FAIL absent login user accepted'; exit 1
fi
[ ! -e "$WORK/root/var/lib/qm1/firstboot-done" ]
echo 'PASS firstboot key readability under non-root UID, private password hash and failed-configuration markers'
