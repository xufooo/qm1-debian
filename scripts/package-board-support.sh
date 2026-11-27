#!/usr/bin/env bash
# Board settings for a normal Debian-Installer target. No users, partitions,
# network ownership or private credentials are created by this package.
set -euo pipefail
OUT="${1:?usage: package-board-support.sh OUTPUT_DIR}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/pkg"
mkdir -p "$PKG/DEBIAN"
files=(
    etc/default/qm1-hardware etc/sysctl.d/90-qm1.conf
    etc/systemd/journald.conf.d/qm1.conf etc/systemd/oomd.conf.d/qm1.conf
    etc/systemd/system/bluetooth.service.d/qm1.conf
    etc/systemd/system/qm1-bluetooth.service
    etc/systemd/system/qm1-hardware-fixups.service
    etc/systemd/system/qm1-health-collect.service
    etc/systemd/system/qm1-health-collect.timer
    etc/systemd/system/user@.service.d/60-qm1-oomd.conf
    etc/udev/rules.d/60-qm1-emmc-power.rules
    usr/local/sbin/qm1-bluetooth-up usr/local/sbin/qm1-hardware-fixups
    usr/local/sbin/qm1-hardware-survey usr/local/sbin/qm1-health-collect
)
for file in "${files[@]}"; do
    mkdir -p "$PKG/$(dirname "$file")"
    install -m 0644 "$REPO/overlay/$file" "$PKG/$file"
    case "$file" in usr/local/sbin/*) chmod 0755 "$PKG/$file" ;; esac
done
mkdir -p "$PKG/usr/share/qm1"
install -m 0644 "$REPO/overlay/etc/default/zramswap" "$PKG/usr/share/qm1/zramswap.conf"
mkdir -p "$PKG/etc/default/grub.d" "$PKG/usr/share/initramfs-tools/hooks"
cat > "$PKG/etc/default/grub.d/60-qm1.cfg" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} intel_idle.max_cstate=1"
EOF
cat > "$PKG/usr/share/initramfs-tools/hooks/qm1-emmc-power" <<'EOF'
#!/bin/sh
set -e
case "${1:-}" in prereqs) exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
for module in sdhci_pci sdhci_acpi mmc_block vfat ext4 usb_storage xhci_hcd xhci_pci ehci_pci usbhid hid_generic i915; do
    manual_add_modules "$module"
done
copy_file config /etc/udev/rules.d/60-qm1-emmc-power.rules /usr/lib/udev/rules.d/60-qm1-emmc-power.rules
EOF
chmod 0755 "$PKG/usr/share/initramfs-tools/hooks/qm1-emmc-power"
mkdir -p "$PKG/etc/modules-load.d"
printf '%s\n' i915 snd_hda_intel snd_hdmi_lpe_audio hci_uart btrtl rtw88_qm1 > "$PKG/etc/modules-load.d/qm1-hardware.conf"
cat > "$PKG/DEBIAN/control" <<'EOF'
Package: qm1-board-support
Version: 1.0
Section: admin
Priority: optional
Architecture: all
Depends: qm1-rtw88-8723bs, firmware-realtek, intel-microcode, bluez, zram-tools, systemd-oomd, alsa-utils, iw, rfkill, kmod, iproute2, pciutils, usbutils, python3, python3-venv, curl, ca-certificates, openssh-server, sudo, init-system-helpers
Maintainer: QM1 installer build
Description: QM1 board support for systems installed with Debian-Installer
 Applies the reviewed eMMC power, Bay Trail idle, audio, Bluetooth and memory
 settings without replacing Debian account setup or its network configuration.
EOF
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "${1:-}" = configure ]; then
    # zram-tools owns this conffile; keep its ownership and apply the board
    # settings as an administrator configuration, never a second dpkg owner.
    install -m 0644 /usr/share/qm1/zramswap.conf /etc/default/zramswap
    for unit in qm1-rtw88-8723bs.service qm1-hardware-fixups.service qm1-bluetooth.service qm1-health-collect.timer; do
        deb-systemd-helper enable "$unit" >/dev/null
    done
    install -d -m 0750 /var/log/qm1-health
    if command -v update-initramfs >/dev/null; then update-initramfs -u -k all; fi
    if command -v update-grub >/dev/null; then update-grub; fi
fi
EOF
chmod 0755 "$PKG/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/qm1-board-support_1.0_all.deb"
