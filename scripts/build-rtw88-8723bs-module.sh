#!/usr/bin/env bash
# ============================================================================
# build-rtw88-8723bs-module.sh — build the RTL8723BS Wi-Fi driver out of tree
#
# Why this exists
# ---------------
# The QM1 carries a Realtek RTL8723BS combo (SDIO Wi-Fi, UART Bluetooth).
# Debian 13 ships the obsolete staging driver "r8723bs" for it.  That driver
# can wedge permanently: a TX worker that is never kicked again, an SDIO TX
# wait without a timeout and unbalanced TX completions.
#
# Upstream fixed this properly: Linux (7.4 merge window) moved the RTL8723B /
# RTL8723BS support into the rtw88 driver:
#   d726c70ce082  wifi: rtw88: 8723b: add the RTL8723B chip driver
#   269946cba92e  rtw88: 8723bs: add the RTL8723BS SDIO bind
#   b2d251aa7f16  rtw88: 8723bs: enable building…
#   c520f3af7df4  staging: rtl8723bs: remove the obsolete driver
# No distribution kernel we can install on the QM1 carries that code yet, so
# the chip driver is built as an out-of-tree module against the kernel that
# goes into the image.
#
# Three sources are supported:
#   upstream        the upstream rtw88 chip driver, compiled against the rtw88
#                   headers of the target kernel series (v6.12)
#   upstream-full   the *whole* upstream rtw88 tree of --upstream-ref (master),
#                   built as out-of-tree modules against the target kernel.
#                   This is the root-cause path: upstream restructured rtw88
#                   (main.c split into fw.c/efuse.c/mac80211.c/... and the
#                   8723b chip driver moved to the new core API), so mixing
#                   upstream chip files with the old core headers cannot
#                   work -- the whole tree has to come from one place.
#   vendor          a maintained rtw88 tree with the RTL8723BS support and the
#                   SDIO workarounds, used when the upstream backport does not
#                   compile
#
# The result is a .deb that installs the modules, the firmware blob, the
# modprobe configuration and the systemd unit that loads the driver.
# ============================================================================
set -euo pipefail

KVER=""
OUT_DIR="out"
SOURCE="vendor"
JOBS="$(nproc --ignore=1 2>/dev/null || echo 2)"
KERNEL_REPO="https://github.com/torvalds/linux.git"
KERNEL_REF="v6.12"
UPSTREAM_REF="master"
VENDOR_REPO="MocLG/rtw88-rtl8723bs"
VENDOR_REF="0f64b72d8ec091d811a1a44f8b314e9df1b72d78"
FIRMWARE_DIR=""
DEB_NAME="qm1-rtw88-8723bs"
# 本仓库对 vendor 树的本地补丁（patches/rtw88/*.patch）。这些补丁承载上游
# 还没进 vendor 树的修复，例如 8723BS 的 TX report purge 超时（上游 4d688f22ebbf）。
PATCH_DIR=""
KERNEL_BUILD_DIR=""
UPSTREAM_TREE=""

log()  { printf '[rtw88] %s\n' "$*" >&2; }
warn() { printf '[rtw88][warn] %s\n' "$*" >&2; }
die()  { printf '[rtw88][fail] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-rtw88-8723bs-module.sh --kver <kernel-abi> [options]

  --kver <abi>          target kernel ABI, e.g. 6.12.113+deb13-amd64 (required)
  --out-dir <dir>       output directory (default: out)
  --source <mode>       auto | upstream | upstream-full | vendor (default: auto)
  --jobs <n>            parallel make jobs
  --kernel-repo <url>   linux.git URL used for the rtw88 headers
  --kernel-ref <ref>    ref of the kernel tree (default: v6.12)
  --upstream-ref <ref>  ref that carries the 8723b chip driver (default: master)
  --vendor-repo <repo>  github repo of the vendor rtw88 tree
  --vendor-ref <sha>    commit of the vendor tree
  --patch-dir <dir>     directory with local *.patch files applied to the
                        vendor tree (default: <repo>/patches/rtw88)
  --upstream-tree <dir>   an existing kernel checkout that carries the rtw88
                        tree (skips the git clone)
  --kernel-build-dir <dir>
                        explicit kernel build tree (overrides the automatic
                        lookup of /lib/modules/<abi>/build)
  --firmware-dir <dir>  directory that holds rtw8723b_fw.bin
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kver)          KVER="$2"; shift 2 ;;
        --out-dir)       OUT_DIR="$2"; shift 2 ;;
        --source)        SOURCE="$2"; shift 2 ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --kernel-repo)   KERNEL_REPO="$2"; shift 2 ;;
        --kernel-ref)    KERNEL_REF="$2"; shift 2 ;;
        --upstream-ref)  UPSTREAM_REF="$2"; shift 2 ;;
        --vendor-repo)   VENDOR_REPO="$2"; shift 2 ;;
        --vendor-ref)    VENDOR_REF="$2"; shift 2 ;;
        --patch-dir)     PATCH_DIR="$2"; shift 2 ;;
        --kernel-build-dir) KERNEL_BUILD_DIR="$2"; shift 2 ;;
        --upstream-tree)  UPSTREAM_TREE="$2"; shift 2 ;;
        --firmware-dir)  FIRMWARE_DIR="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$KVER" ] || { usage; die "--kver is required"; }
