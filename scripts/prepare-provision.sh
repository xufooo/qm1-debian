#!/usr/bin/env bash
# prepare-provision.sh — 生成"开机即联网"的 provisioning 目录
#
# 照 Raspberry Pi 的思路：把配置写成一个目录，放进启动分区（ESP）或随安装
# 介质一起带走，QM1 首次开机就会自动读取（见 overlay 的 qm1-firstboot）。
#
# 产出目录内容：
#   wpa_supplicant.conf   Wi-Fi 配置（SSID / 密码 / 国家码）
#   ssh                   存在即启用 SSH（通常为空文件）
#   authorized_keys       可选：SSH 公钥
#   ssh_user              可选：公钥同时装给哪个普通用户
#   hostname              可选：主机名
#
# 用法：
#   # 交互式（会提示输入 SSID 与密码）
#   bash scripts/prepare-provision.sh --out build/provision
#
#   # 非交互（适合 CI / 脚本）
#   bash scripts/prepare-provision.sh --out build/provision \
#        --ssid "MyWiFi" --psk "passphrase" --enable-ssh \
#        --ssh-pubkey ~/.ssh/id_ed25519.pub
#
#   # 密码从文件读（避免进 shell 历史）
#   bash scripts/prepare-provision.sh --out build/provision \
#        --ssid "MyWiFi" --psk-file ./psk.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT=""
SSID=""
PSK=""
PSK_FILE=""
COUNTRY="CN"
HOSTNAME=""
ENABLE_SSH=0
SSH_USER=""
SSH_PUBKEY=""
FORCE=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --ssid) SSID="$2"; shift 2 ;;
        --psk) PSK="$2"; shift 2 ;;
        --psk-file) PSK_FILE="$2"; shift 2 ;;
        --country) COUNTRY="$2"; shift 2 ;;
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --enable-ssh) ENABLE_SSH=1; shift ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --ssh-pubkey) SSH_PUBKEY="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) die "未知参数：$1（--help 看用法）" ;;
    esac
done

[ -n "$OUT" ] || die "缺少 --out（输出目录）"

if [ -n "$PSK_FILE" ]; then
    [ -f "$PSK_FILE" ] || die "找不到密码文件：$PSK_FILE"
    PSK="$(tr -d '\r\n' < "$PSK_FILE")"
fi

if [ -n "$SSH_PUBKEY" ]; then
    [ -f "$SSH_PUBKEY" ] || die "找不到公钥文件：$SSH_PUBKEY"
    ENABLE_SSH=1
fi

# 交互式补齐缺失的 SSID / 密码
if [ -z "$SSID" ] && [ -t 0 ]; then
    printf 'Wi-Fi SSID: '
    read -r SSID
fi
[ -n "$SSID" ] || die "缺少 SSID（用 --ssid 提供，或在交互终端里运行）"

if [ -z "$PSK" ] && [ -t 0 ]; then
    printf 'Wi-Fi 密码（留空表示开放网络）: '
    read -r PSK
fi

if [ -e "$OUT" ] && [ "$FORCE" != 1 ]; then
    [ -d "$OUT" ] || die "输出路径已存在且不是目录：$OUT"
    if [ -n "$(ls -A "$OUT" 2>/dev/null || true)" ]; then
        die "输出目录非空：${OUT}（加 --force 覆盖）"
    fi
fi

mkdir -p "$OUT"
chmod 0700 "$OUT"

# ---------- wpa_supplicant.conf ----------
# psk 可以是 8..63 字符的明文（加引号）或 64 位十六进制 PSK（不加引号）。
# 取值规则统一走 common.sh 的 qm1_wpa_* ：64 位十六进制**不加引号**，
# 否则它会被当成 64 字符的口令而超过 63 的上限，wpa_supplicant 直接拒绝
# （现象是"密码是对的却连不上"）。SSID 一律加引号并转义。
PSK_LINE=""
SAE_LINE=""
if [ -n "$PSK" ]; then
    if ! PSK_VALUE="$(qm1_wpa_psk_value "$PSK")"; then
        die "Wi-Fi 密码长度非法（${#PSK} 字符）：需要 8..63 字符，或 64 位十六进制"
    fi
    PSK_LINE="    psk=$PSK_VALUE"
    # 明文口令同时可以当 SAE 口令（路由器是 WPA3-only 或混合模式时要用）。
    # 64 位十六进制是 PMK，不能当口令，所以那情况不给 sae_password。
    if SAE_VALUE="$(qm1_wpa_sae_value "$PSK")" && [ -n "$SAE_VALUE" ]; then
        SAE_LINE="    sae_password=$SAE_VALUE"
    fi
fi

{
    echo "# 由 prepare-provision.sh 生成 —— 首启时 qm1-firstboot 会读取并写入系统"
    echo "country=$COUNTRY"
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    echo "network={"
    echo "    ssid=$(qm1_wpa_ssid_value "$SSID")"
    [ -n "$PSK_LINE" ] && echo "$PSK_LINE"
    [ -n "$SAE_LINE" ] && echo "$SAE_LINE"
    # 没有 psk 就是开放网络 ⇒ key_mgmt 必须是 NONE。
    # 写成 WPA-PSK 又不带 psk，wpa_supplicant 会拒绝整段 network 块
    # （而且是"连不上"这种看不出原因的现象）。
    # 有口令时 key_mgmt 带 SAE：纯 WPA2 的路由器会先走 PSK，不受影响；
    # WPA3-only / 要求 SAE 的混合路由器才连得上（这台机器没网口）。
    echo "    key_mgmt=$(qm1_wpa_key_mgmt_value "$PSK")"
    echo "}"
} > "$OUT/wpa_supplicant.conf"
chmod 0600 "$OUT/wpa_supplicant.conf"

# ---------- SSH ----------
if [ "$ENABLE_SSH" = 1 ]; then
    : > "$OUT/ssh"
    chmod 0600 "$OUT/ssh"
fi

if [ -n "$SSH_PUBKEY" ]; then
    cp "$SSH_PUBKEY" "$OUT/authorized_keys"
    chmod 0600 "$OUT/authorized_keys"
    [ -n "$SSH_USER" ] && printf '%s\n' "$SSH_USER" > "$OUT/ssh_user"
fi

[ -n "$HOSTNAME" ] && printf '%s\n' "$HOSTNAME" > "$OUT/hostname"

log "provisioning 目录已生成：$OUT"
ls -l "$OUT" >&2
log "把它放进启动分区（ESP）的 /qm1/provision/，或用 --provision-dir 传给 make-esp.sh"
