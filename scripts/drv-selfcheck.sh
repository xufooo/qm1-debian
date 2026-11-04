#!/usr/bin/env bash
# drv-selfcheck.sh — QM1 设备端硬件自检（"保证硬件能够启动"的验收工具）
#
# 在目标机上运行，逐项检查硬件与驱动是否就位：
#   1) 启动关键路径：内核 / 根盘 / eMMC 控制器 / SDHCI / 文件系统
#   2) 外设：USB、显卡 i915、Intel HDA、Wi-Fi、蓝牙、RTC、温控
#   3) 资源：可用内存、zram、磁盘空间
#   4) 内核抱怨：firmware 加载失败、未绑定驱动
#
# 退出码：
#   0 = 无 BLOCK 级失败（可能有 WARN）
#   1 = 存在 BLOCK 级失败（启动关键路径缺失）
#
# 用法：
#   sudo bash drv-selfcheck.sh            # 表格输出
#   sudo bash drv-selfcheck.sh --json     # 追加机读 JSON
set -uo pipefail

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

PASS=0; WARN=0; FAIL=0
declare -a ROWS=()

GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'

row() {  # $1=状态(PASS/WARN/FAIL) $2=检查项 $3=实测值
    local st="$1" item="$2" val="${3:-}"
    case "$st" in
        PASS) PASS=$((PASS+1)) ;;
        WARN) WARN=$((WARN+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
    esac
    ROWS+=("$st|$item|$val")
    local color="$GREEN"; [ "$st" = WARN ] && color="$YELLOW"; [ "$st" = FAIL ] && color="$RED"
    printf '  %s%-4s%s %-34s %s\n' "$color" "$st" "$RESET" "$item" "$val"
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
mod_loaded() { grep -qw "$1" /proc/modules 2>/dev/null; }

printf '\033[1mQM1 硬件自检\033[0m  %s\n' "$(date -Is)"

# ---------------- 1. 启动关键路径 ----------------
section "启动关键路径"
if [ -r /proc/version ]; then
    row PASS "内核" "$(uname -r) ($(uname -m))"
else
    row FAIL "内核" "无法读取 /proc/version"
fi

if findmnt -no SOURCE / >/dev/null 2>&1; then
    src="$(findmnt -no SOURCE /)"
    fstype="$(findmnt -no FSTYPE /)"
    opts="$(findmnt -no OPTIONS /)"
    case "$opts" in
        *ro*) row FAIL "根文件系统可写" "$src 只读挂载" ;;
        *)     row PASS "根文件系统可写" "$src ($fstype)" ;;
    esac
else
    row FAIL "根文件系统可写" "根目录未挂载或不可读"
fi

# eMMC / SD 控制器
if [ -d /sys/class/mmc_host ]; then
    hosts="$(ls -1 /sys/class/mmc_host | tr '\n' ' ')"
    row PASS "MMC 控制器" "$hosts"
else
    row FAIL "MMC 控制器" "未发现 /sys/class/mmc_host —— eMMC 未被驱动接管（启动关键）"
fi

if [ -b /dev/mmcblk0 ]; then
    cap="$(cat /sys/block/mmcblk0/size 2>/dev/null | awk '{printf "%.1f GiB", $1*512/1024/1024/1024}')"
    parts="$(lsblk -ndo NAME /dev/mmcblk0 2>/dev/null | tail -n +2 | tr '\n' ' ')"
    row PASS "eMMC 块设备" "$cap 分区：$parts"
else
    row FAIL "eMMC 块设备" "缺少 /dev/mmcblk0"
fi

for m in sdhci_pci sdhci_acpi mmc_block; do
    if mod_loaded "$m" || [ -d "/sys/module/$m" ]; then
        row PASS "模块 $m" "已加载"
    else
        row WARN "模块 $m" "未加载（可能由另一条路径驱动，或为内置）"
    fi
done

for m in vfat ext4; do
    if [ -d "/sys/module/$m" ]; then row PASS "文件系统 $m" "已加载"; else row WARN "文件系统 $m" "未加载"; fi
done

# ---------------- 2. 外设 ----------------
section "外设"
if [ -d /sys/class/drm ]; then
    cards=""
    for c in /sys/class/drm/card[0-9]*; do
        [ -e "$c" ] || continue
        cards="$cards $(basename "$c")"
    done
    drv="$(cat /sys/class/drm/card0/device/driver/module 2>/dev/null | xargs -r basename)"
    row PASS "显示设备" "cards=${cards:-无} driver=${drv:-未知}"
    [ -n "$drv" ] || row WARN "显示驱动" "未绑定驱动（HDMI 可能无输出）"
else
    row WARN "显示设备" "无 /sys/class/drm"
fi

