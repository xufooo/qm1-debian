#!/usr/bin/env bash
# provision-agent.sh — 在已安装好的 QM1 系统上部署 agent 运行时
#
# 目标负载：Hermes CLI（gateway 常驻）+ 一个 headless Chrome 会话。
#
# 关键约束：
#   * Hermes 必须用官方安装方式（官方安装器用 uv 托管 standalone CPython 3.14、
#     Node.js/npm、ripgrep、FFmpeg）。系统自带的 Debian python3 是 3.13，装不上
#     Hermes 锁定的依赖 —— 绝不要在设备上源码编译 Python。
#   * 设备只有 2 GB 内存：Chrome 与 gateway 各有限额，并由 systemd-oomd 兜底。
#   * 本脚本可重复执行（幂等）。
#
# 用法：
#   sudo bash provision-agent.sh                       # 最小安装（需已联网）
#   sudo bash provision-agent.sh --wifi-ssid MySSID --wifi-pass 'xxx'
#   sudo bash provision-agent.sh --skip-hermes         # 只补依赖与 systemd 单元
set -euo pipefail

# wpa_supplicant 的取值规则（64 位十六进制 PSK 不能加引号）由 install-lib.sh
# 提供：这个脚本会被装进镜像（/usr/local/share/qm1/provision-agent.sh），所以不能
# 依赖仓库里的 scripts/lib/common.sh —— 镜像里对应的是 /usr/local/lib/qm1/。
_qm1_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_qm1_lib=""
for _cand in "/usr/local/lib/qm1/install-lib.sh" \
             "$(dirname "$_qm1_self")/../overlay/usr/local/lib/qm1/install-lib.sh" \
             "$(dirname "$_qm1_self")/../../overlay/usr/local/lib/qm1/install-lib.sh"; do
    if [ -r "$_cand" ]; then _qm1_lib="$_cand"; break; fi
done
if [ -z "$_qm1_lib" ]; then
    printf '[provision][fail] 找不到 install-lib.sh（wpa_supplicant 取值规则）\n' >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$_qm1_lib"

SKIP_HERMES=0
WIFI_SSID="${QM1_WIFI_SSID:-}"
WIFI_PASS="${QM1_WIFI_PASS:-}"
HERMES_CMD="curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"

log()  { printf '[provision] %s\n' "$*"; }
warn() { printf '[provision][warn] %s\n' "$*" >&2; }
die()  { printf '[provision][error] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --wifi-ssid) WIFI_SSID="$2"; shift 2 ;;
        --wifi-pass) WIFI_PASS="$2"; shift 2 ;;
        --hermes-cmd) HERMES_CMD="$2"; shift 2 ;;
        --skip-hermes) SKIP_HERMES=1; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root（用 sudo 重跑）"
command -v apt-get >/dev/null 2>&1 || die "这不是 Debian 系系统"

log "系统：$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")  内核：$(uname -r)"
log "内存：$(free -m | awk '/^Mem:/{print $2" MiB 总 / "$7" MiB 可用"}')"

# ---------- 1. Wi-Fi（必须最先做）----------
# ★ 顺序原来反了：先 apt-get update 再写 Wi-Fi 配置。
#   在一台刚装好、还没有任何网络配置的系统上，apt-get update 会先卡住/失败
#   （仓库域名要 DNS 解析，而 DNS 要先联网），于是"配网"这一步永远轮不到。
#   现在：先把 Wi-Fi 拉起来 → 等 DNS 能解析 → 再动 apt。
if [ -n "$WIFI_SSID" ]; then
    log "写入 Wi-Fi 配置：$WIFI_SSID"
    install -d -m 0755 /etc/wpa_supplicant
    umask 077
    # psk 的写法有讲究：64 位十六进制必须不加引号，否则会被当成 64 字符口令
    # 而超过 wpa_supplicant 的 63 字符上限 ⇒ 密码正确也连不上。
    if ! _psk_value="$(qm1_wpa_psk_value "$WIFI_PASS")"; then
        printf '[provision][fail] Wi-Fi 密码长度非法（%s 字符）：需要 8..63 字符，或 64 位十六进制\n' "${#WIFI_PASS}" >&2
        exit 1
    fi
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=CN

network={
    ssid=$(qm1_wpa_ssid_value "$WIFI_SSID")
    psk=$_psk_value
    key_mgmt=WPA-PSK
}
EOF
    # 单元名是 qm1-wifi@**.service（模板单元，%i = 接口名），
    # 不是 qm1-wifi.service —— 原来写的那个名字不存在，enable 永远失败。
    systemctl enable --now qm1-wifi@wlan0.service \
        || warn "qm1-wifi@wlan0.service 启用失败，可稍后手工配置"
else
    log "未提供 Wi-Fi 参数，跳过（如需联网可改用 USB 以太网适配器）"
fi

