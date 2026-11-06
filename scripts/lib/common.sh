#!/usr/bin/env bash
# common.sh — QM1-Debian 构建链共享辅助函数
#
# 约定：
#   log/warn/die 统一输出到 stderr，保持 stdout 只有"产物路径"这类可解析信息。
#   所有脚本都要求 bash 4+（Debian 13 默认 bash 5.2）。
set -euo pipefail

# 防止重复 source
if [ -n "${_QM1_COMMON_SH:-}" ]; then return 0; fi
_QM1_COMMON_SH=1

# shellcheck disable=SC2034  # 独立检查本文件时看不到外部脚本的引用
QM1_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

QM1_ESP_LABEL="${QM1_ESP_LABEL:-QM1ESP}"      # FAT32 ESP 卷标（GRUB 用 --label 定位）
QM1_ROOT_LABEL="${QM1_ROOT_LABEL:-QM1ROOT}"    # ext4 根分区卷标

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1${2:+（$2）}"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限（请用 sudo 运行本脚本）"
}

# 在 chroot 内执行命令（带 /proc /sys /dev 挂载时使用）
in_chroot() {
    local root="$1"; shift
    chroot "$root" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

# 生成随机 UUID（优先 uuidgen，缺失时退回 /proc/sys/kernel/random/uuid）
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
}

# 计算目录占用的字节数（du 语义，含块对齐）
dir_bytes() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo 0
}

# 每个架构默认使用的 Debian 发行版。
#
#   amd64 → trixie（Debian 13，当前主线）
#   i386  → bookworm（Debian 12）
#
# 为什么 32 位必须留在 bookworm：
#   Debian 13 的 binary-i386 索引里已经没有任何 linux-image-* 包（实测命中数为 0），
#   官方也不再提供 i386 安装器，trixie 的 i386 只用于"在 64 位 CPU 上跑 32 位用户态"。
#   真正要启动一套 32 位系统（32 位内核 + 32 位用户态），只能用 bookworm 的
#   linux-image-686-pae（PAE 内核，Bay Trail 支持 PAE）。
default_suite_for_arch() {
    # 只做 64 位系统：QM1 是 64 位 CPU，32 位变体已按决定取消。
    # 注意区分两件事：32 位 *系统* 不做了，但 32 位 *EFI 引导器* 仍然要留着 ——
    # 实机 UEFI 是 32 位 IA32 EFI（fw_platform_size=32），BOOTIA32.EFI 是必需品。
    case "$1" in
        amd64) printf 'trixie\n' ;;
        *) die "只支持 amd64（32 位系统变体已取消）：$1" ;;
    esac
}

# 每个架构对应的内核包名。
#
# 只做 64 位系统：QM1 是 64 位 CPU，32 位系统变体已按决定取消
# （Debian 13 起也没有 i386 内核包，32 位只能留在 bookworm + 686-pae）。
# 仍然保留的是 32 位 *EFI 引导器*（实机固件是 32 位 IA32 EFI）。
kernel_pkgs_for_arch() {
    case "$1" in
        amd64) printf 'linux-image-amd64,linux-headers-amd64\n' ;;
        *) die "只支持 amd64（32 位系统变体已取消）：$1" ;;
    esac
}

# 固定内核 point release 时用到的 ABI 命名。
#
# Debian 的内核包名、/lib/modules 目录名、uname -r 三者是同一个字符串：
#   trixie 的 amd64 内核 6.12.113 → 6.12.113+deb13-amd64
#     +deb13 = 发行版 ABI 后缀（Debian 13 = trixie）
#     amd64  = 内核 flavour
# 所以"固定某个 point release"等价于"装这个字符串对应的版本化包"：
#   linux-image-6.12.113+deb13-amd64
#   linux-headers-6.12.113+deb13-amd64
# 顺带解释了 uname -r 为什么会带 +deb13：那是 Debian 自己的 ABI 标记。
#
# 注意 hooks/customize02-drivers.sh 里有一份等价实现（hook 拿不到仓库路径，
# 不能 source 本文件），改这里必须同步改那边。
#
# 用法：kernel_abi_name <point-release> <flavour> <发行版ABI后缀>
#   kernel_abi_name 6.12.113 amd64 deb13 → 6.12.113+deb13-amd64
kernel_abi_name() {
    printf '%s+%s-%s\n' "$1" "$3" "$2"
}

