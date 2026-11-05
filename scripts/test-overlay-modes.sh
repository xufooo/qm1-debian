#!/usr/bin/env bash
# ============================================================================
# test-overlay-modes.sh — 镜像里 overlay 文件的权限规范化，单测
# ============================================================================
# 背景：git 只记录"有没有执行位"，checkout 时按当前 umask 重算权限，于是
# 同一个提交在不同构建机上落出来的权限不一样（umask 022 → 0755，
# umask 002 → 0775）。CI 上镜像校验要求 qm1-wifi-start 是 0755，构建机却把
# 0775 写进了 ext4 镜像，校验因此翻脸。
#
# 这里用一棵合成目录树把规则钉死：
#   * 可执行脚本（usr/local/sbin、usr/local/bin）⇒ 0755
#   * 其余普通文件（单元、配置、函数库）⇒ 0644
#   * 目录 ⇒ 0755
#   * overlay 之外的东西不许被碰
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/overlay-modes.sh
. "$SCRIPT_DIR/lib/overlay-modes.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
DST="$WORK/dst"

mkdir -p "$SRC/usr/local/sbin" "$SRC/usr/local/bin" "$SRC/usr/local/lib/qm1" \
         "$SRC/etc/systemd/system" "$SRC/etc/default"
mkdir -p "$DST/usr/bin"

: > "$SRC/usr/local/sbin/qm1-wifi-start"
: > "$SRC/usr/local/bin/qm1-selftest-report"
: > "$SRC/usr/local/lib/qm1/install-lib.sh"
: > "$SRC/etc/systemd/system/qm1-wifi@.service"
: > "$SRC/etc/default/qm1-hardware"
: > "$DST/usr/bin/not-ours"

# 模拟 checkout 在不同 umask 下的结果
chmod 0775 "$SRC/usr/local/sbin/qm1-wifi-start"
chmod 0775 "$SRC/usr/local/bin/qm1-selftest-report"
chmod 0777 "$SRC/usr/local/lib/qm1/install-lib.sh"
chmod 0664 "$SRC/etc/systemd/system/qm1-wifi@.service"
chmod 0664 "$SRC/etc/default/qm1-hardware"
chmod 0700 "$DST/usr/bin/not-ours"

# 模拟 cp -a 之后的样子
cp -a "$SRC/." "$DST/"

fail=0
expect_mode() {
    local path="$1" want="$2" got
    got="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
    if [ "$got" = "$want" ]; then
        printf '  OK   %-52s (%s)\n' "$path" "$want"
    else
        printf '  FAIL %-52s (期望 %s，实际 %s)\n' "$path" "$want" "$got"
        fail=$((fail + 1))
    fi
}

qm1_normalize_overlay_modes "$SRC" "$DST"

expect_mode "$DST/usr/local/sbin/qm1-wifi-start"      755
expect_mode "$DST/usr/local/bin/qm1-selftest-report"  755
expect_mode "$DST/usr/local/lib/qm1/install-lib.sh"    644
expect_mode "$DST/etc/systemd/system/qm1-wifi@.service" 644
expect_mode "$DST/etc/default/qm1-hardware"           644
expect_mode "$DST/usr/local/sbin"                     755
expect_mode "$DST/usr/local/lib/qm1"                  755
expect_mode "$DST/usr/bin/not-ours"                   700

# 再跑一遍必须得到同样的结果（幂等）
qm1_normalize_overlay_modes "$SRC" "$DST"
expect_mode "$DST/usr/local/sbin/qm1-wifi-start"      755
expect_mode "$DST/etc/systemd/system/qm1-wifi@.service" 644

if [ "$fail" -gt 0 ]; then
    printf '\n[FAIL] overlay 权限规范化：%d 项不通过\n' "$fail"
    exit 1
fi
printf '\n[ OK ] overlay 权限规范化单测全部通过\n'
