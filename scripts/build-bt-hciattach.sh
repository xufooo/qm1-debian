#!/usr/bin/env bash
# build-bt-hciattach.sh — 构建 RTL8723BS 蓝牙（UART HCI）支持包并打成 .deb
#
# 背景（为什么不是内核模块）：
#   QM1 的蓝牙是 Realtek RTL8723BS combo 的 BT 部分，经 **ACPI 枚举的 UART**
#   挂在主机上 —— ASUS 官方 Win8 驱动的 rtkuart.inf 里写得很清楚：
#       ACPI\VEN_OBDA&DEV_8723
#       ACPI\VEN_OBDA&DEV_0623
#   驱动是 RtkUart.sys（用户态服务，Bus_Service_Inst）。
#   而 **Linux 主线没有 Realtek UART HCI 驱动**（linux-firmware 的提交说明里
#   直接写明：内核没有 Realtek UART HCI 驱动，这些固件名字来自 Realtek 驱动）。
#   所以内核侧只需要 CONFIG_BT_HCIUART（Debian 内核已内置 btuart），
#   缺的是「把厂商固件刷进芯片并初始化」这一步 —— 那正是用户态 hciattach
#   的活儿：Realtek 的 hciattach 衍生版 rtk_hciattach。
#
# 方案：
#   装 lwfinger/rtl8723bs_bt（上游，MIT）的 rtk_hciattach + 它自带的固件
#   （rtlbt_fw / rtlbt_config / rtlbt_fw_new），用 systemd 在开机时对 BT
#   UART 执行 `rtk_hciattach -n -s 115200 <tty> rtk_h5`：
#     -n = detach = 0（不摘 ldisc，固件下发后由内核 btuart 接手同一个串口）
#     rtk_h5 = 3 线 UART 协议（内核需 ≥ 3.12，Debian 6.12 满足）
#
# 固件与 ASUS Win8 驱动的关系（取证结论，写在这里备查）：
#   ASUS Win8.1 蓝牙包里的 rtl8723b_mp_bt40_fw_asic_rom / rtl8723b_config.bin
#   是 **Windows 用的未打补丁版本**；Debian 的 firmware-realtek 里
#   rtl_bt/rtl8723bs_fw.bin 与 rtl8723bs_config.bin 才是 Linux 侧打过补丁的
#   版本（把 UART 波特率改成 1500000 bps 的那一版）。两者首字节就不同，
#   不能互相替代。本包用的是上游 rtk_hciattach 自带的那份补丁固件。
#
# 用法：
#   bash scripts/build-bt-hciattach.sh [--out-dir DIR] [--work-dir DIR] \
#        [--src-ref COMMIT] [--src-url URL]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT_DIR="$REPO_ROOT/build/bt-hciattach"
WORK_DIR="$REPO_ROOT/build/bt-work"
# 钉死上游提交（lwfinger/rtl8723bs_bt 的 master）。
SRC_REF="09eb91f52a639ec5e4c5c4c98dc2afede046cf20"
SRC_URL=""
PKG_VERSION="1.0"
JOBS="$(nproc 2>/dev/null || echo 2)"

while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --src-ref) SRC_REF="$2"; shift 2 ;;
        --src-url) SRC_URL="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

for cmd in curl tar make cc dpkg-deb sha256sum; do
    need_cmd "$cmd"
done

mkdir -p "$OUT_DIR" "$WORK_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

[ -n "$SRC_URL" ] || SRC_URL="https://codeload.github.com/lwfinger/rtl8723bs_bt/tar.gz/${SRC_REF}"

SRC_TARBALL="$WORK_DIR/rtl8723bs_bt.tar.gz"
log "下载上游源码：$SRC_URL"
rm -f "$SRC_TARBALL"
# GitHub 偶尔 TLS 抖动，失败重试几次。
if ! curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$SRC_TARBALL" "$SRC_URL"; then
    die "下载上游源码失败：$SRC_URL"
fi
TARBALL_SHA="$(sha256sum "$SRC_TARBALL" | awk '{print $1}')"
log "源码包 sha256：$TARBALL_SHA"

