#!/bin/sh
# ============================================================================
# customize03-overlay.sh — mmdebstrap customize hook：应用 QM1 定制 overlay
# ============================================================================
# overlay/ 里放的是"这台机器专用"的配置：zram、journald 限额、systemd-oomd、
# Wi-Fi 服务、SSH、apt 定时任务（护 eMMC 寿命）等。
# 目录由 QM1_OVERLAY_DIR 传入（构建脚本设置），设备端自检脚本由
# QM1_SELFCHECK_SRC 传入。
# ============================================================================
set -e

TARGET="${1:?usage: mmdebstrap hook requires the chroot directory as \$1}"

if [ -n "${QM1_OVERLAY_DIR:-}" ] && [ -d "$QM1_OVERLAY_DIR" ]; then
    echo "[hook03] 应用 overlay：$QM1_OVERLAY_DIR"
    cp -a "$QM1_OVERLAY_DIR/." "$TARGET/"
else
    echo "[hook03][warn] 未提供 QM1_OVERLAY_DIR，跳过 overlay"
fi

# 设备端自检脚本（overlay 的 /usr/local/bin/qm1-selftest 依赖此路径）
if [ -n "${QM1_SELFCHECK_SRC:-}" ] && [ -f "$QM1_SELFCHECK_SRC" ]; then
    mkdir -p "$TARGET/usr/local/lib/qm1"
    cp "$QM1_SELFCHECK_SRC" "$TARGET/usr/local/lib/qm1/drv-selfcheck.sh"
    chmod 0755 "$TARGET/usr/local/lib/qm1/drv-selfcheck.sh"
    if [ -f "$TARGET/usr/local/bin/qm1-selftest" ]; then
        chmod 0755 "$TARGET/usr/local/bin/qm1-selftest"
    fi
fi

# overlay 里的 systemd 单元需要重新生成缓存（离线也能做）
if [ -d "$TARGET/etc/systemd/system" ]; then
    chroot "$TARGET" systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 安装单元开机自启（平时被 ConditionKernelCommandLine=qm1.install=1 挡住，
# 只有从安装介质选"安装到 eMMC"那条菜单项时才会真的执行）。
if [ -f "$TARGET/etc/systemd/system/qm1-install.service" ]; then
    mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/qm1-install.service \
        "$TARGET/etc/systemd/system/multi-user.target.wants/qm1-install.service"
    echo "[hook03] 已启用安装单元 qm1-install.service（仅 qm1.install=1 时触发）"
fi

echo "[hook03] 完成"
