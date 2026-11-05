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
#   * 备份与 sha256 校验是硬前置，不可跳过（--no-backup 仅用于已确认无数据的盘）。
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

usage() {
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
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

# ---------- 6. 登记 UEFI 启动项 ----------
# 写完盘还不够：这台机器的固件不一定扫描内部存储的 \EFI\BOOT，
# 登记一条 UEFI 启动项才稳。找不到 ESP 就明说，别让人以为装好了。
#
# 登记**哪一个**引导器有个容易踩的坑：ESP 上有两条（make-esp.sh 写入）
#   \EFI\BOOT\BOOTIA32.EFI —— PE32（32 位）
#   \EFI\BOOT\BOOTX64.EFI  —— PE32+（64 位）
# **IA32 固件加载不了 PE32+ 的 BOOTX64.EFI**；而 64 位固件按 UEFI 规范
# 必须能加载 IA32 应用 ⇒ 只有 BOOTIA32.EFI 是"两种固件都能加载"的那条。
# 这台机器的固件就是 32 位 IA32 ⇒ 优先登记 BOOTIA32.EFI。
# （之前这里写死 BOOTX64.EFI：在 32 位固件上登记出来的是一条加载不了的启动项。）
ESP_NO=""
ESP_PART=""
ESP_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
while read -r _part _ptype _pno; do
    [ -n "${_ptype:-}" ] || continue
    case "$_ptype" in
        "$ESP_TYPE"|"${ESP_TYPE^^}") ESP_NO="$_pno"; ESP_PART="/dev/$_part"; break ;;
    esac
done < <(lsblk -nro NAME,PARTTYPE,PARTN "$TARGET" 2>/dev/null || true)

# 到目标 ESP 上看一眼实际有哪些引导器（只读挂载）
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

if [ -z "$ESP_NO" ]; then
    warn "在 $TARGET 上找不到 EFI System 分区（PARTTYPE $ESP_TYPE）—— 跳过 EFI 启动项登记。"
    warn "如果开机后找不到系统，请用 U 盘跳板引导，或手工执行："
    warn "  efibootmgr -c -d $TARGET -p <ESP分区号> -L 'QM1 Debian' -l '\\EFI\\BOOT\\BOOTIA32.EFI'"
elif ! command -v efibootmgr >/dev/null 2>&1; then
    warn "没有 efibootmgr（apt install efibootmgr）—— 跳过 EFI 启动项登记。"
    warn "  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'"
elif [ ! -d /sys/firmware/efi/efivars ]; then
    warn "当前不是以 UEFI 方式启动（没有 /sys/firmware/efi/efivars）—— 跳过 EFI 启动项登记。"
else
    if efibootmgr -c -d "$TARGET" -p "$ESP_NO" -L "QM1 Debian" -l "$ESP_LOADER"; then
        log "已登记 UEFI 启动项：QM1 Debian → $ESP_LOADER"
    else
        warn "efibootmgr 登记失败 —— 请手工执行："
        warn "  efibootmgr -c -d $TARGET -p $ESP_NO -L 'QM1 Debian' -l '$ESP_LOADER'"
    fi
fi

# ---------- 7. 后续步骤 ----------
cat <<EOF

安装完成。接下来：

  1. 关机取出安装介质（或拔掉 U 盘），上电启动。
  2. 固件若不扫描内部存储的 \\EFI\\BOOT，用 U 盘跳板引导（见 README 的救援一节）。
  3. 首次开机后执行自检：
         sudo /usr/local/bin/qm1-selftest
  4. 装 agent 运行时（Hermes 官方安装方式 + Chrome 依赖）：
         sudo bash /usr/local/share/qm1/provision-agent.sh

EOF
