#!/usr/bin/env bash
# test-installer-e2e.sh — 用合成磁盘跑一遍"主机侧安装器"的完整流程
#
# 为什么要有这个测试：
#   scripts/install-qm1.sh 是"从 Linux 主机把整机镜像写进 eMMC"那条路径，
#   此前只有库级单测（scripts/test-install-lib.sh 测 qm1_hash_range 等函数），
#   整个脚本**一次都没被真正跑过**。而这条脚本历史上出过三类错：
#     * 写盘校验拿整个分区哈希去比镜像（镜像小于分区 ⇒ 每次安装都中止）；
#     * 备份只算自己的 sha256，没有跟"安装前的内容"比对过；
#     * 破坏性写入前的确认与前置检查没有真正生效。
#   单元测试测不出这些 —— 它们只有整条流程跑一遍才会暴露。
#
# 做法：造两个环设备
#   * 目标盘（512 MiB 文件，先写进可识别内容）—— 假装是 eMMC；
#   * 整机镜像（300 MiB，GPT + ESP + 根分区）—— 假装是 qm1-disk.img。
# 然后跑真正的 install-qm1.sh，断言：
#   1) 退出码为 0；
#   2) 备份文件存在，且它的 sha256 == 安装前目标盘内容的 sha256（备份是真的）；
#   3) 备份目录里的 .sha256 能被 sha256sum -c 复核通过；
#   4) 写完的目标盘前 N 字节与镜像一致（cmp -n）；
#   5) 镜像比目标盘大时，安装器必须拒绝并且**一字节都不写**。
#
# 需要 root（losetup）。环境不支持时以 77 退出（CI 里表示跳过）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-qm1.sh"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf 'SKIP: %s\n' "$*"; exit 77; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf '  (warn) %s\n' "$*"; }
FAILED=0

[ "$(id -u)" = "0" ] || skip "需要 root（losetup）"
for c in losetup sfdisk mkfs.vfat blockdev findmnt lsblk sha256sum; do
    command -v "$c" >/dev/null 2>&1 || skip "缺依赖 $c"
done
[ -f "$INSTALLER" ] || { bad "找不到 $INSTALLER"; exit 1; }

