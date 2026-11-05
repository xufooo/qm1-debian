#!/bin/sh
# ============================================================================
# customize01-base.sh — mmdebstrap customize hook：QM1 基础系统配置
# ============================================================================
# IMPORTANT: mmdebstrap runs hooks on the HOST and passes the chroot directory
# in $1. All paths must therefore be prefixed with "$TARGET"; use
# chroot "$TARGET" for commands that must really run inside the chroot.
# ============================================================================
set -e

TARGET="${1:?usage: mmdebstrap hook requires the chroot directory as \$1}"

# --- 主机名 / hosts -------------------------------------------------------
echo qm1 > "$TARGET/etc/hostname"
cat > "$TARGET/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   qm1
::1         localhost ip6-localhost ip6-loopback
EOF

# --- locale / 时区 --------------------------------------------------------
if [ -f "$TARGET/etc/locale.gen" ]; then
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' "$TARGET/etc/locale.gen"
    chroot "$TARGET" locale-gen
fi
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$TARGET/etc/localtime"
echo "Asia/Shanghai" > "$TARGET/etc/timezone"

# --- fstab：根盘由内核 root=UUID= 挂载，这里只补伪文件系统 ------------------
cat > "$TARGET/etc/fstab" <<'EOF'
# <file system>  <mount point>  <type>     <options>              <dump> <pass>
proc            /proc          proc       defaults               0      0
sysfs           /sys           sysfs      defaults               0      0
devtmpfs        /dev           devtmpfs   mode=0755,nosuid       0      0
tmpfs           /run           tmpfs      mode=0755,nosuid,nodev 0      0
tmpfs           /tmp           tmpfs      defaults,nosuid,nodev 0      0
EOF

# --- 服务开关：2GB 内存 + eMMC 寿命，宁可少开常驻 -------------------------
# systemd 的 enable/disable 是离线操作（只写符号链接），chroot 里可用。
# systemctl enable 在 chroot 里偶尔不写符号链接（没有 /proc 时它会拒绝），
# 所以每个单元都要有确定的手工兜底：单元文件在镜像里就自己建链接。
enable_unit() {
    _unit="$1"
    _dir="$2"
    chroot "$TARGET" systemctl enable "$_unit" >/dev/null 2>&1 || true
    if [ -f "$TARGET/lib/systemd/system/$_unit" ] \
       && [ ! -e "$TARGET/etc/systemd/system/$_dir/$_unit" ]; then
        mkdir -p "$TARGET/etc/systemd/system/$_dir"
        ln -sf "/lib/systemd/system/$_unit" \
               "$TARGET/etc/systemd/system/$_dir/$_unit"
        echo "[hook01] 已启用 $_unit（$_dir）: $(ls -l "$TARGET/etc/systemd/system/$_dir/$_unit" 2>&1)"
    fi
}

enable_unit ssh.service multi-user.target
enable_unit systemd-oomd.service multi-user.target
# 这台机器没有板载 RJ45，内置 Wi-Fi 是唯一的主联网链路 → 必须有 DHCP 客户端。
# 用 systemd-networkd：它顺带负责写 /etc/resolv.conf，所以 systemd-resolved
# 可以继续关着（2GB 内存，少一个常驻服务）。
enable_unit systemd-networkd.service multi-user.target
for svc in systemd-resolved avahi-daemon; do
    chroot "$TARGET" systemctl disable "$svc" >/dev/null 2>&1 || true
done

# 时间同步必须开：这台机器没有电池、没有 RTC 时钟从 1970 年开始，
# 而 TLS 证书有效期校验、agent 任务调度、日志时间戳全都依赖正确时钟。
# 时间同步是 timers.target 激活的单元。
enable_unit systemd-timesyncd.service timers.target
# 蓝牙栈（bluez）也要开：厂商固件下发后由它管理 hci0 并负责配对；
# 它依赖 overlay 的 bluetooth.service.d/qm1.conf 排在 qm1-bluetooth.service 之后。
enable_unit bluetooth.service multi-user.target

# --- 首次启动不要在硬件随机数池上等太久 ------------------------------------
mkdir -p "$TARGET/etc/systemd/system.conf.d"
printf '[Service]\nTimeoutStartSec=30s\n' > "$TARGET/etc/systemd/system.conf.d/quick-boot.conf"

echo "[hook01] 基础配置完成"
