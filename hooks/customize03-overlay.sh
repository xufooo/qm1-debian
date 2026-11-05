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

# ---------------------------------------------------------------------------
# 屏蔽发行版自带的 wpa_supplicant.service
#
# 这台机器的 Wi-Fi 只有一条路：qm1-wifi@wlan0.service（按接口实例化，
# 进程内等接口出现，见 /usr/local/sbin/qm1-wifi-start）。
#
# 发行版的 wpa_supplicant.service 是全局单元、不知道自己管哪个接口，
# 它会被发行版的默认配置带起来（CI 的控制台里能看到它和我们的单元
# 同时 "Started"）。两个 wpa_supplicant 争同一个 wlan0 ⇒ 控制套接字
# 抢锁、关联互相踢 —— 现场表现就是"wlan0 在、能看到 SSID，就是连不上"，
# 而日志里没有任何报错，极难查。
#
# 所以明确屏蔽：Wi-Fi 由我们自己的单元独占。
# ---------------------------------------------------------------------------
mkdir -p "$TARGET/etc/systemd/system"
ln -sf /dev/null "$TARGET/etc/systemd/system/wpa_supplicant.service"

# ---------------------------------------------------------------------------
# overlay 单元的 wants 链接
#
# 之前的写法有个致命错位：overlay 的单元是用 cp -a 落在 **/etc/systemd/system**
# 下面的（见本文件开头的 cp -a "$QM1_OVERLAY_DIR/." "$TARGET/"），而 wants 链接
# 却指向 /lib/systemd/system/<unit> —— 那个路径在镜像里根本不存在，于是每一个
# 链接都是悬空的。systemd 只看链接在不在，不看目标在不在，于是：
#   * 单元永远不会启动；
#   * CI 侧用 [ -L ... ] 判定（有悬空链接也满足）⇒ 流水线全绿。
# 最典型的后果是 qm1-install.service 悬空 ⇒ GRUB 菜单里那条"安装到 eMMC"
# 选下去什么都不会发生。
#
# 现在统一：链接指向单元的**真实所在路径**，并且建完立刻断言不是悬空的。
# systemctl enable 在构建 chroot 里不可靠（没有运行中的 systemd），所以
# 链接由我们自己写一份确定的出来，而不是靠 systemctl 的副作用。
# ---------------------------------------------------------------------------
enable_overlay_unit() {
    _unit_file="$1"   # 单元文件名，例如 qm1-wifi@.service
    _link_name="$2"   # wants 目录里的链接名，例如 qm1-wifi@wlan0.service
    _wants="$3"       # multi-user.target / timers.target / network.target ...

    _src="/etc/systemd/system/$_unit_file"
    if [ ! -f "$TARGET$_src" ]; then
        echo "[hook03][warn] 单元不存在，跳过：$_unit_file"
        return 0
    fi

    mkdir -p "$TARGET/etc/systemd/system/$_wants.wants"
    chroot "$TARGET" systemctl enable "$_unit_file" >/dev/null 2>&1 || true

    ln -sf "$_src" "$TARGET/etc/systemd/system/$_wants.wants/$_link_name"

    # 悬空链接是这次要根除的病根 —— 建完必须验一次。
    #
    # ★ 链接目标是**绝对路径**（/etc/systemd/system/<unit>），所以不能用
    #   `[ -e "$TARGET/.../wants/<name>" ]` 去验：那样内核会拿**宿主机**的根
    #   去解析那个绝对路径，宿主机上当然没有这个单元 ⇒ 一律判成「悬空」，
    #   构建必挂。必须把链接目标拼回 $TARGET 再判断。
    _link="$TARGET/etc/systemd/system/$_wants.wants/$_link_name"
    _tgt="$(readlink "$_link" 2>/dev/null || true)"
    case "$_tgt" in
        /*) _resolved="$TARGET$_tgt" ;;
        *)  _resolved="$(dirname "$_link")/$_tgt" ;;
    esac
    if [ ! -e "$_resolved" ]; then
        echo "[hook03][fail] wants 链接悬空：$_wants.wants/$_link_name -> $_tgt"
        exit 1
    fi
    echo "[hook03] 已启用 $_link_name（$_wants.wants -> $_src）"
}

# Wi-Fi 是这台机器唯一的主联网链路（没有 RJ45）→ 开机自启。
# 单元是模板（qm1-wifi@.service），实例名就是无线接口名（wlan0）。
enable_overlay_unit "qm1-wifi@.service" "qm1-wifi@wlan0.service" "multi-user.target"

# 首启自动配置（Wi-Fi / SSH / 主机名）：开机自启，读取启动分区或根文件系统里的
# provisioning 文件 —— 装完就能联网、能 SSH，不用接显示器手动敲配置。
mkdir -p "$TARGET/var/lib/qm1"
enable_overlay_unit "qm1-firstboot.service" "qm1-firstboot.service" "multi-user.target"

# 稳定性取证采集器：周期快照（整机卡死 / eMMC 掉卡 / Wi-Fi 断流的判据）。
# 没有计数器就无法判断某个缓解到底有没有用，所以它是第一优先级的组件。
enable_overlay_unit "qm1-hardware-fixups.service" "qm1-hardware-fixups.service" "multi-user.target"

mkdir -p "$TARGET/var/log/qm1-health"
enable_overlay_unit "qm1-health-collect.timer" "qm1-health-collect.timer" "timers.target"

# 蓝牙控制器初始化（内核 hci_uart + btrtl 路线，见单元里的说明）
enable_overlay_unit "qm1-bluetooth.service" "qm1-bluetooth.service" "multi-user.target"

# 运行时部署（Hermes CLI + headless Chrome）：等 network-online 之后跑一次
# provision-agent.sh，成功后写 /var/lib/qm1/provision-done；失败下次开机重试。
# 没有这个单元的话，刷完机不会自动铺运行时 —— 交付口径是"开机即用"。
#
# ★ 这里启用的是 **timer**，不是 service 本身。
#
#   原因：target 会给 Wants= 成员隐式补上 After=
#   （systemd.unit(5)：target units will implicitly complement all configured
#   dependencies of type Wants= or Requires= with After= dependencies）。
#   所以只要 qm1-provision.service 挂在 multi-user.target 上，而它自己
#   After=network-online.target，就等于"整机开机必须等到网络就绪"——
#   这台机器没有 RJ45，内置 Wi-Fi 是唯一链路，Wi-Fi 没起来时
#   整机到不了 multi-user.target ⇒ 没有 SSH、看起来像砖了。
#
#   挂到 timers.target 上就没有这个问题：定时器触发服务，服务等网络，
#   两条链互不阻塞。
enable_overlay_unit "qm1-provision.timer" "qm1-provision.timer" "timers.target"

# 开机自检：开机后跑一遍硬件体检，报告进 journal，机读 JSON 落盘。
#
# 用 timer 触发，和运行时部署同理：挂进 multi-user.target 就等于
# "整机开机必须等自检跑完"，自检卡住整机就卡住（这个坑踩过两次）。
enable_overlay_unit "qm1-selftest.timer" "qm1-selftest.timer" "timers.target"

# 安装单元开机自启（平时被 ConditionKernelCommandLine=qm1.install=1 挡住，
# 只有从安装介质选"安装到 eMMC"那条菜单项时才会真的执行）。
enable_overlay_unit "qm1-install.service" "qm1-install.service" "multi-user.target"

echo "[hook03] 完成"
