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
#   upstream-full   the *whole* upstream rtw88 tree of --upstream-ref, built
#                   as out-of-tree modules against the target kernel.
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
# The upstream rtw88 tree is pinned to one commit.  A floating "master" makes
# the build irreproducible: if upstream puts the 500 ms TX report purge
# timeout back, the image silently falls back to the "the link comes up but
# the throughput collapses" symptom and *nothing* in this build fails.
# The pin is checked against the tree itself further down (the 2500 ms
# RTW_TX_PROBE_TIMEOUT_LONG assertion in build_upstream_full).
UPSTREAM_REF="05441d697f7f9a927264f4058cbbc6a03dfcac9d"
VENDOR_REPO="MocLG/rtw88-rtl8723bs"
VENDOR_REF="0f64b72d8ec091d811a1a44f8b314e9df1b72d78"
FIRMWARE_DIR=""
DEB_NAME="qm1-rtw88-8723bs"
# 本仓库对 vendor 树的本地补丁（patches/rtw88/*.patch）。这些补丁承载上游
# 还没进 vendor 树的修复，例如 8723BS 的 TX report purge 超时（上游 4d688f22ebbf）。
PATCH_DIR=""
# 对上游整棵 rtw88 树的本地补丁（patches/rtw88-upstream/*.patch），用来把上游
# 的 mac80211 胶水层适配到 6.12 的 API。
UPSTREAM_PATCH_DIR=""
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
  --upstream-ref <ref>  ref that carries the 8723b chip driver; a 40 hex
                         commit is pinned and verified (default: the pinned
                         upstream commit 05441d697f7f9a927264f4058cbbc6a03dfcac9d)
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
case "$SOURCE" in
    auto|upstream-full|vendor) ;;
    upstream)
        # ★ 这个模式在本项目里是死路，明确说出来，别让人在它上面浪费时间。
        #   它做的是"把上游的 8723B 芯片驱动单独回移"，产出的模块名
        #   （rtw88_8723b / rtw88_8723bs）与**树内** rtw88 完全同名，
        #   而且依赖树内 rtw88_core ⇒ 树内模块和树外模块不可能同时加载。
        #   出货请用 upstream-full（整棵上游 rtw88 编成一个模块 rtw88_qm1），
        #   回退请用 vendor（staging 树）。
        die "--source upstream is not supported here: the chip-backport modules share the names of the in-tree rtw88 modules and depend on the in-tree rtw88_core. Use --source upstream-full (shipping) or --source vendor (fallback)."
        ;;
    *) die "invalid --source: $SOURCE" ;;
esac

# The patch directories always get a default, no matter whether --patch-dir was
# given: with --source upstream-full the upstream patch directory is used even
# when the caller only overrode the vendor patch directory, and an unset
# variable would abort the run under `set -u`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/rtw88}"
UPSTREAM_PATCH_DIR="${UPSTREAM_PATCH_DIR:-$REPO_ROOT/patches/rtw88-upstream}"

# assert_required_patches() and apply_patches() live in scripts/lib/patch-tree.sh
# so that the build here and scripts/test-upstream-patches.sh walk exactly the
# same code path.  They used to be two copies, and the copies drifted: the
# build dry-ran the whole patch set against the *unpatched* tree before
# applying anything, while the self test applied patch by patch.  A patch
# written against the state its predecessors leave behind (0006, which
# rewrites the chip capability lines that 0004 and 0005 replace) can never
# pass such a dry-run -- the build then fell back to the staging driver with
# a warning, and only the image guard noticed, three layers away from the
# cause.
. "$SCRIPT_DIR/lib/patch-tree.sh"

