#!/usr/bin/env bash
# build-image.sh — 由已构建的根文件系统生成可刷写的镜像产物
#
# 产物（分开存放，便于上传与复用）：
#   build/esp.img      FAT32 ESP（引导器 + 内核 + initrd + grub.cfg）
#   build/rootfs.img   ext4 根文件系统（直接由根目录树填充，无需挂载）
#   build/manifest.txt 尺寸、UUID、内核版本、SHA-256
#
# 之所以用 mkfs.ext4 -d 而不是"建镜像再挂载复制"：
#   挂载需要 root 与 loop 设备，CI 与受限容器里都不方便；-d 直接把目录树写进
#   文件系统，rootless 也能跑，且产物完全可复现。
#
# 用法：
#   bash scripts/build-image.sh --rootfs build/rootfs --out-dir build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOTFS=""
OUT_DIR="build"
ARCH="amd64"
# 默认 runtime：交付口径是"装进 eMMC、开机即用"，而 Hermes/Chrome 这套
# agent 运行时只出现在 runtime profile 里（hook04 按 QM1_PROFILE 决定装不装）。
# 默认曾经是 base ⇒ 谁按文档直接跑构建，谁就得到一个没有运行时、
# qm1-provision 单元的条件恒为假的镜像 ⇒ "开机即用"从一开始就不成立。
# 要最小系统请显式 --profile base。
PROFILE="runtime"
ESP_SIZE_MIB=256
ROOT_SIZE_GIB=6
BOOTLOADERS=""
KERNEL32=""
INITRD32=""
INSTALLER=0
DISK_SIZE_GIB=30
PROVISION_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --esp-size-mib) ESP_SIZE_MIB="$2"; shift 2 ;;
        --root-size-gib) ROOT_SIZE_GIB="$2"; shift 2 ;;
        --bootloaders) BOOTLOADERS="$2"; shift 2 ;;
        --kernel32) KERNEL32="$2"; shift 2 ;;
        --initrd32) INITRD32="$2"; shift 2 ;;
        --installer) INSTALLER=1; shift ;;
        --disk-size-gib) DISK_SIZE_GIB="$2"; shift 2 ;;
        --provision-dir) PROVISION_DIR="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

[ -n "$ROOTFS" ] || die "缺少 --rootfs"
[ -d "$ROOTFS/boot" ] || die "$ROOTFS 不像根文件系统（缺 /boot）"
need_cmd mkfs.ext4 "apt install e2fsprogs"
need_cmd sfdisk  "apt install fdisk"

mkdir -p "$OUT_DIR"

# ---------- 1. 定位内核与 initrd ----------
KVER="$(ls -1 "$ROOTFS/lib/modules" 2>/dev/null | sort -V | tail -1)"
[ -n "$KVER" ] || die "找不到内核版本（$ROOTFS/lib/modules 为空）"
KERNEL="$ROOTFS/boot/vmlinuz-$KVER"
INITRD="$ROOTFS/boot/initrd.img-$KVER"
[ -f "$KERNEL" ] || die "缺少内核：$KERNEL"
[ -f "$INITRD" ] || die "缺少 initrd：$INITRD"
log "内核：$KVER"

# ---------- 2. 引导器 ----------
if [ -z "$BOOTLOADERS" ]; then
    BOOTLOADERS="$OUT_DIR/bootloaders"
    log "构建双架构引导器 → $BOOTLOADERS"
    bash "$SCRIPT_DIR/build-bootloaders.sh" "$BOOTLOADERS"
fi

# ---------- 3. UUID ----------
ROOT_UUID="$(gen_uuid)"
ROOT32_UUID=""
if [ -n "$KERNEL32" ]; then
    ROOT32_UUID="$(gen_uuid)"
fi
log "根分区 UUID：$ROOT_UUID${ROOT32_UUID:+ / 32 位：$ROOT32_UUID}"

