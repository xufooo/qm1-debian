# shellcheck shell=bash
# 镜像内路径的存在性判断 —— verify-image.sh 与它的单测共用**这一份**实现。
#
# ★ 判断"路径在不在"必须看 debugfs 的**输出**，不能看它的退出码。
#   debugfs 是交互式调试器：对不存在的路径它只打印一行
#   "debugfs: stat: File not found"，然后**照样以 0 退出**。
#   以前 verify-image.sh 用 `debugfs ... >/dev/null 2>&1` 的退出码判断，
#   结果是：
#     check_exists 永远报"存在"（假绿）—— 整个镜像存在性校验形同虚设；
#     check_absent 永远报"不存在"（假红）—— CI 里那三条"标记没随镜像出厂"
#       就是这么炸的：路径明明不在镜像里，debugfs 却返回 0。
#   现在统一看 stat 输出里有没有 "Inode:" 那一行：存在才有。
#
# 用法：调用方先设好 IMG（镜像路径）与 fail（失败计数），再 source 本文件。
# IMG="$1"
# fail=0

_img_stat() {   # 打印 debugfs 对某个路径的 stat 文本
    debugfs -R "stat $1" "$IMG" 2>&1 || true
}

_img_has() {    # 镜像里有这个路径吗（0 = 有）
    grep -q '^Inode:' <<<"$(_img_stat "$1")"
}

check_empty_directory() {
    local dir="$1" description="$2" listing entries
    listing="$(debugfs -R "ls -p $dir" "$IMG" 2>/dev/null || true)"
    if ! grep -qE '^/[0-9]+/[0-7]+/' <<<"$listing"; then
        printf '  FAIL %s (cannot read directory: %s)\n' "$description" "$dir"
        fail=$((fail + 1))
        return
    fi
    entries="$(awk -F/ '$6!="." && $6!=".." && $6!="" {print $6}' <<<"$listing")"
    if [ -z "$entries" ]; then
        printf '  OK   %-46s (%s)\n' "$dir" "$description"
    else
        printf '  FAIL %-46s (%s: %s)\n' "$dir" "$description" "$entries"
        fail=$((fail + 1))
    fi
}

# 存在性检查：debugfs -R "stat <path>"
check_exists() {
    local path="$1" desc="$2"
    if _img_has "$path"; then
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    else
        printf '  FAIL %-46s (%s) —— 镜像里没有这个路径\n' "$path" "$desc"
        fail=$((fail + 1))
    fi
}

# 反过来：路径必须**不在**镜像里（首启标记、部署标记这类东西不能随镜像出厂）
check_absent() {
    local path="$1" desc="$2"
    if _img_has "$path"; then
        printf '  FAIL %-46s (%s)\n' "$path" "$desc"
        fail=$((fail + 1))
    else
        printf '  OK   %-46s (%s)\n' "$path" "$desc"
    fi
}

# Check the packaged module, not just the build tree or a config symbol.
check_kernel_driver() {
    local version="$1" module="$2" symbol="$3" description="$4"
    local config index path
    config="$(debugfs -R "cat /boot/config-$version" "$IMG" 2>/dev/null || true)"
    if grep -qx "CONFIG_$symbol=y" <<<"$config"; then
        printf '  OK   %s (builtin: %s)\n' "$description" "$symbol"
        return
    fi
    if grep -qx "CONFIG_$symbol=m" <<<"$config"; then
        index="$(debugfs -R "cat /lib/modules/$version/modules.dep" "$IMG" 2>/dev/null || true)"
        path="$(awk -F: -v module="$module" '
            { n=split($1, parts, "/"); name=parts[n]
              sub(/\.ko(\.(xz|zst|gz))?$/, "", name)
              if (name==module) { print $1; exit } }' <<<"$index")"
        if [ -n "$path" ] && _img_has "/lib/modules/$version/$path"; then
            printf '  OK   %s (indexed module: %s)\n' "$description" "$path"
            return
        fi
    fi
    printf '  FAIL %s (missing config, indexed module or payload: %s)\n' "$description" "$symbol"
    fail=$((fail + 1))
}

# debugfs ls -l prints numeric modes, not Unix "-rwx" strings. Use its
# machine-readable ls -p format: /inode/mode/uid/gid/name/size/.
check_no_group_writable() {
    local dir="$1" description="$2" listing bad
    listing="$(debugfs -R "ls -p $dir" "$IMG" 2>/dev/null || true)"
    if ! grep -qE '^/[0-9]+/[0-7]+/' <<<"$listing"; then
        printf '  FAIL %s (cannot read directory modes: %s)\n' "$description" "$dir"
        fail=$((fail + 1))
        return
    fi
    bad="$(awk -F/ '$3 ~ /^100/ {
        mode=$3
        if (substr(mode,length(mode)-1,1) ~ /[2367]/ ||
            substr(mode,length(mode),1) ~ /[2367]/) print $0
    }' <<<"$listing")"
    if [ -z "$bad" ]; then
        printf '  OK   %s\n' "$description"
    else
        printf '  FAIL %s\n%s\n' "$description" "$bad"
        fail=$((fail + 1))
    fi
}
