#!/usr/bin/env bash
# provision-agent.sh — 在已安装好的 QM1 系统上部署 agent 运行时
#
# 目标负载：Hermes CLI（gateway 常驻）+ 一个 headless Chrome 会话。
#
# 关键约束：
#   * Hermes 必须用官方安装方式（官方安装器用 uv 托管 standalone CPython 3.14、
#     Node.js/npm、ripgrep、FFmpeg）。系统自带的 Debian python3 是 3.13，装不上
#     Hermes 锁定的依赖 —— 绝不要在设备上源码编译 Python。
#   * 设备只有 2 GB 内存：浏览器单元自己带 MemoryHigh/MemoryMax 限额，并由
#     systemd-oomd 兜底。网关单元由官方 CLI 安装（hermes gateway install），
#     它带的是上游自己的重启与退出码语义，我们不再手写同名单元。
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
# 官方安装器的参数（上游 install.sh 逐段读过）：
#   --non-interactive  等价于 --skip-setup：没有 TTY 时它本来也会跳过 setup/gateway，
#                       显式写出来是为了让它不要在那儿等终端。
#   --skip-browser     不让包管理器再下载一套浏览器 —— 我们用 apt 装的 Debian Chromium
#                       已经能用，32 GB 盘 + 2 GB 内存容不下第二套浏览器。
#   --skip-computer-use 同理（跳过 cua-driver）。
HERMES_CMD="curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use"

log()  { printf '[provision] %s\n' "$*"; }
warn() { printf '[provision][warn] %s\n' "$*" >&2; }
die()  { printf '[provision][error] %s\n' "$*" >&2; exit 1; }

# 失败要能被上层看见。
# 以前这个脚本在任何一步失败时都只 warn 然后继续，最后一律 exit 0 ——
# 于是调用方（qm1-provision 包装器）以为"运行时部署完成"，写下了
# /var/lib/qm1/provision-done 标记，于是 qm1-provision.service 的
# ConditionPathExists=!标记 以后每次开机都跳过 ⇒ 首次开机没装上的运行时
# 永远补不上，而且日志里只有一句"部署完成"。
# 现在：关键步骤失败记下来，脚本最后以非零退出 ⇒ 不写标记 ⇒ 下次开机重试。
FAILED=0
fail_hard() {
    printf '[provision][fail] %s\n' "$*" >&2
    FAILED=1
}

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

# 以哪个用户的身份装 Hermes、单元写到谁的 home —— 在任何分支之前先算好，
# 否则 --skip-hermes 时 RUN_HOME 是空的，后面的单元会写到 / 下面去。
#
# RUN_AS 的来路有两个：
#   * 手工 sudo 跑 ⇒ SUDO_USER 是调用者 ⇒ 用调用者 ✓；
#   * 由 qm1-provision.service 以 root 触发 ⇒ 没有 SUDO_USER ⇒ 之前会落到
#     root 身上，于是 Hermes 装进 /root/.local/bin、单元写进 /root/.config，
#     而 sshd 明确禁掉了 root 登录（overlay 的 qm1.conf: PermitRootLogin no）
#     ⇒ 交付用户（qm1）根本用不到装好的 Hermes。
#     这时改为用镜像里的登录账号 qm1（安装器创建的 LOGIN_USER 就是它）。
RUN_AS="${QM1_PROVISION_USER:-${SUDO_USER:-}}"
if [ -z "$RUN_AS" ] || [ "$RUN_AS" = "root" ]; then
    if id qm1 >/dev/null 2>&1; then RUN_AS=qm1; fi
fi
[ -n "$RUN_AS" ] || RUN_AS="root"
RUN_HOME="$(getent passwd "$RUN_AS" 2>/dev/null | cut -d: -f6)"
log "运行时部署身份：${RUN_AS}（家目录 ${RUN_HOME:-未知}）"

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
if ! wait_for_dns; then
    # 网络没就绪，后面每一步都会失败（apt 要 DNS，官方安装器要 HTTPS）。
    # 但这里不判死刑：判死刑交给后面的 apt-get update —— 它报的错更贴近现场
    # （"还没联网？"），而这里只能说出"DNS 不通"这种没法定位的话。
    #
    # 注意这段**无条件**等：以前只在传了 Wi-Fi 凭据时才等，可自动路径
    # （qm1-provision.service）恰恰不带凭据 —— 凭据是 qm1-firstboot 写进
    # wpa_supplicant.conf 的，provision-agent 自己并不知道 ⇒ 于是 DNS 等待
    # 被整段跳过，后面直接撞在时钟等待上，错误信息完全指不到病根。
    warn "DNS 仍未就绪 —— 下面的 apt 与官方安装器大概率会失败（检查 Wi-Fi 是否关联成功）"
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
    fail_hard "系统时钟仍未同步（$(date -u)）—— TLS 证书校验必然失败，请检查 systemd-timesyncd"