case "$SOURCE" in auto|upstream|upstream-full|vendor) ;; *) die "invalid --source: $SOURCE" ;; esac

if [ -z "$PATCH_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PATCH_DIR="$SCRIPT_DIR/../patches/rtw88"
    UPSTREAM_PATCH_DIR="$SCRIPT_DIR/../patches/rtw88-upstream"
fi

for cmd in make gcc git curl dpkg-deb modinfo; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing tool: $cmd"
done

# Debian 的 linux-headers-<abi> 不提供 /usr/src/linux-headers-<abi>/build（那是
# Red Hat / kernel.org 的布局）；Debian 的构建树是 /usr/src/linux-headers-<abi>，
# 并由 /lib/modules/<abi>/build 指向它。两个路径都认，优先用 /lib/modules 那个。
KSRC=""
if [ -n "$KERNEL_BUILD_DIR" ]; then
    [ -d "$KERNEL_BUILD_DIR" ] || die "kernel build tree not found: $KERNEL_BUILD_DIR"
    KSRC="$(cd "$KERNEL_BUILD_DIR" && pwd)"
else
    for cand in "/lib/modules/${KVER}/build" "/usr/src/linux-headers-${KVER}" "/usr/src/linux-headers-${KVER}/build"; do
        if [ -d "$cand" ]; then KSRC="$cand"; break; fi
    done
fi
[ -n "$KSRC" ] || die "kernel build tree not found (tried /lib/modules/${KVER}/build and /usr/src/linux-headers-${KVER}); install linux-headers-${KVER}"

# make -C <kernel> 会切目录，所以 M= 必须是绝对路径
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK="$OUT_DIR/rtw88-build"
rm -rf "$WORK"
mkdir -p "$WORK"
RTW88_DIR="$WORK/rtw88-src"

# ---------------------------------------------------------------------------
# fetch helpers
# ---------------------------------------------------------------------------
fetch_to() {   # fetch_to <url> <target>
    local url="$1" target="$2" attempt
    for attempt in 1 2 3 4 5; do
        if curl -fsSL --retry 3 --retry-all-errors --max-time 180 -o "$target" "$url"; then
            return 0
        fi
        warn "download failed ($attempt/5): $url"
        sleep $((attempt * 3))
    done
    return 1
}

# ---------------------------------------------------------------------------
# upstream backport: chip driver from upstream + rtw88 headers of the target
# kernel series, built as external modules against the in-tree rtw88 core.
# ---------------------------------------------------------------------------
build_upstream() {
    log "building the upstream rtw88 8723b backport"

    # 目标内核自带的 rtw88 头文件最理想：与内核版本严格一致，也省掉一次大仓库 clone。
    local sysrtw="$KSRC/drivers/net/wireless/realtek/rtw88"
    if [ -f "$sysrtw/main.h" ]; then
        log "using the rtw88 headers shipped with $KVER"
        RTW88_DIR="$WORK/rtw88-headers"
        rm -rf "$RTW88_DIR"
        mkdir -p "$RTW88_DIR"
        cp "$sysrtw"/*.h "$RTW88_DIR/" 2>/dev/null || true
    else
        log "fetching the rtw88 headers of $KERNEL_REF"
        rm -rf "$WORK/linux"
        git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$KERNEL_REF" \
            "$KERNEL_REPO" "$WORK/linux" \
            || { warn "kernel tree clone failed"; return 1; }
        git -C "$WORK/linux" sparse-checkout set drivers/net/wireless/realtek/rtw88 \
            || { warn "sparse checkout failed"; return 1; }
        RTW88_DIR="$WORK/linux/drivers/net/wireless/realtek/rtw88"
    fi
    [ -f "$RTW88_DIR/main.h" ] || { warn "rtw88 headers are incomplete"; return 1; }

    local base="https://raw.githubusercontent.com/torvalds/linux/${UPSTREAM_REF}/drivers/net/wireless/realtek/rtw88"
    local f
    for f in rtw8723b.c rtw8723b.h rtw8723b_table.c rtw8723b_table.h rtw8723bs.c; do
        fetch_to "${base}/${f}" "$RTW88_DIR/$f" || { warn "cannot fetch ${f}"; return 1; }
    done

    local mod="$WORK/module-upstream"
    rm -rf "$mod"
    mkdir -p "$mod/rtw88"
    cp "$RTW88_DIR"/*.h "$mod/rtw88/" 2>/dev/null || true
    cp "$RTW88_DIR/rtw8723b.c" "$RTW88_DIR/rtw8723b_table.c" "$RTW88_DIR/rtw8723bs.c" "$mod/"
    cat > "$mod/Makefile" <<'EOF'
# Out-of-tree build of the upstream rtw88 RTL8723B / RTL8723BS support.
obj-m += rtw88_8723b.o
rtw88_8723b-objs := rtw8723b.o rtw8723b_table.o
obj-m += rtw88_8723bs.o
rtw88_8723bs-objs := rtw8723bs.o
ccflags-y += -I$(src)/rtw88
EOF

    log "compiling against $KSRC"
    make -C "$KSRC" M="$mod" -j"$JOBS" modules \
        || { warn "the upstream backport does not compile against $KVER"; return 1; }
    [ -f "$mod/rtw88_8723b.ko" ] && [ -f "$mod/rtw88_8723bs.ko" ] \
        || { warn "upstream build produced no modules"; return 1; }
    MOD_DIR="$mod"
    MOD_NAMES="rtw88_8723b.ko rtw88_8723bs.ko"
    return 0
}

# ---------------------------------------------------------------------------
# upstream-full: the complete upstream rtw88 tree of --upstream-ref, built as
# out-of-tree modules against the target kernel.
#
# Upstream restructured rtw88 (main.c split into fw.c / efuse.c / mac80211.c
# / ... and the 8723b chip driver moved onto the new core API), so the chip
# files cannot be combined with the old core headers.  The root-cause path is
# therefore to take the whole tree from one place.
#
# The module names get a _qm1 suffix: the in-tree kernel already ships modules
# called rtw88_core / rtw88_sdio, and two modules of the same name cannot
# coexist in one module tree.
# ---------------------------------------------------------------------------
build_upstream_full() {
    log "building the whole upstream rtw88 tree ($UPSTREAM_REF) against $KVER"

    # An existing checkout can be used as it is; this skips the git clone.
    local src=""
    if [ -n "$UPSTREAM_TREE" ]; then
        src="$UPSTREAM_TREE/drivers/net/wireless/realtek/rtw88"
        [ -f "$src/rtw8723bs.c" ] || { warn "$UPSTREAM_TREE has no rtw8723bs.c"; return 1; }
    fi

    # A pre-seeded tree (for example a cached clone) is reused as it is.
    local up_src="$WORK/linux-upstream/drivers/net/wireless/realtek/rtw88"
    if [ -z "$src" ] && [ ! -f "$up_src/rtw8723bs.c" ]; then
        rm -rf "$WORK/linux-upstream"
        git_clone_retry "$KERNEL_REPO" "$WORK/linux-upstream" \
            --depth 1 --filter=blob:none --sparse --branch "$UPSTREAM_REF" \
            || { warn "kernel tree clone failed"; return 1; }
        git -C "$WORK/linux-upstream" sparse-checkout set drivers/net/wireless/realtek/rtw88 \
            || { warn "sparse checkout failed"; return 1; }
    else
        log "reusing the pre-seeded upstream tree in $WORK/linux-upstream"
    fi

    if [ -z "$src" ]; then
        src="$WORK/linux-upstream/drivers/net/wireless/realtek/rtw88"
    fi
    [ -f "$src/rtw8723bs.c" ] || { warn "$UPSTREAM_REF has no rtw8723bs.c"; return 1; }

    local mod="$WORK/module-upstream-full"
    rm -rf "$mod"
    mkdir -p "$mod"
    cp "$src"/*.c "$src"/*.h "$mod"/ 2>/dev/null || true

    # The upstream tree needs the local compatibility patch: its mac80211 glue
    # uses the multi-radio and the MLO callbacks that Linux 6.12 does not have.
    apply_patches "$mod" "$UPSTREAM_PATCH_DIR" || return 1

    # Object list: upstream's own core list plus the SDIO transport and the
    # 8723x / 8723B / 8723BS chip files.  Everything is built into a single
    # module named rtw88_qm1, so it never collides with the in-tree modules
    # rtw88_core / rtw88_sdio that the distribution ships.
    local up_mk="$src/Makefile"
    [ -f "$up_mk" ] || { warn "upstream rtw88 Makefile not found"; return 1; }
    local core_objs chip_8723b chip_8723bs chip_8723x sdio_objs
    core_objs=$(awk '
        /^rtw88_core-y[ \t]*\+=/ {
            inblk=1
            line=$0
            sub(/^[^=]*\+=[ \t]*/, "", line)
            gsub(/\\/, "", line)
            gsub(/^[ \t]+/, "", line)
            if (line != "") print line
            next
        }
        inblk {
            line=$0
            cont = (line ~ /\\$/)
            gsub(/\\/, "", line)
            gsub(/^[ \t]+/, "", line)
            if (line != "") print line
            if (!cont) exit
        }
    ' "$up_mk" | tr '\n' ' ' | tr -s ' ')
    chip_8723b=$(awk '/^rtw88_8723b-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    chip_8723bs=$(awk '/^rtw88_8723bs-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    chip_8723x=$(awk '/^rtw88_8723x-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    sdio_objs=$(awk '/^rtw88_sdio-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    [ -n "$core_objs" ] && [ -n "$chip_8723b" ] && [ -n "$chip_8723bs" ] \
        && [ -n "$sdio_objs" ] \
        || { warn "could not read the upstream object lists"; return 1; }

    # CONFIG gated parts, same rules as upstream
    local kcfg=""
    for c in "$KSRC/.config" "$KSRC/../../linux-headers-$KVER/.config" "/boot/config-$KVER"; do
        if [ -f "$c" ]; then kcfg="$c"; break; fi
    done
    if [ -n "$kcfg" ] && grep -q '^CONFIG_PM=y' "$kcfg"; then
        core_objs="$core_objs wow.o"
    fi
    if [ -n "$kcfg" ] && grep -q '^CONFIG_RTW88_LEDS=y' "$kcfg"; then
        core_objs="$core_objs led.o"
    else
        log "target kernel has no CONFIG_RTW88_LEDS; leaving led.o out (as upstream does)"
    fi

    cat > "$mod/Kbuild" <<EOF
# Out-of-tree build of the complete upstream rtw88 tree.
# The object lists are taken from the upstream Makefile of $UPSTREAM_REF.
obj-m := rtw88_qm1.o
rtw88_qm1-objs := $core_objs $sdio_objs $chip_8723x $chip_8723b $chip_8723bs
ccflags-y += -I\$(src)
EOF

    log "compiling against $KSRC"
    # KBUILD_MODPOST_WARN: the module exports symbols that the 6.12 kernel
    # does not know yet, so modpost cannot give them a version.
    # CONFIG_DEBUG_INFO_BTF_MODULES: the distribution headers ship a vmlinux
    # that pahole cannot use as the BTF base, so the module BTF step is off.
    local ld_bin cc_bin
    ld_bin="$(command -v x86_64-linux-gnu-ld || command -v ld || true)"
    [ -n "$ld_bin" ] || { warn "no linker found"; return 1; }
    # The distribution headers pin the compiler of the distribution
    # (x86_64-linux-gnu-gcc-14); fall back to any available gcc.
    cc_bin="$(command -v x86_64-linux-gnu-gcc-14 || command -v gcc-14 || command -v gcc || true)"
    [ -n "$cc_bin" ] || { warn "no C compiler found"; return 1; }
    make -C "$KSRC" M="$mod" -j"$JOBS" modules \
        KBUILD_MODPOST_WARN=1 CONFIG_DEBUG_INFO_BTF_MODULES= \
        CC="$cc_bin" LD="$ld_bin" \
        || { warn "the full upstream rtw88 tree does not compile against $KVER"; return 1; }

    [ -f "$mod/rtw88_qm1.ko" ] || { warn "upstream build produced no module"; return 1; }
    MOD_DIR="$mod"
    MOD_NAMES="rtw88_qm1.ko"
    return 0
}

# ---------------------------------------------------------------------------
# local patches for the vendor tree
#
# The vendor tree misses fixes that upstream already merged for this chip --
# most importantly the TX report purge timeout (upstream 4d688f22ebbf gives
# the 8723BS 2500 ms instead of 500 ms).  Those patches live in
# patches/rtw88/ and are applied here; a missing patch directory is fatal,
# because building the unpatched vendor tree would ship the very symptom
# this backport is meant to cure.
# ---------------------------------------------------------------------------
apply_patches() {   # apply_patches <tree-dir> [patch-dir]
    local dir="$1" p n=0
    local pdir="${2:-$PATCH_DIR}"
    [ -d "$dir" ] || die "patch target $dir does not exist"
    [ -d "$pdir" ] || die "patch directory $pdir does not exist"
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || die "no *.patch found in $PATCH_DIR"
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        log "dry-run $(basename "$p")"
        if ! (cd "$dir" && patch -p1 --dry-run --batch --forward < "$p"); then
            die "patch does not apply to the vendor tree: $(basename "$p")"
        fi
    done
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        log "applying $(basename "$p")"
        (cd "$dir" && patch -p1 --batch --forward < "$p") \
            || die "failed to apply $(basename "$p")"
    done
    find "$dir" \( -name '*.rej' -o -name '*.orig' \) -delete
    log "$n patch(es) applied to $dir"
}

# ---------------------------------------------------------------------------
# vendor tree: self contained rtw88 copy with the RTL8723BS support
# ---------------------------------------------------------------------------
build_vendor() {
    log "building the vendor rtw88 tree $VENDOR_REPO@${VENDOR_REF:0:12}"
    local tarball="$WORK/vendor.tar.gz"
    fetch_to "https://codeload.github.com/${VENDOR_REPO}/tar.gz/${VENDOR_REF}" "$tarball" \
        || { warn "cannot fetch the vendor tree"; return 1; }
    rm -rf "$WORK/vendor"
    mkdir -p "$WORK/vendor"
    tar -xzf "$tarball" -C "$WORK/vendor" --strip-components=1 \
        || { warn "cannot unpack the vendor tree"; return 1; }
    [ -f "$WORK/vendor/Makefile" ] || { warn "vendor tree has no Makefile"; return 1; }

    # 本仓库的本地补丁（TX report purge 超时等）必须打上，否则编出来的模块
    # 仍带着 500 ms 的旧超时。
    apply_patches "$WORK/vendor" || return 1

    log "compiling the vendor tree against $KSRC"
    make -C "$KSRC" M="$WORK/vendor" -j"$JOBS" modules \
        || { warn "the vendor tree does not compile against $KVER"; return 1; }

    local mod="$WORK/module-vendor"
    rm -rf "$mod"
    mkdir -p "$mod"
    local m
    for m in rtw_core.ko rtw_sdio.ko rtw_8723b.ko rtw_8723bs.ko; do
        if [ ! -f "$WORK/vendor/$m" ]; then
            warn "vendor build is missing $m"
            return 1
        fi
        cp "$WORK/vendor/$m" "$mod/"
    done
    MOD_DIR="$mod"
    MOD_NAMES="rtw_core.ko rtw_sdio.ko rtw_8723b.ko rtw_8723bs.ko"
    return 0
}

# git clone from github fails now and then with a TLS EOF; retry a few times.
git_clone_retry() {   # git_clone_retry <url> <dir> [extra args...]
    local url="$1" dir="$2"; shift 2
    local attempt
    for attempt in 1 2 3 4 5; do
        rm -rf "$dir"
        if git clone --quiet "$@" "$url" "$dir"; then
            return 0
        fi
        warn "git clone of $url failed (attempt $attempt), retrying"
        sleep $((attempt * 3))
    done
    return 1
}

MOD_DIR=""
MOD_NAMES=""
case "$SOURCE" in
    upstream)        build_upstream || die "the upstream backport failed" ;;
    upstream-full)  build_upstream_full || die "the full upstream rtw88 build failed" ;;
    vendor)   build_vendor   || die "the vendor build failed" ;;
    auto)
        # 上游 7.4 的芯片驱动需要 7.4 时期的 rtw88 核心 API（mac_postinit /
        # query_phy_status / set_ampdu_factor / led_set / hw_feature_report …），
        # 在 6.12 上编不过；能编过的是维护中的 vendor rtw88 树，所以默认先试它。
        build_vendor || { warn "falling back to the upstream backport"; build_upstream || die "both builds failed"; }
        ;;
