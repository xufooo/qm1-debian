#!/bin/bash
# qm1 install helpers -- the disk-level logic of the installer.
#
# Why this file exists: these are the parts of the installer that decide
# *which bytes go where*.  Getting them wrong on a real machine means a
# destroyed eMMC, so they are kept in a separate file that can be exercised
# without a machine -- the CI job "Installer disk helpers" builds synthetic
# GPT images and checks that the helpers find the right partitions and that
# the backup verification really detects a difference.
#
# Everything here is a pure function of its arguments: no globals, no
# side effects beyond writing to stdout.  The installer passes its own
# globals in.

# GPT partition type GUIDs (the on-disk form, mixed endian in the table).
# shellcheck disable=SC2034  # used by the scripts that source this file
QM1_PARTTYPE_EFI="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
# shellcheck disable=SC2034
QM1_PARTTYPE_LINUX="0fc63daf-8483-4772-8e79-3d69d8477de4"

qm1_install_log() { printf '[qm1-install][info] %s\n' "$*"; }
qm1_install_warn() { printf '[qm1-install][warn] %s\n' "$*" >&2; }

# sha256 of a byte range of a file: $1=file $2=offset $3=length
qm1_hash_range() {
    dd if="$1" iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none 2>/dev/null \
        | sha256sum | awk '{print $1}'
}

# The partitions of a device, one per line:
#   name start size parttype partnumber
# start and size are in bytes (lsblk -b).
qm1_partitions() {
    lsblk -bnro NAME,START,SIZE,PARTTYPE,PARTN "$1" 2>/dev/null \
        | awk 'NF>=4 && $4 ~ /^[0-9a-fA-F][0-9a-fA-F-]+$/ {print $1, $2, $3, tolower($4), $5}'
}

# Find a partition by its type GUID: $1=device $2=type GUID
# prints "name start size", empty if there is none.
qm1_find_partition() {
    qm1_partitions "$1" | awk -v t="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
        '$4 == t {print $1, $2, $3; exit}'
}

# Same, but with the partition number: $1=device $2=type GUID
# prints "name partno start size", empty if there is none.
qm1_find_partition_by_type() {
    qm1_partitions "$1" | awk -v t="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
        '$4 == t {print $1, $5, $2, $3; exit}'
}

# The end of the last partition, in bytes: $1=device
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

# Compare a disk against its backup, partition by partition.
#   $1=target device, $2=backup source (file or raw device), $3=offset of the
#   backup image inside that source (0 for a plain file)
# The point of doing it this way and not just hashing the backup file: a
# backup that was written to the wrong place, or that was truncated, has a
# perfectly consistent hash of its own.
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
            qm1_install_log "  分区 $name（偏移 $start，$(( size / 1048576 )) MiB）一致：$dsum"
            ok=$(( ok + 1 ))
        else
            qm1_install_warn "  分区 $name（偏移 $start，$(( size / 1048576 )) MiB）不一致：原盘 $dsum / 备份 $bsum"
            bad=$(( bad + 1 ))
        fi
    done < <(lsblk -bnro NAME,START,SIZE,TYPE "$target" 2>/dev/null \
             | awk '$4=="part" && $3>0 {print $1, $2, $3}')

    qm1_install_log "备份校验：$ok 项一致，$bad 项不一致"
    [ "$bad" -eq 0 ]
}

# ---------- wpa_supplicant.conf 的取值规则 ----------
#
# wpa_supplicant 的 psk 有两种写法，含义完全不同：
#   * 加引号 = 明文口令，必须是 8..63 个字符，引号里的 " 和 \ 要用 \ 转义；
#   * 不加引号 + 64 位十六进制 = 直接给出 PMK（就是路由器上显示的那串 64 字符）。
# 把 64 位十六进制 PSK 加引号写出去，它会被当成 64 个字符的口令 —— 超过 63
# 的上限，wpa_supplicant 直接拒绝，现象是"密码明明是对的却连不上"。
# SSID 则一律加引号并转义。
#
# 这三个函数在构建链（scripts/lib/common.sh）与镜像内（install-lib.sh）各有一份
# 同名实现，scripts/test-install-lib.sh 会断言两边输出一致，防止走样。

qm1_wpa_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# SSID 的取值（一律加引号并转义）
qm1_wpa_ssid_value() {
    printf '"%s"' "$(qm1_wpa_escape "$1")"
}

# PSK 的取值：64 位十六进制不加引号；8..63 字符加引号并转义。
# 空口令 = 开放网络，输出为空（调用方据此省略 psk 行）。
# 长度非法返回 1，由调用方报错。
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
