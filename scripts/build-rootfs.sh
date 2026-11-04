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
SUITE=""
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

# 发行版默认值随架构走：i386 没有 trixie 内核，只能留在 bookworm。
[ -n "$SUITE" ] || SUITE="$(default_suite_for_arch "$ARCH")"

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

# 运行时（Hermes CLI + headless Chrome）
# 说明（实测）：Debian 的 chromium 确实有 i386 包（trixie 150.x / bookworm 同款），
# 所以"32 位没有浏览器"并不成立。32 位变体不装 runtime profile 的真正原因是：
#   * Hermes 要求 Python 3.14，而 uv 托管的 standalone CPython 只提供
#     x86_64-unknown-linux-gnu 产物（pm/lock.json 里 python.artifacts 只有 linux-x64）；
#   * 上游 Node.js 把 32 位 x86 标为 Experimental（Debian 自己构建了 nodejs 20.x i386，
#     但不追主线）；
#   * Debian 13 起不再提供 i386 内核。
# 因此 i386 变体的定位是"救援兜底系统"：能起机、能上网、能维护，但承不了 agent 运行时。
RUNTIME_PKGS_AMD64="chromium,chromium-driver,fonts-liberation,fonts-noto-cjk,\
libnss3,libgbm1,libasound2,libasound2-plugins,libatk-bridge2.0-0,libgtk-3-0,\
libx11-xcb1,libdrm2,libxshmfence1,libxkbcommon0,libpango-1.0-0,libcairo2"

KERNEL_PKGS="$(kernel_pkgs_for_arch "$ARCH")"

PKGS="$BASE_PKGS,$KERNEL_PKGS"
if [ "$PROFILE" = "runtime" ] && [ "$ARCH" = "amd64" ]; then
    PKGS="$PKGS,$RUNTIME_PKGS_AMD64"
elif [ "$PROFILE" = "runtime" ]; then
    warn "profile=runtime 但 $ARCH 承不了 agent 运行时（无 Python 3.14 standalone 构建）—— $ARCH 变体按救援兜底系统构建"
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
export QM1_PROVISION_SRC="$SCRIPT_DIR/provision-agent.sh"

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

# ---------- 构建信息（供后续脚本读取发行版/架构/内核版本） ----------
mkdir -p "$OUT/etc"
{
    echo "suite=$SUITE"
    echo "arch=$ARCH"
    echo "profile=$PROFILE"
    echo "components=$COMPONENTS"
    echo "kernel=$(ls -1 "$OUT/lib/modules" 2>/dev/null | sort -V | tail -1)"
} > "$OUT/etc/qm1-build-info"

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
