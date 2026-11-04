#!/bin/sh
# ============================================================================
# customize02-drivers.sh — mmdebstrap customize hook：QM1 硬件驱动与固件预置
# ============================================================================
# 对应"把硬件驱动都带上，保证硬件能够启动"：
#   1) 内核自带（in-tree）：eMMC/SD、USB、显卡 i915、Intel HDA、蓝牙、RTC、ACPI/电源
#   2) 需 firmware（只读固件 blob）：Wi-Fi/BT 芯片、Intel 微码
#      —— 在 Debian 13 里位于 non-free-firmware 组件，mmdebstrap 必须带上该组件
#   3) 需 out-of-tree（DKMS）：Realtek RTL8723AU/8812AU/8812BU
#      —— 主线无驱动；QM1 具体无线芯片型号尚未确认，构建期不内置源码，
#         可用 QM1_DKMS_DEB_DIR 传入自编译的 .deb；否则改用 USB 以太网适配器
# ============================================================================
set -e

TARGET="${1:?usage: mmdebstrap hook requires the chroot directory as \$1}"

ARCH="${QM1_ARCH:-amd64}"
PROFILE="${QM1_PROFILE:-base}"

export DEBIAN_FRONTEND=noninteractive

log()  { printf '[hook02] %s\n' "$*" >&2; }
warn() { printf '[hook02][warn] %s\n' "$*" >&2; }
die()  { printf '[hook02][fail] %s\n' "$*" >&2; exit 1; }

# ---------- 1. 内核与头文件 ----------
case "$ARCH" in
    amd64) KERNEL_PKGS="linux-image-amd64 linux-headers-amd64" ;;
    i386)  KERNEL_PKGS="linux-image-i386 linux-headers-i386" ;;
    *) die "不支持的架构：$ARCH" ;;
esac
log "安装内核：$KERNEL_PKGS"
chroot "$TARGET" apt-get install -y -qq --no-install-recommends $KERNEL_PKGS

# ---------- 2. firmware（尽力而为，缺包只告警） ----------
FIRMWARE_PKGS="firmware-linux-free firmware-brcm80211 firmware-realtek firmware-atheros firmware-iwlwifi intel-microcode"
installed_fw=""
missing_fw=""
for p in $FIRMWARE_PKGS; do
    if chroot "$TARGET" apt-cache show "$p" >/dev/null 2>&1; then
        if chroot "$TARGET" apt-get install -y -qq --no-install-recommends "$p"; then
            installed_fw="$installed_fw $p"
        else
            missing_fw="$missing_fw $p"
        fi
    else
        missing_fw="$missing_fw $p(无此包)"
    fi
done
log "已装 firmware：${installed_fw:-（无）}"
if [ -n "$missing_fw" ]; then
    warn "未能安装：$missing_fw"
fi

# ---------- 3. initramfs：启动关键模块必须提前可用 ----------
mkdir -p "$TARGET/etc/initramfs-tools"
cat > "$TARGET/etc/initramfs-tools/modules" <<'EOF'
# QM1 启动关键路径（Bay Trail）
# eMMC 控制器有两条枚举路径：PCI（sdhci_pci）与 ACPI（sdhci_acpi），
# 两条都塞进 initramfs —— 固件用哪种枚举方式就命中哪个。
sdhci_pci
sdhci_acpi
mmc_block
vfat
ext4
usb_storage
xhci_hcd
ehci_pci
EOF
if ! grep -q '^MODULES=' "$TARGET/etc/initramfs-tools/initramfs.conf"; then
    echo 'MODULES=most' >> "$TARGET/etc/initramfs-tools/initramfs.conf"
else
    sed -i 's/^MODULES=.*/MODULES=most/' "$TARGET/etc/initramfs-tools/initramfs.conf"
fi
grep -q '^COMPRESS=' "$TARGET/etc/initramfs-tools/initramfs.conf" \
    || echo 'COMPRESS=zstd' >> "$TARGET/etc/initramfs-tools/initramfs.conf"
log "生成 initramfs（MODULES=most, COMPRESS=zstd）"
chroot "$TARGET" update-initramfs -u -k all

# ---------- 4. 运行时自动加载的硬件模块 ----------
mkdir -p "$TARGET/etc/modules-load.d"
cat > "$TARGET/etc/modules-load.d/qm1-hardware.conf" <<'EOF'
# QM1 硬件模块（缺哪个会在 drv-selfcheck.sh 里报出来）
i915
snd_hda_intel
btusb
EOF

# ---------- 5. out-of-tree / DKMS 驱动（可选） ----------
if [ -n "${QM1_DKMS_DEB_DIR:-}" ] && [ -d "$QM1_DKMS_DEB_DIR" ]; then
    log "安装外部驱动包：$QM1_DKMS_DEB_DIR"
    debs=$(find "$QM1_DKMS_DEB_DIR" -maxdepth 1 -name '*.deb' | sort)
    if [ -n "$debs" ]; then
        # shellcheck disable=SC2086
        chroot "$TARGET" apt-get install -y -qq $debs || warn "外部驱动安装失败，Wi-Fi 可能仍不可用"
        chroot "$TARGET" dkms autoinstall || warn "dkms autoinstall 失败"
    else
        warn "目录内没有 .deb"
    fi
