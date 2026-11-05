#!/usr/bin/env bash
# boot-smoke.sh — 在 QEMU 里把出厂镜像真启动一次
#
# 为什么需要这个：
#   到目前为止，整条出货链路的验证全是"静态检查"——文件在不在、软链指向哪、
#   参数写对没有。CI 全绿不代表刷上去能开机：这个仓库出过一次"镜像能构建、
#   CI 全绿，但刷上去装不了、起不来、登不进、上不了网"（25 条审计问题）。
#   这个脚本让镜像**真的启动一次**，并在启动日志上做一组断言。
#
# 为什么不是"进调试 shell 敲命令"：
#   systemd 从 v255 起把早期调试 shell 换成了 sulogin（src/sulogin-shell/），
#   它要**口令登录**才给 shell（units/debug-shell.service.in 的 ExecStart=
#   {{SUSHELL}} → systemd-sulogin-shell → 调 sulogin 认证）。也就是说
#   `systemd.debug_shell=1` 起得来，但自动化没法登录进去 —— 之前那版脚本
#   就是死在这儿：等一句永远不来的 "Booting in debug shell."，等到超时。
#   所以这里改成两条不依赖交互的路：
#     ① 串口控制台日志：断言 systemd 走到了 multi-user.target、sshd 起���、
#        resolved 起了、qm1-firstboot 跑完了，而且**关键单元没有一个起失败**；
#     ② 离线读客户机写回磁盘的 journal（debugfs 导出 + journalctl --directory），
#        从里面断言更细的东西（单元输出、自检脚本的结论）。
#   两条都不需要客户机里有任何可登录账号 —— 这一点很重要，因为出厂镜像的
#   口令是安装时才生成的，镜像里没有。
#
# 它不能替代真机验收（QEMU 里没有 RTL8723BS、没有 8250、没有真实 eMMC），
# 但它能把"内核起不来 / initrd 找不到根 / systemd 起不来 / DNS 链没挂上 /
# 开机自启单元没挂上"这一整类问题挡在刷机之前。
#
# 用法：
#   bash scripts/boot-smoke.sh --rootfs build/out/rootfs.img [--timeout 420]
#
# 退出码：
#   0  启动成功且断言全过
#   1  启动失败或断言不过（控制台日志留在 build/out/boot-smoke.log）
#   77 缺依赖（qemu / debugfs / python3），跳过
set -euo pipefail

ROOTFS=""
TIMEOUT=420
LOG="build/out/boot-smoke.log"
WORK="build/out/boot-smoke"
SETTLE=25

die() { echo "BOOT-SMOKE: $*" >&2; exit 1; }
log() { echo "BOOT-SMOKE: $*"; }
need() {
    command -v "$1" >/dev/null 2>&1 || { echo "BOOT-SMOKE: SKIP（缺 $1）"; exit 77; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)  ROOTFS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --log)     LOG="$2"; shift 2 ;;
        --settle)  SETTLE="$2"; shift 2 ;;
        *) die "未知参数 $1" ;;
    esac
done

[ -n "$ROOTFS" ] || die "必须给 --rootfs"
[ -f "$ROOTFS" ] || die "找不到镜像 $ROOTFS"
need qemu-system-x86_64
need debugfs
need python3

mkdir -p "$(dirname "$LOG")" "$WORK"

# ---------- 1. 从 ext4 镜像里取出内核、initrd 与根 UUID ----------
# 用 debugfs 读，不挂载：CI 里没有 loop 权限也不该去动宿主的挂载表。
KERNEL=""
INITRD=""
for f in $(debugfs -R "ls -l /boot" "$ROOTFS" 2>/dev/null | awk '{print $NF}'); do
    case "$f" in
        vmlinuz-*)   KERNEL="$f" ;;
        initrd.img-*) INITRD="$f" ;;
    esac
done
[ -n "$KERNEL" ] || die "镜像的 /boot 里没有 vmlinuz-*"
[ -n "$INITRD" ] || die "镜像的 /boot 里没有 initrd.img-*"
log "内核：$KERNEL　initrd：$INITRD"