# The modversions CRC comparison lives in scripts/lib/modversions-crc.sh so
# that the build and its test use the same code.
. "$SCRIPT_DIR/lib/modversions-crc.sh"

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
    BUILT_FROM="upstream-full"
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
        git_clone_retry "$KERNEL_REPO" "$WORK/linux-upstream" "$UPSTREAM_REF" \
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
    # It also needs the 8723B fixes that upstream made after 2026-10-09 and
    # that are therefore not in this snapshot -- see
    # patches/rtw88-upstream/README.md.
    assert_required_patches "$UPSTREAM_PATCH_DIR" "upstream" \
        "$REQUIRED_UPSTREAM_PATCHES" || return 1
    apply_patches "$mod" "$UPSTREAM_PATCH_DIR" "upstream" || return 1

    # Hard assertion on the tree that is about to be compiled: the TX report
    # purge timeout has to be the fixed 2500 ms value.
    assert_tx_probe_timeout "$mod/tx.h"

    # Object list: upstream's own core list plus the SDIO transport and the
    # 8723x / 8723B / 8723BS chip files.  Everything is built into a single
    # module named rtw88_qm1, so it never collides with the in-tree modules
    # rtw88_core / rtw88_sdio that the distribution ships.
    #
    # All `rtw88_core-y +=` / `rtw88_core-y :=` blocks are collected — upstream
    # may split the list into several blocks, and taking only the first one
    # silently drops objects (sar.o / bf.o and friends), which shows up as a
    # missing symbol at runtime while the build still succeeds.
    local up_mk="$src/Makefile"
    [ -f "$up_mk" ] || { warn "upstream rtw88 Makefile not found"; return 1; }
    local core_objs chip_8723b chip_8723bs chip_8723x sdio_objs
    core_objs="$(awk '
        # a core block starts here (both += and := are accepted)
        /^rtw88_core-y[ \t]*(\+=|:=)/ {
            inblk = 1
            line = $0
            sub(/^[^=]*[+]?=[ \t]*/, "", line)
            gsub(/\\/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line ~ /\.o$/) print line
            next
        }
        # a conditional core item closes the current block
        /^rtw88_core-\$\(CONFIG_/ { inblk = 0; next }
        inblk {
            line = $0
            cont = (line ~ /\\$/)
            gsub(/\\/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == "") next              # blank line: keep the block open
            if (line ~ /\.o$/) print line
            if (!cont) inblk = 0
        }
    ' "$up_mk" | tr '\n' ' ' | tr -s ' ')"
    chip_8723b=$(awk '/^rtw88_8723b-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    chip_8723bs=$(awk '/^rtw88_8723bs-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    chip_8723x=$(awk '/^rtw88_8723x-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    sdio_objs=$(awk '/^rtw88_sdio-objs/ {sub(/^[^:]*:=[ \t]*/, ""); print; exit}' "$up_mk")
    [ -n "$core_objs" ] && [ -n "$chip_8723b" ] && [ -n "$chip_8723bs" ] \
        && [ -n "$sdio_objs" ] \
        || { warn "could not read the upstream object lists"; return 1; }

    # Conditional core objects (rtw88_core-$(CONFIG_PM) += wow.o,
    # rtw88_core-$(CONFIG_RTW88_LEDS) += led.o, ...) are resolved against the
    # config of the *target* kernel, exactly like upstream does.
    local kcfg=""
    for c in "$KSRC/.config" "$KSRC/../../linux-headers-$KVER/.config" "/boot/config-$KVER"; do
        if [ -f "$c" ]; then kcfg="$c"; break; fi
    done
    [ -n "$kcfg" ] \
        || die "cannot find the config of the target kernel (tried $KSRC/.config and /boot/config-$KVER); the conditional rtw88 core objects cannot be resolved"
    log "target kernel config: $kcfg"
    local cond_pairs cfg obj
    cond_pairs="$(awk '
        /^rtw88_core-\$\(CONFIG_[A-Za-z0-9_]+\)[ \t]*\+=/ {
            cfg = $0
            sub(/^rtw88_core-\$\(/, "", cfg)
            sub(/\).*/, "", cfg)
            obj = $0
            sub(/^[^=]*\+=[ \t]*/, "", obj)
            gsub(/\\/, "", obj)
            gsub(/^[ \t]+|[ \t]+$/, "", obj)
            if (obj != "") print cfg " " obj
        }' "$up_mk")"
    while read -r cfg obj; do
        if [ -z "$cfg" ] || [ -z "$obj" ]; then
            continue
        fi
        if grep -q "^${cfg}=\(y\|m\)$" "$kcfg"; then
            core_objs="$core_objs $obj"
            log "conditional core object $obj included ($cfg is set in the target kernel)"
        else
            log "conditional core object $obj left out ($cfg is not set in the target kernel)"
        fi
    done <<< "$cond_pairs"

    # merge and de-duplicate
    core_objs="$(printf '%s' "$core_objs" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
    core_objs="$(printf '%s' "$core_objs" | sed 's/^ *//; s/ *$//')"
    local core_count
    core_count="$(printf '%s\n' "$core_objs" | tr ' ' '\n' | sed '/^$/d' | wc -l)"
    log "upstream rtw88 core objects ($core_count): $core_objs"
    # The 6.12 adapted upstream tree has ~17 core objects.  Fewer means the
    # Makefile parsing lost a block — that must not reach the compiler.
    [ "$core_count" -ge 15 ] \
        || die "the upstream rtw88 core object list has only $core_count objects (expected at least 15); the upstream Makefile parsing is incomplete"

    cat > "$mod/Kbuild" <<EOF
# Out-of-tree build of the complete upstream rtw88 tree.
# The object lists are taken from the upstream Makefile of $UPSTREAM_REF.
obj-m := rtw88_qm1.o
rtw88_qm1-objs := $core_objs $sdio_objs $chip_8723x $chip_8723b $chip_8723bs
ccflags-y += -I\$(src)
EOF

    log "compiling against $KSRC"
    # KBUILD_MODPOST_WARN is deliberately NOT set on the first attempt: an
    # unresolved symbol has to fail the build.  With the warning mode the .deb
    # is produced anyway, the module refuses to load on the QM1 ("Unknown
    # symbol") and no wlan0 ever appears — while the build reports success.
    #
    # CONFIG_DEBUG_INFO_BTF_MODULES: the distribution headers ship a vmlinux
    # that pahole cannot use as the BTF base, so the module BTF step is off.
    local ld_bin cc_bin
    ld_bin="$(command -v x86_64-linux-gnu-ld || command -v ld || true)"
    [ -n "$ld_bin" ] || { warn "no linker found"; return 1; }
    # The distribution headers pin the compiler of the distribution
    # (x86_64-linux-gnu-gcc-14); fall back to any available gcc.
    cc_bin="$(command -v x86_64-linux-gnu-gcc-14 || command -v gcc-14 || command -v gcc || true)"
    [ -n "$cc_bin" ] || { warn "no C compiler found"; return 1; }

    local build_log="$WORK/build-upstream-full.log"
    local undef_syms bad_syms sym
    if make -C "$KSRC" M="$mod" -j"$JOBS" modules \
        CONFIG_DEBUG_INFO_BTF_MODULES= CC="$cc_bin" LD="$ld_bin" \
        2>&1 | tee "$build_log"; then
        :
    else
        # The build failed.  If it failed on unresolved symbols, every one of
        # them has to be accounted for before the build may continue.
        undef_syms="$(grep -E 'modpost.*undefined' "$build_log" \
            | grep -oE '"[^"]+"' | tr -d '"' | sed '/^$/d' | sort -u || true)"
        if [ -z "$undef_syms" ]; then
            die "the full upstream rtw88 tree does not compile against $KVER (log: $build_log)"
        fi
        bad_syms=""
        for sym in $undef_syms; do
            if ! tree_exports_symbol "$sym"; then
                bad_syms="$bad_syms $sym"
            fi
        done
        if [ -n "$bad_syms" ]; then
            printf '[rtw88][fail] unresolved symbols that do not come from the in-tree rtw88 exports:%s\n' "$bad_syms" >&2
            printf '[rtw88][fail] those symbols have to be provided by the out-of-tree module itself (log: %s)\n' "$build_log" >&2
            die "the out-of-tree rtw88 module has unresolved symbols"
        fi
        # ★ 这里原来有一次"降级重编"：加上 KBUILD_MODPOST_WARN=1 再编一遍，
        #   打印一句"这些符号来自树内 rtw88，镜像里已经拉黑，属预期"就当成功。
        #   那条路是自相矛盾的，本轮审查把它判成 P0 并已修掉：
        #     * 树内 rtw88_core / rtw88_sdio 被镜像拉黑 ⇒ 运行时那些符号根本
        #       不存在 ⇒ insmod 会报 "Unknown symbol" ⇒ 模块永远装不上 ⇒
        #       没有 wlan0。而构建却报成功，CI 的所有断言（.ko 存在、vermagic、
        #       alias 含 b723、固件在、conf 行在）全部满足 ⇒ "绿镜像没有 Wi-Fi"。
        #     * 树内 rtw88_core.ko 导出的符号（rtw_core_init / rtw_register_hw /
        #       rtw_chip_info_setup …）与上游整树**同名**，两个模块不可能同时
        #       加载（第二个 insmod 报 "exported symbol already defined"）。
        #       所以"复用树内导出"这条路本身就不成立。
        #     * 真正会触发这条分支的场景 = 上游 Makefile 的对象表没解析全
        #       （漏 CONFIG_PM 的 wow.o、漏新增文件），于是 modpost 报的未定义
        #       符号恰好是树内 rtw88 导出的那批 —— 那是**对象表不完整**，
        #       属于必须失败的缺陷，不是"预期"。
        #   ⇒ 现在这里直接失败，不允许产出符号残缺的模块。
        printf '[rtw88][fail] %s\n' "未定义符号（modpost 判定）:" >&2
        for sym in $undef_syms; do
            printf '[rtw88][fail]   - %s\n' "$sym" >&2
        done
        printf '[rtw88][fail] %s\n' \
            "其中来自树内 rtw88 导出的符号在镜像里不可用（树内 rtw88 被拉黑，符号同名冲突），" >&2
        printf '[rtw88][fail] %s\n' \
            "用 KBUILD_MODPOST_WARN 硬编出来的模块会在真机上 insmod 报 Unknown symbol —— 拒绝出货。" >&2
        printf '[rtw88][fail] %s\n' \
            "请检查上游 Makefile 的对象表解析（core_count >= 15 只是粗检查）" >&2
        die "the out-of-tree rtw88 module has unresolved symbols (log: $build_log)"
    fi

    [ -f "$mod/rtw88_qm1.ko" ] || { warn "upstream build produced no module"; return 1; }
    MOD_DIR="$mod"
    MOD_NAMES="rtw88_qm1.ko"
    return 0
}

# ---------------------------------------------------------------------------
# The patches that must be present, per tree.
#
# The upstream snapshot we build from (a torvalds/linux master snapshot of
# 2026-11-03) only merged rtw-next up to the "rtw-next-2026-10-08" tag, so
# the 8723B fixes that upstream made from 2026-10-09 onwards are not in it.
# We carry them ourselves (see patches/rtw88-upstream/README.md).
#
# A missing patch is not a build error by itself: the module would still
# compile, still load and still bring the interface up.  It would just be
# missing the fix -- the RX path that can overflow the skb, the beacon loss
# on a 40 MHz connection, the 40 MHz capability itself.  That is exactly the
# kind of quiet regression this repository refuses to ship, so the presence
# of every required patch is checked before anything is compiled.
# ---------------------------------------------------------------------------
REQUIRED_UPSTREAM_PATCHES="0001-rtw88-adapt-the-mac80211-api-to-linux-6.12.patch
0002-rtw88-sdio-reject-oversized-rx-packets.patch
0003-rtw88-sdio-copy-rx-status-after-updating-the-frequency.patch
0004-rtw88-8723b-do-not-set-channel-invalid-in-query-phy-status.patch
0005-rtw88-8723b-always-report-a-single-spatial-stream.patch
0006-rtw88-8723b-stay-at-20mhz-until-the-chip-variant-can-be-read.patch
0007-trigger-firmware-recovery-when-failing-to-leave-lps-state.patch
0008-avoid-converting-rx-snr-twice.patch
0009-allow-key-removal-when-the-cam-table-is-full.patch"

REQUIRED_VENDOR_PATCHES="0001-rtw88-8723bs-extend-the-tx-report-purge-timeout.patch"



# ---------------------------------------------------------------------------
# vendor tree: self contained rtw88 copy with the RTL8723BS support
# ---------------------------------------------------------------------------
build_vendor() {
    BUILT_FROM="vendor"
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
    assert_required_patches "$PATCH_DIR" "vendor" \
        "$REQUIRED_VENDOR_PATCHES" || return 1
    apply_patches "$WORK/vendor" "$PATCH_DIR" "vendor" || return 1

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
# The ref may be a branch/tag or a pinned 40 hex commit: a commit cannot be
# selected with `git clone --branch`, so it is fetched explicitly and checked
# out as FETCH_HEAD.  A pinned commit is verified after the checkout, so a
# wrong tree can never sneak into the build.
git_clone_retry() {   # git_clone_retry <url> <dir> <ref>
    local url="$1" dir="$2" ref="$3"
    local attempt
    for attempt in 1 2 3 4 5; do
        rm -rf "$dir"
        if clone_ref "$url" "$dir" "$ref"; then
            return 0
        fi
        warn "git clone of $url@$ref failed (attempt $attempt), retrying"
        sleep $((attempt * 3))
    done
    return 1
}

clone_ref() {   # clone_ref <url> <dir> <ref>
    local url="$1" dir="$2" ref="$3"
    local got=""
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        # A pinned commit cannot be selected with --branch.  The sparse
        # checkout is set up *before* the checkout, so the working tree never
        # materializes the whole kernel.
        if git clone --quiet --filter=blob:none --no-checkout "$url" "$dir" \
            && git -C "$dir" sparse-checkout init --cone \
            && git -C "$dir" sparse-checkout set drivers/net/wireless/realtek/rtw88 \
            && git -C "$dir" fetch --quiet --depth 1 origin "$ref" \
            && git -C "$dir" checkout --quiet --detach FETCH_HEAD; then
            :
        else
            # fallback for servers that refuse a by-SHA fetch: take the full
            # history (blobs stay filtered) and check the commit out locally
            rm -rf "$dir"
            git clone --quiet --filter=blob:none --no-checkout "$url" "$dir" \
                && git -C "$dir" sparse-checkout init --cone \
                && git -C "$dir" sparse-checkout set drivers/net/wireless/realtek/rtw88 \
                && git -C "$dir" checkout --quiet --detach "$ref" \
                || return 1
        fi
    else
        git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$url" "$dir" \
            || return 1
    fi
    got="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    [ -n "$got" ] || return 1
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && [ "$got" != "$ref" ]; then
        warn "the clone resolved to $got but $ref was pinned"
        return 1
    fi
    log "cloned $url at $got (requested: $ref)"
    return 0
}

MOD_DIR=""
MOD_NAMES=""
case "$SOURCE" in
    upstream-full)  build_upstream_full || die "the full upstream rtw88 build failed" ;;
    vendor)   build_vendor   || die "the vendor build failed" ;;
    auto)
        # 上游 7.4 的芯片驱动需要 7.4 时期的 rtw88 核心 API（mac_postinit /
        # query_phy_status / set_ampdu_factor / led_set / hw_feature_report …），
        # 在 6.12 上编不过；能编过的是维护中的 vendor rtw88 树，所以默认先试它。
        # build_vendor 内部的失败（包括补丁打不上）都以非零状态返回，所以这个
        # 回退分支是真的能走到的。
        # 回退到**出货那一棵树**（upstream-full），不是那个芯片回移的
        # upstream 模式 —— 后者是死路（模块名与树内 rtw88 相同且依赖树内
        # rtw88_core），回退到它等于回退到一个装不上的东西。
        build_vendor || { warn "falling back to the full upstream rtw88 tree"; build_upstream_full || die "both builds failed"; }
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
# modversions CRC check — see scripts/lib/modversions-crc.sh for the why.
# vermagic only carries the kernel version string; two different kernel
# builds with the same version string look identical to it, yet the kernel
# rejects the module at insmod time ("symbol version mismatch").  The build
# would stay green and the driver would never load.
# ---------------------------------------------------------------------------
assert_modversions_crc() {   # assert_modversions_crc <ko> [<ko> ...]
    local ksymvers="$KSRC/Module.symvers"
    if [ ! -f "$ksymvers" ]; then
        # 没有 Module.symvers 就没法比。这一步不该静默跳过 —— 出货镜像的
        # 内核与头文件是同源的，CI 里应该有；真没有就明确说出来。
        warn "no Module.symvers under $KSRC — the modversions CRC check is skipped"
        return 0
    fi
    local own_symvers="$MOD_DIR/Module.symvers"
    local table_file imports_file ko n=0
    table_file="$WORK/crc-table.txt"
    qm1_crc_symbol_table "$ksymvers" "$own_symvers" > "$table_file"
    for ko in "$@"; do
        imports_file="$WORK/crc-imports-$(basename "$ko").txt"
        modprobe --show-modversions "$ko" > "$imports_file" 2>/dev/null || true
        if [ ! -s "$imports_file" ]; then
            warn "modprobe --show-modversions produced nothing for $(basename "$ko") — CRC check skipped for it"
            continue
        fi
        if ! qm1_check_modversions_crc "$table_file" "$imports_file"; then
            die "modversions CRC mismatch for $(basename "$ko") — the kernel would reject this module at insmod time (the vermagic check cannot see this)"
        fi
        n=$((n + $(wc -l < "$imports_file" | tr -d ' ')))
    done
    log "modversions CRC checked ($n imported symbol(s) against $ksymvers)"
}

_crc_kos=()
for _m in $MOD_NAMES; do
    _crc_kos+=("$MOD_DIR/$_m")
done
assert_modversions_crc "${_crc_kos[@]}"

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
[ -f "$CORE_KO" ] || die "the core module $CORE_MODULE.ko is not in the package"
AVAILABLE_PARAMS="$(modinfo -p "$CORE_KO" | awk -F: '{print $1}' | tr '\n' ' ')"
for param in $CORE_PARAMS; do
    case " $AVAILABLE_PARAMS " in
        *" $param "*) ;;
        *) die "$CORE_MODULE.ko has no parameter '$param' (available: $AVAILABLE_PARAMS)" ;;
    esac
