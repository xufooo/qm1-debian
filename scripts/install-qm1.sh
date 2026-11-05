#!/usr/bin/env bash
# install-qm1.sh — 把 QM1 整机镜像安装到设备的 eMMC（从 Linux 主机侧执行）
#
# 这是"安装"环节的落地脚本：不是 dd 的裸封装，而是一套带前置检查、
# 强制备份、写入校验、EFI 启动项登记与救援提示的流程。任何破坏性动作前
# 都要求显式确认。
#
# ⚠️ QM1 上的设备编号是反直觉的，别照抄别的板子的写法：
#      /dev/mmcblk0  = 内置 Wi-Fi 的 SDIO 卡（0x024c:0xb723）
#      /dev/mmcblk1  = eMMC（ACPI 80860F14:00，SanDisk S10032，28.5 GiB）
#    写错目标 = 把系统盖在 Wi-Fi 卡上。本脚本会按 MMC 的 type 字段
#    拦掉 SDIO 卡与 SD 卡，但**不要**因此就省略 --target 的核对。
#
# 用法：
#   # 1) 先看看会做什么（不写盘）
#   sudo bash scripts/install-qm1.sh --image build/qm1-disk.img \
#        --target /dev/mmcblk1 --dry-run
#
#   # 2) 真正安装（会先整盘备份到备份目录）
#   sudo bash scripts/install-qm1.sh --image build/qm1-disk.img \
#        --target /dev/mmcblk1 --backup-dir /mnt/usb/qm1-backup --yes
#
# 关键约束：
#   * 镜像自带 ESP（引导器 + 内核 + initrd + grub.cfg），写完即可脱离 U 盘自启动；
#   * 写完会用 efibootmgr 登记 \EFI\BOOT\BOOTIA32.EFI（IA32 与 64 位固件
#     都能加载它；BOOTX64.EFI 是 PE32+，这台机器的 32 位固件加载不了）；
#     固件不扫内部存储的 \EFI\BOOT 时仍需保留 U 盘跳板，见 README 的救援一节）；
#   * 备份与 sha256 校验是硬前置，不可跳过（--no-backup 仅用于已确认无数据的盘）；
#   * EFI 启动项登记失败 = 装机失败（机器开不了机却报成功是最坏的结果），
#     需要在非 UEFI 环境里跑（例如 CI）请显式加 --skip-efi-entry。
#
# 另一条安装路径：从 U 盘启动安装介质，选菜单 ①「安装到 eMMC」。
# 那条路径（设备内的 qm1-install-to-emmc）会自动选对目标、自动备份、
# 自动登记 EFI 启动项，并会生成登录口令 —— 不想在本机折腾就用它。
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
ALLOW_SD=0
FORCE_KIND=0
SKIP_EFI_ENTRY=0

usage() {
    sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="$2"; shift 2 ;;
        --target)     TARGET="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --no-backup)  NO_BACKUP=1; shift ;;
        --no-verify)  DO_VERIFY=0; shift ;;
        --no-discard) DO_DISCARD=0; shift ;;
        --allow-sd)   ALLOW_SD=1; shift ;;
        --force-kind) FORCE_KIND=1; shift ;;
        --skip-efi-entry) SKIP_EFI_ENTRY=1; shift ;;
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

# 目标是什么类型的介质？必须先分清：
#   MMC  = eMMC（本机要写的那个）
#   SD   = SD 卡
#   SDIO = 内置 Wi-Fi 的卡（写它等于毁掉无线模块）
# 之前的用法示例里写的是 /dev/mmcblk0 —— 在这台机器上那是 Wi-Fi 的卡。
_target_name="$(basename "$TARGET")"
_target_type=""
if [ -r "/sys/block/${_target_name}/device/type" ]; then
    _target_type="$(cat "/sys/block/${_target_name}/device/type" 2>/dev/null || true)"
