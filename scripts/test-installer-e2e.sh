#!/usr/bin/env bash
# test-installer-e2e.sh — 用合成磁盘跑一遍两个安装器的完整流程
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
# 设备侧安装器（overlay/usr/local/sbin/qm1-install-to-emmc）也一样：
#   它是 QM1 上唯一真正把系统装进 eMMC 的脚本，但 CI 里只做过 lint，
#   它的写盘/校验逻辑一行都没被跑过 ——
#   而"stat 对块设备返回 0 所以断言必挂"这类错，恰恰只有真跑才会暴露。
#
# 做法：造几个环设备
#   * 目标盘（假装是 eMMC，上面已经有一套旧系统）；
#   * 整机镜像（GPT + ESP + 根分区，布局与 assemble-disk.sh 的产物一致）。
# 然后跑真正的安装器，断言：
#   1) 退出码为 0；
#   2) 备份文件存在，且它的 sha256 == 安装前目标盘内容的 sha256；
#   3) 备份**逐分区**与安装前的原盘一致（不是只算备份自己的哈希）；
#   4) 备份目录里的 .sha256 能被 sha256sum -c 复核通过；
#   5) 等大目标：写完的目标盘前 N 字节与镜像一致（cmp -n）；
#   6) 目标更大：分区表按真实容量重建（根分区撑到盘尾）、旧尾部被清零、
#      ESP/根分区内容仍与镜像一致；
#   7) EFI 启动项：要么登记成功，要么**明确失败**并给出补救命令
#      （不许"悄悄跳过"还报成功）；
#   8) 镜像比目标盘大时，安装器必须拒绝并且**一字节都不写**；
#   9) 设备侧安装器在环设备上跑通：目标 ESP 里的引导文件内容与源一致、
#      根分区里有源的文件内容、文件系统撑满、e2fsck 干净（不许停在半路）。
#
# 需要 root（losetup）。环境不支持时以 77 退出（CI 里表示跳过）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$SCRIPT_DIR/install-qm1.sh"
DEVICE_INSTALLER="$REPO_ROOT/overlay/usr/local/sbin/qm1-install-to-emmc"
INSTALL_LIB="$REPO_ROOT/overlay/usr/local/lib/qm1/install-lib.sh"

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
skip() { printf 'SKIP: %s\n' "$*"; exit 77; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf '  (warn) %s\n' "$*"; }
FAILED=0

[ "$(id -u)" = "0" ] || skip "需要 root（losetup）"
for c in losetup sfdisk mkfs.vfat mkfs.ext4 blockdev findmnt lsblk sha256sum dd truncate mount resize2fs; do
    command -v "$c" >/dev/null 2>&1 || skip "缺依赖 $c"
done
command -v e2fsck >/dev/null 2>&1 || skip "缺依赖 e2fsck"
[ -f "$INSTALLER" ] || { bad "找不到 $INSTALLER"; exit 1; }
[ -f "$DEVICE_INSTALLER" ] || { bad "找不到 $DEVICE_INSTALLER"; exit 1; }
[ -f "$INSTALL_LIB" ] || { bad "找不到 $INSTALL_LIB"; exit 1; }

