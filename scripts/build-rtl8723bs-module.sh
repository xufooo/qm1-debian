#!/usr/bin/env bash
# build-rtl8723bs-module.sh — 把打过补丁的 rtl8723bs 编译成 out-of-tree 模块并打成 .deb
#
# 产物：r8723bs_qm1.ko —— Debian 内核里那个 r8723bs 的「改名打补丁版」。
#
# 为什么必须另起一个模块名（而不是直接替换树内 r8723bs）：
#   两个模块带完全相同的 SDIO alias（sdio:c*v024CdB723*）。
#   modprobe 按 alias 加载时会把所有匹配项都插进内核，树内那个一旦先注册
#   sdio driver，打补丁的那个就再也注册不上去（-EBUSY）。
#   所以：树内 r8723bs 用 blacklist 挡住，打补丁的改名成 r8723bs_qm1。
#
# 改名怎么做才不改驱动的 C 代码：
#   上游 Makefile 是「复合模块」：obj-$(CONFIG_RTL8723BS) := r8723bs.o，
#   加上 r8723bs-y = <57 个 .o>。这里生成一份包装 Makefile：
#       obj-m := r8723bs_qm1.o
#       r8723bs_qm1-y := <同一份对象列表>
#   Kbuild 会把它编译成 r8723bs_qm1.ko，并且 modpost 会把模块名
#   （.modinfo 里的 name=）写成 r8723bs_qm1 —— 内核里的模块名也就跟着变了。
#   注意：单纯把 .ko 文件改名是不行的，内核读的是 .modinfo 里的 name=。
#
# 用法：
#   bash scripts/build-rtl8723bs-module.sh [--kver 6.12.113+deb13-amd64] \
#        [--src-dir DIR] [--work-dir DIR] [--out-dir DIR] [--patch-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---- 默认参数 ----
KVER="${KVER:-6.12.113+deb13-amd64}"        # 目标内核（Debian trixie amd64）
SRC_DIR="${SRC_DIR:-$REPO_ROOT/build/rtl8723bs-src}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/rtl8723bs-work}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/wifi-module}"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/rtl8723bs}"

PKG_NAME="qm1-rtl8723bs-module"
PKG_VERSION="${PKG_VERSION:-1.0.0}"
PKG_ARCH="amd64"
MOD_NAME="r8723bs_qm1"                      # 打补丁后的模块名
DRIVER_REL="drivers/staging/rtl8723bs"     # 源码树里的相对路径
KDIR="/lib/modules/${KVER}/build"

while [ $# -gt 0 ]; do
    case "$1" in
        --kver)      KVER="$2"; shift 2 ;;
        --src-dir)   SRC_DIR="$2"; shift 2 ;;
        --work-dir)  WORK_DIR="$2"; shift 2 ;;
        --out-dir)   OUT_DIR="$2"; shift 2 ;;
        --patch-dir) PATCH_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) die "未知参数：$1" ;;
    esac
done

# KVER 变了，KDIR 也得跟着变
KDIR="/lib/modules/${KVER}/build"

log "目标内核：$KVER"
log "源码目录：$SRC_DIR"
log "工作目录：$WORK_DIR"
log "产物目录：$OUT_DIR"
log "补丁目录：$PATCH_DIR"

# ===========================================================================
# 1) 前置检查
# ===========================================================================
need_cmd gcc "apt install build-essential"
need_cmd make "apt install build-essential"
need_cmd dpkg-deb "apt install dpkg"
need_cmd curl "apt install curl"
need_cmd patch "apt install patch"
need_cmd modinfo "apt install kmod"
need_cmd depmod "apt install kmod"
need_cmd awk
need_cmd grep

[ -d "$KDIR" ] || die "内核头文件不存在：$KDIR
请先安装对应版本的内核头文件：
  apt install linux-headers-${KVER}
（Debian 13 的内核包名带 +deb13-amd64 后缀）"

