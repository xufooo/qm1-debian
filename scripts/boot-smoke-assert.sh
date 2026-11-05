#!/usr/bin/env bash
# boot-smoke-assert.sh — 对一份客户机控制台日志做断言
#
# 为什么单独拆一个脚本：
#   断言串是这套冒烟测试里最脆的东西。systemd 从 v255 起改了控制台状态行
#   的格式（单元名被插到描述前面，还带 ANSI 高亮），一改就全盘匹配不到，
#   而"匹配不到"和"启动失败"在 CI 上长得一模一样 —— 本轮就踩过一次：
#   断言写着 "Started OpenBSD Secure Shell server"（旧格式），
#   真实字节却是
#       Started \e[0;1;39mssh.service\e[0m - OpenBSD Secure Shell server.
#   ⇒ 断言必须能被单独喂数据验证，否则只能等真跑一次 CI 才知道自己写错了。
#   拆出来之后：
#     · boot-smoke.sh 跑完把控制台日志丢给它断言；
#     · scripts/test-boot-smoke-assert.sh 用带 ANSI 的 fixture 喂它，
#       正例必须过、反例必须挂 —— 断言串腐化了当场就能发现。
#
# 用法：
#   bash scripts/boot-smoke-assert.sh --console build/out/boot-smoke/console.log
#   bash scripts/boot-smoke-assert.sh --console xxx.log --journal-text-file jj.txt
#
# 退出码：0 = 断言全过；1 = 有断言不过。
set -uo pipefail

CONSOLE=""
JOURNAL_TEXT_FILE=""
JOURNAL_TEXT=""

die() { echo "BOOT-SMOKE-ASSERT: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --console)         CONSOLE="$2"; shift 2 ;;
        --journal-text-file) JOURNAL_TEXT_FILE="$2"; shift 2 ;;
        *) die "未知参数 $1" ;;
    esac
done

[ -n "$CONSOLE" ] || die "必须给 --console"
[ -f "$CONSOLE" ] || die "找不到控制台日志 $CONSOLE"

# ---------- 清洗 ----------
# ★ 剥掉 systemd 打在控制台上的 ANSI 高亮序列。
#   systemd v255+ 的状态行格式是 "[  OK  ] Started <单元名> - <描述>."，
#   而 <单元名> 两侧套着 ANSI_HIGHLIGHT / ANSI_NORMAL（src/core/unit.c 的
#   unit_status_printf()）⇒ 原始字节其实是
#       Started \e[0;1;39mssh.service\e[0m - OpenBSD Secure Shell server.
#   直接 grep "Started ssh.service" 匹配不到 ⇒ 断言前先清洗。
#   （描述部分还会被 systemd 按终端宽度截断并插省略号 "…"，所以断言一律
#     用单元名，不用描述。）
OUT_RAW="$(cat "$CONSOLE" 2>/dev/null || true)"
OUT="$(printf '%s' "$OUT_RAW" | python3 -c '
import re, sys
data = sys.stdin.read()
# 真的 ESC 序列，以及某些日志采集器把它转义成字面 "^[…" 的形态
data = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", data)
data = re.sub(r"\^\[\[[0-9;]*[A-Za-z]", "", data)
sys.stdout.write(data)
' 2>/dev/null || printf '%s' "$OUT_RAW")"

# ---------- 拿 journal（要放在断言前面：失败时要一起摊开）----------
if [ -n "$JOURNAL_TEXT_FILE" ] && [ -f "$JOURNAL_TEXT_FILE" ]; then
    JOURNAL_TEXT="$(cat "$JOURNAL_TEXT_FILE" 2>/dev/null || true)"
fi

# ---------- 失败时的取证 ----------
# ★ 为什么不能只 tail 控制台尾部：
#   控制台尾部是关机序列，看不到开机段；而"单元没跑完"的原因恰恰在开机段。
#   所以这里把整条单元事件流（谁 Starting 了、谁 Finished 了、谁 Failed 了、
#   有没有排序环）整段打出来，再附控制台尾部和 journal 尾部。
dump_diag() {
    echo "BOOT-SMOKE-ASSERT: —— 单元事件流（控制台）——" >&2
    printf '%s' "$OUT" \
        | grep -E 'Starting |Started |Finished |Failed |Skipped|Reached target|ordering cycle|Dependency ' \
        | tail -80 >&2 || true
    echo "BOOT-SMOKE-ASSERT: —— 控制台尾部 60 行 ——" >&2
    tail -60 "$CONSOLE" >&2 || true
    if [ -n "$JOURNAL_TEXT" ]; then
        echo "BOOT-SMOKE-ASSERT: —— journal 尾部 40 行 ——" >&2
        printf '%s' "$JOURNAL_TEXT" | tail -40 >&2 || true
    fi
}
fail() {
    echo "BOOT-SMOKE-ASSERT: 断言不过：$*" >&2
    dump_diag
    exit 1
}

# ---------- 断言 ----------
MILESTONE_RE='Reached target .*multi-user\.target'

assert_console() {
    grep -qF -- "$1" <<<"$OUT" || fail "$2"
}
assert_console_re() {
    grep -qE -- "$1" <<<"$OUT" || fail "$2"
}

