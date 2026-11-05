#!/usr/bin/env bash
# test-boot-smoke-assert.sh — 用 fixture 验证 boot-smoke 的断言逻辑
#
# 为什么要有这个：
#   boot-smoke 的断言串是整套出货链里最脆的一环。systemd 从 v255 起改了
#   控制台状态行格式（单元名插到描述前面 + ANSI 高亮 + 描述按宽度截断），
#   一改，断言就全盘匹配不到 —— 而"匹配不到"在 CI 上和"启动失败"长得
#   一模一样。本轮就踩了：断言写的是旧格式的
#       "Started OpenBSD Secure Shell server"
#   真实字节却是
#       Started \e[0;1;39mssh.service\e[0m - OpenBSD Secure Shell server.
#   ⇒ 断言必须能被离线喂数据验证，否则只能等真跑一次 CI 才知道写错了。
#
# 这里造四份 fixture：
#   ① 正常启动（带 ANSI）        → 断言必须全过
#   ② 卡在 getty.target（无 multi-user.target）→ 必须挂
#   ③ Wi-Fi 单元卡在 activating → 必须挂
#   ④ 关键单元 Failed to start   → 必须挂
#
# fixture 里的 ANSI 是**真的 ESC 字节**（printf '\033'），不是字面 "^["
# —— 因为那才是 systemd 写进串口的样子；字面 "^[…" 那种形态（某些日志
# 采集器转义后的结果）在断言脚本里也做了兼容，但主用例必须用真字节。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSERT="$SCRIPT_DIR/boot-smoke-assert.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()   { echo "  [ OK ] $1"; }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

[ -f "$ASSERT" ] || { echo "找不到 $ASSERT" >&2; exit 1; }

ESC="$(printf '\033')"

# ---------- fixture ①：正常启动 ----------
cat > "$WORK/good.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Finished ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-rtw88-8723bs.service${ESC}[0m - Load the RTL8723BS driver.
EOF

# ---------- fixture ②：卡在 getty.target ----------
cat > "$WORK/stuck.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] ${ESC}[0;1;39mgetty.target${ESC}[0m - Login Prompts.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Finished ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF

