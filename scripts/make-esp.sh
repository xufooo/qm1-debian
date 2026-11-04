#!/usr/bin/env bash
# make-esp.sh — 组装 FAT32 ESP 镜像（放引导器 + 内核 + initrd + grub.cfg）
#
# 关键点：
#   * 用 mkfs.vfat 建卷（VFAT，带长文件名表）；mformat 建的卷不带长名表，
#     文件名会被截断成 8.3，GRUB 就找不到 grub.cfg / vmlinuz-32。
#   * 即使有长名表，文件名也一律用 8.3 可精确表示的形式（vmlinuz / initrd.img /
#     vmlinuz32 / initrd32.img），这样在无长名表的卷上同样可用。
#   * 全程不需要 root：用 mtools（mcopy/mmd）直接操作镜像文件，不做 loop 挂载。
#
# 用法：
#   bash scripts/make-esp.sh --out build/esp.img \
#        --bootloaders build/bootloaders \
#        --kernel rootfs/boot/vmlinuz-6.12.115-amd64 \
#        --initrd rootfs/boot/initrd.img-6.12.115-amd64 \
#        --root-uuid 11111111-2222-3333-4444-555555555555
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT="build/esp.img"
SIZE_MIB=256
LABEL="$QM1_ESP_LABEL"
BOOTLOADERS=""
KERNEL=""
INITRD=""
KERNEL32=""
INITRD32=""
ROOT_UUID=""
ROOT32_UUID=""
CONFIG_TEMPLATE="$SCRIPT_DIR/grub.cfg.example"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --size-mib) SIZE_MIB="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --bootloaders) BOOTLOADERS="$2"; shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        --kernel32) KERNEL32="$2"; shift 2 ;;
        --initrd32) INITRD32="$2"; shift 2 ;;
        --root-uuid) ROOT_UUID="$2"; shift 2 ;;
        --root32-uuid) ROOT32_UUID="$2"; shift 2 ;;
        --config) CONFIG_TEMPLATE="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

need_cmd mkfs.vfat "apt install dosfstools"
need_cmd mcopy    "apt install mtools"
need_cmd mmd      "apt install mtools"

[ -n "$BOOTLOADERS" ] || die "缺少 --bootloaders（先跑 scripts/build-bootloaders.sh）"
[ -f "$BOOTLOADERS/grub2ia32.efi" ] || die "缺少 $BOOTLOADERS/grub2ia32.efi"
[ -f "$BOOTLOADERS/grubx64.efi" ]   || die "缺少 $BOOTLOADERS/grubx64.efi"
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || die "缺少 --kernel（内核文件不存在）"
[ -n "$INITRD" ] && [ -f "$INITRD" ] || die "缺少 --initrd（initrd 文件不存在）"
[ -n "$ROOT_UUID" ] || die "缺少 --root-uuid"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${SIZE_MIB}M" "$OUT"
log "建 FAT32 卷：$OUT (${SIZE_MIB}MiB, label=$LABEL)"
mkfs.vfat -F 32 -n "$LABEL" "$OUT" >/dev/null

mmd -i "$OUT" ::/EFI >/dev/null 2>&1 || true
mmd -i "$OUT" ::/EFI/BOOT >/dev/null 2>&1 || true

log "写入引导器"
mcopy -i "$OUT" "$BOOTLOADERS/grub2ia32.efi" ::/EFI/BOOT/BOOTIA32.EFI
mcopy -i "$OUT" "$BOOTLOADERS/grubx64.efi"   ::/EFI/BOOT/BOOTX64.EFI

log "写入内核与 initrd（8.3 安全名）"
mcopy -i "$OUT" "$KERNEL" ::/vmlinuz
mcopy -i "$OUT" "$INITRD" ::/initrd.img

CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
sed -e "s|@ROOT_UUID@|$ROOT_UUID|g" \
    -e "s|@ROOT32_UUID@|${ROOT32_UUID:-}|g" \
    "$CONFIG_TEMPLATE" > "$CFG"
if [ -z "${ROOT32_UUID:-}" ]; then
    # 没有 32 位系统时，删掉 32 位菜单项（awk 状态机）
    awk '
        /^menuentry .*32-bit/ {skip=1}
        skip && /^}/ {skip=0; next}
        !skip {print}
    ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi
mcopy -i "$OUT" "$CFG" ::/EFI/BOOT/grub.cfg

if [ -n "${KERNEL32:-}" ] && [ -f "${KERNEL32:-}" ]; then
    mcopy -i "$OUT" "$KERNEL32" ::/vmlinuz32
    [ -n "${INITRD32:-}" ] && [ -f "${INITRD32:-}" ] && mcopy -i "$OUT" "$INITRD32" ::/initrd32.img
    log "已写入 32 位内核"
fi

log "校验镜像内容"
mdir -/ -i "$OUT" ::/EFI/BOOT >&2
mdir -/ -i "$OUT" ::/ >&2

for f in ::/EFI/BOOT/BOOTIA32.EFI ::/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/grub.cfg ::/vmlinuz ::/initrd.img; do
    mdir -i "$OUT" "$f" >/dev/null 2>&1 || die "ESP 缺少 $f"
done
log "ESP 校验通过：$OUT"
