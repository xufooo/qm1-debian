#!/usr/bin/env bash
# Resolve the target board's aliases/dependencies inside the image tree.
# --resolve-alias and --show-depends never load modules into the build host.
set -euo pipefail
ROOT="$(cd "${1:?usage: verify-board-modules.sh ROOTFS}" && pwd)"
KVER="$(basename "$(find "$ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")"
[ -n "$KVER" ] || { echo 'missing module tree' >&2; exit 1; }
CONFIG="$ROOT/boot/config-$KVER"
[ -s "$CONFIG" ] || { echo 'missing kernel config' >&2; exit 1; }
for pair in 80860F0A:8250_dw:SERIAL_8250_DW OBDA8723:hci_uart:BT_HCIUART 80860F14:sdhci_acpi:MMC_SDHCI_ACPI; do
    IFS=: read -r id expected symbol <<<"$pair"
    # Built-in ACPI drivers register directly; MODULE_DEVICE_TABLE aliases
    # need not be present in the module alias database for built-in code.
    if grep -qx "CONFIG_$symbol=y" "$CONFIG"; then
        echo "OK built-in ACPI driver $id -> $expected ($symbol=y)"
        continue
    fi
    resolved="$(chroot "$ROOT" modprobe --set-version "$KVER" --resolve-alias "acpi:$id:")"
    grep -qxF "$expected" <<<"$resolved" || {
        echo "unresolved board alias $id -> $expected (got $resolved)" >&2; exit 1;
    }
    echo "OK ACPI $id -> $expected"
done
for pair in 8250_dw:SERIAL_8250_DW pinctrl-baytrail:PINCTRL_BAYTRAIL \
            sdhci-acpi:MMC_SDHCI_ACPI hci_uart:BT_HCIUART btrtl:BT_RTL \
            i915:DRM_I915 snd-hdmi-lpe-audio:HDMI_LPE_AUDIO; do
    IFS=: read -r module symbol <<<"$pair"
    if grep -qx "CONFIG_$symbol=y" "$CONFIG"; then
        echo "OK built-in driver: $module ($symbol=y)"
        continue
    fi
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
