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
for script in install-qm1.sh prepare-provision.sh inject-provision.sh; do
    cp "$SCRIPT_DIR/$script" "$OUT/$script"
done
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

Before booting a trial image, prepare private Wi-Fi/SSH configuration on Linux.
Dependencies: mtools, python3, openssl, zstd, coreutils.
Generate a local sudo password hash interactively:
  umask 077; openssl passwd -6 > local-password.hash
Prepare the private directory (use your own SSID, Wi-Fi password and public key):
  bash prepare-provision.sh --out private-provision --ssid YOUR_SSID --psk-file wifi-password.txt --enable-ssh --ssh-user qm1 --ssh-pubkey YOUR_PUBLIC_KEY --ssh-password-hash-file local-password.hash
Inject into a private decompressed image copy:
  bash inject-provision.sh --image qm1-installer.img --dir private-provision
Public image checksums apply before this private modification.
Keep private-provision, password hashes and configured images private.
Installation writes the selected target and requires a verified backup.
EOF
(
    cd "$OUT"
    sha256sum qm1-disk.img.zst qm1-installer.img.zst manifest.txt \
        install-qm1.sh prepare-provision.sh inject-provision.sh lib/common.sh BUILD-INFO.txt IMAGE-README.txt > SHA256SUMS
    sha256sum -c SHA256SUMS
    bash install-qm1.sh --help >/dev/null
    bash prepare-provision.sh --help >/dev/null
    bash inject-provision.sh --help >/dev/null
)
