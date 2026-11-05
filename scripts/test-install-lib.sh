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
# ★ 必须改**环设备本身**，不是它背后的镜像文件：环设备有自己的页缓存，
#   直接改底层文件，环设备仍从缓存里读出旧内容 ⇒ 校验看不见改动。
#   （CI 就是这样发现"这个用例其实一直没测到东西"的：改的是文件、读的是缓存，
#     校验"通过"了，却什么也没证明。）
off=$(( 64 * 1024 * 1024 ))
orig="$(dd if="$LOOP" bs=1 skip="$off" count=1 status=none | od -An -tx1 | tr -d ' \n')"
printf 'X' | dd of="$LOOP" bs=1 seek="$off" conv=notrunc status=none
if qm1_verify_backup "$LOOP" "$BACKUP" 0; then
    bad "目标盘改了一个字节，校验却通过了"
else
    ok "目标盘的改动被检出"
fi
# 还原（后面的用例还要拿这个盘跟备份比对）
if [ -n "$orig" ]; then
    printf "\\x$orig" | dd of="$LOOP" bs=1 seek="$off" conv=notrunc status=none
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

echo "== 写入校验：镜像比分区小（安装器的真实情形） =="
# 安装器把镜像 dd 进一个**按整块盘大小建出来的**分区：根分区 = 盘容量 -
# ESP - 1MiB，而根文件系统镜像只有镜像那么大。所以校验必须只比镜像那几字节，
# 拿整个分区去 sha256 永远对不上 —— 那会让每一次安装都停在"写入校验失败"。
IMAGE="$WORK/rootfs.img"
truncate -s 50M "$IMAGE"
dd if=/dev/urandom of="$IMAGE" bs=1M count=50 status=none
IMG_BYTES="$(stat -c%s "$IMAGE")"
# 模拟 dd：把镜像写进分区开头
dd if="$IMAGE" of="/dev/$root_name" bs=1M conv=notrunc status=none
src_hash="$(sha256sum "$IMAGE" | awk '{print $1}')"
dst_hash="$(qm1_hash_range "/dev/$root_name" 0 "$IMG_BYTES")"
if [ -n "$dst_hash" ] && [ "$src_hash" = "$dst_hash" ]; then
    ok "镜像写进更大的分区后，镜像范围内的 sha256 一致"
else
    bad "镜像写进更大的分区后校验不一致：$src_hash / $dst_hash"
fi
# 镜像范围内改一个字节，必须被发现
printf 'Q' | dd of="/dev/$root_name" bs=1 seek=1048576 conv=notrunc status=none
dst_hash="$(qm1_hash_range "/dev/$root_name" 0 "$IMG_BYTES")"
if [ "$src_hash" != "$dst_hash" ]; then
    ok "镜像范围内改一个字节被检出"
else
    bad "镜像范围内改了一个字节，校验却通过了"
fi
# 镜像范围之外（分区尾巴）改一个字节，不应影响镜像范围内的校验
printf 'W' | dd of="/dev/$root_name" bs=1 seek=$(( IMG_BYTES + 4096 )) conv=notrunc status=none
dd if="$IMAGE" of="/dev/$root_name" bs=1M conv=notrunc status=none
printf 'W' | dd of="/dev/$root_name" bs=1 seek=$(( IMG_BYTES + 4096 )) conv=notrunc status=none
dst_hash="$(qm1_hash_range "/dev/$root_name" 0 "$IMG_BYTES")"
if [ "$src_hash" = "$dst_hash" ]; then
    ok "镜像范围之外的改动不影响镜像范围内的校验"
else
    bad "镜像范围之外的改动影响了镜像范围内的校验"
fi

echo "== wpa_supplicant 取值规则（两份实现必须一致） =="
# 镜像内的 install-lib.sh 与构建链的 scripts/lib/common.sh 各有一份同名实现
# （前者要随镜像走，后者给 prepare-provision.sh / provision-agent.sh 用）。
# 两边一旦走样，就会出现"CI 里配好的密码，机器上连不上"。
COMMON_LIB="$REPO_ROOT/scripts/lib/common.sh"
[ -r "$COMMON_LIB" ] || { echo "找不到 $COMMON_LIB" >&2; exit 1; }
wpa_eval() {  # $1=lib $2=ssid $3=psk → "ssid_value|psk_value|rc"
    bash -c '
        set -uo pipefail
        . "$1"
        s="$(qm1_wpa_ssid_value "$2")"
        if p="$(qm1_wpa_psk_value "$3")"; then rc=0; else rc=1; p=""; fi
        printf "%s|%s|%s\n" "$s" "$p" "$rc"
    ' _ "$1" "$2" "$3"
}
wpa_case() {  # $1=说明 $2=ssid $3=psk $4=期望
    a="$(wpa_eval "$LIB" "$2" "$3")"
    b="$(wpa_eval "$COMMON_LIB" "$2" "$3")"
    if [ "$a" != "$b" ]; then
        bad "$1：两份实现不一致（镜像内 $a / 构建链 ${b}）"
    elif [ -n "${4:-}" ] && [ "$a" != "$4" ]; then
        bad "$1：得到 ${a}，期望 $4"
    else
        ok "$1 → $a"
    fi
}
HEX64="$(printf 'a%.0s' $(seq 1 64))"
wpa_case "64 位十六进制 PSK 不加引号" "MySSID" "$HEX64" "\"MySSID\"|$HEX64|0"
wpa_case "普通口令加引号" "MySSID" "passphrase" '"MySSID"|"passphrase"|0'
wpa_case "含引号与反斜杠的口令" "MySSID" 'pa"ss\word' '"MySSID"|"pa\"ss\\word"|0'
# SSID 里同时有空格、引号和反斜杠：这三个都要转义，否则 wpa_supplicant 会
# 把 SSID 截断或读成别的名字。
SSID_TRICKY='My "Net"\'
wpa_case "含空格与引号的 SSID" "$SSID_TRICKY" "passphrase" '"My \"Net\"\\"|"passphrase"|0'
wpa_case "太短的口令被拒绝" "MySSID" "short" '"MySSID"||1'
wpa_case "太长的口令被拒绝" "MySSID" "$(printf 'b%.0s' $(seq 1 64))x" '"MySSID"||1'
wpa_case "开放网络没有 psk" "OpenNet" "" '"OpenNet"||0'