esac

# ---------------------------------------------------------------------------
# verify the modules
# ---------------------------------------------------------------------------
log "verifying the built modules"
for m in $MOD_NAMES; do
    ko="$MOD_DIR/$m"
    [ -f "$ko" ] || die "missing module: $m"
    vermagic="$(modinfo -F vermagic "$ko" 2>/dev/null || true)"
    case "$vermagic" in
        "$KVER"*) : ;;
        *) die "vermagic mismatch for $m: '$vermagic' does not match $KVER" ;;
    esac
done
# the SDIO bind has to claim the QM1 wireless device
_aliases="$(modinfo "$MOD_DIR"/*.ko 2>/dev/null | grep -i 'alias' || true)"
    if ! grep -qi 'b723' <<<"$_aliases"; then
    die "no built module claims the SDIO device 0x024c:0xb723"
fi
log "modules verified against $KVER"

# ---------------------------------------------------------------------------
# firmware
# ---------------------------------------------------------------------------
FW_DIR="$WORK/firmware"
mkdir -p "$FW_DIR"
if [ -n "$FIRMWARE_DIR" ] && [ -f "$FIRMWARE_DIR/rtw8723b_fw.bin" ]; then
    cp "$FIRMWARE_DIR"/rtw8723b*.bin "$FW_DIR/" 2>/dev/null || true
