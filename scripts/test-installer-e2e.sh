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
    # tmpfs（用例 G 的备份目录）要先卸载，否则 rm -rf 删的是挂载点里的内容，
    # 挂载本身还留在内核里。
    umount "$WORK/tiny-backup" 2>/dev/null || true
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

# 某个字节区间里有没有 GPT 头的签名 "EFI PART"
#
# 同样不能用 grep -q（命中即退出 ⇒ 上游 dd 收 SIGPIPE(141) ⇒
# set -euo pipefail 下管道判失败）。用 grep -c：它把整个输入读完，
# 退出码非零也只表示"没找到"，不影响 dd 的状态。
gpt_sig_at() {  # $1=文件 $2=偏移；0 = 那一带里找到了 "EFI PART"
    _gsa_count="$(dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count=1M status=none 2>/dev/null \
        | grep -ac 'EFI PART')" || _gsa_count=0
    [ "${_gsa_count:-0}" -gt 0 ]
}

# 分区里某个文件的权限位（八进制，如 600）
file_mode() {  # $1=分区设备 $2=相对路径
    _fm_mnt="$WORK/mnt-$$-$RANDOM"
    mkdir -p "$_fm_mnt"
    if mount -o ro "$1" "$_fm_mnt" 2>/dev/null; then
        if [ -f "$_fm_mnt/$2" ]; then
            stat -c '%a' "$_fm_mnt/$2" 2>/dev/null || stat -f '%Lp' "$_fm_mnt/$2" 2>/dev/null
            umount "$_fm_mnt" 2>/dev/null || true
            rmdir "$_fm_mnt" 2>/dev/null || true
            return 0
        fi
        umount "$_fm_mnt" 2>/dev/null || true
    fi
    rmdir "$_fm_mnt" 2>/dev/null || true
    return 1
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
#
# 用 grep -c 而不是 grep -q：grep -q 一命中就退出，上游的 dd 会收到
# SIGPIPE（141）；本脚本是 set -euo pipefail，管道里任何一环非零 ⇒
# 整条管道判失败（这个坑本脚本里踩过两次了）。
if gpt_sig_at "$LOOP_TGT_B" $(( 767 * 1048576 )); then
    ok "用例 B：备份 GPT 已落在盘尾（最后 1 MiB 内）"
else
    bad "用例 B：盘尾没找到备份 GPT（分区表没按真实容量重建？）"
fi

# 镜像原来的备份 GPT 头必须不再是有效的 GPT 头。
#
# 注意判据不是"那一段必须全零"：镜像的旧备份 GPT 在镜像末尾前 1 MiB 里，
# 而目标盘比镜像大、根分区又撑到了盘尾 ⇒ 那一段现在属于根文件系统，
# 装的是根文件系统的字节，本来就该是非零。要判的是"旧备份 GPT 还在不在"：
# 它的头在镜像的最后一个扇区（IMAGE_SIZE_B - 512），签名是 "EFI PART"。
if gpt_sig_at "$LOOP_TGT_B" $(( IMAGE_SIZE_B - 512 )); then
    bad "用例 B：镜像旧备份 GPT 的头还在原处（两个 GPT 并存）"
else
    ok "用例 B：镜像旧备份 GPT 已不再是有效 GPT 头"
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
# media 分支的安装器会顺手把整盘备份到 /var/tmp（每个 512 MiB）——
# 用完就删，别让 CI 磁盘被这几个副本吃满。
rm -f /var/tmp/qm1-target-preinstall-*.img /var/tmp/qm1-target-metadata-*.img 2>/dev/null || true

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
# media 分支顺手做的那份整盘备份落在 /var/tmp（每个 512 MiB）——用完就删。
rm -f /var/tmp/qm1-target-preinstall-*.img /var/tmp/qm1-target-metadata-*.img 2>/dev/null || true

# ---------- 7. 用例 E2：设备侧安装器的 emmc 分支（QM1 上真正的那条路） ----------
#
# 用例 E 走的是 --mode media；QM1 上真正把系统装进 eMMC 走的是 --mode emmc ——
# 而 emmc 分支有一整套 media 分支没有的东西：覆盖前强制整盘备份、备份与原盘
# 逐分区 sha256 比对、备份位置的四级搜索、按目标真实容量重建 GPT、
# 撑满整盘、写安装记录。**这条分支在 CI 里从来没有被跑过** ——
# 而历史错误（dd 的 seek 以块为单位、备份偏移放大 4 倍）恰好全藏在这条分支里。
#
# CI 里没有真的 ACPI eMMC，环设备被内核报成别的类型 ⇒ 用 --force-kind emmc
# 把它"说成" eMMC（安装器本来就支持这个开关，主机侧脚本早就有）。
log "用例 E2：设备侧安装器的 emmc 分支（整盘备份 + 重建分区表 + 撑满整盘）"
SRC_G="$WORK/source-g.img"
make_disk "$SRC_G" 512 64 446 || skip "造源盘失败"
LOOP_SRC_G="$MD_DEV"
format_parts "$LOOP_SRC_G"
put_file "${LOOP_SRC_G}p1" "EFI/BOOT/BOOTIA32.EFI" "FAKE-BOOTLOADER" || warn "放引导文件失败"
# 源 ESP 上同时放"安装菜单"和"正常菜单"：6a 步要用后者换掉前者。
# 目标里要是还留着安装菜单，重开机就会又走进安装流程 —— 这是刷机后最恶心的坑。
put_file "${LOOP_SRC_G}p1" "EFI/BOOT/grub.cfg" \
    "menuentry 'install to eMMC' { linux /qm1.install=1 qm1.install.mode=emmc }" \
    || warn "放安装菜单失败"
put_file "${LOOP_SRC_G}p1" "EFI/BOOT/grub-normal.cfg" "normal boot menu" || warn "放正常菜单失败"
put_file "${LOOP_SRC_G}p2" "QM1-MARKER-FILE" "SOURCE-CONTENT-MARKER" || warn "放标记文件失败"

TGT_G="$WORK/target-g.img"
truncate -s 512M "$TGT_G"
LOOP_TGT_G="$(losetup --partscan --find --show "$TGT_G" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_G")

