# qm1-debian

可复现地构建 **ASUS QM1-B002** 的 Debian 13 (trixie) amd64 整机镜像：**双架构 EFI 引导器 + 预置驱动与固件 + 定制 overlay + 设备端自检脚本**，一条命令重造整机。

目标机器：Intel Atom Z3735F（Bay Trail-T，4 核 4 线程，1.33–1.83 GHz，**无 AVX/AVX2**）/ 2 GB DDR3L / 32 GB eMMC / 无 RJ45 / USB 2.0 + HDMI + microSD。

## 为什么是 Debian 13

- Debian 13 的 amd64 基线是 **x86-64-v2**（SSE4.2/POPCNT/CX16/AES-NI 即可），Bay Trail 恰好达标；v3 及以上会 SIGILL。
- Debian 13 内核 6.12 LTS 支持到 2028-08（LTS 延到 2030 前后）。
- 与主流 agent 运行时的官方底座一致（Hermes 官方镜像的用户层就是 `debian:trixie`）。

## 双架构引导

32 位 IA32 EFI 固件只能加载 PE32 应用，64 位 UEFI 才能加载 PE32+。因此 ESP 里同时放两个引导器：

| 文件 | 格式 | 用途 |
|------|------|------|
| `EFI/BOOT/BOOTIA32.EFI` | PE32 (Intel i386) | 32 位 IA32 EFI 固件入口，可引导 64 位内核（EFI handover） |
| `EFI/BOOT/BOOTX64.EFI` | PE32+ (x86-64) | 64 位 UEFI 固件入口 |

GRUB 菜单同时给出两个启动项（amd64 与 i386），对应两套内核与根文件系统。64 位固件同样能加载 32 位 PE32 应用，所以 `BOOTIA32.EFI` 在两种固件上都是安全的。

引导器由 `grub-mkimage` 组装，模块集刻意精简：

```
part_gpt part_msdos fat ext2 normal linux search search_fs_uuid search_label chain terminal
```

> 注意：GRUB **没有** 独立的 `linuxefi` 模块，EFI handover 支持在 `linux` 模块内。写 `linuxefi` 会直接构建失败。
> `grub-mkimage` 与 `.mod` 必须来自同一 GRUB 版本，否则报模块不兼容 —— CI 用同一套 trixie 的 `grub2-common` + `grub-efi-*-bin` 保证一致。

## 快速开始

```bash
# 依赖（Debian/Ubuntu）
sudo apt install mmdebstrap debian-archive-keyring mtools dosfstools e2fsprogs fdisk \
     grub2-common grub-efi-amd64-bin file curl zstd
sudo dpkg --add-architecture i386
sudo apt update && sudo apt install grub-efi-ia32-bin:i386

# 1) 构建根文件系统（mmdebstrap + hooks/，需要 root）
sudo bash scripts/build-rootfs.sh --out build/rootfs --profile runtime

# 2) 生成 ESP + 根文件系统镜像（无需 root）
bash scripts/build-image.sh --rootfs build/rootfs --out-dir build/out

# 3) 合成整盘镜像（GPT：p1 = ESP 实际体积的 FAT32 + p2 = ext4 根 + 盘尾 1MiB 给 GPT 备份头）
bash scripts/assemble-disk.sh --esp build/out/esp.img --root build/out/rootfs.img \
     --out build/qm1-debian13-amd64.img --size-gib 30

# 刷写（破坏性操作，务必先整盘备份并校验 SHA-256）
sudo dd if=build/qm1-debian13-amd64.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress
```

产物清单见 `build/out/manifest.txt`（尺寸、UUID、内核版本、SHA-256）。

### 固定内核 point release（可选）

默认镜像里的内核跟着发行版的元包走（Debian 13 当前给 `6.12.107+deb13-amd64`）。
但 `rtl8723bs` 的 2026-07/08 那批安全修复（`kfree_sensitive`、WMM IE 长度校验、
WPA IE 越界读、监控帧长度校验等）是从 **6.12.111** 才回移进 6.12.y 的 ——
trixie stable 当前的 6.12.107-1 **不含**这批修复。定向 6.12.113-1：

```bash
sudo bash scripts/build-rootfs.sh --out build/rootfs --profile runtime \
     --kernel-version 6.12.113
```

固定版本时构建脚本**不装**发行版内核元包（避免 `/lib/modules` 里出现两个版本、
initramfs 和 GRUB 挑错），改由 `hooks/customize02-drivers.sh` 精确安装
`linux-image-6.12.113+deb13-amd64-unsigned`（**用 `-unsigned` 变体**：signed 变体
`linux-image-6.12.113+deb13-amd64` 会拉 `grub-efi-amd64-signed`，和本项目自带的
`BOOTIA32.EFI` / `BOOTX64.EFI` 双引导器抢 EFI 目录）；该 point release 若不在主仓库，
hook 会临时挂 `<suite>-proposed-updates` 精确安装，装完即撤，
**装不上直接失败，不静默回退到旧内核**。
`/etc/qm1-build-info` 与 `rootfs-manifest.txt` 会记录 `kernel_mode=pinned-point-release`、
`kernel_requested`、`kernel_abi` 与实际装上的版本。
（i386 变体固定用 Debian 12 的 `686-pae`，不受此选项影响。
镜像内不装 `linux-headers-*`：外部模块在 CI 里编，不需要在镜像里带编译头文件。）

## 安装（把镜像装到 QM1）

镜像**自带引导链**：ESP 里有 `BOOTIA32.EFI` + `BOOTX64.EFI` + 内核 + initrd + `grub.cfg`，
写进 eMMC 就能脱离 U 盘自启动。安装按「先 U 盘试跑 → 再动 eMMC」的顺序做。

### 两种发布形态

| 产物 | 是什么 | 怎么用 |
|---|---|---|
| `qm1-disk.img` | **原始整盘镜像**（GPT：p1 ESP + p2 根） | 写到 U 盘当启动盘，或用 `install-qm1.sh` 写进 eMMC |
| `qm1-installer.img` | **安装包**（同样的分区，但 ESP 的菜单换成"装到 eMMC"） | 写进 U 盘 → 开机 → 选第 ① 项 → 脚本自动备份、写入、校验 |

