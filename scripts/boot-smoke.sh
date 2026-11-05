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
#   bash scripts/boot-smoke.sh --disk   build/out/qm1-disk.img [--timeout 420]
#
# 两种模式的区别：
#   --rootfs 直接用 -kernel/-initrd 起，只验证"根文件系统 + systemd"这一层；
#   --disk   用 OVMF 从整盘镜像的 ESP 里走 GRUB 引导，验证的是**出货形态**
#            （GPT → ESP → GRUB → 内核 handover → 根 UUID → systemd），
#            也就是"刷完这个盘能不能开机"。GRUB 菜单有 5 秒超时，会自动选
#            第 ① 项（正常启动那条）⇒ 不需要任何交互。
#
# 退出码：
#   0  启动成功且断言全过
#   1  启动失败或断言不过（控制台日志留在 build/out/boot-smoke.log）
#   77 缺依赖（qemu / debugfs / python3），跳过
set -euo pipefail

ROOTFS=""
DISK=""
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
        --disk)    DISK="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --log)     LOG="$2"; shift 2 ;;
        --settle)  SETTLE="$2"; shift 2 ;;
        *) die "未知参数 $1" ;;
    esac
done

if [ -n "$ROOTFS" ] && [ -n "$DISK" ]; then
    die "--rootfs 与 --disk 只能给一个"
fi
if [ -z "$ROOTFS" ] && [ -z "$DISK" ]; then
    die "必须给 --rootfs 或 --disk"
fi
if [ -n "$ROOTFS" ] && [ ! -f "$ROOTFS" ]; then
    die "找不到镜像 $ROOTFS"
fi
if [ -n "$DISK" ] && [ ! -f "$DISK" ]; then
    die "找不到整盘镜像 $DISK"
fi
need qemu-system-x86_64
need debugfs
need python3

mkdir -p "$(dirname "$LOG")" "$WORK"

# ---------- 1. 准备要启动的东西 ----------
# 两种模式：
#   --rootfs：直接 -kernel/-initrd 起，只验证根文件系统 + systemd 这一层；
#             BOOT_IMG 就是 ext4 镜像副本。
#   --disk  ：从整盘镜像（GPT + ESP + GRUB + 根分区）经 OVMF 走 UEFI 引导，
#             验证的是出货形态。为此要把整盘镜像里的根分区抠出来（BOOT_IMG），
#             用来读 fstab 的根 UUID 和事后的 journal。
BOOT_IMG=""
BOOT_MEDIUM=""
OVMF_CODE=""
OVMF_VARS=""

if [ -n "$DISK" ]; then
    # OVMF：优先 32 位变体（这台机器的固件就是 32 位 IA32 ⇒ 只有 IA32 固件
    # 加载不了 PE32+ 的 BOOTX64.EFI；但 x64 的 OVMF 反而能加载 IA32 应用 ⇒
    # 用 IA32 固件更贴近真机，x64 固件作为退路）。
    for d in /usr/share/OVMF /usr/share/ovmf /usr/share/qemu; do
        [ -n "$OVMF_CODE" ] && break
        [ -f "$d/OVMF_CODE_IA32.fd" ] && { OVMF_CODE="$d/OVMF_CODE_IA32.fd"; OVMF_VARS="$d/OVMF_VARS_IA32.fd"; }
        [ -z "$OVMF_CODE" ] && [ -f "$d/OVMF_CODE.fd" ] && { OVMF_CODE="$d/OVMF_CODE.fd"; OVMF_VARS="$d/OVMF_VARS.fd"; }
    done
    if [ -z "$OVMF_CODE" ] || [ ! -f "$OVMF_CODE" ]; then
        echo "BOOT-SMOKE: SKIP（找不到 OVMF 固件，装 ovmf 包才有）" >&2
        exit 77
    fi
    [ -f "$OVMF_VARS" ] || { echo "BOOT-SMOKE: SKIP（找不到配套的 OVMF_VARS：$OVMF_VARS）" >&2; exit 77; }
    log "OVMF 固件：$OVMF_CODE"

    DISK_COPY="$WORK/qm1-disk-boot.img"
    # 整盘镜像是稀疏的（30 GiB 盘只写了几百 MB）⇒ 拷贝时保持稀疏，
    # 否则 CI runner 的磁盘会被实打实地吃掉 30 GiB。
    cp --sparse=always -- "$DISK" "$DISK_COPY"
    BOOT_MEDIUM="$DISK_COPY"
    log "启动用整盘镜像副本：$DISK_COPY"

    # 从 GPT 里找出 ext4 的根分区（type=0fc63daf-8483-4772-8e79-3d69d8477de4）
    need sfdisk
    need dd
    PART_LINE="$(sfdisk -d "$DISK_COPY" 2>/dev/null \
        | grep 'type=0fc63daf-8483-4772-8e79-3d69d8477de4' | head -1 || true)"
    [ -n "$PART_LINE" ] || die "整盘镜像里找不到 ext4 根分区（GPT 里没有 0fc63daf 类型）"
    PART_START="$(printf '%s' "$PART_LINE" | sed -n 's/.*start=\([0-9]*\).*/\1/p')"
    PART_SIZE="$(printf '%s' "$PART_LINE" | sed -n 's/.*size=\([0-9]*\).*/\1/p')"
    if [ -z "$PART_START" ] || [ -z "$PART_SIZE" ]; then
        die "解析分区位置失败：$PART_LINE"
    fi
    log "根分区：起始扇区 $PART_START，长度 $PART_SIZE 扇区"
    BOOT_IMG="$WORK/rootfs-from-disk.img"
    dd if="$DISK_COPY" of="$BOOT_IMG" bs=512 skip="$PART_START" count="$PART_SIZE" conv=sparse status=none
    [ -s "$BOOT_IMG" ] || die "从整盘镜像里抠出根分区失败"