if [ -s /proc/asound/cards ] 2>/dev/null; then
    row PASS "声卡" "$(head -1 /proc/asound/cards | cut -c1-60)"
else
    row WARN "声卡" "未发现声卡"
fi

ifs=""
wlan_found=0
wlan_drv=""
for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    nm="$(basename "$n")"
    [ "$nm" = "lo" ] && continue
    ifs="$ifs $nm"
    case "$nm" in
        wl*)
            wlan_found=1
            # 报出真实绑定驱动：只认接口名会把"驱动没起来"误判成"Wi-Fi 就绪"
            d="$(readlink -f "/sys/class/net/$nm/device/driver" 2>/dev/null | xargs -r basename)"
            [ -n "$d" ] && wlan_drv="$wlan_drv $nm:$d"
            ;;
    esac
done

if [ -n "$ifs" ]; then
    row PASS "网络接口" "$ifs"
    if [ "$wlan_found" = "1" ]; then
        row PASS "无线接口" "存在（绑定驱动：${wlan_drv:-未知}）"
        case "$wlan_drv" in
            *r8723bs_qm1*)
                # 打了补丁的外部模块（patches/rtl8723bs/），永久卡死路径已修
                row PASS "无线驱动 r8723bs_qm1" "已打补丁的外部模块（永久卡死路径已修）"
                fw8723=""
                for p in /lib/firmware/rtlwifi/rtl8723bs_nic.bin \
                         /usr/lib/firmware/rtlwifi/rtl8723bs_nic.bin; do
                    [ -f "$p" ] && fw8723="$p"
                done
                if [ -n "$fw8723" ]; then
                    row PASS "rtl8723bs 固件" "$fw8723"
                else
                    row FAIL "rtl8723bs 固件" "缺 rtl8723bs_nic.bin（装 firmware-realtek）"
                fi
                pm="$(cat /sys/module/r8723bs_qm1/parameters/rtw_power_mgnt 2>/dev/null || echo '?')"
                ips="$(cat /sys/module/r8723bs_qm1/parameters/rtw_ips_mode 2>/dev/null || echo '?')"
                bw="$(cat /sys/module/r8723bs_qm1/parameters/rtw_bw_mode 2>/dev/null || echo '?')"
                if [ "$pm" = "0" ] && [ "$ips" = "0" ] && [ "$bw" = "0" ]; then
                    row PASS "r8723bs_qm1 省电/带宽" "rtw_power_mgnt=$pm rtw_ips_mode=$ips rtw_bw_mode=$bw"
                else
                    row WARN "r8723bs_qm1 省电/带宽" \
                        "rtw_power_mgnt=$pm rtw_ips_mode=$ips rtw_bw_mode=$bw —— 应为 0 0 0（见 /etc/modprobe.d/qm1-rtl8723bs.conf）"
                fi
                ;;
            *r8723bs*)
                # 发行版内置 staging 驱动：只支持 WPA2，且存在永久卡死路径
                row WARN "无线驱动 r8723bs" \
                    "发行版内置 staging 驱动：仅 WPA2-PSK（无 WPA3/SAE），数据帧无逐包反馈、速率静态查表，且存在永久卡死路径（丢一次 SDIO 中断即可能永久断流）—— 建议改用打了补丁的 r8723bs_qm1 外部模块"
                fw8723=""
                for p in /lib/firmware/rtlwifi/rtl8723bs_nic.bin \
                         /usr/lib/firmware/rtlwifi/rtl8723bs_nic.bin; do
                    [ -f "$p" ] && fw8723="$p"
                done
                if [ -n "$fw8723" ]; then
                    row PASS "rtl8723bs 固件" "$fw8723"
                else
                    row FAIL "rtl8723bs 固件" "缺 rtl8723bs_nic.bin（装 firmware-realtek）"
                fi
                # 模块参数：省电会挡住 TX（离开省电看门狗 2 秒），40MHz 有随机断连报告
                pm="$(cat /sys/module/r8723bs/parameters/rtw_power_mgnt 2>/dev/null || echo '?')"
                ips="$(cat /sys/module/r8723bs/parameters/rtw_ips_mode 2>/dev/null || echo '?')"
                bw="$(cat /sys/module/r8723bs/parameters/rtw_bw_mode 2>/dev/null || echo '?')"
                if [ "$pm" = "0" ] && [ "$ips" = "0" ] && [ "$bw" = "0" ]; then
                    row PASS "r8723bs 省电/带宽" "rtw_power_mgnt=$pm rtw_ips_mode=$ips rtw_bw_mode=$bw"
                else
                    row WARN "r8723bs 省电/带宽" \
                        "rtw_power_mgnt=$pm rtw_ips_mode=$ips rtw_bw_mode=$bw —— 应为 0 0 0（见 /etc/modprobe.d/qm1-rtl8723bs-in-tree.conf）"
                fi
                ;;
        esac
    else
        row WARN "无线接口" "未发现 wlan* —— Wi-Fi 未启用或驱动缺失（内置 RTL8723BS 需 r8723bs 模块 + rtl8723bs_nic.bin）"
    fi