# ---------- 先查"起失败"，再查"没跑完" ----------
# ★ 顺序是刻意的。
#   上一轮 CI 红在"qm1-firstboot.service 没跑完"，但真正的原因被藏住了：
#   失败清单排在正例后面，所以"这个单元起失败了"和"这个单元没跑完"两种
#   情况报出来的是同一句话，只能靠猜。现在失败在前、正例在后，
#   一旦它真的起失败，报出来的就是"起失败"，附带单元事件流。
for unit in ssh.service systemd-resolved.service systemd-networkd.service \
            qm1-firstboot.service qm1-hardware-fixups.service; do
    if grep -qF "Failed to start $unit" <<<"$OUT"; then
        fail "$unit 起失败了"
    fi
    # 超时被杀也算起失败（systemd 打的是 "Failed with result 'timeout'"）
    if grep -qF "$unit: Failed with result" <<<"$OUT"; then
        fail "$unit 起失败了（超时或被杀掉）"
    fi
done

# 出货的 Wi-Fi 驱动单元：只要它出现在日志里，就不允许起失败。
# QEMU 里没有 SDIO 卡，但模块本身照样能加载成功（modprobe 只做符号解析和
# 注册驱动，没有设备是正常的）⇒ 这条在 QEMU 里也成立，而且正好能挡住
# 「模块索引没刷新 ⇒ modprobe 报 not found ⇒ 驱动永远加载不上」这类问题。
if grep -qF "qm1-rtw88-8723bs.service" <<<"$OUT"; then
    if grep -qF "Failed to start qm1-rtw88-8723bs.service" <<<"$OUT"; then
        fail "Wi-Fi 驱动单元 qm1-rtw88-8723bs.service 起失败（最常见原因：镜像的 modules.dep 里没有这个模块，modprobe 找不到它）"
    fi
fi

assert_console_re "$MILESTONE_RE" "客户机没走到 multi-user.target"
assert_console "Started ssh.service" "sshd 没起来（登录不进去）"
assert_console "Started systemd-resolved.service" "systemd-resolved 没起来（DNS 没有数据源）"

# ★ 首启那一步到底跑没跑。
#   判据是"行为"，不是"呈现"：控制台上 systemd 的 Finished 行**或者**
#   journal 里脚本自己的输出，任一有就算它跑过。
#   为什么放宽：控制台是串口，systemd 打的状态行可能被截断或丢失；
#   而脚本自己的输出（journal 里的 [qm1-firstboot]）是它确实执行的直接证据。
#   两份证据都没有 ⇒ 它确实没跑（被条件跳过、或压根没被拉起）。
if ! grep -qF "Finished qm1-firstboot.service" <<<"$OUT" \
   && ! grep -q "\[qm1-firstboot\]" <<<"$JOURNAL_TEXT"; then
    fail "qm1-firstboot.service 没跑（开机即用的配置那一步）：控制台没有它的 Finished 行，journal 里也没有它的输出"
fi
if ! grep -qF "Finished qm1-firstboot.service" <<<"$OUT"; then
    echo "BOOT-SMOKE-ASSERT: 注意：控制台没有 qm1-firstboot.service 的 Finished 行（journal 里有它的输出，判为已执行）" >&2
fi

# ★ Wi-Fi 单元必须"起来"（而不是卡在 activating）。
#   这条是本轮修的那个真机级缺陷的回归闸：
#   早先 qm1-wifi@.service 用 ExecStartPre 等 SDIO 枚举出 wlan0，
#   QEMU 里没有 SDIO 卡 ⇒ 这个 start job 永远不完成 ⇒ 因为 multi-user.target
#   对 Wants= 成员隐式补 After=，整机永远到不了 multi-user.target，
#   表现为"装完开机像砖了、没有 SSH"。真机上 SDIO 枚举慢或驱动没起来时
#   是同一个坑。
#   现在等待搬进了 qm1-wifi-start 进程内部，Type=simple 的 start job
#   在 fork 之后立刻完成 ⇒ 即使 wlan0 永远不出现，单元也会显示 Started，
#   multi-user.target 照常达成。
assert_console "Started qm1-wifi@wlan0.service" \
    "Wi-Fi 单元没起来（qm1-wifi@wlan0.service 没有达到 Started）"

# journal 断言（可选）：只在拿到 journal 文本时才查。
if [ -n "$JOURNAL_TEXT" ]; then
    assert_journal() {
        grep -q -- "$1" <<<"$JOURNAL_TEXT" || fail "（journal）$2"
    }
    assert_journal "Startup finished" "journal 里没有 systemd 的启动收尾记录（journal 可能是坏的）"
    assert_journal "\[qm1-firstboot\]" "journal 里没有 qm1-firstboot 的输出（开机即用的配置那一步没跑）"
    # 自检脚本的输出格式（QM1 硬件自检 … PASS=n WARN=n FAIL=n）——
    # 自检本身是手工工具（不进开机流程），所以这里只确认它可执行、格式没坏。
    if grep -q "qm1-selftest.service" <<<"$JOURNAL_TEXT"; then
        echo "BOOT-SMOKE-ASSERT: 客户机自检（qm1-selftest）的输出摘录："
        printf '%s' "$JOURNAL_TEXT" \
            | grep -A2 "qm1-selftest.service" \
            | tail -12 | sed 's/^/    /' >&2 || true
    fi
fi

echo "BOOT-SMOKE-ASSERT: 断言全过"