rm -rf "$WORK_DIR/src"
mkdir -p "$WORK_DIR/src"
tar -xzf "$SRC_TARBALL" -C "$WORK_DIR/src"
SRC_DIR="$(find "$WORK_DIR/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$SRC_DIR" ] || die "解压后找不到源码目录"
log "源码目录：$SRC_DIR"

# ---- 编译 rtk_hciattach ----
log "编译 rtk_hciattach"
make -C "$SRC_DIR" -j"$JOBS" >/dev/null
BIN="$SRC_DIR/rtk_hciattach"
[ -f "$BIN" ] || die "编译产物 rtk_hciattach 不存在"
chmod 0755 "$BIN"
log "rtk_hciattach：$(stat -c%s "$BIN") 字节"

# ---- 打包 ----
PKG="$WORK_DIR/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/usr/sbin" \
         "$PKG/usr/local/bin" \
         "$PKG/lib/firmware/rtl_bt" \
         "$PKG/lib/systemd/system" \
         "$PKG/etc/default"

cp "$BIN" "$PKG/usr/sbin/rtk_hciattach"
chmod 0755 "$PKG/usr/sbin/rtk_hciattach"

# 固件：上游自带的三件套（rtlbt_fw_new 是备用版本）
for f in rtlbt_fw rtlbt_config rtlbt_fw_new; do
    if [ -f "$SRC_DIR/$f" ]; then
        cp "$SRC_DIR/$f" "$PKG/lib/firmware/rtl_bt/$f"
        log "固件 $f：$(stat -c%s "$PKG/lib/firmware/rtl_bt/$f") 字节"
    else
        warn "上游源码里没有 $f，跳过"
    fi
done
[ -f "$PKG/lib/firmware/rtl_bt/rtlbt_fw" ] || die "缺少固件 rtlbt_fw"
[ -f "$PKG/lib/firmware/rtl_bt/rtlbt_config" ] || die "缺少固件 rtlbt_config"

# 开机自动探测 BT 串口并 attach 的小脚本
cat > "$PKG/usr/local/bin/qm1-bt-attach.sh" <<'EOF'
#!/bin/sh
# qm1-bt-attach.sh — 找到 RTL8723BS 的蓝牙 UART 并执行 Realtek 厂商初始化
#
# 探测顺序：
#   1) /etc/default/qm1-bluetooth 里的 BT_TTY（人工指定，最优先）
#   2) 按 ACPI HID 找（ASUS 官方 Win 驱动 rtkuart.inf 里就是
#      ACPI\VEN_OBDA&DEV_8723 / ACPI\VEN_OBDA&DEV_0623）
#   3) 退回 dmesg 里的第一个 MMIO 串口（8250_dw 一般是 ttyS1）
set -e

TTY=""
if [ -r /etc/default/qm1-bluetooth ]; then
    # shellcheck disable=SC1091
    . /etc/default/qm1-bluetooth
fi
[ -n "${BT_TTY:-}" ] && TTY="$BT_TTY"

if [ -z "$TTY" ]; then
    for hid in OBDA8723 OBDA0623; do
        for adev in /sys/bus/acpi/devices/${hid}*; do
            [ -e "$adev" ] || continue
            abase="$(basename "$adev")"
            for t in /sys/class/tty/ttyS*; do
                [ -e "$t" ] || continue
                rp="$(readlink -f "$t" 2>/dev/null || echo "$t")"
                case "$rp" in
                    *"$abase"*) TTY="/dev/$(basename "$t")"; break ;;
                esac
            done
            [ -n "$TTY" ] && break
        done
        [ -n "$TTY" ] && break
    done
fi

if [ -z "$TTY" ]; then
    cand="$(dmesg 2>/dev/null | grep -o 'ttyS[0-9]\+' | head -1 || true)"
    [ -n "$cand" ] && TTY="/dev/$cand"
fi

if [ -z "$TTY" ] || [ ! -e "$TTY" ]; then
    echo "qm1-bt-attach: 找不到蓝牙 UART（ACPI OBDA8723/OBDA0623 都没匹配上）" >&2
    exit 1
fi

echo "qm1-bt-attach: 使用 $TTY（BT_PROTOCOL=${BT_PROTOCOL:-rtk_h5}, BT_SPEED=${BT_SPEED:-115200}）"

