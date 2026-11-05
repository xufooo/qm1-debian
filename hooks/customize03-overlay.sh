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

# Wi-Fi 是这台机器唯一的主联网链路（没有 RJ45）→ 开机自启。
# 单元是模板（qm1-wifi@.service），实例名就是无线接口名（wlan0）。
if [ -f "$TARGET/etc/systemd/system/qm1-wifi@.service" ]; then
    chroot "$TARGET" systemctl enable qm1-wifi@wlan0 >/dev/null 2>&1 \
        || ln -sf /lib/systemd/system/qm1-wifi@.service \
               "$TARGET/etc/systemd/system/multi-user.target.wants/qm1-wifi@wlan0.service"
    echo "[hook03] 已启用 qm1-wifi@wlan0（内置 Wi-Fi 主链路）"
fi

# 首启自动配置（Wi-Fi / SSH / 主机名）：开机自启，读取启动分区或根文件系统里的
# provisioning 文件 —— 装完就能联网、能 SSH，不用接显示器手动敲配置。
if [ -f "$TARGET/etc/systemd/system/qm1-firstboot.service" ]; then
    mkdir -p "$TARGET/var/lib/qm1"
    chroot "$TARGET" systemctl enable qm1-firstboot.service >/dev/null 2>&1 \
        || ln -sf /lib/systemd/system/qm1-firstboot.service \
               "$TARGET/etc/systemd/system/multi-user.target.wants/qm1-firstboot.service"
    echo "[hook03] 已启用 qm1-firstboot.service（首启自动配置 Wi-Fi/SSH）"
fi

# 稳定性取证采集器：周期快照（整机卡死 / eMMC 掉卡 / Wi-Fi 断流的判据）。
# 没有计数器就无法判断某个缓解到底有没有用，所以它是第一优先级的组件。
if [ -f "$TARGET/etc/systemd/system/qm1-health-collect.timer" ]; then
    mkdir -p "$TARGET/var/log/qm1-health"
    chroot "$TARGET" systemctl enable qm1-health-collect.timer >/dev/null 2>&1 \
        || ln -sf /lib/systemd/system/qm1-health-collect.timer \
               "$TARGET/etc/systemd/system/timers.target.wants/qm1-health-collect.timer"
    echo "[hook03] 已启用 qm1-health-collect.timer（周期采集稳定性证据）"
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