WORK="$(mktemp -d /tmp/qm1-install-e2e.XXXXXX)"
LOOPS=()
cleanup() {
    set +e
    for d in "${LOOPS[@]:-}"; do losetup -d "$d" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 工具函数 ----------

# 造一块 GPT 磁盘：ESP 在 1 MiB，根分区紧跟其后。
# 布局与 scripts/assemble-disk.sh 的产物一致（尾部留 1 MiB 给备份 GPT）。
# 结果放在全局变量 MD_DEV 里 —— 不能用命令替换：
# 命令替换跑在子 shell 里，子 shell 里登记的环设备会随子 shell 一起消失，
# 清理时就漏掉了。
MD_DEV=""
make_disk() {  # $1=镜像文件 $2=总容量 MiB $3=ESP MiB $4=根分区 MiB
    MD_DEV=""
    truncate -s "${2}M" "$1" || return 1
    MD_DEV="$(losetup --partscan --find --show "$1" 2>/dev/null)" || return 1
    LOOPS+=("$MD_DEV")
    {
        echo "label: gpt"
        echo "start=1MiB, size=${3}MiB, type=${ESP_GUID}, name=QM1ESP"
        echo "start=$(( 1 + ${3} ))MiB, size=${4}MiB, type=${LINUX_GUID}, name=QM1ROOT"
    } > "$1.sfdisk"
    sfdisk "$MD_DEV" < "$1.sfdisk" >/dev/null 2>&1 || return 1
    udevadm settle 2>/dev/null || true
    partprobe "$MD_DEV" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    return 0
}

# 给环设备上的两个分区建文件系统
format_parts() {  # $1=环设备
    if [ -b "${1}p1" ]; then
        mkfs.vfat -F 32 -n QM1ESP "${1}p1" >/dev/null 2>&1 \
            || warn "mkfs.vfat 失败（${1}p1）"
    else
        warn "没有出现 ${1}p1（分区设备没出来）"
    fi
    if [ -b "${1}p2" ]; then
        mkfs.ext4 -q -F "${1}p2" >/dev/null 2>&1 \
            || warn "mkfs.ext4 失败（${1}p2）"
    else
        warn "没有出现 ${1}p2（分区设备没出来）"
    fi
}

# 在分区里放一个文件（用来放引导文件 / 标记文件）
put_file() {  # $1=分区设备 $2=相对路径 $3=内容
    _pf_mnt="$WORK/mnt-$$-$RANDOM"
    mkdir -p "$_pf_mnt"
    if mount "$1" "$_pf_mnt" 2>/dev/null; then
        mkdir -p "$(dirname "$_pf_mnt/$2")"
        printf '%s\n' "$3" > "$_pf_mnt/$2"
        sync
        umount "$_pf_mnt" 2>/dev/null || true
        return 0
    fi
    rmdir "$_pf_mnt" 2>/dev/null || true
    return 1
}

# 分区里还有没有这个文件
has_file() {  # $1=分区设备 $2=相对路径
    _hf_mnt="$WORK/mnt-$$-$RANDOM"
    mkdir -p "$_hf_mnt"
    if mount -o ro "$1" "$_hf_mnt" 2>/dev/null; then
        if [ -f "$_hf_mnt/$2" ]; then
            umount "$_hf_mnt" 2>/dev/null || true
            rmdir "$_hf_mnt" 2>/dev/null || true
            return 0
        fi
        umount "$_hf_mnt" 2>/dev/null || true
    fi
    rmdir "$_hf_mnt" 2>/dev/null || true
    return 1
}

# 取分区里某个文件的内容（用来比"内容"，而不是比整分区字节）
file_content() {  # $1=分区设备 $2=相对路径
    _fc_mnt="$WORK/mnt-$$-$RANDOM"
    mkdir -p "$_fc_mnt"
    if mount -o ro "$1" "$_fc_mnt" 2>/dev/null; then
        if [ -f "$_fc_mnt/$2" ]; then
            cat "$_fc_mnt/$2"
            umount "$_fc_mnt" 2>/dev/null || true
            rmdir "$_fc_mnt" 2>/dev/null || true
            return 0
        fi
        umount "$_fc_mnt" 2>/dev/null || true
    fi
    rmdir "$_fc_mnt" 2>/dev/null || true
    return 1
}

# 取整块盘（不是分区）的 sha256
whole_sha() { sha256sum "$1" | awk '{print $1}'; }

# 某个字节区间是不是全 0
#
# 这里**不能**写成 "… | grep -q '[^0]'"：grep -q 命中即退出，
# 上游的 od/tr 会收到 SIGPIPE（141）；本脚本是 set -euo pipefail，
# 管道里任何一环非零 ⇒ 整条管道判失败 ⇒ 本来"全零"的区域
# 反而被报成"不是零"。先把输出收进变量里，再判断里面有没有非零字节。
range_is_zero() {  # $1=文件 $2=偏移 $3=长度
    _riz_hex=""
    _riz_hex="$(dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none \
        | od -An -tx1 | tr -d ' \n')" || return 1
    [ -n "$_riz_hex" ] || return 1
    case "$_riz_hex" in
        *[!0]*) return 1 ;;
    esac
    return 0
}

# 逐分区比对：备份 vs 安装前的原盘（用与安装器同一份实现）
per_partition_ok() {  # $1=原盘环设备 $2=备份文件
    bash -c '
        set -uo pipefail
        . "$1"; shift
        set +e
        qm1_verify_backup "$1" "$2" 0 >/dev/null 2>&1
        exit $?
    ' _ "$INSTALL_LIB" "$1" "$2"
}