else
    warn "未提供 QM1_DKMS_DEB_DIR：Realtek 8723AU/8812AU/8812BU 等无主线驱动的芯片未被覆盖"
    warn "对策：改用 USB 以太网适配器（推荐），或自行编译对应 DKMS 驱动后重装本步骤"
fi

# ---------- 6. 驱动清单（供 drv-selfcheck.sh 与 CI 断言） ----------
KVER="$(ls -1 "$TARGET/lib/modules" 2>/dev/null | sort -V | tail -1)"
[ -n "$KVER" ] || die "镜像内没有 /lib/modules 目录（内核包安装失败？）"
log "镜像内核版本：$KVER"

CRITICAL_MODULES="sdhci_pci sdhci_acpi mmc_block vfat ext4"
missing_critical=""
fw_blob_summary=""
for blob in brcmfmac4352-pcie.bin brcmfmac4356-pcie.bin brcmfmac4365-pcie.bin \
            rtl8723a_fw.bin rtl8723befw.bin; do
    if [ -e "$TARGET/lib/firmware/$blob" ] \
       || find "$TARGET/lib/firmware" -name "$blob" -print -quit 2>/dev/null | grep -q .; then
        fw_blob_summary="$fw_blob_summary $blob:ok"
    else
        fw_blob_summary="$fw_blob_summary $blob:-"
    fi
done

mkdir -p "$TARGET/usr/local/share/qm1"
MANIFEST="$TARGET/usr/local/share/qm1/driver-manifest.txt"
{
    echo "# QM1 期望驱动清单（生成于 rootfs 构建期，arch=$ARCH profile=$PROFILE）"
    echo "# 字段：模块名 用途"
    cat <<'EOF'
sdhci_pci      eMMC/SD 控制器（PCI 枚举路径）
sdhci_acpi     eMMC/SD 控制器（ACPI 枚举路径）
mmc_block      MMC 块设备（根盘所在）
vfat           ESP / microSD（FAT32）
ext4           根文件系统
ehci_pci       USB 2.0 控制器
xhci_hcd       USB 3.0 控制器
usb_storage    microSD 读卡器 / U 盘
usbnet         USB 网卡
cdc_ether      USB 网卡（CDC-ECM）
r8152          Realtek USB 网卡（8152 系列）
i915           Intel HD 显卡（Gen7）
snd_hda_intel  Intel HD Audio
snd_hda_codec_realtek  Realtek HDA 编解码器
btusb          蓝牙 USB 适配器
brcmfmac       Broadcom Wi-Fi（主线）
iwlwifi        Intel Wi-Fi（主线）
rt2x00         Ralink/MediaTek Wi-Fi（主线）
rtl8723au      Realtek 8723AU（需 DKMS，主线无）
rtl8812au      Realtek 8812AU（需 DKMS，主线无）
rtl8812bu      Realtek 8812BU（需 DKMS，主线无）
rtc_cmos       RTC
intel_idle     空闲状态
acpi_cpufreq   频率调节（若平台提供）
intel_powerclamp  温度兜底降频
EOF
    echo ""
    echo "--- 本镜像内核实际提供的模块（kernel=$KVER）---"
    for m in sdhci_pci sdhci_acpi mmc_block vfat ext4 ehci_pci xhci_hcd usb_storage \
             usbnet cdc_ether r8152 i915 snd_hda_intel snd_hda_codec_realtek btusb \
             brcmfmac iwlwifi rt2x00 rtc_cmos intel_idle acpi_cpufreq intel_powerclamp; do
        # 必须用 -k 指定镜像自己的内核版本，否则查的是宿主 running kernel
        if chroot "$TARGET" modinfo -k "$KVER" "$m" >/dev/null 2>&1; then
            printf '%-26s present\n' "$m"
        else
            printf '%-26s MISSING\n' "$m"
            case " $CRITICAL_MODULES " in
                *" $m "*) missing_critical="$missing_critical $m" ;;
            esac
        fi
    done
    echo ""
    echo "--- firmware blob 核对 ---"
    echo "$fw_blob_summary"
    echo "--- 已装 firmware 包 ---"
    echo "installed:${installed_fw:-none}"
    echo "missing:${missing_fw:-none}"
} > "$MANIFEST"
log "驱动清单：$MANIFEST"

if [ -n "$missing_critical" ]; then
    die "启动关键驱动缺失：$missing_critical —— 这会让 QM1 认不到 eMMC/ESP，插电也起不来"
fi
log "启动关键驱动齐全：$CRITICAL_MODULES"
log "完成"