# ---------- fixture ③：Wi-Fi 单元卡在 activating（只有 Starting，没有 Started）----------
cat > "$WORK/wifi-stuck.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Finished ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
${ESC}[0;1;39mStarting${ESC}[0m ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF

# ---------- fixture ④：关键单元起失败 ----------
cat > "$WORK/failed.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;31mFAILED${ESC}[0m] Failed to start ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Finished ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF

# ---------- fixture ⑤：驱动单元起失败（模块索引没刷新的经典症状）----------
cat > "$WORK/driver-failed.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Finished ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
[${ESC}[0;31mFAILED${ESC}[0m] Failed to start ${ESC}[0;1;39mqm1-rtw88-8723bs.service${ESC}[0m - Load the RTL8723BS driver.
EOF

# ---------- 跑 ----------
echo "== boot-smoke 断言逻辑自测 =="

if bash "$ASSERT" --console "$WORK/good.log" >/dev/null 2>&1; then
    ok "正常启动的日志应当全过"
else
    bad "正常启动的日志竟然没通过 —— 断言串可能腐化了"
    bash "$ASSERT" --console "$WORK/good.log" 2>&1 | tail -5
fi

if bash "$ASSERT" --console "$WORK/stuck.log" >/dev/null 2>&1; then
    bad "没走到 multi-user.target 的日志竟然通过了 —— 里程碑断言失效"
else
    ok "卡在 getty.target 的日志应当挂（里程碑断言有效）"
fi

if bash "$ASSERT" --console "$WORK/wifi-stuck.log" >/dev/null 2>&1; then
    bad "Wi-Fi 单元卡在 activating 的日志竟然通过了 —— 回归闸失效"
else
    ok "Wi-Fi 单元只有 Starting 没有 Started 的日志应当挂"
fi

if bash "$ASSERT" --console "$WORK/failed.log" >/dev/null 2>&1; then
    bad "sshd 起失败的日志竟然通过了 —— 失败清单失效"
else
    ok "关键单元起失败的日志应当挂"
fi

if bash "$ASSERT" --console "$WORK/driver-failed.log" >/dev/null 2>&1; then
    bad "驱动单元起失败的日志竟然通过了 —— 驱动特判失效"
else
    ok "Wi-Fi 驱动单元起失败的日志应当挂"
fi

# ---------- journal 断言 ----------
cat > "$WORK/j-ok.txt" <<'EOF'
Startup finished in 12s.
[qm1-firstboot] provisioning ok
EOF
cat > "$WORK/j-bad.txt" <<'EOF'
something else entirely
EOF
if bash "$ASSERT" --console "$WORK/good.log" --journal-text-file "$WORK/j-ok.txt" >/dev/null 2>&1; then
    ok "journal 完整时应当全过"
else
    bad "journal 完整时竟然没过"
fi
if bash "$ASSERT" --console "$WORK/good.log" --journal-text-file "$WORK/j-bad.txt" >/dev/null 2>&1; then
    bad "journal 里没有 qm1-firstboot 记录竟然过了 —— journal 断言失效"
else
    ok "journal 缺 qm1-firstboot 记录时应当挂"
fi

# ---------- 字面 "^[…" 形态（采集器转义后的日志）也要能读 ----------
cat > "$WORK/escaped.log" <<'EOF'
[^[[0;32m  OK  ^[[0m] Reached target ^[[0;1;39mmulti-user.target^[[0m - Multi-User System.
[^[[0;32m  OK  ^[[0m] Started ^[[0;1;39mssh.service^[[0m - OpenBSD Secure Shell server.
[^[[0;32m  OK  ^[[0m] Started ^[[0;1;39msystemd-resolved.service^[[0m - Resolve LLM DNS and DNS Over TLS.
[^[[0;32m  OK  ^[[0m] Finished ^[[0;1;39mqm1-firstboot.service^[[0m - QM1 first boot provisioning (Wi-Fi, SSH, hostname).
[^[[0;32m  OK  ^[[0m] Started ^[[0;1;39mqm1-wifi@wlan0.service^[[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF
if bash "$ASSERT" --console "$WORK/escaped.log" >/dev/null 2>&1; then
    ok "ANSI 被转义成字面 ^[ 的日志也应当全过"
else
    bad "ANSI 被转义成字面 ^[ 的日志竟然没过 —— 清洗逻辑有洞"
fi

# ---------- fixture ⑥：首启单元起失败（"没跑完"和"起失败"必须能分开报）----------
cat > "$WORK/firstboot-failed.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;31mFAILED${ESC}[0m] Failed to start ${ESC}[0;1;39mqm1-firstboot.service${ESC}[0m - QM1 first boot provisioning.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF
if bash "$ASSERT" --console "$WORK/firstboot-failed.log" >/dev/null 2>&1; then
    bad "首启单元起失败的日志竟然通过了 —— 失败清单失效"
else
    ok "首启单元起失败的日志应当挂（并且要报成『起失败』，不是『没跑完』）"
fi

# ---------- fixture ⑦：控制台缺 Finished 行，但 journal 里有脚本输出 ⇒ 判为已执行 ----------
cat > "$WORK/no-finished.log" <<EOF
[${ESC}[0;32m  OK  ${ESC}[0m] Reached target ${ESC}[0;1;39mmulti-user.target${ESC}[0m - Multi-User System.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mssh.service${ESC}[0m - OpenBSD Secure Shell server.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39msystemd-resolved.service${ESC}[0m - Resolve LLM DNS and DNS Over TLS.
[${ESC}[0;32m  OK  ${ESC}[0m] Started ${ESC}[0;1;39mqm1-wifi@wlan0.service${ESC}[0m - QM1 internal Wi-Fi (wlan0) managed by wpa_supplicant.
EOF
cat > "$WORK/j-firstboot.txt" <<'EOF'
Startup finished in 12s.
[qm1-firstboot] provisioning ok
EOF
if bash "$ASSERT" --console "$WORK/no-finished.log" --journal-text-file "$WORK/j-firstboot.txt" >/dev/null 2>&1; then
    ok "控制台缺 Finished 行但 journal 里有首启输出时，应当判为已执行"
else
    bad "控制台缺 Finished 行但 journal 里有首启输出时，不该判失败"
fi

# ---------- fixture ⑧：控制台缺 Finished 行，journal 里也没有 ⇒ 它确实没跑 ----------
cat > "$WORK/j-none.txt" <<'EOF'
something else entirely
EOF
if bash "$ASSERT" --console "$WORK/no-finished.log" --journal-text-file "$WORK/j-none.txt" >/dev/null 2>&1; then
    bad "两份证据都没有首启痕迹时竟然过了 —— 首启断言失效"
else
    ok "两份证据都没有首启痕迹时应当挂（首启那一步确实没跑）"
fi

# ---------- fixture ⑨：SIGPIPE 假失败（命中位置靠前 + 文本超过管道缓冲）----------
#   本轮 CI 红在"systemd-resolved 没起来"，而日志里明明有
#       [  OK  ] Started systemd-resolved.service - Network Name Resolution.
#   真正的原因：断言写成 `printf '%s' "$OUT" | grep -qF -- "…"`，
#   grep -q 一命中就退出 ⇒ 上游 printf 还在写（控制台文本 > 64KB 管道缓冲）
#   ⇒ printf 被 SIGPIPE 打死（141）⇒ set -o pipefail 把 141 变成管道失败码
#   ⇒ 明明命中却报"不过"。命中位置越靠前越容易踩：resolved 开机很早就
#   Started（早 ⇒ grep 立刻退出），ssh 永远在很晚（从没踩到）。
#   这个 fixture 把命中行放在**最前面**并把日志灌到 > 64KB，
#   用旧的管道写法必挂、用 herestring 写法必须过。
{
    printf '[%s[0;32m  OK  %s[0m] Started %s[0;1;39msystemd-resolved.service%s[0m - Network Name Resolution.\n' \
        "$ESC" "$ESC" "$ESC" "$ESC"
    # 灌一堆噪声，把总量推到远大于管道的默认缓冲（64KB）
    i=0
    while [ "$i" -lt 1200 ]; do
        printf 'noise line %04d: %s\n' "$i" "$(printf 'x%.0s' $(seq 1 60))"
        i=$((i + 1))
    done
    printf '[%s[0;32m  OK  %s[0m] Reached target %s[0;1;39mmulti-user.target%s[0m - Multi-User System.\n' \
        "$ESC" "$ESC" "$ESC" "$ESC"
    printf '[%s[0;32m  OK  %s[0m] Started %s[0;1;39mssh.service%s[0m - OpenBSD Secure Shell server.\n' \
        "$ESC" "$ESC" "$ESC" "$ESC"
    printf '[%s[0;32m  OK  %s[0m] Finished %s[0;1;39mqm1-firstboot.service%s[0m - QM1 first boot provisioning.\n' \
        "$ESC" "$ESC" "$ESC" "$ESC"
    printf '[%s[0;32m  OK  %s[0m] Started %s[0;1;39mqm1-wifi@wlan0.service%s[0m - QM1 internal Wi-Fi managed by wpa_supplicant.\n' \
        "$ESC" "$ESC" "$ESC" "$ESC"
} > "$WORK/big.log"
if [ "$(wc -c < "$WORK/big.log")" -lt 65536 ]; then
    bad "fixture ⑨ 没造够数据（$(wc -c < "$WORK/big.log") 字节），测不到 SIGPIPE"
elif bash "$ASSERT" --console "$WORK/big.log" >/dev/null 2>&1; then
    ok "命中行靠前且日志超过 64KB 时仍然判过（没有 SIGPIPE 假失败）"
else
    bad "命中行靠前且日志超过 64KB 时被判不过 —— 又踩了 grep -q 的 SIGPIPE"
    bash "$ASSERT" --console "$WORK/big.log" 2>&1 | tail -5
fi

if [ "$FAIL" -ne 0 ]; then
    echo "自测失败：$FAIL 项不对" >&2
    exit 1
fi
echo "自测全部通过"