# 按分区类型取分区大小（字节）
part_size_by_type() {  # $1=整盘设备 $2=类型 GUID
    lsblk -bnro SIZE,PARTTYPE "$1" 2>/dev/null \
        | awk -v t="$2" '$2==t{print $1; exit}'
}

# ---------- 1. 用例 A：等大目标（512 MiB 目标 / 512 MiB 镜像） ----------
#
# 这是"把镜像原样写进同尺寸的盘"：镜像自带的分区表和文件系统必须原封不动，
# 所以"写进去的字节 == 镜像字节"可以直接核对。
log "用例 A：等大目标（镜像 512 MiB → 目标 512 MiB）"
IMG_A="$WORK/disk-a.img"
make_disk "$IMG_A" 512 64 446 || skip "造镜像失败"
LOOP_IMG_A="$MD_DEV"
format_parts "$LOOP_IMG_A"
put_file "${LOOP_IMG_A}p1" "EFI/BOOT/BOOTIA32.EFI" "FAKE-BOOTLOADER" || warn "放引导文件失败"
IMAGE_SIZE="$(stat -c%s "$IMG_A")"

TGT_A="$WORK/target-a.img"
make_disk "$TGT_A" 512 64 446 || skip "造目标失败"
LOOP_TGT_A="$MD_DEV"
format_parts "$LOOP_TGT_A"
# 旧系统里留一个标记文件：装完必须没有它
put_file "${LOOP_TGT_A}p1" "EFI/BOOT/OLDSYSTEM-MARKER.EFI" "OLD-SYSTEM-MARKER" || warn "放标记文件失败"
ORIG_TARGET_SHA="$(whole_sha "$TGT_A")"
# 装前的原盘留一份 —— 备份要跟它逐分区对得上
TGT_A_PRISTINE="$WORK/target-a-pristine.img"
cp "$TGT_A" "$TGT_A_PRISTINE"
LOOP_TGT_A_PRISTINE="$(losetup --partscan --find --show "$TGT_A_PRISTINE" 2>/dev/null)" || skip "造原盘副本失败"
LOOPS+=("$LOOP_TGT_A_PRISTINE")

BACKUP_DIR_A="$WORK/backup-a"
log "跑 install-qm1.sh --skip-efi-entry"
if bash "$INSTALLER" --image "$IMG_A" --target "$LOOP_TGT_A" \
        --backup-dir "$BACKUP_DIR_A" --yes --force-kind --skip-efi-entry \
        > "$WORK/install-a.log" 2>&1; then
    ok "用例 A：安装器退出码为 0"
else
    bad "用例 A：安装器返回非零"
    tail -30 "$WORK/install-a.log"
fi

BACKUP_IMG_A="$(find "$BACKUP_DIR_A" -maxdepth 1 -name '*.img' 2>/dev/null | head -1)"
if [ -n "$BACKUP_IMG_A" ] && [ -f "$BACKUP_IMG_A" ]; then
    ok "用例 A：备份文件已生成（$(basename "$BACKUP_IMG_A")）"
    if [ "$(whole_sha "$BACKUP_IMG_A")" = "$ORIG_TARGET_SHA" ]; then
        ok "用例 A：备份内容 == 安装前的目标盘（整盘 sha256 相同）"
    else
        bad "用例 A：备份内容与安装前不一致（备份没保住原盘）"
    fi
    if per_partition_ok "$LOOP_TGT_A_PRISTINE" "$BACKUP_IMG_A"; then
        ok "用例 A：备份与安装前的原盘逐分区一致（GPT 头 + 每个分区）"
    else
        bad "用例 A：备份与安装前的原盘逐分区比对不过"
    fi
    if [ -f "$BACKUP_IMG_A.sha256" ]; then
        if ( cd "$(dirname "$BACKUP_IMG_A")" && sha256sum -c "$(basename "$BACKUP_IMG_A").sha256" >/dev/null 2>&1 ); then
            ok "用例 A：备份的 .sha256 复核通过"
        else
            bad "用例 A：备份的 .sha256 复核不过"
        fi
    else
        bad "用例 A：备份目录里没有 .sha256 校验文件"
    fi
else
    bad "用例 A：没有找到备份文件（安装器的备份是硬前置）"
fi

if cmp -n "$IMAGE_SIZE" "$IMG_A" "$LOOP_TGT_A" 2>/dev/null; then
    ok "用例 A：目标盘内容与镜像一致（前 $IMAGE_SIZE 字节）"
