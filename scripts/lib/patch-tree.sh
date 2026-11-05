#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-tree.sh — 给一棵树打补丁，并断言补丁集是完整的
#
# 这个库只有一份实现，构建脚本和补丁自测脚本都用它 —— 这一点很重要：
# 之前构建脚本和自测脚本各写了一份"打补丁"的逻辑，两份在"先 dry-run 一遍
# 还是边 dry-run 边打"上分了叉，于是出现了一个只有构建才会踩的坑：
#
#   * 构建脚本先把整个补丁集在**未打补丁的树**上 dry-run 一遍，再统一打；
#   * 而 0006 这类补丁是照着"前面几个补丁打完之后的树"写的（它要改的
#     正是 0004/0005 重写过的芯片能力那几行），
#   * 于是 0006 的 dry-run 在未打补丁的树上必然失败，
#   * 构建脚本只打一条 warning 就回退到 staging 驱动，
#   * 直到镜像守卫那一步才红，而那离真正的原因隔了三层。
#
# 自测脚本当时是"边 dry-run 边打"的，所以它一直是绿的 —— 测的不是出货
# 那条路。现在两边共用这一个函数，测的就是出货那条路。
#
# 用法：
#   . scripts/lib/patch-tree.sh
#   assert_required_patches <patch-dir> <label> <文件名列表>
#   apply_patches <tree-dir> <patch-dir> <tree-label>
#
# 两套补丁目录：
#   patches/rtw88/         vendor 树（MocLG/rtw88-rtl8723bs）的本地补丁。
#                           vendor 树缺上游已经合进这块芯片的修复，最要紧的是
#                           TX report purge 超时（上游 4d688f22ebbf 给 8723BS
#                           的是 2500 ms，不是 500 ms）。补丁目录缺失是致命的：
#                           打不上补丁的 vendor 树会原样出货我们正要治的那个
#                           症状。函数返回非零而不是直接退出，好让
#                           --source auto 还能退到另一棵树。
#   patches/rtw88-upstream/ 上游 rtw88 树（钉死在 UPSTREAM_REF）的本地补丁。
# ---------------------------------------------------------------------------

# 日志出口：宿主脚本已经定义了 log/warn 就用它，否则自己打印。
patch_tree_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$@"
    else
        printf '[patch-tree] %s\n' "$*"
    fi
}

patch_tree_warn() {
    if declare -F warn >/dev/null 2>&1; then
        warn "$@"
    else
        printf '[patch-tree][warn] %s\n' "$*" >&2
    fi
}

# ---------------------------------------------------------------------------
# 补丁集必须是完整的。
#
# 少一个补丁不会让构建失败 —— 模块照样能编译、照样能加载、照样能把接口
# 拉起来，只是悄悄少了那个修复。这种"构建是绿的、镜像是旧的"最难查，
# 所以这里把它变成硬失败。
# ---------------------------------------------------------------------------
assert_required_patches() {   # assert_required_patches <patch-dir> <label> <list>
    local pdir="$1" label="$2" list="$3" p missing=0
    for p in $list; do
        if [ ! -f "$pdir/$p" ]; then
            patch_tree_warn "the $label patch set is missing $p"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -ne 0 ]; then
        patch_tree_warn "the $label tree would build without $missing patch(es) -- it would still"
        patch_tree_warn "load and still bring the interface up, but silently without the fixes"
        return 1
    fi
    patch_tree_log "the $label patch set is complete ($(printf '%s' "$list" | wc -w | tr -d ' ') patch(es))"
    return 0
}

# ---------------------------------------------------------------------------
# 按顺序打补丁：每个补丁先 dry-run，再立刻真正打上去。
#
# 为什么必须边 dry-run 边打：dry-run 不改文件，所以如果先把整个补丁集在
# 未打补丁的树上试一遍，后面那些"照着前面补丁的结果写的"补丁一定失败。
# 逐个 dry-run + 逐个应用，每个补丁校验的就是它真正会被应用到的那个状态。
# ---------------------------------------------------------------------------
apply_patches() {   # apply_patches <tree-dir> <patch-dir> <tree-label>
    local dir="$1" pdir="$2" label="$3"
    local p n=0
    [ -d "$dir" ] || { patch_tree_warn "patch target $dir does not exist"; return 1; }
    [ -d "$pdir" ] || { patch_tree_warn "patch directory $pdir does not exist"; return 1; }
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || { patch_tree_warn "no *.patch found in $pdir"; return 1; }
    for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        patch_tree_log "dry-run $(basename "$p")"
        if ! (cd "$dir" && patch -p1 --dry-run --batch --forward < "$p"); then
            patch_tree_warn "patch does not apply to the $label tree: $(basename "$p")"
            return 1
        fi
        patch_tree_log "applying $(basename "$p")"
        if ! (cd "$dir" && patch -p1 --batch --forward < "$p"); then
            patch_tree_warn "failed to apply $(basename "$p") to the $label tree"
            return 1
        fi
    done
    find "$dir" \( -name '*.rej' -o -name '*.orig' \) -delete
    patch_tree_log "$n patch(es) applied to $dir"
    return 0
}