# ===========================================================================
# 2) 源码
#
# 源码版本必须跟着目标内核走：fetch 脚本用 KVER 推出对应的 Debian 源包版本
# （6.12.113+deb13-amd64 → linux 6.12.113-1）。拿别的 point release 的源码
# 去编这个内核的头文件，编出来的东西就不是「那个内核里在跑的那份驱动」，
# 与本包的意义正好相反。
#
# 完整就跳过重抓：146 次 HTTP 请求不便宜。抓取目录始终保持「未打补丁」的
# 原样（补丁只打在下面的工作副本上），所以重复运行不会把补丁冲掉。
# ===========================================================================
if sh "$SCRIPT_DIR/fetch-rtl8723bs-source.sh" --check "$SRC_DIR" "$KVER"; then
    log "源码树已完整，跳过重新抓取：$SRC_DIR"
else
    log "抓取 rtl8723bs 源码（内核 $KVER → Debian linux 源包）…"
    sh "$SCRIPT_DIR/fetch-rtl8723bs-source.sh" "$SRC_DIR" "$KVER"
fi

SRC_DRIVER_DIR="$SRC_DIR/$DRIVER_REL"
[ -d "$SRC_DRIVER_DIR" ] || die "源码目录结构不对：找不到 $SRC_DRIVER_DIR"
[ -s "$SRC_DRIVER_DIR/Makefile" ] || die "源码目录缺少驱动 Makefile：$SRC_DRIVER_DIR/Makefile"

# ===========================================================================
# 3) 准备可写副本 + 打补丁
#
# 补丁放在 patches/rtl8723bs/，按文件名排序依次应用。
# 任何一个补丁失败都必须立刻退出：留着「半打补丁」的源码树去编译，
# 编出来的东西看着成功、跑起来行为却不可预期，比直接失败糟糕得多。
#
# 补丁打在 WORK_DIR 下的工作副本上，抓取目录保持原样：
# 脚本可以重复执行（不会把上一轮打过的补丁再打一遍），
# 也方便对比「原始源码 / 补丁后源码」。
# ===========================================================================
rm -rf "$WORK_DIR"
TREE_ROOT="$WORK_DIR/tree"
DRIVER_BUILD_DIR="$TREE_ROOT/$DRIVER_REL"
mkdir -p "$(dirname "$DRIVER_BUILD_DIR")"
cp -a "$SRC_DRIVER_DIR" "$DRIVER_BUILD_DIR"

apply_one_patch() {
    local pf="$1" base log strip dir attempt
    base="$(basename "$pf")"
    log="$(mktemp)"
    : >"$log"

    # 依次尝试 (剥离层数|基准目录)：
    #   补丁路径形如 a/drivers/staging/rtl8723bs/... → 源码树根目录 -p1
    #   补丁路径形如 a/os_dep/...                → 驱动目录   -p1
    # 先 --dry-run 再真跑：GNU patch 不是原子的，真跑失败会留下半打补丁的文件。
    for attempt in "1|$TREE_ROOT" "1|$DRIVER_BUILD_DIR" "0|$DRIVER_BUILD_DIR" "0|$TREE_ROOT"; do
        strip="${attempt%%|*}"
        dir="${attempt#*|}"
        printf '\n===== patch -p%s @ %s =====\n' "$strip" "$dir" >>"$log"
        if patch --dry-run --batch --strip="$strip" -d "$dir" <"$pf" >>"$log" 2>&1; then
            if patch --batch --strip="$strip" -d "$dir" <"$pf" >>"$log" 2>&1; then
                log "已应用补丁：${base}（patch -p$strip @ ${dir}）"
                rm -f "$log"
                return 0
            fi
        fi
    done

    printf 'ERROR: 补丁应用失败：%s\n' "$pf" >&2
    printf '       下面是各次尝试的完整输出（含失败 hunk 的上下文）：\n' >&2
    sed -n '1,200p' "$log" >&2
    rm -f "$log"
    # 清掉 patch 留下的 .rej / .orig，别把垃圾带进编译
    find "$TREE_ROOT" -name '*.rej' -o -name '*.orig' 2>/dev/null | while read -r f; do
        rm -f "$f"
    done
    return 1
}

shopt -s nullglob
patch_files=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [ "${#patch_files[@]}" -eq 0 ]; then
    die "没有找到补丁（$PATCH_DIR/*.patch）—— 这个模块的全部价值就是那几个补丁，
