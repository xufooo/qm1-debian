# qm1-debian

为 ASUS QM1-B002 制作基于 Debian 官方 amd64 安装 ISO 的完整安装盘。保留 Debian-Installer 的语言、联网、账号、分区确认、引导器安装和救援流程，加入 QM1 的 IA32 EFI 入口及板级驱动。安装完成后从 eMMC 独立启动。

- 目标硬件：Atom Z3735F / 2 GB 内存 / 32 GB eMMC / RTL8723BS SDIO Wi-Fi 与 UART 蓝牙。
- 官方 ISO 的签名与 SHA512 必须验证；EFI 同时提供官方 IA32 CD loader 和原有 x64 loader。
- 官方安装内核与树外 Wi-Fi 模块按 ABI、包版本和符号 CRC 配对；驱动及固件同时进入安装环境和目标系统。
- 安装菜单默认文字模式，保留图形安装、专家安装及救援选项；安装盘不会自动分区或擦除 eMMC。
- 系统不预装 Hermes / Chrome。板级支持包含内存、eMMC 电源、Bay Trail idle、音频和蓝牙设置；应用组合负载需要实机验收。
- CI：`build-official-installer` 构建完整安装盘，并在 IA32 / x64 UEFI 下从 USB 完成虚拟安装，再移除 USB 验证目标盘启动、正常账号密码、sudo 和驱动。只有通过后才发布安装 ISO。
- 原预部署整盘镜像保留为手动 `build-image-legacy` 诊断任务，不再作为默认交付方式。

当前处于安装盘改造与验证阶段。静态检查和虚拟机通过不能证明真实 Wi-Fi、蓝牙、microSD、eMMC 长稳以及 Hermes + Chrome 组合负载全部通过；交付验收必须记录这些实机结果。

构建入口：`scripts/build-official-installer.sh`。构建需要 Debian trixie 环境、对应官方内核头文件和 `scripts/build-rtw88-8723bs-module.sh` 产出的驱动包；依赖及完整命令见 `.github/workflows/build-official-installer.yml`。

许可：GPL-2.0-or-later。改造后的镜像是 QM1 安装盘，不能冒称未经修改的 Debian 官方镜像。