else
    bad "用例 A：写入内容与镜像不一致"
fi

if has_file "${LOOP_TGT_A}p1" "EFI/BOOT/OLDSYSTEM-MARKER.EFI"; then
    bad "用例 A：旧系统的标记还在（目标分区没被真正覆盖）"
else
    ok "用例 A：旧系统的标记已被覆盖"
fi

if e2fsck -fn "${LOOP_TGT_A}p2" >/dev/null 2>&1; then
    ok "用例 A：目标根文件系统 e2fsck -fn 干净"
else
    bad "用例 A：目标根文件系统 e2fsck -fn 不干净"
fi

if grep -q '跳过 EFI 启动项登记' "$WORK/install-a.log"; then
    ok "用例 A：--skip-efi-entry 是**明确**跳过的（日志里有说明）"
else
    bad "用例 A：--skip-efi-entry 没有在日志里说明"
fi

# ---------- 2. 用例 B：目标比镜像大 ⇒ 分区表按真实容量重建 ----------
#
# 这正是 6.3 GiB 的镜像写进 28.5 GiB eMMC 的场景：
# 镜像自带的备份 GPT 落在 6.3 GiB 处，老盘的备份 GPT 还在盘尾 ⇒ 两个 GPT；
# 根分区只有 6 GiB，多出来的 22 GiB 全是上一套系统的残留。
# 正确做法：按目标真实容量重建分区表、把根分区撑到盘尾、清掉旧尾部。
log "用例 B：目标 768 MiB > 镜像 512 MiB（必须重建分区表并清掉旧尾部）"
IMG_B="$WORK/disk-b.img"
make_disk "$IMG_B" 512 64 446 || skip "造镜像失败"
LOOP_IMG_B="$MD_DEV"
format_parts "$LOOP_IMG_B"
# 在镜像的根分区里放一个标记文件 —— 后面用它比"内容"，
# 而不是逐字节比整个根分区（扩容之后元数据一定会变）。
put_file "${LOOP_IMG_B}p2" "QM1-MARKER-FILE" "IMAGE-B-CONTENT-MARKER" || warn "放标记文件失败"
IMAGE_SIZE_B="$(stat -c%s "$IMG_B")"

TGT_B="$WORK/target-b.img"
truncate -s 768M "$TGT_B"
LOOP_TGT_B="$(losetup --partscan --find --show "$TGT_B" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_B")
# 给老盘也写一套分区表（模拟"上面已经装过系统"）
printf 'label: gpt\nstart=1MiB, size=64MiB, type=%s\nstart=65MiB, size=700MiB, type=%s\n' \
    "$ESP_GUID" "$LINUX_GUID" | sfdisk "$LOOP_TGT_B" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null || true

if bash "$INSTALLER" --image "$IMG_B" --target "$LOOP_TGT_B" \
        --backup-dir "$WORK/backup-b" --yes --force-kind --skip-efi-entry \
        > "$WORK/install-b.log" 2>&1; then
    ok "用例 B：安装器退出码为 0"
else
    bad "用例 B：安装器返回非零"
    tail -30 "$WORK/install-b.log"
fi

# 根分区必须撑到盘尾（留 1 MiB 给备份 GPT）
ROOT_BYTES_B="$(part_size_by_type "$LOOP_TGT_B" "$LINUX_GUID")"
ROOT_MIB_B=$(( ${ROOT_BYTES_B:-0} / 1048576 ))
if [ "$ROOT_MIB_B" -eq 702 ]; then
    ok "用例 B：根分区已按真实容量重建（702 MiB = 768 - 65 - 1）"
else
    bad "用例 B：根分区大小不对（期望 702 MiB，实际 ${ROOT_MIB_B} MiB）"
fi

# 备份 GPT 必须落在盘尾，而不是镜像末尾那个位置
if dd if="$LOOP_TGT_B" bs=1M skip=767 count=1 status=none 2>/dev/null | grep -q 'EFI PART'; then
    ok "用例 B：备份 GPT 已落在盘尾（最后 1 MiB 内）"
else
    bad "用例 B：盘尾没找到备份 GPT（分区表没按真实容量重建？）"
fi

# 镜像原来的备份 GPT 位置（镜像末尾前 1 MiB）必须已被清零
if range_is_zero "$LOOP_TGT_B" $(( IMAGE_SIZE_B - 1048576 )) 1048576; then
    ok "用例 B：镜像旧备份 GPT 所在区域已清零"
