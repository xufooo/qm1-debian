#!/usr/bin/env bash
# fetch-rtw8723b-firmware.sh — 取 RTL8723BS 的 rtw88 固件 blob
#
# 背景：
#   rtw88 的 RTL8723BS 支持（上游 Linux 7.4 引入）需要固件
#   /lib/firmware/rtw88/rtw8723b_fw.bin。
#   Debian 13 (trixie) 的 firmware-realtek 里**没有**这个 blob
#   （实测 filelist：只有 rtw8703b/rtw8723d/rtw8812a/rtw8814a/rtw8821a/
#   rtw8821c/rtw8822b/rtw8822c/rtw89*），而 Debian sid 的 firmware-realtek
#   已经有了（实测同样查 filelist 命中 rtw88/rtw8723b_fw.bin）。
#   所以这里的做法是：从 **sid** 的 firmware-realtek 里只取这一个文件，
#   并用 sid 的 Packages 索引里的 SHA256 校验 .deb 本身。
#
# 为什么不直接用 GitHub 上那份：apt 索引能给出可校验的哈希与版本号，
# 供应链上比「从某个仓库随手拿一个 bin」干净；仓库自带那份只作兜底。
#
# 用法：
#   bash scripts/fetch-rtw8723b-firmware.sh [--out-dir DIR] [--mirror URL] [--suite sid]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/rtw8723b-fw}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SUITE="${SUITE:-sid}"
PKG="firmware-realtek"
# 目标文件在包内的相对路径
BLOB_REL="lib/firmware/rtw88/rtw8723b_fw.bin"
BLOB_REL_WOW="lib/firmware/rtw88/rtw8723b_wow_fw.bin"

while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --mirror)  MIRROR="$2"; shift 2 ;;
        --suite)   SUITE="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

need_cmd curl "apt install curl"
need_cmd xz
need_cmd dpkg-deb "apt install dpkg"
need_cmd sha256sum
need_cmd awk
need_cmd grep

mkdir -p "$OUT_DIR"
WORK="$OUT_DIR/.work"
rm -rf "$WORK"
mkdir -p "$WORK"

log "从 $SUITE 的 $PKG 取 RTL8723BS 固件（$MIRROR）"

# ---------------------------------------------------------------------------
# 1) 从 apt 索引里定位 .deb 的路径与哈希
# ---------------------------------------------------------------------------
IDX="$WORK/Packages.xz"
log "下载索引：$MIRROR/dists/$SUITE/main/binary-all/Packages.xz"
curl -fsSL --max-time 300 "$MIRROR/dists/$SUITE/main/binary-all/Packages.xz" -o "$IDX"

# 只取 firmware-realtek 那个 stanza 的 Filename / SHA256 / Version
read -r DEB_PATH DEB_SHA DEB_VER <<EOF
$(xzcat "$IDX" | awk -v pkg="$PKG" '
    $1 == "Package:" { inpkg = ($2 == pkg) }
    inpkg && $1 == "Filename:"  { fn = $2 }
    inpkg && $1 == "SHA256:"    { sh = $2 }
    inpkg && $1 == "Version:"   { ver = $2 }
    inpkg && /^$/ {
        if (fn != "") { print fn, sh, ver; exit }
        fn = ""; sh = ""; ver = ""
    }
    END { if (fn != "") print fn, sh, ver }
')
EOF

[ -n "$DEB_PATH" ] || die "在 $SUITE 索引里找不到 $PKG（组件可能变了，检查 --suite/--mirror）"
[ -n "$DEB_SHA" ]  || die "$PKG 在索引里没有 SHA256（索引异常）"
log "$PKG $DEB_VER → $DEB_PATH"

# ---------------------------------------------------------------------------
# 2) 下载并校验 .deb
# ---------------------------------------------------------------------------
DEB="$WORK/$(basename "$DEB_PATH")"
log "下载 .deb …"
curl -fsSL --max-time 600 "$MIRROR/$DEB_PATH" -o "$DEB"

GOT_SHA="$(sha256sum "$DEB" | cut -d' ' -f1)"
if [ "$GOT_SHA" != "$DEB_SHA" ]; then
    die ".deb 校验失败：期望 $DEB_SHA，实际 $GOT_SHA"
fi
log ".deb sha256 校验通过"

# ---------------------------------------------------------------------------
# 3) 解包并取出目标 blob
# ---------------------------------------------------------------------------
EXDIR="$WORK/x"
mkdir -p "$EXDIR"
dpkg-deb -x "$DEB" "$EXDIR"

[ -f "$EXDIR/$BLOB_REL" ] || die "$PKG 里没有 $BLOB_REL（包内容变了？）"
install -m 0644 "$EXDIR/$BLOB_REL" "$OUT_DIR/rtw8723b_fw.bin"

if [ -f "$EXDIR/$BLOB_REL_WOW" ]; then
    install -m 0644 "$EXDIR/$BLOB_REL_WOW" "$OUT_DIR/rtw8723b_wow_fw.bin"
fi

{
    echo "# 来源：$MIRROR  $SUITE  $PKG $DEB_VER"
    echo "# .deb 路径：$DEB_PATH"
    echo "# .deb sha256：$DEB_SHA"
    echo "# blob 路径：$BLOB_REL"
    ( cd "$OUT_DIR" && sha256sum rtw8723b_fw.bin ) >>"$OUT_DIR/SOURCE.txt"
    if [ -f "$OUT_DIR/rtw8723b_wow_fw.bin" ]; then
        ( cd "$OUT_DIR" && sha256sum rtw8723b_wow_fw.bin ) >>"$OUT_DIR/SOURCE.txt"
    fi
} >"$OUT_DIR/SOURCE.txt"

rm -rf "$WORK"

log "固件就绪：$OUT_DIR/rtw8723b_fw.bin"
cat "$OUT_DIR/SOURCE.txt" >&2