两个镜像内容一致，区别只有 ESP 里的 `grub.cfg`：

- `qm1-disk.img` 里的菜单 = 直接启动已装好的系统；
- `qm1-installer.img` 里的菜单 = ① 安装到 eMMC（备份 → 写入 → 校验）
  ② 试用系统（不写盘，可先跑驱动自检） ③ GRUB 命令行（救援）。
  它还额外带一份 `grub-normal.cfg`，安装脚本装完会把它拷回目标 ESP，
  所以装好之后从 eMMC 启动看到的仍是普通菜单。

### 第 1 步：先在 U 盘上试跑（不碰 eMMC）

```bash
# 把整机镜像写到 U 盘（先用 lsblk 确认设备名，例如 /dev/sdb）
sudo dd if=build/out/qm1-disk.img of=/dev/sdX bs=4M conv=fsync status=progress
```

插好 U 盘 → BIOS 里选 U 盘启动 → GRUB 菜单选 `QM1 Debian 13 (64-bit amd64)`。
能进系统并跑通自检，说明引导链和驱动都成立，再考虑刷 eMMC。

### 安装包形态：一键装到 eMMC（推荐路径）

```bash
# 把安装介质写到 U 盘
sudo dd if=build/out/qm1-installer.img of=/dev/sdX bs=4M conv=fsync status=progress
```

开机 → BIOS 选 U 盘启动 → GRUB 里选 `① 安装 QM1 Debian 13 到 eMMC`。
系统会：

1. 确认目标 `/dev/mmcblk0`、当前不是从 eMMC 启动（否则拒绝重装）；
2. **先备份**——空间够就整盘备份 + SHA-256；不够就只备份分区表与前 16 MiB
   并明确警告（32 GiB eMMC 的整盘备份通常塞不进 U 盘，
   想留完整原件请先在别处 `dd` 一份）；
3. 在 eMMC 上写分区表（p1 ESP / p2 根，根分区撑满整盘），逐分区 `dd` 写入；
4. 把目标 ESP 的 `grub.cfg` 换回正常菜单；
5. 逐分区比对 SHA-256；
6. 提示拔 U 盘、重启、从 eMMC 启动。

后台跑法（不想看着屏幕）：在 GRUB 里按 `e` 编辑第 ① 项，在内核参数后加
`systemd.unit=multi-user.target`，或者直接看串口日志
（`console=ttyS0,115200n8`，1.3 GHz 的 Atom 上整盘备份 + 6 GiB 拷贝 + 两遍
SHA-256 大约十几分钟）。

### 第 2 步：备份 eMMC（硬前置，不可跳过）

```bash
sudo dd if=/dev/mmcblk0 of=backup-mmcblk0.img bs=4M status=progress
sha256sum backup-mmcblk0.img > backup-mmcblk0.img.sha256
```

### 第 3 步：安装到 eMMC

```bash
sudo bash scripts/install-qm1.sh \
  --image build/out/qm1-disk.img \
  --target /dev/mmcblk0 \
  --backup-dir /mnt/usb/qm1-backup
```

脚本会依次做：检查目标设备不是挂载中 → 整盘备份并生成 SHA-256 → `dd` 写入（`conv=fsync`）
→ 回读比对镜像覆盖范围 → 打印后续步骤。可加 `--dry-run` 先看它要做什么。

> **救援路径**：部分 Bay Trail 固件不扫描内部存储的 `\EFI\BOOT`。此时用一张常驻
> U 盘跳板（`\EFI\BOOT\BOOTIA32.EFI` + `grub.cfg` 指向 eMMC 根 UUID）引导，
> 或在 GRUB 里 `set root=UUID=<root_uuid>` 后 `linux /boot/vmlinuz-*`。
> 根 UUID 见 `build/out/manifest.txt` 的 `root_uuid=`。
> 安装介质自带跳板：它的 ESP 里就有 `BOOTIA32.EFI`，装完拔盘前留在 U 盘上即可当救援盘用。

### 第 4 步：首次开机与运行时安装

```bash
sudo /usr/local/bin/qm1-selftest                          # 硬件驱动自检
sudo bash /usr/local/share/qm1/provision-agent.sh         # Hermes + Chrome + systemd 单元
```

`provision-agent.sh` 幂等，可重复执行：补齐 Chromium 运行库与字体、写入 Wi-Fi/SSH
配置、装 Hermes **官方安装方式**的运行时、生成 `systemd --user` 单元并设好内存限额。
Hermes 本体由官方安装器安装（官方用 uv 托管 standalone CPython 3.14）——
**不要**用系统的 python3（Debian 13 是 3.13.5）去装。

### 变体：分区级安装（不用整盘镜像）

不想覆盖整盘时，可以只用分区镜像：根文件系统的 UUID 在构建期固定（`mkfs.ext4 -U`），
并已写进 `esp.img` 里的 `grub.cfg`（`root=UUID=`），所以只要把两个镜像写到正确的
分区位置就能引导：

```bash
# 先用任意分区工具建 GPT：p1 = 与 esp.img 同大的 FAT32（卷标 QM1ESP），p2 = 与 rootfs.img 同大的 ext4（卷标 QM1ROOT）
sudo dd if=build/out/esp.img   of=/dev/sdX1 bs=1M conv=fsync status=progress
sudo dd if=build/out/rootfs.img of=/dev/sdX2 bs=1M conv=fsync status=progress
```

注意：**不要重新格式化 p2**，否则 UUID 变化会让 `grub.cfg` 里的 `root=UUID=` 失效。

### CI 产物

`build-image` 工作流产出：整机镜像 `qm1-disk.img`（可选 zstd 压缩）、分区镜像
`esp.img` / `rootfs.img`、引导器、`manifest.txt`、`SHA256SUMS`，以及
`install-qm1.sh` 与 `provision-agent.sh`（下载即可装）。