# 先把厂商固件刷进芯片并初始化。注意用 -n（不摘 ldisc），
# 这样固件下发后内核的 hci_uart 驱动能接管同一个串口。
/usr/sbin/rtk_hciattach -n -s "${BT_SPEED:-115200}" "$TTY" "${BT_PROTOCOL:-rtk_h5}" || {
    echo "qm1-bt-attach: rtk_hciattach 失败（固件下发未完成）" >&2
    exit 1
}

# Debian 13 的内核 CONFIG_BT_HCIUART=m（实测 6.12.113+deb13-amd64），
# hci_uart 是模块 bt_hciuart.ko —— 固件下发完要把它加载起来，
# 内核才会把这个串口认成蓝牙控制器并注册 hci0。
# 编进内核的发行版上 modprobe 会失败，忽略即可。
modprobe bt_hciuart 2>/dev/null || true

sleep 2
if [ -d /sys/class/bluetooth/hci0 ]; then
    echo "qm1-bt-attach: 蓝牙已就绪（hci0 已出现）"
else
    echo "qm1-bt-attach: 固件已下发但 hci0 没出现 —— 试 modprobe bt_hciuart，或检查 /etc/default/qm1-bluetooth 里的 BT_TTY/协议" >&2
fi
EOF
chmod 0755 "$PKG/usr/local/bin/qm1-bt-attach.sh"

cat > "$PKG/etc/default/qm1-bluetooth" <<'EOF'
# qm1-bluetooth — 蓝牙 UART 初始化参数
# BT_TTY: 留空 = 自动探测（ACPI OBDA8723/OBDA0623 → dmesg 首个 MMIO 串口）
# BT_PROTOCOL: rtk_h5 = 3 线 UART（默认），rtk_h4 = 2 线
# BT_SPEED: 初始波特率（厂商固件默认 115200）
BT_TTY=""
BT_PROTOCOL="rtk_h5"
BT_SPEED="115200"
EOF

cat > "$PKG/lib/systemd/system/qm1-bluetooth.service" <<'EOF'
[Unit]
Description=Realtek RTL8723BS Bluetooth (UART HCI firmware attach)
After=systemd-udevd.service
ConditionPathExists=/usr/sbin/rtk_hciattach

[Service]
Type=simple
ExecStart=/usr/local/bin/qm1-bt-attach.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > "$PKG/DEBIAN/control" <<EOF
Package: qm1-rtl8723bs-bt
Version: ${PKG_VERSION}
Section: kernel
Priority: optional
Architecture: amd64
Maintainer: QM1 image builder <none>
Description: Realtek RTL8723BS Bluetooth UART support for ASUS QM1
 The RTL8723BS Bluetooth part is an ACPI enumerated UART (OBDA8723/OBDA0623)
 that the Linux kernel has no vendor driver for. This package ships the
 upstream rtk_hciattach helper (lwfinger/rtl8723bs_bt) together with the
 patched vendor firmware so the chip is initialized at boot and the in-tree
 btuart driver can take over the port.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
EOF
chmod 0755 "$PKG/DEBIAN/postinst"

DEB="$OUT_DIR/qm1-rtl8723bs-bt_${PKG_VERSION}_amd64.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
log "生成：$DEB"

# ---- 清单 ----
MANIFEST="$OUT_DIR/manifest.txt"
{
    echo "package=qm1-rtl8723bs-bt"
    echo "version=$PKG_VERSION"
    echo "arch=amd64"
    echo "source_ref=$SRC_REF"
    echo "source_url=$SRC_URL"
    echo "tarball_sha256=$TARBALL_SHA"
    echo "binary_sha256=$(sha256sum "$DEB" | awk '{print $1}')"
    echo "binary_bytes=$(stat -c%s "$DEB")"
    echo "hciattach_sha256=$(sha256sum "$PKG/usr/sbin/rtk_hciattach" | awk '{print $1}')"
    for f in rtlbt_fw rtlbt_config rtlbt_fw_new; do
        [ -f "$PKG/lib/firmware/rtl_bt/$f" ] || continue
        echo "firmware_$f=$(sha256sum "$PKG/lib/firmware/rtl_bt/$f" | awk '{print $1}')"
    done
} > "$MANIFEST"

( cd "$OUT_DIR" && sha256sum ./*.deb > SHA256SUMS )
log "清单：$MANIFEST"
cat "$MANIFEST"