直接编上游源码等于编了一份没修过断流问题的驱动，装上去只会让人误以为已经修好了。
请先准备好补丁再构建。"
else
    log "待应用补丁 ${#patch_files[@]} 个："
    for p in "${patch_files[@]}"; do
        printf '  - %s\n' "$(basename "$p")" >&2
    done
    for p in "${patch_files[@]}"; do
        apply_one_patch "$p" || die "补丁 $(basename "$p") 应用失败，已中止构建"
    done
fi

# ===========================================================================
# 4) 生成 out-of-tree 构建目录 + Kbuild 包装 Makefile
# ===========================================================================
BUILD_ROOT="$WORK_DIR/module"
mkdir -p "$BUILD_ROOT"

# 只把源码复制进构建目录：补丁打在工作副本上，构建目录保持干净，
# 免得上一轮的 .o 残留混进这一轮。
for d in core hal include os_dep; do
    cp -a "$DRIVER_BUILD_DIR/$d" "$BUILD_ROOT/$d"
done
cp -a "$DRIVER_BUILD_DIR/Makefile" "$BUILD_ROOT/Makefile.driver-orig"

# 从上游 Makefile 里解析出复合模块的对象列表（r8723bs-y = ...）
# 用 awk 而不是硬编码：上游改了对象列表时，这里自动跟着走。
OBJS_AWK='
/^[A-Za-z0-9_]+-(y|objs)[ \t]*=/ {
    inlist = 1
    sub(/^[A-Za-z0-9_]+-(y|objs)[ \t]*=[ \t]*/, "")
}
inlist {
    line = $0
    n = split(line, w, /[ \t]+/)
    for (i = 1; i <= n; i++) {
        g = w[i]
        gsub(/\\/, "", g)
        if (g ~ /\.o$/) print g
    }
    if (line !~ /\\[ \t]*$/) inlist = 0
}
'
objs="$(awk "$OBJS_AWK" "$BUILD_ROOT/Makefile.driver-orig")"

if [ -z "$objs" ]; then
    die "无法从上游 Makefile 解析出对象列表（r8723bs-y）：$BUILD_ROOT/Makefile.driver-orig"
fi

obj_count="$(printf '%s\n' "$objs" | grep -c .)"
log "上游复合模块对象数：$obj_count"

# 每个 .o 都必须能找到对应的 .c，否则说明抓取或解析出了问题
missing=0
for o in $objs; do
    c="${o%.o}.c"
    if [ ! -f "$BUILD_ROOT/$c" ]; then
        printf 'ERROR: 缺少源文件：%s（对象 %s）\n' "$c" "$o" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || die "源码树不完整，构建中止"

# 生成包装 Makefile
{
    printf '%s\n' "# 由 scripts/build-rtl8723bs-module.sh 自动生成，请勿手改。"
    printf '%s\n' "#"
    printf '%s\n' "# 上游是复合模块：obj-\$(CONFIG_RTL8723BS) := r8723bs.o + r8723bs-y 对象列表。"
    printf '%s\n' "# 这里保持复合模块结构不变，只把模块名换成 ${MOD_NAME}，对象列表原样沿用 ——"
    printf '%s\n' "# 驱动的 C 代码一行都不用改。"
    printf '%s\n' "#"
    printf '%s\n' "# 改名是必须的：树内 r8723bs 与本模块带同一个 SDIO alias"
    printf '%s\n' "# (sdio:c*v024CdB723*)，modprobe 按 alias 加载时两个都会命中。"
    printf '\n'
    printf 'obj-m := %s.o\n\n' "$MOD_NAME"
    printf '%s-y := \\\n' "$MOD_NAME"
    i=0
    for o in $objs; do
        i=$((i + 1))
        if [ "$i" -lt "$obj_count" ]; then
            printf '\t%s \\\n' "$o"
        else
            printf '\t%s\n' "$o"
        fi
    done
    printf '\n'
    printf '%s\n' "# include 路径："
    printf '%s\n' "#   相对路径 —— Kbuild 编译外部模块时工作目录就是本模块目录；"
    printf '%s\n' "#   \$(src)     —— 外部模块构建里 \$(src) 指向本模块根目录。"
    printf '%s\n' "# 两种都写上，任何一种生效即可（上游 Makefile 用的是 \$(src) 形式）。"
    printf '%s\n' "ccflags-y += -Iinclude -Ihal -I\$(src)/include -I\$(src)/hal"
} >"$BUILD_ROOT/Makefile"