fi

# ---------- 4. 运行时依赖 ----------
log "安装运行时依赖（Chromium 运行库 / 字体 / ripgrep / ffmpeg / 工具链）"
export DEBIAN_FRONTEND=noninteractive
# 没网时 apt 会失败，但那不该让脚本死在半路 —— 后面的 systemd 单元才是这台
# 机器能长期干活的骨架，联网后重跑本脚本就能补上软件包。
apt-get update -qq || fail_hard "apt-get update 失败（还没联网？）—— 单元会照写，但运行时没铺上"
apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg ripgrep ffmpeg \
    chromium chromium-driver \
    fonts-liberation fonts-noto-cjk \
    libnss3 libgbm1 libasound2 libatk-bridge2.0-0 libxkbcommon0 \
    libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    zram-tools e2fsprogs rsync || fail_hard "部分包安装失败（离线？）—— 运行时没铺上，下次开机重试"

# ---------- 5. Hermes（官方安装方式）----------
if [ "$SKIP_HERMES" -eq 1 ]; then
    warn "按要求跳过 Hermes 安装"
else
    log "运行 Hermes 官方安装器（以 $RUN_AS 身份，需要网络）"
    if curl -fsS --max-time 20 -o /dev/null https://hermes-agent.nousresearch.com/install.sh; then
        # shellcheck disable=SC2086
        set +e
        sudo -u "$RUN_AS" -H bash -c "$HERMES_CMD"
        rc=$?
        set -e
        [ "$rc" -eq 0 ] || warn "Hermes 官方安装器返回 ${rc}；可联网后重跑本脚本"
    else
        warn "无法访问 hermes-agent.nousresearch.com（离线？）——联网后重跑本脚本"
    fi
fi

# ---------- 6. systemd 单元与资源限额 ----------
log "配置 Hermes 网关服务与浏览器会话"
[ -n "$RUN_HOME" ] || die "算不出 $RUN_AS 的家目录（getent 失败）"
install -d -m 0755 "$RUN_HOME/.config/systemd/user" 2>/dev/null || true

# ---- 6a 网关服务：交给官方 CLI 装 ----
# 上游 hermes_cli/gateway.py 的 user 单元模板带着一整套我们手写时漏掉的关键项：
#   Environment="HERMES_HOME=..." / HERMES_SUPERVISED_CHILD=1 / 整理过的 PATH /
#   RestartPreventExitStatus=<致命配置错误码> / ExecReload=USR1 / ExecStop* 助手 /
#   WorkingDirectory=...
# 而且上游在每次网关启动时会 refresh_systemd_unit_if_needed() 刷新自己的单元，
# 我们手写的同名单元会被它改写/替换，两个单元还会互相打架
# （上游注释：legacy 的 hermes.service 与 hermes-gateway.service 会抢同一个 bot token）。
# 所以这里不再手写网关单元，改成调用官方安装器 —— 官方安装器的 stage_gateway
# 做的也正是这件事：
#     hermes gateway install --if-missing
HERMES_GATEWAY_UNIT=""
if [ "$SKIP_HERMES" -eq 0 ] && [ -x "$RUN_HOME/.local/bin/hermes" ]; then
    log "用官方 CLI 安装网关服务（hermes gateway install --if-missing）"
    if sudo -u "$RUN_AS" -H bash -lc 'hermes gateway install --if-missing'; then
        HERMES_GATEWAY_UNIT="hermes-gateway.service"
        log "网关服务已由官方 CLI 安装"
    else
        warn "官方网关服务安装失败 —— 回落到本机自带的最小单元"
    fi
elif [ "$SKIP_HERMES" -eq 1 ]; then
    log "按要求跳过 Hermes：网关服务不安装"