done

# The in-tree kernel ships its own rtw88 modules.  They export the same symbol
# names as the backport (rtw_core_init / rtw_register_hw / rtw_chip_info_setup …),
# so the two can never be loaded at the same time — the second insmod fails with
# "exported symbol already defined".  They must therefore be blocked in the
# image, not just in the build hook.
#
# The staging driver r8723bs has to be blocked as well: it claims the very same
# SDIO device id (0x024c:0xb723) and udev loads it by modalias, so it would
# bind the card before the backport ever gets a chance.
#
# ★ 两道隔离都要（blacklist + install ... /bin/false）：
#   blacklist 只挡自动加载（udev 的 modalias 路径），挡不住显式 modprobe；
#   install ... /bin/false 才挡显式加载。少一道就等于没隔离。
#   ★ 这些行**写在包自带的 conf 里**，不只写在构建钩子里：
#     这个包将来完全可能通过 apt 直接安装（不经本项目的 hook），那时
#     钩子补的那几行就不在了 ⇒ 树内驱动照样抢先绑定，出货模块永远拿不到设备，
#     而"装上了根治模块"这件事在日志和清单里看起来一切正常。
INTREE_RTW88="rtw88_core rtw88_sdio rtw88_8723x rtw88_8723b rtw88_8723bs rtw88_pci rtw88_usb"