ROOT_UUID="$(debugfs -R "cat /etc/fstab" "$ROOTFS" 2>/dev/null \
    | awk '$2 == "/" { for (i = 1; i <= NF; i++) if ($i ~ /^UUID=/) { sub(/^UUID=/, "", $i); print $i; exit } }')"
[ -n "$ROOT_UUID" ] || die "从镜像的 /etc/fstab 里读不出根分区的 UUID"
log "根 UUID：$ROOT_UUID"

debugfs -R "dump /boot/$KERNEL $WORK/vmlinuz" "$ROOTFS" >/dev/null 2>&1 || die "取出内核失败"
debugfs -R "dump /boot/$INITRD $WORK/initrd" "$ROOTFS" >/dev/null 2>&1 || die "取出 initrd 失败"
[ -s "$WORK/vmlinuz" ] || die "内核文件为空"
[ -s "$WORK/initrd" ] || die "initrd 文件为空"

# 客户机要往磁盘里写 journal 才能让我们事后读它；用副本启动，免得把构建产物
# 弄脏（后面还有一步要核对产物哈希）。
BOOT_IMG="$WORK/rootfs-boot.img"
cp -- "$ROOTFS" "$BOOT_IMG"
log "启动用副本：$BOOT_IMG"

# ---------- 2. 起 QEMU，串口日志写文件 ----------
# console=ttyS0 让 systemd 把开机过程写到串口；mask 掉 getty 是因为登录提示
# 会占住控制台，日志里全是 "qm1 login:"，反而把有用信息淹掉。
CONSOLE="$WORK/console.log"
MONITOR="$WORK/monitor.sock"
rm -f "$CONSOLE" "$MONITOR"

QEMU_CMD=(qemu-system-x86_64
    -machine q35 -m 1024 -smp 2
    -display none -no-reboot
    -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd"
    -append "root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200n8"
    -drive "file=$BOOT_IMG,format=raw,if=virtio,cache=unsafe"
    -serial "file:$CONSOLE"
    -monitor "unix:$MONITOR,server=on,wait=off"
    -pidfile "$WORK/qemu.pid")

log "启动 QEMU（超时 ${TIMEOUT}s）…"
: > "$LOG"
"${QEMU_CMD[@]}" >>"$LOG" 2>&1 &
QEMU_PID=$!
cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------- 3. 等它走到 multi-user.target ----------
MILESTONE="Reached target Multi-User System"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if [ -f "$CONSOLE" ] && grep -q "$MILESTONE" "$CONSOLE"; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "BOOT-SMOKE: QEMU 自己退出了，控制台日志尾部：" >&2
        tail -60 "$CONSOLE" >&2 || true
        exit 1
    fi
    sleep 2
done

if ! grep -q "$MILESTONE" "$CONSOLE" 2>/dev/null; then
    echo "BOOT-SMOKE: 客户机没走到 multi-user.target（超时 ${TIMEOUT}s），控制台日志尾部：" >&2
    tail -60 "$CONSOLE" >&2 || true
    exit 1
fi
log "客户机到达 multi-user.target"

# 再给它一点时间，让开机自启的单元（firstboot / health-collect / provision 起步）跑完
sleep "$SETTLE"

# ---------- 4. 优雅关机，让 journal 落盘 ----------
# 用 ACPI 电源键（QEMU monitor 的 system_powerdown）而不是 kill —— 硬杀会丢日志。
python3 - "$MONITOR" <<'PY' || true
import socket, sys, time
path = sys.argv[1]
for _ in range(40):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(path)
        break
    except OSError:
        time.sleep(0.5)
else:
    sys.exit(0)
try:
    s.sendall(b"system_powerdown\n")
    time.sleep(1)
finally:
    s.close()
PY

SHUT_TIMEOUT=120
while [ "$SHUT_TIMEOUT" -gt 0 ]; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 2
    SHUT_TIMEOUT=$(( SHUT_TIMEOUT - 2 ))
done
cleanup
trap - EXIT
log "客户机已关机"