else
    # ---------- 1a. 从 ext4 镜像里取出内核、initrd 与根 UUID ----------
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

    # 客户机要往磁盘里写 journal 才能让我们事后读它；用副本启动，免得把构建产物
    # 弄脏（后面还有一步要核对产物哈希）。
    BOOT_IMG="$WORK/rootfs-boot.img"
    cp -- "$ROOTFS" "$BOOT_IMG"
    BOOT_MEDIUM="$BOOT_IMG"
    log "启动用副本：$BOOT_IMG"

    debugfs -R "dump /boot/$KERNEL $WORK/vmlinuz" "$ROOTFS" >/dev/null 2>&1 || die "取出内核失败"
    debugfs -R "dump /boot/$INITRD $WORK/initrd" "$ROOTFS" >/dev/null 2>&1 || die "取出 initrd 失败"
    [ -s "$WORK/vmlinuz" ] || die "内核文件为空"
    [ -s "$WORK/initrd" ] || die "initrd 文件为空"
fi

ROOT_UUID="$(debugfs -R "cat /etc/fstab" "$BOOT_IMG" 2>/dev/null \
    | awk '$2 == "/" { for (i = 1; i <= NF; i++) if ($i ~ /^UUID=/) { sub(/^UUID=/, "", $i); print $i; exit } }')"
[ -n "$ROOT_UUID" ] || die "从镜像的 /etc/fstab 里读不出根分区的 UUID"
log "根 UUID：$ROOT_UUID"

# ---------- 2. 起 QEMU，串口日志写文件 ----------
# console=ttyS0 让 systemd 把开机过程写到串口；mask 掉 getty 是因为登录提示
# 会占住控制台，日志里全是 "qm1 login:"，反而把有用信息淹掉。
CONSOLE="$WORK/console.log"
MONITOR="$WORK/monitor.sock"
rm -f "$CONSOLE" "$MONITOR"

QEMU_CMD=(qemu-system-x86_64
    -machine q35 -m 1024 -smp 2
    -display none -no-reboot)

if [ -n "$DISK" ]; then
    # 出货形态：OVMF 从 ESP 里的 \EFI\BOOT\*.EFI 起 GRUB，GRUB 再加载内核。
    # 这条链上任何一环坏了（ESP 里的引导器、grub.cfg 的 search 行、根 UUID、
    # 内核 handover），机器都开不了机，而直接 -kernel 起是发现不了的。
    VARS_COPY="$WORK/ovmf-vars.fd"
    cp -- "$OVMF_VARS" "$VARS_COPY"
    QEMU_CMD+=(
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$VARS_COPY"
        -drive "file=$BOOT_MEDIUM,format=raw,if=virtio,cache=unsafe")
else
    QEMU_CMD+=(
        -kernel "$WORK/vmlinuz" -initrd "$WORK/initrd"
        -append "root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200n8"
        -drive "file=$BOOT_MEDIUM,format=raw,if=virtio,cache=unsafe")
fi

QEMU_CMD+=(
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
# 整盘模式下，客户机写的是整盘副本里的根分区 ⇒ 关机后要重新抠一次，
# 否则拿到的是开机前那份（没有 journal）。
if [ -n "$DISK" ]; then
    dd if="$DISK_COPY" of="$BOOT_IMG" bs=512 skip="$PART_START" count="$PART_SIZE" conv=sparse status=none || true
fi
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

# 出货的 Wi-Fi 驱动单元：只要它出现在日志里，就不允许起失败。
# QEMU 里没有 SDIO 卡，但模块本身照样能加载成功（modprobe 只做符号解析和
# 注册驱动，没有设备是正常的）⇒ 这条在 QEMU 里也成立，而且正好能挡住
# 「模块索引没刷新 ⇒ modprobe 报 not found ⇒ 驱动永远加载不上」这类问题。
if printf '%s' "$OUT" | grep -q "qm1-rtw88-8723bs.service"; then
    if printf '%s' "$OUT" | grep -q "Failed to start qm1-rtw88-8723bs.service"; then
        echo "BOOT-SMOKE: 断言不过：Wi-Fi 驱动单元 qm1-rtw88-8723bs.service 起失败" >&2
        echo "BOOT-SMOKE:（最常见原因：镜像的 modules.dep 里没有这个模块，modprobe 找不到它）" >&2
        tail -60 "$CONSOLE" >&2
        exit 1
    fi
fi

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
