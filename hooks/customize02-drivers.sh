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
# 注意 Debian 的 i386 内核 flavour 叫 686 / 686-pae，没有 linux-image-i386 这个包：
#   linux-image-686      "Linux for older PCs"（非 PAE）
#   linux-image-686-pae  "Linux for modern PCs"（PAE）← Bay Trail 用这个
# 且 Debian 13 起不再提供 i386 内核，所以 i386 变体的发行版固定用 bookworm。
case "$ARCH" in
    amd64) KERNEL_PKGS="linux-image-amd64 linux-headers-amd64" ;;
    i386)  KERNEL_PKGS="linux-image-686-pae linux-headers-686-pae" ;;
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

KCFG="$TARGET/boot/config-$KVER"
[ -f "$KCFG" ] || warn "没有 $KCFG（内核 config 缺失，驱动状态只能靠 modinfo 判定）"

# 判断一个驱动在本内核里的状态：
#   module  = 编成模块（.ko），可 modprobe
#   builtin = 编进内核（=y），没有 .ko 但功能在
#   absent  = 两者都不是
# 必须区分这两者：例如 rtc_cmos / acpi / intel_idle / thermal 是 =y（编进内核），
# 用 modinfo 查会报 MISSING —— 那是误报，不是缺驱动。
driver_state() {
    _mod="$1"; _sym="$2"
    if chroot "$TARGET" modinfo -k "$KVER" "$_mod" >/dev/null 2>&1; then
        echo "module"; return
    fi
    if [ -n "$_sym" ] && [ -f "$KCFG" ]; then
        if grep -qE "^CONFIG_${_sym}=y$" "$KCFG"; then echo "builtin"; return; fi
        if grep -qE "^CONFIG_${_sym}=m$" "$KCFG"; then echo "absent"; return; fi
    fi
    echo "absent"
}

# 期望驱动清单：模块名 | 内核 config 符号 | 服务的硬件 | 启动关键
# (config 符号为 6.12 的实际命名：I915 在 6.2+ 改名 DRM_I915，rtc_cmos 改名 RTC_DRV_CMOS)
DRIVER_TABLE="
sdhci-pci|MMC_SDHCI_PCI|eMMC/SD 控制器（PCI 枚举路径）|critical
sdhci-acpi|MMC_SDHCI_ACPI|eMMC/SD 控制器（ACPI 枚举路径）|critical
mmc_block|MMC_BLOCK|MMC 块设备（根盘）|critical
vfat|VFAT_FS|ESP / microSD 的 FAT32|critical
ext4|EXT4_FS|根文件系统|critical
usb-storage|USB_STORAGE|microSD 读卡器 / U 盘|
ehci-pci|USB_EHCI_PCI|USB 2.0 控制器|
xhci-hcd|USB_XHCI_HCD|USB 3.0 控制器|
ohci-hcd|USB_OHCI_HCD|USB 1.1 控制器|
usbnet|USB_NET|USB 网卡框架|
r8152|USB_NET_RTL8152|Realtek USB 网卡（8152/8153）|
asix|USB_NET_ASIX|ASIX USB 网卡|
cdc_ether|USB_NET_CDC_ETHER|USB 网卡（CDC-ECM）|
ax8817x|USB_NET_AX8817X|ASIX USB 网卡（8817x）|
i915|DRM_I915|Intel HD Graphics Gen7（HDMI 输出）|
snd-hda-intel|SND_HDA_INTEL|Intel HD Audio（HDMI 音频 + Realtek codec）|
snd-hda-codec-realtek|SND_HDA_CODEC_REALTEK|Realtek HDA 编解码器|
btusb|BT_HCIBTUSB|蓝牙（USB 模组）|
brcmfmac|BRCMFMAC|Broadcom Wi-Fi（主线驱动）|
iwlwifi|IWLWIFI|Intel Wi-Fi（主线驱动）|
rtw88|RTW88|Realtek 88xx Wi-Fi（主线驱动）|
ath9k|ATH9K|Atheros Wi-Fi（主线驱动）|
ath10k|ATH10K|Atheros Wi-Fi（主线驱动）|
mt76|MT76_CORE|MediaTek Wi-Fi（主线驱动）|
rtc_cmos|RTC_DRV_CMOS|ACPI RTC（编进内核）|
intel_idle|INTEL_IDLE|CPU 空闲状态（编进内核）|
acpi|ACPI|ACPI 电源管理（编进内核）|
thermal|THERMAL|温度与热管理（编进内核）|
"

CRITICAL_MODULES="sdhci-pci sdhci-acpi mmc_block vfat ext4"
missing_critical=""

# firmware blob 核对：只查 Debian 实际发布的 blob 名
# （brcmfmac4352-pcie.bin / brcmfmac4365-pcie.bin 在 Debian 里并不存在，
#   PCIe 可用的是 4350/4350c2/4356/4358/43570/43602/4366b/4366c）
fw_blob_summary=""
for blob in brcmfmac4350-pcie.bin brcmfmac4356-pcie.bin brcmfmac4358-pcie.bin \
            brcmfmac4366b-pcie.bin brcmfmac4366c-pcie.bin \
            rtl8723a_fw.bin rtl8723befw.bin rtl8723bs_fw.bin; do
    # find -quit 会让上游管道出 SIGPIPE，这里直接取结果判断
    if [ -n "$(find "$TARGET/lib/firmware" -name "$blob" -print -quit 2>/dev/null)" ]; then
        fw_blob_summary="$fw_blob_summary $blob:ok"
    else
        fw_blob_summary="$fw_blob_summary $blob:-"
    fi
done

mkdir -p "$TARGET/usr/local/share/qm1"
MANIFEST="$TARGET/usr/local/share/qm1/driver-manifest.txt"
{
    echo "# QM1 驱动清单（生成于 rootfs 构建期，arch=$ARCH profile=$PROFILE kernel=$KVER）"
    echo "# 字段：模块名 状态( module/builtin/absent ) 服务的硬件"
    echo ""
    echo "--- 期望驱动与实际状态 ---"
    printf '%s\n' "$DRIVER_TABLE" | while IFS='|' read -r m sym hw crit; do
        [ -n "$m" ] || continue
        st="$(driver_state "$m" "$sym")"
        mark=""
        [ "$crit" = "critical" ] && mark=" [启动关键]"
        printf '%-26s %-8s %s%s\n' "$m" "$st" "$hw" "$mark"
    done
    echo ""
    echo "--- firmware blob 核对 ---"
    echo "$fw_blob_summary"
    echo "--- 已装 firmware 包 ---"
    echo "installed:${installed_fw:-none}"
    echo "missing:${missing_fw:-none}"
} > "$MANIFEST"

# 关键驱动判定：module 或 builtin 都算有，只有 absent 才致命
for m in $CRITICAL_MODULES; do
    st="$(driver_state "$m" "")"
    case "$st" in
        module|builtin) : ;;
        *) missing_critical="$missing_critical $m" ;;
    esac
done

log "驱动清单：$MANIFEST"
if [ -n "$missing_critical" ]; then
    die "启动关键驱动缺失：$missing_critical —— 这会让 QM1 认不到 eMMC/ESP，插电也起不来"
fi
log "启动关键驱动齐全：$CRITICAL_MODULES"
log "完成"
