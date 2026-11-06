#!/usr/bin/env bash
# build-bootloaders.sh — 构建 IA32(32位) 与 x86_64(64位) 两套 EFI 引导器
#
# 为什么需要：
#   某些 x86 设备 CPU 支持 64 位，但 UEFI 固件只有 32 位（IA32 EFI），只能加载
#   PE32 格式的 .efi，无法加载 PE32+（x86_64 官方 grubx64.efi 即 PE32+）。
#   解法是用 GRUB 的 i386-efi 平台构建一个 32 位引导器（PE32），由它加载 64 位内核。
#   同时输出 64 位引导器（PE32+），使同一块启动介质同时兼容 32 位与 64 位固件。
#
# 关键事实：64 位 UEFI 固件同样能加载 32 位 PE32 应用，
#           因此 32 位引导器对两种固件都安全 —— "固件位宽未知"由此被介质层吸收。
#
# 用法：
#   bash scripts/build-bootloaders.sh [输出目录]        # 默认 build/bootloaders
#   FETCH_DEBIAN=1 bash scripts/build-bootloaders.sh    # 本机缺模块时从 Debian 拉同版本包
#   ALL_MODULES=1 bash scripts/build-bootloaders.sh      # 内嵌整平台模块集（上游案例做法）
#
# 产物：
#   grub2ia32.efi   PE32  / Intel 80386  → 部署名 /EFI/BOOT/BOOTIA32.EFI
#   grubx64.efi     PE32+ / x86-64       → 部署名 /EFI/BOOT/BOOTX64.EFI
#   SHA256SUMS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

OUT_DIR="${1:-build/bootloaders}"

# 精简模块集：足以完成"读 ESP → 找内核 → 加载内核 → 进菜单"。
# 注意：不存在独立的 linuxefi 模块 —— EFI handover 支持已并入 linux 模块
#（Debian trixie grub2 的 i386-efi 模块集共 270 个，其中无 linuxefi.mod）。
MODS="part_gpt part_msdos fat ext2 normal linux search search_fs_uuid search_label chain terminal"
ALL_MODULES="${ALL_MODULES:-0}"
PREFIX="/EFI/BOOT"                 # 运行时 GRUB 寻找自身模块/配置的目录前缀
DEB_SUITE="${DEB_SUITE:-trixie}"

need_cmd file "用于校验产物形态"

# ---------- 1. 定位 grub-mkimage ----------
GRUB_MKIMAGE=""
for c in grub-mkimage grub2-mkimage; do
    if command -v "$c" >/dev/null 2>&1; then GRUB_MKIMAGE="$(command -v "$c")"; break; fi
done
[ -n "$GRUB_MKIMAGE" ] || die "找不到 grub-mkimage（Debian/Ubuntu: apt install grub2-common）"
log "grub-mkimage: $GRUB_MKIMAGE ($("$GRUB_MKIMAGE" --version | head -1))"

# ---------- 2. 定位两套模块目录 ----------
# grub-mkimage 与 .mod 必须来自同一 GRUB 版本，否则报"模块不兼容"。
# 系统安装的 grub2-common 与 grub-efi-*-bin 天然同版本，优先使用。
IA32_MODDIR=""
AMD64_MODDIR=""
for d in /usr/lib/grub/i386-efi /usr/lib/grub/i386-efi64; do
    [ -d "$d" ] && { IA32_MODDIR="$d"; break; }
done
for d in /usr/lib/grub/x86_64-efi /usr/lib/grub/x86_64-efi64; do
    [ -d "$d" ] && { AMD64_MODDIR="$d"; break; }
done

# ---------- 3. 缺模块时：从 Debian 同套件拉同版本包 ----------
if { [ -z "$IA32_MODDIR" ] || [ -z "$AMD64_MODDIR" ]; } && [ "${FETCH_DEBIAN:-0}" = "1" ]; then
    log "系统模块不全，从 Debian $DEB_SUITE 拉取同版本包"
    need_cmd dpkg-deb "用于解包 .deb"
    need_cmd curl "用于下载 .deb"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    fetch_pkg() {   # $1=包名 $2=架构
        local pkg="$1" arch="$2" url
        # ★ awk 里不要用 exit：Packages.gz 解出来有好几十 MB，awk 提前退出会让
        #   gzip 收到 SIGPIPE（141），而本脚本 set -o pipefail ⇒ 整条管道被判失败
        #   ⇒ 取包这一段必然挂。读完整份索引再打印最后一条匹配即可。
        url="$(curl -fsSL "https://deb.debian.org/debian/dists/$DEB_SUITE/main/binary-$arch/Packages.gz" \
               | gzip -dc | awk -v p="$pkg" '$1=="Package:"{cur=$2} $1=="Filename:"&&cur==p{last=$2} END{print last}')"
        [ -n "$url" ] || die "在 $DEB_SUITE/$arch 索引里找不到 $pkg"
        curl -fsSL -o "$TMP/$(basename "$url")" "https://deb.debian.org/debian/$url"
        dpkg-deb -x "$TMP/$(basename "$url")" "$TMP/root"
        log "已取 $pkg ($arch)"
    }
    fetch_pkg grub2-common amd64          # 提供 grub-mkimage
    fetch_pkg grub-efi-ia32-bin i386      # 提供 i386-efi 模块
    fetch_pkg grub-efi-amd64-bin amd64    # 提供 x86_64-efi 模块
    # 用 linux.mod 定位模块目录（linuxefi.mod 不存在，见上文说明）
    [ -z "$IA32_MODDIR" ]   && IA32_MODDIR="$(dirname "$(find "$TMP/root" -name 'linux.mod' -path '*i386-efi*' | head -1)")"
    [ -z "$AMD64_MODDIR" ] && AMD64_MODDIR="$(dirname "$(find "$TMP/root" -name 'linux.mod' -path '*x86_64-efi*' | head -1)")"
    # 优先用同套件的 grub-mkimage，保证与模块同版本
    if [ -x "$TMP/root/usr/bin/grub-mkimage" ]; then
        GRUB_MKIMAGE="$TMP/root/usr/bin/grub-mkimage"
        log "改用同套件 grub-mkimage: $GRUB_MKIMAGE"
    fi