log "已生成 Kbuild 包装 Makefile：$BUILD_ROOT/Makefile"

# ===========================================================================
# 5) 编译
# ===========================================================================
log "编译 out-of-tree 模块 $MOD_NAME …"
make -C "$KDIR" M="$BUILD_ROOT" modules

KO="$BUILD_ROOT/$MOD_NAME.ko"
[ -f "$KO" ] || die "编译没有产出 $KO
（检查上面 make 的输出；常见原因是头文件版本与目标内核不匹配）"

# ===========================================================================
# 6) 校验模块
# ===========================================================================
log "校验模块元信息（modinfo）…"

mi_name="$(modinfo -F name "$KO")"
[ "$mi_name" = "$MOD_NAME" ] || die "模块名不对：期望 ${MOD_NAME}，实际 $mi_name"

mi_license="$(modinfo -F license "$KO")"
[ "$mi_license" = "GPL" ] || die "license 不对：期望 GPL，实际 '$mi_license'"

# .modinfo 里的 name= 才是内核认的模块名（内核 module/main.c:
# info->name = get_modinfo(info, "name")），必须单独确认一次
grep -aq "name=$MOD_NAME" "$KO" \
    || die ".modinfo 里没有 name=$MOD_NAME —— 内核会把模块当成 $mi_name 注册"

# alias：SDIO 设备 024c:b723 必须能被 udev/modprobe 认出来
if ! modinfo -F alias "$KO" | grep -qF 'sdio:c*v024CdB723*'; then
    printf 'ERROR: 模块缺少 alias sdio:c*v024CdB723*\n' >&2
    modinfo "$KO" >&2
    die "alias 校验失败"
fi

mi_vermagic="$(modinfo -F vermagic "$KO")"
case "$mi_vermagic" in
    "$KVER"*) : ;;
    *) die "vermagic 与目标内核不匹配：期望 ${KVER}，实际 '$mi_vermagic'" ;;
esac

log "模块校验通过：name=$mi_name license=$mi_license"
log "alias 列表：$(modinfo -F alias "$KO" | tr '\n' ' ')"

# ===========================================================================
# 7) 打包 .deb
# ===========================================================================
PKG_ROOT="$WORK_DIR/pkg"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/DEBIAN"

install -d -m 0755 "$PKG_ROOT/lib/modules/$KVER/extra/rtl8723bs"
install -d -m 0755 "$PKG_ROOT/etc/modprobe.d"
install -d -m 0755 "$PKG_ROOT/lib/systemd/system"
install -d -m 0755 "$PKG_ROOT/usr/share/doc/$PKG_NAME"

install -m 0644 "$KO" "$PKG_ROOT/lib/modules/$KVER/extra/rtl8723bs/$MOD_NAME.ko"

cat >"$PKG_ROOT/etc/modprobe.d/qm1-rtl8723bs.conf" <<EOF
# QM1 内置 Realtek RTL8723BS（SDIO）的驱动选择与参数
#
# 为什么必须 blacklist 树内的 r8723bs：
#   两个模块带同一个 SDIO alias（sdio:c*v024CdB723*），modprobe 按 alias
#   加载时会把所有匹配项都插进内核；树内那个一旦先注册 sdio driver，
#   打补丁的 $MOD_NAME 就再也注册不上去（-EBUSY）。
#   "blacklist r8723bs" 等价于 "alias r8723bs off"；kmod 在解析 alias 时
#   会跳过被 blacklist 的模块，所以 alias 命中后只有 $MOD_NAME 会被加载。
#
# 参数说明（Realtek 私有协议栈，不受 wifi.powersave 控制）：
#   rtw_power_mgnt  0 = PS_MODE_ACTIVE（不休眠）；1 = PS_MODE_MIN（默认，允许省电）
#   rtw_ips_mode    0 = IPS_NONE（关闭空闲省电）；1 = IPS_NORMAL（默认）
#   rtw_smart_ps    0 = 关闭智能省电
#   rtw_bw_mode     0 = 关闭带宽自适应（2.4G 场景固定 20MHz 更稳）
#
# 想退回树内驱动：删掉本文件，再 rmmod $MOD_NAME && modprobe r8723bs
blacklist r8723bs
options $MOD_NAME rtw_power_mgnt=0 rtw_ips_mode=0 rtw_smart_ps=0 rtw_bw_mode=0
EOF

