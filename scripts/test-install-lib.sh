#!/usr/bin/env bash
# test-install-lib.sh -- exercise the installer's disk-level helpers against
# synthetic disk images.
#
# The helpers decide which bytes of the eMMC get written.  Getting that wrong
# does not produce a failed build, it produces a bricked tablet -- and until
# now those helpers had never been executed by anything.  This test builds
# GPT images with sfdisk, attaches them to loop devices, and checks:
#
#   1. a partition is found by its type GUID, not by its order on the disk
#      (the ESP is deliberately created *second* here);
#   2. a backup of an untouched disk verifies;
#   3. a single changed byte anywhere in the disk is detected -- both when
#      the target changed and when the backup changed.
#
# Point 3 is the one that matters: a verification that always passes is
# worse than no verification, because it is reported as a working backup.
#
# Needs: util-linux (sfdisk, lsblk, losetup), root (loop devices), coreutils.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/overlay/usr/local/lib/qm1/install-lib.sh"

[ -r "$LIB" ] || { echo "找不到 $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

for c in sfdisk lsblk losetup dd sha256sum awk; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少工具：$c" >&2; exit 1; }
done
[ "$(id -u)" = "0" ] || { echo "需要 root（loop 设备）" >&2; exit 1; }

WORK="$(mktemp -d)"
LOOP=""
cleanup() {
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*" >&2; fails=$(( fails + 1 )); }

IMG="$WORK/disk.img"
BACKUP="$WORK/backup.img"

# 512 MiB, GPT, root filesystem partition FIRST and the EFI partition SECOND.
# The order is the point: a helper that takes "the first partition" as the
# ESP would put an ext4 filesystem into the boot partition.
truncate -s 512M "$IMG"
sfdisk "$IMG" >/dev/null <<'SPEC'
label: gpt
size=128MiB, type=0fc63daf-8483-4772-8e79-3d69d8477de4
size=64MiB, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
SPEC

LOOP="$(losetup --partscan --find --show "$IMG")"
udevadm settle 2>/dev/null || sleep 1

echo "== 分区按类型识别（不按顺序） =="
esp="$(qm1_find_partition_by_type "$LOOP" "$QM1_PARTTYPE_EFI")"
root="$(qm1_find_partition_by_type "$LOOP" "$QM1_PARTTYPE_LINUX")"
[ -n "$esp" ] && ok "找到 EFI 分区：$esp" || bad "没找到 EFI System 分区"
[ -n "$root" ] && ok "找到 Linux 文件系统分区：$root" || bad "没找到 Linux 文件系统分区"

esp_name="$(echo "$esp" | awk '{print $1}')"
root_name="$(echo "$root" | awk '{print $1}')"
esp_no="$(echo "$esp" | awk '{print $2}')"
root_no="$(echo "$root" | awk '{print $2}')"
if [ -n "$esp_no" ] && [ "$esp_no" != "1" ]; then
    ok "ESP 是第 $esp_no 号分区（顺序不是靠前的那个）"
else
    bad "ESP 的分区号是 '$esp_no'，期望不是 1"
fi
if [ -n "$root_no" ] && [ "$root_no" != "2" ]; then
    ok "根文件系统是第 $root_no 号分区"
else
    bad "根文件系统的分区号是 '$root_no'，期望不是 2"
fi
if [ -n "$esp_name" ] && [ -n "$root_name" ] && [ "$esp_name" != "$root_name" ]; then
    ok "两个分区不是同一个设备"
else
    bad "ESP 与根文件系统解析成了同一个分区"
fi

echo "== 未分区空间计算 =="
used="$(qm1_used_end_bytes "$LOOP")"
size="$(blockdev --getsize64 "$LOOP")"
if [ "$used" -gt 0 ] && [ "$used" -lt "$size" ]; then
    ok "已用 $used 字节 / 共 $size 字节"
else
    bad "已用空间看起来不对：used=$used size=$size"
fi

echo "== 备份校验 =="
# 给两个分区写上真实内容，否则比对的是一片零
dd if=/dev/urandom of="$IMG" bs=1M count=200 seek=2 conv=notrunc status=none
cp "$IMG" "$BACKUP"

if qm1_verify_backup "$LOOP" "$BACKUP" 0; then
    ok "完好的备份通过校验"
else
    bad "完好的备份没有通过校验"
fi

# 目标盘被改了一个字节（根文件系统分区中间）
off=$(( 64 * 1024 * 1024 ))
printf 'X' | dd of="$IMG" bs=1 seek="$off" conv=notrunc status=none
if qm1_verify_backup "$LOOP" "$BACKUP" 0; then
    bad "目标盘改了一个字节，校验却通过了"
else
    ok "目标盘的改动被检出"
fi

# 还原，再改备份
cp "$IMG" "$BACKUP"
off=$(( 64 * 1024 * 1024 ))
printf 'Y' | dd of="$BACKUP" bs=1 seek="$off" conv=notrunc status=none
if qm1_verify_backup "$LOOP" "$BACKUP" 0; then
    bad "备份改了一个字节，校验却通过了"
else
    ok "备份的改动被检出"
fi

# 备份放在介质尾部（偏移不为 0）时也要能校验：安装器在 U 盘尾部未分区
# 空间里做备份时就是这个情形。
TAIL="$WORK/tail.img"
truncate -s 700M "$TAIL"
TAIL_BASE=$(( 100 * 1024 * 1024 ))
dd if="$IMG" of="$TAIL" bs=1M seek=100 conv=notrunc status=none
if qm1_verify_backup "$LOOP" "$TAIL" "$TAIL_BASE"; then
    ok "尾部偏移位置的备份通过校验"
else
    bad "尾部偏移位置的备份没有通过校验"
fi
off=$(( 64 * 1024 * 1024 ))
printf 'Z' | dd of="$IMG" bs=1 seek="$off" conv=notrunc status=none
if qm1_verify_backup "$LOOP" "$TAIL" "$TAIL_BASE"; then
    bad "目标盘改了一个字节（带偏移的备份），校验却通过了"
else
    ok "带偏移的备份也能检出差异"
fi

if [ "$fails" -eq 0 ]; then
    echo "install-lib 测试全部通过"
else
    echo "$fails 项失败" >&2
    exit 1
fi