# 规范化 --kernel-version 的输入：接受 upstream point release（6.12.113）
# 或 Debian ABI 名（6.12.113+deb13-amd64），统一返回 upstream point release。
normalize_kernel_version() {
    printf '%s\n' "${1%%+*}"
}

# ---------- 磁盘层面的辅助函数 ----------
#
# 这一节与镜像内的 overlay/usr/local/lib/qm1/install-lib.sh **同名同义**：
# 两边各有一份实现（构建链要拿它算分区、校验备份；镜像内那份要随镜像走，
# 才能在没有仓库的机器上工作）。scripts/test-install-lib.sh 会断言两份实现
# 在同一组合成盘上给出完全相同的输出，防止走样 —— 一旦走样，"备份校验通过"
# 这个结论在构建链和在真机上就不是同一件事了。
#
# 注意：本文件是 bash（构建链），镜像内那份也是 bash；设备侧安装器是 /bin/sh
# 风格，但只 source 镜像内那份，不碰这里。

# GPT 分区类型 GUID（磁盘上的形式）
QM1_PARTTYPE_EFI="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
# shellcheck disable=SC2034  # 由 source 本文件的脚本使用
QM1_PARTTYPE_LINUX="0fc63daf-8483-4772-8e79-3d69d8477de4"

# 与镜像内 install-lib.sh 同名的日志函数：固定前缀、无时间戳，
# 这样两份实现的输出可以直接逐字比较。
qm1_install_log()  { printf '[qm1-install][info] %s\n' "$*"; }
qm1_install_warn() { printf '[qm1-install][warn] %s\n' "$*" >&2; }

# 某个字节范围的 sha256：$1=文件 $2=偏移 $3=长度
qm1_hash_range() {
    dd if="$1" iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none 2>/dev/null \
        | sha256sum | awk '{print $1}'
}

# 设备上的分区，一行一个：name start size parttype partnumber
# start/size 单位是字节（lsblk -b）。
qm1_partitions() {
    lsblk -bnro NAME,START,SIZE,PARTTYPE,PARTN "$1" 2>/dev/null \
        | awk 'NF>=4 && $4 ~ /^[0-9a-fA-F][0-9a-fA-F-]+$/ {print $1, $2, $3, tolower($4), $5}'
}

# 按分区类型 GUID 找分区：$1=设备 $2=类型 GUID → "name start size"
qm1_find_partition() {
    qm1_partitions "$1" | awk -v t="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
        '$4 == t {print $1, $2, $3; exit}'
}

# 同上，但带上分区号：$1=设备 $2=类型 GUID → "name partno start size"
qm1_find_partition_by_type() {
    qm1_partitions "$1" | awk -v t="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
        '$4 == t {print $1, $5, $2, $3; exit}'
}

# 最后一个分区的结束位置（字节）：$1=设备
qm1_used_end_bytes() {
    local end=0 st sz
    while read -r st sz; do
        [ -n "${st:-}" ] || continue
        [ "${sz:-0}" -gt 0 ] || continue
        end=$(( st + sz ))
    done < <(lsblk -bnro START,SIZE,TYPE "$1" 2>/dev/null \
             | awk '$3=="part" && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1, $2}')
    echo "$end"
}

