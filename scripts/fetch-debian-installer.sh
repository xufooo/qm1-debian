#!/usr/bin/env bash
# Fetch an authenticated, complete upstream Debian amd64 installer ISO.
set -euo pipefail
OUT="${1:?usage: fetch-debian-installer.sh OUTPUT_DIR}"
BASE="${DEBIAN_CD_BASE:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
for tool in curl gpgv sha512sum python3; do command -v "$tool" >/dev/null; done
keyring=""
for candidate in /usr/share/keyrings/debian-role-keys.pgp /usr/share/keyrings/debian-role-keys.gpg; do
    if [ -f "$candidate" ]; then keyring="$candidate"; break; fi
done
[ -n "$keyring" ] || { echo 'Install debian-keyring to verify Debian CD signatures' >&2; exit 1; }
curl -fLsS --retry 3 "$BASE/SHA512SUMS" -o "$OUT/SHA512SUMS"
curl -fLsS --retry 3 "$BASE/SHA512SUMS.sign" -o "$OUT/SHA512SUMS.sign"
gpgv --status-fd 1 --keyring "$keyring" "$OUT/SHA512SUMS.sign" "$OUT/SHA512SUMS" \
    > "$OUT/signature-status.txt"
# Stable CD signing keys published at https://www.debian.org/CD/verify.
awk '$2=="VALIDSIG" && ($3=="DF9B9C49EAA9298432589D76DA87E80D6294BE9B" ||
    $NF=="DF9B9C49EAA9298432589D76DA87E80D6294BE9B" ||
    $3=="10460DAD76165AD81FBC0CE9988021A964E6EA7D" ||
    $NF=="10460DAD76165AD81FBC0CE9988021A964E6EA7D"){ok=1} END{exit !ok}' \
    "$OUT/signature-status.txt"
name="$(awk '$2 ~ /^debian-[0-9.]+-amd64-netinst\.iso$/ {print $2}' "$OUT/SHA512SUMS")"
[[ "$name" =~ ^debian-[0-9.]+-amd64-netinst\.iso$ ]] || { echo 'Ambiguous installer name' >&2; exit 1; }
awk -v name="$name" '$2==name{print}' "$OUT/SHA512SUMS" > "$OUT/selected.SHA512SUMS"
if ! ( cd "$OUT"; sha512sum -c selected.SHA512SUMS ) 2>/dev/null; then
    curl -fLsS --retry 3 "$BASE/$name" -o "$OUT/$name"
    ( cd "$OUT"; sha512sum -c selected.SHA512SUMS )
fi
printf '%s\n' "$OUT/$name" > "$OUT/iso-path.txt"
python3 - "$OUT" "$BASE" "$name" <<'PY'
import json, pathlib, sys
out=pathlib.Path(sys.argv[1])
(out/'source.json').write_text(json.dumps(dict(url=sys.argv[2]+'/'+sys.argv[3],
    filename=sys.argv[3],sha512=(out/'selected.SHA512SUMS').read_text().split()[0],
    signature_verified=True),indent=2)+'\n')
PY