# ---------- 2. 等网络与 DNS ----------
# 这台机器的 DNS 由 systemd-resolved 提供（/etc/resolv.conf 指向它的 stub）。
# 没有 DNS 就没法 apt、没法拉官方安装器、连时钟都对不上。
wait_for_dns() {
    local waited=0
    while [ "$waited" -lt "${QM1_DNS_WAIT:-90}" ]; do
        if getent hosts deb.debian.org >/dev/null 2>&1; then
            log "DNS 已就绪（${waited}s）"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
if [ -n "$WIFI_SSID" ]; then
    if ! wait_for_dns; then
        warn "DNS 仍未就绪 —— 下面的 apt/安装步骤可能失败（检查 Wi-Fi 是否关联成功）"
    fi
fi

# ---------- 3. 时钟 ----------
# 时钟必须先对：官方安装器走 HTTPS，证书有效期校验依赖正确时钟；
# 这台机器没有 RTC，冷启动时系统时间从 1970 年开始。
wait_for_clock() {
    local waited=0 year
    while [ "$waited" -lt "${QM1_CLOCK_WAIT:-120}" ]; do
        year="$(date +%Y 2>/dev/null || echo 1970)"
        if [ "$year" -ge 2025 ] 2>/dev/null; then
            log "系统时钟已就绪（$(date -u)）"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

if ! wait_for_clock; then
    warn "系统时钟仍未同步（$(date -u)）——TLS 证书校验可能失败，请检查 systemd-timesyncd"
fi

# ---------- 4. 运行时依赖 ----------
log "安装运行时依赖（Chromium 运行库 / 字体 / ripgrep / ffmpeg / 工具链）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg ripgrep ffmpeg \
    chromium chromium-driver \
    fonts-liberation fonts-noto-cjk \
    libnss3 libgbm1 libasound2 libatk-bridge2.0-0 libxkbcommon0 \
    libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    zram-tools e2fsprogs rsync || warn "部分包安装失败（离线？），继续"

# ---------- 5. Hermes（官方安装方式）----------
if [ "$SKIP_HERMES" -eq 1 ]; then
    warn "按要求跳过 Hermes 安装"
else
    RUN_AS="${SUDO_USER:-root}"
    RUN_HOME="$(getent passwd "$RUN_AS" | cut -d: -f6)"
    log "运行 Hermes 官方安装器（以 $RUN_AS 身份，需要网络）"
    if curl -fsS --max-time 20 -o /dev/null https://hermes-agent.nousresearch.com/install.sh; then
        # shellcheck disable=SC2086
        set +e
        sudo -u "$RUN_AS" -H bash -c "$HERMES_CMD"
        rc=$?
        set -e
        [ "$rc" -eq 0 ] || warn "Hermes 官方安装器返回 $rc；可联网后重跑本脚本"
    else
        warn "无法访问 hermes-agent.nousresearch.com（离线？）——联网后重跑本脚本"
    fi
fi

# ---------- 6. systemd 单元与资源限额 ----------
log "写入 systemd --user 单元（gateway 常驻 + 浏览器会话）"
install -d -m 0755 /etc/systemd/system
install -d -m 0755 "$RUN_HOME/.config/systemd/user" 2>/dev/null || true

cat > /etc/systemd/system/qm1-agent.slice <<'EOF'
[Unit]
Description=QM1 agent workload slice
Before=slices.target

[Slice]
MemoryHigh=300M
MemoryMax=420M
CPUWeight=50
EOF

cat > "$RUN_HOME/.config/systemd/user/hermes-gateway.service" <<'EOF'
[Unit]
Description=Hermes gateway (long running agent)
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/hermes gateway
Restart=on-failure
RestartSec=10
MemoryHigh=280M
MemoryMax=350M
EOF

cat > "$RUN_HOME/.config/systemd/user/qm1-browser.service" <<'EOF'
[Unit]
Description=Headless Chrome session for browser_exec

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/chromium --headless=new --no-sandbox --disable-dev-shm-usage \
  --disable-gpu --disable-features=VizDisplayCompositor \
  --remote-debugging-port=9222 --user-data-dir=%h/.cache/qm1-chrome about:blank
ExecStop=/usr/bin/pkill -f "remote-debugging-port=9222"

[Install]
WantedBy=default.target
EOF

chown -R "$RUN_AS" "$RUN_HOME/.config/systemd/user" 2>/dev/null || true
loginctl enable-linger "$RUN_AS" 2>/dev/null || warn "enable-linger 失败（需 systemd-logind）"

# ---------- 7. SSH ----------
systemctl enable --now ssh 2>/dev/null || warn "ssh 启用失败"

# ---------- 8. 验收提示 ----------
cat <<EOF

运行时部署完成。验收步骤：

  hermes --version                     # CLI 可用
  python3.14 --version                 # 解释器版本（Hermes 要求 3.14）
  systemctl --user status hermes-gateway
  journalctl --user -u hermes-gateway -n 50
  /usr/local/bin/qm1-selftest          # 硬件驱动自检

EOF
log "Hermes 用的解释器由官方安装器托管（standalone CPython 3.14），不要用系统 python3 代替。"
