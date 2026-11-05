#!/usr/bin/env bash
# make-esp.sh — 组装 FAT32 ESP 镜像（放引导器 + 内核 + initrd + grub.cfg）
#
# 关键点：
#   * 用 mkfs.vfat 建卷（VFAT，带长文件名表）；mformat 建的卷不带长名表，
#     文件名会被截断成 8.3，GRUB 就找不到 grub.cfg / vmlinuz32。
#   * 即使有长名表，文件名也一律用 8.3 可精确表示的形式（vmlinuz / initrd.img /
#     vmlinuz32 / initrd32.img），这样在无长名表的卷上同样可用。
#   * 全程不需要 root：用 mtools（mcopy/mmd）直接操作镜像文件，不做 loop 挂载。
#
# 双架构槽位：
#   64 位槽 → ::/vmlinuz     + ::/initrd.img     + grub 里的 @ROOT_UUID@
#   32 位槽 → ::/vmlinuz32   + ::/initrd32.img   + grub 里的 @ROOT32_UUID@
#   只有"内核文件 + 根分区 UUID"都在时，对应菜单项才会保留；
#   否则整段菜单项删除（避免出现一个点了就起不来的入口）。
#
# 用法：
#   bash scripts/make-esp.sh --out build/esp.img --arch amd64 \
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
ARCH="amd64"
SUITE_AMD64="Debian 13"
SUITE_I386="Debian 12"
KERNEL=""
INITRD=""
KERNEL64=""
INITRD64=""
KERNEL32=""
INITRD32=""
ROOT_UUID=""
ROOT64_UUID=""
ROOT32_UUID=""
CONFIG_TEMPLATE="$SCRIPT_DIR/grub.cfg.example"
EXTRA_GRUB=""      # 额外拷进 ESP 的文件（安装介质里放正常菜单 grub-normal.cfg）
WRITE_CONFIG=""    # 把生成出来的 grub.cfg 另存一份（构建安装介质时用）

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --size-mib) SIZE_MIB="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --bootloaders) BOOTLOADERS="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --suite-amd64) SUITE_AMD64="$2"; shift 2 ;;
        --suite-i386) SUITE_I386="$2"; shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        --kernel64) KERNEL64="$2"; shift 2 ;;
        --initrd64) INITRD64="$2"; shift 2 ;;
        --kernel32) KERNEL32="$2"; shift 2 ;;
        --initrd32) INITRD32="$2"; shift 2 ;;
        --root-uuid) ROOT_UUID="$2"; shift 2 ;;
        --root64-uuid) ROOT64_UUID="$2"; shift 2 ;;
        --root32-uuid) ROOT32_UUID="$2"; shift 2 ;;
        --config) CONFIG_TEMPLATE="$2"; shift 2 ;;
        --extra-grub) EXTRA_GRUB="$2"; shift 2 ;;
        --write-config) WRITE_CONFIG="$2"; shift 2 ;;
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

# ---------- 槽位分配 ----------
case "$ARCH" in
    amd64)
        SLOT64_UUID="$ROOT_UUID"
        SLOT32_UUID="${ROOT32_UUID:-}"
        SLOT64_KERNEL="$KERNEL";  SLOT64_INITRD="$INITRD"
        SLOT32_KERNEL="${KERNEL32:-}"; SLOT32_INITRD="${INITRD32:-}"
        ;;
    i386)
        SLOT32_UUID="$ROOT_UUID"
        SLOT64_UUID="${ROOT64_UUID:-}"
        SLOT32_KERNEL="$KERNEL";  SLOT32_INITRD="$INITRD"
        SLOT64_KERNEL="${KERNEL64:-}"; SLOT64_INITRD="${INITRD64:-}"
        ;;
    *) die "不支持的架构：$ARCH" ;;
esac

# 菜单项成立的条件：根分区 UUID 与内核文件都在
have64=0; have32=0
[ -n "$SLOT64_UUID" ] && [ -n "$SLOT64_KERNEL" ] && [ -n "$SLOT64_INITRD" ] && have64=1
[ -n "$SLOT32_UUID" ] && [ -n "$SLOT32_KERNEL" ] && [ -n "$SLOT32_INITRD" ] && have32=1
log "架构=$ARCH  64 位槽：$( [ "$have64" = 1 ] && echo 有 || echo 无 )  32 位槽：$( [ "$have32" = 1 ] && echo 有 || echo 无 )"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${SIZE_MIB}M" "$OUT"
log "建 FAT32 卷：$OUT (${SIZE_MIB}MiB, label=$LABEL)"
mkfs.vfat -F 32 -n "$LABEL" "$OUT" >/dev/null