# 逐分区比对磁盘与它的备份。
#   $1=目标设备 $2=备份所在（文件或裸设备） $3=备份映像在该源里的偏移（普通文件为 0）
#
# 为什么要这么比对而不是只算备份文件自己的哈希：
# 一份写错位置、或者被截断的备份，它自己的 sha256 完全自洽 —— 只有拿它跟
# "写盘之前的原盘"逐分区比，才能发现"备份其实没保住原盘"。
qm1_verify_backup() {
    local target="$1" bsrc="$2" base="$3"
    local name start size dsum bsum ok=0 bad=0

    dsum="$(qm1_hash_range "$target" 0 1048576)"
    bsum="$(qm1_hash_range "$bsrc" "$base" 1048576)"
    if [ -n "$dsum" ] && [ "$dsum" = "$bsum" ]; then
        qm1_install_log "  GPT/分区表区（1 MiB）一致：$dsum"
        ok=$(( ok + 1 ))
    else
        qm1_install_warn "  GPT/分区表区（1 MiB）不一致：原盘 $dsum / 备份 $bsum"
        bad=$(( bad + 1 ))
    fi

    while read -r name start size; do
        [ -n "${name:-}" ] || continue
        [ "${size:-0}" -gt 0 ] || continue
        dsum="$(qm1_hash_range "$target" "$start" "$size")"
        bsum="$(qm1_hash_range "$bsrc" $(( base + start )) "$size")"
        if [ -n "$dsum" ] && [ "$dsum" = "$bsum" ]; then
            qm1_install_log "  分区 ${name}（偏移 ${start}，$(( size / 1048576 )) MiB）一致：$dsum"
            ok=$(( ok + 1 ))
        else
            qm1_install_warn "  分区 ${name}（偏移 ${start}，$(( size / 1048576 )) MiB）不一致：原盘 $dsum / 备份 $bsum"
            bad=$(( bad + 1 ))
        fi
    done < <(lsblk -bnro NAME,START,SIZE,TYPE "$target" 2>/dev/null \
             | awk '$4=="part" && $3>0 {print $1, $2, $3}')

    qm1_install_log "备份校验：$ok 项一致，$bad 项不一致"
    [ "$bad" -eq 0 ]
}

