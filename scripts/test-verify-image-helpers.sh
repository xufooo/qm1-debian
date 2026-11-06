#!/usr/bin/env bash
# test-verify-image-helpers.sh — 钉住"镜像内路径存在性"的判断语义
#
# 为什么要有这个测试：
#   verify-image.sh 里有一大半检查是"这个文件在不在镜像里"。这条判断以前
#   写成 `if debugfs -R "stat <path>" img >/dev/null 2>&1; then` ——
#   也就是看 debugfs 的**退出码**。
#
#   但 debugfs 是交互式调试器：对不存在的路径它只打印一行
#   "debugfs: stat: File not found"，然后**照样以 0 退出**。
#   于是：
#     * check_exists 永远说"存在" ⇒ 镜像里缺文件，CI 照样绿；
#     * check_absent 永远说"不存在" ⇒ CI 里那三条"标记不该随镜像出厂"
#       反过来炸掉（路径明明不在镜像里，却报 FAIL）。
#
#   现在改成看 stat 输出里有没有 "Inode:" 那一行。这个测试就是防止
#   有人哪天"顺手"把它改回看退出码 —— 那样镜像校验又会形同虚设，
#   而且**不会有一行红字**提醒你。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v debugfs >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
    echo "[SKIP] 需要 e2fsprogs（debugfs + mkfs.ext4）"
    exit 77
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src"
printf 'hello\n' > "$TMP/src/hello.txt"
mkdir -p "$TMP/src/dir"
truncate -s 16M "$TMP/img"
mkfs.ext4 -q -F -d "$TMP/src" "$TMP/img"

# shellcheck disable=SC2034  # IMG 由下面 source 进来的 lib 使用
IMG="$TMP/img"
fail=0
# shellcheck source=lib/img-check.sh
source "$SCRIPT_DIR/lib/img-check.sh"

rc=0
OUT="$TMP/out"
expect() {   # expect <说明> <期望输出片段> <实际输出>
    if grep -qF "$2" <<<"$3"; then
        printf '  [ OK ] %s\n' "$1"
    else
        printf '  [FAIL] %s —— 期望输出里有「%s」，实际是：%s\n' "$1" "$2" "$3"
        rc=1
    fi
}

# ★ 调 helper 时**不能**用 $(...) 捕获输出 ——
#   命令替换是子 shell，里面 fail=$((fail + 1)) 改的是子 shell 的计数，
#   父进程的 fail 纹丝不动 ⇒ 计数断言永远失败（这个坑本仓库踩过好几次：
#   printf | while 也是同一类 —— 子 shell 里丢状态）。
#   所以输出重定向到文件，函数在当前 shell 里跑。
call() {   # call <helper> <参数…>；输出在 ${OUT}，计数在 $fail
    : > "$OUT"
    "$@" > "$OUT"
}

echo "== 先把 debugfs 的行为说清楚（这是整件事的根因） =="
set +e
debugfs -R "stat /definitely-not-here" "$TMP/img" >/dev/null 2>&1
_dbfs_rc=$?
set -e
echo "  debugfs 对不存在的路径返回的退出码：$_dbfs_rc"
if [ "$_dbfs_rc" -eq 0 ]; then
    echo "  （确认：只看退出码会判成「存在」—— 这就是以前的 bug）"
else
    echo "  （这个版本的 debugfs 返回了非零；无论它返回什么，我们的判断都只看输出）"
fi

echo "== check_exists / check_absent 的语义 =="
before="$fail"
call check_exists /hello.txt "文件在镜像里"
expect "存在的文件 ⇒ OK" "OK" "$(cat "$OUT")"
[ "$fail" = "$before" ] || { echo "  [FAIL] 存在的文件不该让失败计数增加"; rc=1; }

call check_exists /definitely-not-here "文件不在镜像里"
expect "不存在的文件 ⇒ FAIL" "FAIL" "$(cat "$OUT")"
[ "$fail" -eq $((before + 1)) ] || { echo "  [FAIL] 不存在的文件必须计一次失败"; rc=1; }

before="$fail"
call check_absent /definitely-not-here "文件不在镜像里"
expect "不存在的文件 ⇒ check_absent 说 OK" "OK" "$(cat "$OUT")"
[ "$fail" = "$before" ] || { echo "  [FAIL] check_absent 不该计失败"; rc=1; }

call check_absent /hello.txt "文件在镜像里"
expect "存在的文件 ⇒ check_absent 说 FAIL" "FAIL" "$(cat "$OUT")"
[ "$fail" -eq $((before + 1)) ] || { echo "  [FAIL] check_absent 必须计一次失败"; rc=1; }

call check_absent /dir "目录"
expect "目录也能认出来（不是只认普通文件）" "FAIL" "$(cat "$OUT")"

if [ "$rc" -eq 0 ]; then
    echo "镜像存在性判断的语义测试全部通过"
else
    echo "语义测试有失败项"
fi
exit "$rc"