cat >"$PKG_ROOT/lib/systemd/system/qm1-rtl8723bs.service" <<EOF
[Unit]
Description=QM1 内置 RTL8723BS（SDIO）打补丁驱动 $MOD_NAME
Documentation=man:modprobe(8)
After=systemd-modules-load.service
Before=network-pre.target
Wants=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 树内 r8723bs 若已经被加载（先装包后启用服务、或用户手动 modprobe 过），
# 先把它卸掉，否则两个驱动抢同一个 SDIO 设备。
ExecStartPre=-/sbin/modprobe -r r8723bs
ExecStart=/sbin/modprobe $MOD_NAME
ExecStop=-/sbin/modprobe -r $MOD_NAME

[Install]
WantedBy=multi-user.target
EOF

cat >"$PKG_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Section: kernel
Priority: optional
Architecture: $PKG_ARCH
Depends: kmod (>= 1.6.0), systemd
Maintainer: QM1-Debian CI <qm1-debian@users.noreply.github.com>
Description: 打补丁的 out-of-tree RTL8723BS SDIO Wi-Fi 驱动（${MOD_NAME}）
 针对 ASUS QM1（Intel Atom Z3735F）内置 Realtek RTL8723BS（SDIO ID 024c:b723）
 的内核树外驱动模块。以 Debian 13 内核自带的 r8723bs 源码为基础打好补丁，
 编译成改名后的 ${MOD_NAME}，并附 modprobe 配置与 systemd 单元。
 .
 模块只针对内核版本 $KVER 编译，升级内核后需要重新构建。
EOF

cat >"$PKG_ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
KVER='$KVER'

case "\$1" in
    configure)
        # 让 modules.dep / modules.alias 认得新模块
        if command -v depmod >/dev/null 2>&1; then
            depmod -a "\$KVER" || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
            systemctl enable qm1-rtl8723bs.service || true
        fi
        ;;
esac
exit 0
EOF

cat >"$PKG_ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    remove|deconfigure)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now qm1-rtl8723bs.service || true
        fi
        if command -v modprobe >/dev/null 2>&1; then
            modprobe -r r8723bs_qm1 || true
        fi
        ;;
esac
exit 0
EOF

cat >"$PKG_ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
KVER='$KVER'

case "\$1" in
    remove|purge)
        if command -v depmod >/dev/null 2>&1; then
            depmod -a "\$KVER" || true
        fi
        ;;
esac
exit 0
EOF

chmod 0755 "$PKG_ROOT/DEBIAN/postinst" "$PKG_ROOT/DEBIAN/prerm" "$PKG_ROOT/DEBIAN/postrm"

# 附上人读的说明
if [ -f "$SCRIPT_DIR/rtl8723bs-module.README.md" ]; then
    install -m 0644 "$SCRIPT_DIR/rtl8723bs-module.README.md" \
        "$PKG_ROOT/usr/share/doc/$PKG_NAME/README.md"
fi

mkdir -p "$OUT_DIR"
DEB_PATH="$OUT_DIR/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
rm -f "$DEB_PATH"
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB_PATH"

[ -f "$DEB_PATH" ] || die "dpkg-deb 没有产出 $DEB_PATH"

# ===========================================================================
# 8) 摘要
# ===========================================================================
log "构建完成"
{
    echo "模块名    : $MOD_NAME"
    echo "目标内核  : $KVER"
    echo "源码来源  : Debian linux ${KVER%%-*} 的 $DRIVER_REL"
    echo "补丁      : ${#patch_files[@]} 个（${PATCH_DIR}）"
    echo "模块别名  : $(modinfo -F alias "$KO" | tr '\n' ' ')"
    echo "模块参数  : $(modinfo -F parm "$KO" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    echo "安装路径  : /lib/modules/$KVER/extra/rtl8723bs/$MOD_NAME.ko"
    echo "软件包    : $DEB_PATH"
    echo "包大小    : $(du -h "$DEB_PATH" | cut -f1)"
    echo "SHA256    : $(sha256sum "$DEB_PATH" | cut -d' ' -f1)"
} >&2

echo "$DEB_PATH"
