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

## 驱动与固件策略

「把硬件驱动都带上，保证硬件能够启动」分成三类处理：

| 类别 | 内容 | 来源 |
|------|------|------|
| **内核自带** | eMMC/SD（`sdhci_pci` / `sdhci_acpi`）、USB（`xhci_hcd`/`ehci_pci`/`usb_storage`）、显卡 `i915`、Intel HDA、蓝牙 `btusb`、RTC、ACPI/电源管理 | Debian `linux-image-amd64` |
| **需 firmware** | Broadcom brcmfmac、Realtek 8723*/8812*、Atheros、Intel 7 系无线、Intel 微码、SOF 音频固件 | `firmware-brcm80211` / `firmware-realtek` / `firmware-atheros` / `firmware-iwlwifi` / `firmware-sof-signed` / `intel-microcode`（**位于 non-free-firmware 组件**，mmdebstrap 必须带 `--components=main,non-free-firmware`） |
| **需 out-of-tree（DKMS）** | Realtek RTL8723AU / 8812AU / 8812BU 等消费级无线芯片（主线内核无驱动） | 通过 `QM1_DKMS_DEB_DIR` 注入预编译 .deb，或改用 USB 以太网适配器 |

启动关键路径（eMMC 控制器 + 根文件系统）会被写进 initramfs：`MODULES=most` + `COMPRESS=zstd`，并显式声明 `sdhci_pci sdhci_acpi mmc_block vfat ext4 usb_storage xhci_hcd ehci_pci`。

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

- **Wi-Fi 芯片型号待实测确认**：QM1 的无线芯片公开资料查不到型号，若为 Realtek 8723AU/8812AU/8812BU 则需 DKMS 驱动（主线内核没有）。设备端 `lsusb` / `lspci -kn` 可确认；在此之前建议常驻使用 USB 以太网适配器。
- **i386 变体只能当救援兜底**：32 位 x86 的 Node.js 自 v10 起为 Experimental，且没有 32 位 Chromium，承不了现代 agent 运行时。
- **Bay Trail 无 AVX**：本地 LLM（llama.cpp）会退化到 SSE 路径；无头 agent 编排逻辑几乎不受影响。
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