else
    bad "用例 B：镜像旧备份 GPT 所在区域还有残留（两个 GPT 并存）"
fi

# ESP 的内容必须仍然来自镜像。
#
# 注意偏移：**两边都要跳 1 MiB**。镜像文件自己的第 0 字节是它的 GPT 头，
# ESP 是从 1 MiB 开始的；目标盘上 ESP 也在 1 MiB 处。
# 之前这里写成 "cmp -i 1048576:0"，拿镜像的 GPT 头去比目标的 ESP ——
# 必然在第 1 个字节就报"不一致"。
if cmp -i 1048576:1048576 -n $(( 64 * 1048576 )) "$IMG_B" "$LOOP_TGT_B" 2>/dev/null; then
    ok "用例 B：ESP 内容与镜像一致"
else
    bad "用例 B：ESP 内容与镜像不一致"
fi

# 根分区**不能**逐字节比：安装器在撑大文件系统**之前**会做自己的逐字节核对
# （install-qm1.sh 第 7 步），核对通过之后它才 e2fsck + resize2fs ——
# 扩容必然改超级块与块组描述符，元数据全变，逐字节比必然报"不一致"，
# 而那个"不一致"恰恰是设计要的。该比的是**内容**。
if has_file "${LOOP_TGT_B}p2" "QM1-MARKER-FILE"; then
    ok "用例 B：目标根分区里有镜像里的文件内容"
else
    bad "用例 B：目标根分区里没有镜像里的文件（根分区没复制过来？）"
fi
if e2fsck -fn "${LOOP_TGT_B}p2" >/dev/null 2>&1; then
    ok "用例 B：目标根文件系统 e2fsck -fn 干净（撑大之后没停在半路）"
else
    bad "用例 B：目标根文件系统 e2fsck -fn 不干净"
fi

# ---------- 3. 用例 C：EFI 启动项登记必须"要么成功、要么明确失败" ----------
#
# 最坏的结果是"装完了、报成功、但固件里没有启动项" ⇒ 机器开不了机。
# 所以这里用一个**故意失败**的 efibootmgr 桩，
# 断言安装器必须因此判失败并给出可复制的补救命令。
log "用例 C：EFI 启动项登记失败必须显式报错（不许悄悄跳过）"
STUB_DIR="$WORK/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/efibootmgr" <<'EOF'
#!/bin/sh
echo "stub efibootmgr: 故意失败" >&2
exit 1
EOF
chmod +x "$STUB_DIR/efibootmgr"

TGT_C="$WORK/target-c.img"
truncate -s 512M "$TGT_C"
LOOP_TGT_C="$(losetup --partscan --find --show "$TGT_C" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_C")

if PATH="$STUB_DIR:$PATH" bash "$INSTALLER" --image "$IMG_A" --target "$LOOP_TGT_C" \
        --backup-dir "$WORK/backup-c" --yes --force-kind \
        > "$WORK/install-c.log" 2>&1; then
    bad "用例 C：efibootmgr 失败时安装器居然报成功（机器会开不了机）"
else
    ok "用例 C：efibootmgr 失败时安装器判失败"
fi
if grep -q 'efibootmgr' "$WORK/install-c.log" && grep -q 'efibootmgr -c' "$WORK/install-c.log"; then
    ok "用例 C：失败信息里给出了可复制的补救命令"
else
    bad "用例 C：失败信息里没有补救命令"
fi
if grep -q '跳过 EFI 启动项登记' "$WORK/install-c.log"; then
    bad "用例 C：没给 --skip-efi-entry 却显示跳过了 EFI 登记"
else
    ok "用例 C：没有把 EFI 登记失败伪装成'跳过'"
fi

# ---------- 4. 用例 D：反向用例 —— 镜像比目标盘大 ⇒ 拒绝且不写盘 ----------
log "用例 D：镜像 600 MiB > 目标盘 512 MiB（必须拒绝且一字节都不写）"
BIG_IMG="$WORK/too-big.img"
truncate -s 600M "$BIG_IMG"
SHA_BEFORE="$(whole_sha "$TGT_C")"
if bash "$INSTALLER" --image "$BIG_IMG" --target "$LOOP_TGT_C" \
        --backup-dir "$WORK/backup-d" --yes --force-kind --skip-efi-entry \
        > "$WORK/install-d.log" 2>&1; then
    bad "用例 D：镜像比目标盘大时安装器居然成功了"
