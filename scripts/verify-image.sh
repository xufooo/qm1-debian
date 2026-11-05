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

# 内容检查：debugfs -R "cat <path>"，在镜像内取文件正文
check_content() {
    local path="$1" regex="$2" desc="$3"
    local out
    out="$(debugfs -R "cat $path" "$IMG" 2>/dev/null || true)"
    if grep -qE "$regex" <<<"$out"; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s)\n' "$path" "$desc"
        printf '%s\n' "$out" | head -5 | sed 's/^/         /' >&2
        fail=$((fail + 1))
    fi
}

# 逐行精确匹配检查（整行等于给定的字面量，不当正则用）：
# 用来核对 modprobe 配置里的具体行 —— 那些行里有 / 和空格，当正则容易写错。
check_content_fixed() {
    local path="$1" line="$2" desc="$3"
    local out
    out="$(debugfs -R "cat $path" "$IMG" 2>/dev/null || true)"
    if grep -qxF -- "$line" <<<"$out"; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s)\n' "$path" "$desc"
        printf '%s\n' "$out" | head -8 | sed 's/^/         /' >&2
        fail=$((fail + 1))
    fi
}

# 静默版逐行精确匹配：只返回成败，不打印（供"几个候选里命中任意一个就算过"
# 的场景使用 —— 例如出货模块的模块名有三种可能，死写一个名字会误报）。
check_content_fixed_quiet() {
    local path="$1" line="$2"
    local out
    out="$(debugfs -R "cat $path" "$IMG" 2>/dev/null || true)"
    grep -qxF -- "$line" <<<"$out"
}

# 反向检查：文件里**不能**出现匹配该正则的行
check_absent_content() {
    local path="$1" regex="$2" desc="$3"
    local out
    out="$(debugfs -R "cat $path" "$IMG" 2>/dev/null || true)"
    if grep -qE -- "$regex" <<<"$out"; then
        printf '  FAIL %-46s (%s)\n' "$path" "$desc"
        printf '%s\n' "$out" | grep -E -- "$regex" | head -5 | sed 's/^/         /' >&2
        fail=$((fail + 1))
    else
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    fi
}

# 软链目标检查：debugfs 的 stat 对软链会给出 Fast link dest
# ★ 必须在镜像内部判断软链是否指向存在的目标；直接在宿主机上 readlink -e
#   会跑到宿主根去解析绝对目标，必然误判成悬空。
check_link() {
    local path="$1" want="$2" desc="$3"
    local out dest
    out="$(debugfs -R "stat $path" "$IMG" 2>/dev/null || true)"
    dest="$(sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p' <<<"$out")"
    if [ "$dest" = "$want" ]; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s) —— 实际目标：%s\n' "$path" "$desc" "${dest:-（不是软链或读不到）}"
        fail=$((fail + 1))
    fi
}

log "校验 ext4 镜像：$IMG"

echo "-- 属主与权限（打包阶段最容易丢的部分）--"
check_attr /etc/shadow    'Group: *42'  "shadow 组仍是 42(shadow)"
check_attr /usr/bin/sudo   'Mode: *04755' "sudo 保留 setuid 位"

echo "-- 定制层是否落进镜像 --"
check_exists /etc/default/zramswap                 "zram 配置（768M zstd）"
# 配置文件在 ≠ zram 设备在跑：zramswap.service 必须被 enable（要看到
# multi-user.target.wants 里的那个链接），否则这台 2 GiB 的机器实际零交换，
# 而旧的检查只看 /etc/default/zramswap 存在 ⇒ 永远绿。
# 链接目标在 Debian 上可能是 /lib/… 也可能是 /usr/lib/…（/lib 是软链），
# 所以这里只断言"链接在"，不绑死目标字符串。
check_exists /etc/systemd/system/multi-user.target.wants/zramswap.service \
    "zram 交换已启用（zramswap.service 在 multi-user.target.wants 里）"
