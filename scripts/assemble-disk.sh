#!/usr/bin/env bash
# assemble-disk.sh — 把 esp.img + rootfs.img 合成为可直接 dd 到 eMMC 的整盘镜像
#
# 分区布局（GPT）：
#   p1  1 MiB    起，512 MiB   FAT32  ESP，卷标 QM1ESP（放引导器与内核）
#   p2  513 MiB 起，其余       ext4   根文件系统，卷标 QM1ROOT
#
# 刷盘时整盘 dd 即可；系统内的 rootfs UUID 与 grub.cfg 已在构建期固定，
# 因此镜像与设备是一一对应的（换设备要重新构建或改 UUID）。
#
# 用法：
#   bash scripts/assemble-disk.sh --esp build/esp.img --root build/rootfs.img \
#        --out build/qm1-debian13-amd64.img --size-gib 30
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ESP=""
ROOT=""
OUT="build/qm1-debian13-amd64.img"
SIZE_GIB=30
ESP_MIB=512
ROOT_START_MIB=513

while [ $# -gt 0 ]; do
    case "$1" in
        --esp) ESP="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --size-gib) SIZE_GIB="$2"; shift 2 ;;
        --esp-mib) ESP_MIB="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

[ -f "$ESP" ]  || die "缺少 ESP 镜像：$ESP"
[ -f "$ROOT" ] || die "缺少根文件系统镜像：$ROOT"
need_cmd sfdisk "apt install fdisk"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${SIZE_GIB}G" "$OUT"

ROOT_MIB=$(( SIZE_GIB * 1024 - ROOT_START_MIB ))
log "写分区表：p1 ${ESP_MIB}MiB (FAT32/UFS) + p2 ${ROOT_MIB}MiB (Linux)"
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
