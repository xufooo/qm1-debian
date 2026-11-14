#!/usr/bin/env bash
# Prepare exactly the downloadable files, with checksums valid after extraction.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "${1:?usage: package-images.sh OUTPUT_DIR}" && pwd)"
for name in qm1-disk.img.zst qm1-installer.img.zst manifest.txt; do
    [ -s "$OUT/$name" ] || { echo "missing image payload: $name" >&2; exit 1; }
done
zstd -t "$OUT/qm1-disk.img.zst" "$OUT/qm1-installer.img.zst"
mkdir -p "$OUT/lib"
cp "$SCRIPT_DIR/install-qm1.sh" "$OUT/install-qm1.sh"
cp "$SCRIPT_DIR/lib/common.sh" "$OUT/lib/common.sh"
commit="${GITHUB_SHA:-$(git -C "$SCRIPT_DIR/.." rev-parse HEAD)}"
printf 'source_commit=%s\nprofile=base\nstatus=preflight-image\n' "$commit" > "$OUT/BUILD-INFO.txt"
cat > "$OUT/IMAGE-README.txt" <<'EOF'
QM1 Debian amd64 system base, with IA32 and x64 EFI loaders.
This is a preflight image; physical-device acceptance is still required.
Applications are installed separately by the user.

Verify the extracted download first: sha256sum -c SHA256SUMS
Decompress the selected image: zstd -d qm1-installer.img.zst
qm1-installer.img: bootable installer/trial medium; default boot is trial.
qm1-disk.img: ordinary system disk image.

Keep install-qm1.sh beside lib/common.sh if using the host-side installer.
Read its options with: bash install-qm1.sh --help
Installation writes the selected target and requires a verified backup.
EOF
(
    cd "$OUT"
    sha256sum qm1-disk.img.zst qm1-installer.img.zst manifest.txt \
        install-qm1.sh lib/common.sh BUILD-INFO.txt IMAGE-README.txt > SHA256SUMS
    sha256sum -c SHA256SUMS
    bash install-qm1.sh --help >/dev/null
)