check_exists /etc/systemd/journald.conf.d/qm1.conf     "journald 限额"
# ★ 这两行曾经被挤成一行（"…journald 限额"check_exists …"）：
#   shell 会把 `check_exists A "B"check_exists C "D"` 解析成**一次**调用
#   —— 第二个 check_exists 变成了第一个的第四个参数，于是 systemd-oomd 的
#   限额文件从来没被检查过，而脚本照样全绿。
check_exists /etc/systemd/oomd.conf.d/qm1.conf         "systemd-oomd 限额"
check_exists /etc/modules-load.d/qm1-hardware.conf  "硬件模块自动加载清单"
check_exists /etc/initramfs-tools/modules          "initramfs 关键模块清单"
check_exists /usr/local/share/qm1/driver-manifest.txt "驱动清单"
check_exists /usr/local/lib/qm1/drv-selfcheck.sh    "设备端自检脚本"
check_exists /etc/wpa_supplicant/wpa_supplicant.conf "Wi-Fi 配置"
# 这份是**回退**参数（发行版树内 staging r8723bs），不是出货配置。
# 出货配置是 qm1-rtw88-8723bs.conf（在下面的 rtw88 段里按内容校验）。
# 留着这份是为了"rtw88 起不来、需要临时回退"时不用重踩省电的坑。
check_exists /etc/modprobe.d/qm1-rtl8723bs-in-tree.conf "RTL8723BS 树内 staging 回退参数（关省电/20MHz）"
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
    # 出货模块的实际名字（rtw88_ko 的 basename，去掉 .ko）
    _ship_mod="$(basename "$rtw88_ko" .ko)"
    # ★ modprobe 是靠 modules.dep 找模块的：文件在 extra/ 下但索引里没有 ⇒
    #   "modprobe rtw88_qm1" 报 "not found in directory"，驱动永远加载不上，
    #   而镜像构建全程绿灯。这条断言就是为拦住那种情况而存在的。
    #   模块名不能死写：出货模块有三种可能的来源（rtw88_qm1 整树单模块 /
    #   rtw88_8723bs 芯片回移 / rtw_8723bs vendor 树）。
    check_content "/lib/modules/$KVER/modules.dep" "${_ship_mod}\.ko" \
        "模块索引 modules.dep 里有 $_ship_mod（否则 modprobe 找不到它）"
    # ★ 隔离配置必须查**内容**，不能只查文件在不在。
    #   本项目最怕的失败模式恰恰全落在这些行上：镜像里装了根治模块，
    #   却因为隔离行缺失或被覆盖，树内 staging 驱动照样按 SDIO modalias
    #   抢先绑定同一张卡 —— 于是"装了根治模块"看起来一切正常，实际仍在用
    #   那个丢一次中断就永久断流的老驱动。CI 那边查了这些行，验收脚本却
    #   没查 ⇒ 镜像验收比流水线还松。这次两边对齐。
    #
    #   两道隔离都要：blacklist 挡 udev 的 modalias 自动加载，
    #   install ... /bin/false 再挡一次显式 modprobe。
    _iso="/etc/modprobe.d/qm1-rtw88-8723bs.conf"
    # 名单与 build 脚本的 INTREE_RTW88 一致：树内 rtw88 的每个模块都要
    # "blacklist + install /bin/false"两道。少一道就有可能被显式 modprobe
    # 装进去 —— 树内 rtw88_core 导出的符号与树外模块同名，撞车之后树外模块
    # insmod 报 Unknown symbol，现场表现是"驱动装上了却没有 wlan0"。
    #
    # ★ 但绝不能要求"拉黑出货模块自己"：
    #   上游芯片回移模式（只编 rtw8723bs.c，复用树内 rtw88 核心）产出的
    #   模块名就叫 rtw88_8723bs，而且它依赖树内的 rtw88_core ⇒ 这种模式下
    #   树内 rtw88 一个都不能拉黑（build 脚本与 hook02 也是这么判的）。
    _iso_lines=("blacklist r8723bs" "install r8723bs /bin/false"
                "blacklist r8723bs_qm1" "install r8723bs_qm1 /bin/false")
    if [ "$_ship_mod" != "rtw88_8723bs" ]; then
        for _m in rtw88_core rtw88_sdio rtw88_8723x rtw88_8723b rtw88_8723bs rtw88_usb rtw88_pci; do
            [ "$_m" = "$_ship_mod" ] && continue
            _iso_lines+=("blacklist $_m" "install $_m /bin/false")
        done
    fi
    # ★ 用数组而不是 `printf | while read`：
    #   管道里的 while 在**子 shell** 里跑，子 shell 里 fail=$((fail+1))
    #   的计数丢不回父进程 ⇒ 检查失败了也不会计入总数（脚本照样报成功）。
    for _line in "${_iso_lines[@]}"; do
        check_content_fixed "$_iso" "$_line" "隔离配置含：$_line"
    done
    for _p in disable_lps_deep support_bf debug_mask; do
        check_content "$_iso" "^options .*${_p}=" "rtw88 模块参数 ${_p} 已下发"
    done
    # modules-load.d 里必须只有出货模块，不能留着会抢设备的 staging 驱动。
    # ★ 不能死写 "rtw88_qm1"：出货模块有三种可能的模块名
    #   （rtw88_qm1 上游整树单模块 / rtw88_8723bs 上游芯片回移 /
    #    rtw_8723bs vendor 树），hook02 按实际装上的那个写进 modules-load.d。
    #   死写一个名字，换成另一种构建来源就误报 FAIL。
    _loaded_ok=0
    for _cand in rtw88_qm1 rtw88_8723bs rtw_8723bs; do
        if check_content_fixed_quiet "/etc/modules-load.d/qm1-hardware.conf" "$_cand"; then
            _loaded_ok=1
            printf '  OK   %-46s (%s)\n' "/etc/modules-load.d/qm1-hardware.conf" \
                "开机自动加载的是出货模块 $_cand"
        fi
    done
    if [ "$_loaded_ok" -eq 0 ]; then
        printf '  FAIL %-46s (%s)\n' "/etc/modules-load.d/qm1-hardware.conf" \
            "开机自动加载的不是出货模块（rtw88_qm1 / rtw88_8723bs / rtw_8723bs 一个都没有）"
        fail=$((fail + 1))
    fi
    check_absent_content "/etc/modules-load.d/qm1-hardware.conf" '^r8723bs(_qm1)?$' \
        "modules-load.d 里没有 staging r8723bs/r8723bs_qm1（它们会抢同一张 SDIO 卡）"