## 驱动与固件策略

**跟随发行版做法：不自编内核。** 发行版的通行做法是「官方内核 + 官方模块集」——
① 绝大多数驱动编译成模块（`=m`），只有内核运转必需项内置（`=y`）；
② 启动关键路径的模块塞进 initramfs；
③ 其余模块交给 udev 按设备别名自动加载（所以一般不需要手工维护驱动清单）；
④ `/etc/modules-load.d/` 只放必须早加载的少数几个；
⑤ 固件 blob 走发行版 firmware 包，只有主线内核没有的驱动才用 DKMS。

Debian 13 的 6.12 内核对本机全部外设驱动都已是模块，因此无需任何定制内核：

| 类别 | 内容 | 来源 |
|------|------|------|
| **内核模块（`=m`）** | eMMC/SD（`sdhci-pci` / `sdhci-acpi` / `mmc_block`）、USB（`ehci-pci`/`xhci-hcd`/`usb-storage`）、显卡 `i915`、Intel HDA（`snd-hda-intel` + `snd-hda-codec-realtek`）、蓝牙 `btusb`（USB 蓝牙棒）、无线 `r8723bs`（内置 RTL8723BS）/ `brcmfmac`/`iwlwifi`/`rtw88` | Debian `linux-image-amd64` |
| **内置（`=y`）** | ACPI、EFI stub（含 handover）、串口控制台、RTC（`CONFIG_RTC_DRV_CMOS`）、thermal、intel_idle | 同上（无法改成模块，属发行版正常形态） |
| **需 firmware** | Broadcom brcmfmac、Realtek 8723*/8812*、MediaTek mt76、Atheros、Intel 无线、Intel 微码、SOF 音频固件 | `firmware-brcm80211` / `firmware-realtek` / `firmware-mediatek` / `firmware-atheros` / `firmware-iwlwifi` / `firmware-sof-signed` / `intel-microcode`（**位于 non-free-firmware 组件**，mmdebstrap 必须带 `--components=main,non-free-firmware`） |
| **需 out-of-tree（DKMS）** | Realtek RTL8723AU / 8812AU / 8812BU 等 **USB** 消费级无线芯片（主线内核无驱动） | 通过 `QM1_DKMS_DEB_DIR` 注入预编译 .deb，或改用 USB 以太网适配器 |
| **需厂商用户态工具** | 内置蓝牙（ACPI UART）初始化：主线没有 Realtek UART HCI 驱动，要靠 `rtk_hciattach` 下发厂商固件 | `scripts/build-bt-hciattach.sh` 产出的 `qm1-rtl8723bs-bt`（见下节） |

启动关键路径（eMMC 控制器 + 根文件系统）会被写进 initramfs：`MODULES=most` + `COMPRESS=zstd`，并显式声明 `sdhci_pci sdhci_acpi mmc_block vfat ext4 usb_storage xhci_hcd ehci_pci`。
`modules-load.d` 只放 `i915`（HDMI 首屏）、`snd_hda_intel`、`btusb`；其余靠 udev 自动加载。
构建产物里的 `driver-manifest.txt` 会用 `modinfo -k <版本>` 与 `/boot/config-*` 判定每个驱动是 `module` / `builtin` / `absent`，CI 对启动关键项做硬断言。

### 内置无线：RTL8723BS（SDIO）

QM1 内置无线已实测确认为 **Realtek RTL8723BS**（SDIO 模组，AzureWave，SDIO ID `0x024c:0xb723`），不是常见资料里说的 USB 型号。这个区别决定了整条链路：

| 环节 | 结论 |
|------|------|
| 内核驱动 | Debian 13（6.12）**和** Debian 12（6.1 / 686-pae）都自带主线 staging 驱动 `r8723bs`（`CONFIG_RTL8723BS=m`），模块随 `linux-image-*` 一起发布 → **不需要 DKMS** |
| 固件 | `firmware-realtek` 提供 `/usr/lib/firmware/rtlwifi/rtl8723bs_nic.bin`（驱动实际请求的文件名）。`rtl8723bs_fw.bin` 是蓝牙固件（`rtl_bt/`），别拿它当 Wi-Fi blob 核对 |
| 加密 | 仅 WPA2-PSK，无 WPA3/SAE（staging 版仍是 Realtek 私有协议栈） |
| 上游路线 | staging 版已被上游在 7.4 删除，官方并入 `rtw88`（`CONFIG_RTW88_8723BS`，需内核 ≥ 7.4；Debian 尚无 7.4 内核包，trixie 也缺 `rtw88/rtw8723b_fw.bin`）→ 本仓库把上游芯片驱动**按镜像内核回移成树外模块**（见下） |
| 稳定性 | staging 版是 Realtek 私有栈，**没有逐包发送反馈**：数据帧无 report、无主机超时、无重传反馈，速率是关联时查表定死的 → 弱信号下固件内部丢弃对主机不可见，表现为 TCP 超时重传。同时存在多条**永久卡死路径**（见下） |

镜像侧对应处理：驱动表纳入 `r8723bs`，firmware blob 核对改查 `rtl8723bs_nic.bin`，`/etc/modprobe.d/qm1-rtl8723bs-in-tree.conf` 关掉驱动的省电与 40MHz 带宽（`rtw_power_mgnt=0 rtw_smart_ps=0 rtw_ips_mode=0 rtw_bw_mode=0`）；打了补丁的外部模块另用 `/etc/modprobe.d/qm1-rtl8723bs.conf`（blacklist 内置 `r8723bs`，改用 `r8723bs_qm1`），`drv-selfcheck.sh` 报出真实绑定驱动并在检测到 `r8723bs` 时给出稳定性告警。

staging 版已确认的**永久卡死路径**（丢失 SDIO 中断后不会自愈，只能靠模块重载）：

