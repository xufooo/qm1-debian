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
#
# 常用可选参数：
#   --kernel-version 6.12.113   固定内核 point release（不装发行版元包，由 hook 精确安装）
#   --wifi-module-deb PATH      装这个打了补丁的 r8723bs_qm1 模块 deb（与内核版本必须配套）
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
KERNEL_VERSION=""   # 空 = 用发行版元包；非空 = 固定某个 point release
WIFI_MODULE_DEB=""  # 空 = 不装外部 Wi-Fi 模块；非空 = 装这个打了补丁的 .deb

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --components) COMPONENTS="$2"; shift 2 ;;
        --hooks) HOOKS_DIR="$2"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        --wifi-module-deb) WIFI_MODULE_DEB="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

# 只做 64 位系统（32 位系统变体已取消；32 位 EFI 引导器照旧保留）。
[ -n "$SUITE" ] || SUITE="$(default_suite_for_arch "$ARCH")"

# ---------- 固定内核 point release（可选） ----------
# --kernel-version 6.12.113 表示"要 6.12.113 这一版内核"，而不是跟着发行版
# 滚动的 linux-image-amd64 元包：
#   * 元包跟着发行版走，Debian 13 当前给的是 6.12.107-1，而 rtl8723bs 的
#     安全修复（kfree_sensitive、WMM_param_handler / rtw_get_wpa_ie 的越界读、
#     监控帧长度校验）是从 6.12.111 才回移进 6.12.y 的；
#   * 要的 point release 可能还只在 <suite>-proposed-updates 里，由
#     hooks/customize02-drivers.sh 临时挂该源精确安装，装完即撤。
# 两种写法都接受：6.12.113（upstream point release）或 6.12.113+deb13-amd64（uname -r）。
KERNEL_ABI=""
if [ -n "$KERNEL_VERSION" ]; then
    [ "$ARCH" = "amd64" ] \
        || die "--kernel-version 只支持 amd64（$ARCH 没有 trixie 内核，也没有对应的 point release）"
    KERNEL_VERSION="$(normalize_kernel_version "$KERNEL_VERSION")"
    case "$KERNEL_VERSION" in
        *[!0-9.]*) die "--kernel-version 只能是数字与点（如 6.12.113），收到：$KERNEL_VERSION" ;;
    esac
    case "$KERNEL_VERSION" in
        *.*.*) : ;;
        *) die "--kernel-version 需要 point release 形式（如 6.12.113），收到：$KERNEL_VERSION" ;;
    esac
    case "$KERNEL_VERSION" in
        *.*.*.*) die "--kernel-version 需要三段式 point release（如 6.12.113），收到：$KERNEL_VERSION" ;;
    esac
    KERNEL_ABI="$(kernel_abi_name "$KERNEL_VERSION" "$ARCH" deb13)"
fi

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
kmod,initramfs-tools,zstd,apt-transport-https"

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
if [ -n "$KERNEL_VERSION" ]; then
    # 固定版本时**不**让 mmdebstrap 装内核元包：
    # 元包会把发行版当前内核（trixie 现在是 6.12.107-1）一起装进来，
    # /lib/modules 出现两个版本，initramfs 与 GRUB 都要挑，容易装错版本。
    # 固定版本改由 hooks/customize02-drivers.sh 精确安装，镜像里只留一个内核。
    KERNEL_PKGS=""
    log "固定内核版本：$KERNEL_VERSION（ABI 名 $KERNEL_ABI）—— 跳过元包，由 hook 精确安装"
fi

PKGS="$BASE_PKGS"
if [ -n "$KERNEL_PKGS" ]; then
    PKGS="$PKGS,$KERNEL_PKGS"
fi
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
# hook 需要知道用哪个发行版/镜像源，才能拼出 <suite>-proposed-updates 的临时 apt 源
export QM1_SUITE="$SUITE"
export QM1_MIRROR="$MIRROR"
# 空 = 用发行版元包；非空 = 固定 point release（如 6.12.113）
export QM1_KERNEL_VERSION="$KERNEL_VERSION"
# 打了 P1–P5 补丁的外部 Wi-Fi 模块（r8723bs_qm1）；空 = 不装
if [ -n "$WIFI_MODULE_DEB" ]; then
    [ -f "$WIFI_MODULE_DEB" ] || die "--wifi-module-deb 指向的文件不存在：$WIFI_MODULE_DEB"
    _wifi_deb_dir="$(cd "$(dirname "$WIFI_MODULE_DEB")" && pwd)"
    _wifi_deb_name="$(basename "$WIFI_MODULE_DEB")"
    QM1_WIFI_MODULE_DEB="$_wifi_deb_dir/$_wifi_deb_name"
    export QM1_WIFI_MODULE_DEB
else
    export QM1_WIFI_MODULE_DEB=""
fi

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
KERNEL_INSTALLED="$(ls -1 "$OUT/lib/modules" 2>/dev/null | sort -V | tail -1)"
if [ -n "$KERNEL_VERSION" ]; then
    KERNEL_MODE="pinned-point-release"
else
    KERNEL_MODE="distro-metapackage"
fi
{
    echo "suite=$SUITE"
    echo "arch=$ARCH"
    echo "profile=$PROFILE"
    echo "components=$COMPONENTS"
    echo "kernel_mode=$KERNEL_MODE"
    echo "kernel_requested=$KERNEL_VERSION"
    echo "kernel_abi=$KERNEL_ABI"
    echo "kernel=$KERNEL_INSTALLED"
} > "$OUT/etc/qm1-build-info"

# ---------- 清单 ----------
MANIFEST="$OUT/../rootfs-manifest.txt"
{
    echo "# QM1-Debian rootfs manifest"
    echo "suite=$SUITE arch=$ARCH profile=$PROFILE components=$COMPONENTS"
    echo "kernel_mode=$KERNEL_MODE kernel_requested=$KERNEL_VERSION kernel_abi=$KERNEL_ABI"
    echo "kernel=$KERNEL_INSTALLED"
    echo "size_kib=$(du -sk "$OUT" | awk '{print $1}')"
    echo "--- 已装包 ---"
    chroot "$OUT" dpkg-query -W -f='${Package}\n' 2>/dev/null | sort || true
} > "$MANIFEST"
log "清单：$MANIFEST（$(grep -c '' "$MANIFEST") 行）"
log "完成：$OUT"
