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
    case "$1" in
        amd64) printf 'trixie\n' ;;
        i386)  printf 'bookworm\n' ;;
        *) die "不支持的架构：$1" ;;
    esac
}

# 每个架构对应的内核包名。
#
# 注意 Debian 的 i386 内核 flavour 叫 686 / 686-pae，并没有 linux-image-i386 这个包：
#   linux-image-686      "Linux for older PCs"（非 PAE，老 CPU 用）
#   linux-image-686-pae  "Linux for modern PCs"（PAE，Bay Trail 选它）
kernel_pkgs_for_arch() {
    case "$1" in
        amd64) printf 'linux-image-amd64,linux-headers-amd64\n' ;;
        i386)  printf 'linux-image-686-pae,linux-headers-686-pae\n' ;;
        *) die "不支持的架构：$1" ;;
    esac
}