mmd -i "$OUT" ::/EFI >/dev/null 2>&1 || true
mmd -i "$OUT" ::/EFI/BOOT >/dev/null 2>&1 || true

log "写入引导器（两个都放：BOOTIA32.EFI 给 32 位固件，BOOTX64.EFI 给 64 位固件）"
mcopy -i "$OUT" "$BOOTLOADERS/grub2ia32.efi" ::/EFI/BOOT/BOOTIA32.EFI
mcopy -i "$OUT" "$BOOTLOADERS/grubx64.efi"   ::/EFI/BOOT/BOOTX64.EFI

log "写入内核与 initrd（8.3 安全名）"
if [ "$have64" = 1 ]; then
    mcopy -i "$OUT" "$SLOT64_KERNEL" ::/vmlinuz
    mcopy -i "$OUT" "$SLOT64_INITRD" ::/initrd.img
fi
if [ "$have32" = 1 ]; then
    mcopy -i "$OUT" "$SLOT32_KERNEL" ::/vmlinuz32
    mcopy -i "$OUT" "$SLOT32_INITRD" ::/initrd32.img
fi

CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
sed -e "s|@ROOT_UUID@|$SLOT64_UUID|g" \
    -e "s|@ROOT32_UUID@|$SLOT32_UUID|g" \
    -e "s|@SUITE_AMD64@|$SUITE_AMD64|g" \
    -e "s|@SUITE_I386@|$SUITE_I386|g" \
    "$CONFIG_TEMPLATE" > "$CFG"

# 删除"内核/UUID 缺失"那一侧的菜单项（64 位侧与 32 位侧互相独立）
awk -v have64="$have64" -v have32="$have32" '
    /^menuentry .*64-bit/ { skip = (have64 != "1"); next }
    /^menuentry .*32-bit/ { skip = (have32 != "1"); next }
    skip && /^}/ { skip = 0; next }
    !skip { print }
' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

mcopy -i "$OUT" "$CFG" ::/EFI/BOOT/grub.cfg

# 安装介质用：把"正常菜单"另存一份进 ESP（安装时由 qm1-install-to-emmc
# 拷回目标 ESP，装好之后就不会再看到"安装到 eMMC"这一项）。
if [ -n "$EXTRA_GRUB" ]; then
    [ -f "$EXTRA_GRUB" ] || die "缺少 --extra-grub 指定的文件：$EXTRA_GRUB"
    mcopy -i "$OUT" "$EXTRA_GRUB" ::/EFI/BOOT/grub-normal.cfg
    log "额外写入正常菜单：::/EFI/BOOT/grub-normal.cfg"
fi

# 把生成出来的 grub.cfg 另存一份（构建安装介质时要拿它当 --extra-grub 的输入）
if [ -n "$WRITE_CONFIG" ]; then
    mkdir -p "$(dirname "$WRITE_CONFIG")"
    cp "$CFG" "$WRITE_CONFIG"
    log "grub.cfg 另存：$WRITE_CONFIG"
fi

log "校验镜像内容"
mdir -/ -i "$OUT" ::/EFI/BOOT >&2
mdir -/ -i "$OUT" ::/ >&2

for f in ::/EFI/BOOT/BOOTIA32.EFI ::/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/grub.cfg; do
    mdir -i "$OUT" "$f" >/dev/null 2>&1 || die "ESP 缺少 $f"
done
[ "$have64" = 1 ] || [ "$have32" = 1 ] || die "ESP 里一个可引导的内核都没有"
[ "$have64" = 1 ] && { mdir -i "$OUT" ::/vmlinuz >/dev/null 2>&1 || die "ESP 缺少 ::/vmlinuz"; }
[ "$have32" = 1 ] && { mdir -i "$OUT" ::/vmlinuz32 >/dev/null 2>&1 || die "ESP 缺少 ::/vmlinuz32"; }
log "ESP 校验通过：$OUT"
