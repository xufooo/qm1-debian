#!/usr/bin/env bash
# install-drivers.sh — 在 chroot 内预置 QM1 的内核、firmware 与启动关键模块
#
# 设计原则（对应"把硬件驱动都带上，保证硬件能够启动"）：
#   1) 内核自带（in-tree）：eMMC/SD、USB、显卡 i915、Intel HDA、蓝牙、RTC、ACPI/电源管理
#      —— 这些是"能启动"的关键路径，全部由 Debian 内核包提供，无需额外驱动。
#   2) 需要 firmware（只读固件 blob）：Wi-Fi/BT 芯片、Intel 微码。
#      —— firmware-brcm80211 / firmware-realtek / firmware-atheros / firmware-iwlwifi
#         位于 Debian 的 non-free-firmware 组件，debootstrap 必须带上该组件。
#   3) 需要 out-of-tree（DKMS）：Realtek RTL8723AU/8812AU/8812BU 等消费级无线芯片
#      —— Debian 内核没有这些驱动；必须针对镜像内的同一个内核版本编译。
#      本脚本提供安装入口，但默认不内置源码（许可证与内核版本适配风险由使用者承担）。
#
# 用法（一般由 build-rootfs.sh 调用；也可在已建好的 chroot 内单独执行）：
#   /tmp/install-drivers.sh --arch amd64 --profile base
#
# 环境变量：
#   QM1_DKMS_DEB_DIR   含待安装 DKMS/驱动 .deb 的目录（非空时批量安装）
set -euo pipefail

ARCH="amd64"
PROFILE="base"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        *) echo "[drivers] 忽略未知参数：$1" >&2 ;;
    esac
done

log()  { printf '\033[1;34m[drivers]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[drivers][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[drivers][fail]\033[0m %s\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# ---------- 1. 内核与头文件 ----------
KERNEL_PKGS="linux-image-$ARCH"
if apt-cache show "linux-headers-$ARCH" >/dev/null 2>&1; then
    KERNEL_PKGS="$KERNEL_PKGS linux-headers-$ARCH"   # DKMS/out-of-tree 编译必需
fi
log "安装内核：$KERNEL_PKGS"
apt-get install -y -qq --no-install-recommends $KERNEL_PKGS

# ---------- 2. firmware（尽力而为） ----------
# non-free-firmware 组件缺失时不应让整条构建失败 —— 但要在日志里明确指出。
FIRMWARE_PKGS=(
    firmware-linux-free          # main：显卡/常用 blob
    firmware-brcm80211           # non-free-firmware：Broadcom brcmfmac（BCM4352/4356/4365/4366）
    firmware-realtek             # non-free-firmware：Realtek 8723*/8812* 系列 blob
    firmware-atheros             # non-free-firmware：Qualcomm Atheros
    firmware-iwlwifi             # non-free-firmware：Intel 7 系列无线
    intel-microcode              # main：Intel 平台微码（i915 等）
)
installed_fw=""
missing_fw=""
for p in "${FIRMWARE_PKGS[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
        if apt-get install -y -qq --no-install-recommends "$p"; then
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
    warn "未能安装：${missing_fw}"
    warn "若 Wi-Fi/蓝牙固件缺失，需在 sources 里启用 non-free-firmware 组件后重建"
fi

# ---------- 3. initramfs：启动关键模块必须在内核启动早期可用 ----------
# MODULES=most：把大部分驱动编进 initramfs，避免根盘驱动缺失导致"起不来"。
mkdir -p /etc/initramfs-tools
cat > /etc/initramfs-tools/modules <<'EOF'
# QM1 启动关键路径（Bay Trail）
sdhci_pci
sdhci_acpi
mmc_block
vfat
ext4
usb_storage
xhci_hcd
ehci_pci
EOF
if ! grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf; then
    echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf
else
    sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
fi
grep -q '^COMPRESS=' /etc/initramfs-tools/initramfs.conf \
    || echo 'COMPRESS=zstd' >> /etc/initramfs-tools/initramfs.conf
log "生成 initramfs（MODULES=most, COMPRESS=zstd）"
update-initramfs -u -k all

# ---------- 4. 运行时自动加载的硬件模块 ----------
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/qm1-hardware.conf <<'EOF'
# QM1 硬件模块（缺哪个会在 drv-selfcheck.sh 里报出来）
i915
snd_hda_intel
btusb
EOF

# ---------- 5. out-of-tree / DKMS 驱动（可选） ----------
if [ -n "${QM1_DKMS_DEB_DIR:-}" ] && [ -d "$QM1_DKMS_DEB_DIR" ]; then
    log "安装外部驱动包：$QM1_DKMS_DEB_DIR"
    shopt -s nullglob
    debs=("$QM1_DKMS_DEB_DIR"/*.deb)
    shopt -u nullglob
    if [ "${#debs[@]}" -gt 0 ]; then
        apt-get install -y -qq "${debs[@]}" || warn "外部驱动安装失败，Wi-Fi 可能仍不可用"
        dkms autoinstall || warn "dkms autoinstall 失败"
    else
        warn "目录内没有 .deb"
    fi
else
    warn "未提供 QM1_DKMS_DEB_DIR：Realtek 8723AU/8812AU/8812BU 等无主线驱动的芯片未被覆盖"
    warn "对策：改用 USB 以太网适配器（推荐），或自行编译对应 DKMS 驱动后重装本步骤"
fi

# ---------- 6. 驱动清单（供 drv-selfcheck.sh 与人工核对） ----------
# 说明：这里是"应该被支持"的期望清单，不代表已经在目标机上验证过绑定成功。
mkdir -p /usr/local/share/qm1
MANIFEST=/usr/local/share/qm1/driver-manifest.txt
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
} > "$MANIFEST"
log "驱动清单：$MANIFEST"

# 汇总：本镜像内实际存在哪些模块（modinfo 能查到 = 内核包里有）
{
    echo ""
    echo "--- 本镜像内核实际提供的模块 ---"
    for m in sdhci_pci sdhci_acpi mmc_block vfat ext4 ehci_pci xhci_hcd usb_storage \
             usbnet cdc_ether r8152 i915 snd_hda_intel snd_hda_codec_realtek btusb \
             brcmfmac iwlwifi rt2x00 rtc_cmos intel_idle acpi_cpufreq intel_powerclamp; do
        if modinfo "$m" >/dev/null 2>&1; then
            printf '%-26s present\n' "$m"
        else
            printf '%-26s MISSING\n' "$m"
        fi
    done
} >> "$MANIFEST"

log "完成"