BACKUP_G="$WORK/backup-g"
mkdir -p "$BACKUP_G"

if bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_G" \
        --source-disk "$LOOP_SRC_G" --source-root "${LOOP_SRC_G}p2" --source-esp "${LOOP_SRC_G}p1" \
        --lib "$INSTALL_LIB" --no-login-account --mode emmc --force-kind emmc --yes --skip-efi-entry \
        --backup-dir "$BACKUP_G" \
        > "$WORK/install-g.log" 2>&1; then
    ok "用例 E2：设备侧安装器的 emmc 分支退出码为 0"
    _e2_rc=0
else
    _e2_rc=$?
    bad "用例 E2：设备侧安装器的 emmc 分支返回非零（退出码 ${_e2_rc}）"
    # ★ 整份日志都打出来，不要只打尾部。
    #   上一版只 tail -40，结果 shell 的 stdout 是块缓冲的、stderr 是不缓冲的，
    #   两者的先后顺序在文件里是乱的 ⇒ 出错那几行可能落在前面被 tail 切掉，
    #   于是"为什么失败"完全看不到。退出码也要打出来 —— 被信号杀掉时
    #   退出码是 128+信号号（137 = SIGKILL，通常是 OOM）。
    echo "---- 安装器完整输出（退出码 ${_e2_rc}）----"
    cat "$WORK/install-g.log"
    echo "---- 安装器输出结束 ----"
fi

