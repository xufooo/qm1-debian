#!/bin/sh
# fetch-rtl8723bs-source.sh — 逐文件抓取 Debian 内核里的 rtl8723bs 驱动子树
#
# 为什么用 sources.debian.org 的 /data/ 接口逐文件抓：
#   * Debian 不提供该目录的 tarball 直链，逐文件抓是唯一稳定的取法；
#   * 逐文件抓可以给每个文件做体检（空文件 / HTML 错误页），
#     避免把 Debian 的 404 页面当成源码写进源码树 —— 那种坑极难排查：
#     编译报的是 C 语法错误，根因却是抓到了 <html>。
#
# 为什么不用上游 git 仓库：
#   * 目标是「目标内核（uname -r 对应的那个 point release）里实际在跑的那份驱动」，
#     必须和发行版内核的 .ko 同源，否则 ABI/行为差异无从追溯；
#   * sources.debian.org 是只读镜像，CI 里拉取稳定、限速友好。
#
# 用法：
#   scripts/fetch-rtl8723bs-source.sh [--check] [输出目录] [内核版本]
#
#   --check       只检查输出目录里的源码树是否完整，不抓取。
#                 完整返回 0，缺失返回 1 —— 供 build 脚本做「跳过重抓」的判断。
#   输出目录      默认 build/rtl8723bs-src
#   内核版本      point release（6.12.113）或 ABI 名（6.12.113+deb13-amd64）。
#                 默认 6.12.113。也可以用环境变量 KERNEL_VERSION 覆盖。
#
# 产物布局（保留内核源码树里的相对路径）：
#   <输出目录>/drivers/staging/rtl8723bs/{Kconfig,Makefile,TODO,core,hal,include,os_dep}
#
# 该目录可以直接：
#   * 覆盖到内核源码树的同一路径下，做 in-tree 编译；
#   * 作为 out-of-tree 模块的源码根，由 build-rtl8723bs-module.sh 编译。
set -eu

PACKAGE="linux"
SUBDIR="drivers/staging/rtl8723bs"
API_BASE="https://sources.debian.org/api/src/$PACKAGE"
# /data/ 端点走的是 pool 布局：主目录取首字母 + 源包名（linux → l/linux）。
# 少了这一层前缀就是 404，而且返回的是 HTML 页面，不是源码。
POOL_DIR="$(printf '%s' "$PACKAGE" | cut -c1)/$PACKAGE"
DATA_BASE="https://sources.debian.org/data/main/$POOL_DIR"

# 默认目标内核：与 scripts/build-rootfs.sh --kernel-version 6.12.113 一致
DEFAULT_KERNEL_VERSION="6.12.113"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
    shift
fi

OUT_DIR="${1:-build/rtl8723bs-src}"
KERNEL_VERSION="${2:-${KERNEL_VERSION:-$DEFAULT_KERNEL_VERSION}}"

# ---------------------------------------------------------------------------
# 内核版本 → Debian 源包版本
#
# 内核 ABI 名（uname -r）形如 6.12.113+deb13-amd64，Debian 源包版本形如
# 6.12.113-1。两者的 upstream 部分都是 6.12.113，但源包的修订号（-1/-2…）
# 只有问 sources.debian.org 才知道 —— 猜错了就是 404。
#
# 为什么必须跟着目标内核走：
#   源码和目标内核头文件必须来自同一个 point release。用 6.12.113 的源码
#   去编 6.12.107 的头文件，编出来的东西可能在 C 层面就编不过，
#   就算编过了也不是「那个内核里在跑的那份驱动」，与本包的意义相反。
# ---------------------------------------------------------------------------
POINT_VERSION="$(printf '%s' "$KERNEL_VERSION" | sed 's/+.*$//')"

resolve_source_version() {
    _rv_versions="$1"
    _rv_point="$2"

    # 源包版本形如 <upstream>-<revision>，取最后一个 '-' 之前的部分作为 upstream
    _rv_match="$(printf '%s\n' "$_rv_versions" | awk -v p="$_rv_point" '
        {
            v = $0
            i = length(v)
            while (i > 0 && substr(v, i, 1) != "-") i--
            if (i > 1 && substr(v, 1, i - 1) == p) print v
        }' | sort -V | tail -1)"

    if [ -n "$_rv_match" ]; then
        printf '%s' "$_rv_match"
        return 0
    fi
    return 1
}

if ! command -v curl >/dev/null 2>&1; then
    printf '缺少命令：curl（apt install curl）\n' >&2
    exit 1
fi