fi
case "$_target_type" in
    MMC)
        log "目标类型：MMC（eMMC）"
        ;;
    SDIO)
        die "目标是 SDIO 卡（${_target_name}）—— 在 QM1 上那是内置 Wi-Fi 的卡，不是 eMMC！拒绝写入。
     eMMC 通常是 /dev/mmcblk1（ACPI 80860F14:00）。先用 'lsblk -o NAME,TYPE,MODEL,SIZE' 确认。"
        ;;
    SD)
        if [ "$ALLOW_SD" -eq 1 ]; then
            warn "目标是 SD 卡（--allow-sd 放行）"
        else
            die "目标是 SD 卡（${_target_name}）。确认要写 SD 卡请加 --allow-sd。"
        fi
        ;;
    "")
        if [ "$FORCE_KIND" -eq 1 ]; then
            warn "读不出目标类型（--force-kind 放行）"
        else
            die "读不出 ${_target_name} 的介质类型（/sys/block/${_target_name}/device/type 不存在）。
     这通常意味着它不是 MMC 设备。确认无误再加 --force-kind。"
        fi
        ;;
    *)
        warn "目标类型未知：$_target_type"
        ;;
esac

# 已挂载的盘绝不允许直接写 —— 而且**分区挂着一样不行**。
#
# 为什么分区也要拦：整盘没挂载不代表盘上的分区没挂载。在一台已经装好的
# QM1 上跑 `--target /dev/mmcblk1`，会把正在运行的系统从它自己脚下的分区
# 上 dd 掉 —— 这不是"覆盖安装"，这是把正在跑的系统抽走。设备侧安装器
# （qm1-install-to-emmc）对这件事的处理是直接 die，主机侧必须对齐。
if findmnt -rn -S "$TARGET" >/dev/null 2>&1; then
    die "目标 $TARGET 上有已挂载的文件系统，请先卸载"
fi
_mounted_parts=""
for _p in $(lsblk -nro NAME "$TARGET" 2>/dev/null | grep -v '^$' || true); do
    [ "$_p" = "$_target_name" ] && continue
    if findmnt -rn "/dev/$_p" >/dev/null 2>&1; then
        _mounted_parts="/dev/$_p $_mounted_parts"
    fi
done
if [ -n "$_mounted_parts" ]; then
    die "目标盘上还有分区挂着：$_mounted_parts
     在已装好的机器上写这块盘会把正在运行的系统抽走 —— 先卸载它们（或从安装介质启动再跑）。"
fi

TARGET_SIZE="$(blockdev --getsize64 "$TARGET")"
IMAGE_SIZE="$(stat -c%s "$IMAGE")"
log "目标设备：${TARGET}（$((TARGET_SIZE/1024/1024/1024)) GiB）"
log "镜像大小：$IMAGE_SIZE 字节"

if [ "$IMAGE_SIZE" -gt "$TARGET_SIZE" ]; then
    die "镜像比目标盘还大：$IMAGE_SIZE > $TARGET_SIZE"
fi

if [ "$IMAGE_SIZE" -lt $((256 * 1024 * 1024)) ]; then
    warn "镜像看起来偏小（<$((256/1024)) MiB），确认这是完整整机镜像？"
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
  EFI 启动项: $([ "$SKIP_EFI_ENTRY" -eq 1 ] && echo "显式跳过（--skip-efi-entry）" || echo "必须登记成功，否则算失败")

EOF

if [ "$DRY_RUN" -eq 1 ]; then
    log "--dry-run：到此为止，不做任何写入。"
    exit 0
fi

require_root

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
    dd if="$TARGET" of="$BACKUP_IMG" bs=4M conv=fsync status=progress
    ( cd "$BACKUP_DIR" && sha256sum "$(basename "$BACKUP_IMG")" > "$(basename "$BACKUP_IMG").sha256" )
    log "备份完成，校验文件：$(basename "$BACKUP_IMG").sha256"

    # 备份必须跟"写盘之前的原盘"逐分区比过 —— 只算备份文件自己的 sha256
    # 是不够的：一份写错位置或者被截断的备份，它的哈希完全自洽。
    # 逐分区比对（1 MiB GPT 头 + 每个分区）才能发现"备份其实没保住原盘"。
    log "逐分区校验备份与原盘是否一致"
    if qm1_verify_backup "$TARGET" "$BACKUP_IMG" 0; then
        log "备份与原盘逐分区一致，可以放心继续。"
    else
        die "备份与写盘前的原盘不一致 —— 中止，没有对 $TARGET 做任何写入。
