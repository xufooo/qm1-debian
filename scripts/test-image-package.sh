#!/usr/bin/env bash
# Exercise the real downloadable bundle outside the source checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/payload" "$WORK/download"
printf 'ordinary disk fixture\n' | zstd -q -o "$WORK/payload/qm1-disk.img.zst"
printf 'installer fixture\n' | zstd -q -o "$WORK/payload/qm1-installer.img.zst"
printf 'kernel=fixture\n' > "$WORK/payload/manifest.txt"
bash "$SCRIPT_DIR/package-images.sh" "$WORK/payload"
for name in qm1-disk.img.zst qm1-installer.img.zst manifest.txt install-qm1.sh \
            lib/common.sh BUILD-INFO.txt IMAGE-README.txt SHA256SUMS; do
    mkdir -p "$WORK/download/$(dirname "$name")"
    cp "$WORK/payload/$name" "$WORK/download/$name"
done
(
    cd "$WORK/download"
    sha256sum -c SHA256SUMS
    bash install-qm1.sh --help >/dev/null
    printf 'corruption\n' >> qm1-disk.img.zst
    if sha256sum -c SHA256SUMS >/dev/null 2>&1; then
        echo 'FAIL corrupted downloaded image was accepted'; exit 1
    fi
)
rm "$WORK/payload/qm1-installer.img.zst"
if bash "$SCRIPT_DIR/package-images.sh" "$WORK/payload" >/dev/null 2>&1; then
    echo 'FAIL incomplete image set was packaged'; exit 1
fi
echo 'PASS isolated download checksums, installer dependency, corruption and missing-image rejection'
