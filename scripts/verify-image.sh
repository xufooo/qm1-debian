#!/usr/bin/env bash
# verify-image.sh — 直接检查 ext4 镜像内容（不挂载，用 debugfs）
#
# 为什么用 debugfs 而不是 mount：
#   CI 与受限容器里挂载 ext4 需要 root + loop 设备；debugfs 直接读镜像里的
#   inode，既不需要特权，也能验证"属主/权限/文件是否存在"这些最容易在
#   打包阶段丢掉的东西（tar 解包与 mke2fs 分开跑会丢属主）。
#
# 用法：
#   bash scripts/verify-image.sh build/out/rootfs.img
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

IMG="${1:-}"
[ -n "$IMG" ] || die "用法：verify-image.sh <rootfs.img>"
[ -f "$IMG" ] || die "镜像不存在：$IMG"
need_cmd debugfs "apt install e2fsprogs"

fail=0

# 存在性检查：debugfs -R "stat <path>"
check_exists() {
    local path="$1" desc="$2"
    if debugfs -R "stat $path" "$IMG" >/dev/null 2>&1; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s) —— 镜像里没有这个路径\n' "$path" "$desc"
        fail=$((fail + 1))
    fi
}

# 属主/权限检查：stat 输出里的 User:/Group:/Mode:
check_attr() {
    local path="$1" regex="$2" desc="$3"
    local out
    out="$(debugfs -R "stat $path" "$IMG" 2>/dev/null || true)"
    # 用 herestring 而不是管道：管道里 grep -q 提前退出会给上游发 SIGPIPE，
    # 本脚本开了 pipefail，管道返回 141 会把"找到了"误判成"没找到"。
    if grep -qE "$regex" <<<"$out"; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s)\n' "$path" "$desc"
        printf '%s\n' "$out" | grep -E 'User:|Group:|Mode:' | sed 's/^/         /' >&2
        fail=$((fail + 1))
    fi
}

log "校验 ext4 镜像：$IMG"

echo "-- 属主与权限（打包阶段最容易丢的部分）--"
check_attr /etc/shadow    'Group: *42'  "shadow 组仍是 42(shadow)"
check_attr /usr/bin/sudo   'Mode: *04755' "sudo 保留 setuid 位"

echo "-- 定制层是否落进镜像 --"
check_exists /etc/default/zramswap                 "zram 配置（768M zstd）"
check_exists /etc/systemd/journald.conf.d/qm1.conf "journald 限额"
check_exists /etc/systemd/oomd.conf.d/qm1.conf     "systemd-oomd 限额"
check_exists /etc/modules-load.d/qm1-hardware.conf  "硬件模块自动加载清单"
check_exists /etc/initramfs-tools/modules          "initramfs 关键模块清单"
check_exists /usr/local/share/qm1/driver-manifest.txt "驱动清单"
check_exists /usr/local/lib/qm1/drv-selfcheck.sh    "设备端自检脚本"
check_exists /etc/wpa_supplicant/wpa_supplicant.conf "Wi-Fi 配置"
check_exists /etc/modprobe.d/qm1-rtl8723bs-in-tree.conf "RTL8723BS 驱动参数（关省电/20MHz）"
check_exists /etc/hostname                           "主机名"

echo "-- 内核与固件 --"
KVER="$(debugfs -R "ls -l /lib/modules" "$IMG" 2>/dev/null \
        | tr -s ' ' '\n' | grep -E '^[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
if [ -n "$KVER" ]; then
    printf '  OK   %-46s (%s)\n' "/lib/modules/$KVER" "内核模块目录"
    check_exists "/boot/vmlinuz-$KVER" "内核镜像"
    check_exists "/boot/initrd.img-$KVER" "initrd"
else
    printf '  FAIL %-46s (%s)\n' "/lib/modules/<ver>" "找不到内核模块目录"
    fail=$((fail + 1))
fi
fw_listing="$(debugfs -R "ls -l /lib/firmware" "$IMG" 2>/dev/null || true)"
for blob in brcmfmac4365-pcie.bin brcmfmac4352-pcie.bin rtl8723a_fw.bin; do
    if grep -q "$blob" <<<"$fw_listing"; then
        printf '  OK   %-46s (%s)\n' "/lib/firmware/$blob" "固件 blob"
    else
        printf '  WARN %-46s (%s) —— 无线芯片型号尚未确认，缺 blob 不致命\n' "/lib/firmware/$blob" "固件 blob"
    fi