# ★ fstab 必须有 "/" 条目。
# 原来只有伪文件系统（proc/sys/devtmpfs/run/tmpfs），没有根分区条目：
#   * systemd 不会按 fstab 重新挂载根（options 不生效、remount-fs 没意义）
#   * systemd-fsck-root 不会检查根文件系统
#   * 某些工具（mount -a、systemctl daemon-reload 后的重挂载）会把根当成没挂
# UUID 在这里才确定（前面 mkfs.ext4 -U "$ROOT_UUID" 会写进超级块），
# 装机时整盘 dd 复制会把它一起带走，所以装到 eMMC 之后这条依然成立。
if [ -f "$ROOTFS/etc/fstab" ]; then
    if ! grep -qE '^[^#]*[[:space:]]/[[:space:]]' "$ROOTFS/etc/fstab"; then
        {
            echo "# 根分区：由内核 root=UUID= 挂载，这里补一条让 systemd 也能按 fstab 管理"
            echo "UUID=$ROOT_UUID / ext4 defaults,noatime 0 1"
        } >> "$ROOTFS/etc/fstab"
        log "已向 fstab 补上根分区条目（UUID=${ROOT_UUID}）"
    fi
    # ★ 补上 ESP 的挂载点。
    # 原来 fstab 里只有 "/" 一条 ⇒ 装进 eMMC 之后系统不挂 /boot/efi，
    # 凡是依赖 ESP 已挂载的工具（grub-install、部分引导脚本、查看引导器的
    # 脚本）都会说"找不到 ESP"。qm1-firstboot 自己是会挂 ESP 的，但那是
    # 它自己的逻辑，不代表系统里有一条正常的 ESP 挂载。
    #
    # 用卷标而不是 UUID：ESP 是 FAT32，卷标在 make-esp.sh 里写死成
    # $QM1_ESP_LABEL，装机时整盘 dd 会把它一起带走，所以标签订得住。
    #
    # nofail + device-timeout 是关键：**ESP 挂不上绝不能挡住开机**。
    # 我们这台机器的 Wi-Fi 是唯一链路，任何"开机要等某个挂载"的设计都会
    # 变成"没有网络就没有 SSH"。
    if ! grep -qE '^[^#]*[[:space:]]/boot/efi[[:space:]]' "$ROOTFS/etc/fstab"; then
        mkdir -p "$ROOTFS/boot/efi"
        {
            echo "# ESP：装进 eMMC 之后系统自己就能挂上引导分区"
            echo "LABEL=$QM1_ESP_LABEL /boot/efi vfat defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2"
        } >> "$ROOTFS/etc/fstab"
        log "已向 fstab 补上 ESP 挂载条目（LABEL=$QM1_ESP_LABEL → /boot/efi，nofail）"
    fi
fi

# 发行版名（菜单标题用）：从 rootfs 的构建信息里读
SUITE_NAME=""
if [ -f "$ROOTFS/etc/qm1-build-info" ]; then
    SUITE_NAME="$(sed -n 's/^suite=//p' "$ROOTFS/etc/qm1-build-info" | head -1)"
fi
[ -n "$SUITE_NAME" ] || SUITE_NAME="$ARCH"
case "$SUITE_NAME" in
    trixie)   SUITE_LABEL="Debian 13" ;;
    bookworm) SUITE_LABEL="Debian 12" ;;
    *)        SUITE_LABEL="$SUITE_NAME" ;;
esac

# ---------- 4. ESP ----------
ESP_IMG="$OUT_DIR/esp.img"
NORMAL_CFG="$OUT_DIR/grub-normal.cfg"
log "组装 ESP（arch=$ARCH suite=${SUITE_LABEL}）"
bash "$SCRIPT_DIR/make-esp.sh" \
    --out "$ESP_IMG" \
    --size-mib "$ESP_SIZE_MIB" \
    --bootloaders "$BOOTLOADERS" \
    --arch "$ARCH" \
    --suite-amd64 "Debian 13" \
    --kernel "$KERNEL" \
    --initrd "$INITRD" \
    ${KERNEL32:+--kernel32 "$KERNEL32"} \
    ${INITRD32:+--initrd32 "$INITRD32"} \
    --root-uuid "$ROOT_UUID" \
    ${ROOT32_UUID:+--root32-uuid "$ROOT32_UUID"} \
    ${PROVISION_DIR:+--provision-dir "$PROVISION_DIR"} \
    --write-config "$NORMAL_CFG"

# 4b. 安装介质用的 ESP：菜单多两项（装到 eMMC / 试用），
#     并把上面的正常菜单一起塞进去（安装脚本装完会把它拷回目标 ESP）。
INSTALLER_ESP_IMG=""
if [ "$INSTALLER" = 1 ]; then
    INSTALLER_ESP_IMG="$OUT_DIR/esp-installer.img"
    log "组装安装介质 ESP（菜单：安装到 eMMC / 试用 / 救援）"
    bash "$SCRIPT_DIR/make-esp.sh" \
        --out "$INSTALLER_ESP_IMG" \
        --size-mib "$ESP_SIZE_MIB" \
        --bootloaders "$BOOTLOADERS" \
        --arch "$ARCH" \
        --suite-amd64 "Debian 13" \
        --kernel "$KERNEL" \
        --initrd "$INITRD" \
        --root-uuid "$ROOT_UUID" \
        --config "$SCRIPT_DIR/grub-installer.cfg.example" \
        ${PROVISION_DIR:+--provision-dir "$PROVISION_DIR"} \
        --extra-grub "$NORMAL_CFG"
