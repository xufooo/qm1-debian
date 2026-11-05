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

GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'

row() {  # $1=状态(PASS/WARN/FAIL/INFO) $2=检查项 $3=实测值
    local st="$1" item="$2" val="${3:-}"
    case "$st" in
        PASS) PASS=$((PASS+1)) ;;
        WARN) WARN=$((WARN+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        INFO) ;;   # 只做记录，不计入统计
    esac
    ROWS+=("$st|$item|$val")
    local color="$GREEN"; [ "$st" = WARN ] && color="$YELLOW"; [ "$st" = FAIL ] && color="$RED"; [ "$st" = INFO ] && color="$CYAN"
    printf '  %s%-4s%s %-34s %s\n' "$color" "$st" "$RESET" "$item" "$val"
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
mod_loaded() { grep -qw "$1" /proc/modules 2>/dev/null; }

# 一次性把 dmesg 收进变量。
#
# 两个坑：
#   1) 管道 + grep -q 在 pipefail 下会因 SIGPIPE 返回 141，误判成"没有匹配"
#      ⇒ 统一用 herestring 在变量上匹配。
#   2) 赋值必须**早于**任何使用处。原来的写法把赋值放在第 4 节末尾，而
#      第 4 节开头就已经用了 $dmesg_out —— set -u 下那是未绑定变量，整个
#      自检脚本当场退出（正好是在系统真出问题时退出，最需要诊断结果时
#      拿不到诊断）。现在提到最前面。
dmesg_out="$(dmesg 2>/dev/null || true)"

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

# eMMC / SD 块设备
#
# 不能把 /dev/mmcblk0 当成 eMMC：QM1 上 mmc0 是 Wi-Fi 的 SDIO 卡
# （Realtek RTL8723BS，AzureWave 模组），eMMC 实际是 mmc1
# （实机观测 mmc1 = ACPI 80860F14:00 = SanDisk S10032 28.5 GiB）。
# 内核在 MMC 卡的 device/type 里给出 "MMC"(eMMC) / "SD"(SD 卡)，据此判定。
mmc_summary=""
emmc_blk=""
emmc_card_dev=""
sd_blk=""
for b in /sys/class/block/mmcblk*; do
    [ -e "$b" ] || continue
    _blk="$(basename "$b")"
    _dev="$(readlink -f "$b/device" 2>/dev/null || true)"
    _kind="?"
    [ -n "$_dev" ] && [ -r "$_dev/type" ] && _kind="$(cat "$_dev/type" 2>/dev/null || echo '?')"
    _cap="$(cat "$b/size" 2>/dev/null | awk '{printf "%.1fGiB", $1*512/1024/1024/1024}')"
    mmc_summary="$mmc_summary ${_blk}[${_kind} ${_cap:-?}]"
    if [ "$_kind" = "MMC" ]; then
        emmc_blk="/dev/$_blk"
        emmc_card_dev="$_dev"
    fi
    [ "$_kind" = "SD" ] && sd_blk="$_blk"
done
if [ -n "$emmc_blk" ]; then
    _parts="$(lsblk -ndo NAME "$emmc_blk" 2>/dev/null | tail -n +2 | tr '\n' ' ')"
    row PASS "eMMC 块设备" "$emmc_blk（type=MMC）分区：${_parts:-无}　全部 mmc：${mmc_summary}"
elif [ -n "$mmc_summary" ]; then
    row FAIL "eMMC 块设备" "没有找到 type=MMC 的 eMMC（只看到：${mmc_summary}）"
else
    row FAIL "eMMC 块设备" "未发现任何 MMC 块设备"
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

# 整机到得了 multi-user.target 吗？
#
# 这是"开机即用"的底线：多用户目标到不了 ⇒ SSH 起不来 ⇒ 看起来像砖了。
# 之前就栽在这上面 —— Wi-Fi 单元的 ExecStartPre 在等 SDIO 枚举 wlan0，
# 它的 start job 永不完成，而 multi-user.target 会对 Wants= 的成员
# 隐式补 After=，于是整机永远停在那儿。
# is-system-running 在 degraded 时也会返回非零，所以要兜住。
_state="$(systemctl is-system-running 2>/dev/null || true)"
case "$_state" in
    running)  row PASS "系统状态" "running —— 已到 multi-user.target" ;;
    degraded) row WARN "系统状态" "degraded —— 已到 multi-user.target，但有单元失败（看下面的 FAIL 行）" ;;
    *)        row FAIL "系统状态" "${_state:-未知} —— 没到 multi-user.target，SSH 可能根本没起来" ;;
esac

# 只有一套内核？
#
# 曾经出过"签名内核与 -unsigned 内核互 Conflicts ⇒ apt 把内核换掉"的坑。
# 两套内核并存时，模块的 vermagic 会对不上 ⇒ 驱动装上了也不认。
_kvers="$(ls -1 /lib/modules 2>/dev/null | tr '\n' ' ')"
_kcount="$(ls -1 /lib/modules 2>/dev/null | wc -l | tr -d ' ')"
if [ "${_kcount:-0}" -le 1 ]; then
    row PASS "内核套数" "${_kcount:-0} 套（${_kvers:-无}）"
else
    row FAIL "内核套数" "${_kcount} 套内核并存：${_kvers} —— 模块 vermagic 会对不上，删掉多余的那套"
