#!/usr/bin/env bash
#
# 把 qm1-installer.img 写进 U 盘，并确认"同一支 U 盘"还能装下 eMMC 的
# 整盘备份。
#
# 为什么需要这个脚本：
#
#  - 直接 `dd of=/dev/sdX` 打错一个字母，主机硬盘就没了。这里会先确认
#    目标是不是可移动设备、有没有分区正被挂着、容量够不够。
#  - 安装时整盘备份会落在安装介质尾部那段**未分区空间**里。U 盘小了，
#    备份就放不下 —— 而这个故障要等到装机那一步才暴露（人在机器前面，
#    插着 U 盘）。这里写盘之前就把容量算清楚。
#  - 写完要确认 ESP 和根分区确实落在盘上、尾部空间确实够用。
#
# 用法：
#   bash scripts/prepare-usb-media.sh --image build/out/qm1-installer.img \
#        --target /dev/sdX --backup-gib 30
#
set -euo pipefail

IMAGE=""
TARGET=""
BACKUP_GIB="30"
ASSUME_YES=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --backup-gib) BACKUP_GIB="$2"; shift 2 ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --force)      FORCE=1; shift ;;
        *) echo "用法：$0 --image <installer.img> --target /dev/sdX [--backup-gib N] [--yes] [--force]" >&2; exit 2 ;;
    esac
done

log()  { printf '[usb-media] %s\n' "$*"; }
fail() { printf '[usb-media] ::error::%s\n' "$*" >&2; exit 1; }

[ -n "$IMAGE" ]  || fail "缺少 --image"
[ -n "$TARGET" ] || fail "缺少 --target"
[ -f "$IMAGE" ]  || fail "镜像不存在：$IMAGE"
[ -r "$IMAGE" ]  || fail "镜像读不了：$IMAGE"

for c in dd blockdev lsblk sfdisk cmp; do
    command -v "$c" >/dev/null 2>&1 || fail "缺命令：$c"
done

# ---- 目标设备的基本检查 ----
[ -b "$TARGET" ] || fail "$TARGET 不是块设备（拼错了？dd of= 一定要指到 /dev/sdX 这种设备节点）"

TGT_NAME="$(basename "$TARGET")"
TGT_SIZE="$(blockdev --getsize64 "$TARGET")"
TGT_SIZE_MIB=$(( TGT_SIZE / 1048576 ))
IMG_SIZE="$(wc -c < "$IMAGE" | tr -d ' ')"
IMG_SIZE_MIB=$(( IMG_SIZE / 1048576 ))
BACKUP_BYTES=$(( BACKUP_GIB * 1024 * 1024 * 1024 ))
NEEDED=$(( IMG_SIZE + BACKUP_BYTES + 16 * 1048576 ))

log "镜像      ：${IMAGE}（${IMG_SIZE_MIB} MiB）"
log "目标设备  ：${TARGET}（${TGT_SIZE_MIB} MiB，$(lsblk -ndo MODEL "$TARGET" 2>/dev/null || echo '型号未知')）"
log "备份预留  ：${BACKUP_GIB} GiB"

# 可移动性：能读出 removable 就以它为准，读不出就当固定盘处理
REMOVABLE="unknown"
if [ -r "/sys/block/$TGT_NAME/removable" ]; then
    REMOVABLE="$(cat "/sys/block/$TGT_NAME/removable")"
fi
if [ "$REMOVABLE" != "1" ] && [ "$FORCE" -ne 1 ]; then
    fail "$TARGET 不是可移动设备（/sys/block/$TGT_NAME/removable = ${REMOVABLE}）。
写盘会把这块盘上的一切抹掉。确认这就是你要清空的盘，就加 --force 再跑一次。"
fi
[ "$REMOVABLE" = "1" ] || log "注意：$TARGET 被当作固定盘处理（--force）"

