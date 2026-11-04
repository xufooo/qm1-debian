#!/usr/bin/env bash
# build-rootfs.sh — 用 mmdebstrap 构建 QM1 的 Debian 13 根文件系统
#
# 为什么用 mmdebstrap 而不是 debootstrap：
#   * mmdebstrap 直接产出 tar，不依赖 debootstrap 那套 chroot 挂载/清理，
#     也就不会出现"构建期挂进 /dev /proc /sys 的伪文件系统残留进镜像"的问题；
#   * 定制步骤全部放进 hooks/ 目录（customizeNN.sh），语义清晰、可单独 dry-run；
#   * 支持 --format=tar，镜像构建阶段可以像 ZYBO 那样
#     "解包 + mke2fs -d" 一次完成，避免逐个文件复制导致的权限漂移。
#
# 用法：
#   bash scripts/build-rootfs.sh --out build/rootfs --arch amd64 --profile runtime
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT="build/rootfs"
ARCH="amd64"
PROFILE="base"
SUITE="trixie"
MIRROR="http://deb.debian.org/debian"
COMPONENTS="main,non-free-firmware"
HOOKS_DIR="$REPO_ROOT/hooks"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --components) COMPONENTS="$2"; shift 2 ;;
        --hooks) HOOKS_DIR="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

need_cmd mmdebstrap "apt install mmdebstrap"
[ -d "$HOOKS_DIR" ] || die "hooks 目录不存在：$HOOKS_DIR"

# 目标目录必须是绝对路径（mmdebstrap 的 TARGET 参数）
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -rf "$OUT"
mkdir -p "$OUT"

# ---------- 包清单 ----------
# 基础系统：systemd + 网络 + SSH + 无线 + 存储工具 + agent 运行时前置
BASE_PKGS="systemd,systemd-sysv,systemd-resolved,systemd-oomd,openssh-server,sudo,\
curl,wget,ca-certificates,git,iproute2,iputils-ping,net-tools,pciutils,usbutils,\
lm-sensors,alsa-utils,bluez,wpasupplicant,iw,rfkill,wireless-regdb,mmc-utils,\
dosfstools,e2fsprogs,zram-tools,python3,python3-venv,ripgrep,locales,tzdata,\
kmod,initramfs-tools,apt-transport-https"

# 运行时（Hermes CLI + headless Chrome）：Chromium 只有 amd64/arm64，32 位变体装不了
RUNTIME_PKGS_AMD64="chromium,chromium-driver,fonts-liberation,fonts-noto-cjk,\
libnss3,libgbm1,libasound2,libasound2-plugins,libatk-bridge2.0-0,libgtk-3-0,\
libx11-xcb1,libdrm2,libxshmfence1,libxkbcommon0,libpango-1.0-0,libcairo2"

case "$ARCH" in
    amd64) KERNEL_PKGS="linux-image-amd64,linux-headers-amd64" ;;
    i386)  KERNEL_PKGS="linux-image-i386,linux-headers-i386" ;;
    *) die "不支持的架构：$ARCH" ;;
esac

PKGS="$BASE_PKGS,$KERNEL_PKGS"
if [ "$PROFILE" = "runtime" ] && [ "$ARCH" = "amd64" ]; then
    PKGS="$PKGS,$RUNTIME_PKGS_AMD64"
elif [ "$PROFILE" = "runtime" ]; then
    warn "profile=runtime 但 $ARCH 没有 Chromium 包 —— 32 位变体只能作为救援兜底"
fi

log "suite=$SUITE arch=$ARCH profile=$PROFILE components=$COMPONENTS"
log "包清单：$(echo "$PKGS" | tr ',' '\n' | wc -l) 个"

# ---------- mmdebstrap ----------
TAR="$OUT.tar"
rm -f "$TAR"
export QM1_ARCH="$ARCH"
export QM1_PROFILE="$PROFILE"
export QM1_OVERLAY_DIR="$REPO_ROOT/overlay"
export QM1_SELFCHECK_SRC="$SCRIPT_DIR/drv-selfcheck.sh"

log "mmdebstrap 开始（这一步会下载并安装全部包，CI 里约需 10–20 分钟）"
if ! mmdebstrap \
        --variant=minbase \
        --components="$COMPONENTS" \
        --architectures="$ARCH" \
        --include="$PKGS" \
        --aptopt='Apt::Install-Recommends "true"' \
        --hook-dir="$HOOKS_DIR" \
        --format=tar \
        "$SUITE" "$TAR" "$MIRROR" 2>&1 | tee "$OUT.mmdebstrap.log"; then
    die "mmdebstrap 失败，日志见 $OUT.mmdebstrap.log"
fi

# ---------- 解包成目录树 ----------
log "解包 rootfs tar → $OUT"
tar -xpf "$TAR" -C "$OUT"
rm -f "$TAR"

# ---------- 收尾：清空伪文件系统 ----------
# /dev /proc /sys /run 在运行时由内核挂载，构建期残留会让 mkfs.ext4 -d 无法填充。
for d in dev proc sys run; do
    if [ -d "$OUT/$d" ]; then
        find "$OUT/$d" -mindepth 1 -delete 2>/dev/null || true
    fi
done
mkdir -p "$OUT"/{dev,proc,sys,run}

# ---------- 清单 ----------
MANIFEST="$OUT/../rootfs-manifest.txt"
{
    echo "# QM1-Debian rootfs manifest"
    echo "suite=$SUITE arch=$ARCH profile=$PROFILE components=$COMPONENTS"
    echo "kernel=$(ls -1 "$OUT/lib/modules" 2>/dev/null | sort -V | tail -1)"
    echo "size_kib=$(du -sk "$OUT" | awk '{print $1}')"
    echo "--- 已装包 ---"
    chroot "$OUT" dpkg-query -W -f='${Package}\n' 2>/dev/null | sort || true
} > "$MANIFEST"
log "清单：$MANIFEST（$(grep -c '' "$MANIFEST") 行）"
log "完成：$OUT"