fi

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
wlan_mod=""
for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    nm="$(basename "$n")"
    [ "$nm" = "lo" ] && continue
    ifs="$ifs $nm"
    case "$nm" in
        wl*)
            wlan_found=1
            # 报出真实绑定的驱动与模块：只认接口名会把"驱动没起来"误判成"Wi-Fi 就绪"。
            #
            # 分类要看**模块名**（/sys/class/net/wlan0/device/driver/module 的 basename
            # = KBUILD_MODNAME），不要看 driver 目录名：
            #   * 树外整树回移的出货模块 = rtw88_qm1（上游把 8723B/BS 并进 rtw88 后
            #     整个树编成一个模块，模块名就是 KBUILD_MODNAME）；
            #   * 树内 staging = r8723bs；打了 P1–P5 补丁的树外 staging = r8723bs_qm1。
            # 之前只按 driver 名匹配 rtw88_8723bs / rtw_8723bs，出货的 rtw88_qm1
            # 一个都不匹配 ⇒ 自检对实际在用的驱动完全静默。
            d="$(readlink -f "/sys/class/net/$nm/device/driver" 2>/dev/null | xargs -r basename)"
            m="$(readlink -f "/sys/class/net/$nm/device/driver/module" 2>/dev/null | xargs -r basename)"
            [ -n "$d" ] && wlan_drv="$wlan_drv $nm:$d"
            [ -n "$m" ] && wlan_mod="$wlan_mod $nm:$m"
            ;;
    esac
done

if [ -n "$ifs" ]; then
    row PASS "网络接口" "$ifs"
    if [ "$wlan_found" = "1" ]; then
        row PASS "无线接口" "存在（绑定驱动：${wlan_drv:-未知}　模块：${wlan_mod:-未知}）"
        # 分类依据是模块名（KBUILD_MODNAME）
        case "$wlan_mod" in
            *rtw88_qm1*|*rtw88_8723bs*|*rtw_8723bs*)
                # rtw88 回移模块（上游 7.4 的 8723b/8723bs 支持，按镜像内核回移）：
                # staging 驱动那 4 条永久卡死路径在上游已被重写，不再存在。
                row PASS "无线驱动 rtw88" "rtw88 回移模块（上游 7.4 的 RTL8723BS 支持，staging 卡死路径已在上游修掉）"
                fw8723=""
                for p in /lib/firmware/rtw88/rtw8723b_fw.bin \
                         /usr/lib/firmware/rtw88/rtw8723b_fw.bin; do
                    [ -f "$p" ] && fw8723="$p"
                done
                if [ -n "$fw8723" ]; then
                    row PASS "rtw8723b 固件" "$fw8723"
                else
                    row FAIL "rtw8723b 固件" "缺 rtw88/rtw8723b_fw.bin（Debian 13 的 firmware-realtek 不含该 blob）"
                fi
                # ★ 镜像下发的三个参数必须**运行期**核对。
                #   构建期（build 脚本）确认过参数存在，CI 也确认了 conf 里有
                #   options 行，但没有任何一个脚本在真机上读回实际生效值 ——
                #   参数写错、被别的 conf 覆盖、模块换了名字，都会静默通过。
                #   这三个参数正是用来压住 8723BS 的省电/死锁路径的：
                #   disable_lps_deep 关掉深度省电（否则 TX 被看门狗卡住），
                #   support_bf 开 beamforming，debug_mask=0 关调试打印。
                #
                # 两个坑：
                #   a) 上游这三个参数定义在**核心**模块（core.c/main.c）上
                #      （module_param_named(disable_lps_deep, ..., bool, 0644)），
                #      而 wlan0 绑定的模块是 SDIO 那个 —— 整树编译成一个模块时
                #      两者同名，分开编译时不是。所以这里在所有 rtw* 模块里
                #      找**真正持有该参数**的那个，不死绑 wlan 的模块名。
                #   b) bool 型参数在 sysfs 里读回来是 "Y"/"N"，不是 "1"/"0"
                #      （kernel/params.c 的 param_get_bool 输出的是字母）。
                #      拿 "1" 去比，会把正确的配置判成 FAIL。
                _rtw_owner=""
                for _m in /sys/module/rtw*; do
                    [ -e "$_m/parameters/disable_lps_deep" ] || continue
                    _rtw_owner="$(basename "$_m")"
                    break
                done
                _p_lps='?'; _p_bf='?'; _p_dbg='?'
                if [ -n "$_rtw_owner" ]; then
                    _p_lps="$(cat "/sys/module/$_rtw_owner/parameters/disable_lps_deep" 2>/dev/null || echo '?')"
                    _p_bf="$(cat "/sys/module/$_rtw_owner/parameters/support_bf" 2>/dev/null || echo '?')"
                    _p_dbg="$(cat "/sys/module/$_rtw_owner/parameters/debug_mask" 2>/dev/null || echo '?')"
                fi
                # bool 真值：Y/y/1/true/on
                _bool_true() {
                    case "$1" in
                        Y|y|1|true|TRUE|on|ON) return 0 ;;
                        *) return 1 ;;
                    esac
                }
                if [ -n "$_rtw_owner" ] \
                   && _bool_true "$_p_lps" && _bool_true "$_p_bf" \
                   && [ "$_p_dbg" = "0" ]; then
                    row PASS "rtw88 省电/参数" \
                        "disable_lps_deep=$_p_lps support_bf=$_p_bf debug_mask=$_p_dbg（模块 $_rtw_owner）"
                else
                    row FAIL "rtw88 省电/参数" \
                        "disable_lps_deep=$_p_lps support_bf=$_p_bf debug_mask=$_p_dbg（模块 ${_rtw_owner:-未找到持有该参数的 rtw 模块}）—— 前两项须为真、debug_mask 须为 0（见 /etc/modprobe.d/qm1-rtw88-8723bs.conf；disable_lps_deep 不为真会被省电看门狗卡住 TX）"
                fi
                ;;
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
        row WARN "无线接口" \
            "未发现 wlan* —— Wi-Fi 未启用或驱动缺失。出货路径有两条：rtw88 回移模块（rtw88_qm1 + rtw88/rtw8723b_fw.bin，见 /etc/modprobe.d/qm1-rtw88-8723bs.conf）或打了补丁的树外 staging 模块（r8723bs_qm1 + rtlwifi/rtl8723bs_nic.bin）；发行版树内 staging（r8723bs）有永久卡死路径，只能当最后回退"
    fi
