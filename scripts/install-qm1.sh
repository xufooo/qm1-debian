#!/usr/bin/env bash
# install-qm1.sh — 把 QM1 整机镜像安装到设备的 eMMC
#
# 这是"安装"环节的落地脚本：不是 dd 的裸封装，而是一套带前置检查、
# 强制备份、写入校验与救援提示的流程。任何破坏性动作前都要求显式确认。
#
# 用法：
#   # 1) 先看看会做什么（不写盘）
#   sudo bash scripts/install-qm1.sh --image build/qm1-debian13-amd64.img \
#        --target /dev/mmcblk0 --dry-run
#
#   # 2) 真正安装（会先整盘备份到备份目录）
#   sudo bash scripts/install-qm1.sh --image build/qm1-debian13-amd64.img \
#        --target /dev/mmcblk0 --backup-dir /mnt/usb/qm1-backup --yes
#
# 关键约束：
#   * 镜像自带 ESP（引导器 + 内核 + initrd + grub.cfg），写完即可脱离 U 盘自启动；
#   * 固件若不扫描内部存储的 \EFI\BOOT，仍需保留 U 盘跳板（见 --rescue-stick 说明）；
#   * 备份与 sha256 校验是硬前置，不可跳过（--no-backup 仅用于已确认无数据的盘）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IMAGE=""
TARGET=""
BACKUP_DIR=""
NO_BACKUP=0
DO_VERIFY=1
DO_DISCARD=1
ASSUME_YES=0
DRY_RUN=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --no-backup)  NO_BACKUP=1; shift ;;
        --no-verify)  DO_VERIFY=0; shift ;;
        --no-discard) DO_DISCARD=0; shift ;;
        --yes)        ASSUME_YES=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "未知参数：$1（--help 看用法）" ;;
    esac
done

[ -n "$IMAGE" ]  || die "缺少 --image"
[ -n "$TARGET" ] || die "缺少 --target"
[ -f "$IMAGE" ]  || die "镜像不存在：$IMAGE"
need_cmd dd
need_cmd sha256sum
need_cmd blockdev

# ---------- 1. 目标设备检查 ----------
[ -b "$TARGET" ] || die "目标不是块设备：$TARGET"

# 已挂载的盘绝不允许直接写
if findmnt -rn -S "$TARGET" >/dev/null 2>&1; then
    die "目标 $TARGET 上有已挂载的文件系统，请先卸载"
fi

TARGET_SIZE="$(blockdev --getsize64 "$TARGET")"
IMAGE_SIZE="$(stat -c%s "$IMAGE")"
log "目标设备：$TARGET（$((TARGET_SIZE/1024/1024/1024)) GiB）"
log "镜像大小：$IMAGE_SIZE 字节"

if [ "$IMAGE_SIZE" -gt "$TARGET_SIZE" ]; then
    die "镜像比目标盘还大：$IMAGE_SIZE > $TARGET_SIZE"
fi

if [ "$IMAGE_SIZE" -lt $((256 * 1024 * 1024)) ]; then
    warn "镜像看起来偏小（<$((256/1024)) MiB），确认这是完整整机镜像？"
fi

PART_ROOTS="$(lsblk -nrpo MOUNTPOINT "$TARGET" 2>/dev/null | grep -v '^$' || true)"
if [ -n "$PART_ROOTS" ]; then
    warn "目标盘上检测到挂载点：$(echo "$PART_ROOTS" | tr '\n' ' ')"
fi

# ---------- 2. 确认 ----------
cat <<EOF

即将对 $TARGET 执行破坏性写入：
  镜像      : $IMAGE
  镜像大小  : $IMAGE_SIZE 字节
  目标容量  : $TARGET_SIZE 字节
  备份      : $([ "$NO_BACKUP" -eq 1 ] && echo "跳过（--no-backup）" || echo "${BACKUP_DIR:-<镜像同目录>}")
  写入后校验: $([ "$DO_VERIFY" -eq 1 ] && echo "开启" || echo "关闭")
  写入前 discard: $([ "$DO_DISCARD" -eq 1 ] && echo "开启" || echo "关闭")

EOF

if [ "$DRY_RUN" -eq 1 ]; then
    log "--dry-run：到此为止，不做任何写入。"
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "确认对 %s 写入？输入 yes 继续： " "$TARGET"
    read -r reply
    [ "$reply" = "yes" ] || die "未确认，已退出。"
fi

# ---------- 3. 备份（硬前置）----------
if [ "$NO_BACKUP" -eq 1 ]; then
    warn "跳过备份 —— 设备原有数据将永久丢失。"
else
    [ -n "$BACKUP_DIR" ] || BACKUP_DIR="$(dirname "$IMAGE")/qm1-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    BACKUP_IMG="$BACKUP_DIR/$(basename "$TARGET")-backup-$(date +%Y%m%d-%H%M%S).img"
    log "备份整盘 → $BACKUP_IMG"
    dd if="$TARGET" of="$BACKUP_IMG" bs=4M status=progress
    ( cd "$BACKUP_DIR" && sha256sum "$(basename "$BACKUP_IMG")" > "$(basename "$BACKUP_IMG").sha256" )
    log "备份完成，校验文件：$(basename "$BACKUP_IMG").sha256"
    warn "请把备份与校验文件另存一份到机器之外。"
fi

# ---------- 4. 写入 ----------
if [ "$DO_DISCARD" -eq 1 ] && command -v blkdiscard >/dev/null 2>&1; then
    log "discard 未覆盖区域（若设备不支持会失败，忽略即可）"
    blkdiscard "$TARGET" 2>/dev/null || warn "blkdiscard 失败，继续"
fi

log "写入镜像 → $TARGET"
dd if="$IMAGE" of="$TARGET" bs=4M conv=fsync status=progress

# ---------- 5. 校验 ----------
if [ "$DO_VERIFY" -eq 1 ]; then
    log "回读校验（比对镜像覆盖范围内的字节）"
    if cmp -n "$IMAGE_SIZE" "$IMAGE" "$TARGET"; then
        log "校验通过：写入内容与镜像一致。"
    else
        die "校验失败：写入内容与镜像不一致，请勿继续开机，先用备份恢复。"
    fi
fi

# ---------- 6. 后续步骤 ----------
cat <<EOF

安装完成。接下来：

  1. 关机取出安装介质（或拔掉 U 盘），上电启动。
  2. 固件若不扫描内部存储的 \\EFI\\BOOT，用 U 盘跳板引导（见 README 的救援一节）。
  3. 首次开机后执行自检：
         sudo /usr/local/bin/qm1-selftest
  4. 装 agent 运行时（Hermes 官方安装方式 + Chrome 依赖）：
         sudo bash /usr/local/share/qm1/provision-agent.sh

EOF