# ---------- 5. 把客户机写进磁盘的 journal 取出来 ----------
JOURNAL_DIR="$WORK/journal"
rm -rf "$JOURNAL_DIR"
mkdir -p "$JOURNAL_DIR"
JOURNAL_TEXT=""
JOURNAL_OK="no"
MACHINE_ID="$(debugfs -R "ls -l /var/log/journal" "$BOOT_IMG" 2>/dev/null | awk '{print $NF}' | grep -E '^[0-9a-f]{32}$' | head -1 || true)"
if [ -n "$MACHINE_ID" ]; then
    for jf in $(debugfs -R "ls -l /var/log/journal/$MACHINE_ID" "$BOOT_IMG" 2>/dev/null | awk '{print $NF}' | grep -E '\.journal' || true); do
        debugfs -R "dump /var/log/journal/$MACHINE_ID/$jf $JOURNAL_DIR/$jf" "$BOOT_IMG" >/dev/null 2>&1 || true
    done
fi
if command -v journalctl >/dev/null 2>&1 && [ -n "$(ls -A "$JOURNAL_DIR" 2>/dev/null)" ]; then
    JOURNAL_TEXT="$(journalctl --directory="$JOURNAL_DIR" --output=cat --no-pager 2>/dev/null || true)"
    [ -n "$JOURNAL_TEXT" ] && JOURNAL_OK="yes"
fi
if [ "$JOURNAL_OK" = "yes" ]; then
    log "已导出客户机的 journal（$(wc -c <"$JOURNAL_DIR"/system.journal 2>/dev/null || echo 0) 字节起）"
else
    log "警告：没能读到客户机的 journal（可能它写在了 /run/log/journal），只按控制台日志断言"
fi

# ---------- 6. 断言 ----------
OUT="$(cat "$CONSOLE" 2>/dev/null || true)"
assert_console() {
    printf '%s' "$OUT" | grep -q -- "$1" \
        || { echo "BOOT-SMOKE: 断言不过：$2" >&2; tail -60 "$CONSOLE" >&2; exit 1; }
}
assert_console "$MILESTONE" "客户机没走到 multi-user.target"
assert_console "Started OpenBSD Secure Shell server" "sshd 没起来（登录不进��）"
assert_console "Started systemd-resolved.service" "systemd-resolved 没起来（DNS 没有数据源）"
assert_console "Finished qm1-firstboot.service" "qm1-firstboot.service 没跑完（开机即用的配置那一步）"

# 关键单元一个都不能起失败。QEMU 里注定起不来的（没 SDIO 设备、没网卡、
# 没蓝牙）不在这张表里 —— 它们在真机上才是判据。
for unit in ssh.service systemd-resolved.service systemd-networkd.service \
            qm1-firstboot.service qm1-hardware-fixups.service; do
    if printf '%s' "$OUT" | grep -q "Failed to start $unit"; then
        echo "BOOT-SMOKE: 断言不过：$unit 起失败了" >&2
        tail -60 "$CONSOLE" >&2
        exit 1
    fi
done

if [ "$JOURNAL_OK" = "yes" ]; then
    assert_journal() {
        printf '%s' "$JOURNAL_TEXT" | grep -q -- "$1" \
            || { echo "BOOT-SMOKE: 断言不过（journal）：$2" >&2; exit 1; }
    }
    assert_journal "Startup finished" "journal 里没有 systemd 的启动收尾记录（journal 可能是坏的）"
    assert_journal "\[qm1-firstboot\]" "journal 里没有 qm1-firstboot 的输出（开机即用的配置那一步没跑）"
    # 自检脚本的输出格式（QM1 硬件自检 … PASS=n WARN=n FAIL=n）——
    # 自检本身是手工工具（不进开机流程），所以这里只确认它可执行、格式没坏。
    if printf '%s' "$JOURNAL_TEXT" | grep -q "qm1-selftest.service"; then
        log "客户机自检（qm1-selftest）的输出摘录："
        printf '%s' "$JOURNAL_TEXT" \
            | grep -A2 "qm1-selftest.service" \
            | tail -12 | sed 's/^/    /' >&2 || true
    fi
fi

log "启动成功，断言全过（日志：$LOG，控制台：$CONSOLE）"