echo "== 磁盘辅助函数（两份实现必须一致） =="
# 主机侧（构建链）现在也有一份同名实现，放在 scripts/lib/common.sh 里 ——
# install-qm1.sh 用它做"备份逐分区校验"和"目标分区布局规划"。
#
# 为什么必须断言一致：设备侧安装器 source 的是镜像里那份 install-lib.sh，
# 主机侧安装器 source 的是构建链这份 common.sh。两份实现一旦走样，
# "CI 里验证过的备份校验"和"真机上真正跑的备份校验"就不是同一件事了 ——
# 而备份校验失手的后果是"出事时才发现没有退路"。
disk_eval() {  # $1=lib $2...=要执行的命令 → 输出 + "rc=返回值"
    bash -c '
        set -uo pipefail
        . "$1"; shift
        set +e
        "$@"
        printf "rc=%s\n" "$?"
    ' _ "$1" "${@:2}"
}
disk_parity() {  # $1=说明 $2...=命令
    _desc="$1"; shift
    _a="$(disk_eval "$LIB" "$@" 2>&1 || true)"
    _b="$(disk_eval "$COMMON_LIB" "$@" 2>&1 || true)"
    if [ "$_a" = "$_b" ]; then
        ok "${_desc}：两份实现输出一致"
    else
        bad "${_desc}：两份实现不一致
  镜像内：$_a
  构建链：$_b"
    fi
}
disk_parity "分区列表"        qm1_partitions "$LOOP"
disk_parity "按类型找分区"    qm1_find_partition "$LOOP" "$QM1_PARTTYPE_EFI"
disk_parity "按类型找分区（带分区号）" qm1_find_partition_by_type "$LOOP" "$QM1_PARTTYPE_LINUX"
disk_parity "已用空间"        qm1_used_end_bytes "$LOOP"
disk_parity "字节范围哈希"    qm1_hash_range "$LOOP" 0 1048576
# 备份与原盘此刻**不一致**（上面刚往备份里写过一个字节），
# 所以这一步同时验证了"不一致时两份实现都判失败、且给出同样的说明"。
disk_parity "备份逐分区校验（不一致时）" qm1_verify_backup "$LOOP" "$BACKUP" 0

echo "== 目标布局规划（写盘后按真实容量重建分区表） =="
# 这个函数决定"写完盘之后分区表长什么样"：ESP 固定在 1 MiB，
# 根分区一直撑到盘尾前 1 MiB（给备份 GPT 留位）。
# 它要读镜像自己的分区表 —— 而 sfdisk -d 的分区行是 **"key=value"**
# （"start=2048, size=131072, type=c12a..."，冒号只出现在行首的
# "设备路径 : " 上）。这里曾经按 "key: value" 解析，结果永远读不到
# ESP 大小 —— 解析不出来不是报错退出，就是默默规划出一个错的布局。
PLAN_IMG="$WORK/plan.img"
truncate -s 256M "$PLAN_IMG"
sfdisk "$PLAN_IMG" >/dev/null <<'SPEC'
label: gpt
start=1MiB, size=64MiB, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
start=65MiB, size=190MiB, type=0fc63daf-8483-4772-8e79-3d69d8477de4
SPEC
plan="$(bash -c '. "$1"; qm1_plan_target_layout "$2" "$3"' _ "$COMMON_LIB" "$PLAN_IMG" 268435456 2>&1 || true)"
if [ "$plan" = "64 65 190" ]; then
    ok "256 MiB 目标规划出：ESP 64 MiB / 根分区 65 MiB 起 / 根分区 190 MiB"
else
    bad "分区布局规划结果不对：'$plan'（期望 '64 65 190'）"
fi

# 反向用例：根分区不在 ESP 之后的镜像必须被拒绝（宁可不装，
# 也不能按另一种布局重建分区表）。
#
# 这里判的是**行为**（必须非零退出），而不是某一句文案：
# 上一版只匹配"不一致"和"没有 EFI System 分区"两句，于是函数换了种说法
# 拒绝（"ESP 不是从 1 MiB 开始"），用例反而判它没拒绝 —— 断言比被测
# 代码更 brittle 的时候，红的永远是测试。
plan_bad_out="$(bash -c '. "$1"; qm1_plan_target_layout "$2" "$3"' _ "$COMMON_LIB" "$IMG" 268435456 2>&1)"
plan_bad_rc=$?
if [ "$plan_bad_rc" -ne 0 ] \
   && printf '%s' "$plan_bad_out" | grep -qE '不一致|没有 EFI System 分区|不是从 1 MiB 开始|拒绝按另一种布局'; then
    ok "拒绝了与约定布局不符的镜像（根分区不在 ESP 之后）"
else
    bad "非约定布局的镜像没有被拒绝（rc=${plan_bad_rc}）：'$plan_bad_out'"
fi

if [ "$fails" -eq 0 ]; then
    echo "install-lib 测试全部通过"
else
    echo "$fails 项失败" >&2
    exit 1
fi
