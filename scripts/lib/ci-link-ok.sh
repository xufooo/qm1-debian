# shellcheck shell=bash
# ci-link-ok.sh —— CI 断言辅助：判断「镜像里的软链」能否解析到「镜像里的真实文件」
#
# 为什么需要它：
#   镜像里的 systemd wants 链接基本都是**绝对路径**（/lib/systemd/system/...），
#   而 CI 的检查是在宿主机上对着 build/rootfs 这个目录做的。
#   直接写 [ -e "$ROOT/etc/systemd/system/multi-user.target.wants/foo.service" ] 时，
#   内核会跟随软链去**宿主机**的 / 下面找目标 —— 宿主机上当然没有镜像里的单元文件，
#   于是镜像里明明存在的单元也会被判成「悬空链接」（假阴性，会把好镜像判死）。
#   这个函数把绝对目标拼回 $ROOT 再判断，相对目标则按链接所在目录解析。
#
# 用法：
#   source scripts/lib/ci-link-ok.sh
#   link_ok "$ROOT/etc/systemd/system/multi-user.target.wants/foo.service" \
#     || { echo "::error::foo.service 的 wants 链接是悬空的"; exit 1; }
#
# 注意：调用方必须先定义 ROOT（镜像根目录）。

link_ok() {
    _lo_path="$1"
    [ -L "$_lo_path" ] || return 1
    _lo_t="$(readlink "$_lo_path" 2>/dev/null || true)"
    case "$_lo_t" in
        /*) _lo_resolved="$ROOT$_lo_t" ;;
        "")  return 1 ;;
        *)  _lo_resolved="$(dirname "$_lo_path")/$_lo_t" ;;
    esac
    [ -e "$_lo_resolved" ]
}

# 打印链接目标（报错信息里用，让人一眼看出指向哪儿）
link_target() {
    readlink "$1" 2>/dev/null || true
}
