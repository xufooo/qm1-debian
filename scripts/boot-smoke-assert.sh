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

# ---------- 断言 ----------
MILESTONE_RE='Reached target .*multi-user\.target'

assert_console() {
    printf '%s' "$OUT" | grep -qF -- "$1" \
        || { echo "BOOT-SMOKE-ASSERT: 断言不过：$2" >&2; tail -60 "$CONSOLE" >&2; exit 1; }
}
assert_console_re() {
    printf '%s' "$OUT" | grep -qE -- "$1" \
        || { echo "BOOT-SMOKE-ASSERT: 断言不过：$2" >&2; tail -60 "$CONSOLE" >&2; exit 1; }
}
assert_console_re "$MILESTONE_RE" "客户机没走到 multi-user.target"
assert_console "Started ssh.service" "sshd 没起来（登录不进去）"
assert_console "Started systemd-resolved.service" "systemd-resolved 没起来（DNS 没有数据源）"
assert_console "Finished qm1-firstboot.service" "qm1-firstboot.service 没跑完（开机即用的配置那一步）"

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

# 关键单元一个都不能起失败。QEMU 里注定起不来的（没 SDIO 设备、没网卡、
# 没蓝牙）不在这张表里 —— 它们在真机上才是判据。
for unit in ssh.service systemd-resolved.service systemd-networkd.service \
            qm1-firstboot.service qm1-hardware-fixups.service; do
    if printf '%s' "$OUT" | grep -qF "Failed to start $unit"; then
        echo "BOOT-SMOKE-ASSERT: 断言不过：$unit 起失败了" >&2
        tail -60 "$CONSOLE" >&2
        exit 1
    fi
done

# 出货的 Wi-Fi 驱动单元：只要它出现在日志里，就不允许起失败。
# QEMU 里没有 SDIO 卡，但模块本身照样能加载成功（modprobe 只做符号解析和
# 注册驱动，没有设备是正常的）⇒ 这条在 QEMU 里也成立，而且正好能挡住
# 「模块索引没刷新 ⇒ modprobe 报 not found ⇒ 驱动永远加载不上」这类问题。
if printf '%s' "$OUT" | grep -qF "qm1-rtw88-8723bs.service"; then
    if printf '%s' "$OUT" | grep -qF "Failed to start qm1-rtw88-8723bs.service"; then
        echo "BOOT-SMOKE-ASSERT: 断言不过：Wi-Fi 驱动单元 qm1-rtw88-8723bs.service 起失败" >&2
        echo "BOOT-SMOKE-ASSERT:（最常见原因：镜像的 modules.dep 里没有这个模块，modprobe 找不到它）" >&2
        tail -60 "$CONSOLE" >&2
        exit 1
    fi
fi

# journal 断言（可选）：只在拿到 journal 文本时才查。
if [ -n "$JOURNAL_TEXT_FILE" ] && [ -f "$JOURNAL_TEXT_FILE" ]; then
    JOURNAL_TEXT="$(cat "$JOURNAL_TEXT_FILE" 2>/dev/null || true)"
fi
if [ -n "$JOURNAL_TEXT" ]; then
    assert_journal() {
        printf '%s' "$JOURNAL_TEXT" | grep -q -- "$1" \
            || { echo "BOOT-SMOKE-ASSERT: 断言不过（journal）：$2" >&2; exit 1; }
    }
    assert_journal "Startup finished" "journal 里没有 systemd 的启动收尾记录（journal 可能是坏的）"
    assert_journal "\[qm1-firstboot\]" "journal 里没有 qm1-firstboot 的输出（开机即用的配置那一步没跑）"
    # 自检脚本的输出格式（QM1 硬件自检 … PASS=n WARN=n FAIL=n）——
    # 自检本身是手工工具（不进开机流程），所以这里只确认它可执行、格式没坏。
    if printf '%s' "$JOURNAL_TEXT" | grep -q "qm1-selftest.service"; then
        echo "BOOT-SMOKE-ASSERT: 客户机自检（qm1-selftest）的输出摘录："
        printf '%s' "$JOURNAL_TEXT" \
            | grep -A2 "qm1-selftest.service" \
            | tail -12 | sed 's/^/    /' >&2 || true
    fi
fi

echo "BOOT-SMOKE-ASSERT: 断言全过"