# 目标上还有分区挂着？说明它正在被使用
if command -v lsblk >/dev/null 2>&1; then
    MOUNTED="$(lsblk -nro MOUNTPOINT "$TARGET" 2>/dev/null | grep -c . || true)"
    if [ "${MOUNTED:-0}" -gt 0 ]; then
        fail "$TARGET 上还有分区挂着，请先卸载"
    fi
fi

if [ "$TGT_SIZE" -lt "$NEEDED" ]; then
    NEEDED_GIB=$(( NEEDED / 1073741824 ))
    fail "容量不够：目标 ${TGT_SIZE_MIB} MiB，需要至少 ${NEEDED_GIB} GiB
  = 镜像 ${IMG_SIZE_MIB} MiB + 备份 ${BACKUP_GIB} GiB + 16 MiB 余量。
换一支更大的 U 盘（建议 64 GiB 以上），或者把 --backup-gib 调小 —— 但
备份放不下时，安装器会在写盘之前就拒绝，不会把 eMMC 写成半截。"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '[usb-media] 即将把 %s 整盘写入 %s —— 这块盘上的一切都会消失。\n' "$IMAGE" "$TARGET"
    printf '[usb-media] 输入 yes 继续：'
    read -r reply
    [ "$reply" = "yes" ] || fail "没有得到确认，没有写入"
fi

log "开始写入（6 GiB 上下，请耐心）…"
dd if="$IMAGE" of="$TARGET" bs=4M conv=fsync status=progress

log "回读校验写入的前 64 MiB …"
cmp -n $(( 64 * 1048576 )) "$IMAGE" "$TARGET" || fail "回读校验失败，写入的盘和镜像对不上"

# ---- 写完之后的分区布局与尾部空间 ----
LAYOUT="$(sfdisk -d "$TARGET" 2>/dev/null || true)"
if [ -z "$LAYOUT" ]; then
    log "读不到分区表（sfdisk 读不了），跳过布局检查"
    exit 0
fi
log "分区表："
printf '%s\n' "$LAYOUT" | sed 's/^/    /'

# 最后那个分区的结束位置（字节）—— 备份就落在它后面
#
# sfdisk -d 的 start/size 单位是**扇区**（unit: sectors），所以要乘上
# 扇区大小；字段是 "start=2048," / "size=524288," 这种 key=value 形式，
# 不能直接拿 awk 的 $3 当数字。
SECTOR_SIZE="$(blockdev --getss "$TARGET" 2>/dev/null || echo 512)"
LAST_END="$(
    printf '%s\n' "$LAYOUT" | awk -v ss="$SECTOR_SIZE" '
        /^[[:space:]]*\// {
            start = 0; size = 0
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                # sfdisk 会把值用空格对齐（"start=        2048"），
                # 所以要在字段里找 key，不能假设字段开头就是 key。
                if (match(parts[i], /start=[ ]*[0-9]+/)) {
                    start = substr(parts[i], RSTART + 6, RLENGTH - 6) + 0
                } else if (match(parts[i], /size=[ ]*[0-9]+/)) {
                    size = substr(parts[i], RSTART + 5, RLENGTH - 5) + 0
                }
            }
            if (start > 0 && size > 0) { e = (start + size) * ss; if (e > max) max = e }
        }
        END { print max + 0 }
    '
)"
[ -n "$LAST_END" ] || LAST_END="$IMG_SIZE"
FREE=$(( TGT_SIZE - LAST_END ))
FREE_GIB=$(( FREE / 1073741824 ))

log "已用空间末尾：${LAST_END} 字节；尾部剩余：${FREE_GIB} GiB"
if [ "$FREE" -lt "$BACKUP_BYTES" ]; then
    fail "尾部空间只够 ${FREE_GIB} GiB，装不下 ${BACKUP_GIB} GiB 的整盘备份。
请换更大的 U 盘，或把 --backup-gib 调小。"
fi

log "OK —— 这支 U 盘既能当安装介质，也能当整盘备份盘（尾部 ${FREE_GIB} GiB 未分区空间）"
log "下一步：把 U 盘插到 QM1 上开机，在 UEFI 里选它启动，安装菜单里选「安装到 eMMC」"
