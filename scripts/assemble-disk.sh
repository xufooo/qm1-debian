#!/usr/bin/env bash
# assemble-disk.sh — 把 esp.img + rootfs.img 合成为可直接 dd 到 eMMC 的整盘镜像
#
# 分区布局（GPT，按输入镜像的实际大小算，避免分区表越过盘尾）：
#   p1  1 MiB     起，ESP 镜像大小（向上取整 MiB）  FAT32，卷标 QM1ESP
#   p2  1+ESP MiB 起，根文件系统镜像大小（向上取整 MiB）  ext4，卷标 QM1ROOT
#
# 盘尾留 1 MiB 给 GPT 备份头 —— GPT 的备份分区表在盘尾，若最后一个分区一直顶到
# 盘尾，sfdisk 会因越界报 "Failed to add #1 partition: Invalid argument"。
#
# 镜像默认只占"内容所需"的容量（ESP + 根文件系统 + 1 MiB 余量），刷到 32GB eMMC
# 后剩余空间不分区；需要全盘铺满时可在设备上 extend 分区再 resize2fs 根文件系统。
#
# 刷盘时整盘 dd 即可；系统内的 rootfs UUID 与 grub.cfg 已在构建期固定，
# 因此镜像与设备是一一对应的（换设备要重新构建或改 UUID）。
#
# 用法：
#   bash scripts/assemble-disk.sh --esp build/out/esp.img --root build/out/rootfs.img \
#        --out build/out/qm1-disk.img --size-gib 30
#
# --size-gib 是上限（默认 30，够 32GB eMMC）；实际镜像按内容大小生成。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ESP=""
ROOT=""
OUT="build/qm1-debian13-amd64.img"
SIZE_GIB=30

while [ $# -gt 0 ]; do
    case "$1" in
        --esp) ESP="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --size-gib) SIZE_GIB="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

[ -f "$ESP" ]  || die "缺少 ESP 镜像：$ESP"
[ -f "$ROOT" ] || die "缺少根文件系统镜像：$ROOT"
need_cmd sfdisk "apt install fdisk"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# 分区大小按输入镜像实际体积算（向上取整到 MiB）
ESP_BYTES="$(stat -c%s "$ESP")"
ROOT_BYTES="$(stat -c%s "$ROOT")"
ESP_MIB=$(( (ESP_BYTES + 1048575) / 1048576 ))
ROOT_MIB=$(( (ROOT_BYTES + 1048575) / 1048576 ))
ROOT_START_MIB=$(( 1 + ESP_MIB ))
DISK_MIB=$(( ROOT_START_MIB + ROOT_MIB + 1 ))
MAX_MIB=$(( SIZE_GIB * 1024 ))
[ "$DISK_MIB" -le "$MAX_MIB" ] || die "内容需要 ${DISK_MIB}MiB，超过 --size-gib ${SIZE_GIB}GiB 的上限"

truncate -s "${DISK_MIB}M" "$OUT"
log "写分区表：p1 ${ESP_MIB}MiB (FAT32/UFS) + p2 ${ROOT_MIB}MiB (Linux)，盘尾留 1MiB 给备份 GPT"
printf 'label: gpt\nstart=1MiB, size=%sMiB, type=UFS\nstart=%sMiB, size=%sMiB, type=Linux\n' \
    "$ESP_MIB" "$ROOT_START_MIB" "$ROOT_MIB" | sfdisk "$OUT" >/dev/null

log "写入 ESP"
dd if="$ESP" of="$OUT" bs=1M seek=1 conv=notrunc status=none
log "写入根文件系统"
dd if="$ROOT" of="$OUT" bs=1M seek="$ROOT_START_MIB" conv=notrunc status=none

log "校验分区表"
sfdisk -l "$OUT" >&2 || true
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "完成：$OUT"
cat "$(dirname "$OUT")/$(basename "$OUT").sha256" >&2
