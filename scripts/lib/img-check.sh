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
