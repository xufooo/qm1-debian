#!/usr/bin/env bash
# Exercise build entry points with a former application profile: refuse it
# before touching any output, even on hosts without Linux build dependencies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/rootfs"
printf 'preserve\n' > "$WORK/rootfs/sentinel"
for script in build-rootfs.sh build-image.sh; do
    output_arg=--out
    [ "$script" = build-image.sh ] && output_arg=--out-dir
    if bash "$SCRIPT_DIR/$script" --profile runtime "$output_arg" "$WORK/rootfs" >"$WORK/error" 2>&1; then
        echo "FAIL $script accepted an application image"; exit 1
    fi
    grep -q -- '--profile base' "$WORK/error"
    grep -q '^preserve$' "$WORK/rootfs/sentinel"
done
echo 'PASS application profile is refused before changing output'

for cfg in "$SCRIPT_DIR/grub.cfg.example" "$SCRIPT_DIR/grub-installer.cfg.example"; do
    if grep -Eq '^[[:space:]]*linux[[:space:]].*console=ttyS' "$cfg"; then
        echo "FAIL production menu claims a serial console: $cfg"; exit 1
    fi
done
echo 'PASS production menus leave serial UARTs available to hardware drivers'