WORK="$(mktemp -d /tmp/qm1-install-e2e.XXXXXX)"
cleanup() {
    set +e
    [ -n "${LOOP_TARGET:-}" ] && losetup -d "$LOOP_TARGET" 2>/dev/null
    [ -n "${LOOP_IMAGE:-}" ] && losetup -d "$LOOP_IMAGE" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 1. 造目标盘 ----------
TARGET_IMG="$WORK/target.img"
truncate -s 512M "$TARGET_IMG"
# 写一点可识别内容，确认"备份确实是安装前的样子"
printf 'QM1-PREEXISTING-DATA-DO-NOT-LOSE' | dd of="$TARGET_IMG" bs=1 seek=1048576 conv=notrunc status=none
ORIG_TARGET_SHA="$(sha256sum "$TARGET_IMG" | awk '{print $1}')"

LOOP_TARGET="$(losetup --find --show "$TARGET_IMG" 2>/dev/null)" || skip "losetup 失败（容器里没有 loop 设备？）"
log "目标盘：$LOOP_TARGET"

# ---------- 2. 造整机镜像（GPT + ESP + 根分区）----------
DISK_IMG="$WORK/qm1-disk.img"
truncate -s 300M "$DISK_IMG"
LOOP_IMAGE="$(losetup --find --show "$DISK_IMG" 2>/dev/null)" || skip "losetup 失败"
# ESP = c12a7328-f81f-11d2-ba4b-00a0c93ec93b（EFI 系统分区），根分区 = Linux
cat > "$WORK/part.sfdisk" <<'EOF'
label: gpt
start=1MiB, size=64MiB, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name=QM1ESP
start=65MiB, size=200MiB, type=0fc63daf-8483-4772-8e79-3d69d8477de4, name=QM1ROOT
EOF
sfdisk "$LOOP_IMAGE" < "$WORK/part.sfdisk" >/dev/null 2>&1 || bad "sfdisk 写分区表失败"
udevadm settle 2>/dev/null || true
# ESP 里塞点东西（引导器），根分区做个小 ext4
if [ -b "${LOOP_IMAGE}p1" ]; then
    mkfs.vfat -F 32 -n QM1ESP "${LOOP_IMAGE}p1" >/dev/null 2>&1 \
        || warn "mkfs.vfat 失败（ESP 内容不影响本测试的断言）"
fi
if [ -b "${LOOP_IMAGE}p2" ]; then
    mkfs.ext4 -q -F "${LOOP_IMAGE}p2" >/dev/null 2>&1 \
        || warn "mkfs.ext4 失败（根分区内容不影响本测试的断言）"
fi
log "整机镜像：$LOOP_IMAGE"

# ---------- 3. 跑安装器 ----------
BACKUP_DIR="$WORK/backup"
log "跑 install-qm1.sh（--yes --force-kind，环设备读不出介质类型）"
if bash "$INSTALLER" --image "$DISK_IMG" --target "$LOOP_TARGET" \
        --backup-dir "$BACKUP_DIR" --yes --force-kind > "$WORK/install.log" 2>&1; then
    ok "安装器退出码为 0"
else
    bad "安装器返回非零"
    tail -30 "$WORK/install.log"
fi

# ---------- 4. 断言 ----------
IMAGE_SIZE="$(stat -c%s "$DISK_IMG")"

BACKUP_IMG="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.img' 2>/dev/null | head -1)"
if [ -n "$BACKUP_IMG" ] && [ -f "$BACKUP_IMG" ]; then
    ok "备份文件已生成：$(basename "$BACKUP_IMG")"
    BACKUP_SHA="$(sha256sum "$BACKUP_IMG" | awk '{print $1}')"
    if [ "$BACKUP_SHA" = "$ORIG_TARGET_SHA" ]; then
        ok "备份内容 == 安装前的目标盘（sha256 相同）"
    else
        bad "备份内容与安装前不一致（备份没保住原盘）"
    fi
    if [ -f "$BACKUP_IMG.sha256" ]; then
        ok "备份的 .sha256 校验文件已生成"
        if ( cd "$(dirname "$BACKUP_IMG")" && sha256sum -c "$(basename "$BACKUP_IMG").sha256" >/dev/null 2>&1 ); then
            ok "备份的 .sha256 复核通过"
        else
            bad "备份的 .sha256 复核不过"
        fi
    else
        bad "备份目录里没有 .sha256 校验文件"
    fi
else
    bad "没有找到备份文件（安装器的备份是硬前置）"
fi

if cmp -n "$IMAGE_SIZE" "$DISK_IMG" "$LOOP_TARGET" 2>/dev/null; then
    ok "目标盘已写入镜像（前 $IMAGE_SIZE 字节一致）"
else
    bad "写入内容与镜像不一致"
fi

# ---------- 5. 反向用例：镜像比目标盘大 ⇒ 必须拒绝且不写盘 ----------
BIG_IMG="$WORK/too-big.img"
truncate -s 600M "$BIG_IMG"
SHA_BEFORE="$(sha256sum "$TARGET_IMG" | awk '{print $1}')"
log "跑反向用例（镜像 600M > 目标盘 512M）"
if bash "$INSTALLER" --image "$BIG_IMG" --target "$LOOP_TARGET" \
        --backup-dir "$WORK/backup2" --yes --force-kind > "$WORK/install-big.log" 2>&1; then
    bad "镜像比目标盘大时安装器居然成功了"
else
    ok "镜像比目标盘大时安装器拒绝执行"
fi
SHA_AFTER="$(sha256sum "$TARGET_IMG" | awk '{print $1}')"
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
    ok "拒绝之后目标盘一字节都没动"
else
    bad "拒绝之后目标盘内容变了"
fi

printf '\n'
if [ "$FAILED" = "0" ]; then
    printf '安装器端到端测试全部通过\n'
    exit 0
fi
printf '安装器端到端测试有失败项\n'
exit 1