| 现象 | 位置 | 触发条件 |
|------|------|----------|
| TX 队列停下后 worker 再不被踢 | `hal/rtl8723bs_xmit.c` 取不到 TX free page 时把 buffer 塞回队头却不上报 | 丢一次 SDIO 中断即永久断流 |
| TX 线程无限自旋 | `rtw_sdio_wait_enough_TxOQT_space()` 无超时轮询 | 固件停止消费 TX OQT |
| 子队列停掉后不再 restart | `os_dep/xmit_linux.c` 停的是新 skb 的队列号，恢复时唤醒的是已释放 skb 的队列号，且全树没有 `netif_start_subqueue` | 队列资源紧张时 |
| TX 线程忙等（completion 计数残留） | v5.9 起 `complete()` 是计数型信号量，驱动从不 `reinit_completion`，计数不配平时 wait 立即返回 | 潜在风险；2026-11-05 实机测线程 CPU 仅 0.2 %，未复现 |

这四条用 `patches/rtl8723bs/` 下的补丁修掉（外部模块方式，见 `scripts/rtl8723bs-module.README.md`）。参数层面的止血是关掉省电与 40MHz；结构性解（mac80211 化、有逐包反馈）是 rtw88 路线 —— 本仓库用 vendor rtw88 树外模块实现（见下），纯上游版本需内核 ≥ 7.4（Debian 目前无此内核包）。

#### 打了补丁的外部模块 `r8723bs_qm1`

补丁做在**树外模块**上，不动发行版内核：

| 文件 | 作用 |
|------|------|
| `patches/rtl8723bs/000[1-5]-*.patch` | P1 重新踢 TX worker + 超时重试 / P2 TxOQT 等待加超时 / P3 completion 配平 / P4 子队列 restart / P5 coalesce 失败释放 + `tx_drop++` |
| `scripts/fetch-rtl8723bs-source.sh` | 逐文件抓 Debian 源包里那份 `drivers/staging/rtl8723bs/`（每个文件都做「非空 + 不是 HTML 错误页」体检，防把 404 页面当源码写进树） |
| `scripts/build-rtl8723bs-module.sh` | 打补丁 → Kbuild 包装 Makefile → out-of-tree 编译 → 校验（`modinfo` name/license/alias/vermagic）→ 打 `.deb` |
| `.github/workflows/build-wifi-module.yml` | CI 出包：Debian trixie 容器里编译并上传 `.deb` |
| `scripts/rtl8723bs-module.README.md` | 安装、回滚、与内核版本的对应关系 |

**为什么模块必须改名**：树内 `r8723bs` 与外部模块带**同一个 SDIO alias**
`sdio:c*v024CdB723*`。modprobe 按 alias 加载时会把两个都插进内核，树内那个一旦先注册
sdio driver，打补丁的模块就再也注册不上去（`-EBUSY`）。所以外部模块改名 `r8723bs_qm1`
（Kbuild 包装 Makefile 换模块名，**驱动的 C 代码一行不改**），并由
`/etc/modprobe.d/qm1-rtl8723bs.conf` 做 `blacklist r8723bs` + `options r8723bs_qm1 …`。

本地出包（需要对应版本的内核头文件）：

```bash
bash scripts/build-rtl8723bs-module.sh --kver 6.12.113+deb13-amd64
```

产物 `build/wifi-module/qm1-rtl8723bs-module_*.deb`，装到设备上 `dpkg -i` 即可
（postinst 会 `depmod -a` 并 enable `qm1-rtl8723bs.service`）。
**模块与内核版本强绑定（vermagic）**：换内核 point release 后必须重跑 CI 重新出包。

**直接装进镜像**：构建 rootfs 时用 `--wifi-module-deb` 把这个 deb 装进去，
hook 会核对模块 vermagic 与镜像内核是否一致（不一致直接失败），并把
`/etc/modules-load.d/qm1-hardware.conf` 里的 `r8723bs` 换成 `r8723bs_qm1`：

```bash
bash scripts/build-rtl8723bs-module.sh --kver 6.12.113+deb13-amd64
bash scripts/build-rootfs.sh --out build/rootfs --profile runtime \
     --kernel-version 6.12.113 \
     --wifi-module-deb build/wifi-module/qm1-rtl8723bs-module_*.deb
```

CI 里 `build-image` 已经把这两步串起来了（先装 `6.12.113+deb13-amd64` 的内核头文件
→ 编译模块 → 带着 `--kernel-version` 与 `--wifi-module-deb` 构建 rootfs），
所以 CI 产出的镜像自带打了补丁的 Wi-Fi 驱动。

#### rtw88 树外模块（根治路线，推荐）

staging 驱动那四条永久卡死路径的根因是 Realtek 私有协议栈没有逐包发送反馈。上游的解法是把这颗芯片
**并入 rtw88**（mac80211 化，有逐包反馈），并把 staging 驱动删掉：

| 上游提交 | 内容 |
|----------|------|
| `d726c70ce082` | `wifi: rtw88: 8723b: add the RTL8723B chip driver`（新增 `rtw8723b.c` / `rtw8723b.h`） |
| `269946cba92e` | `rtw88: 8723bs: add the RTL8723BS SDIO bind` |
| `b2d251aa7f16` | `rtw88: 8723bs: enable building…`（Kconfig + Makefile） |
| `c520f3af7df4` | `staging: rtl8723bs: remove the obsolete driver` |

但**还没有发行版内核带着它**：Debian sid 的内核是 7.2.15（< 7.4），trixie 是 6.12；
Debian 13 的 `firmware-realtek` 里也没有 `rtw88/rtw8723b_fw.bin`（sid 才有）。