ALL_VERSIONS=""
if ALL_VERSIONS="$(curl --fail --silent --show-error --location \
        --retry 2 --connect-timeout 20 --max-time 90 \
        "$API_BASE/" 2>/dev/null | grep -o '"version":"[^"]*"' | sed 's/^"version":"//; s/"$//')" \
    && [ -n "$ALL_VERSIONS" ]; then
    :
else
    ALL_VERSIONS=""
    printf 'WARN: 取不到 %s 的源包版本列表（sources.debian.org 不可达？）\n' "$PACKAGE" >&2
fi

if VERSION="$(resolve_source_version "$ALL_VERSIONS" "$POINT_VERSION")"; then
    printf '内核版本 %s → Debian 源包版本 %s\n' "$KERNEL_VERSION" "$VERSION" >&2
else
    VERSION="$POINT_VERSION-1"
    printf 'WARN: 源包列表里没有 %s（上游 point release），按 %s 尝试\n' "$POINT_VERSION" "$VERSION" >&2
fi

BASE_URL="$DATA_BASE/$VERSION/$SUBDIR"

# ---------------------------------------------------------------------------
# 文件清单
#
# 首选：直接问 sources.debian.org 的 API 要这个目录的真实文件清单。
#   理由：目标内核的 point release 会滚动，不同 point release 里这个目录
#   的内容原则上可能不同；硬编码的清单只对写它的那一版负责。
#
# 兜底：内嵌一份 linux 6.12.113-1 的完整清单（146 个文件），
#   API 不可达时用它 —— 抓取必须能在没有 API 的情况下跑通。
#
# 注意：不要凭印象写这份清单。该目录里既有 .c 也有 .h，还混着 Hal*/odm*
# 这类大小写敏感的文件名；漏掉任何一个 .h 都会让编译在某个 #include 处
# 莫名其妙地失败，而 .c 漏掉则会在链接阶段报 undefined symbol。
# 清单与上游 Makefile 的 r8723bs-y 对象列表一一对应（.c 是 .o 的来源）。
# ---------------------------------------------------------------------------
TOP_FILES="Kconfig Makefile TODO"

CORE_FILES="rtw_ap.c rtw_btcoex.c rtw_cmd.c rtw_efuse.c rtw_ieee80211.c rtw_io.c
rtw_ioctl_set.c rtw_mlme.c rtw_mlme_ext.c rtw_pwrctrl.c rtw_recv.c rtw_security.c
rtw_sta_mgt.c rtw_wlan_util.c rtw_xmit.c"

HAL_FILES="Hal8723BReg.h HalBtc8723b1Ant.c HalBtc8723b1Ant.h HalBtc8723b2Ant.c
HalBtc8723b2Ant.h HalBtcOutSrc.h HalHWImg8723B_BB.c HalHWImg8723B_BB.h
HalHWImg8723B_MAC.c HalHWImg8723B_MAC.h HalHWImg8723B_RF.c HalHWImg8723B_RF.h
HalPhyRf.c HalPhyRf.h HalPhyRf_8723B.c HalPhyRf_8723B.h HalPwrSeqCmd.c Mp_Precomp.h
hal_btcoex.c hal_com.c hal_com_phycfg.c hal_intf.c hal_pwr_seq.c hal_sdio.c odm.c odm.h
odm_CfoTracking.c odm_CfoTracking.h odm_DIG.c odm_DIG.h odm_DynamicBBPowerSaving.c
odm_DynamicBBPowerSaving.h odm_DynamicTxPower.c odm_DynamicTxPower.h
odm_EdcaTurboCheck.c odm_EdcaTurboCheck.h odm_HWConfig.c odm_HWConfig.h
odm_RegConfig8723B.c odm_RegConfig8723B.h odm_RegDefine11N.h odm_interface.h
odm_precomp.h odm_reg.h odm_types.h rtl8723b_cmd.c rtl8723b_dm.c rtl8723b_hal_init.c
rtl8723b_phycfg.c rtl8723b_rf6052.c rtl8723b_rxdesc.c rtl8723bs_recv.c
rtl8723bs_xmit.c sdio_halinit.c sdio_ops.c"

INCLUDE_FILES="Hal8192CPhyReg.h HalPwrSeqCmd.h HalVerDef.h basic_types.h cmd_osdep.h
drv_types.h drv_types_sdio.h hal_btcoex.h hal_com.h hal_com_h2c.h hal_com_phycfg.h
hal_com_reg.h hal_data.h hal_intf.h hal_pg.h hal_phy.h hal_phy_cfg.h hal_phy_reg.h
hal_pwr_seq.h hal_sdio.h ieee80211.h ioctl_cfg80211.h mlme_osdep.h osdep_intf.h
osdep_service.h osdep_service_linux.h recv_osdep.h rtl8192c_recv.h rtl8723b_cmd.h
rtl8723b_dm.h rtl8723b_hal.h rtl8723b_recv.h rtl8723b_rf.h rtl8723b_spec.h
rtl8723b_xmit.h rtw_ap.h rtw_btcoex.h rtw_byteorder.h rtw_cmd.h rtw_eeprom.h rtw_efuse.h
rtw_event.h rtw_ht.h rtw_io.h rtw_ioctl_set.h rtw_mlme.h rtw_mlme_ext.h rtw_mp.h
rtw_pwrctrl.h rtw_qos.h rtw_recv.h rtw_rf.h rtw_security.h rtw_version.h
rtw_wifi_regd.h rtw_xmit.h sdio_hal.h sdio_ops.h sdio_ops_linux.h sta_info.h wifi.h
wlan_bssdef.h xmit_osdep.h"

OS_DEP_FILES="ioctl_cfg80211.c ioctl_linux.c mlme_linux.c os_intfs.c osdep_service.c
recv_linux.c sdio_intf.c sdio_ops_linux.c wifi_regd.c xmit_linux.c"

FALLBACK_COUNT=146

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

LIST_FILE="$TMP_DIR/filelist.txt"
: >"$LIST_FILE"

# ---------------------------------------------------------------------------
# API 清单
#
# sources.debian.org 的目录 API 返回一行 JSON，条目形如
#   {"hidden":false,"name":"Kconfig",...,"type":"file"}
# 没有 jq，所以按 '{"hidden":' 切行，再用 sed 抓 name 与 type。
# type 取最后一个匹配项：stat 里也有一个 "type"（文件类型 '-'），
# 但它不匹配 file|directory，所以不会误取。
# ---------------------------------------------------------------------------
api_list_dir() {
    _al_dir="$1"
    _al_url="$API_BASE/$VERSION/$_al_dir/"
    # 用 awk 而不是 sed 切 JSON：BSD sed 的替换里 \n 不表示换行，
    # macOS 上会把整个响应当成一行，后面就全错了。awk 的 "\n" 是可移植的。
    curl --fail --silent --show-error --location \
        --retry 2 --connect-timeout 20 --max-time 90 \
        "$_al_url" 2>/dev/null \
        | awk '
            {
                gsub(/\},\{"hidden":/, "\n")
                n = split($0, parts, "\n")
                for (i = 1; i <= n; i++) {
                    p = parts[i]
                    nm = ""
                    if (match(p, /"name":"[^"]*"/))
                        nm = substr(p, RSTART + 8, RLENGTH - 9)
                    if (nm != "" && match(p, /"type":"(file|directory)"/))
                        print substr(p, RSTART + 8, RLENGTH - 9), nm
                }
            }'
}

# 广度优先遍历，避免递归里的 while 抢 stdin
api_collect() {
    _ac_out="$1"
    _ac_queue="$SUBDIR"
    : >"$TMP_DIR/one_dir.txt"
    while [ -n "$_ac_queue" ]; do
        _ac_head="${_ac_queue%% *}"
        if [ "$_ac_head" = "$_ac_queue" ]; then
            _ac_queue=""
        else
            _ac_queue="${_ac_queue#* }"
        fi
        api_list_dir "$_ac_head" >"$TMP_DIR/one_dir.txt" || return 1
        while read -r _ac_type _ac_name; do
            [ -n "$_ac_type" ] || continue
            _ac_path="${_ac_head}/${_ac_name}"
            if [ "$_ac_type" = "file" ]; then
                printf '%s\n' "${_ac_path#"$SUBDIR"/}" >>"$_ac_out"
            else
                _ac_queue="${_ac_queue}${_ac_queue:+ }$_ac_path"
            fi
        done <"$TMP_DIR/one_dir.txt"
    done
    return 0
}

if api_collect "$LIST_FILE" && [ -s "$LIST_FILE" ]; then
    LIST_SOURCE="sources.debian.org API"
else
    printf 'WARN: API 取不到目录清单，改用内嵌清单（对应 linux %s）\n' "$DEFAULT_KERNEL_VERSION" >&2
    : >"$LIST_FILE"
    for f in $TOP_FILES; do printf '%s\n' "$f" >>"$LIST_FILE"; done
    for f in $CORE_FILES; do printf '%s\n' "core/$f" >>"$LIST_FILE"; done
    for f in $HAL_FILES; do printf '%s\n' "hal/$f" >>"$LIST_FILE"; done
    for f in $INCLUDE_FILES; do printf '%s\n' "include/$f" >>"$LIST_FILE"; done
    for f in $OS_DEP_FILES; do printf '%s\n' "os_dep/$f" >>"$LIST_FILE"; done
    LIST_SOURCE="内嵌清单"
    _fb_count="$(grep -c . "$LIST_FILE" || true)"
    if [ "$_fb_count" -ne "$FALLBACK_COUNT" ]; then
        printf 'ERROR: 内嵌清单数量不对（期望 %s，实际 %s）\n' "$FALLBACK_COUNT" "$_fb_count" >&2
        exit 1
    fi
fi

EXPECTED_COUNT="$(grep -c . "$LIST_FILE" || true)"
[ -n "$EXPECTED_COUNT" ] || EXPECTED_COUNT=0

if [ "$EXPECTED_COUNT" -eq 0 ]; then
    printf 'ERROR: 文件清单为空，无法继续\n' >&2
    exit 1
fi

DEST_ROOT="$OUT_DIR/$SUBDIR"

# ---------------------------------------------------------------------------
# --check：只体检，不抓取
#
# build 脚本用它判断「源码树是不是已经完整」——完整就跳过重抓。
# 判据：清单里每个文件都在、且非空；驱动 Makefile 存在且非空。
# ---------------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    _ck_missing=0
    while read -r _ck_rel; do
        [ -n "$_ck_rel" ] || continue
        if [ ! -s "$DEST_ROOT/$_ck_rel" ]; then
            printf '缺失或为空：%s\n' "$_ck_rel" >&2
            _ck_missing=$((_ck_missing + 1))
        fi
    done <"$LIST_FILE"
    if [ "$_ck_missing" -ne 0 ]; then
        printf '源码树不完整：%s 个文件缺失或为空\n' "$_ck_missing" >&2
        exit 1
    fi
    if [ ! -s "$DEST_ROOT/Makefile" ]; then
        printf '源码树不完整：缺少驱动 Makefile\n' >&2
        exit 1
    fi
    printf '源码树完整：%s 个文件（清单来源：%s）\n' "$EXPECTED_COUNT" "$LIST_SOURCE" >&2
    exit 0
fi

# 每次都重新抓：半成品目录比没有目录更危险（残留的旧文件会让编译"看起来成功"）
rm -rf "$DEST_ROOT"
mkdir -p "$DEST_ROOT"

failed=0
total=0

# fetch_one <相对路径>
#
# 失败要报清楚是哪一步坏了：网络失败 / 内容为空 / 拿到的是 HTML 错误页，
# 三种情况的排查方向完全不同。
fetch_one() {
    rel="$1"
    dest="$DEST_ROOT/$rel"
    tmp="$dest.part"

    mkdir -p "$(dirname "$dest")"
    rm -f "$tmp"

    if ! curl --fail --silent --show-error --location \
              --retry 3 --retry-delay 2 \
              --connect-timeout 30 --max-time 180 \
              -o "$tmp" "$BASE_URL/$rel"; then
        printf 'ERROR: 下载失败：%s\n' "$rel" >&2
        rm -f "$tmp"
        return 1
    fi

    if [ ! -s "$tmp" ]; then
        printf 'ERROR: 下载内容为空：%s\n' "$rel" >&2
        rm -f "$tmp"
        return 1
    fi

    # Debian 的 404 页面带 <!DOCTYPE html> / </html>，绝不能当成源码存下来
    if grep -qiE '<!doctype html|</html>' "$tmp"; then
        printf 'ERROR: 抓到的是 HTML 页面而不是源码：%s\n' "$rel" >&2
        printf '       （Debian 上该路径可能已不存在，源包版本 %s 是否正确？）\n' "$VERSION" >&2
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    return 0
}

while read -r rel; do
    [ -n "$rel" ] || continue
    total=$((total + 1))
    fetch_one "$rel" || failed=$((failed + 1))
done <"$LIST_FILE"

if [ "$failed" -ne 0 ]; then
    printf 'ERROR: 共 %s/%s 个文件抓取失败，未生成可用的源码树\n' "$failed" "$total" >&2
    exit 1
fi

if [ "$total" -ne "$EXPECTED_COUNT" ]; then
    printf 'ERROR: 文件清单数量不符（期望 %s，实际 %s）\n' "$EXPECTED_COUNT" "$total" >&2
    exit 1
fi

# Makefile 是编译入口，必须存在且非空
if [ ! -s "$DEST_ROOT/Makefile" ]; then
    printf 'ERROR: 缺少驱动 Makefile：%s\n' "$DEST_ROOT/Makefile" >&2
    exit 1
fi

printf '已抓取 %s 个文件 → %s（源包 %s，清单来源：%s）\n' \
    "$total" "$DEST_ROOT" "$VERSION" "$LIST_SOURCE"