fi
if [ ! -f "$FW_DIR/rtw8723b_fw.bin" ]; then
    log "fetching rtw88/rtw8723b_fw.bin from Debian sid"
    fetch_script="$(dirname "$0")/fetch-rtw8723b-firmware.sh"
    if [ -x "$fetch_script" ] || [ -f "$fetch_script" ]; then
        bash "$fetch_script" --out-dir "$FW_DIR" >&2 || warn "the firmware fetch failed"
    fi
fi
if [ ! -f "$FW_DIR/rtw8723b_fw.bin" ] && [ -f "$WORK/vendor/firmware/rtw8723b_fw.bin" ]; then
    warn "using the firmware blob shipped with the vendor tree"
    cp "$WORK/vendor/firmware/rtw8723b_fw.bin" "$FW_DIR/rtw8723b_fw.bin"
    [ -f "$WORK/vendor/firmware/rtw8723b_wow_fw.bin" ] && cp "$WORK/vendor/firmware/rtw8723b_wow_fw.bin" "$FW_DIR/rtw8723b_wow_fw.bin" || true
fi
[ -f "$FW_DIR/rtw8723b_fw.bin" ] || die "rtw8723b_fw.bin is missing (Debian sid firmware-realtek, or the vendor tree fallback)"

# ---------------------------------------------------------------------------
# package the .deb
# ---------------------------------------------------------------------------
PKG="$WORK/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/lib/modules/$KVER/extra/rtw88" "$PKG/lib/firmware/rtw88" \
         "$PKG/etc/modprobe.d" "$PKG/lib/systemd/system"