# (1) 覆盖前必须留下整盘备份 —— 这是"还能装回原版系统"的唯一保障。
BACKUP_FILE_G="$(find "$BACKUP_G" -maxdepth 1 -type f -name 'qm1-emmc-preinstall-*' | head -1)"
if [ -n "$BACKUP_FILE_G" ]; then
    ok "用例 E2：覆盖前做了整盘备份（$(basename "$BACKUP_FILE_G")）"
    _bg_size="$(stat -c '%s' "$BACKUP_FILE_G" 2>/dev/null || stat -f '%z' "$BACKUP_FILE_G" 2>/dev/null || echo 0)"
    _tg_size="$(stat -c '%s' "$TGT_G" 2>/dev/null || stat -f '%z' "$TGT_G" 2>/dev/null || echo 0)"
    if [ "${_bg_size:-0}" = "${_tg_size:-0}" ] && [ "${_tg_size:-0}" -gt 0 ]; then
        ok "用例 E2：备份大小等于整盘大小（是整盘副本，不是分区表）"
    else
        bad "用例 E2：备份大小 ${_bg_size} 与整盘 ${_tg_size} 不一致"
    fi
else
    bad "用例 E2：没有找到整盘备份文件"
fi

# (2) 目标必须按真实容量重建分区表：正好两个分区、类型 GUID 正确、ESP 起于 1 MiB。
SF_G="$(sfdisk -d "$LOOP_TGT_G" 2>/dev/null || true)"
_g_parts="$(printf '%s\n' "$SF_G" | grep -c ' type=' || true)"
if [ "${_g_parts:-0}" = "2" ]; then
    ok "用例 E2：目标盘上正好两个分区"
else
    bad "用例 E2：目标盘上有 ${_g_parts:-0} 个分区（应该是 2）"
fi
if printf '%s\n' "$SF_G" | grep -qi "type=$ESP_GUID"; then
    ok "用例 E2：ESP 的分区类型 GUID 正确"
else
    bad "用例 E2：ESP 的分区类型 GUID 不对"
fi
if printf '%s\n' "$SF_G" | grep -qi "type=$LINUX_GUID"; then
    ok "用例 E2：根分区的分区类型 GUID 正确"
else
    bad "用例 E2：根分区的分区类型 GUID 不对"
fi
# ★ 取 ESP 的起始扇区。
#   util-linux 的 sfdisk -d 会把数值**按列对齐**打印：
#       start=        2048, size=       131072, type=c12a7328-…
#   数字和 "start=" 之间有一串空格 ⇒ 按空白切字段再找 /^start=/ 是找不到的
#   （切出来的是裸的 "start="，数字被切到下一个字段去了）。
#   所以这里在**整行**上用正则取数，不切字段。
#   ★ 断言只认 sfdisk 这一个来源：它是磁盘上真正的 GPT，别拿第二个来源
#     来"凑"一个判定 —— 两个来源不一致时该查的是谁错了，而不是放宽断言。
_g_esp_line="$(printf '%s\n' "$SF_G" | awk -v t="$ESP_GUID" '!seen && index(tolower($0), t) { print; seen=1 }')"
_g_esp_start="$(printf '%s' "$_g_esp_line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if [ "${_g_esp_start:-}" = "2048" ]; then
    ok "用例 E2：ESP 起于 1 MiB（扇区 2048）"
else
    bad "用例 E2：ESP 的起始扇区是 ${_g_esp_start:-?}（应该是 2048；sfdisk 行：${_g_esp_line:-?}）"
fi
# 交叉核对（只作参考，不参与判定）：lsblk 的 START 列**永远是扇区**，
# 不是字节 —— 即使加了 -b（那个开关只影响 SIZE 等尺寸列）。
# ESP 起于 1 MiB ⇒ 2048 个 512 字节扇区。
# 之前这里以为 START 是字节、拿 1048576 去比，于是每次都报一条
# "与 sfdisk 不一致，值得看一眼" 的假警告。
_g_esp_start_sectors="$(lsblk -bnro START,PARTTYPE "$LOOP_TGT_G" 2>/dev/null \
    | awk -v t="$ESP_GUID" 'tolower($2) == t { print $1; exit }')"
if [ -n "${_g_esp_start_sectors:-}" ] && [ "$_g_esp_start_sectors" != "2048" ]; then
    warn "用例 E2：lsblk 报的 ESP 起始是 ${_g_esp_start_sectors} 扇区（应为 2048）—— 与 sfdisk 不一致，值得看一眼"
fi