# ---------- 目标盘的分区布局规划 ----------
#
# 背景：主机侧写盘用的是"按内容大小截出来的"整机镜像（assemble-disk.sh 用
# truncate 把镜像截到"ESP + 根文件系统 + 1 MiB"），而 eMMC 有 28.5 GiB。
# 直接把镜像 dd 上去会留下两个问题：
#   1) 镜像里的备份 GPT 落在 6.3 GiB 处，旧盘尾部的备份 GPT 还在那儿 ——
#      一盘两套 GPT，sgdisk/parted 会报 "backup GPT is not at the end of the disk"；
#   2) 约 22 GiB 的旧系统残留还在盘上，根分区也只有 6 GiB。
# 所以写盘之后必须**按目标真实容量重建分区表**：ESP 保持 1 MiB 偏移，
# 备份 GPT 落到真实盘尾，根分区一直扩到盘尾前 1 MiB。
#
# ESP 的大小不在这里写死，而是从**镜像自己的分区表**里读出来 ——
# 镜像的分区表就是 scripts/assemble-disk.sh 生成的，那里的布局约定是
# "ESP 从 1 MiB 起、根分区紧接其后、盘尾留 1 MiB 给备份 GPT"。
# 读镜像而不是抄数字，才能保证两条安装路径（主机侧 / 设备侧）布局一致。
#
# 用法：qm1_plan_target_layout <镜像> <目标盘字节数>
# 输出："ESP_MIB ROOT_START_MIB ROOT_SIZE_MIB"
qm1_plan_target_layout() {
    local image="$1" target_bytes="$2"
    local dump esp_size unit scale

    need_cmd sfdisk "apt install fdisk"
    dump="$(LC_ALL=C sfdisk -d "$image" 2>/dev/null || true)"
    [ -n "$dump" ] || die "读不出镜像的分区表（${image}），无法按目标真实容量重建布局"

    # 单位换算：sfdisk -d 的默认单位是扇区（512 字节），也可能声明成字节。
    unit="$(awk '/^unit:/ {print $2; exit}' <<<"$dump")"
    case "$unit" in
        bytes) scale=1 ;;
        sectors|"") scale=512 ;;
        kibibytes) scale=1024 ;;
        *) scale=512 ;;
    esac

    # ESP 分区的大小（字节）与根分区的起始位置。
    # 只认 EFI System 类型 GUID —— 按顺序取第一个分区会把 ESP 和根文件系统
    # 搞反（这是本仓库历史上真出过的错）。
    #
    # sfdisk -d 的分区行长这样（"key=value"，**不是** "key: value"；
    # 冒号只出现在行首的 "设备路径 : " 上）：
    #   /dev/loop0p1 : start=2048, size=131072, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
    # 解析时：先剥掉行首的 "设备路径 : " 前缀，再按逗号切字段，
    # 每个字段按**第一个** "=" 或 ":" 切键值（两种写法都收，
    # 万一 sfdisk 版本换了分隔符也不会解析成空）。
    #
    # 要读三样东西：ESP 的大小、ESP 的起点、根分区的起点。
    # 根分区的起点只能从 **Linux 文件系统类型**的那一行拿 ——
    # 拿成 ESP 的起点会把"1 MiB"当成根分区位置，布局校验就全乱了。
    read -r esp_size esp_start_raw lin_start_raw <<<"$(awk \
        -v g="$(printf '%s' "$QM1_PARTTYPE_EFI" | tr 'A-Z' 'a-z')" \
        -v l="$(printf '%s' "$QM1_PARTTYPE_LINUX" | tr 'A-Z' 'a-z')" '
        {
            line = $0
            p = index(line, " : ")
            if (p > 0) line = substr(line, p + 3)
            type=""; size=""; start=""
            n=split(line, a, ",")
            for (i = 1; i <= n; i++) {
                f = a[i]
                gsub(/^[ \t]+|[ \t]+$/, "", f)
                eq = index(f, "=")
                co = index(f, ":")
                if (eq == 0 && co == 0) continue
                if (eq == 0 || (co > 0 && co < eq)) { k = substr(f, 1, co-1); v = substr(f, co+1) }
                else { k = substr(f, 1, eq-1); v = substr(f, eq+1) }
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k == "type") type=v
                if (k == "size") size=v
                if (k == "start") start=v
            }
            t = tolower(type)
            if (t == g && size != "") { esp_size = size; esp_start = start }
            if (t == l && start != "") { lin_start = start }
        }
        END { printf "%s %s %s\n", (esp_size==""?"0":esp_size), (esp_start==""?"0":esp_start), (lin_start==""?"0":lin_start) }' <<<"$dump")"
    [ "${esp_size:-0}" -gt 0 ] || die "镜像的分区表里没有 EFI System 分区（${QM1_PARTTYPE_EFI}），无法规划目标布局"

    esp_size=$(( esp_size * scale ))
    [ "$esp_size" -gt 0 ] || die "镜像里的 ESP 大小为 0"

    # 目标布局：ESP 从 1 MiB 起，根分区一直撑到盘尾前 1 MiB（给备份 GPT 留位）。
    local esp_mib=$(( (esp_size + 1048575) / 1048576 ))
    local root_start_mib=$(( 1 + esp_mib ))

    # 镜像里的布局必须是"ESP 在 1 MiB、根分区紧跟其后"（assemble-disk.sh 的布局）。
    # 读出来只为校验这一点 —— 不一致就直接报错：宁可不装，
    # 也不要按另一种布局重建分区表。
    if [ "${esp_start_raw:-0}" -gt 0 ]; then
        local img_esp_start_mib=$(( esp_start_raw * scale / 1048576 ))
        [ "$img_esp_start_mib" -eq 1 ] \
            || die "镜像的 ESP 不是从 1 MiB 开始（实际 ${img_esp_start_mib} MiB）—— 拒绝按另一种布局重建分区表"
    fi
    if [ "${lin_start_raw:-0}" -gt 0 ]; then
        local img_root_start_mib=$(( lin_start_raw * scale / 1048576 ))
        [ "$img_root_start_mib" -eq "$root_start_mib" ] \
            || die "镜像的根分区起始位置（${img_root_start_mib} MiB）与约定的 $root_start_mib MiB 不一致 —— 拒绝按另一种布局重建分区表"
    else
        die "镜像的分区表里没有 Linux 文件系统分区（${QM1_PARTTYPE_LINUX}），无法规划目标布局"
    fi
    local root_size_mib=$(( (target_bytes - root_start_mib * 1048576 - 1048576) / 1048576 ))
    [ "$root_size_mib" -gt 0 ] \
        || die "目标盘太小：$(( target_bytes / 1048576 )) MiB 装不下 ESP（$esp_mib MiB）+ 根分区"

    printf '%s %s %s\n' "$esp_mib" "$root_start_mib" "$root_size_mib"
}

