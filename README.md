# qm1-debian

构建 ASUS QM1-B002 的 Debian 13 (trixie) amd64 整机镜像：双架构 EFI 引导器 + 驱动与固件预置 + 系统定制 + 首启配置。

- 目标机器：Intel Atom Z3735F（Bay Trail-T，4 核 4 线程 1.33–1.83 GHz，无 AVX/AVX2）/ 2 GB DDR3L / 32 GB eMMC / 无 RJ45
- 引导：32 位 IA32 EFI 固件也能引导 64 位内核（ESP 同时放 `BOOTIA32.EFI` 与 `BOOTX64.EFI`）
- Wi-Fi 用树外 rtw88 模块替代发行版 staging `r8723bs`；蓝牙用内核 `hci_uart` + 厂商固件下发
- 镜像构建与安装全在 CI（`lint` / `build-image` / `build-wifi-module`），细节看各脚本 `--help`

许可：GPL-2.0-or-later。