# (3) 整盘上只能有两份 GPT 头（主表 + 盘尾备份表），不能有第三份留在中间。
#     主机侧那条路径曾经把"内容大小的镜像"写进 28.5 GiB 的盘 ⇒ 镜像自带的
#     备份 GPT 留在 6.3 GiB 处，盘尾还有旧的一份 ⇒ 一盘三份 GPT。
_g_gpt_count="$(grep -abo 'EFI PART' "$TGT_G" 2>/dev/null | wc -l | tr -d ' ')"
# ★ GPT 的备份头在**最后一个扇区**（LBA 总数 - 1），不是"尾部留 1 MiB 里的第 33 个扇区"。
#   512 MiB 的盘 ⇒ 最后一个扇区的起始字节 = 512*1024*1024 - 512 = 536870400。
#   之前按 "尾部 33 个扇区" 算成了 536854016，于是"备份 GPT 在盘尾"这条永远不过。
_g_gpt_tail=$(( 512 * 1024 * 1024 - 512 ))
_g_gpt_offsets="$(grep -abo 'EFI PART' "$TGT_G" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
if [ "${_g_gpt_count:-0}" = "2" ]; then
    ok "用例 E2：整盘上只有两份 GPT 头（主表 + 盘尾备份表）"
else
    bad "用例 E2：整盘上有 ${_g_gpt_count:-0} 份 GPT 头（应该是 2），偏移：${_g_gpt_offsets:-}"
fi
_g_gpt_tail_ok=0
for _g_off in $_g_gpt_offsets; do
    [ "$_g_off" = "$_g_gpt_tail" ] && _g_gpt_tail_ok=1
done
if [ "$_g_gpt_tail_ok" = "1" ]; then
    ok "用例 E2：备份 GPT 落在盘尾（偏移 ${_g_gpt_tail}）"
else
    bad "用例 E2：盘尾没有备份 GPT（偏移：${_g_gpt_offsets:-}）"
fi

# (4) 目标 ESP 里必须是正常菜单，不能还留着安装菜单。
_g_menu="$(file_content "${LOOP_TGT_G}p1" "EFI/BOOT/grub.cfg" 2>/dev/null || true)"
if [ -n "$_g_menu" ] && ! printf '%s' "$_g_menu" | grep -q 'qm1.install=1'; then
    ok "用例 E2：目标 ESP 里换成了正常菜单（不再重入安装）"
else
    bad "用例 E2：目标 ESP 里还是安装菜单或没有菜单"
fi

# (5) 安装记录必须写进目标根分区，权限 0600，内容标明是 emmc 模式。
if has_file "${LOOP_TGT_G}p2" "etc/qm1-installed-to-emmc"; then
    ok "用例 E2：目标根分区里写了安装记录"
    _g_rec="$(file_content "${LOOP_TGT_G}p2" "etc/qm1-installed-to-emmc" 2>/dev/null || true)"
    if printf '%s' "$_g_rec" | grep -q 'mode=emmc'; then
        ok "用例 E2：安装记录标明 mode=emmc"
    else
        bad "用例 E2：安装记录里没有 mode=emmc"
    fi
    _g_mode="$(file_mode "${LOOP_TGT_G}p2" "etc/qm1-installed-to-emmc" 2>/dev/null || echo '?')"
    if [ "$_g_mode" = "600" ]; then
        ok "用例 E2：安装记录权限是 0600"
    else
        bad "用例 E2：安装记录权限是 ${_g_mode}（应该是 600）"
    fi
else
    bad "用例 E2：目标根分区里没有安装记录"
fi

# (6) 根文件系统撑满整盘且干净。
if has_file "${LOOP_TGT_G}p2" "QM1-MARKER-FILE"; then
    ok "用例 E2：目标根分区里有源的文件内容"
else
    bad "用例 E2：目标根分区里没有源的文件"
fi
if e2fsck -fn "${LOOP_TGT_G}p2" >/dev/null 2>&1; then
    ok "用例 E2：目标根文件系统 e2fsck -fn 干净"