> **实测更正**：只把上游那几个芯片文件回移到 6.12 **编不过**。上游 7.4 的 `rtw8723b.c` 用到
> `mac_postinit` / `query_phy_status` / `set_ampdu_factor` / `led_set` / `hw_feature_report` /
> `c2h_ra_report_size` / `old_datarate_fb_limit` / `RTW_CHIP_TYPE_8723B` / `rtw_phy_cck_pd_set`
> 这些 **7.4 时期的 rtw88 核心 API**，6.12 的 rtw88 核心里没有 —— 要用上游方案，得把 rtw88
> **核心**也一起回移（数天工作量）。
>
> 所以本仓库实际走的是**维护中的 vendor rtw88 树**（`MocLG/rtw88-rtl8723bs`）：它本身就是
> 「rtw88 全树 + RTL8723B/8723BS 支持」，已针对 6.12 适配，并额外修了 SDIO 变体的长期 bus
> timeout、扫描失败（重实现 vendor association/join 序列、修正上电时序、WiFi/BT 共存天线），
> 在 6.12.113+deb13-amd64 上**编译通过**。等有 ≥ 7.4 的内核包时，可直接换成纯上游。

| 文件 | 作用 |
|------|------|
| `scripts/build-rtw88-8723bs-module.sh` | 默认走 **vendor rtw88 树**（`--source vendor`）：编出 `rtw_core.ko` / `rtw_sdio.ko` / `rtw_8723b.ko` / `rtw_8723bs.ko`。`--source upstream` 可切到「上游芯片文件 + 6.12 头文件」的实验路线（在 6.12 上编不过，见上）。校验 vermagic 必须与目标内核一致、模块 alias 必须认领 `0x024c:0xb723`，最后打成 `.deb` |
| `scripts/fetch-rtw8723b-firmware.sh` | 从 Debian sid 的 `firmware-realtek` 里只取 `rtw88/rtw8723b_fw.bin`（用 sid 包索引里的 SHA256 校验 .deb 本身） |
| `patches/rtw88/*.patch` | 打给 vendor 树的本地补丁（构建脚本自动按序应用，缺补丁直接失败）。目前是 `0001`：把 **8723BS 的 TX report purge 超时从 500 ms 提到 2500 ms** —— vendor 树没跟上上游 `4d688f22ebbf`（上游 7.4 起给 8723BS 单独放宽，现已推广成非 PCIe 总线一律 2500 ms）。不补这一条，超时器会在帧还在路上时把整条 tx_report 队列清掉、内核永远等不到「已发送」，正是「链路通但吞吐塌陷 / 断流」的成因 |

打好的 deb 里包含：模块（`/lib/modules/<abi>/extra/rtw88/`）、固件（`/lib/firmware/rtw88/`）、
`/etc/modprobe.d/qm1-rtw88-8723bs.conf`（`blacklist r8723bs` + rtw88 核心自己的参数
`disable_lps_deep=y` / `support_bf=y` / `debug_mask=0`；注意 `rtw_power_mgnt` /
`rtw_smart_ps` / `rtw_ips_mode` / `rtw_bw_mode` 是 **staging 驱动**的参数，rtw88 没有，
写上去会让 modprobe 直接拒绝加载模块 —— CI 会逐个参数核对 `modinfo -p`）、
以及 `qm1-rtw88-8723bs.service`（先 rmmod 树内 staging 驱动，再 modprobe 回移模块）。

**装进镜像**：

```bash
bash scripts/build-rtw88-8723bs-module.sh --kver 6.12.113+deb13-amd64 \
     --out-dir build/rtw88-module
bash scripts/build-rootfs.sh --out build/rootfs --profile runtime \
     --kernel-version 6.12.113 \
     --rtw88-module-deb build/rtw88-module/qm1-rtw88-8723bs_*.deb
```

hook 会核对 vermagic 与镜像内核一致、固件在位，并把 `/etc/modules-load.d/qm1-hardware.conf`
里的 `r8723bs` 换成回移后的模块名；`drv-selfcheck.sh` 看到 rtw88 模块时直接报 PASS。
CI 里 `build-image` 已经把这条链路串起来了。**rtw88 模块是硬要求**：构建步骤虽然带
「失败就退回打了补丁的 staging 模块」的兜底，但后面的断言步骤会直接 `exit 1` ——
镜像里只允许出现 rtw88 根治模块，不允许悄悄退回那四条永久卡死路径的 staging 驱动。

#### 蓝牙：RTL8723BS 的 BT 部分（ACPI UART + 厂商固件下发）

内置蓝牙和 Wi-Fi 是同一颗 combo 芯片，但**不是 USB 设备**——它是 ACPI 枚举的 UART。
ASUS 官方 Win8 驱动的 `rtkuart.inf` 写得很明确：

```
ACPI\VEN_OBDA&DEV_8723
ACPI\VEN_OBDA&DEV_0623
```

对应驱动 `RtkUart.sys`（用户态服务）。

**实测更正（2026-11-05）**：早先写「Linux 主线没有 Realtek UART HCI 驱动」**过于绝对**。
把 Debian 13 内核里的 `hci_uart.ko` 抽出来 `modinfo` 一看，它的 ACPI alias 里**明确带着这两个 ID**：

```
alias: acpi*:OBDA8723:*
alias: acpi*:OBDA0623:*
```

也就是说**主线驱动认得这个口**，只是它不会替 Realtek 芯片做「厂商固件下发 + 初始化」——
那一步必须由用户态 `rtk_hciattach` 完成，之后内核 `hci_uart` 接手同一个串口。
另外要注意模块名：Linux 6.x 里这个模块叫 **`hci_uart.ko`**（早期内核才叫 `bt_hciuart.ko`），
Debian 13 的 6.12.113+deb13-amd64 是 `CONFIG_BT_HCIUART=m`（**模块**，不是编进内核）。

