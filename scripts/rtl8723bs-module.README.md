# r8723bs_qm1 —— QM1 内置 RTL8723BS 的 out-of-tree 驱动

本目录配套的构建链把 Debian 13 内核自带的 `r8723bs` 驱动**打好补丁**、
**改名**成 `r8723bs_qm1`，编译成 out-of-tree 内核模块并打成 `.deb`。

| 项目 | 值 |
| --- | --- |
| 硬件 | ASUS QM1-B002 内置 Realtek RTL8723BS（SDIO，ID `0x024c:0xb723`，AzureWave） |
| 源码来源 | Debian `linux` 源包的 `drivers/staging/rtl8723bs/`（与发行版内核同源） |
| 模块名 | `r8723bs_qm1`（内核里的模块名也变了，不只是文件名） |
| 软件包 | `qm1-rtl8723bs-module` |
| 目标内核 | 每个内核版本单独出一包（vermagic + symbol version 绑定） |

---

## 1. 它和内核自带的 `r8723bs` 是什么关系

Debian 13 的 `linux-image-6.12.x+deb13-amd64` 里已经有主线 staging 驱动
`r8723bs`（`CONFIG_RTL8723BS=m`），固件是 `firmware-realtek` 提供的
`/usr/lib/firmware/rtlwifi/rtl8723bs_nic.bin`。

本包**不是**替换它，而是**并存的第二个实现**：

```
树内    r8723bs        ← Debian 内核自带，主线 staging 驱动
本包    r8723bs_qm1    ← 同一份源码 + 本仓库 patches/ 里的补丁
```

两份源码同源，但驱动代码里存在几个已知问题（省电模式下断流、
WMM 参数与监控帧长度相关的越界读等），补丁就是冲着这些去的。
**补丁打在源码上，不打在树内模块上** —— 所以必须自己编译一份。

### 为什么必须改名，不能直接替换树内模块

两个模块带**完全相同**的 SDIO alias（`sdio:c*v024CdB723*`，由
`MODULE_DEVICE_TABLE(sdio, sdio_ids)` 生成）。

`modprobe` 按 alias 加载时会把**所有**匹配项都插进内核。如果树内的
`r8723bs` 先注册了 SDIO driver，打补丁的那个再注册就会拿到 `-EBUSY`，
表现为「模块加载了但没有无线网卡」。

所以本包用两个手段保证只有一个驱动真正生效：

1. 模块改名成 `r8723bs_qm1`（内核里 `lsmod` 看到的也是这个名字）；
2. `/etc/modprobe.d/qm1-rtl8723bs.conf` 里 `blacklist r8723bs`，
   把树内那个挡掉。

`blacklist r8723bs` 在 kmod 里的语义是「解析 alias 时跳过被 blacklist 的模块」。
它**只挡加载，不挡卸载** —— `modprobe -r r8723bs` 照样能用。

### 改名是怎么做到的（没改一行 C 代码）

上游是**复合模块**：

```make
obj-$(CONFIG_RTL8723BS) := r8723bs.o
r8723bs-y = core/rtw_ap.o core/rtw_btcoex.o ... os_dep/xmit_linux.o
```

构建脚本从上游 Makefile 里解析出这份对象列表，生成一份包装 Makefile：

```make
obj-m := r8723bs_qm1.o
r8723bs_qm1-y := core/rtw_ap.o core/rtw_btcoex.o ... os_dep/xmit_linux.o
```

`modpost` 会把模块名（`.modinfo` 里的 `name=`）写成 `r8723bs_qm1`，
内核 `module/main.c` 读的正是这个 `name=`，所以内核里看到的模块名也变了。

> 单纯把 `.ko` 文件改名是**没用**的：内核读的是 `.modinfo` 里的 `name=`。

---

## 2. 构建

CI：`.github/workflows/build-wifi-module.yml`（在 `debian:trixie-slim` 容器里跑）。

本地（Debian/Ubuntu，需装内核头文件）：