else
    bad "用例 E2：目标根文件系统 e2fsck -fn 不干净"
fi
_g_root_mib="$(lsblk -bnro SIZE "${LOOP_TGT_G}p2" 2>/dev/null | head -1)"
if [ "${_g_root_mib:-0}" -gt 400000000 ] 2>/dev/null; then
    ok "用例 E2：根分区撑满了（${_g_root_mib:-?} 字节）"
else
    bad "用例 E2：根分区只有 ${_g_root_mib:-?} 字节（没撑满整盘）"
fi

# (7) 日志必须写明做了整盘备份。
if grep -q '整盘备份' "$WORK/install-g.log"; then
    ok "用例 E2：日志写明了整盘备份"
else
    bad "用例 E2：日志里没有整盘备份的记录"
fi

# ---------- 8. 用例 G：备份位置放不下 ⇒ 必须中止，且目标盘一字节都不动 ----------
#
# 为什么要有这条：
#   覆盖 eMMC 之前必须先有整盘备份，这是"还能装回原版系统"的唯一保障。
#   如果备份位置放不下，正确行为是**中止并且什么都不写** ——
#   绝不能"先写了再说"。这条以前没被测过：安装器会先去找备份位置，
#   找不到就 die；但"找到的位置空间不够"这条分支从来没被走过。
#
# 做法：挂一个 1 MiB 的 tmpfs 当备份目录（要 root，CI 里是 sudo 跑的），
#   目标盘是 512 MiB ⇒ 备份目录必然放不下。
log "用例 G：备份位置空间不足（必须中止，目标零改动）"
SMALL_DIR="$WORK/tiny-backup"
mkdir -p "$SMALL_DIR"
if mount -t tmpfs -o size=1M tmpfs "$SMALL_DIR" 2>/dev/null; then
    TGT_G2="$WORK/target-g2.img"
    truncate -s 512M "$TGT_G2"
    LOOP_TGT_G2="$(losetup --partscan --find --show "$TGT_G2" 2>/dev/null)" || skip "造目标失败"
    LOOPS+=("$LOOP_TGT_G2")
    _g2_before="$(whole_sha "$TGT_G2")"

    if bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_G2" \
            --source-disk "$LOOP_SRC_G" --source-root "${LOOP_SRC_G}p2" --source-esp "${LOOP_SRC_G}p1" \
            --lib "$INSTALL_LIB" --no-login-account --mode emmc --force-kind emmc --yes --skip-efi-entry \
            --backup-dir "$SMALL_DIR" \
            > "$WORK/install-g2.log" 2>&1; then
        bad "用例 G：备份位置明明放不下，安装器却报了成功"
        tail -30 "$WORK/install-g2.log"
    else
        ok "用例 G：备份位置放不下时安装器判失败"
        if grep -q '空间不足' "$WORK/install-g2.log"; then
            ok "用例 G：失败原因说清了是空间不足"
        else
            bad "用例 G：失败信息里没有说明是空间不足"
            tail -20 "$WORK/install-g2.log"
        fi
    fi

    _g2_after="$(whole_sha "$TGT_G2")"
    if [ "$_g2_before" = "$_g2_after" ]; then
        ok "用例 G：中止之后目标盘一字节都没动"
    else
        bad "用例 G：中止之后目标盘被改了（整盘 sha256 变了）"
    fi

    umount "$SMALL_DIR" 2>/dev/null || true
else
    warn "用例 G：挂不了 tmpfs，跳过（内核不允许？）"
fi

# E2 的备份文件占了 512 MiB，后面两个用例还要再建目标盘 ——
# 先把它删掉腾地方（断言早就做完了）。
rm -f "$BACKUP_FILE_G" 2>/dev/null || true

