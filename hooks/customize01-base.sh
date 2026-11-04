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
chroot "$TARGET" systemctl enable ssh >/dev/null 2>&1 || true
chroot "$TARGET" systemctl enable systemd-oomd >/dev/null 2>&1 || true
for svc in systemd-resolved avahi-daemon bluetooth systemd-timesyncd; do
    chroot "$TARGET" systemctl disable "$svc" >/dev/null 2>&1 || true
done

# --- 首次启动不要在硬件随机数池上等太久 ------------------------------------
mkdir -p "$TARGET/etc/systemd/system.conf.d"
printf '[Service]\nTimeoutStartSec=30s\n' > "$TARGET/etc/systemd/system.conf.d/quick-boot.conf"

echo "[hook01] 基础配置完成"
