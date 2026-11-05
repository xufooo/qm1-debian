#!/bin/sh
# ============================================================================
# customize02-drivers.sh — mmdebstrap customize hook：QM1 硬件驱动与固件预置
# ============================================================================
# 对应"把硬件驱动都带上，保证硬件能够启动"：
#   1) 内核自带（in-tree）：eMMC/SD、USB、显卡 i915、Intel HDA、蓝牙、RTC、ACPI/电源
#   2) 需 firmware（只读固件 blob）：Wi-Fi/BT 芯片、Intel 微码
#      —— 在 Debian 13 里位于 non-free-firmware 组件，mmdebstrap 必须带上该组件
#   3) 需 out-of-tree（DKMS）：Realtek RTL8723AU/8812AU/8812BU 等 USB 无线芯片
#      —— 主线无驱动；构建期不内置源码，可用 QM1_DKMS_DEB_DIR 传入自编译的 .deb
#
# QM1 内置无线（已实测确认）：Realtek RTL8723BS，SDIO 模组（AzureWave），
#   SDIO ID 0x024c:0xb723。Debian 13 的 6.12 与 bookworm 的 6.1 都自带主线
#   staging 驱动 r8723bs（CONFIG_RTL8723BS=m），固件为 rtl8723bs_nic.bin
#   （firmware-realtek 提供）→ 内置 Wi-Fi **不需要 DKMS**。
#   注意 rtl8723bs_fw.bin 是蓝牙固件（rtl_bt/），不是 Wi-Fi blob。
#
# 内核版本：默认跟发行版元包（linux-image-amd64）滚动；也可以用
#   --kernel-version 6.12.113 钉死某个 point release（本 hook 负责精确安装）。
#   钉死的原因是 rtl8723bs 的几项安全修复从 6.12.111 才回移进 6.12.y，
#   而 Debian 13 当前元包给的是 6.12.107-1 —— 少了那批修复。
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
#
# 固定内核 point release（可选，QM1_KERNEL_VERSION 非空时启用）：
#   发行版元包（linux-image-amd64）跟着发行版滚动 —— Debian 13 当前给的是
#   6.12.107-1，而 rtl8723bs 的几项安全修复（kfree_sensitive、WMM_param_handler
#   越界读、监控帧长度校验）是从 6.12.111 才回移进 6.12.y 的。
#   固定版本时：
#     * 不装元包（否则 /lib/modules 会出现两个版本，initramfs/GRUB 都要挑，容易装错）；
#     * 由本 hook 临时挂 <suite>-proposed-updates 源，精确安装
#       linux-image-<ABI>-unsigned，装完立即撤掉临时源；
#     * 装不上 → die，绝不静默回退到元包（静默回退 = 镜像里又少了那批修复）。
case "$ARCH" in
    amd64) KERNEL_PKGS="linux-image-amd64 linux-headers-amd64" ;;
    i386)  die "32 位系统变体已取消（QM1 是 64 位 CPU）；引导器仍保留 IA32 版本" ;;
    *) die "不支持的架构：$ARCH" ;;
esac

# hook 拿不到仓库路径（不能 source scripts/lib/common.sh），
# 下面这两份实现与 common.sh 里的 kernel_abi_name / normalize_kernel_version 等价，
# 改一处必须同步改另一处。

# Debian 内核 ABI 后缀：Debian 13 (trixie) → deb13，Debian 12 (bookworm) → deb12
kernel_abi_suffix() {
    case "$1" in
        bookworm) printf 'deb12\n' ;;
        *)        printf 'deb13\n' ;;
    esac
}

# point release（6.12.113）→ Debian 内核 ABI 名（6.12.113+deb13-amd64）
kernel_abi_name() {
    printf '%s+%s-%s\n' "${1%%+*}" "$(kernel_abi_suffix "$2")" "$3"
}

