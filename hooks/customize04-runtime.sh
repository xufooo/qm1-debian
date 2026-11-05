#!/usr/bin/env bash
# customize04-runtime.sh — 在构建期把 agent 运行时的"底座"预置进根文件系统
#
# 目标：刷完盘第一次开机就有 Chrome 与 Python 3.14 在位；Hermes 本体留给
# 设备端官方安装器（scripts/provision-agent.sh）装 —— 官方安装器会自己用 uv
# 托管 standalone CPython 3.14，版本与 Hermes 锁定的一致。
#
# 约定（与 mmdebstrap 一致）：本 hook 在宿主执行，$1 = 目标根文件系统目录；
# 需要进入目标系统时用 chroot "$TARGET" ...。
set -eu

# 仅 runtime profile 做运行时预置（base profile 保持最小系统）
if [ "${QM1_PROFILE:-base}" != "runtime" ]; then
    printf '[runtime] profile=%s 非 runtime，跳过运行时预置\n' "${QM1_PROFILE:-base}"
    exit 0
fi

TARGET="${1:?用法: customize04-runtime.sh <目标根文件系统目录>}"
[ -d "$TARGET" ] || { echo "目标目录不存在：$TARGET" >&2; exit 1; }

log() { printf '[runtime] %s\n' "$*"; }

log "安装 Chromium 与运行库、字体"
export DEBIAN_FRONTEND=noninteractive
chroot "$TARGET" /bin/bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg ripgrep ffmpeg \
        chromium chromium-driver \
        fonts-liberation fonts-noto-cjk \
        libnss3 libgbm1 libasound2 libatk-bridge2.0-0 libxkbcommon0 \
        libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
        zram-tools rsync
    rm -rf /var/lib/apt/lists/*
'

# ★ zram 必须**确定地**开着：配置文件在 ≠ zram 设备在跑。
#   zram-tools 的 postinst 会不会 enable zramswap.service 取决于发行版的
#   preset，跨版本不是承诺；而这台机器只有 2 GiB 内存，零交换等于随时 OOM。
#   所以这里显式 enable 一次，不靠发行版的默认行为。
if chroot "$TARGET" /bin/bash -c '
        set -e
        systemctl enable zramswap.service >/dev/null 2>&1 \
            || echo "warning: could not enable zramswap.service" >&2
    '; then
    log "已启用 zramswap.service"
else
    log "警告：zram 交换没能启用（这台机器只有 2 GiB 内存）"
fi

log "安装 uv（Astral）与 standalone CPython 3.14"
# uv 自己下载的 standalone CPython 与 Hermes 官方锁定的是同一类产物
# （cpython-3.14.x-...-x86_64-unknown-linux-gnu），因此解释器 ABI 与官方一致。
chroot "$TARGET" /bin/bash -c '
    set -e
    export HOME=/root
    curl -LsSf https://astral.sh/uv/install.sh | sh
    install -m 0755 /root/.local/bin/uv /usr/local/bin/uv
    mkdir -p /opt/qm1/python
    uv python install 3.14 --install-dir /opt/qm1/python
'

log "写入解释器 PATH 与运行时说明"
cat > "$TARGET/etc/profile.d/qm1-python.sh" <<'EOF'
# QM1: standalone CPython 3.14（Hermes 官方安装器使用同一类产物）
for p in /opt/qm1/python/*/bin; do
    [ -d "$p" ] && case ":$PATH:" in *":$p:"*) ;; *) PATH="$PATH:$p" ;; esac
done
export PATH
EOF

install -d -m 0755 "$TARGET/usr/local/share/qm1"
if [ -f "$QM1_PROVISION_SRC" ]; then
    install -m 0755 "$QM1_PROVISION_SRC" "$TARGET/usr/local/share/qm1/provision-agent.sh"
    log "已放入 provision-agent.sh"
else
    log "警告：QM1_PROVISION_SRC 未设置，设备端安装脚本未随镜像分发"
fi

cat > "$TARGET/usr/local/share/qm1/README-runtime.txt" <<'EOF'
QM1 agent 运行时说明

  1. Hermes 本体用官方安装器装（官方会托管 standalone CPython 3.14）：
       curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
     不要用系统 python3（Debian 13 是 3.13.5）去装 Hermes。
  2. 预装依赖与 systemd 单元可用脚本一键补齐：
       sudo bash /usr/local/share/qm1/provision-agent.sh
  3. 硬件驱动自检：
       sudo /usr/local/bin/qm1-selftest
EOF

log "完成"