# ★ 隔离名单必须与**我们自己编出来的模块**不冲突，否则会把出货模块自己拉黑。
#   三种构建来源的模块名各不相同：
#     upstream-full → rtw88_qm1（整树一个模块）⇒ 与树内名字都不冲突。
#     vendor        → rtw_core / rtw_sdio / rtw_8723b / rtw_8723bs（vendor 树
#                     的旧命名）⇒ 与树内 rtw88_* 不重名，但导出的是**同名符号**
#                     （rtw_core_init …），所以树内 rtw88_core 仍然必须挡住。
#     upstream      → rtw88_8723b / rtw88_8723bs（只有芯片文件，复用树内核心）
#                     ⇒ 名字与树内**完全相同**，而且依赖树内 rtw88_core ⇒
#                       这两种情况下一个都不能挡（挡了等于把出货模块自己挡死）。
_own_mods="$(printf '%s\n' $MOD_NAMES | sed 's/\.ko$//' | tr '\n' ' ')"
_block_tree_rtw88=1
if [ "$SOURCE" = "upstream" ]; then
    _block_tree_rtw88=0
fi

{
    echo "# The staging driver r8723bs is superseded by the rtw88 backport."
    echo "# The staging parameters (rtw_power_mgnt / rtw_smart_ps / rtw_ips_mode /"
    echo "# rtw_bw_mode) belong to r8723bs only; the rtw88 driver exposes the ones below."
    echo "#"
    echo "# NOTE: the staging drivers themselves are blocked in a separate file"
    echo "# (qm1-rtl8723bs-fallback.conf) so that the fallback can be re-enabled"
    echo "# on a machine without a wired network by deleting that one file."
    if [ "$_block_tree_rtw88" = "1" ]; then
        for m in $INTREE_RTW88; do
            # 绝不挡我们自己编出来的模块。
            case " $_own_mods " in
                *" $m "*) continue ;;
            esac
            echo "blacklist $m"
            echo "install $m /bin/false"
        done
    else
        echo "# $SOURCE 模式复用树内 rtw88 核心（模块名与树内相同）⇒ 不隔离树内 rtw88。"
    fi
    echo "options ${CORE_MODULE} disable_lps_deep=y"
    echo "options ${CORE_MODULE} support_bf=y"
    echo "options ${CORE_MODULE} debug_mask=0"
} > "$PKG/etc/modprobe.d/qm1-rtw88-8723bs.conf"

