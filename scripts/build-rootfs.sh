#!/usr/bin/env bash
# build-rootfs.sh — 用 debootstrap 生成 QM1 的 Debian 13 根文件系统
#
# 目标机器：ASUS QM1-B002（Intel Atom Z3735F / Bay Trail / 2GB RAM / 32GB eMMC）
# 底座选择：Debian 13 (trixie) amd64 —— 与 Hermes 官方镜像同一用户层；
#           trixie 的 amd64 基线为 x86-64-v2，Bay Trail（无 AVX）恰好达标。
#
# 用法（需要 root，debootstrap 必须 chroot）：
#   sudo bash scripts/build-rootfs.sh --out build/rootfs
#   sudo bash scripts/build-rootfs.sh --out build/rootfs --profile runtime
#
# 选项：
#   --suite trixie            Debian 发行代号（默认 trixie）
#   --arch  amd64|i386       目标架构（默认 amd64；i386 仅作救援兜底）
#   --out  DIR               输出目录（默认 build/rootfs）
#   --profile base|runtime   base=最小可运行系统；runtime=追加浏览器等 agent 运行时依赖
#   --extra-pkgs "a b c"     追加软件包
#   --no-drivers             跳过 install-drivers.sh（驱动预置）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SUITE="trixie"
ARCH="amd64"
OUT="build/rootfs"
PROFILE="base"
EXTRA_PKGS=""
RUN_DRIVERS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --suite) SUITE="$2"; shift 2 ;;
        --arch)  ARCH="$2";  shift 2 ;;
        --out)   OUT="$2";   shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --extra-pkgs) EXTRA_PKGS="$2"; shift 2 ;;
        --no-drivers) RUN_DRIVERS=0; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

require_root
need_cmd debootstrap "apt install debootstrap"
need_cmd wget "apt install wget（debootstrap 内部用 wget 取 InRelease，缺它会报 unknown location）"
need_cmd mount

# debootstrap 内部会 cd 进目标目录，相对路径会失败（"can't cd to build"）→ 一律转绝对路径
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

case "$ARCH" in
    amd64|i386) ;;
    *) die "仅支持 amd64 / i386（i386 仅作救援兜底，不能承载现代 agent 运行时）" ;;
esac

# ---------- 包清单 ----------
# base：最小可运行 + 远程运维 + agent 运行时所需的基础库
BASE_PKGS=(
    systemd-sysv systemd-resolved systemd-oomd dbus
    openssh-server sudo
    ca-certificates curl wget git gnupg apt-utils
    locales tzdata less file
    iproute2 iputils-ping ethtool dnsutils procps psmisc
    rsync xz-utils zstd bzip2 tar
    pciutils usbutils lm-sensors alsa-utils
    bluez wpasupplicant
    mmc-utils dosfstools e2fsprogs zram-tools
    python3 python3-venv
    ripgrep
)
# runtime：headless Chrome + 字体 + 常见运行库（Chromium 依赖会自动带入）
RUNTIME_PKGS=(
    chromium
    fonts-liberation fonts-noto-cjk
    libnss3 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 libgbm1
    libasound2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3
    libxrandr2 libpango-1.0-0 libcairo2
)
if [ "$ARCH" = "i386" ]; then
    RUNTIME_PKGS=()   # 32 位变体不装浏览器与 agent 运行时
fi

PKGS=("${BASE_PKGS[@]}")
if [ "$PROFILE" = "runtime" ]; then
    PKGS+=("${RUNTIME_PKGS[@]}")
elif [ "$PROFILE" != "base" ]; then
    die "--profile 只支持 base / runtime（收到：$PROFILE）"
fi
if [ -n "$EXTRA_PKGS" ]; then
    # shellcheck disable=SC2206
    PKGS+=($EXTRA_PKGS)
fi

# ---------- 1. debootstrap ----------
if [ -e "$OUT" ]; then
    die "输出目录已存在：$OUT（请先删除，避免半成品混用）"
fi
log "debootstrap $SUITE/$ARCH → $OUT（profile=$PROFILE）"

COMPONENTS="main,non-free-firmware"
if ! debootstrap --variant=minbase --components="$COMPONENTS" "$SUITE" "$OUT" "$ARCH"; then
    warn "带 non-free-firmware 组件的 debootstrap 失败，退回仅 main 组件"
    warn "（此时 firmware-brcm80211 / firmware-realtek 等 firmware 包不可用，Wi-Fi 需另行处理）"
    rm -rf "$OUT"
    debootstrap --variant=minbase --components=main "$SUITE" "$OUT" "$ARCH"
fi