```bash
sudo apt install build-essential dpkg-dev curl patch kmod
sudo apt install linux-headers-$(uname -r)

# 第二个参数是目标内核：脚本据此挑对应的 Debian linux 源包版本
# （6.12.113+deb13-amd64 → linux 6.12.113-1），避免「用 A 的源码编 B 的头文件」。
# 这一步可以省：build 脚本发现源码树不完整时会自己抓。
bash scripts/fetch-rtl8723bs-source.sh build/rtl8723bs-src "$(uname -r)"
bash scripts/build-rtl8723bs-module.sh --kver "$(uname -r)"
```

产物：

```
build/wifi-module/qm1-rtl8723bs-module_1.0.0_amd64.deb
```

可选参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--kver` | `6.12.113+deb13-amd64` | 目标内核（`uname -r` 形式） |
| `--src-dir` | `build/rtl8723bs-src` | 上游源码目录 |
| `--work-dir` | `build/rtl8723bs-work` | 构建与打包中间目录 |
| `--out-dir` | `build/wifi-module` | `.deb` 输出目录 |
| `--patch-dir` | `patches/rtl8723bs` | 补丁目录（按文件名排序依次应用） |

补丁应用顺序：`patches/rtl8723bs/*.patch` 按文件名排序。
任何一个补丁打不上就**立刻退出**并打印失败 hunk 的上下文 —— 绝不带着
「半打补丁」的源码树去编译。
补丁目录里一个 `.patch` 都没有时同样**直接失败**：这个模块的全部价值就是
那几个补丁，直接编上游源码等于编了一份没修过断流问题的驱动，
装上去只会让人误以为已经修好了。

### 模块与内核版本是一一对应的

`.deb` 里的模块装在 `/lib/modules/<KVER>/extra/rtl8723bs/` 下，vermagic 里
写死 `$KVER`：**一个包只对构建它时的那一个内核版本有效**。

Debian 13 的 `6.12.x` point release 会滚动（6.12.113 → 6.12.115 → …）。
镜像里的内核版本一换，旧包的 vermagic 就对不上，模块根本装不进去
（`modprobe: FATAL: Module r8723bs_qm1 not found`）。

所以：

- **升级内核之后必须重新跑一次 `.github/workflows/build-wifi-module.yml`**
  出一个新的 `.deb`，再装新的；
- 装之前先对一下版本：包里模块的路径是 `/lib/modules/<KVER>/…`，
  这个 `<KVER>` 必须等于目标机上的 `uname -r`；
- CI 里那个工作流有每周一 04:10 UTC 的定时跑（`schedule: cron "10 4 * * 1"`），
  就是为了在 Debian 滚动 point release 之后自动出一个跟得上镜像的包；
- 想钉死某个 point release，用 workflow_dispatch 的 `kernel_version` 输入；
  此时源码也跟着走（fetch 脚本按目标内核选对应的 linux 源包版本）。

---

## 3. 安装

```bash
sudo dpkg -i qm1-rtl8723bs-module_1.0.0_amd64.deb
```

装完自动做三件事：

- `depmod -a <KVER>` —— 让 `modules.dep` / `modules.alias` 认得新模块；
- `systemctl enable qm1-rtl8723bs.service`；
- 写 `/etc/modprobe.d/qm1-rtl8723bs.conf`。

装完**需要重启**（模块与内核版本绑定，运行中的内核不能热插模块）。

开机后确认：

```bash
lsmod | grep r8723bs          # 应看到 r8723bs_qm1，且没有 r8723bs
ip link show wlan0            # 接口名默认 wlan%d
```

> 镜像里的 `/etc/modules-load.d/qm1-hardware.conf` 列的是树内的 `r8723bs`。
> 装上本包之后，那一条会被 `blacklist` 挡住（变成空操作），
> 真正加载 `r8723bs_qm1` 的是 `qm1-rtl8723bs.service`。

### modprobe 参数

`/etc/modprobe.d/qm1-rtl8723bs.conf` 里带四个参数：

```
blacklist r8723bs
options r8723bs_qm1 rtw_power_mgnt=0 rtw_ips_mode=0 rtw_smart_ps=0 rtw_bw_mode=0
```

它们是 Realtek 私有协议栈的省电开关，**不受 `wifi.powersave` 控制**：

| 参数 | 0 的含义 | 默认值 | 作用 |
| --- | --- | --- | --- |
| `rtw_power_mgnt` | `PS_MODE_ACTIVE`（不休眠） | 1（`PS_MODE_MIN`） | 关掉省电 → 断流的主要开关 |
| `rtw_ips_mode` | `IPS_NONE`（不空闲省电） | 1（`IPS_NORMAL`） | 关掉空闲省电 → 断流的第二个开关 |
| `rtw_smart_ps` | 关闭智能省电 | 1 | 降低链路空闲时被下线的概率 |
| `rtw_bw_mode` | 关闭带宽自适应 | 1 | 2.4G 场景固定 20MHz，少一次切带宽的重协商 |

### systemd 单元

`/lib/systemd/system/qm1-rtl8723bs.service`：

```
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe -r r8723bs
ExecStart=/sbin/modprobe r8723bs_qm1
ExecStop=-/sbin/modprobe -r r8723bs_qm1
```

`ExecStartPre` 先把树内的 `r8723bs` 卸掉（万一它已经被加载），
避免两个驱动抢同一个 SDIO 设备。

---

## 4. 回退

三种回退路径，从轻到重：

**（1）临时换回树内驱动，不卸载本包**

```bash
sudo systemctl disable --now qm1-rtl8723bs.service
sudo rm /etc/modprobe.d/qm1-rtl8723bs.conf
sudo depmod -a
sudo modprobe r8723bs
```

**（2）彻底卸载本包**

```bash
sudo dpkg -r qm1-rtl8723bs-module
```

`prerm` 会停掉服务并卸载模块，`postrm` 会重跑 `depmod`。

**（3）内核层面兜底**

如果 `r8723bs_qm1` 因为符号版本不匹配加载失败（vermagic 对不上），
删掉 `/etc/modprobe.d/qm1-rtl8723bs.conf` 里的 `blacklist` 行，
重启，树内 `r8723bs` 就会重新接管。

---

## 5. 取舍与已知限制

**① 模块名不同，系统里会同时看到两个名字**

内核里只有 `r8723bs_qm1`，树内的 `r8723bs` 被 blacklist 挡住。
好处是两边可以来回切，出问题好定位；坏处是习惯用 `r8723bs` 查状态的人
要改成 `r8723bs_qm1`。

**② 每个内核版本要重新编译、重新装**

内核模块与内核版本强绑定（`vermagic` + symbol version）。
Debian 的 6.12.x point release 会滚动，模块包不跟着走。
升级内核后旧模块会失效，必须用新内核的头文件重新编译再装。
CI 默认跟着发行版元包 `linux-headers-amd64` 走，
和 `build-image.yml` 造镜像时装的是同一套内核，就是为了避免这个错位。

**③ Secure Boot 下装不上去**

out-of-tree 模块不在 Debian 的签名信任链里，Secure Boot 开启时
`insmod` 会因为签名校验失败被拒绝（`Key was rejected by service`）。
需要：

1. 生成 MOK（Machine Owner Key），用 `mokutil --import` 灌进固件；
2. 重启，在固件界面确认 enrollment；
3. 用 MOK 私钥重新签一遍模块（`scripts/linux/sign-file`）。

也就是说 Secure Boot 用户要么关掉 Secure Boot，要么额外做一次 MOK 流程。
树内 `r8723bs` 没有这个问题。

**④ 源码来自 Debian 的 `linux` 源包，不是上游 git**

好处是和发行版内核里的那一份同源；坏处是跟着 Debian 的 point release
走，而 Debian 会给上游 staging 驱动打安全补丁（补丁内容与上游不同）。
这正是本仓库要自己打补丁的原因。

**⑤ 打包的是 `.deb`，不是 DKMS**

`.deb` 的优点是装完就有明确版本、可控、可回退；
缺点是**不会跟着内核升级自动重编**。如果希望内核升级后自动重编，
得改成 DKMS 方案（本仓库当前没有实现）。

---

## 6. 参考

- 上游源码：Debian `linux` 源包 `6.12.113-1` 的 `drivers/staging/rtl8723bs/`
  （取自 `sources.debian.org`）
- SDIO 设备表：`os_dep/sdio_intf.c` 的 `sdio_ids[]`
- 模块参数：`os_dep/os_intfs.c`
- 复合模块定义：上游 `drivers/staging/rtl8723bs/Makefile`