else
    row WARN "网络接口" "除 lo 外无接口"
fi

if [ -d /sys/class/bluetooth ]; then
    bt=""
    for b in /sys/class/bluetooth/*; do
        [ -e "$b" ] || continue
        bt="$bt $(basename "$b")"
    done
    row PASS "蓝牙" "$bt"
else
    row WARN "蓝牙" "未发现蓝牙适配器"
fi

if [ -d /sys/class/rtc ]; then
    rtc=""
    for r in /sys/class/rtc/rtc[0-9]*; do
        [ -e "$r" ] || continue
        rtc="$rtc $(basename "$r")"
    done
    row PASS "RTC" "$rtc"
else
    row WARN "RTC" "未发现 RTC"
fi

if [ -d /sys/class/thermal ]; then
    zones=0
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z" ] || continue
        zones=$((zones + 1))
    done
    row PASS "温控" "$zones 个 thermal_zone"
else
    row WARN "温控" "未发现 thermal_zone"
fi

# ---------------- 3. 资源 ----------------
section "资源"
if [ -r /proc/meminfo ]; then
    avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
    total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    row PASS "内存" "总计 $((total_kb/1024)) MiB，可用 $((avail_kb/1024)) MiB"
    [ "$avail_kb" -lt 204800 ] && row WARN "内存余量" "可用内存 < 200 MiB（Hermes+Chrome 需要约 1.1 GiB）"
fi
if [ -r /proc/swaps ]; then
    swap_mib="$(awk 'NR>1 && $1!="Filename"{s+=$3} END{printf "%.0f", s/1024}' /proc/swaps)"
    row PASS "交换" "${swap_mib:-0} MiB（zram 建议 768 MiB）"
fi
df -h / | tail -1 | awk '{printf "  %-4s 根分区空间 %s 已用 / %s 可用\n", "PASS", $3, $4}' >/dev/null
if have df; then
    row PASS "根分区空间" "$(df -h / | awk 'NR==2{print $3" 已用 / "$4" 可用 ("$5")"}')"
fi

# ---------------- 4. 内核抱怨 ----------------
section "内核抱怨"
fw_fail="$(dmesg 2>/dev/null | grep -c 'Direct firmware load for .* failed')"
if [ "${fw_fail:-0}" -gt 0 ]; then
    row WARN "firmware 加载失败" "$fw_fail 条 —— 见下方明细（多为 Wi-Fi/BT blob 缺失）"
    dmesg | grep 'Direct firmware load for .* failed' | tail -5 | sed 's/^/      /'
else
    row PASS "firmware 加载失败" "无"
fi
nodrv="$(dmesg 2>/dev/null | grep -ci 'no driver for')"
if [ "${nodrv:-0}" -gt 0 ]; then
    row WARN "未绑定驱动" "$nodrv 条"
    grep -i 'no driver for' <<<"$dmesg_out" | tail -5 | sed 's/^/      /'
else
    row PASS "未绑定驱动" "无"
fi
# 先把 dmesg 收进变量再用 herestring 匹配：管道 + grep -q 在 pipefail 下会因
# SIGPIPE 返回 141，误判成"没有 I/O 错误"。
dmesg_out="$(dmesg 2>/dev/null || true)"
if grep -qi 'I/O error\|Buffer I/O error' <<<"$dmesg_out"; then
    row FAIL "存储 I/O 错误" "dmesg 有 I/O error —— eMMC 或供电可能有问题"
    grep -i 'I/O error\|Buffer I/O error' <<<"$dmesg_out" | tail -5 | sed 's/^/      /'
else
    row PASS "存储 I/O 错误" "无"
fi

# ---------------- 汇总 ----------------
printf '\n\033[1m== 汇总 ==\033[0m\n'
printf '  PASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$JSON" = "1" ]; then
    printf '{"pass":%d,"warn":%d,"fail":%d,"checks":[' "$PASS" "$WARN" "$FAIL"
    first=1
    for r in "${ROWS[@]}"; do
        st="${r%%|*}"; rest="${r#*|}"; item="${rest%%|*}"; val="${rest#*|}"
        [ $first -eq 1 ] || printf ','
        first=0
        printf '{"status":"%s","item":"%s","value":"%s"}' "$st" "$item" "$val"
    done
    printf ']}\n'
fi

[ "$FAIL" -gt 0 ] && exit 1
exit 0