# 按规划好的布局在目标盘上重建 GPT。
# 用法：qm1_write_target_layout <目标盘> <ESP_MIB> <根起始 MiB> <根大小 MiB>
# 之所以要重建而不是沿用镜像里的表：sfdisk 是对着**真实设备**写表的，
# 它会把备份 GPT 放到真实盘尾 —— 这正是我们要的（一盘一套 GPT）。
qm1_write_target_layout() {
    local target="$1" esp_mib="$2" root_start_mib="$3" root_size_mib="$4"
    local spec
    spec="$(mktemp)"
    {
        echo "label: gpt"
        echo "start=1MiB, size=${esp_mib}MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        echo "start=${root_start_mib}MiB, size=${root_size_mib}MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    } > "$spec"
    LC_ALL=C sfdisk "$target" < "$spec" >/dev/null \
        || { rm -f "$spec"; die "重建 $target 的分区表失败"; }
    rm -f "$spec"
}

# 让内核重读分区表 —— 写完盘不重读，后续看到的还是旧分区表。
# 三个手段各管一段：partprobe 通知内核、partx -u 让内核更新分区表、
# udevadm settle 等 /dev 下的分区设备节点出现。都不可用时跳过（不致命）。
qm1_rescan_partitions() {
    local target="$1" done=0
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$target" >/dev/null 2>&1 && done=1
    fi
    if command -v partx >/dev/null 2>&1; then
        partx -u "$target" >/dev/null 2>&1 && done=1
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle >/dev/null 2>&1 || true
    fi
    [ "$done" -eq 1 ] || warn "partprobe/partx 都不可用，分区表可能没被内核重读"
    return 0
}

# ---------- wpa_supplicant.conf 的取值规则 ----------
#
# 与 overlay/usr/local/lib/qm1/install-lib.sh 里的同名实现保持一致
# （scripts/test-install-lib.sh 会断言两边输出相同）：
#   * 加引号 = 明文口令（8..63 字符），引号里的 " 和 \ 要转义；
#   * 不加引号 + 64 位十六进制 = 直接给 PMK。
# 64 位十六进制 PSK 如果加引号，会被当成 64 字符口令而超过上限 ⇒ 认证失败。

qm1_wpa_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

qm1_wpa_ssid_value() {
    printf '"%s"' "$(qm1_wpa_escape "$1")"
}

qm1_wpa_psk_value() {
    local psk="$1"
    [ -n "$psk" ] || return 0
    if printf '%s' "$psk" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        printf '%s' "$psk"
        return 0
    fi
    if [ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ]; then
        printf '"%s"' "$(qm1_wpa_escape "$psk")"
        return 0
    fi
    return 1
}

# SAE（WPA3）口令：只有**明文口令**能用。
# 64 位十六进制是 PMK（预计算好的密钥），不是口令 ——
# 拿 PMK 去当 SAE 口令，认证必然失败，所以这种情况干脆不给 sae_password。
qm1_wpa_sae_value() {
    local psk="$1"
    [ -n "$psk" ] || return 0
    if printf '%s' "$psk" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        return 0
    fi
    if [ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ]; then
        printf '"%s"' "$(qm1_wpa_escape "$psk")"
        return 0
    fi
    return 1
}

# key_mgmt 的取值：
#   空口令          → NONE（开放网络）
#   64 位十六进制   → WPA-PSK（只有 WPA2-PSK 能用 PMK）
#   8..63 字符明文  → WPA-PSK SAE
#
# ★ 为什么加上 SAE：
#   路由器要是 WPA3-only，或者 WPA2/WPA3 混合且要求 SAE，
#   只写 key_mgmt=WPA-PSK 就永远连不上 —— 这台机器没有 RJ45，
#   Wi-Fi 连不上等于整机断网。
#   key_mgmt 里 PSK 排在前面，wpa_supplicant 会先试 PSK，
#   所以纯 WPA2 的路由器完全不受影响；驱动不支持 SAE 时
#   顶多多一条 wpa_supplicant 日志，不会把 PSK 那条路弄坏。
qm1_wpa_key_mgmt_value() {
    local psk="$1"
    [ -n "$psk" ] || { printf 'NONE'; return 0; }
    if printf '%s' "$psk" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        printf 'WPA-PSK'
        return 0
    fi
    # 只有长度合法的明文口令才配得上 SAE；
    # 长度非法的口令会在 qm1_wpa_psk_value 那一步被调用方拒绝。
    if [ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ]; then
        printf 'WPA-PSK SAE'
        return 0
    fi
    printf 'WPA-PSK'
}