done
# 内置 Realtek RTL8723BS 的 Wi-Fi blob 是 staging 驱动实际请求的文件名。
# 它在 rtlwifi/ 子目录下，上面的顶层 ls 看不到，必须单独 stat。
if debugfs -R "stat /lib/firmware/rtlwifi/rtl8723bs_nic.bin" "$IMG" >/dev/null 2>&1; then
    printf '  OK   %-46s (%s)\n' "/lib/firmware/rtlwifi/rtl8723bs_nic.bin" "内置 RTL8723BS Wi-Fi 固件"
else
    printf '  WARN %-46s (%s) —— 缺它则内置 Wi-Fi 无法工作（装 firmware-realtek）\n' \
        "/lib/firmware/rtlwifi/rtl8723bs_nic.bin" "内置 RTL8723BS Wi-Fi 固件"
fi

echo "-- 内置 Wi-Fi 驱动（rtw88 回移 / 树外 staging）--"
# 出货的 Wi-Fi 驱动有两条合法路径：
#   1) 上游 rtw88 整树回移成树外模块 rtw88_qm1（推荐，根治路径）
#      → 需要 rtw88/rtw8723b_fw.bin 固件 + /etc/modprobe.d/qm1-rtw88-8723bs.conf
#   2) 打 P1–P5 补丁的树外 staging 模块 r8723bs_qm1
#      → 需要 rtlwifi/rtl8723bs_nic.bin 固件
# 两条都必须是"驱动 + 固件"成对出现，只有一个等于 Wi-Fi 上不了网。
rtw88_ko=""
for _m in rtw88_qm1 rtw88_8723bs rtw_8723bs; do
    if [ -n "$KVER" ] && debugfs -R "stat /lib/modules/$KVER/extra/rtw88/$_m.ko" "$IMG" >/dev/null 2>&1; then
        rtw88_ko="/lib/modules/$KVER/extra/rtw88/$_m.ko"
        break
    fi
done
if [ -n "$rtw88_ko" ]; then
    printf '  OK   %-46s (%s)\n' "$rtw88_ko" "出货的 Wi-Fi 驱动（rtw88 回移模块）"
    check_exists "/lib/firmware/rtw88/rtw8723b_fw.bin" "rtw88 固件（缺它 rtw88 起不来）"
    check_exists "/etc/modprobe.d/qm1-rtw88-8723bs.conf" "rtw88 模块参数与树内 staging 的 blacklist"
else
    printf '  WARN %-46s (%s)\n' "/lib/modules/*/extra/rtw88/*.ko" "镜像里没有 rtw88 回移模块"
    # 没有 rtw88 时，树外补丁模块是唯一可用的根治路径
    if [ -n "$KVER" ] \
       && debugfs -R "stat /lib/modules/$KVER/extra/rtl8723bs/r8723bs_qm1.ko" "$IMG" >/dev/null 2>&1; then
        printf '  OK   %-46s (%s)\n' \
            "/lib/modules/$KVER/extra/rtl8723bs/r8723bs_qm1.ko" "出货的 Wi-Fi 驱动（打补丁的树外 staging 模块）"
    else
        printf '  FAIL %-46s (%s)\n' "/lib/modules/*/extra/*/*.ko" \
            "镜像里既没有 rtw88 回移模块，也没有打了补丁的 r8723bs_qm1 —— 内置 Wi-Fi 无法工作"
        fail=$((fail + 1))
    fi
fi

echo "-- 蓝牙（内核 hci_uart + btrtl + 发行版固件）--"
check_exists "/etc/systemd/system/qm1-bluetooth.service" "蓝牙初始化单元（内核路线）"
check_exists "/lib/firmware/rtl_bt/rtl8723bs_fw.bin" "蓝牙固件（缺它 btrtl 无法下发）"
check_exists "/lib/firmware/rtl_bt/rtl8723bs_config-OBDA8723.bin" "蓝牙配置固件（按 ACPI HID 取名）"

echo "-- 伪文件系统应为空 --"
for d in /dev /proc /sys /run; do
    n="$(debugfs -R "ls -l $d" "$IMG" 2>/dev/null | grep -cv '^d' || true)"
    if [ "${n:-0}" -le 1 ]; then
        printf '  OK   %-46s (%s)\n' "$d" "运行时由内核挂载，镜像内为空"
    else
        printf '  WARN %-46s (%s)\n' "$d" "镜像内还有内容（应为运行时挂载点）"
    fi
done

if [ "$fail" -gt 0 ]; then
    die "镜像校验失败：$fail 项不通过"
fi
log "镜像校验通过"