else
    warn "$RUN_HOME/.local/bin/hermes 不存在 —— 网关服务装不了（官方安装器没跑成功？）"
fi

# ---- 6b 兜底：只有官方没装成时才手写一个最小单元 ----
if [ -z "$HERMES_GATEWAY_UNIT" ] && [ "$SKIP_HERMES" -eq 0 ]; then
    cat > "$RUN_HOME/.config/systemd/user/hermes-gateway.service" <<'EOF'
[Unit]
Description=Hermes gateway (fallback unit: the upstream install failed)
After=network-online.target
Wants=network-online.target
# 没有凭据时上游网关会自己退出（"Exit 1 if no platform connects"），
# 限制重启次数，免得它在没有平台凭据时把机器刷成日志。
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
Environment="HERMES_HOME=%h/.hermes"
Environment="HERMES_SUPERVISED_CHILD=1"
ExecStart=%h/.local/bin/hermes gateway run
Restart=on-failure
RestartSec=10
MemoryHigh=280M
MemoryMax=350M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    HERMES_GATEWAY_UNIT="hermes-gateway.service"
    warn "已写入兜底网关单元 —— 它没有官方单元的 RestartPreventExitStatus 等保护，联网后建议重跑 hermes gateway install --force 换成官方单元"
fi

# ---- 6b-bis 给网关单元加内存限额（官方单元不带）----
#
# 官方 `hermes gateway install` 写出来的单元没有 MemoryHigh/MemoryMax ⇒
# 在这台 2 GiB 的机器上它可以一直涨到把 sshd 挤死：systemd-oomd 盯的是
# system.slice 与 user.slice（oomd.conf.d/qm1.conf），user.slice 的压力
# 最终会以"杀 system.slice 里最大的进程"收场 ⇒ 倒霉的常常是 sshd，
# 也就是"SSH 可登"这条交付口径。
#
# 用 drop-in 加限额，而不是改单元本体：官方 CLI 每次启动都会
# refresh_systemd_unit_if_needed() 重写单元本体，我们改的内容会被冲掉；
# drop-in 是它不碰的地方。
if [ -n "$HERMES_GATEWAY_UNIT" ] \
   && [ -f "$RUN_HOME/.config/systemd/user/$HERMES_GATEWAY_UNIT" ]; then
    _ddir="$RUN_HOME/.config/systemd/user/$HERMES_GATEWAY_UNIT.d"
    mkdir -p "$_ddir"
    cat > "$_ddir/qm1-limits.conf" <<'EOF'
[Service]
# 2 GiB 的机器上网关必须限额：不设上限它会把 sshd 挤死，
# 而 systemd-oomd 盯的 system.slice 里最大的进程常常就是 sshd。
MemoryHigh=280M
MemoryMax=350M
EOF
    chown -R "$RUN_AS" "$_ddir" 2>/dev/null || true
    log "已给网关单元加内存限额 drop-in（MemoryHigh=280M / MemoryMax=350M）"
fi

# ---- 6c 浏览器会话（我们自己管，上游不碰它）----
# 注意：--user 单元里写 Slice= 只会在用户管理器里找一个"用户作用域"的 slice，
# 我们之前写的 /etc/systemd/system/qm1-agent.slice 是系统作用域，对 user 单元
# 根本不起作用 —— 内存限额实际只来自单元自己的 MemoryHigh/MemoryMax。
cat > "$RUN_HOME/.config/systemd/user/qm1-browser.service" <<'EOF'
[Unit]
Description=Headless Chrome session for browser_exec
After=network-online.target

[Service]
# Type 必须是 simple（或 exec），不能是 oneshot：
# oneshot 的语义是"ExecStart 跑完就算启动完成"，而 chromium 是**永不返回**的
# 常驻进程 ⇒ systemd 会一直等它，等超过用户管理器的 DefaultTimeoutStartSec
# （默认 90 秒）就把进程杀掉、单元判 failed ⇒ 9222 端口从来没有服务，
# browser_exec 这条交付能力等于不存在（而脚本当时只 warn 一句）。
# Type=simple 才是"前台常驻"的正确写法：--now 立刻返回，进程一直活着。
Type=simple
Restart=on-failure
RestartSec=5
ExecStart=/usr/bin/chromium --headless=new --no-sandbox --disable-dev-shm-usage \
  --disable-gpu --disable-features=VizDisplayCompositor \
  --remote-debugging-port=9222 --user-data-dir=%h/.cache/qm1-chrome about:blank
