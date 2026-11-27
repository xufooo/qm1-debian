#!/usr/bin/env bash
# Resolve the target board's aliases/dependencies inside the image tree.
# --resolve-alias and --show-depends never load modules into the build host.
set -euo pipefail
ROOT="$(cd "${1:?usage: verify-board-modules.sh ROOTFS}" && pwd)"
KVER="$(basename "$(find "$ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)")"
[ -n "$KVER" ] || { echo 'missing module tree' >&2; exit 1; }
CONFIG="$ROOT/boot/config-$KVER"
[ -s "$CONFIG" ] || { echo 'missing kernel config' >&2; exit 1; }
# These select the actual Realtek H5 ACPI match table and the board's parent
# buses. A generic Bluetooth or xHCI symbol alone does not cover this board.
for symbol in EFI_MIXED EFI_STUB EFI_PARTITION ACPI X86_INTEL_LPSS IOSF_MBI \
              GPIOLIB PINCTRL_BAYTRAIL SERIAL_DEV_BUS SERIAL_DEV_CTRL_TTYPORT \
              BT_HCIUART_SERDEV BT_HCIUART_3WIRE BT_HCIUART_RTL \
              ZRAM_BACKEND_ZSTD; do
    grep -qx "CONFIG_$symbol=y" "$CONFIG" || {
        echo "missing required board capability: CONFIG_$symbol=y" >&2; exit 1;
    }
    echo "OK board capability: $symbol"
done
for pair in 80860F0A:8250_dw:SERIAL_8250_DW OBDA8723:hci_uart:BT_HCIUART \
            80860F14:sdhci_acpi:MMC_SDHCI_ACPI INT33BB:sdhci_acpi:MMC_SDHCI_ACPI \
            INT33FC:pinctrl_baytrail:PINCTRL_BAYTRAIL; do
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
# Check udev's real SDIO autoload selection with blacklist policy applied,
# rather than merely finding the preferred driver somewhere on disk.
wifi_dependencies="$(chroot "$ROOT" modprobe --set-version "$KVER" --use-blacklist \
    --show-depends 'sdio:c00v024CdB723')"
grep -qE '/extra/(rtw88/[^ ]+|r8723bs_qm1)\.ko' <<<"$wifi_dependencies" || {
    echo "SDIO autoload does not select a packaged QM1 Wi-Fi driver: $wifi_dependencies" >&2; exit 1;
}
while read -r operation path rest; do
    if [ "$operation" = insmod ]; then
        [ -s "$ROOT$path" ] || { echo "missing Wi-Fi dependency: $path" >&2; exit 1; }
    elif [ "$operation" != builtin ]; then
        echo "unexpected Wi-Fi dependency operation: $operation $path $rest" >&2; exit 1
    fi
done <<<"$wifi_dependencies"
echo "OK effective SDIO autoload and dependency closure"
for pair in 8250_dw:SERIAL_8250_DW pinctrl-baytrail:PINCTRL_BAYTRAIL \
            sdhci-acpi:MMC_SDHCI_ACPI hci_uart:BT_HCIUART btrtl:BT_RTL \
            i915:DRM_I915 snd-hdmi-lpe-audio:HDMI_LPE_AUDIO \
            mmc_block:MMC_BLOCK xhci-pci:USB_XHCI_PCI xhci-hcd:USB_XHCI_HCD \
            usb-storage:USB_STORAGE usbhid:USB_HID hid-generic:HID_GENERIC \
            intel_soc_dts_thermal:INTEL_SOC_DTS_THERMAL coretemp:SENSORS_CORETEMP \
            acpi-cpufreq:X86_ACPI_CPUFREQ rtc_cmos:RTC_DRV_CMOS \
            vfat:VFAT_FS ext4:EXT4_FS exfat:EXFAT_FS zram:ZRAM; do
    IFS=: read -r module symbol <<<"$pair"
    grep -qE "^CONFIG_$symbol=(y|m)$" "$CONFIG" || {
        echo "missing required driver config: CONFIG_$symbol" >&2; exit 1;
    }
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
