#!/usr/bin/env bash
#
# 出货模块用的上游 rtw88 补丁集，必须能在"钉死的那棵树上"按顺序干净应用。
#
# 这个检查存在的理由：补丁打不上时，模块构建脚本会**回退**到打了补丁的
# staging 模块（那棵树有已知的永久卡死路径），构建不会红，只是打一条
# warning —— 直到镜像守卫那一步才失败，而且失败信息离真正的原因很远。
# 所以这里把"补丁能不能打上"单独拎出来，变成一道**阻断性**的检查：
# 它不需要内核头、不需要编译，几秒钟就能给出确切答案。
#
# 用法：
#   bash scripts/test-upstream-patches.sh
#   bash scripts/test-upstream-patches.sh --sha <commit> --work <目录>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_SCRIPT="$SCRIPT_DIR/build-rtw88-8723bs-module.sh"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/rtw88-upstream}"

SHA=""
WORK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sha)  SHA="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --patch-dir) PATCH_DIR="$2"; shift 2 ;;
        *) echo "用法：$0 [--sha <commit>] [--work <目录>] [--patch-dir <目录>]" >&2; exit 2 ;;
    esac
done

log()  { printf '[upstream-patches] %s\n' "$*"; }
fail() { printf '[upstream-patches] ::error::%s\n' "$*" >&2; exit 1; }

# 版本号必须和构建脚本用的一致 —— 两边分叉的话，测的就不是出货的那棵树。
if [ -z "$SHA" ]; then
    SHA="$(sed -n 's/^UPSTREAM_REF="\([0-9a-f]\{40\}\)".*/\1/p' "$BUILD_SCRIPT" | head -1)"
fi
[ -n "$SHA" ] || fail "在 $BUILD_SCRIPT 里找不到 UPSTREAM_REF"
log "上游树：$SHA"
log "补丁目录：$PATCH_DIR"

# ---------- 1. 补丁路径必须是 rtw88 目录内的相对路径 ----------
#
# 构建脚本把 rtw88 目录里的 .c/.h 平铺到一个目录，再在那个目录里
# `patch -p1`。所以补丁里的路径必须是相对 rtw88 根的短路径
# （a/sdio.c），不能是内核树里的完整路径
# （a/drivers/net/wireless/realtek/rtw88/sdio.c）—— 后者会被剥掉一层
# 之后找不到文件，补丁直接打不上。
for p in "$PATCH_DIR"/000*.patch; do
    [ -f "$p" ] || continue
    if grep -qE '^(diff --git |\+\+\+ |--- )a?/?drivers/net/wireless/realtek/rtw88/' "$p"; then
        fail "$(basename "$p") 里的路径带了内核树前缀；补丁是打在平铺后的 rtw88 目录上的，路径必须相对 rtw88 根"
    fi
done

# ---------- 2. 取钉死那棵树里补丁要碰的文件 ----------
#
# 只取补丁真正涉及的文件：构建脚本只需要那几个文件就能判断补丁能不能打上。
FILES="mac80211.c rtw8723bs.c tx.c sdio.c rtw8723b.c"
BASE_URL="https://raw.githubusercontent.com/torvalds/linux/$SHA/drivers/net/wireless/realtek/rtw88"

if [ -z "$WORK" ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/qm1-upstream-patches.XXXXXX")"
    CLEANUP=1
else
    mkdir -p "$WORK"
    CLEANUP=0
fi
cleanup() { [ "$CLEANUP" = "1" ] && rm -rf "$WORK"; }
trap cleanup EXIT

for f in $FILES; do
    out="$WORK/$f"
    if [ ! -s "$out" ]; then
        ok=0
        for _attempt in 1 2 3; do
            if curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$BASE_URL/$f"; then
                ok=1
                break
            fi
            sleep 3
        done
        [ "$ok" = "1" ] || fail "取不到 $BASE_URL/$f"
    fi
done
log "已取到 $(echo $FILES | wc -w) 个源文件"

# ---------- 3. 按顺序应用 ----------
#
# 必须真的 apply（--dry-run 不会改文件，后面的补丁就会拿旧上下文去试，
# 于是得出"打不上"的假结论）。每一步失败都立刻停。
for p in "$PATCH_DIR"/000*.patch; do
    [ -f "$p" ] || continue
    name="$(basename "$p")"
    if out="$(cd "$WORK" && patch -p1 --batch --forward --no-backup-if-mismatch < "$p" 2>&1)"; then
        log "应用成功：$name"
    else
        printf '%s\n' "$out" >&2
        fail "补丁 $name 打不上（上面是 patch 的原话）"
    fi
done

# ---------- 4. 结果必须符合我们写这份补丁的目的 ----------
check() {  # check <说明> <文件> <正则>
    grep -qE "$3" "$2" || fail "$1（$2 里没找到 $3）"
}
check "8723B 的空间流数没有固定成 1" "$WORK/rtw8723b.c" 'hw_cap\.nss = 1;'
check "8723B 的天线数没有固定成 1" "$WORK/rtw8723b.c" 'hw_cap\.ant_num = 1;'
check "8723B 的信道宽度没有收窄成 20 MHz" "$WORK/rtw8723b.c" 'hw_cap\.bw = BIT\(RTW_CHANNEL_WIDTH_20\);'
if grep -qE 'hw_cap\.bw = .*BIT\(RTW_CHANNEL_WIDTH_40\)' "$WORK/rtw8723b.c"; then
    fail "8723B 仍然会启用 40 MHz —— 这台机的 Wi-Fi 是唯一链路，不能冒这个险"
fi
if grep -q 'channel_invalid' "$WORK/rtw8723b.c"; then
    fail "8723B 仍然在 query_phy_status 里设 channel_invalid —— 接收频率会被写成中心信道，40 MHz 下会被 mac80211 拒收"
fi
check "SDIO 的超长 RX 包守卫不在" "$WORK/sdio.c" 'oversized RX packet'

# RX 状态必须在频率更新之后才拷给 mac80211，否则前面修的频率对不上。
_rx_line="$(grep -n 'IEEE80211_SKB_RXCB(skb) = \*rx_status' "$WORK/sdio.c" | head -1 | cut -d: -f1 || true)"
_freq_line="$(grep -n 'rtw_update_rx_freq_for_invalid' "$WORK/sdio.c" | head -1 | cut -d: -f1 || true)"
[ -n "$_rx_line" ] || fail "sdio.c 里找不到 RX 状态的拷贝"
[ -n "$_freq_line" ] || fail "sdio.c 里找不到 rtw_update_rx_freq_for_invalid"
if [ "$_rx_line" -le "$_freq_line" ]; then
    fail "RX 状态的拷贝（第 $_rx_line 行）在频率更新（第 $_freq_line 行）之前 —— 修好的频率到不了 mac80211"
fi

log "补丁集全部应用成功，结果也符合预期"