else
    ok "用例 D：镜像比目标盘大时安装器拒绝执行"
fi
if [ "$(whole_sha "$TGT_C")" = "$SHA_BEFORE" ]; then
    ok "用例 D：拒绝之后目标盘一字节都没动"
else
    bad "用例 D：拒绝之后目标盘内容变了"
fi

# ---------- 5. 用例 E：设备侧安装器在环设备上跑通 ----------
#
# 设备侧安装器才是 QM1 上真正把系统装进 eMMC 的那个脚本。
# CI 里没有真的 SDIO 卡 / ACPI eMMC，所以源和目标都得能由参数给定；
# 断言的重点是"不许停在半路"：写完之后目标分区里有源的内容、
# 文件系统撑满、e2fsck 干净、EFI 登记结果有明确交代。
log "用例 E：设备侧安装器（qm1-install-to-emmc）在环设备上跑通"
SRC_E="$WORK/source-e.img"
make_disk "$SRC_E" 512 64 446 || skip "造源盘失败"
LOOP_SRC_E="$MD_DEV"
format_parts "$LOOP_SRC_E"
put_file "${LOOP_SRC_E}p1" "EFI/BOOT/BOOTIA32.EFI" "FAKE-BOOTLOADER" || warn "放引导文件失败"
put_file "${LOOP_SRC_E}p2" "QM1-MARKER-FILE" "SOURCE-CONTENT-MARKER" || warn "放标记文件失败"

TGT_E="$WORK/target-e.img"
truncate -s 512M "$TGT_E"
LOOP_TGT_E="$(losetup --partscan --find --show "$TGT_E" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_E")

# CI 里没有 UEFI 固件变量（/sys/firmware/efi/efivars），登记不了启动项 ——
# 必须**显式**跳过（--skip-efi-entry），不能让安装器偷偷跳过还报成功。
if bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_E" \
        --source-disk "$LOOP_SRC_E" --source-root "${LOOP_SRC_E}p2" --source-esp "${LOOP_SRC_E}p1" \
        --lib "$INSTALL_LIB" --no-login-account --mode media --yes --skip-efi-entry \
        > "$WORK/install-e.log" 2>&1; then
    ok "用例 E：设备侧安装器退出码为 0"
else
    bad "用例 E：设备侧安装器返回非零"
    tail -40 "$WORK/install-e.log"
fi

if [ -b "${LOOP_TGT_E}p1" ] && [ -b "${LOOP_TGT_E}p2" ]; then
    ok "用例 E：目标上出现了 ESP 与根分区两个分区"
    # 目标 ESP **不能逐字节比**：安装器本来就会改它 ——
    #   6a 步把 EFI/BOOT/grub-normal.cfg 拷成 EFI/BOOT/grub.cfg（换掉安装菜单），
    #   6b 步把 provisioning 写进 /qm1/provision/，
    # FAT 的簇分配、目录项、时间戳都会跟着变 ⇒ 逐字节比必然报"不一致"，
    # 而那个"不一致"恰恰是设计要的。
    # 该比的是**内容**：引导文件必须原封不动搬过去。
    ESP_SRC_BIN="$(file_content "${LOOP_SRC_E}p1" "EFI/BOOT/BOOTIA32.EFI" 2>/dev/null || true)"
    ESP_TGT_BIN="$(file_content "${LOOP_TGT_E}p1" "EFI/BOOT/BOOTIA32.EFI" 2>/dev/null || true)"
    if [ -n "$ESP_SRC_BIN" ] && [ "$ESP_SRC_BIN" = "$ESP_TGT_BIN" ]; then
        ok "用例 E：目标 ESP 里的引导文件与源一致"
    else
        bad "用例 E：目标 ESP 里的引导文件与源不一致"
    fi
    # 根文件系统不能逐字节比：安装器会在目标里写安装记录，
    # 文件系统元数据随之变化 ⇒ 只能比"内容"。
    if has_file "${LOOP_TGT_E}p2" "QM1-MARKER-FILE"; then
        ok "用例 E：目标根分区里有源的文件内容"
    else
        bad "用例 E：目标根分区里没有源的文件（根分区没复制过来？）"
    fi
    if e2fsck -fn "${LOOP_TGT_E}p2" >/dev/null 2>&1; then
        ok "用例 E：目标根文件系统 e2fsck -fn 干净（没停在半路）"
    else
        bad "用例 E：目标根文件系统 e2fsck -fn 不干净"
    fi
    if has_file "${LOOP_TGT_E}p1" "EFI/BOOT/BOOTIA32.EFI"; then
        ok "用例 E：目标 ESP 里有引导文件"
    else
        bad "用例 E：目标 ESP 里没有引导文件"
    fi
