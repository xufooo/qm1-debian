#!/usr/bin/env bash
# build-image.sh — 由已构建的根文件系统生成可刷写的镜像产物
#
# 产物（分开存放，便于上传与复用）：
#   build/esp.img      FAT32 ESP（引导器 + 内核 + initrd + grub.cfg）
#   build/rootfs.img   ext4 根文件系统（直接由根目录树填充，无需挂载）
#   build/manifest.txt 尺寸、UUID、内核版本、SHA-256
#
# 之所以用 mkfs.ext4 -d 而不是"建镜像再挂载复制"：
#   挂载需要 root 与 loop 设备，CI 与受限容器里都不方便；-d 直接把目录树写进
#   文件系统，rootless 也能跑，且产物完全可复现。
#
# 用法：
#   bash scripts/build-image.sh --rootfs build/rootfs --out-dir build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOTFS=""
OUT_DIR="build"
ARCH="amd64"
PROFILE="base"
ESP_SIZE_MIB=256
ROOT_SIZE_GIB=6
BOOTLOADERS=""
KERNEL32=""
INITRD32=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --esp-size-mib) ESP_SIZE_MIB="$2"; shift 2 ;;
        --root-size-gib) ROOT_SIZE_GIB="$2"; shift 2 ;;
        --bootloaders) BOOTLOADERS="$2"; shift 2 ;;
        --kernel32) KERNEL32="$2"; shift 2 ;;
        --initrd32) INITRD32="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

[ -n "$ROOTFS" ] || die "缺少 --rootfs"
[ -d "$ROOTFS/boot" ] || die "$ROOTFS 不像根文件系统（缺 /boot）"
need_cmd mkfs.ext4 "apt install e2fsprogs"
need_cmd sfdisk  "apt install fdisk"

mkdir -p "$OUT_DIR"

# ---------- 1. 定位内核与 initrd ----------
KVER="$(ls -1 "$ROOTFS/lib/modules" 2>/dev/null | sort -V | tail -1)"
[ -n "$KVER" ] || die "找不到内核版本（$ROOTFS/lib/modules 为空）"
KERNEL="$ROOTFS/boot/vmlinuz-$KVER"
INITRD="$ROOTFS/boot/initrd.img-$KVER"
[ -f "$KERNEL" ] || die "缺少内核：$KERNEL"
[ -f "$INITRD" ] || die "缺少 initrd：$INITRD"
log "内核：$KVER"

# ---------- 2. 引导器 ----------
if [ -z "$BOOTLOADERS" ]; then
    BOOTLOADERS="$OUT_DIR/bootloaders"
    log "构建双架构引导器 → $BOOTLOADERS"
    bash "$SCRIPT_DIR/build-bootloaders.sh" "$BOOTLOADERS"
fi

# ---------- 3. UUID ----------
ROOT_UUID="$(gen_uuid)"
ROOT32_UUID=""
if [ -n "$KERNEL32" ]; then
    ROOT32_UUID="$(gen_uuid)"
fi
log "根分区 UUID：$ROOT_UUID${ROOT32_UUID:+ / 32 位：$ROOT32_UUID}"

# ---------- 4. ESP ----------
ESP_IMG="$OUT_DIR/esp.img"
log "组装 ESP"
bash "$SCRIPT_DIR/make-esp.sh" \
    --out "$ESP_IMG" \
    --size-mib "$ESP_SIZE_MIB" \
    --bootloaders "$BOOTLOADERS" \
    --kernel "$KERNEL" \
    --initrd "$INITRD" \
    ${KERNEL32:+--kernel32 "$KERNEL32"} \
    ${INITRD32:+--initrd32 "$INITRD32"} \
    --root-uuid "$ROOT_UUID" \
    ${ROOT32_UUID:+--root32-uuid "$ROOT32_UUID"}

# ---------- 5. 根文件系统 ----------
ROOT_IMG="$OUT_DIR/rootfs.img"
USED_KB="$(du -sk "$ROOTFS" | awk '{print $1}')"
NEED_KB=$((USED_KB + 1024 * 1024))          # 留 1 GiB 余量
TARGET_KB=$((ROOT_SIZE_GIB * 1024 * 1024))
[ "$NEED_KB" -gt "$TARGET_KB" ] && TARGET_KB=$(( NEED_KB + NEED_KB / 10 ))
log "根文件系统：占用 ${USED_KB} KiB → 目标 $((TARGET_KB/1024/1024)) GiB"
rm -f "$ROOT_IMG"
truncate -s "${TARGET_KB}K" "$ROOT_IMG"
mkfs.ext4 -q -F -L "$QM1_ROOT_LABEL" -U "$ROOT_UUID" -d "$ROOTFS" "$ROOT_IMG" \
    || die "mkfs.ext4 -d 失败（目标尺寸可能小于内容）"

# ---------- 6. 清单 ----------
MANIFEST="$OUT_DIR/manifest.txt"
{
    echo "# QM1-Debian image manifest"
    echo "arch=$ARCH profile=$PROFILE kernel=$KVER"
    echo "esp_label=$QM1_ESP_LABEL root_label=$QM1_ROOT_LABEL"
    echo "root_uuid=$ROOT_UUID"
    [ -n "$ROOT32_UUID" ] && echo "root32_uuid=$ROOT32_UUID"
    echo "esp_bytes=$(stat -c%s "$ESP_IMG")"
    echo "rootfs_bytes=$(stat -c%s "$ROOT_IMG")"
    echo "--- sha256 ---"
    ( cd "$OUT_DIR" && sha256sum esp.img rootfs.img )
} > "$MANIFEST"
cat "$MANIFEST" >&2
log "完成：$ESP_IMG + $ROOT_IMG（用 scripts/assemble-disk.sh 合成整盘镜像）"