else
    printf '  WARN %-46s (%s)\n' "/lib/modules/*/extra/rtw88/*.ko" "镜像里没有 rtw88 回移模块"
    # 没有 rtw88 时，树外补丁模块是唯一可用的根治路径
    if [ -n "$KVER" ] \
       && debugfs -R "stat /lib/modules/$KVER/extra/rtl8723bs/r8723bs_qm1.ko" "$IMG" >/dev/null 2>&1; then
        printf '  OK   %-46s (%s)\n' \
            "/lib/modules/$KVER/extra/rtl8723bs/r8723bs_qm1.ko" "出货的 Wi-Fi 驱动（打补丁的树外 staging 模块）"
        check_content "/lib/modules/$KVER/modules.dep" 'r8723bs_qm1\.ko' \
            "模块索引 modules.dep 里有 r8723bs_qm1（否则 modprobe 找不到它）"
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

echo "-- 开机即用基线（DNS / 账号 / Wi-Fi 单元 / fstab / 超时）--"
# 这一段对应审计 B 组那 8 条「装上去也用不了」的问题。
# CI 的 boot-to-usable 步骤查的是解包出来的根目录树；这里查的是**最终产物**
# （ext4 镜像），因为「文件在树里」不等于「进了镜像」——mkfs.ext4 -d 复制时
# 才可能把内容丢掉，而丢掉之后的镜像照样能构建成功。
check_link /etc/resolv.conf /usr/lib/systemd/resolv.conf \
    "DNS 数据源指向 systemd-resolved 的 stub（Debian 13 的包不带 /etc/resolv.conf）"
