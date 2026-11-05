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