备份位置：$BACKUP_IMG
这通常意味着介质本身读写有问题（U 盘/SD 卡掉盘或容量不足）。
请换一块介质重试；不要在备份不可信的情况下继续 —— 出了事就没有退路了。"
    fi
    warn "请把备份与校验文件另存一份到机器之外。"
fi

# ---------- 4. 写入 ----------
if [ "$DO_DISCARD" -eq 1 ] && command -v blkdiscard >/dev/null 2>&1; then
    log "discard 未覆盖区域（若设备不支持会失败，忽略即可）"
    blkdiscard "$TARGET" 2>/dev/null || warn "blkdiscard 失败，继续"
fi

log "写入镜像 → $TARGET"
dd if="$IMAGE" of="$TARGET" bs=4M conv=fsync status=progress

# ---------- 4b. 原始字节回读校验（必须在任何后续改动之前）----------
#
# 这一步比的是"刚写进去的字节"与镜像是否一致 —— 此刻目标盘上的内容就是
# 镜像的内容（分区表也是镜像里的那份）。后面会重建分区表并 resize 文件系统，
# 那之后两者必然不再逐字节相同，所以校验必须放在这个时间点上。
if [ "$DO_VERIFY" -eq 1 ]; then
    log "回读校验（比对镜像覆盖范围内的字节）"
    if cmp -n "$IMAGE_SIZE" "$IMAGE" "$TARGET"; then
        log "校验通过：写入内容与镜像一致。"
    else
        die "校验失败：写入内容与镜像不一致，请勿继续开机，先用备份恢复。
备份位置：${BACKUP_IMG:-<未备份>}
恢复命令：dd if=<备份文件> of=$TARGET bs=4M conv=fsync status=progress"
    fi
fi

# ---------- 5. 按目标真实容量重建分区表 ----------
#
# 镜像只有"内容所需"的大小（ESP + 根文件系统 + 1 MiB），而 eMMC 有 28.5 GiB。
# 直接 dd 上去的后果：
#   * 镜像里的备份 GPT 落在 6.3 GiB 处，旧盘尾部的备份 GPT 还在那儿 ——
#     一盘两套 GPT，sgdisk/parted 会报 "backup GPT is not at the end of the disk"；
#   * 约 22 GiB 的旧系统残留还留在盘上；
#   * 根分区只有 6 GiB，装完就只剩 6 GiB 可用。
# 所以写完必须按真实容量重建：ESP 保持 1 MiB 偏移，根分区一直撑到盘尾
# 前 1 MiB，sfdisk 对着真实设备写表 ⇒ 备份 GPT 落在真实盘尾。
# 设备侧安装器（qm1-install-to-emmc）走的是同一条路（重建整盘 GPT + resize2fs）。
LAYOUT="$(qm1_plan_target_layout "$IMAGE" "$TARGET_SIZE")" || die "无法规划目标分区布局"
read -r ESP_MIB ROOT_START_MIB ROOT_SIZE_MIB <<<"$LAYOUT"
[ -n "${ESP_MIB:-}" ] && [ -n "${ROOT_START_MIB:-}" ] && [ -n "${ROOT_SIZE_MIB:-}" ] \
    || die "分区布局规划失败：$LAYOUT"

if [ "$TARGET_SIZE" -eq "$IMAGE_SIZE" ]; then
    # 目标与镜像**等大** ⇒ 镜像自带的分区表对这个目标已经是正确的
    # （ESP 在 1 MiB、根分区紧跟其后、备份 GPT 在盘尾）。
    # 这时再重建一遍只会换掉 GPT 里的 GUID，把"写进去的字节 == 镜像字节"
    # 这个本来可以直接核对的事实弄丢 —— 写 U 盘、或在循环设备上做验证时
    # 都要靠这个核对。所以等大的目标走"原样保留镜像布局"这条路。
    KEEP_IMAGE_LAYOUT=1
    log "目标与镜像等大（${TARGET_SIZE} 字节）：保留镜像自带的分区表，不重建。"