for m in $MOD_NAMES; do
    install -m 0644 "$MOD_DIR/$m" "$PKG/lib/modules/$KVER/extra/rtw88/$m"
done
install -m 0644 "$FW_DIR"/rtw8723b*.bin "$PKG/lib/firmware/rtw88/"

# load the out-of-tree driver instead of the obsolete staging driver
SDIO_MODULE="rtw88_8723bs"
for cand in rtw88_qm1.ko rtw_8723bs.ko rtw88_8723bs.ko rtw88_qm1_8723bs.ko; do
    if [ -f "$PKG/lib/modules/$KVER/extra/rtw88/$cand" ]; then
        SDIO_MODULE="${cand%.ko}"
        break
    fi
done

# The module parameters live in the rtw88 core module, not in the SDIO bind.
# Note: rtw_power_mgnt / rtw_smart_ps / rtw_ips_mode / rtw_bw_mode are the
# *staging* driver's parameters -- the rtw88 driver does not have them, and
# modprobe refuses to load a module with an unknown parameter.
CORE_MODULE="rtw_core"
for cand in rtw88_qm1.ko rtw_core.ko rtw88_core.ko rtw88_qm1_core.ko; do
    if [ -f "$PKG/lib/modules/$KVER/extra/rtw88/$cand" ]; then
        CORE_MODULE="${cand%.ko}"
        break
    fi
