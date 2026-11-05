#!/bin/sh
# ============================================================================
# overlay-modes.sh — 镜像里 overlay 文件的权限规范化（POSIX sh，宿主与 hook 共用）
# ============================================================================
# 为什么要专门管这件事：
#   git 只记录"有没有执行位"，不记录组/其他人能不能写。checkout 时 git 会按
#   当前 umask 重算权限，于是同一个提交在不同构建机上落出来的权限并不一样：
#   同一份 overlay，在 umask 022 的机器上是 0755/0644，在 umask 002 的机器上
#   就是 0775/0664。CI 上就是这么翻的车 —— 镜像校验要求 qm1-wifi-start 是
#   0755，构建机却把 0775 写进了 ext4 镜像。
#
#   权限不是"构建机的环境"，它是镜像的一部分，必须由仓库说了算。
#   所以：hook03 拷贝完 overlay 之后，按下面的规则统一收口一次。
#
#   * 我们自己的可执行脚本（usr/local/sbin、usr/local/bin）⇒ 0755
#   * 其余普通文件（单元、配置、函数库）⇒ 0644
#   * 目录 ⇒ 0755
#
#   只处理 overlay 自己带来的路径，不碰发行版包装出来的文件。
# ============================================================================

# qm1_normalize_overlay_modes <overlay-src-dir> <target-dir>
qm1_normalize_overlay_modes() {
    _om_src="${1:?usage: qm1_normalize_overlay_modes <overlay-src-dir> <target-dir>}"
    _om_dst="${2:?usage: qm1_normalize_overlay_modes <overlay-src-dir> <target-dir>}"
    [ -d "$_om_src" ] || return 0

    find "$_om_src" -type d | while read -r _om_d; do
        _om_rel="${_om_d#"$_om_src"}"
        chmod 0755 "$_om_dst$_om_rel" 2>/dev/null || true
    done

    find "$_om_src" -type f | while read -r _om_f; do
        _om_rel="${_om_f#"$_om_src"}"
        case "$_om_rel" in
            /usr/local/sbin/*|/usr/local/bin/*) _om_mode=0755 ;;
            *)                                    _om_mode=0644 ;;
        esac
        chmod "$_om_mode" "$_om_dst$_om_rel" 2>/dev/null || true
    done
}