else
    KEEP_IMAGE_LAYOUT=0
    log "按目标真实容量重建分区表（ESP 1 MiB 偏移 + 根分区撑到盘尾）"
    log "  ESP ${ESP_MIB} MiB（1 MiB 起） / 根分区 ${ROOT_SIZE_MIB} MiB（${ROOT_START_MIB} MiB 起）"
    qm1_write_target_layout "$TARGET" "$ESP_MIB" "$ROOT_START_MIB" "$ROOT_SIZE_MIB"
fi

# 让内核重读分区表：不重读的话，后面 lsblk 看到的还是旧分区表，
# 找不到 EFI System 分区 ⇒ 跳过 EFI 启动项登记 ⇒ 机器装上了却开不了机。
qm1_rescan_partitions "$TARGET"

# 重新枚举分区（等设备节点出现）
ESP_NO=""
ESP_PART=""
ROOT_PART=""
for _ in $(seq 1 20); do
    ESP_NO=""; ESP_PART=""; ROOT_PART=""
    read -r _n _pno _s _z <<<"$(qm1_find_partition_by_type "$TARGET" "$QM1_PARTTYPE_EFI" || true)"
    if [ -n "${_n:-}" ]; then ESP_NO="$_pno"; ESP_PART="/dev/$_n"; fi
    read -r _n _pno _s _z <<<"$(qm1_find_partition_by_type "$TARGET" "$QM1_PARTTYPE_LINUX" || true)"
    if [ -n "${_n:-}" ]; then ROOT_PART="/dev/$_n"; fi
    if [ -n "$ESP_PART" ] && [ -n "$ROOT_PART" ] \
       && [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; then
        break
    fi
    sleep 0.5
done
[ -n "$ESP_PART" ] && [ -n "$ROOT_PART" ] \
    || die "写完盘之后没有看到 ESP / 根分区设备（等 10 秒仍未出现）。$TARGET 上的分区表不可用，不要从这里启动。"
log "目标分区：${ESP_PART}（ESP，p${ESP_NO}） / ${ROOT_PART}（根）"

# ---------- 6. 清掉旧尾巴 ----------
#
# 旧盘尾部（镜像结束之后）还留着上一套系统的数据和它自己的备份 GPT。
# 那一段现在落在新根分区里面，必须清干净：
#   * 不清 ⇒ 旧备份 GPT 变成"埋在文件系统里的垃圾"，一旦被工具认出来
#     就会报一盘两套 GPT；
#   * 不清 ⇒ 根分区扩容时 resize2fs 会把这堆陈旧数据当成可用空间。
# 先写零，再让 resize2fs 把它变成干净的文件系统空间。
TAIL_START=$(( IMAGE_SIZE - 1048576 ))          # 镜像最后 1 MiB 就是它自己的备份 GPT
TAIL_END=$(( TARGET_SIZE - 1048576 ))            # 真实盘最后 1 MiB 留给新的备份 GPT
if [ "$TAIL_END" -gt "$TAIL_START" ]; then
    TAIL_MIB=$(( (TAIL_END - TAIL_START) / 1048576 ))
    log "清掉旧尾巴（${TAIL_MIB} MiB：旧备份 GPT 与旧系统残留）"
    dd if=/dev/zero of="$TARGET" bs=1M seek=$(( TAIL_START / 1048576 )) \
       count="$TAIL_MIB" conv=notrunc,fsync status=progress
fi

# ---------- 7. 内容核对 + 文件系统撑满 ----------
#
# 核对两件事（都在 resize 之前做 —— resize 会改文件系统元数据，之后就没法
# 逐字节比了）：
#   * ESP 分区的内容与镜像里的 ESP 一致；
#   * 根分区开头那段与镜像里的根分区一致。
#
# 取镜像里的字节区间用 dd 的 skip_bytes/count_bytes（字节口径），
# 不用 bs=1M + count 换算 —— 那样遇到"长度不是整数 MiB"就会少几个字节，
# cmp 会误报成"内容不一致"。
cmp_image_range() {   # $1=镜像 $2=偏移 $3=长度 $4=目标分区
    dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none \
        | cmp -n "$3" - "$4"
}
IMG_ROOT_BYTES=$(( IMAGE_SIZE - ROOT_START_MIB * 1048576 - 1048576 ))
[ "$IMG_ROOT_BYTES" -gt 0 ] || IMG_ROOT_BYTES=0
if [ "$DO_VERIFY" -eq 1 ]; then
    if cmp_image_range "$IMAGE" 1048576 $(( ESP_MIB * 1048576 )) "$ESP_PART"; then
        log "ESP 内容与镜像一致。"
    else
        die "ESP 内容与镜像不一致 —— 写盘有问题，请用备份恢复后再开机。"
    fi
    if [ "$IMG_ROOT_BYTES" -gt 0 ]; then
        if cmp_image_range "$IMAGE" $(( ROOT_START_MIB * 1048576 )) "$IMG_ROOT_BYTES" "$ROOT_PART"; then
            log "根分区内容与镜像一致（${IMG_ROOT_BYTES} 字节）。"
        else
            die "根分区内容与镜像不一致 —— 写盘有问题，请用备份恢复后再开机。"
        fi
    fi
fi

if [ "$KEEP_IMAGE_LAYOUT" -eq 1 ]; then
    # 等大目标：镜像自带的分区表和文件系统原样保留。
    # 这里只做**只读**检查（e2fsck -fn）—— 连 e2fsck -p 都不跑：
    # 它可能顺手改超级块的时间戳，那样"写进去的字节 == 镜像字节"这个
    # 本来可以直接核对的结论就被自己弄丢了。
    if e2fsck -fn "$ROOT_PART" >/dev/null 2>&1; then
        log "根文件系统只读检查通过（e2fsck -fn 无错误）"
    else
        die "根文件系统检查没通过（e2fsck -fn）—— $ROOT_PART 上的文件系统有错，不要从这里启动。
请用备份恢复：dd if=<备份文件> of=$TARGET bs=4M conv=fsync status=progress"
    fi
else
    log "检查并撑满根文件系统（撑到 ${ROOT_SIZE_MIB} MiB）"
    # e2fsck -p（预修复）失败就退回 -f（强制修复）；两个都不行才判失败。
    if ! e2fsck -fp "$ROOT_PART" >/dev/null 2>&1 && ! e2fsck -f "$ROOT_PART" >/dev/null 2>&1; then
        die "根文件系统检查没通过（e2fsck）—— $ROOT_PART 上的文件系统有错，不要从这里启动。
请用备份恢复：dd if=<备份文件> of=$TARGET bs=4M conv=fsync status=progress"
    fi
    if ! resize2fs "$ROOT_PART" >/dev/null 2>&1; then
        die "撑大根文件系统失败（resize2fs）—— $ROOT_PART 仍然是旧容量，不要从这里启动。
请用备份恢复：dd if=<备份文件> of=$TARGET bs=4M conv=fsync status=progress"
    fi
    if e2fsck -fn "$ROOT_PART" >/dev/null 2>&1; then
        log "撑大后的文件系统检查通过（e2fsck -fn 无错误）"
    else
        die "撑大后的文件系统检查没通过（e2fsck -fn）—— $ROOT_PART 上的文件系统有错，不要从这里启动。
请用备份恢复：dd if=<备份文件> of=$TARGET bs=4M conv=fsync status=progress"
    fi
fi

# ---------- 8. 登记 UEFI 启动项 ----------
# 写完盘还不够：这台机器的固件不一定扫描内部存储的 \EFI\BOOT，
# 登记一条 UEFI 启动项才稳。**找不到 ESP、或者登记不成，都必须判失败** ——
# 装上了却开不了机却报"成功"，是最坏的结果（用户只会看到一台开不了机的机器）。
#
# 登记**哪一个**引导器有个容易踩的坑：ESP 上有两条（make-esp.sh 写入）
#   \EFI\BOOT\BOOTIA32.EFI —— PE32（32 位）
#   \EFI\BOOT\BOOTX64.EFI  —— PE32+（64 位）
# **IA32 固件加载不了 PE32+ 的 BOOTX64.EFI**；而 64 位固件按 UEFI 规范
# 必须能加载 IA32 应用 ⇒ 只有 BOOTIA32.EFI 是"两种固件都能加载"的那条。
# 这台机器的固件就是 32 位 IA32 ⇒ 优先登记 BOOTIA32.EFI。
# （之前这里写死 BOOTX64.EFI：在 32 位固件上登记出来的是一条加载不了的启动项。）
ESP_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ESP_LOADER=""
if [ -n "$ESP_PART" ]; then
    _esp_mnt="$(mktemp -d)"
    if mount -o ro "$ESP_PART" "$_esp_mnt" 2>/dev/null; then
        if [ -f "$_esp_mnt/EFI/BOOT/BOOTIA32.EFI" ]; then
            ESP_LOADER='\EFI\BOOT\BOOTIA32.EFI'
        elif [ -f "$_esp_mnt/EFI/BOOT/BOOTX64.EFI" ]; then
            ESP_LOADER='\EFI\BOOT\BOOTX64.EFI'
        fi
        umount "$_esp_mnt" 2>/dev/null || true
    fi
    rmdir "$_esp_mnt" 2>/dev/null || true
fi
[ -n "$ESP_LOADER" ] || ESP_LOADER='\EFI\BOOT\BOOTIA32.EFI'   # 兜底：IA32 那条两边固件都能加载

if [ "$SKIP_EFI_ENTRY" -eq 1 ]; then
    warn "按 --skip-efi-entry 明确跳过 EFI 启动项登记（这台机器开不了机时要手工登记）。"
    warn "  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'"
    EFI_ENTRY_DONE="skipped"
elif [ -z "$ESP_NO" ]; then
    die "在 $TARGET 上找不到 EFI System 分区（PARTTYPE ${ESP_TYPE}）—— 装机失败。
补救（先确认分区号，例如 ESP 是 p1）：
  lsblk -o NAME,PARTTYPE,PARTN $TARGET
  efibootmgr -c -d $TARGET -p <ESP分区号> -L 'QM1 Debian' -l '\\EFI\\BOOT\\BOOTIA32.EFI'
或用 U 盘跳板引导（见 README 的救援一节）。"
elif ! command -v efibootmgr >/dev/null 2>&1; then
    die "没有 efibootmgr（apt install efibootmgr）—— EFI 启动项没法登记，装机不算完成。
补救：装上 efibootmgr 后执行：
  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'
（确实无法登记时，可以加 --skip-efi-entry 显式跳过，但那样机器多半开不了机。）"
elif [ ! -d /sys/firmware/efi/efivars ]; then
    die "当前不是以 UEFI 方式启动（没有 /sys/firmware/efi/efivars）—— efibootmgr 没法写固件变量。
补救：在已装好的系统（用 UEFI 启动）里执行：
  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'
（确实无法登记时，可以加 --skip-efi-entry 显式跳过，但那样机器多半开不了机。）"
elif efibootmgr -c -d "$TARGET" -p "$ESP_NO" -L "QM1 Debian" -l "$ESP_LOADER"; then
    log "已登记 UEFI 启动项：QM1 Debian → $ESP_LOADER"
    EFI_ENTRY_DONE="yes"
else
    die "efibootmgr 登记启动项失败 —— 装机不算完成（机器会开不了机）。
补救：手工执行：
  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'
如果这台机器确实没法登记（例如固件不支持），请加 --skip-efi-entry 显式跳过。"
fi

# ---------- 9. 后续步骤 ----------
cat <<EOF

安装完成。接下来：

  1. 关机取出安装介质（或拔掉 U 盘），上电启动。
  2. 固件若不扫描内部存储的 \\EFI\\BOOT，用 U 盘跳板引导（见 README 的救援一节）。
  3. 首次开机后执行自检：
         sudo /usr/local/bin/qm1-selftest
  4. 装 agent 运行时（Hermes 官方安装方式 + Chrome 依赖）：
         sudo bash /usr/local/share/qm1/provision-agent.sh

  EFI 启动项：$EFI_ENTRY_DONE
EOF
