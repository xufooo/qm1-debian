#!/usr/bin/env bash
# Resolve the target board's aliases/dependencies inside the image tree.
# --resolve-alias and --show-depends never load modules into the build host.
set -euo pipefail
ROOT="$(cd "${1:?usage: verify-board-modules.sh ROOTFS}" && pwd)"
KVER="$(basename "$(find "$ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")"
[ -n "$KVER" ] || { echo 'missing module tree' >&2; exit 1; }
for pair in 80860F0A:8250_dw OBDA8723:hci_uart 80860F14:sdhci_acpi; do
    id="${pair%%:*}" expected="${pair#*:}"
    resolved="$(chroot "$ROOT" modprobe --set-version "$KVER" --resolve-alias "acpi:$id:")"
    grep -qxF "$expected" <<<"$resolved" || {
        echo "unresolved board alias $id -> $expected (got $resolved)" >&2; exit 1;
    }
    echo "OK ACPI $id -> $expected"
done
for module in 8250_dw pinctrl-baytrail sdhci-acpi hci_uart btrtl i915 snd-hdmi-lpe-audio; do
    dependencies="$(chroot "$ROOT" modprobe --set-version "$KVER" --show-depends "$module")"
    [ -n "$dependencies" ] || { echo "empty dependency result: $module" >&2; exit 1; }
    while read -r operation path rest; do
        if [ "$operation" = insmod ]; then
            [ -s "$ROOT$path" ] || { echo "missing module dependency: $path" >&2; exit 1; }
        elif [ "$operation" != builtin ]; then
            echo "unexpected dependency operation for $module: $operation $path $rest" >&2; exit 1
        fi
    done <<<"$dependencies"
    echo "OK module closure: $module"
done
