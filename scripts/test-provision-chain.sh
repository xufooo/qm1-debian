#!/usr/bin/env bash
# test-provision-chain.sh — 用合成的磁盘镜像验证「凭据注入」这条链路
#
# 为什么要有这个测试：
#   出厂镜像里不含任何 Wi-Fi 凭据（凭据是私密信息，不该进公开仓库，也不该进
#   CI 的日志）。但「装进 eMMC、开机即用」要求装完就能联网 —— 安装器是从
#   启动分区（ESP）上的 /qm1/provision/ 读凭据的。于是交付流程多了一步：
#   准备凭据 → 注入已构建好的介质 → dd 到 U 盘。
#
#   这条链路以前**一次都没有被执行过**：脚本能通过语法检查，但从来没在真的
#   镜像上跑过。而它失败的后果是"装机现场才发现连不上网"。
#
# 这里做的事：
#   1) 造一个 512 MiB 的 GPT 磁盘镜像，里面放一个真的 FAT32 ESP；
#   2) 用 prepare-provision.sh 生成凭据目录（非交互，假的凭据）；
#   3) 用 inject-provision.sh 把目录注入镜像；
#   4) 用 mdir/mcopy 回读，确认文件在、内容对；
#   5) 再走一遍「裸 ESP 镜像」那条路径。
#
# 不需要 root（不需要 loop 设备，mtools 的 @@偏移 语法直接读写镜像文件）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fails=$(( fails + 1 )); }

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '  skip 缺少 %s，跳过整条链路测试\n' "$1" >&2
        exit 77
    }
}
need sfdisk
need mkfs.vfat
need mcopy
need mdir
need python3

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ESP_MIB=64
DISK="$WORK/disk.img"
ESP="$WORK/esp.img"
PROV="$WORK/provision"

# ---------------------------------------------------------------- 造磁盘
: > "$ESP"
dd if=/dev/zero of="$ESP" bs=1M count="$ESP_MIB" status=none
mkfs.vfat -F 32 -n QM1ESP "$ESP" >/dev/null

# GPT：ESP 从 1 MiB 开始（LBA 2048，与 assemble-disk.sh 的真实布局一致），
# 类型 GUID = EFI System。
# 两个要点：
#   * 文件要先建出来（truncate）—— sfdisk 只往已存在的文件里写分区表；
#   * 每条分区都要写死 size —— 写成默认 size 会让分区超出盘尾而失败。
truncate -s 512M "$DISK"
sfdisk "$DISK" >/dev/null <<'SPEC'
label: gpt
start=1MiB, size=64MiB, type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name=QM1ESP
SPEC
dd if="$ESP" of="$DISK" bs=1M seek=1 conv=notrunc status=none

# ---------------------------------------------------------------- 生成凭据
# 假的凭据：只用来看格式对不对，不含任何真实信息
"$SCRIPT_DIR/prepare-provision.sh" --out "$PROV" \
    --ssid "QM1 Test Net" --psk "test-passphrase" --enable-ssh >/dev/null
[ -f "$PROV/wpa_supplicant.conf" ] \
    && ok "prepare-provision 生成了 wpa_supplicant.conf" \
    || bad "prepare-provision 没有生成 wpa_supplicant.conf"
[ -f "$PROV/ssh" ] \
    && ok "prepare-provision 生成了 ssh 标记" \
    || bad "prepare-provision 没有生成 ssh 标记"

# ---------------------------------------------------------------- 注入整盘镜像
"$SCRIPT_DIR/inject-provision.sh" --image "$DISK" --dir "$PROV" >/dev/null \
    && ok "inject-provision 完成了整盘注入" \
    || bad "inject-provision 整盘注入失败"

listing="$(mdir -i "$DISK@@1048576" ::/qm1/provision 2>/dev/null || true)"
for f in wpa_supplicant.conf ssh; do
    case "$listing" in
        *"$f"*) ok "镜像里有 ::/qm1/provision/$f" ;;
        *)      bad "镜像里缺 ::/qm1/provision/$f" ;;
    esac
done

# 回读内容，确认写进去的是"读取方按其规则解释"的格式
mcopy -i "$DISK@@1048576" ::/qm1/provision/wpa_supplicant.conf "$WORK/read-back.conf" 2>/dev/null \
    || true
if [ -f "$WORK/read-back.conf" ]; then
    ok "回读出了 wpa_supplicant.conf"
    if grep -q 'ssid="QM1 Test Net"' "$WORK/read-back.conf"; then
        ok "SSID 按引号+转义的写法落盘"
    else
        bad "SSID 的写法不对：$(grep -a ssid "$WORK/read-back.conf" | tr -d '\r')"
    fi
    if grep -q 'psk="test-passphrase"' "$WORK/read-back.conf"; then
        ok "普通口令按加引号的写法落盘"
    else
        bad "psk 的写法不对：$(grep -a psk "$WORK/read-back.conf" | tr -d '\r')"
    fi
else
    bad "回读 wpa_supplicant.conf 失败"
fi

# ---------------------------------------------------------------- 裸 ESP 那条路径
BARE="$WORK/bare-esp.img"
cp "$ESP" "$BARE"
"$SCRIPT_DIR/inject-provision.sh" --image "$BARE" --dir "$PROV" --esp-only >/dev/null \
    && ok "inject-provision 完成了裸 ESP 注入" \
    || bad "inject-provision 裸 ESP 注入失败"
listing2="$(mdir -i "$BARE" ::/qm1/provision 2>/dev/null || true)"
case "$listing2" in
    *wpa_supplicant.conf*) ok "裸 ESP 里也有 ::/qm1/provision/wpa_supplicant.conf" ;;
    *) bad "裸 ESP 里缺 ::/qm1/provision/wpa_supplicant.conf" ;;
esac

# ---------------------------------------------------------------- 该拒绝的情况
if "$SCRIPT_DIR/inject-provision.sh" --image "$DISK" --dir "$PROV" --offset-mib 999999 >/dev/null 2>&1; then
    bad "指向磁盘之外的偏移居然成功了"
else
    ok "越界的偏移被拒绝"
fi

if [ "$fails" -eq 0 ]; then
    printf 'provision 链路测试全部通过\n'
    exit 0
fi
printf '%s 项失败\n' "$fails" >&2
exit 1