done
CORE_PARAMS="disable_lps_deep support_bf debug_mask"

# every parameter we write must really exist, otherwise modprobe fails to load
CORE_KO="$PKG/lib/modules/$KVER/extra/rtw88/$CORE_MODULE.ko"
AVAILABLE_PARAMS="$(modinfo -p "$CORE_KO" | awk -F: '{print $1}' | tr '\n' ' ')"
for param in $CORE_PARAMS; do
    case " $AVAILABLE_PARAMS " in
        *" $param "*) ;;
        *) die "$CORE_MODULE.ko has no parameter '$param' (available: $AVAILABLE_PARAMS)" ;;
    esac
done

# The in-tree kernel ships its own rtw88 modules.  They export the same symbol
# names as the backport, so they must never be loaded next to it.
BLACKLIST_EXTRA=""
if [ "$SOURCE" = "upstream-full" ]; then
    BLACKLIST_EXTRA="rtw88_core rtw88_sdio rtw88_8723x rtw88_8723b rtw88_8723bs rtw88_pci rtw88_usb"
fi

{
    echo "# The staging driver r8723bs is superseded by the rtw88 backport."
    echo "# The staging parameters (rtw_power_mgnt / rtw_smart_ps / rtw_ips_mode /"
    echo "# rtw_bw_mode) belong to r8723bs only; the rtw88 driver exposes the ones below."
    echo "blacklist r8723bs"
    for m in $BLACKLIST_EXTRA; do
        echo "blacklist $m"
    done
    echo "options ${CORE_MODULE} disable_lps_deep=y"
    echo "options ${CORE_MODULE} support_bf=y"
    echo "options ${CORE_MODULE} debug_mask=0"
} > "$PKG/etc/modprobe.d/qm1-rtw88-8723bs.conf"