# ---------------------------------------------------------------------------
# 隔离分成两个文件，为的是**现场没有网口时还能有退路**。
#
# 出货驱动装不上（符号不匹配 / modversions CRC 对不上 / 固件缺失）时，
# 如果树内 staging 驱动也被同一个文件挡死，这台机器就彻底没网了 ——
# 而它没有 RJ45，唯一的网络就是这块 Wi-Fi。
#
# 所以：挡住 staging 驱动的行单独放在这个文件里。要回退到打了补丁的
# staging 模块，现场只要删掉这一个文件：
#
#   rm /etc/modprobe.d/qm1-rtl8723bs-fallback.conf
#   modprobe r8723bs_qm1     # 打过 P1–P6 补丁的树外 staging 模块
#
# 剩下的树内 rtw88 隔离留在 qm1-rtw88-8723bs.conf 里 —— 那道必须一直在，
# 因为出货模块导出的符号与树内 rtw88_core 同名，两个同时加载会
# "exported symbol already defined"。
# ---------------------------------------------------------------------------
{
    echo "# QM1 的 Wi-Fi 回退开关 —— 出货驱动（rtw88 整树回移）装不上时用它。"
    echo "#"
    echo "# 这台机没有 RJ45，Wi-Fi 是唯一的网络。如果机器连不上网："
    echo "#   1) 先看 journalctl -u qm1-rtw88-8723bs.service 里的失败原因"
    echo "#   2) 删掉本文件，重新让树外 staging 模块接手："
    echo "#        rm /etc/modprobe.d/qm1-rtl8723bs-fallback.conf"
    echo "#        modprobe r8723bs_qm1"
    echo "#      （r8723bs_qm1 是打了 P1–P6 补丁的树外 staging 模块，"
    echo "#        永久卡死路径已修，但速率与弱信号表现不如 rtw88）"
    echo "#"
    echo "# 平时这两个文件都在 ⇒ staging 驱动不会按 SDIO modalias 抢先绑定。"
    echo "blacklist r8723bs"
    echo "install r8723bs /bin/false"
    # 打了补丁的树外 staging 模块带的是**同一个** SDIO device id
    # （0x024c:0xb723），udev 照样会按 modalias 抢先加载它 ——
    # 那就等于换了个名字的老驱动，永久卡死路径一条没少。
    echo "blacklist r8723bs_qm1"
    echo "install r8723bs_qm1 /bin/false"
} > "$PKG/etc/modprobe.d/qm1-rtl8723bs-fallback.conf"

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

