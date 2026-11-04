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

# 3) 合成整盘镜像（GPT：p1 FAT32 ESP 512MiB + p2 ext4 根）
bash scripts/assemble-disk.sh --esp build/out/esp.img --root build/out/rootfs.img \
     --out build/qm1-debian13-amd64.img --size-gib 30

# 刷写（破坏性操作，务必先整盘备份并校验 SHA-256）
sudo dd if=build/qm1-debian13-amd64.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress
```

产物清单见 `build/out/manifest.txt`（尺寸、UUID、内核版本、SHA-256）。

## 安装（把镜像装到 QM1）

镜像**自带引导链**：ESP 里有 `BOOTIA32.EFI` + `BOOTX64.EFI` + 内核 + initrd + `grub.cfg`，
写进 eMMC 就能脱离 U 盘自启动。安装按「先 U 盘试跑 → 再动 eMMC」的顺序做。

### 第 1 步：先在 U 盘上试跑（不碰 eMMC）

```bash
# 把整机镜像写到 U 盘（先用 lsblk 确认设备名，例如 /dev/sdb）
sudo dd if=build/out/qm1-disk.img of=/dev/sdX bs=4M conv=fsync status=progress
```

插好 U 盘 → BIOS 里选 U 盘启动 → GRUB 菜单选 `QM1 Debian 13 (64-bit amd64)`。
能进系统并跑通自检，说明引导链和驱动都成立，再考虑刷 eMMC。

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
# 先用任意分区工具建 GPT：p1 = 512 MiB FAT32（卷标 QM1ESP），p2 = 其余 ext4（卷标 QM1ROOT）
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
| **内核模块（`=m`）** | eMMC/SD（`sdhci-pci` / `sdhci-acpi` / `mmc_block`）、USB（`ehci-pci`/`xhci-hcd`/`usb-storage`）、显卡 `i915`、Intel HDA（`snd-hda-intel` + `snd-hda-codec-realtek`）、蓝牙 `btusb`、无线 `brcmfmac`/`iwlwifi`/`rtw88` | Debian `linux-image-amd64` |
| **内置（`=y`）** | ACPI、EFI stub（含 handover）、串口控制台、RTC（`CONFIG_RTC_DRV_CMOS`）、thermal、intel_idle | 同上（无法改成模块，属发行版正常形态） |
| **需 firmware** | Broadcom brcmfmac、Realtek 8723*/8812*、Atheros、Intel 无线、Intel 微码、SOF 音频固件 | `firmware-brcm80211` / `firmware-realtek` / `firmware-atheros` / `firmware-iwlwifi` / `firmware-sof-signed` / `intel-microcode`（**位于 non-free-firmware 组件**，mmdebstrap 必须带 `--components=main,non-free-firmware`） |
| **需 out-of-tree（DKMS）** | Realtek RTL8723AU / 8812AU / 8812BU 等消费级无线芯片（主线内核无驱动） | 通过 `QM1_DKMS_DEB_DIR` 注入预编译 .deb，或改用 USB 以太网适配器 |

启动关键路径（eMMC 控制器 + 根文件系统）会被写进 initramfs：`MODULES=most` + `COMPRESS=zstd`，并显式声明 `sdhci_pci sdhci_acpi mmc_block vfat ext4 usb_storage xhci_hcd ehci_pci`。
`modules-load.d` 只放 `i915`（HDMI 首屏）、`snd_hda_intel`、`btusb`；其余靠 udev 自动加载。
构建产物里的 `driver-manifest.txt` 会用 `modinfo -k <版本>` 与 `/boot/config-*` 判定每个驱动是 `module` / `builtin` / `absent`，CI 对启动关键项做硬断言。

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
- `build-image`：在 `debian:trixie-slim`（privileged）里跑完整构建（mmdebstrap → hooks → 引导器 → ESP → ext4），校验 SHA-256、引导器文件类型、ESP 目录清单、驱动清单，并用 `debugfs` 直接检查 ext4 镜像里的属主/权限与定制文件；手动触发时可选择上传镜像。

## 目录结构

```
scripts/
  lib/common.sh          公共函数
  build-bootloaders.sh   构建双架构 EFI 引导器（grub-mkimage）
  build-rootfs.sh        mmdebstrap 生成根文件系统（--hook-dir=hooks/）
  make-esp.sh            组装 FAT32 ESP（mtools，无需 root）
  build-image.sh         生成 esp.img + rootfs.img + manifest
  assemble-disk.sh       合成 GPT 整盘镜像
  verify-image.sh        debugfs 直接校验 ext4 镜像（属主/权限/文件）
  drv-selfcheck.sh       设备端硬件自检
  grub.cfg.example       ESP 引导菜单模板（64 位 + 32 位两个启动项）
hooks/                   mmdebstrap customize 钩子（在宿主执行，$1 = chroot 目录）
  customize01-base.sh    主机名/locale/时区/fstab/服务开关
  customize02-drivers.sh 内核+firmware+initramfs+模块清单（启动关键驱动缺失即失败）
  customize03-overlay.sh 应用 overlay/ 与设备端自检脚本
overlay/                 随镜像分发的定制层
```

## 已知限制

- **Wi-Fi 芯片型号待实测确认**：QM1 的无线芯片公开资料查不到型号，若为 Realtek 8723AU/8812AU/8812BU 则需 DKMS 驱动（主线内核没有）。设备端 `lsusb` / `lspci -kn` 可确认；在此之前建议常驻使用 USB 以太网适配器。若识别为 Broadcom，注意 brcmfmac 的 PCIe 型号还需要对应的 NVRAM（`.txt`）文件，`firmware-brcm80211` 未包含全部型号。
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