cleanup() {
    log "清理 chroot 挂载点"
    umount -R "$OUT/dev/pts" 2>/dev/null || true
    umount "$OUT/dev" 2>/dev/null || true
    umount "$OUT/sys"  2>/dev/null || true
    umount "$OUT/proc" 2>/dev/null || true
    rm -f "$OUT/resolv.conf"
}
trap cleanup EXIT

# ---------- 2. chroot 环境 ----------
cp -L /etc/resolv.conf "$OUT/resolv.conf"
mount -t proc proc "$OUT/proc"
mount --rbind /sys "$OUT/sys"
mount --rbind /dev "$OUT/dev"
mount -t devpts devpts "$OUT/dev/pts"

printf '%s\n' "$SUITE" > "$OUT/etc/debian_version"

# ---------- 3. 基础配置 ----------
log "配置 locale / 时区 / 主机名"
in_chroot "$OUT" apt-get update -qq
in_chroot "$OUT" apt-get install -y -qq --no-install-recommends locales tzdata
printf 'en_US.UTF-8 UTF-8\n' > "$OUT/etc/locale.gen"
in_chroot "$OUT" locale-gen
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$OUT/etc/localtime"
echo "qm1" > "$OUT/etc/hostname"

log "安装基础包（${#PKGS[@]} 个）"
in_chroot "$OUT" apt-get install -y -qq --no-install-recommends "${PKGS[@]}"

# 精简：关掉用不上的常驻服务，减小内存与 eMMC 写入
log "关闭用不上的服务"
for svc in systemd-resolved avahi-daemon bluetooth systemd-timesyncd; do
    in_chroot "$OUT" systemctl disable "$svc" >/dev/null 2>&1 || true
done
in_chroot "$OUT" systemctl enable ssh >/dev/null 2>&1 || true
in_chroot "$OUT" systemctl enable systemd-oomd >/dev/null 2>&1 || true
# 首次启动不要等硬件随机数池（有 rngd 更好，但本机无 TPM/urandomd 时用 haveged 亦可；此处仅缩短超时）
mkdir -p "$OUT/etc/systemd/system.conf.d"
printf '[Service]\nTimeoutStartSec=30s\n' > "$OUT/etc/systemd/system.conf.d/quick-boot.conf"

# ---------- 4. 驱动与 firmware 预置 ----------
if [ "$RUN_DRIVERS" = "1" ]; then
    log "预置驱动与 firmware（install-drivers.sh）"
    # 把脚本复制进 chroot 后执行（chroot 内没有宿主脚本路径）
    cp "$SCRIPT_DIR/install-drivers.sh" "$OUT/tmp/install-drivers.sh"
    chmod +x "$OUT/tmp/install-drivers.sh"
    in_chroot "$OUT" /tmp/install-drivers.sh --arch "$ARCH" --profile "$PROFILE"
    rm -f "$OUT/tmp/install-drivers.sh"
fi

# ---------- 5. overlay 定制层 ----------
log "应用 overlay 定制层"
cp -a "$SCRIPT_DIR/../overlay/." "$OUT/"

# 设备端自检脚本（overlay 的 /usr/local/bin/qm1-selftest 依赖此路径）
mkdir -p "$OUT/usr/local/lib/qm1"
cp "$SCRIPT_DIR/drv-selfcheck.sh" "$OUT/usr/local/lib/qm1/drv-selfcheck.sh"
chmod 0755 "$OUT/usr/local/lib/qm1/drv-selfcheck.sh" "$OUT/usr/local/bin/qm1-selftest"

# ---------- 6. 收尾 ----------
log "清理 apt 缓存与文档"
in_chroot "$OUT" apt-get clean
rm -rf "$OUT/usr/share/doc"/* "$OUT/usr/share/man"/* "$OUT/usr/share/info"/* 2>/dev/null || true
rm -rf "$OUT/var/lib/apt/lists/"*
rm -f "$OUT/etc/machine-id"
: > "$OUT/var/lib/dbus/machine-id" 2>/dev/null || true

log "生成清单"
MANIFEST="${OUT%/}.manifest.txt"
{
    echo "# qm1-debian rootfs manifest"
    echo "suite=$SUITE arch=$ARCH profile=$PROFILE"
    echo "kernel=$(ls "$OUT/lib/modules" 2>/dev/null | tr '\n' ' ')"
    echo "--- packages ---"
    chroot "$OUT" dpkg-query -W -f='${Package}=${Version}\n' 2>/dev/null | sort || true
} > "$MANIFEST"
log "清单：$MANIFEST"
log "完成：根文件系统位于 $OUT"