# The package version carries the target kernel ABI: the modules are built for
# one kernel only, so two kernels must never end up with the same package
# version.  The kernel ABI is not part of the Debian version syntax (it holds
# '+' and '-'), so it is reduced to dots.
KVER_SLUG="$(printf '%s' "$KVER" | sed 's/[^A-Za-z0-9.]/./g')"
PKG_VERSION="1.0.0+${KVER_SLUG}-1"

# ★ 包名必须区分"出货那棵树"与"回退那棵树"。
#   两个 CI 作业以前都产出同名同版本（qm1-rtw88-8723bs 1.0.0+<kver>-1）
#   但内容完全不同（upstream 整树 = 单模块 rtw88_qm1；vendor = 四个模块
#   rtw_core/rtw_sdio/rtw_8723b/rtw_8723bs）。同名同版本 ⇒
#     * dpkg 会拒绝"用另一个内容覆盖同版本"的安装；
#     * 运维很容易拿错产物，还以为装的是出货那一版。
#   所以回退树的包名加 -fallback 后缀。
case "${BUILT_FROM:-upstream-full}" in
    vendor)         DEB_NAME="qm1-rtw88-8723bs-fallback" ;;
    upstream)       DEB_NAME="qm1-rtw88-8723bs-upstream" ;;
    upstream-full)  DEB_NAME="qm1-rtw88-8723bs" ;;
    *)              die "unknown build source: ${BUILT_FROM:-}" ;;