ExecStop=/usr/bin/pkill -f "remote-debugging-port=9222"
# Chromium 在这台 2 GiB 的机器上大约吃 200~300 MiB，不设上限的话它会把
# Hermes 挤到 OOM。
MemoryHigh=350M
MemoryMax=450M

[Install]
WantedBy=default.target
EOF

chown -R "$RUN_AS" "$RUN_HOME/.config/systemd/user" 2>/dev/null || true
loginctl enable-linger "$RUN_AS" 2>/dev/null || warn "enable-linger 失败（需 systemd-logind）"

# 单元写好不等于会跑：--user 单元必须 enable 之后才会启动。
# 之前只写了文件就收工，于是验收步骤里的
#   systemctl --user status hermes-gateway
# 永远报 "not found"。
_user_uid="$(id -u "$RUN_AS" 2>/dev/null || echo "")"
_user_rt="/run/user/$_user_uid"
# 先看该有的东西在不在：单元写好了但二进制没有，启用只会得到一个起不来的服务。
if [ ! -x "$RUN_HOME/.local/bin/hermes" ]; then
    warn "$RUN_HOME/.local/bin/hermes 不存在 —— 网关单元会启动失败（Hermes 官方安装器没跑成功？）"
fi
if [ ! -x /usr/bin/chromium ]; then
    warn "/usr/bin/chromium 不存在 —— 浏览器单元会启动失败（软件包没装上？）"
fi
if [ -z "$_user_uid" ]; then
    warn "算不出 $RUN_AS 的 uid —— 单元已写好，请手动 systemctl --user enable --now"
else
    _waited=0
    while [ ! -d "$_user_rt" ] && [ "$_waited" -lt 15 ]; do
        sleep 1
        _waited=$(( _waited + 1 ))
    done
    if [ -d "$_user_rt" ]; then
        _units="qm1-browser.service"
        [ -n "$HERMES_GATEWAY_UNIT" ] && _units="$_units $HERMES_GATEWAY_UNIT"
        # shellcheck disable=SC2086
        sudo -u "$RUN_AS" XDG_RUNTIME_DIR="$_user_rt" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$_user_rt/bus" \
            systemctl --user enable --now $_units \
            || warn "user 单元启动失败（网关或浏览器还没装好？）—— 单元已 enable，稍后 systemctl --user start 即可"
    else
        warn "用户 $RUN_AS 的 user manager 没起来（$_user_rt 不存在）—— 单元已写好，下次登录后 systemctl --user enable --now"
    fi
fi

# ---------- 7. SSH ----------
systemctl enable --now ssh 2>/dev/null || warn "ssh 启用失败"

# ---------- 8. 验收提示 ----------
cat <<EOF

运行时部署完成。验收步骤：

  hermes --version                     # CLI 可用（官方安装器托管的版本）
  ls ~/.local/share/uv/python/*/bin/python3.14   # Hermes 用的解释器（standalone 3.14，不在 PATH 里）
  systemctl --user status hermes-gateway
  journalctl --user -u hermes-gateway -n 50
  curl -s http://127.0.0.1:9222/json/version    # headless Chrome 的调试端口
  /usr/local/bin/qm1-selftest          # 硬件驱动自检

网关常驻的前提是**已经配置好消息平台凭据**：上游网关在没有平台连上时会自己
退出（"Exit 1 if no platform connects so systemd Restart=always retries
transient errors"），这是它的设计，不是故障。凭据由 hermes setup 写入，
无终端的自动安装不会替你填 —— 首次使用请手工执行一次：

  hermes setup                         # 选平台、填 token（交互）
  systemctl --user restart hermes-gateway

EOF
log "Hermes 用的解释器由官方安装器托管（standalone CPython 3.14），不要用系统 python3 代替。"
log "网关单元由官方 CLI 安装（hermes gateway install --if-missing）；凭据未配置时网关会自行退出，先跑 hermes setup。"

if [ "$FAILED" -ne 0 ]; then
    # 非零退出 ⇒ 调用方不写 /var/lib/qm1/provision-done ⇒ 下次开机自动重试。
    printf '[provision][fail] 运行时部署未全部成功（见上面的 fail 行）—— 以非零退出，下次开机重试\n' >&2
    exit 1
fi
