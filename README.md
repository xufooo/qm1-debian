# qm1-debian

构建 ASUS QM1-B002 的 Debian 13 (trixie) amd64 整机镜像：双架构 EFI 引导器 + 驱动与固件预置 + 系统定制 + 首启配置。

- 目标机器：Intel Atom Z3735F（Bay Trail-T，4 核 4 线程 1.33–1.83 GHz，无 AVX/AVX2）/ 2 GB DDR3L / 32 GB eMMC / 无 RJ45
- 引导：ESP 同时放 `BOOTIA32.EFI` 与 `BOOTX64.EFI`，分别对应 IA32 / x64 固件；IA32 GRUB 可引导 amd64 Linux，不要求 IA32 固件直接执行 x64 EFI 应用。
- Wi-Fi 用树外 rtw88 模块替代发行版 staging `r8723bs`；蓝牙用内核 `hci_uart` + 厂商固件下发
- 镜像仅含系统底座，不预装 Hermes / Chrome，也不在首启时下载应用。系统验收后由用户安装并验证组合负载。
- 镜像构建与安装逻辑验证在 CI（`lint` / `build-image` / `build-wifi-module`），细节看各脚本 `--help`

许可：GPL-2.0-or-later。