esac

cat > "$PKG/DEBIAN/control" <<EOF
Package: $DEB_NAME
Version: $PKG_VERSION
Section: kernel
Priority: optional
Architecture: amd64
Depends: linux-image-${KVER}-unsigned | linux-image-${KVER} | linux-image-amd64
Maintainer: QM1 image build
Description: Out-of-tree rtw88 driver for the Realtek RTL8723BS SDIO Wi-Fi chip
 The upstream RTL8723B and RTL8723BS support that was merged into the rtw88
 driver is built against the kernel of the image, together with the firmware
 blob that the distribution does not ship.
 .
 This package is built for the kernel ABI $KVER only; the modules are
 installed below /lib/modules/$KVER and are unusable with any other kernel.
EOF

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
# dpkg 调用维护脚本时给的是*包版本*（$1），不是内核 ABI；所以不能靠 $1 取
# 内核版本 —— 早先写的 [ -d "/lib/modules/$1" ] 永远为假，depmod 从没跑过，
# 模块索引（modules.alias / modules.dep）一直是旧的，结果就是
# "modprobe rtw88_qm1" 报 "not found in directory"，驱动永远加载不上。
#
# 这个包只往 /lib/modules/<KVER>/extra/rtw88/ 里放文件 ⇒ 从自己的文件反推
# 内核版本，再对**那个版本**跑 depmod。
#
# 为什么必须显式给版本：depmod 不带版本参数时用的是**当前运行内核**的版本
# （uname -r）。在镜像/chroot 里 uname -r 是构建机的内核（CI runner 的
# 6.11.x 之类），于是 depmod 去刷新一个根本不存在的 /lib/modules/<构建机内核>/，
# 目标内核的 modules.dep 根本没被更新 —— 这正是之前 CI 里
# "qm1-rtw88-8723bs: depmod -a failed" 背后真正的问题。
set -e