else
    row WARN "网络接口" "除 lo 外无接口"
fi

# ---------------- 蓝牙 ----------------
# 内置蓝牙 = Realtek RTL8723BS 的 BT 部分，经 ACPI 枚举的 UART 挂在主机上
# （ACPI HID OBDA8723 / OBDA0623）。
#
# 路线只有一条：内核 hci_uart（含 hci_h5 的 3WIRE 协议）负责传输，
# btrtl 负责取厂商固件 rtl_bt/rtl8723bs_fw.bin 与
# rtl_bt/rtl8723bs_config-OBDA8723.bin 下发给控制器。
# 用户态 rtk_hciattach 已从镜像里删除 —— 它和内核抢同一个串口，
# 结果是两边都没有 hci0。
bt_state=""
if [ -d /sys/class/bluetooth ]; then
    for b in /sys/class/bluetooth/*; do
        [ -e "$b" ] || continue
        bt_state="$bt_state $(basename "$b")"
    done
fi
if [ -n "$bt_state" ]; then
    row PASS "蓝牙" "hci 设备：$bt_state"
else
    row WARN "蓝牙" "没有 hci 设备 —— 内核没绑定上 BT UART"
fi
for m in hci_uart btrtl; do
    if mod_loaded "$m" || [ -d "/sys/module/$m" ]; then
        row PASS "模块 $m" "已加载"
    else
        row WARN "模块 $m" "未加载 —— 内核蓝牙栈没起来"
    fi
done
bt_fw=""
for p in /lib/firmware/rtl_bt/rtl8723bs_fw.bin \
         /usr/lib/firmware/rtl_bt/rtl8723bs_fw.bin; do
    [ -f "$p" ] && bt_fw="$p"
done
if [ -n "$bt_fw" ]; then
    row PASS "蓝牙固件" "$bt_fw"
else
    row FAIL "蓝牙固件" "缺 rtl_bt/rtl8723bs_fw.bin（需要 firmware-realtek）"
fi
if [ -z "$bt_state" ]; then
    # 没有 hci0 时给出可操作的线索，而不是一句"没蓝牙"
    _btlog="$(grep -iE 'OBDA8723|OBDA0623|hci_uart|hci0|rtl8723bs|Bluetooth' <<<"$dmesg_out" \
              | tail -4 | sed 's/^/      /')"
    if [ -n "$_btlog" ]; then
        row INFO "蓝牙线索" "$_btlog"
        row INFO "蓝牙排查" "内核没绑定 OBDA8723 时，多半是 DSDT 把这个 ACPI 设备暴露成了普通 16550 串口（8250 抢先绑定）—— 需要 DSDT 覆盖"
    fi
fi

# 蓝牙的 ACPI HID：这台机的 BT UART 是靠它暴露的（上游 hci_h5 的
# h5_acpi_match[] 认的就是 OBDA8723 / OBDA0623）。
#
# 镜像里的 qm1-bluetooth-up **只有看到这个 HID 才会 modprobe hci_uart**：
# 没有 HID 就加载 hci_uart 没有可绑定的串口，纯属白占一个 uart 端口
# （在 CI 的 QEMU 里它还把串口控制台搅黄了 —— 整机到不了 multi-user.target）。
# 所以这里既要看 HID 在不在，也要看它被谁认领：8250 抢先绑定 ⇒ 内核绑不上。
_bt_hid=""
_bt_owner=""
for _d in /sys/bus/acpi/devices/*; do
    [ -e "$_d" ] || continue
    _hid="$(cat "$_d/hid" 2>/dev/null || true)"
    case "$(printf '%s' "$_hid" | tr 'a-z' 'A-Z')" in
        OBDA8723|OBDA0623)
            _bt_hid="$_hid"
            _bt_owner="$(basename "$(readlink -f "$_d/driver" 2>/dev/null || echo unknown)" 2>/dev/null || echo unknown)"
            ;;
    esac
done
if [ -n "$_bt_hid" ]; then
    if [ -d /sys/class/bluetooth/hci0 ]; then
        row PASS "蓝牙 ACPI" "HID=$_bt_hid 已被 ${_bt_owner:-未知} 认领，hci0 已出现"
    else
        row FAIL "蓝牙 ACPI" "HID=$_bt_hid 存在（认领者=${_bt_owner:-未知}）却没有 hci0 —— 8250 抢占了那条串口，需要 DSDT 覆盖"
    fi
else
    row WARN "蓝牙 ACPI" "没有 OBDA8723/OBDA0623 ⇒ DSDT 没把蓝牙 UART 暴露出来，镜像因此**故意没有**加载 hci_uart"
fi
# 没加载也要留痕：原因写在标记文件里，别让它悄悄消失
if [ -f /run/qm1-bluetooth.failed ]; then
    row INFO "蓝牙失败标记" "$(tr '\n' ' ' < /run/qm1-bluetooth.failed)"
else
    row INFO "蓝牙失败标记" "没有 /run/qm1-bluetooth.failed（蓝牙这一项没有失败记录）"
fi

if [ -d /sys/class/rtc ]; then
    rtc=""
    for r in /sys/class/rtc/rtc[0-9]*; do
        [ -e "$r" ] || continue
        rtc="$rtc $(basename "$r")"
    done
    row PASS "RTC" "$rtc"
else
    # Bay Trail-T 上开着 CONFIG_PINCTRL_BAYTRAIL 可能导致 /dev/rtc0 不出现
    # （上游邮件列表 2015-07-11 的实证），所以这不一定是故障。
    row WARN "RTC" "未发现 RTC —— 注意：Bay Trail-T 上 CONFIG_PINCTRL_BAYTRAIL=y 会让 /dev/rtc0 消失（已知取舍，不一定是故障）"
fi

# C-state 深度：内核参数 intel_idle.max_cstate=1 应把最深空闲态限制在 C1。
# 依据：Z3735F 在 Bay Trail 的 C-state 冻结 bug 受影响名单内（Ubuntu Launchpad #1471989），
# 且深 C-state 与 SDIO/eMMC 的 DMA 冲突同源（watchmysys 实测）。
if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
    deep=""
    for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        [ -e "$s" ] || continue
        [ "$(cat "$s/disable" 2>/dev/null || echo 0)" = "1" ] || deep="$deep $(basename "$s")"
    done
    if [ -z "$deep" ]; then
        row PASS "C-state" "最深空闲态已限制在 C1（intel_idle.max_cstate=1 生效）"
    else
        row WARN "C-state" "以下空闲态仍可用：$deep —— 检查内核参数 intel_idle.max_cstate=1（Bay Trail 冻结 bug 与 eMMC DMA 冲突都跟它有关）"
    fi
else
    row WARN "C-state" "没有 cpuidle 状态目录，无法确认 intel_idle.max_cstate=1 是否生效"
fi

# 硬件无线开关（rfkill）：内置 Wi-Fi 走 SDIO，若有 rfkill 节点但处于 soft-block，
# wpa_supplicant 会连不上。
if [ -d /sys/class/rfkill ]; then
    rf=""
    for k in /sys/class/rfkill/rfkill*; do
        [ -e "$k" ] || continue
        soft="$(cat "$k/soft" 2>/dev/null || echo '?')"
        hard="$(cat "$k/hard" 2>/dev/null || echo '?')"
        rf="$rf $(basename "$k")(soft=$soft,hard=$hard)"
    done
    row PASS "rfkill" "$rf"
else
    row WARN "rfkill" "没有 rfkill 节点（内置 Wi-Fi 是 SDIO 设备，一般不会有独立开关 —— 若社区反馈过 rfkill-gpio 缺 ACPI id，这属预期）"
fi

# 声卡拓扑：Bay Trail 的 HDMI 音频走 i915 的 hdmi_lpe_audio，社区有 blacklist 的建议，
# 但本机模拟输出是否走 realtek codec 需要实机核对。
if command -v aplay >/dev/null 2>&1; then
    cards="$(aplay -l 2>/dev/null | grep -c '^card ' || true)"
    row PASS "声卡" "aplay 看到 ${cards:-0} 张卡（HDMI 音频由 i915 提供，模拟输出取决于 codec）"
else
    row WARN "声卡" "没有 aplay（未装 alsa-utils），无法核对声卡拓扑"
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
    # 以前这里一律 PASS —— 于是"zram 根本没启用"这件事永远查不出来
    # （配置在 /etc/default/zramswap 不等于 zram 设备在跑）。
    if [ "${swap_mib:-0}" -ge 64 ]; then
        row PASS "交换" "${swap_mib} MiB（zram 建议 768 MiB）"
    else
        row FAIL "交换" "${swap_mib:-0} MiB —— 几乎没有交换空间（zram 没起来？检查 zramswap.service）"
    fi
fi
df -h / | tail -1 | awk '{printf "  %-4s 根分区空间 %s 已用 / %s 可用\n", "PASS", $3, $4}' >/dev/null
if have df; then
    row PASS "根分区空间" "$(df -h / | awk 'NR==2{print $3" 已用 / "$4" 可用 ("$5")"}')"
fi

# ---------------- 4. 内核抱怨 ----------------
section "内核抱怨"
fw_fail="$(grep -c 'Direct firmware load for .* failed' <<<"$dmesg_out" || true)"
if [ "${fw_fail:-0}" -gt 0 ]; then
    row WARN "firmware 加载失败" "$fw_fail 条 —— 见下方明细（多为 Wi-Fi/BT blob 缺失）"
    grep 'Direct firmware load for .* failed' <<<"$dmesg_out" | tail -5 | sed 's/^/      /'
else
    row PASS "firmware 加载失败" "无"
fi
nodrv="$(grep -ci 'no driver for' <<<"$dmesg_out" || true)"
if [ "${nodrv:-0}" -gt 0 ]; then
    row WARN "未绑定驱动" "$nodrv 条"
    grep -i 'no driver for' <<<"$dmesg_out" | tail -5 | sed 's/^/      /'
else
    row PASS "未绑定驱动" "无"
fi
if grep -qi 'I/O error\|Buffer I/O error' <<<"$dmesg_out"; then
    row FAIL "存储 I/O 错误" "dmesg 有 I/O error —— eMMC 或供电可能有问题"
    grep -i 'I/O error\|Buffer I/O error' <<<"$dmesg_out" | tail -5 | sed 's/^/      /'
else
    row PASS "存储 I/O 错误" "无"
fi

# ---------------- 5. 首启配置与网络 ----------------
section "首启配置与网络"

if [ -f /var/lib/qm1/firstboot-done ]; then
    row PASS "首启配置" "已完成（$(cat /var/lib/qm1/firstboot-done | tr '\n' ' ' | cut -c1-120)）"
else
    row WARN "首启配置" "尚未执行（没有 /var/lib/qm1/firstboot-done）"
fi

prov_dir=""
if [ -d /etc/qm1/provision ]; then
    prov_dir="/etc/qm1/provision"
fi
if [ -n "$prov_dir" ]; then
    row PASS "provisioning 文件" "$prov_dir（$(ls -1 "$prov_dir" 2>/dev/null | tr '\n' ' ')）"
else
    row WARN "provisioning 文件" "没有 /etc/qm1/provision（可放到启动分区 /qm1/provision/）"
fi

if systemctl is-active --quiet systemd-networkd; then
    row PASS "networkd" "运行中"
else
    row FAIL "networkd" "没在运行 —— 不会有 DHCP/默认路由"
fi

if systemctl is-enabled --quiet qm1-firstboot.service 2>/dev/null; then
    row PASS "qm1-firstboot" "已启用"
else
    row WARN "qm1-firstboot" "未启用"
fi

# ---- 「开机即用」四条判据里的前两条（DNS 与账号），在这里逐条查 ----
# 之前 DELIVERY.md 说这四条"qm1-selftest 会逐条检查"，但自检里只有时钟与
# Wi-Fi 两项，DNS 与账号没有对应判据 —— 手册与自检对不上，就补上。
_resolv_target=""
if [ -L /etc/resolv.conf ]; then
    _resolv_target="$(readlink /etc/resolv.conf 2>/dev/null || true)"
fi
if [ "$_resolv_target" = "/usr/lib/systemd/resolv.conf" ]; then
    row PASS "DNS 数据源" "/etc/resolv.conf → /usr/lib/systemd/resolv.conf（resolved 的 stub）"
elif [ -n "$_resolv_target" ]; then
    row FAIL "DNS 数据源" "/etc/resolv.conf 指向 $_resolv_target，不是 resolved 的 stub —— 没有 DNS 数据源（NTP 解析不了域名 → 时钟停在 1970 → TLS 全废）"
else
    row FAIL "DNS 数据源" "/etc/resolv.conf 不是指向 stub 的软链（Debian 13 的 systemd/resolved 都不带这个文件，得自己挂）"
fi

_qm1_uid="$(id -u qm1 2>/dev/null || true)"
if [ "$_qm1_uid" = "1000" ]; then
    row PASS "可登录账号" "qm1 (uid 1000) 存在"
elif [ -n "$_qm1_uid" ]; then
    row WARN "可登录账号" "qm1 的 uid 是 $_qm1_uid（预期 1000）"
else
    row FAIL "可登录账号" "没有 qm1 账号 —— 刷完机没人能登"
fi

# 铺运行时的入口是 qm1-provision.timer（service 由它触发）。
# 早先查的是 service 本身是否 enabled；改成 timer 之后 service 不再被 enable，
# 这条检查必须跟着改，否则永远判成"未启用"。
if systemctl is-enabled --quiet qm1-provision.timer 2>/dev/null; then
    row PASS "qm1-provision" "定时器已启用（开机后自动铺 Hermes + headless Chrome）"
else
    row WARN "qm1-provision" "定时器未启用 —— 运行时不会自动铺，需手工跑 /usr/local/share/qm1/provision-agent.sh"
fi
if [ -f /var/lib/qm1/provision-done ]; then
    row PASS "运行时部署" "已完成（标记 /var/lib/qm1/provision-done）"
else
    row WARN "运行时部署" "尚未完成（没有 /var/lib/qm1/provision-done）"
fi

if pgrep -x wpa_supplicant >/dev/null 2>&1; then
    row PASS "wpa_supplicant" "运行中"
else
    row WARN "wpa_supplicant" "没在运行 —— Wi-Fi 不会关联"
fi

_addr="$(ip -br addr show wlan0 2>/dev/null || true)"
    if grep -q 'wlan0' <<<"$_addr"; then
    wlan_addr="$(ip -br addr show wlan0 2>/dev/null | awk '{print $3}')"
    if [ -n "$wlan_addr" ]; then
        row PASS "wlan0 地址" "$wlan_addr"
    else
        row WARN "wlan0 地址" "没有地址（未关联或 DHCP 没拿到）"
    fi
else
    row WARN "wlan0" "接口不存在"
fi

# 「开机即用」第三条：Wi-Fi 真的关联上了没有（iw 的 link 里会写 Connected/not connected）
if command -v iw >/dev/null 2>&1 && [ -e /sys/class/net/wlan0 ]; then
    _link="$(iw dev wlan0 link 2>/dev/null || true)"
    if grep -q 'Connected to' <<<"$_link"; then
        _ssid="$(iw dev wlan0 link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' | head -1)"
        row PASS "Wi-Fi 关联" "已关联${_ssid:+（SSID: $_ssid）}"
    elif grep -q 'not connected' <<<"$_link"; then
        row FAIL "Wi-Fi 关联" "未关联 —— 内置 Wi-Fi 是这台机器唯一的联网链路；先看绑定的是哪个模块（rtw88_qm1 才算对）"
    else
        row WARN "Wi-Fi 关联" "读不到关联状态（iw 没输出）"
    fi
else
    row WARN "Wi-Fi 关联" "没有 iw 或 wlan0 不存在"
fi

if systemctl is-enabled --quiet ssh 2>/dev/null; then
    row PASS "SSH" "已启用"
else
    row WARN "SSH" "未启用（远程登录不了）"
fi

# ---------------- 6. 健康采样（稳定性取证）----------------
section "健康采样"

HEALTH_DIR="${QM1_HEALTH_DIR:-/var/log/qm1-health}"
if [ -x /usr/local/sbin/qm1-health-collect ]; then
    row PASS "采集器" "/usr/local/sbin/qm1-health-collect 可执行"
else
    row WARN "采集器" "没有 /usr/local/sbin/qm1-health-collect（拿不到稳定性判据）"
fi

if systemctl is-enabled --quiet qm1-health-collect.timer 2>/dev/null; then
    last="$(systemctl show -p LastTriggerUSec --value qm1-health-collect.timer 2>/dev/null || true)"
    row PASS "采集定时器" "已启用（上次触发 ${last:-未知}）"
else
    row WARN "采集定时器" "qm1-health-collect.timer 未启用"
fi

if [ -r "$HEALTH_DIR/latest.txt" ]; then
    row PASS "最新快照" "$HEALTH_DIR/latest.txt（$(stat -c %y "$HEALTH_DIR/latest.txt" 2>/dev/null | cut -d. -f1)）"
    mmc_err="$(grep -m1 '^mmc_error_lines=' "$HEALTH_DIR/latest.txt" 2>/dev/null | cut -d= -f2)"
    hang="$(grep -m1 '^hung_task=' "$HEALTH_DIR/latest.txt" 2>/dev/null | cut -d= -f2)"
    row INFO "eMMC 错误行" "${mmc_err:-未知}（累计，S2 判据）"
    row INFO "挂死类抱怨" "${hang:-未知}（累计，S1 判据）"
    rxd="$(awk '/^-- wlan0 --$/{f=1;next} f&&/^-- /{f=0} f' "$HEALTH_DIR/latest.txt" 2>/dev/null \
        | tr ' ' '\n' | grep -m1 '^rx_dropped=' | cut -d= -f2)"
    row INFO "wlan0 丢包" "${rxd:-未知}（累计，S3 判据）"
else
    row WARN "最新快照" "还没有健康快照 —— 采集器可能没跑起来，或 /var/log/qm1-health 不可写"
fi

if [ -x /usr/local/bin/qm1-stress ]; then
    row PASS "压测脚本" "/usr/local/bin/qm1-stress（--idle-io / --fio / --wifi）"
else
    row WARN "压测脚本" "没有 /usr/local/bin/qm1-stress"
fi

# ---------------- 7. 功能完备性（每个功能都要真的能用）----------------
section "功能完备性"

# 显示输出
_conn="$(cat /sys/class/drm/card*/connector/*/status 2>/dev/null || true)"
    if grep -q connected <<<"$_conn"; then
    row PASS "显示输出" "有已连接的显示输出"
else
    row WARN "显示输出" "没有已连接的显示输出（HDMI 未接显示器或假显示器）"
fi

# 声卡与 HDMI 音频
if have aplay; then
    cards="$(aplay -l 2>/dev/null | grep -c '^card ' || true)"
    if [ "${cards:-0}" -gt 0 ]; then
        row PASS "声卡" "$cards 张"
    else
        row WARN "声卡" "aplay 没有列出任何声卡"
    fi
else
    row WARN "声卡" "没有 aply（alsa-utils 未安装）"
fi
if mod_loaded snd-hda-codec-hdmi; then
    row PASS "HDMI 音频" "snd-hda-codec-hdmi 已加载"
else
    row WARN "HDMI 音频" "snd-hda-codec-hdmi 未加载（HDMI 可能没有声音）"
fi

# CPU 调频
gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
freqs="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null | tr '\n' ' ')"
if [ -n "$gov" ]; then
    row PASS "CPU 调频" "governor=$gov 可用频率=${freqs:-未知}"
else
    row WARN "CPU 调频" "没有 cpufreq 策略（CPU 可能锁在 1.3GHz）"
fi

# eMMC runtime PM —— 动态发现主机，不再写死 ACPI 路径。
# 写死路径的坏处：固件换了 HID 就静默读不到，读不到时还要区分
# 「这台机器根本没开 runtime PM（无风险）」和「开关没关（有掉卡风险）」。
emmc_host=""
if [ -n "$emmc_card_dev" ]; then
    _rel="${emmc_card_dev#/sys/devices/}"
    case "$_rel" in
        */*) : ;;
        *) _rel="" ;;
    esac
    if [ -n "$_rel" ]; then
        _bus="${_rel%%/*}"
        _rest="${_rel#*/}"
        case "$_rest" in
            */*) _devname="${_rest%%/*}" ;;
            *) _devname="" ;;
        esac
        [ -n "$_devname" ] && emmc_host="/sys/devices/$_bus/$_devname"
    fi
fi
if [ -z "$emmc_host" ]; then
    row WARN "eMMC runtime PM" "找不到 eMMC 的平台设备（无法确认是否已退出 runtime suspend）"
elif [ ! -e "$emmc_host/power/control" ]; then
    row INFO "eMMC runtime PM" "主机 $emmc_host 没有 power/control（未启用 runtime PM，无掉卡风险）"
else
    pc="$(cat "$emmc_host/power/control" 2>/dev/null || true)"
    asd="$(cat "$emmc_host/power/autosuspend_delay_ms" 2>/dev/null || true)"
    if [ "$pc" = "on" ] && { [ -z "$asd" ] || [ "$asd" = "-1" ]; }; then
        row PASS "eMMC runtime PM" "已关闭自动挂起（$emmc_host：control=on${asd:+，autosuspend_delay_ms=$asd}）"
    else
        row WARN "eMMC runtime PM" "control=${pc:-未知} autosuspend_delay_ms=${asd:-未知}（$emmc_host，自动挂起仍开 → 可能在读写中掉卡）"
    fi
fi

# microSD 卡检测：上游 sdhci-acpi 的 CD pull-up quirk 只对
# ASUSTeK + T100TA 生效；这块板子若不匹配，卡槽就是插了也认不出。
if [ -n "$sd_blk" ]; then
    row PASS "microSD 卡" "检测到 SD 卡（$sd_blk）"
else
    dmi_v="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || echo '')"
    dmi_p="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo '')"
    case "$dmi_v:$dmi_p" in
        *ASUSTeK*:*T100TA*)
            row WARN "microSD 卡" "未检出 SD 卡（本板匹配上游 quirk，若卡已插请检查 DSDT 的 CD 引脚）"
            ;;
        *)
            row INFO "microSD 卡" "未检出 SD 卡（上游 CD pull-up quirk 只匹配 ASUSTeK+T100TA，本机=$dmi_v / $dmi_p）"
            ;;
    esac
fi

# 存储设备清单与寿命
mmc_list="$(for d in /sys/block/mmcblk*; do
    [ -e "$d" ] || continue
    n="$(basename "$d")"
    t="$(cat "$d/device/type" 2>/dev/null || echo '?')"
    printf '%s(%s) ' "$n" "$t"
done)"
if [ -n "$mmc_list" ]; then
    row INFO "存储设备" "$mmc_list"
else
    row WARN "存储设备" "没有 mmcblk 设备"
fi
life="$(find /sys/class/mmc_host -name life_time -type f 2>/dev/null | head -1 | xargs -r cat 2>/dev/null || true)"
[ -n "$life" ] && row INFO "eMMC 寿命计数" "$life（0x… 越大越接近寿命上限）"

# RTC
if [ -e /dev/rtc0 ]; then
    row PASS "RTC" "/dev/rtc0 存在"
else
    row WARN "RTC" "没有 /dev/rtc0（Bay Trail-T 开 CONFIG_PINCTRL_BAYTRAIL 的已知副作用；系统时钟仍由 HPET/ACPI 提供）"
fi

# USB 控制器
usb3="$(ls /sys/bus/pci/drivers/xhci-hcd 2>/dev/null | wc -l)"
usb2=0
for d in /sys/bus/pci/drivers/ehci-pci /sys/bus/pci/drivers/ohci-pci; do
    [ -d "$d" ] || continue
    for _ in "$d"/*; do
        [ -e "$_" ] && usb2=$((usb2 + 1))
    done
done
row INFO "USB 控制器" "xHCI=${usb3} EHCI/OHCI=${usb2}"

# 无线与蓝牙（模块名以上面算出的 wlan_mod 为准，不在这里重新猜一套）
if [ -n "$wlan_mod" ]; then
    case "$wlan_mod" in
        *rtw88_qm1*|*rtw88_8723bs*|*rtw_8723bs*)
            row PASS "Wi-Fi 驱动" "${wlan_mod}（rtw88 树外模块）"
            ;;
        *r8723bs_qm1*)
            row PASS "Wi-Fi 驱动" "${wlan_mod}（打了补丁的树外 staging 模块）"
            ;;
        *r8723bs*)
            row WARN "Wi-Fi 驱动" "${wlan_mod}（发行版 staging 模块：有永久卡死路径，只是回退方案）"
            ;;
        *)
            row WARN "Wi-Fi 驱动" "${wlan_mod}（不是本项目预期的模块名）"
            ;;
    esac
    # 树内 staging 与树外模块都认同一个 SDIO id，必须确认实际绑定的是哪一个
    if [ -e /sys/bus/sdio/drivers/rtl8723bs ] && [ -n "${wlan_mod##*:}" ]; then
        case "$wlan_mod" in
            *r8723bs*) ;;
            *) row WARN "Wi-Fi 绑定" "树内 staging r8723bs 也注册在 SDIO 总线上，确认 wlan0 绑的是出货模块" ;;
        esac
    fi
elif mod_loaded rtw88_qm1 || mod_loaded r8723bs_qm1 || mod_loaded r8723bs; then
    # ★ 出货模块已加载却没出无线接口 = FAIL，不是 WARN。
    #   这正是"模块索引里没有它 / 模块符号残缺 / 树内驱动抢先绑定"的现场表现：
    #   模块在、设备在、wlan0 不在。以前这里只 warn，于是"Wi-Fi 实际上没起来"
    #   在自检里显示成一条提醒，运维看一眼就过去了。
    row FAIL "Wi-Fi 驱动" \
        "模块已加载但没有无线接口 —— 出货模块装上了却绑不上设备（看 dmesg 里的 rtw88/rtw8723bs；常见原因：模块索引缺它、模块符号残缺 insmod 报 Unknown symbol、或树内 staging 抢先绑走了 SDIO 卡）"
else
    row WARN "Wi-Fi 驱动" "没有 Wi-Fi 驱动加载"
fi
# ★ 真机上再钉一次：QM1 那张 SDIO 卡（0x024c:0xb723）在不在、被谁认领。
#   前面几条查的是"哪个模块绑着 wlan0"；这条查的是**卡本身**：
#   卡压根没被枚举出来（内核没认出这块 SDIO 设备），还是枚举出来了却没人认领
#   （模块装上了却绑不上设备）—— 两者的现场现象一样（没有 wlan0），
#   但修法完全不同，必须分开报。
#   modalias 从 uevent 里取（设备核心一定写 MODALIAS=），modalias 文件作为兜底。
_sdio_our=""
for _sd in /sys/bus/sdio/devices/*; do
    [ -e "$_sd" ] || continue
    _ma="$(sed -n 's/^MODALIAS=//p' "$_sd/uevent" 2>/dev/null || true)"
    [ -n "$_ma" ] || _ma="$(cat "$_sd/modalias" 2>/dev/null || true)"
    case "$_ma" in
        *024CB723*|*024cb723*)
            _sd_drv="$(basename "$(readlink -f "$_sd/driver" 2>/dev/null)" 2>/dev/null || true)"
            [ -n "$_sd_drv" ] || _sd_drv="未认领"
            if [ "$_sd_drv" = "未认领" ]; then
                row FAIL "SDIO 卡 0x024c:0xb723" \
                    "卡枚举出来了，但没有任何驱动认领它 —— 模块装上了却绑不上设备（查 dmesg 里 rtw88/rtw8723bs 的报错）"
            else
                row PASS "SDIO 卡 0x024c:0xb723" "已枚举并被 ${_sd_drv} 认领"
            fi
            _sdio_our="seen"
            ;;
    esac
done
if [ -z "$_sdio_our" ]; then
    row FAIL "SDIO 卡 0x024c:0xb723" \
        "没有枚举到这张卡（内核没认出这块 SDIO 设备，或驱动没注册 SDIO 总线）"
fi
if [ -d /sys/class/bluetooth/hci0 ]; then
    row PASS "蓝牙" "hci0 已出现"
else
    bt_owner=""
    for _dev in /sys/bus/acpi/devices/*; do
        [ -e "$_dev" ] || continue
        _hid="$(cat "$_dev/hid" 2>/dev/null || true)"
        case "$_hid" in
            OBDA8723|OBDA0623)
                bt_owner="$(basename "$(readlink -f "$_dev/driver" 2>/dev/null || echo none)")"
                ;;
        esac
    done
    if [ -n "$bt_owner" ]; then
        row WARN "蓝牙" "没有 hci0（蓝牙 ACPI 节点被 '$bt_owner' 占用；若是 8250 需 blacklist 8250_generic/8250_serial）"
    else
        row WARN "蓝牙" "没有 hci0（固件未下发成功或 DSDT 未把 OBDA8723 暴露成 serdev 口）"
    fi
fi

# 时钟同步
if command -v timedatectl >/dev/null 2>&1; then
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
    if [ "$sync" = "yes" ]; then
        row PASS "时间同步" "已同步（$(date -u)）"
    else
        row WARN "时间同步" "未同步（NTPSynchronized=$sync），TLS 证书校验会失败"
    fi
else
    row WARN "时间同步" "没有 timedatectl"
fi

# 蓝牙栈
if systemctl is-enabled --quiet bluetooth.service 2>/dev/null; then
    row PASS "蓝牙栈" "bluetooth.service 已启用"
else
    row WARN "蓝牙栈" "bluetooth.service 未启用（只能看到 hci0，无法配对）"
fi

# 硬件修正服务
if systemctl is-enabled --quiet qm1-hardware-fixups.service 2>/dev/null; then
    row PASS "硬件修正服务" "qm1-hardware-fixups.service 已启用"
else
    row WARN "硬件修正服务" "qm1-hardware-fixups.service 未启用"
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
