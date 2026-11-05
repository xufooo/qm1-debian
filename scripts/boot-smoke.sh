#!/usr/bin/env bash
# boot-smoke.sh — 在 QEMU 里把出厂镜像真启动一次
#
# 为什么需要这个：
#   到目前为止，整条出货链路的验证全是"静态检查"——文件在不在、软链指向哪、
#   参数写对没有。CI 全绿不代表刷上去能开机：这个仓库出过一次"镜像能构建、
#   CI 全绿，但刷上去装不了、起不来、登不进、上不了网"（25 条审计问题）。
#   这个脚本让镜像**真的启动一次**，并在里面跑一组断言。
#
# 它不能替代真机验收（QEMU 里没有 RTL8723BS、没有 8250、没有真实 eMMC），
# 但它能把"内核起不来 / initrd 找不到根 / systemd 起不来 / 账号没建 / DNS
# 链没挂上"这一整类问题挡在刷机之前。
#
# 用法：
#   bash scripts/boot-smoke.sh --rootfs build/out/rootfs.img [--timeout 300]
#
# 退出码：
#   0  启动成功且断言全过
#   1  启动失败或断言不过（控制台日志留在 build/out/boot-smoke.log）
#   77 缺依赖（qemu / debugfs / python3），跳过
set -euo pipefail

ROOTFS=""
TIMEOUT=300
LOG="build/out/boot-smoke.log"
WORK="build/out/boot-smoke"

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

# ---------- 2. 起 QEMU，串口接到 unix socket ----------
# console=ttyS0 + systemd.debug_shell：systemd 启动完会把控制台交给调试 shell，
# 我们就能在客户机里真的执行命令（而不是只看它打印了什么）。
SOCK="$WORK/serial.sock"
rm -f "$SOCK"

QEMU_CMD=(qemu-system-x86_64
    -machine q35 -m 1024 -smp 2
    -display none -no-reboot
    -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd"
    -append "root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200n8 systemd.debug_shell=1"
    -drive "file=$ROOTFS,format=raw,if=virtio,cache=unsafe"
    -serial "unix:$SOCK,server=on,wait=on"
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

# ---------- 3. 通过串口进调试 shell，跑一组断言 ----------
# 客户端用 python 写：连接 unix socket、收集输出、等 "Booting in debug shell."、
# 发命令、等结束标记、然后 poweroff。
set +e
python3 - "$SOCK" "$LOG" "$TIMEOUT" <<'PY'
import socket, sys, time

sock_path, log_path, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
deadline = time.time() + timeout
log = open(log_path, "a", buffering=1, encoding="utf-8", errors="replace")

buf = []
s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock_path)
        break
    except OSError:
        if s:
            s.close()
            s = None
        time.sleep(0.5)
if s is None:
    print("BOOT-SMOKE: 连不上串口 socket", file=sys.stderr)
    sys.exit(2)

def pump(until, deadline_ts):
    """读到 until 出现为止；返回是否等到。"""
    while time.time() < deadline_ts:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        except OSError:
            return False
        if not chunk:
            return False
        text = chunk.decode("utf-8", "replace")
        buf.append(text)
        log.write(text)
        if until in "".join(buf[-40:]):
            return True
    return False

def send(line):
    s.sendall((line + "\n").encode())

if not pump("Booting in debug shell.", deadline):
    print("BOOT-SMOKE: 客户机没有进到调试 shell", file=sys.stderr)
    s.close()
    sys.exit(3)

mark = "QM1SMOKE-READY"
send(f"echo {mark}")
if not pump(mark, deadline):
    print("BOOT-SMOKE: 调试 shell 没回话", file=sys.stderr)
    s.close()
    sys.exit(4)

script = r"""
echo QM1SMOKE-BEGIN
echo "SYSTEM_STATE=$(systemctl is-system-running 2>&1)"
echo "USER_QM1=$(id -u qm1 2>&1)"
echo "RESOLV=$(readlink /etc/resolv.conf 2>&1)"
echo "WIFI_UNIT=$(systemctl is-enabled qm1-wifi@wlan0.service 2>&1)"
echo "KVER=$(ls /lib/modules 2>&1 | tr '\n' ' ')"
echo "BUILD=$(grep -h '^kernel=' /etc/qm1-build-info 2>&1)"
echo "LOAD=$(cat /proc/loadavg 2>&1)"
echo QM1SMOKE-END
"""
# 一行一行发：调试 shell 是真交互 shell，整块粘贴可能被它的行编辑拆乱。
for line in script.strip().splitlines():
    send(line)
    time.sleep(0.05)
if not pump("QM1SMOKE-END", deadline):
    print("BOOT-SMOKE: 断言脚本没跑完", file=sys.stderr)
    s.close()
    sys.exit(5)

out = "".join(buf)
s.sendall(b"poweroff -f\n")
time.sleep(1)
s.close()
sys.exit(0 if "QM1SMOKE-END" in out else 6)
PY
RC=$?
set -e

# 让 QEMU 自己收尾
for _ in $(seq 1 20); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.5
done
cleanup
trap - EXIT

if [ "$RC" -ne 0 ]; then
    echo "BOOT-SMOKE: 失败（rc=$RC），控制台日志尾部：" >&2
    tail -60 "$LOG" >&2 || true
    exit 1
fi

# ---------- 4. 断言 ----------
OUT="$(cat "$LOG")"
assert_contains() {
    printf '%s' "$OUT" | grep -q -- "$1" \
        || { echo "BOOT-SMOKE: 断言不过：$2" >&2; tail -60 "$LOG" >&2; exit 1; }
}
assert_contains "QM1SMOKE-END" "客户机没跑完断言脚本"
printf '%s' "$OUT" | grep -qE "SYSTEM_STATE=(running|degraded)" \
    || { echo "BOOT-SMOKE: 断言不过：systemd 没到 running/degraded 状态" >&2; tail -60 "$LOG" >&2; exit 1; }
assert_contains "USER_QM1=1000" "镜像里没有 qm1 账号（uid 1000）"
assert_contains "RESOLV=/usr/lib/systemd/resolv.conf" "/etc/resolv.conf 没指向 resolved 的 stub"
assert_contains "WIFI_UNIT=enabled" "qm1-wifi@wlan0.service 没有开机自启"
assert_contains "6.12.113" "客户机里的内核模块目录不对"
assert_contains "QM1SMOKE" "断言标记缺失"

log "启动成功，断言全过（日志：$LOG）"