_kvers=""
for _d in /lib/modules/*/extra/rtw88; do
    [ -d "$_d" ] || continue
    # 取出内核版本号（basename），不是目录路径 ——
    # depmod -a 收的是版本号；给它 "/lib/modules/<ver>" 会去找
    # /lib/modules//lib/modules/<ver> 然后失败（CI 里那条
    # "depmod -a /lib/modules/6.12.113+deb13-amd64 失败" 就是这么来的）。
    _kv="${_d%/extra/rtw88}"
    _kv="${_kv#/lib/modules/}"
    [ -n "$_kv" ] || continue
    _kvers="$_kvers $_kv"
done

if [ -z "$_kvers" ]; then
    echo "qm1-rtw88-8723bs: 找不到本包装下的模块目录，模块索引没刷新" >&2
    exit 0
fi

if ! command -v depmod >/dev/null 2>&1; then
    echo "qm1-rtw88-8723bs: depmod 不存在，模块索引没刷新" >&2
    exit 0
fi

for _kv in $_kvers; do
    if depmod -a "$_kv"; then
        echo "qm1-rtw88-8723bs: 已刷新 $_kv 的模块索引"
    else
        echo "qm1-rtw88-8723bs: depmod -a $_kv 失败，请手工执行" >&2
    fi
done
exit 0
EOF
chmod 0755 "$PKG/DEBIAN/postinst"

DEB="$OUT_DIR/${DEB_NAME}_${KVER}_amd64.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
log "built $DEB"

{
    echo "kernel=$KVER"
    echo "package_version=$PKG_VERSION"
    echo "source=$SOURCE"
    echo "upstream_ref=$UPSTREAM_REF"
    echo "modules=$MOD_NAMES"
    echo "sdio_module=$SDIO_MODULE"
    for m in $MOD_NAMES; do
        echo "module $m vermagic=$(modinfo -F vermagic "$MOD_DIR/$m") alias=$(modinfo -F alias "$MOD_DIR/$m" | tr '\n' ',')"
    done
    echo "firmware=rtw8723b_fw.bin"
} > "$OUT_DIR/${DEB_NAME}.manifest"

( cd "$OUT_DIR" && sha256sum "$(basename "$DEB")" > "${DEB_NAME}.sha256" )
log "done: $DEB"
