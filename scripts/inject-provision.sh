#!/usr/bin/env bash
# inject-provision.sh — 把「开机即联网」的 provisioning 目录注入已构建好的安装介质
#
# 为什么需要这个脚本：
#   出厂镜像里**不含任何 Wi-Fi 凭据**（凭据是私密信息，不该进公开仓库，
#   也不该进 CI 的日志）。但「装进 eMMC、开机即用」要求装完就能联网 ——
#   安装器会从启动分区（ESP）的 /qm1/provision/ 读取 provisioning。
#   所以流程是：
#     1) 跑脚本/prepare-provision.sh 生成 provisioning 目录（本机，不上传）；
#     2) 把这个目录注入已经构建好的安装介质（不需要重新构建整个镜像）；
#     3) 再把介质 dd 到 U 盘。
#
# 用法：
#   # 注入整盘镜像（自动找 EFI System 分区）
#   bash scripts/inject-provision.sh --image build/qm1-installer.img --dir build/provision
#
#   # 注入裸 ESP 镜像（make-esp.sh 的产物）
#   bash scripts/inject-provision.sh --image build/esp-installer.img --dir build/provision --esp-only
#
#   # 指定偏移（MiB）
#   bash scripts/inject-provision.sh --image build/qm1-installer.img --dir build/provision --offset-mib 1
#
# 依赖：mtools（mcopy/mdir）、python3。都不需要 root，也不需要挂载。

set -euo pipefail

IMAGE=""
PROV_DIR=""
ESP_ONLY=0
OFFSET_MIB=""

log()  { printf '[inject-provision] %s\n' "$*"; }
die()  { printf '[inject-provision][fail] %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="$2"; shift 2 ;;
        --dir)        PROV_DIR="$2"; shift 2 ;;
        --esp-only)   ESP_ONLY=1; shift ;;
        --offset-mib) OFFSET_MIB="$2"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *)            die "未知参数：$1（--help 看用法）" ;;
    esac
done

[ -n "$IMAGE" ]     || die "缺少 --image"
[ -n "$PROV_DIR" ]  || die "缺少 --dir"
[ -f "$IMAGE" ]     || die "找不到镜像文件：$IMAGE"
[ -d "$PROV_DIR" ]  || die "找不到 provisioning 目录：$PROV_DIR"

command -v mcopy >/dev/null 2>&1 || die "缺少 mtools（Debian/Ubuntu: apt install mtools）"
command -v mdir  >/dev/null 2>&1 || die "缺少 mtools（Debian/Ubuntu: apt install mtools）"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"

# --- 找到要写的 FAT 分区偏移 ---
if [ "$ESP_ONLY" = "1" ]; then
    OFFSET=0
    log "按裸 ESP 镜像处理（偏移 0）"
elif [ -n "$OFFSET_MIB" ]; then
    OFFSET=$(( OFFSET_MIB * 1024 * 1024 ))
    log "使用指定偏移：$OFFSET_MIB MiB（$OFFSET 字节）"
else
    OFFSET="$(python3 - "$IMAGE" <<'PY'
import struct, sys

path = sys.argv[1]
with open(path, 'rb') as fh:
    # GPT 的结构：LBA0 = 保护性 MBR，LBA1 = GPT 头，LBA2.. = 分区项数组
    fh.seek(512)
    head = fh.read(512)
    if head[:8] != b'EFI PART':
        sys.exit("不是 GPT 磁盘镜像（offset 512 处没有 EFI PART 头）—— 用 --esp-only 或 --offset-mib 指定")
    part_lba = struct.unpack_from('<Q', head, 72)[0]
    num_parts = struct.unpack_from('<I', head, 80)[0]
    part_size = struct.unpack_from('<I', head, 84)[0]
    fh.seek(part_lba * 512)
    table = fh.read(num_parts * part_size)
    # EFI System Partition 的类型 GUID（GPT 混合端序字节序）
    esp_guid = bytes.fromhex('28732AC11FF8D211BA4B00A0C93EC93B')
    ssz = 512
    for i in range(num_parts):
        entry = table[i * part_size:(i + 1) * part_size]
        type_guid = entry[0:16]
        first_lba = struct.unpack_from('<Q', entry, 32)[0]
        if first_lba == 0:
            continue
        if type_guid == esp_guid:
            print(first_lba * ssz)
            break
    else:
        sys.exit("GPT 里没有 EFI System 分区 —— 用 --esp-only 或 --offset-mib 指定")
PY
)" || die "无法确定 ESP 分区偏移"
    log "ESP 分区偏移：$OFFSET 字节"
fi

# mtools 的 @@ 语法：mcopy -i <镜像>@@<偏移>
TARGET="$IMAGE@@$OFFSET"

# --- 建目录、写文件 ---
mmd -i "$TARGET" ::/qm1 2>/dev/null || true
mmd -i "$TARGET" ::/qm1/provision 2>/dev/null || true

count=0
for f in "$PROV_DIR"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    mcopy -i "$TARGET" "$f" "::/qm1/provision/$base"
    count=$(( count + 1 ))
done
[ "$count" -gt 0 ] || die "provisioning 目录里没有文件：$PROV_DIR"
log "已写入 $count 个 provisioning 文件 → ::/qm1/provision/"

# --- 回读确认 ---
listing="$(mdir -i "$TARGET" ::/qm1/provision 2>/dev/null || true)"
for f in "$PROV_DIR"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$listing" in
        *"$base"*) : ;;
        *) die "回读失败：::/qm1/provision/$base 不在镜像里" ;;
    esac
done

log "完成。写入前请自己记下镜像 sha256（注入会改变镜像内容）："
log "  sha256sum $IMAGE"