| 环节 | 本仓库的做法 |
|------|--------------|
| 用户态工具 | 上游 [lwfinger/rtl8723bs_bt](https://github.com/lwfinger/rtl8723bs_bt)（钉死提交 `09eb91f5`）的 `rtk_hciattach`：BlueZ hciattach 的 Realtek 衍生版，负责下发固件并做厂商初始化 |
| 固件 | 上游自带的 `rtlbt_fw` / `rtlbt_config` / `rtlbt_fw_new`（**不是** Windows 那份未打补丁的 blob，见下） |
| 串口探测 | `/etc/default/qm1-bluetooth` 里的 `BT_TTY` 优先；否则按 ACPI HID（`OBDA8723` / `OBDA0623`）在 sysfs 里反查 tty；再否则退回 dmesg 里的第一个 MMIO 串口 |
| 开机自启 | `qm1-bluetooth.service` → `qm1-bt-attach.sh` → 先 `rtk_hciattach -n -s 115200 <tty> rtk_h5`（`-n` = 不摘 ldisc，让内核接管）下发固件并初始化，再 `modprobe hci_uart` 让内核把该串口认成蓝牙控制器，最后检查 `/sys/class/bluetooth/hci0` |

**固件谱系（取证结论，别混用）**：ASUS Win8.1 蓝牙包里的
`rtl8723b_mp_bt40_fw_asic_rom`（50504 B）与 Debian `firmware-realtek` 的
`rtl_bt/rtl8723bs_fw.bin`（52116 B）**首字节就不同** —— 后者是 Linux 侧**打过补丁**的版本
（把 UART 波特率改成 1500000 bps）。配置也一样：ASUS 的
`rtl8723b_config_internal.bin`（64 B）与 Debian 的 `rtl8723bs_config.bin`（64 B）
只有 0x20–0x25 一段不同，**蓝牙地址字节完全一致**（地址本身属设备唯一标识，已脱敏） ⇒ Debian 的那份
就是 ASUS/Realtek 配置改过波特率后的产物。Windows 那份不能直接塞进 Linux。

**装进镜像**：

```bash
bash scripts/build-bt-hciattach.sh --out-dir build/bt-hciattach
bash scripts/build-rootfs.sh --out build/rootfs --profile runtime \
     --kernel-version 6.12.113 \
     --rtw88-module-deb build/rtw88-module/qm1-rtw88-8723bs_*.deb \
     --bt-hciattach-deb build/bt-hciattach/qm1-rtl8723bs-bt_*.deb
```

hook 会核对 `rtk_hciattach` 可执行、固件在位、内核 `CONFIG_BT_HCIUART`（`=y` 或 `=m`；
Debian 是 `=m`，此时额外确认镜像里存在 `hci_uart.ko`），并建立开机自启链接；
CI 里有一条硬断言（`Assert the Bluetooth vendor package is inside the image`），少了任何一项就红。

**兜底**：如果某个内核上 `rtk_hciattach` 起不来（串口探测不到、或 H5 协议不通），
USB 蓝牙棒（`btusb`，内核自带）仍然是可用的备选 —— 镜像里已经带了 `bluez`。

## 设备端自检

刷机后跑一次，确认每一项硬件都被驱动接管：

```bash
sudo /usr/local/bin/qm1-selftest          # 表格
sudo /usr/local/bin/qm1-selftest --json   # 机读
```

覆盖：内核 / 根盘可写 / MMC 控制器 / `/dev/mmcblk0` / SDHCI / 文件系统 / 显卡 / 声卡 / 网络与无线 / 蓝牙 / RTC / 温控 / 可用内存 / zram / 磁盘空间 / firmware 加载失败 / 未绑定驱动 / 存储 I/O 错误。存在 FAIL 时退出码为 1。

构建期还会生成期望驱动清单 `usr/local/share/qm1/driver-manifest.txt`（含 `modinfo` 实测的 present / MISSING）。

## 定制 overlay

`overlay/` 是随镜像分发的定制层：

- `zram` 768 MiB（zstd）+ `vm.swappiness=180` —— 2 GB 内存机器的换页兜底，尽量不写 eMMC
- journald 上限 50 MiB、关闭 apt 定时任务 —— 控制 eMMC 写放大
- systemd-oomd 内存压力阈值、systemd-networkd 的有线/无线 `.network`
- `qm1-wifi@wlan0.service`（wpa_supplicant）、`qm1-selftest.service`
- SSH 策略：禁 root 登录、禁密码登录

## CI

- `lint`：bash 语法检查、shellcheck、可执行位、隐私扫描（禁止本机路径/私人信息）、overlay 完整性。
- `build-image`：在 `debian:trixie-slim`（privileged）里跑完整构建（装固定内核头文件 → 编译打了补丁的 Wi-Fi 模块 → mmdebstrap → hooks → 引导器 → ESP → ext4），校验 SHA-256、引导器文件类型、ESP 目录清单、驱动清单，并用 `debugfs` 直接检查 ext4 镜像里的属主/权限与定制文件；手动触发时可选择上传镜像。amd64 变体会钉死内核 `6.12.113` 并把 `r8723bs_qm1` 装进镜像（i386 变体仍用 bookworm 的 `686-pae`，不装外部模块）。
- `build-wifi-module`：编译打补丁的 `r8723bs_qm1` 外部模块并打成 `.deb`（upload-artifact 下载）。默认跟随 Debian 13 当前内核，钉死的 point release（`6.12.113+deb13-amd64`）装不上时退回元包；手动触发可指定 `kernel_version`。

最近一次全绿构建的实测结果（amd64 / runtime profile）：

| 项目 | 实测值 |
|---|---|
| 根文件系统内核 | `6.12.107+deb13-amd64` |
| 引导器 | `BOOTIA32.EFI` 425,984 B（PE32 / Intel i386）+ `BOOTX64.EFI` 622,592 B（PE32+ / x86-64） |
| ESP | 256 MiB FAT32（卷标 `QM1ESP`），内含 grub.cfg + vmlinuz + initrd.img |
| 根文件系统 | 6 GiB ext4（卷标 `QM1ROOT`），UUID 构建期固定 |
| 整盘镜像 | 6.25 GiB GPT：p1 256 MiB「EFI System」+ p2 6 GiB「Linux filesystem」，盘尾留 1 MiB 给 GPT 备份头 |
| 压缩后 | zstd 压缩包约 843 MB（`--long=27`） |
| 运行时载荷 | Chromium + standalone CPython 3.14 + `provision-agent.sh` + `drv-selfcheck.sh` 均已就位 |

> 整盘镜像按内容大小生成，刷到 32 GB eMMC 后剩余空间不分区；
> 要铺满时在设备上 extend 分区再 `resize2fs /dev/mmcblk0p2`。

## 目录结构

```
scripts/
  lib/common.sh          公共函数
  build-bootloaders.sh   构建双架构 EFI 引导器（grub-mkimage）
  build-rootfs.sh        mmdebstrap 生成根文件系统（--hook-dir=hooks/，--kernel-version 可钉内核 point release）
  make-esp.sh            组装 FAT32 ESP（mtools，无需 root）
  build-image.sh         生成 esp.img + rootfs.img + manifest
  assemble-disk.sh       合成 GPT 整盘镜像
  verify-image.sh        debugfs 直接校验 ext4 镜像（属主/权限/文件）
  drv-selfcheck.sh       设备端硬件自检
  fetch-rtl8723bs-source.sh  抓 Debian 源包里的 drivers/staging/rtl8723bs/ 子树
  build-rtl8723bs-module.sh  打补丁 + 编译 out-of-tree 模块 + 打 .deb
  rtl8723bs-module.README.md 外部模块的安装 / 回滚说明
  grub.cfg.example       ESP 引导菜单模板（64 位 + 32 位两个启动项）
patches/rtl8723bs/       RTL8723BS 永久卡死路径的修复补丁（P1–P5）
hooks/                   mmdebstrap customize 钩子（在宿主执行，$1 = chroot 目录）
  customize01-base.sh    主机名/locale/时区/fstab/服务开关
  customize02-drivers.sh 内核+firmware+initramfs+模块清单（启动关键驱动缺失即失败）
  customize03-overlay.sh 应用 overlay/ 与设备端自检脚本
overlay/                 随镜像分发的定制层
  etc/modprobe.d/        驱动参数（qm1-rtl8723bs-in-tree.conf 给发行版内置模块）
```

## 构建期踩过的坑（都已在脚本里处理）

- **`sfdisk` 分区类型要写 GUID**：`type=UFS` 不被 util-linux 识别（报 `Failed to add #1 partition: Invalid argument`）；用 p1 = `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`（EFI System）、p2 = `0FC63DAF-8483-4772-8E79-3D69D8477DE4`（Linux filesystem）。
- **`sfdisk` 的类型名表随 locale 翻译**：非 C locale 下英文类型名会变成"不支持的命令" → 脚本固定 `export LC_ALL=C`，分区规格写文件后 `sfdisk "$OUT" < spec`。
- **GPT 最后一个分区不能顶到盘尾**（备份分区表在盘尾最后 33 扇区）→ 分区大小按镜像实际体积算，盘尾留 1 MiB。
- **CI 里 `| grep -q` 会误判**：GitHub 的 bash 默认 `-eo pipefail`，grep 命中后提前退出 → 上游收到 SIGPIPE → 管道返回 141 → 把"存在"判成"缺失"。所有检查改成先捕获输出再用 herestring 匹配。
- **initramfs 不能用 `zstd -dc` 验证**：装了 intel-microcode 后 initrd 是「early cpio + zstd 主归档」拼接格式 → 用 `lsinitramfs` 列举。
- **`mkfs.ext4 -d` 前要清空 `/dev` `/proc` `/sys` `/run`**：构建期挂过的伪文件系统残留会让 populate_fs 报 `Permission denied while opening "bind"`。
- **FAT 上的文件名要能被 8.3 精确表示**：`grub.cfg`→`GRUB.CFG`、`vmlinuz-32` 被截断会让 GRUB 找不到文件 → ESP 内统一用 `vmlinuz` / `initrd.img` / `vmlinuz32` / `initrd32.img`，并用 `mkfs.vfat -F 32`（带长名表）而不是 `mformat`。

## 已知限制

- **内置 Wi-Fi 是 Realtek RTL8723BS（SDIO），不是 USB 型号**：实测确认（AzureWave 模组，SDIO ID `0x024c:0xb723`；设备的 MAC/OUI 等唯一标识已从本仓库脱敏）。
  - Debian 13（6.12）与 Debian 12（6.1 / 686-pae）**都自带主线 staging 驱动 `r8723bs`**（`CONFIG_RTL8723BS=m`），固件 `rtl8723bs_nic.bin` 由 `firmware-realtek` 提供 → **不需要 DKMS**。（注意 `rtl8723bs_fw.bin` 是蓝牙固件，不是 Wi-Fi blob。）
  - Debian 13 稳定仓当前内核是 **6.12.107-1**，它**不含**上游 2026-07/08 回移到 6.12.y 的那批安全修复（kfree_sensitive 等要到 6.12.111 才有）；**6.12.113-1 已全部包含**（见 `trixie-proposed-updates`）。构建时固定内核版本可避免带上有已知 OOB 读取的旧内核。
  - 但 `r8723bs` 是 Realtek 私有协议栈（未迁到 mac80211），只支持 **WPA2-PSK，无 WPA3/SAE**；上游已在 7.4 删除该驱动，官方路线是并入 `rtw88`（`CONFIG_RTW88_8723BS`，需内核 ≥ 7.4，而 Debian 尚无 7.4 内核包，且 trixie 缺 `rtw88/rtw8723b_fw.bin`）。
  - **断流根因（源码级核实结论）**：
    - staging 版**没有** rtw88 那套 tx report 机制（源码 `grep -rn CSTAT` 零命中），所以「固件缺 tx report → 主机栈判丢包 → TCP 吞吐塌陷」这个说法只适用于 rtw88 新驱动，**不适用于本镜像实际加载的 staging 驱动**。
    - staging 版真正的病根有两类：① **没有逐包反馈** —— 数据帧不回报 sent/retry/failed，主机侧没有超时也没有重传反馈，速率是关联时按 wireless_mode/bw_mode **静态查表**定死（`networktype_to_raid_ex()`），主机从不请求速率变更；弱信号下固件内部 ARQ 静默丢弃对主机不可见 → 表现为 TCP 超时重传与吞吐塌陷。② **多条永久卡死路径** —— 丢一次 SDIO 中断就可能让 TX 队列永久停下（worker 不再被踢）、TxOQT 等待无超时自旋、子队列停掉后永不 restart；另外 v5.9 起 `complete()` 是计数型信号量而驱动从不 `reinit_completion`，计数不配平时 TX 线程会忙等（2026-11-05 实机测得 0.2 % CPU，未复现忙等）。
    - 这与现役设备实测到的「ping 抖动 18–168 ms、SSH 偶发拿不到 host key、ping 路由器 0% 丢包而 ping 盒子 5% 丢包」一致：**问题集中在 QM1 侧的无线链路，不是 AP 或网线**。
  - 镜像侧对策：`patches/rtl8723bs/` 提供 5 个修复永久卡死路径的补丁（外部模块 `r8723bs_qm1` 方式安装，见 `scripts/rtl8723bs-module.README.md`）；`/etc/modprobe.d/qm1-rtl8723bs-in-tree.conf` 关掉省电与 40MHz 带宽；`drv-selfcheck.sh` 报出真实绑定驱动并对 `r8723bs` 给出稳定性告警。
  - 结论：**内置 Wi-Fi 可以做主链路**，前提是打上补丁并关掉省电；无法根治的是弱信号下的吞吐塌陷与 WPA3 缺失 —— 前者要靠固定信道 20MHz + 靠近 AP，后者要等 rtw88 内核（≥ 7.4）。
  - **2026-11-04/05 实机只读侦察**（设备的 LAN 地址、主机名等唯一标识已脱敏；SSH 凭据由用户在会话中提供，未入库）：该机当前跑的是 **Void Linux、内核 6.18.60_1、PID 1 为 runit**，加载的是 **staging 的 `r8723bs`**（`/sys/class/net/wlan0/device/driver -> ../../bus/sdio/drivers/rtl8723bs`，dmesg 无 `failed to get tx report from firmware`，进一步印证不是 rtw88）。实时参数全是坏默认值：`rtw_power_mgnt=1 rtw_smart_ps=2 rtw_ips_mode=1 rtw_bw_mode=1`（40MHz），设备 `/etc/modprobe.d/` 为空。链路本身正常（signal −55 dBm、tx bitrate 150 Mbit/s、到网关 0% 丢包），但**抖动全在 QM1 侧**：到网关 30 包 rtt min/avg/max/mdev = 6.4/25.8/87.9/20.3 ms，而同 AP 上另一台机器只有 3.3 ms 均值。staging 驱动无运行时开关（iwpriv 层已移除、无 cfg80211 `.set_power_save`），参数只能在模块加载时给，改参数必须 reload 模块或重启。
  - **硬件拓扑核实（同期）**：eMMC 为 **SanDisk S10032 28.5 GiB**（manfid `0x000070`，rev 0x7；CID 与序列号等唯一标识已脱敏），走 `mmc1` = **SDHCI on ACPI [80860F14:00]**（HS200）；分区 p1 200M vfat → `/boot/efi`、p2 1G swap、p3 27.3G f2fs → `/`。**Wi-Fi 走 mmc0（INT33BB:00）且与 eMMC 不共用 SD 主机**（mmc2 = 80860F14:01 空）⇒ 不存在 SDIO 总线争用，不是断流原因。UEFI：`efi: EFI v2.4 by INSYDE Corp.`，`fw_platform_size`=32，efibootmgr `BootCurrent: 0001` → `\EFI\void_grub\grubia32.efi`，ESP 下只有 32 位 grub ⇒ **该固件实际以 32 位 IA32 EFI 引导**（是否支持 64 位 EFI 仍待实测）。
  - 若识别为 Broadcom，注意 brcmfmac 的 PCIe 型号还需要对应的 NVRAM（`.txt`）文件，`firmware-brcm80211` 未包含全部型号。
- **32 位变体用 Debian 12（bookworm）**：Debian 13 起不再提供 i386 内核包（`binary-i386` 里没有 `linux-image-*`，也没有 i386 安装器），所以 i386 变体固定用 bookworm 的 `linux-image-686-pae`（PAE flavour，适配 Bay Trail）。它只能当救援兜底 —— 32 位 x86 的 Node.js 自 v10 起为 Experimental，Hermes 要求的 Python 3.14 也没有 i686 预编译产物。
- **Bay Trail 无 AVX**：本地 LLM（llama.cpp）会退化到 SSE 路径；无头 agent 编排逻辑几乎不受影响。
- **这颗 Atom 没有 cpufreq 缩放驱动**（内核无 `CONFIG_ACPI_CPUFREQ`），不是缺驱动，是平台本身没有；长时间满载只能靠散热，长任务建议排队而非并发。
- 镜像与设备一一对应：根分区 UUID 在构建期固定，克隆到另一台设备需重新构建或改 UUID。

## 参考案例

- [masterzorag/Z3735F-linux](https://github.com/masterzorag/Z3735F-linux) —— 32 位 EFI shell 加载 32 位 GRUB2、再引导 64 位系统；本文的引导器构建命令即出自此
- [Ubuntu Launchpad #1341944](https://bugs.launchpad.net/ubuntu/+bug/1341944) —— 32 位 UEFI bootloader 引导 64 位 Ubuntu
- [DietPi issue #7518](https://github.com/MichaIng/DietPi/issues/7518) —— 为 Z3735F 这类老 Atom 增加 32 位 EFI 启动支持
- [askubuntu 392719](https://askubuntu.com/questions/392719/) —— 从 Debian multi-arch ISO 取 `bootia32.efi` 与 `grub/i386-efi`
- [sturmflut: Installing Ubuntu on BayTrail tablets](https://sturmflut.github.io/blog/) —— 32 位引导器 + 64 位内核（mixed-mode）
- [unix.stackexchange 155557](https://unix.stackexchange.com/questions/155557/) —— BayTrail 仅 32 位 UEFI 的处理

## 许可

GPL-2.0-or-later（见 `LICENSE`）。脚本与文档可自由使用；被打包进镜像的 Debian 软件包各自遵循其上游许可。