# 探测发行版代号：优先用 build-rootfs.sh 导出的 QM1_SUITE，
# 否则从 chroot 的 /etc/os-release 读 VERSION_CODENAME
detect_suite() {
    if [ -n "${QM1_SUITE:-}" ]; then
        printf '%s\n' "$QM1_SUITE"
        return 0
    fi
    if [ -f "$TARGET/etc/os-release" ]; then
        sed -n 's/^VERSION_CODENAME=//p' "$TARGET/etc/os-release" | tr -d '"' | sed -n '1p'
    fi
}

# 精确安装固定内核；成功返回 0，失败直接 die（不做任何回退）
install_pinned_kernel() {
    _abi="$1"
    _suite="$2"
    _mirror="${QM1_MIRROR:-http://deb.debian.org/debian}"
    _src="$TARGET/etc/apt/sources.list.d/qm1-pinned-kernel.list"

    mkdir -p "$TARGET/etc/apt/sources.list.d"
    {
        for _comp in "${_suite}-proposed-updates" "${_suite}-updates"; do
            printf 'deb %s %s main\n' "$_mirror" "$_comp"
        done
    } > "$_src"
    log "临时挂源：${_suite}-proposed-updates / ${_suite}-updates（装完即撤）"

    if ! chroot "$TARGET" apt-get update -qq; then
        rm -f "$_src"
        die "apt-get update 失败（临时源 ${_suite}-proposed-updates）"
    fi

    # 装 -unsigned 变体：signed 变体（linux-image-<ABI>）会拉 grub-efi-amd64-signed，
    # 和本项目自带的 BOOTIA32/BOOTX64 双引导器抢 EFI 目录。
    if ! chroot "$TARGET" apt-cache show "linux-image-${_abi}-unsigned" >/dev/null 2>&1; then
        rm -f "$_src"
        die "源 ${_suite}-proposed-updates 里没有 linux-image-${_abi}-unsigned —— 固定内核不可用"
    fi

    if chroot "$TARGET" apt-get install -y -qq --no-install-recommends "linux-image-${_abi}-unsigned"; then
        rm -f "$_src"
        log "已安装固定内核：linux-image-${_abi}-unsigned"
    else
        rm -f "$_src"
        die "固定内核 ${_abi} 安装失败（已尝试 ${_suite}-proposed-updates）—— 拒绝静默回退到发行版元包"
    fi

    [ -d "$TARGET/lib/modules/$_abi" ] \
        || die "固定内核装完但 $TARGET/lib/modules/$_abi 不存在，镜像不可用"

    # 镜像里只应有一个内核版本：多个会让 initramfs/GRUB 挑错
    _others=""
    for _d in "$TARGET"/lib/modules/*; do
        [ -e "$_d" ] || continue
        _bn="$(basename "$_d")"
        if [ "$_bn" != "$_abi" ]; then
            _others="$_others $_bn"
        fi
    done
    if [ -n "$_others" ]; then
        warn "镜像里还存在其他内核版本：$_others（固定内核模式下不应出现）"
    fi
}

PINNED_KERNEL_ABI=""
if [ -n "${QM1_KERNEL_VERSION:-}" ]; then
    [ "$ARCH" = "amd64" ] || die "固定内核版本只支持 amd64（$ARCH 没有 trixie 内核，也没有对应的 point release）"
    SUITE_CODENAME="$(detect_suite)"
    [ -n "$SUITE_CODENAME" ] \
        || die "无法确定发行版代号（QM1_SUITE 未设置，/etc/os-release 也没有 VERSION_CODENAME）"
    PINNED_KERNEL_ABI="$(kernel_abi_name "$QM1_KERNEL_VERSION" "$SUITE_CODENAME" amd64)"
    log "固定内核 point release：$QM1_KERNEL_VERSION → ABI $PINNED_KERNEL_ABI（不装元包）"
    # 固定版本时装元包会把发行版当前内核一起拉进来，/lib/modules 出现两个版本
    KERNEL_PKGS=""
    install_pinned_kernel "$PINNED_KERNEL_ABI" "$SUITE_CODENAME"
fi

if [ -n "$KERNEL_PKGS" ]; then
    log "安装内核：$KERNEL_PKGS"
    # shellcheck disable=SC2086
    chroot "$TARGET" apt-get install -y -qq --no-install-recommends $KERNEL_PKGS
fi

# ---------- 2. firmware（尽力而为，缺包只告警） ----------
FIRMWARE_PKGS="firmware-linux-free firmware-brcm80211 firmware-realtek firmware-mediatek firmware-atheros firmware-iwlwifi intel-microcode"
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
# 内置 Realtek RTL8723BS（SDIO）。通常 udev 也能按 modalias 自动加载，
# 显式列出是为了在 SDIO 枚举晚于模块加载时仍能接管。
# 注意：装了就打了补丁的 r8723bs_qm1 时，这个条目要改成 r8723bs_qm1 ——
# 树内 r8723bs 会被 /etc/modprobe.d/qm1-rtl8723bs.conf 里的 blacklist 挡住。
r8723bs
EOF

# ---------- 4b. 打了补丁的 RTL8723BS 外部模块（可选） ----------
# QM1_WIFI_MODULE_DEB 指向一个本地 .deb（由 scripts/build-rtl8723bs-module.sh
# 或 .github/workflows/build-wifi-module.yml 针对同一内核 ABI 产出）。
# 装它 = 用打了 P1–P5 补丁的 r8723bs_qm1 取代发行版树内 r8723bs：
#   * 树内 staging 驱动有 4 条永久卡死路径（丢一次 SDIO 中断即可能永久断流）；
#   * 模块自带 /etc/modprobe.d/qm1-rtl8723bs.conf：
#     blacklist r8723bs + options r8723bs_qm1 rtw_power_mgnt=0 rtw_ips_mode=0
#     rtw_smart_ps=0 rtw_bw_mode=0（关省电 + 20MHz）；
#   * 模块的 vermagic 写死了目标内核版本，和镜像内核对不上就装不了 ——
#     所以这里必须核对，不一致直接失败。
if [ -n "${QM1_WIFI_MODULE_DEB:-}" ] && [ -f "$QM1_WIFI_MODULE_DEB" ]; then
    _img_kver="$(ls -1 "$TARGET/lib/modules" 2>/dev/null | sort -V | tail -1)"
    [ -n "$_img_kver" ] || die "镜像里没有 /lib/modules，无法核对 Wi-Fi 模块的 vermagic"
    _deb_name="$(basename "$QM1_WIFI_MODULE_DEB")"
    log "安装打了补丁的 Wi-Fi 模块：$_deb_name（镜像内核 $_img_kver）"
    cp "$QM1_WIFI_MODULE_DEB" "$TARGET/tmp/$_deb_name"
    if ! chroot "$TARGET" apt-get install -y -qq "/tmp/$_deb_name"; then
        rm -f "$TARGET/tmp/$_deb_name"
        die "Wi-Fi 模块 deb 安装失败：$_deb_name"
    fi
    rm -f "$TARGET/tmp/$_deb_name"
    # vermagic 必须与镜像内核一致，否则模块根本加载不了。
    # 注意 modinfo 必须带 -k <版本>：chroot 里的 uname -r 是**构建机**的内核版本
    # （CI 容器 / 宿主），不是镜像里的内核，不指定就会去错目录里找模块。
    _ko="$TARGET/lib/modules/$_img_kver/extra/rtl8723bs/r8723bs_qm1.ko"
    [ -f "$_ko" ] || die "装完 deb 但镜像里没有 $_ko（模块包布局不对）"
    _vm="$(chroot "$TARGET" modinfo -k "$_img_kver" -F vermagic r8723bs_qm1 2>/dev/null | awk '{print $1}')"
    if [ -z "$_vm" ]; then
        # 兜底：直接从 .ko 的 .modinfo 段里读（不依赖 chroot 里的 modinfo）
        _vm="$(grep -ao 'vermagic=[^ ]*' "$_ko" 2>/dev/null | head -1 | cut -d= -f2)"
    fi
    if [ -z "$_vm" ]; then
        die "装完 deb 仍读不到 r8723bs_qm1 的 vermagic（模块名或 .modinfo 不对）"
    fi
    case "$_vm" in
        "$_img_kver"*) : ;;
        *) die "Wi-Fi 模块 vermagic（$_vm）与镜像内核（$_img_kver）不匹配 —— 必须用同一内核版本重编模块" ;;
    esac
    log "Wi-Fi 模块 vermagic：$_vm（与镜像内核一致）"
    # modules-load.d 里要改成加载打了补丁的那个
    sed -i 's/^r8723bs$/r8723bs_qm1/' "$TARGET/etc/modules-load.d/qm1-hardware.conf"
    WIFI_MODULE_STATE="installed:$_deb_name"
else
    if [ -n "${QM1_WIFI_MODULE_DEB:-}" ]; then
        die "QM1_WIFI_MODULE_DEB 指向的文件不存在：$QM1_WIFI_MODULE_DEB"
    fi
    warn "未提供 QM1_WIFI_MODULE_DEB：镜像里用的是发行版树内 r8723bs（存在永久卡死路径）"
    WIFI_MODULE_STATE="absent"
fi

# ---------- 4c. rtw88 RTL8723BS 回移模块（推荐路径，优先于 4b） ----------
# QM1_RTW88_MODULE_DEB 指向 scripts/build-rtw88-8723bs-module.sh 产出的 .deb：
# 把上游 rtw88 的 RTL8723B / RTL8723BS 支持（Linux 7.4 合并窗口，主线提交
# d726c70ce082 / 269946cba92e / b2d251aa7f16）按镜像内核回移成树外模块，
# 连同 rtw88/rtw8723b_fw.bin 固件一起装进镜像。
# 这是对 staging r8723bs 永久卡死路径的根治 —— 上游干脆删掉了 staging 驱动。
# 与 4b 的补丁模块二选一：rtw88 优先，装了 rtw88 就不装补丁 staging 模块。
if [ -n "${QM1_RTW88_MODULE_DEB:-}" ] && [ -f "$QM1_RTW88_MODULE_DEB" ]; then
    _img_kver="$(ls -1 "$TARGET/lib/modules" 2>/dev/null | sort -V | tail -1)"
    [ -n "$_img_kver" ] || die "镜像里没有 /lib/modules，无法核对 rtw88 模块的 vermagic"
    _deb_name="$(basename "$QM1_RTW88_MODULE_DEB")"
    log "安装 rtw88 回移模块：$_deb_name（镜像内核 $_img_kver）"
    cp "$QM1_RTW88_MODULE_DEB" "$TARGET/tmp/$_deb_name"
    if ! chroot "$TARGET" apt-get install -y -qq "/tmp/$_deb_name"; then
        rm -f "$TARGET/tmp/$_deb_name"
        die "rtw88 模块 deb 安装失败：$_deb_name"
    fi
    rm -f "$TARGET/tmp/$_deb_name"
    # 刷新模块索引：树外模块装在 extra/ 下，模块名要能被 modprobe 解析出来。
    chroot "$TARGET" depmod -a || warn "depmod -a 失败，模块索引可能不完整"
    # 模块名有三种：上游整树回移是 rtw88_qm1（单模块），上游芯片回移是
    # rtw88_8723bs，vendor 树是 rtw_8723bs。
    #
    # 注意：这里不能用 `chroot ... modinfo -k <ver> <名字>` 来找模块 ——
    # kmod 的 modinfo 只查内核的标准模块目录，查不到我们放在 extra/ 下的
    # 树外模块（实测在 CI 里就是因此误判成「模块没装上」）。
    # 所以按文件路径找，模块名取文件名；vermagic 直接从 .ko 里读。
    _sdio_mod=""
    _sdio_ko=""
    for _cand in rtw88_qm1 rtw88_8723bs rtw_8723bs; do
        if [ -f "$TARGET/lib/modules/$_img_kver/extra/rtw88/$_cand.ko" ]; then
            _sdio_mod="$_cand"
            _sdio_ko="$TARGET/lib/modules/$_img_kver/extra/rtw88/$_cand.ko"
            break
        fi
    done
    [ -n "$_sdio_mod" ] || die "装完 deb 但镜像里没有 rtw88_qm1 / rtw88_8723bs / rtw_8723bs 模块"
    _vm="$(modinfo -F vermagic "$_sdio_ko" 2>/dev/null | awk '{print $1}')"
    if [ -z "$_vm" ]; then
        # 兜底：直接从 .ko 的 .modinfo 段里读
        _vm="$(grep -ao 'vermagic=[^ ]*' "$_sdio_ko" 2>/dev/null | head -1 | cut -d= -f2)"
    fi
    [ -n "$_vm" ] || die "读不到 rtw88 模块的 vermagic（$_sdio_ko）"
    case "$_vm" in
        "$_img_kver"*) : ;;
        *) die "rtw88 模块 vermagic（$_vm）与镜像内核（$_img_kver）不匹配 —— 必须用同一内核版本重编模块" ;;
    esac
    [ -f "$TARGET/lib/firmware/rtw88/rtw8723b_fw.bin" ] \
        || die "rtw88 固件 rtw88/rtw8723b_fw.bin 缺失（Debian 13 的 firmware-realtek 不含该 blob）"
    log "rtw88 模块：$_sdio_mod（vermagic $_vm，与镜像内核一致）"
    # modules-load.d：换成回移模块，去掉 staging 驱动与补丁 staging 模块
    sed -i -E '/^r8723bs(_qm1)?$/d' "$TARGET/etc/modules-load.d/qm1-hardware.conf"
    printf '%s\n' "$_sdio_mod" >> "$TARGET/etc/modules-load.d/qm1-hardware.conf"
    RTW88_MODULE_STATE="installed:$_sdio_mod:$_deb_name"
else
    if [ -n "${QM1_RTW88_MODULE_DEB:-}" ]; then
        die "QM1_RTW88_MODULE_DEB 指向的文件不存在：$QM1_RTW88_MODULE_DEB"
    fi
    warn "未提供 QM1_RTW88_MODULE_DEB：镜像里没有 rtw88 回移模块，Wi-Fi 仍靠有永久卡死路径的 staging 驱动"
    RTW88_MODULE_STATE="absent"
fi

# ---------- 4d. 蓝牙：RTL8723BS 的 BT 部分（ACPI UART + 厂商固件下发） ----------
# QM1 的蓝牙是 combo 芯片的 BT 部分，经 **ACPI 枚举的 UART** 挂在主机上
# （ASUS 官方 Win8 驱动 rtkuart.inf：ACPI\VEN_OBDA&DEV_8723 / 0623）。
# Linux 主线没有 Realtek UART HCI 驱动，缺的是「把厂商固件刷进芯片并初始化」
# 这一步 —— 由用户态 rtk_hciattach（lwfinger/rtl8723bs_bt）完成，
# 之后内核 btuart（CONFIG_BT_HCIUART）接手同一个串口。
# QM1_BT_HCIATTACH_DEB 指向 scripts/build-bt-hciattach.sh 产出的 .deb。
if [ -n "${QM1_BT_HCIATTACH_DEB:-}" ] && [ -f "$QM1_BT_HCIATTACH_DEB" ]; then
    _bt_deb_name="$(basename "$QM1_BT_HCIATTACH_DEB")"
    log "安装蓝牙厂商初始化包：$_bt_deb_name"
    cp "$QM1_BT_HCIATTACH_DEB" "$TARGET/tmp/$_bt_deb_name"
    if ! chroot "$TARGET" apt-get install -y -qq "/tmp/$_bt_deb_name"; then
        rm -f "$TARGET/tmp/$_bt_deb_name"
        die "蓝牙包安装失败：$_bt_deb_name"
    fi
    rm -f "$TARGET/tmp/$_bt_deb_name"
    [ -x "$TARGET/usr/sbin/rtk_hciattach" ] \
        || die "装完 deb 但镜像里没有 /usr/sbin/rtk_hciattach"
    for _bt_fw in rtlbt_fw rtlbt_config; do
        [ -f "$TARGET/lib/firmware/rtl_bt/$_bt_fw" ] || die "蓝牙固件 $_bt_fw 缺失"
    done
    _bt_kver="$(ls -1 "$TARGET/lib/modules" 2>/dev/null | sort -V | tail -1)"
    if [ -n "$_bt_kver" ] && [ -f "$TARGET/boot/config-$_bt_kver" ]; then
        # Debian 13 的内核（6.12.113+deb13-amd64）实测：CONFIG_BT=m、
        # CONFIG_BT_HCIUART=m —— hci_uart 是**模块**（Linux 6.x：hci_uart.ko），
        # 不是编进内核。所以两种配置都要接受，=m 时要确认模块文件在镜像里。
        if grep -qE '^CONFIG_BT_HCIUART=y$' "$TARGET/boot/config-$_bt_kver"; then
            log "内核 btuart：编进内核（CONFIG_BT_HCIUART=y）"
        elif grep -qE '^CONFIG_BT_HCIUART=m$' "$TARGET/boot/config-$_bt_kver"; then
            # Linux 6.x 里这个模块叫 hci_uart.ko（早期内核才叫 bt_hciuart.ko）
            if find "$TARGET/lib/modules/$_bt_kver" \( -name 'hci_uart.ko*' -o -name 'bt_hciuart.ko*' \) \
                 -print -quit 2>/dev/null | grep -q .; then
                log "内核 btuart：模块 hci_uart.ko（CONFIG_BT_HCIUART=m），随包加载"
            else
                warn "内核 CONFIG_BT_HCIUART=m，但镜像里找不到 hci_uart.ko —— 厂商固件下发后没人接手串口"
            fi
        else
            warn "内核没有 CONFIG_BT_HCIUART —— 厂商固件下发后蓝牙控制器不会被内核接管"
        fi
    fi
    # 开机自启（用符号链接，避免在 chroot 里跑 systemctl 的副作用）
    mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/qm1-bluetooth.service \
        "$TARGET/etc/systemd/system/multi-user.target.wants/qm1-bluetooth.service"
    BT_HCIATTACH_STATE="installed:rtk_hciattach:$_bt_deb_name"
else
    if [ -n "${QM1_BT_HCIATTACH_DEB:-}" ]; then
        die "QM1_BT_HCIATTACH_DEB 指向的文件不存在：$QM1_BT_HCIATTACH_DEB"
    fi
    warn "未提供 QM1_BT_HCIATTACH_DEB：镜像里没有 rtk_hciattach，内置蓝牙（ACPI UART）不可用"
    BT_HCIATTACH_STATE="absent"
fi

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
    warn "未提供 QM1_DKMS_DEB_DIR：Realtek 8723AU/8812AU/8812BU 等无主线驱动的 USB 无线芯片未被覆盖"
    warn "（QM1 内置的 RTL8723BS 不在此列：Debian 13 / 12 自带 staging 驱动 r8723bs，无需 DKMS）"
    warn "对策：改用 USB 以太网适配器（推荐），或自行编译对应 DKMS 驱动后重装本步骤"
fi

# ---------- 6. 驱动清单（供 drv-selfcheck.sh 与 CI 断言） ----------
KVER="$(ls -1 "$TARGET/lib/modules" 2>/dev/null | sort -V | tail -1)"
[ -n "$KVER" ] || die "镜像内没有 /lib/modules 目录（内核包安装失败？）"
log "镜像内核版本：$KVER"

KCFG="$TARGET/boot/config-$KVER"
[ -f "$KCFG" ] || warn "没有 $KCFG（内核 config 缺失，驱动状态只能靠 modinfo 判定）"

# 关键内核 config 基线核对（Debian 13 / 6.12.113 实测值，随镜像记录进清单）
#   CONFIG_IOSF_MBI=y          —— Bay Trail 的 sdhci-acpi 挂死修复（上游 6e1c7d6103fe）
#                                  真正生效的前提；没有它，eMMC/SD 挂死修复等于没打
#   CONFIG_X86_INTEL_PSTATE=y  —— intel_pstate 编进内核（Silvermont 支持 5 档 P-state）
#   CONFIG_X86_ACPI_CPUFREQ=m  —— acpi-cpufreq 作为备选频率驱动
#   CONFIG_PINCTRL_BAYTRAIL=y  —— Bay Trail-T 上可能导致 /dev/rtc0 不出现（已知取舍）
KCFG_SUMMARY=""
for _sym in CONFIG_IOSF_MBI CONFIG_X86_INTEL_PSTATE CONFIG_X86_ACPI_CPUFREQ \
            CONFIG_PINCTRL_BAYTRAIL CONFIG_MMC_SDHCI_ACPI CONFIG_BT_HCIUART; do
    if [ -f "$KCFG" ]; then
        _val="$(grep -E "^${_sym}=" "$KCFG" 2>/dev/null | head -1 | cut -d= -f2)"
        [ -n "$_val" ] || _val="unset"
    else
        _val="no-config"
    fi
    KCFG_SUMMARY="$KCFG_SUMMARY $_sym=$_val"
done
log "内核 config 基线：$KCFG_SUMMARY"
if [ -f "$KCFG" ] && ! grep -qE '^CONFIG_IOSF_MBI=y$' "$KCFG"; then
    warn "CONFIG_IOSF_MBI 不是 y —— Bay Trail 的 sdhci-acpi 挂死修复（6e1c7d6103fe）不会生效"
fi

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
btuart|BT_HCIUART|蓝牙 UART 控制器（内置 RTL8723BS 的 BT 口，内核模块 hci_uart，Debian 为 =m）|
r8723bs|RTL8723BS|Realtek RTL8723BS SDIO Wi-Fi（内置，主线 staging 驱动）|
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
            rtl8723a_fw.bin rtl8723befw.bin \
            rtl8723bs_nic.bin mt7610u.bin mt7601u.bin; do
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
    echo "--- 内核 config 关键项 ---"
    echo "$KCFG_SUMMARY"
    echo "--- 已装 firmware 包 ---"
    echo "installed:${installed_fw:-none}"
    echo "missing:${missing_fw:-none}"
    echo "--- Wi-Fi 模块 ---"
    echo "${WIFI_MODULE_STATE:-absent}"
    echo "--- rtw88 回移模块 ---"
    echo "${RTW88_MODULE_STATE:-absent}"
    echo "--- 蓝牙厂商初始化包（rtk_hciattach） ---"
    echo "${BT_HCIATTACH_STATE:-absent}"
    if [ -n "${QM1_BT_HCIATTACH_DEB:-}" ] && [ -f "$QM1_BT_HCIATTACH_DEB" ]; then
        for _bt_blob in rtlbt_fw rtlbt_config rtlbt_fw_new; do
            if [ -f "$TARGET/lib/firmware/rtl_bt/$_bt_blob" ]; then
                echo "bt_firmware_$_bt_blob=ok"
            else
                echo "bt_firmware_$_bt_blob=-"
            fi
        done
    fi
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