cat > "$PKG/lib/systemd/system/qm1-rtw88-8723bs.service" <<EOF
[Unit]
Description=Load the rtw88 RTL8723BS Wi-Fi driver
Before=network.target
After=systemd-modules-load.service
ConditionPathExists=/lib/modules/$KVER/extra/rtw88/$SDIO_MODULE.ko

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe -r r8723bs
ExecStart=/sbin/modprobe $SDIO_MODULE
ExecStop=-/sbin/modprobe -r $SDIO_MODULE

[Install]
WantedBy=multi-user.target
EOF

cat > "$PKG/DEBIAN/control" <<EOF
Package: $DEB_NAME
Version: 1.0
Section: kernel
Priority: optional
Architecture: amd64
Maintainer: QM1 image build
Description: Out-of-tree rtw88 driver for the Realtek RTL8723BS SDIO Wi-Fi chip
 The upstream RTL8723B and RTL8723BS support that was merged into the rtw88
 driver is built against the kernel of the image, together with the firmware
 blob that the distribution does not ship.
EOF

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ -d "/lib/modules/$1" ]; then
    depmod -a "/lib/modules/$1" || true
fi
exit 0
EOF
chmod 0755 "$PKG/DEBIAN/postinst"

DEB="$OUT_DIR/${DEB_NAME}_${KVER}_amd64.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
log "built $DEB"

{
    echo "kernel=$KVER"
    echo "source=$SOURCE"
    echo "modules=$MOD_NAMES"
    echo "sdio_module=$SDIO_MODULE"
    for m in $MOD_NAMES; do
        echo "module $m vermagic=$(modinfo -F vermagic "$MOD_DIR/$m") alias=$(modinfo -F alias "$MOD_DIR/$m" | tr '\n' ',')"
    done
    echo "firmware=rtw8723b_fw.bin"
} > "$OUT_DIR/${DEB_NAME}.manifest"

( cd "$OUT_DIR" && sha256sum "$(basename "$DEB")" > "${DEB_NAME}.sha256" )
log "done: $DEB"