fi

[ -n "$IA32_MODDIR" ]   || die "找不到 i386-efi 模块目录（Debian/Ubuntu: dpkg --add-architecture i386 && apt install grub-efi-ia32-bin:i386；或设 FETCH_DEBIAN=1）"
[ -n "$AMD64_MODDIR" ] || die "找不到 x86_64-efi 模块目录（Debian/Ubuntu: apt install grub-efi-amd64-bin）"
log "i386-efi   模块: $IA32_MODDIR"
log "x86_64-efi 模块: $AMD64_MODDIR"

# ---------- 4. 组装 ----------
mkdir -p "$OUT_DIR"

build_one() {   # $1=平台 $2=模块目录 $3=输出文件
    local plat="$1" moddir="$2" out="$3"
    local args=() m f
    if [ "$ALL_MODULES" = "1" ]; then
        while IFS= read -r f; do args+=("$f"); done < <(find "$moddir" -maxdepth 1 -name '*.mod' | sort)
        log "内嵌整平台模块集：${#args[@]} 个（${plat}）"
    else
        for m in $MODS; do
            f="$moddir/$m.mod"
            [ -f "$f" ] || die "缺少模块 $f —— 模块集随 GRUB 版本变化，先核对本机模块目录再定清单"
            args+=("$f")
        done
    fi
    log "组装 $plat -> $out"
    "$GRUB_MKIMAGE" -C xz -O "$plat" -o "$out" -p "$PREFIX" "${args[@]}"
}

build_one i386-efi   "$IA32_MODDIR"   "$OUT_DIR/grub2ia32.efi"
build_one x86_64-efi "$AMD64_MODDIR" "$OUT_DIR/grubx64.efi"

# ---------- 5. 校验 ----------
# file 的措辞随版本而变："Intel 80386"（Debian 常见）与 "Intel i386"（部分发行版）都要接受
file "$OUT_DIR/grub2ia32.efi" | tee "$OUT_DIR/file-report.txt"
file "$OUT_DIR/grubx64.efi"  | tee -a "$OUT_DIR/file-report.txt"

f32="$(file -b "$OUT_DIR/grub2ia32.efi")"
f64="$(file -b "$OUT_DIR/grubx64.efi")"

case "$f32" in *"PE32+"*) die "grub2ia32.efi 竟是 PE32+，32 位固件不会加载它" ;; esac
case "$f32" in *"PE32"*) ;; *) die "grub2ia32.efi 形态不对（非 PE32）：$f32" ;; esac
case "$f32" in *"Intel 80386"*|*"Intel i386"*) ;; *) die "grub2ia32.efi 形态不对（非 32 位 x86）：$f32" ;; esac

case "$f64" in *"PE32+"*) ;; *) die "grubx64.efi 形态不对（非 PE32+）：$f64" ;; esac
case "$f64" in *"x86-64"*) ;; *) die "grubx64.efi 形态不对（非 x86-64）：$f64" ;; esac

# 独立校验（不依赖 file 魔数）：grub-file 能识别 EFI 镜像类型
if command -v grub-file >/dev/null 2>&1; then
    grub-file --is-i386-efi   "$OUT_DIR/grub2ia32.efi" || die "grub-file 判定 grub2ia32.efi 不是 i386-efi 镜像"
    grub-file --is-x86_64-efi "$OUT_DIR/grubx64.efi"  || die "grub-file 判定 grubx64.efi 不是 x86_64-efi 镜像"
    log "grub-file 独立校验通过"
else
    log "提示：未找到 grub-file，跳过独立校验"
fi

( cd "$OUT_DIR" && sha256sum grub2ia32.efi grubx64.efi > SHA256SUMS )
cat "$OUT_DIR/SHA256SUMS"
log "完成：$OUT_DIR/grub2ia32.efi（PE32/IA32） $OUT_DIR/grubx64.efi（PE32+/x86-64）"