# ---------- 9. 用例 H：备份内容坏了 ⇒ 必须中止，且目标一字节都不能写 ----------
#
# 为什么要有这条：
#   "覆盖前必须留一份能装回去的备份"是这条安装路径的安全底线。
#   比对逻辑（qm1_verify_backup）自己是有测试的（scripts/test-install-lib.sh
#   里改一个字节就能被发现），但**安装器接到"比对失败"之后怎么办**，
#   此前没有任何测试覆盖过 —— 而这里如果处理错了，代价是"备份不可信还照样
#   把整盘擦掉"，用户连退路都没有。
#
# 做法：给安装器一个**包装库**（--lib 指向它）：包装库先加载真库，再把
#   qm1_verify_backup 包一层 —— 在比对之前，先把备份源里的一个字节改掉
#   （模拟"介质掉电/写入被截断"）。真比对逻辑一行没改，
#   所以"发现不一致"这件事是真逻辑做出来的，不是测试自己判的。
log "用例 H：备份内容被改坏 ⇒ 安装器必须中止且不写目标"
WRAP_LIB="$WORK/install-lib-tamper.sh"
cat > "$WRAP_LIB" <<WRAP_EOF
#!/bin/bash
# 包装库：先加载真库，再把 qm1_verify_backup 包一层。
#
# 在比对之前，把备份源里的一个字节改掉 —— 模拟"备份写到一半被改坏 /
# 介质掉电"。真比对逻辑一行没改，所以"发现不一致"是真逻辑做出来的。
. "$INSTALL_LIB"
eval "\$(declare -f qm1_verify_backup | sed '1s/qm1_verify_backup/qm1_verify_backup_orig/')"
qm1_verify_backup() {
    local target="\$1" bsrc="\$2" base="\$3"
    # offset 4096 落在 GPT 区（前 1 MiB）里 —— 比对的第一项就会发现不一致。
    printf 'X' | dd of="\$bsrc" bs=1 seek=\$(( base + 4096 )) count=1 conv=notrunc status=none 2>/dev/null || true
    qm1_verify_backup_orig "\$target" "\$bsrc" "\$base"
}
WRAP_EOF

TGT_H="$WORK/target-h.img"
truncate -s 512M "$TGT_H"
LOOP_TGT_H="$(losetup --partscan --find --show "$TGT_H" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_H")
BACKUP_H="$WORK/backup-h"
mkdir -p "$BACKUP_H"
_h_before="$(whole_sha "$TGT_H")"

if bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_H" \
        --source-disk "$LOOP_SRC_G" --source-root "${LOOP_SRC_G}p2" --source-esp "${LOOP_SRC_G}p1" \
        --lib "$WRAP_LIB" --no-login-account --mode emmc --force-kind emmc --yes --skip-efi-entry \
        --backup-dir "$BACKUP_H" \
        > "$WORK/install-h.log" 2>&1; then
    bad "用例 H：备份已经被改坏，安装器却报了成功"
    echo "---- 安装器完整输出 ----"
    cat "$WORK/install-h.log"
    echo "---- 安装器输出结束 ----"
else
    ok "用例 H：备份被改坏时安装器判失败"
    if grep -q '备份校验失败' "$WORK/install-h.log"; then
        ok "用例 H：失败原因说清了是备份校验失败"
    else
        bad "用例 H：失败信息里没有说明是备份校验失败"
        tail -20 "$WORK/install-h.log"
    fi
    # 关键：必须明确说"没有写目标"，否则用户会以为还能重跑。
    if grep -q '没有对' "$WORK/install-h.log" && grep -q '任何写入' "$WORK/install-h.log"; then
        ok "用例 H：失败信息里明确说了没有对目标做任何写入"
    else
        bad "用例 H：失败信息里没有说明目标未被写入"
    fi
fi

_h_after="$(whole_sha "$TGT_H")"
if [ "$_h_before" = "$_h_after" ]; then
    ok "用例 H：中止之后目标盘一字节都没动"
else
    bad "用例 H：中止之后目标盘被写了（整盘 sha256 变了）"
fi
rm -rf "$BACKUP_H" 2>/dev/null || true

