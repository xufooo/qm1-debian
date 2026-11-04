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
