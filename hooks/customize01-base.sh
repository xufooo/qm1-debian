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
# $2 是被依赖的目标（如 multi-user.target / timers.target），
# 链接要放在 <target>.wants/ 里。
enable_unit() {
    _unit="$1"
    _target="$2"
    _dir="${_target}.wants"
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
# 用 systemd-networkd 负责链路与 DHCP，systemd-resolved 负责 DNS。
#
# ★ 为什么必须开 systemd-resolved（原来是关掉的）：
#   systemd-networkd **不写** /etc/resolv.conf —— 它只把 DHCP 拿到的 DNS
#   交给 systemd-resolved，由后者统一提供解析。
#   而 Debian 13 的 systemd 与 systemd-resolved 两个包**都不带** /etc/resolv.conf
#   （实测 packages.debian.org 的 filelist：systemd-resolved 只有
#    /usr/lib/systemd/resolv.conf 这个 stub 文件，/etc/resolv.conf 不在其中；
#    systemd 包里一个 resolv 都没有）。
#   ⇒ 原来的镜像里 /etc/resolv.conf 根本不存在 ⇒ 没有 DNS 数据源 ⇒
#     systemd-timesyncd 拿不到时间（它的默认 NTP 服务器是域名）⇒ 时钟停在 1970
#     ⇒ 所有 HTTPS/TLS 证书校验失败 ⇒ agent 一条命令都跑不了。
#   修法：开 systemd-resolved，并把 /etc/resolv.conf 指向它的 stub。
#
# ★ 但**不在这里换 /etc/resolv.conf**：
#   本 hook 跑在 mmdebstrap 的构建期 chroot 里，chroot 里并没有运行
#   systemd-resolved —— 它的 stub 是给 127.0.0.53 用的，而 chroot 里
#   那个地址上什么都没有。
#   在这里换掉 mmdebstrap 配好的真实 resolver，后面还要联网的 hook02
#   （装内核 linux-image-6.12.113）与 hook04（装 Chromium / uv）就会
#   一片 "Temporary failure resolving 'deb.debian.org'"，构建直接失败。
#   （2026-11-05 的 CI 42048147510 就是这么挂的。）
#   所以真正的替换放在 scripts/build-rootfs.sh 里 —— 等 mmdebstrap 把
#   四个 hook 全部跑完、解包出最终根文件系统之后再换。
enable_unit systemd-networkd.service multi-user.target
enable_unit systemd-resolved.service multi-user.target
if [ ! -f "$TARGET/usr/lib/systemd/resolv.conf" ]; then
    echo "[hook01][fail] 镜像里没有 /usr/lib/systemd/resolv.conf（systemd-resolved 的 stub）—— 出货镜像将没有 DNS 数据源" >&2
    exit 1
fi
# avahi-daemon 保持关闭（2GB 内存，少一个常驻服务）；resolved 不再 disable。
chroot "$TARGET" systemctl disable avahi-daemon >/dev/null 2>&1 || true

# 时间同步必须开：这台机器没有电池、没有 RTC 时钟从 1970 年开始，
# 而 TLS 证书有效期校验、agent 任务调度、日志时间戳全都依赖正确时钟。
# 时间同步是 timers.target 激活的单元。
enable_unit systemd-timesyncd.service timers.target
# 蓝牙栈（bluez）也要开：厂商固件下发后由它管理 hci0 并负责配对；
# 它依赖 overlay 的 bluetooth.service.d/qm1.conf 排在 qm1-bluetooth.service 之后。
enable_unit bluetooth.service multi-user.target

# --- 首次启动不要在硬件随机数池上等太久 ------------------------------------
# 这台机器没有电池、没有 RTC，系统冷启动时时钟从 1970 年开始；
# 同时 /dev/random 在启动早期可能阻塞（没有熵就出不来 random-seed）。
# 解法不是"信任 CPU 的 RNG"（random.trust_cpu=on 会降低安全性），
# 而是在**构建期**就播种一份随机种子，开机就不用等熵。
mkdir -p "$TARGET/var/lib/systemd"
if [ ! -s "$TARGET/var/lib/systemd/random-seed" ]; then
    dd if=/dev/urandom of="$TARGET/var/lib/systemd/random-seed" bs=512 count=1 \
       status=none 2>/dev/null || true
    chmod 0600 "$TARGET/var/lib/systemd/random-seed" 2>/dev/null || true
fi

# 全局默认启动超时：原来是 30s。
# ★ 30s 太短，会**直接把慢单元杀掉**，而且是在它还没来得及报错的时候：
#   qm1-wifi@.service 的 ExecStartPre 要等最多 60 秒 SDIO 卡把 wlan0 枚举出来，
#   30s 的全局上限会让它在接口出现之前就被 systemd 掐掉 —— 表现为"Wi-Fi 永远起不来"。
#   单元自己的 TimeoutStartSec 会覆盖这个默认值（qm1-firstboot 是 180s），
#   但没写这一项的单元就按 30s 算，取证日志也会被截断。
mkdir -p "$TARGET/etc/systemd/system.conf.d"
printf '[Service]\nTimeoutStartSec=120s\n' > "$TARGET/etc/systemd/system.conf.d/quick-boot.conf"

# --- 可用账号 --------------------------------------------------------------
# 原来整个仓库没有 useradd/adduser/chpasswd ⇒ 装完之后**没有任何账号能登进**：
#   sshd 只允许公钥（PasswordAuthentication no）+ PermitRootLogin no，
#   而机器上既没有用户、也没有 authorized_keys。
# 现在建一个普通用户 qm1（uid 1000，sudo 组），**镜像里不设默认口令**
# （账号默认锁定），口令由安装器在装机时随机生成并打印在屏幕上，
# 同时写进目标系统的 /etc/qm1-installed-to-emmc（root 可读，0600）。
if ! chroot "$TARGET" id qm1 >/dev/null 2>&1; then
    chroot "$TARGET" useradd --create-home --shell /bin/bash --uid 1000 qm1
    echo "[hook01] 已创建用户 qm1（uid 1000，初始无口令）"
fi
chroot "$TARGET" usermod -aG sudo qm1 2>/dev/null || true
# 明确锁定密码：镜像里不留任何可用口令
chroot "$TARGET" passwd -l qm1 >/dev/null 2>&1 || true

echo "[hook01] 基础配置完成"