# ---------- 10. 用例 I：没法登记 UEFI 启动项时，最终状态必须交代清楚 ----------
#
# 为什么要有这条：
#   系统装好了、固件里却没有指向它的启动项 —— 报告说"装好了"，
#   用户重开机才发现开不了机，这是最坏的一种收场。
#   所以"登记不上"必须**判失败**，而且失败信息必须说清楚三件事：
#     1) 系统本身已经装好了（不要重跑安装，重跑会把刚装好的再擦一遍）；
#     2) 缺的是启动项；
#     3) 补救命令是什么。
#
# 制造"登记不上"：把 efivars 路径指到一个不存在的地方
#   （QM1_EFIVARS_PATH 是安装器为此留的注入开关）。
#   CI 的 runner 恰恰**有** efivars，想测"没有"就得能把它指走。
#   注意：这次**不给** --skip-efi-entry —— 显式跳过是另一条允许的收场，
#   这里要测的是"没跳过、但登记不上"时必须判失败。
log "用例 I：没有 efivars（登记不了启动项）⇒ 必须判失败并交代最终状态"
TGT_I="$WORK/target-i.img"
truncate -s 512M "$TGT_I"
LOOP_TGT_I="$(losetup --partscan --find --show "$TGT_I" 2>/dev/null)" || skip "造目标失败"
LOOPS+=("$LOOP_TGT_I")

if QM1_EFIVARS_PATH=/nonexistent/qm1-efivars bash "$DEVICE_INSTALLER" --target "$LOOP_TGT_I" \
        --source-disk "$LOOP_SRC_E" --source-root "${LOOP_SRC_E}p2" --source-esp "${LOOP_SRC_E}p1" \
        --lib "$INSTALL_LIB" --no-login-account --mode media --yes \
        > "$WORK/install-i.log" 2>&1; then
    bad "用例 I：登记不上 UEFI 启动项时安装器居然报成功（重开机可能开不了机）"
    echo "---- 安装器完整输出 ----"
    cat "$WORK/install-i.log"
    echo "---- 安装器输出结束 ----"
else
    ok "用例 I：登记不上启动项时安装器判失败"
fi
if grep -q '没有登记成功' "$WORK/install-i.log"; then
    ok "用例 I：失败原因说清了是启动项没登记成功"
else
    bad "用例 I：失败信息里没有说明启动项没登记成功"
    tail -20 "$WORK/install-i.log"
fi
if grep -q '系统本身已经装好了' "$WORK/install-i.log"; then
    ok "用例 I：失败信息里说明系统本身已经装好（别重跑安装）"
else
    bad "用例 I：失败信息里没有说明系统本身已经装好"
fi
if grep -q '别重跑安装' "$WORK/install-i.log"; then
    ok "用例 I：失败信息里提醒了别重跑安装"
else
    bad "用例 I：失败信息里没有提醒别重跑安装"
fi
if grep -q 'efibootmgr -c' "$WORK/install-i.log"; then
    ok "用例 I：失败信息里给出了可复制的补救命令"
else
    bad "用例 I：失败信息里没有补救命令"
    tail -20 "$WORK/install-i.log"
fi
if grep -q '显式跳过 EFI 启动项登记' "$WORK/install-i.log"; then
    bad "用例 I：没给 --skip-efi-entry 却显示跳过了 EFI 登记"
else
    ok "用例 I：没有把 EFI 登记失败伪装成'跳过'"
fi
# 顺便确认：失败点在"启动项"这一步，系统本身确实写下去了 ——
# 不然那句"系统本身已经装好了"就是在骗人。
if has_file "${LOOP_TGT_I}p2" "QM1-MARKER-FILE"; then
    ok "用例 I：系统本身确实已经装进目标（失败点只在启动项）"
else
    bad "用例 I：目标里没有源的文件内容（'系统本身已经装好了'这句是假的？）"
fi
# media 分支顺手做的那份整盘备份落在 /var/tmp（512 MiB）——用完就删。
rm -f /var/tmp/qm1-target-preinstall-*.img /var/tmp/qm1-target-metadata-*.img 2>/dev/null || true

printf '\n'
if [ "$FAILED" = "0" ]; then
    printf '安装器端到端测试全部通过\n'
    exit 0
fi
printf '安装器端到端测试有失败项\n'
exit 1