check_exists /usr/lib/systemd/resolv.conf "systemd-resolved 的 stub 文件本体"
check_content /etc/passwd '^qm1:' "有可登录账号 qm1（口令由安装器装机时生成）"
check_content /etc/fstab '^[^#]*[[:space:]]/[[:space:]]' "fstab 里有根分区条目（systemd 才能按 fstab 管理根、fsck-root 才有意义）"
check_exists /etc/systemd/system/qm1-wifi@.service "Wi-Fi 单元（wpa_supplicant）"
check_content /etc/systemd/system/qm1-wifi@.service '^TimeoutStartSec=(1[2-9][0-9]|[2-9][0-9]{2,})' \
    "Wi-Fi 单元的超时 ≥120s（进程要来得及 fork 出来）"
# ★ 等无线接口出现必须发生在 ExecStart 进程内部，不能用 ExecStartPre。
#   ExecStartPre 属于本单元的 start job，而 multi-user.target 因为 Wants=
#   挂着本单元会被 systemd 隐式补上 After= ⇒ start job 不完成，
#   multi-user.target 就到不了 ⇒ 整机没有 SSH、看起来像砖了。
check_content /etc/systemd/system/qm1-wifi@.service '^ExecStart=/usr/local/sbin/qm1-wifi-start' \
    "Wi-Fi 单元用 qm1-wifi-start 包装（等接口在进程内做，不挡开机）"
check_absent_content /etc/systemd/system/qm1-wifi@.service '^ExecStartPre=.*ip link show' \
    "Wi-Fi 单元不能有等接口的 ExecStartPre（它会拖住 multi-user.target）"
check_exists /usr/local/sbin/qm1-wifi-start "等无线接口出现的包装脚本"
check_attr /usr/local/sbin/qm1-wifi-start 'Mode: *0755' "qm1-wifi-start 可执行"
check_content /etc/systemd/system.conf.d/quick-boot.conf '^TimeoutStartSec=120' \
    "全局单元超时 120s（30s 会在接口出现前把 Wi-Fi 单元掐掉）"
check_content /etc/systemd/journald.conf.d/qm1.conf '^Storage=persistent' \
    "journal 落盘持久化（默认 auto 写 /run，重启即失，现场没法翻日志）"
check_exists /etc/systemd/system/qm1-firstboot.service "首启脚本单元"
check_exists /etc/udev/rules.d/60-qm1-emmc-power.rules "eMMC runtime suspend 的 udev 规则（initramfs 阶段就要生效）"
check_exists /usr/local/sbin/qm1-hardware-survey "真机取证工具（microSD/蓝牙 8250 判定用）"
check_exists /usr/local/sbin/qm1-bluetooth-up "蓝牙初始化辅助脚本（失败要留痕）"
check_exists /usr/local/lib/qm1/install-lib.sh "安装器共用的磁盘/凭据函数库"
check_exists /usr/local/sbin/qm1-provision "首启运行时部署的包装脚本（跑 provision-agent.sh）"
check_exists /usr/local/share/qm1/provision-agent.sh "Hermes + headless Chrome 的部署脚本"
check_exists /etc/systemd/system/qm1-provision.service "首启运行时部署单元（没有它刷完机不会自动铺 Hermes）"
# ★ 运行时部署必须由 timer 触发，而且服务本身不能 After=multi-user.target。
#   target 会给 Wants= 成员隐式补 After=，所以服务挂在 multi-user.target 上
#   又要等 network-online，就等于"整机开机必须等网络就绪"—— Wi-Fi 没起来时
#   整机到不了 multi-user.target，没有 SSH、看起来像砖了。
check_exists /etc/systemd/system/qm1-provision.timer "运行时部署的定时器（把铺运行时移出开机关键路径）"
check_content /etc/systemd/system/qm1-provision.timer '^Unit=qm1-provision.service' \
    "定时器指向 qm1-provision.service"
check_absent_content /etc/systemd/system/qm1-provision.service '^After=.*multi-user\.target' \
    "部署单元不能 After=multi-user.target（会和 target 的隐式 After= 撞成排序环）"

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