fi

# ---------- 5. 根文件系统 ----------
ROOT_IMG="$OUT_DIR/rootfs.img"

# 5.1 清空伪文件系统（/dev /proc /sys /run 运行时由内核挂载）。
#     构建期若挂过这些目录，残留内容会让 mkfs.ext4 -d 无法填充：
#     "Permission denied while opening ... to copy"（设备节点/套接字无法复制）。
for d in dev proc sys run; do
    if [ -d "$ROOTFS/$d" ]; then
        find "$ROOTFS/$d" -mindepth 1 -delete 2>/dev/null || true
    fi
done
mkdir -p "$ROOTFS"/{dev,proc,sys,run}

# 5.2 诊断：把非常规文件（设备节点/套接字/FIFO）与不可读项打出来，
#     真出问题时可直接从日志看出是哪一个路径挡住了 populate_fs。
special="$(find "$ROOTFS" -xdev \( -type b -o -type c -o -type s -o -type p \) -printf '%y %p\n' 2>/dev/null | head -20 || true)"
if [ -n "$special" ]; then
    log "警告：根文件系统里仍有非常规文件（会导致 mkfs.ext4 -d 失败）："
    printf '%s\n' "$special" >&2
fi

USED_KB="$(du -sk "$ROOTFS" | awk '{print $1}')"
NEED_KB=$((USED_KB + 1024 * 1024))          # 留 1 GiB 余量
TARGET_KB=$((ROOT_SIZE_GIB * 1024 * 1024))
[ "$NEED_KB" -gt "$TARGET_KB" ] && TARGET_KB=$(( NEED_KB + NEED_KB / 10 ))
log "根文件系统：占用 ${USED_KB} KiB → 目标 $((TARGET_KB/1024/1024)) GiB"
rm -f "$ROOT_IMG"
truncate -s "${TARGET_KB}K" "$ROOT_IMG"
mkfs.ext4 -q -F -L "$QM1_ROOT_LABEL" -U "$ROOT_UUID" -d "$ROOTFS" "$ROOT_IMG" \
    || die "mkfs.ext4 -d 失败（目标尺寸可能小于内容）"

# ---------- 6. 安装介质整盘镜像（可选） ----------
# 安装介质 = 同一套 ESP（菜单换成"安装到 eMMC"）+ 同一套根文件系统。
# 写进 U 盘、开机、选第 ① 项，就能把系统装到 eMMC（备份 → 写入 → 校验）。
INSTALLER_DISK_IMG=""
if [ "$INSTALLER" = 1 ] && [ -n "$INSTALLER_ESP_IMG" ]; then
    INSTALLER_DISK_IMG="$OUT_DIR/qm1-installer.img"
    log "合成安装介质整盘镜像：$INSTALLER_DISK_IMG"
    bash "$SCRIPT_DIR/assemble-disk.sh" \
        --esp "$INSTALLER_ESP_IMG" \
        --root "$ROOT_IMG" \
        --out "$INSTALLER_DISK_IMG" \
        --size-gib "$DISK_SIZE_GIB"
fi

# ---------- 7. 清单 ----------
MANIFEST="$OUT_DIR/manifest.txt"
{
    echo "# QM1-Debian image manifest"
    echo "arch=$ARCH profile=$PROFILE kernel=$KVER"
    echo "esp_label=$QM1_ESP_LABEL root_label=$QM1_ROOT_LABEL"
    echo "root_uuid=$ROOT_UUID"
    [ -n "$ROOT32_UUID" ] && echo "root32_uuid=$ROOT32_UUID"
    echo "esp_bytes=$(stat -c%s "$ESP_IMG")"
    echo "rootfs_bytes=$(stat -c%s "$ROOT_IMG")"
    if [ -n "$INSTALLER_DISK_IMG" ]; then
        echo "installer_disk=$INSTALLER_DISK_IMG"
        echo "installer_disk_bytes=$(stat -c%s "$INSTALLER_DISK_IMG")"
    fi
    echo "--- sha256 ---"
    ( cd "$OUT_DIR" && sha256sum esp.img rootfs.img )
} > "$MANIFEST"
cat "$MANIFEST" >&2
log "完成：$ESP_IMG + ${ROOT_IMG}（用 scripts/assemble-disk.sh 合成整盘镜像）"