else
    bad "用例 E：目标上没有出现预期的分区（写盘停在了半路）"
fi

if grep -q '已登记 UEFI 启动项' "$WORK/install-e.log" \
   || grep -q 'UEFI 启动项 : 未登记' "$WORK/install-e.log"; then
    ok "用例 E：EFI 启动项的结果有明确交代（登记了或明说没登记）"
else
    bad "用例 E：EFI 启动项的结果没有任何交代（等于悄悄跳过）"
fi
if grep -q '显式跳过 EFI 启动项登记' "$WORK/install-e.log"; then
    ok "用例 E：跳过 EFI 登记是**显式**的（日志里写明了）"
else
    bad "用例 E：日志里没有说明 EFI 登记被显式跳过"
fi

# ---------- 6. 用例 F：设备侧安装器在 EFI 登记不上时必须显式失败 ----------
#
# 与用例 C 同一个道理，但针对设备侧安装器（QM1 上真正装 eMMC 的那个脚本）：
# 系统写好了、固件里却没有启动项 —— 报告说"装好了"，用户重开机才发现开不了机。
# 所以：不给 --skip-efi-entry 时，登记不上必须判失败并给出补救命令。
log "用例 F：设备侧安装器的 EFI 登记失败必须显式报错（不许悄悄报成功）"
TGT_F="$WORK/target-f.img"
truncate -s 512M "$TGT_F"
LOOP_TGT_F="$(losetup --partscan --find --show "$TGT_F" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_F")

# **显式注入登记失败**。
# 以前这个用例靠"CI 里没有 UEFI 固件变量，登记自然失败"来制造失败 ——
# 但 GitHub 的 Ubuntu runner 其实**有** UEFI（/sys/firmware/efi/efivars 在），
# 而且装了 efibootmgr，于是登记真的成功、安装器退出 0，
# 用例反过来判"安装器居然报成功" ⇒ 红的是测试，不是被测代码。
# 现在放一个必然失败的 efibootmgr 桩到 PATH 最前面：
# 安装器用 `command -v efibootmgr` + 裸名调用 efibootmgr，PATH 桩对它有效。
STUB_BIN_F="$WORK/stub-bin-f"
mkdir -p "$STUB_BIN_F"
cat > "$STUB_BIN_F/efibootmgr" <<'STUB_EOF'
#!/bin/sh
echo "stub efibootmgr: 这个用例就是要它失败" >&2
exit 1
STUB_EOF
chmod +x "$STUB_BIN_F/efibootmgr"

if PATH="$STUB_BIN_F:$PATH" bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_F" \
        --source-disk "$LOOP_SRC_E" --source-root "${LOOP_SRC_E}p2" --source-esp "${LOOP_SRC_E}p1" \
        --lib "$INSTALL_LIB" --no-login-account --mode media --yes \
        > "$WORK/install-f.log" 2>&1; then
    bad "用例 F：EFI 登记失败时设备侧安装器居然报成功（重开机可能开不了机）"
    tail -30 "$WORK/install-f.log"
else
    ok "用例 F：EFI 登记失败时设备侧安装器判失败"
fi
if grep -q 'efibootmgr' "$WORK/install-f.log" && grep -q 'efibootmgr -c' "$WORK/install-f.log"; then
    ok "用例 F：失败信息里给出了可复制的补救命令"
else
    bad "用例 F：失败信息里没有补救命令"
    tail -20 "$WORK/install-f.log"
fi
if grep -q '显式跳过 EFI 启动项登记' "$WORK/install-f.log"; then
    bad "用例 F：没给 --skip-efi-entry 却显示跳过了 EFI 登记"
else
    ok "用例 F：没有把 EFI 登记失败伪装成'跳过'"
fi

printf '\n'
if [ "$FAILED" = "0" ]; then
    printf '安装器端到端测试全部通过\n'
    exit 0
fi
printf '安装器端到端测试有失败项\n'
exit 1
