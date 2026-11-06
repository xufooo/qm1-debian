#!/usr/bin/env bash
# test-wpa-conf.sh — wpa_supplicant 配置的取值规则与生成结果
#
# 为什么单独一个测试文件：
#   scripts/test-install-lib.sh 也断言这些规则，但那个脚本要 sfdisk
#   （本机 macOS 没有）⇒ 这部分断言在本地永远跑不到。
#   而"密码写对了却连不上"恰恰是这台机器最致命的一类问题：
#   它没有 RJ45，Wi-Fi 连不上 = 整机断网 = 看起来像砖。
#
# 覆盖三件事：
#   1. 两份同名实现（构建链 scripts/lib/common.sh 与镜像内 install-lib.sh）
#      的输出必须逐字一致，且符合规则；
#   2. prepare-provision.sh 真正生成的 wpa_supplicant.conf 内容正确
#      （明文口令 / 64 位十六进制 PMK / 开放网络三种）；
#   3. 另外两个写配置的脚本（provision-agent.sh 与设备侧安装器）
#      必须走共享的 helper，而不是自己写死 key_mgmt。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_LIB="$REPO_ROOT/scripts/lib/common.sh"
INSTALL_LIB="$REPO_ROOT/overlay/usr/local/lib/qm1/install-lib.sh"

FAILED=0
ok() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

[ -r "$COMMON_LIB" ] || { printf '找不到 %s\n' "$COMMON_LIB" >&2; exit 1; }
[ -r "$INSTALL_LIB" ] || { printf '找不到 %s\n' "$INSTALL_LIB" >&2; exit 1; }

# ---------- 1. 两份实现的取值规则 ----------
eval_wpa() {  # $1=lib $2=psk → "psk|sae|key_mgmt|psk_rc"
    bash -c '
        set -uo pipefail
        . "$1"
        if p="$(qm1_wpa_psk_value "$2")"; then prc=0; else prc=1; p=""; fi
        if s="$(qm1_wpa_sae_value "$2")"; then :; else s=""; fi
        k="$(qm1_wpa_key_mgmt_value "$2")"
        printf "%s|%s|%s|%s\n" "$p" "$s" "$k" "$prc"
    ' _ "$1" "$2"
}

HEX64="$(printf 'a%.0s' $(seq 1 64))"
rule_case() {  # $1=说明 $2=psk $3=期望
    a="$(eval_wpa "$INSTALL_LIB" "$2")"
    b="$(eval_wpa "$COMMON_LIB" "$2")"
    if [ "$a" != "$b" ]; then
        bad "$1：两份实现不一致（镜像内 ${a} / 构建链 ${b}）"
    elif [ "$a" != "$3" ]; then
        bad "$1：得到 ${a}，期望 ${3}"
    else
        ok "$1 → $a"
    fi
}

rule_case "明文口令：psk 加引号 + 同值 sae_password + key_mgmt 带 SAE" \
    "passphrase" '"passphrase"|"passphrase"|WPA-PSK SAE|0'
rule_case "64 位十六进制 PMK：不加引号 + 不给 sae_password + 只 WPA-PSK" \
    "$HEX64" "$HEX64||WPA-PSK|0"
rule_case "开放网络：无 psk + key_mgmt=NONE" \
    "" "||NONE|0"
rule_case "太短的口令被拒绝" "short" "||WPA-PSK|1"

# ---------- 2. prepare-provision.sh 真正生成的配置 ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gen_conf() {  # $1=psk $2=输出目录 → 打印 wpa_supplicant.conf
    local psk="$1" out="$2"
    rm -rf "$out"
    bash "$SCRIPT_DIR/prepare-provision.sh" --out "$out" --ssid "TestNet" --psk "$psk" \
        >/dev/null 2>&1 || return 1
    cat "$out/wpa_supplicant.conf"
}

conf_pass="$(gen_conf "passphrase" "$WORK/p1")"
if grep -q 'ieee80211w=1' <<<"$conf_pass"; then
    ok "SAE 配置同时启用 optional PMF"
else
    bad "SAE 配置缺少管理帧保护（WPA3 不能完成关联）"
fi
if printf '%s' "$conf_pass" | grep -q 'key_mgmt=WPA-PSK SAE'; then
    ok "明文口令生成的配置带 key_mgmt=WPA-PSK SAE"
else
    bad "明文口令生成的配置没有 key_mgmt=WPA-PSK SAE：$(printf '%s' "$conf_pass" | tr '\n' '|')"
fi
if printf '%s' "$conf_pass" | grep -q 'sae_password="passphrase"'; then
    ok "明文口令生成的配置带 sae_password"
else
    bad "明文口令生成的配置缺 sae_password：$(printf '%s' "$conf_pass" | tr '\n' '|')"
fi
if printf '%s' "$conf_pass" | grep -q 'psk="passphrase"'; then
    ok "明文口令生成的配置里 psk 加引号"
else
    bad "明文口令生成的配置里 psk 没加引号：$(printf '%s' "$conf_pass" | tr '\n' '|')"
fi

conf_hex="$(gen_conf "$HEX64" "$WORK/p2")"
if printf '%s' "$conf_hex" | grep -q 'key_mgmt=WPA-PSK$'; then
    ok "64 位十六进制 PMK 生成的配置只用 WPA-PSK"
else
    bad "64 位十六进制 PMK 生成的配置不该带 SAE：$(printf '%s' "$conf_hex" | tr '\n' '|')"
fi
if printf '%s' "$conf_hex" | grep -q 'sae_password'; then
    bad "64 位十六进制 PMK 不能当 SAE 口令，不该写 sae_password：$(printf '%s' "$conf_hex" | tr '\n' '|')"
else
    ok "64 位十六进制 PMK 没有写 sae_password"
fi

# ---------- 3. 另外两个写配置的脚本必须走共享 helper ----------
# 它们自己写死 key_mgmt 的话，改了 common.sh 也不会生效 ——
# "CI 里配好的密码，机器上连不上"就是这么来的。
for f in scripts/provision-agent.sh overlay/usr/local/sbin/qm1-install-to-emmc; do
    path="$REPO_ROOT/$f"
    [ -r "$path" ] || { bad "找不到 $f"; continue; }
    if grep -q 'qm1_wpa_key_mgmt_value' "$path"; then
        ok "$f 走共享的 key_mgmt 取值规则"
    else
        bad "$f 没有调用 qm1_wpa_key_mgmt_value（自己写死 key_mgmt 了？）"
    fi
    if grep -q 'qm1_wpa_sae_value' "$path"; then
        ok "$f 走共享的 sae_password 取值规则"
    else
        bad "$f 没有调用 qm1_wpa_sae_value"
    fi
    if grep -q 'key_mgmt=WPA-PSK$' "$path"; then
        bad "$f 里还有写死的 key_mgmt=WPA-PSK"
    else
        ok "$f 里没有写死的 key_mgmt=WPA-PSK"
    fi
done

if [ "$FAILED" -eq 0 ]; then
    printf '\nwpa_supplicant 配置测试全部通过\n'
    exit 0
fi
printf '\nwpa_supplicant 配置测试有 %s 项失败\n' "$FAILED" >&2
exit 1
