# 交付手册：从 CI 产物到一台开箱即用的 QM1

这份文档写的是**拿到 CI 产物之后，到机器真的能用**之间的每一步。
每一步都标了「怎么验证」，因为这条链路上出过好几类"看起来成功了、
其实没有"的问题（写好的单元没被 enable、凭据格式不对、校验比的不是
写进去的字节……）。

目标状态一句话：**把 Debian 装进 eMMC，从 eMMC 启动，开机自动连 Wi-Fi，
能 SSH 登录，时间正确。**

---

## 0. 你需要准备什么

| 东西 | 规格 | 说明 |
|---|---|---|
| U 盘 | **≥64 GiB**，USB 2.0/3.0 均可 | 同一个盘既当启动盘又当整盘备份区（见 §3） |
| 构建产物 | CI 的 `build-image` 成功 ⇒ 三个文件 | 见 §1 |
| 凭据 | 你的 Wi-Fi SSID/PSK | 见 §2 |

为什么 U 盘要 ≥64 GiB：eMMC 是 28.5 GiB，安装器在写盘前会做**整盘备份**
（逐分区 sha256 校验）。备份有三个落点，优先顺序是
`--backup-dir` → 介质上空间足够的挂载点 → **介质尾部未分区空间**。
用「尾部未分区空间」这一档时，U 盘 必须比 eMMC 大出至少 28.5 GiB
（64 GiB 是安全余量）。

---

## 1. 取构建产物

CI（`build-image` 作业，开了 `upload_images` 输入）成功后拿这些文件：

| 文件 | 是什么 |
|---|---|
| `qm1-installer.img.zst` | **安装盘镜像**（GPT 整盘，ESP 里是安装菜单）—— 走 U 盘安装用这个 |
| `qm1-disk.img.zst` | **整机盘镜像**（GPT 整盘，ESP 里是正常启动菜单）—— 走主机侧直写用这个 |
| `SHA256SUMS` | 校验和 |
| `manifest.txt` | 构建清单：内核版本、ESP 卷标、Wi-Fi 模块状态、固件列表 |
| `install-qm1.sh` | 主机侧安装脚本（见 §4 路径 B） |
| `provision-agent.sh` | 装 Hermes + headless Chrome 的脚本（装完系统后跑） |

解压（zstd 压缩是为了上传快）：

```sh
zstd -d qm1-installer.img.zst
zstd -d qm1-disk.img.zst
sha256sum -c SHA256SUMS
```

⚠️ 出厂镜像里**不含任何 Wi-Fi 凭据**。仓库是公开的，凭据不该进仓库、
也不该进 CI 日志。凭据在 §2 单独注入。

⚠️ 这两个 `.img` 是**整盘镜像**（GPT 布局，ESP 从 1 MiB 开始），
不是能直接挂载的分区镜像。要看内容用 mtools 的偏移语法：

```sh
mdir -i qm1-installer.img@@1048576 ::/          # 偏移 = 2048 扇区 × 512
```

---

## 2. 注入 Wi-Fi 凭据

```sh
# 1) 生成凭据目录（交互式，会问 SSID/PSK；PSK 会被问两次）
bash scripts/prepare-provision.sh --out /tmp/qm1-provision

# 2) 把它注入已经构建好的启动盘镜像（不重建镜像）
bash scripts/inject-provision.sh --image qm1-installer.img --dir /tmp/qm1-provision

# 3) 验证：列一下 ESP 里多出来的目录
mdir -i qm1-installer.img@@$((2048*512)) ::/qm1/provision
```

第 3 步必须能看到 `wpa_supplicant.conf` / `ssh_user` /
`authorized_keys` / `ssh`（私钥）/ `hostname`。

镜像也分两种，注入的目标要跟 §4 选的路径对上：

- 走 U 盘安装（路径 A）→ 注入 `qm1-installer.img`；
- 走主机侧直写（路径 B）→ 注入 `qm1-disk.img`。

**关于 PSK 的写法**（这里很容易踩坑）：

- `psk="你的口令"` —— 明文口令，**8..63 个字符**，引号和反斜杠会被转义；
- `psk=<64 位十六进制>` —— **不加引号**，这是直接给 PMK；
- 加了引号的 64 位十六进制会被当成 64 个字符的口令 → 超过 63 → 认证失败。

`prepare-provision.sh` 与安装器都按上面这套规则生成，**不要手改**
`wpa_supplicant.conf`。

---

## 3. 写 U 盘

```sh
# 整盘写入（会清空 U 盘）
dd if=qm1-installer.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

写完之后，U 盘上会有一张 256 MiB 的 FAT32 分区（卷标见 `manifest.txt` 的
`esp_label=`），后面是未分区空间 —— **那段空间就是安装时的整盘备份区**，
不要手动分区。

插到 QM1 上开机，UEFI 里选 U 盘（`BOOTX64.EFI` / `BOOTIA32.EFI` 两个引导器
都放了，32 位固件也能引导 64 位内核）。

---

## 4. 安装到 eMMC

有两条路径，**推荐路径 A**（它会自动选对目标、自动备份、自动登记 EFI
启动项、并且生成登录口令）。

### 路径 A：从 U 盘启动安装介质（推荐）

把 `qm1-installer.img` 写到 U 盘：

```sh
dd if=qm1-installer.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

写完之后，U 盘上会有一张 256 MiB 的 FAT32 分区（卷标见 `manifest.txt` 的
`esp_label=`），后面是未分区空间 —— **那段空间就是安装时的整盘备份区**，
不要手动分区。

插到 QM1 上开机，UEFI 里选 U 盘（`BOOTX64.EFI` / `BOOTIA32.EFI` 两个引导器
都放了，32 位固件也能引导 64 位内核）。

启动盘里的 GRUB 菜单有三项：

| 菜单项 | 作用 |
|---|---|
| ① 安装 QM1 到 eMMC（备份 → 写入 → 校验） | 正式安装 |
| ② 试用系统（不写盘） | 先跑驱动自检，确认 Wi-Fi/蓝牙/eMMC 都正常再装 |
| ③ GRUB 命令行（救援） | 手工救援 |

**建议先跑 ②**：它不写盘，能用 `qm1-selftest` 把硬件状态看一遍
（Wi-Fi 绑定的是哪个驱动模块、eMMC 有没有掉卡风险、蓝牙栈在不在）。

正式安装（①）会依次做这些事，任何一步失败都会**明确中止并说明现状**：

1. **选目标**：按 `/sys/block/<n>/device/type` 区分 eMMC / SD 卡 / SDIO 卡，
   **SDIO 卡（内置 Wi-Fi）会被跳过** —— 这台机器上 eMMC 是 `mmcblk1`，
   `mmcblk0` 是 Wi-Fi 的 SDIO 卡。
2. **目标检查**：拒绝写正在挂载的分区、拒绝写源盘本身。
3. **读凭据**：从启动盘 `/qm1/provision/` 读取；没有就交互补齐。
4. **备份**：整盘备份到 `--backup-dir` / 介质挂载点 / 介质尾部未分区空间，
   然后**逐分区 sha256 校验**（GPT 头 + 每个分区）。校验不过就中止，
   并且明确告诉你「还没有对目标盘做任何写入」。
5. **写盘**：重建 GPT（ESP + 根分区，按分区类型识别）、写内核与根文件系统，
   然后**只比真正写进去的那段字节**的 sha256（早期版本这里比的是整个
   分区，会导致每次安装都在这里误停）。
6. **收尾**：注册 UEFI 启动项、写安装记录、把凭据写进目标根分区。
   登记的引导器是 **BOOTIA32.EFI**（ESP 上两条引导器里选它）：
   这台机器的固件是 32 位 IA32，**加载不了 PE32+ 的 BOOTX64.EFI**；
   而 64 位固件按 UEFI 规范必须能加载 IA32 应用 ⇒ 只有 IA32 那条
   两种固件都能用。

**关键信息**：安装完成后，屏幕上会打印

- 登录用户名（默认 `qm1`）
- 随机生成的初始口令
- 改口令的命令
- 凭据记录文件的位置（`/etc/qm1-installed-to-emmc`，权限 0600）

这个口令只在装机时打印一次，**记下来**。

### 路径 B：从 Linux 主机直接写 eMMC

前提：机器上已经有能用的 Linux 环境（可以是 U 盘启动的试用系统）。

```sh
# 先看清楚哪个是 eMMC —— QM1 上 mmcblk0 是 Wi-Fi 的 SDIO 卡！
lsblk -o NAME,TYPE,MODEL,SIZE

# 先干跑一遍，看看会做什么
sudo bash install-qm1.sh --image qm1-disk.img --target /dev/mmcblk1 --dry-run

# 真装（强制整盘备份 + 写入校验 + EFI 启动项登记）
sudo bash install-qm1.sh --image qm1-disk.img --target /dev/mmcblk1 \
     --backup-dir /mnt/usb/qm1-backup --yes
```

这条路径与路径 A 的差别：

- 目标必须**手工指定**（脚本会按 MMC type 拦掉 SDIO 卡与 SD 卡，但不会
  替你猜）；
- **不会**生成随机登录口令（整机镜像里的 `qm1` 账号是锁着的，
  需要你用 `passwd` 设一个，或走 §5 的方式）；
- 备份是整盘 `dd`，并且**逐分区与写盘前的原盘比对**（不一致就中止）；
- EFI 启动项登记用 `efibootmgr`，登记不上 = 装机失败（机器开不了机却
  报成功是最坏的结果）。只有明确加 `--skip-efi-entry` 才允许跳过；
- 写盘后会按目标真实容量**重建分区表**（ESP 保持 1 MiB 偏移、根分区
  撑到盘尾留 1 MiB 给备份 GPT），清掉旧盘尾部的残留与旧备份 GPT，
  再 `resize2fs` 把根分区撑满 —— 不会在 28.5 GiB 的 eMMC 上留下
  22 GiB 的旧系统残渣和两套 GPT。

---

## 5. 开机即用要满足的四条

装完第一次开机，下面四条必须同时成立（`qm1-selftest` 会逐条检查）：

| # | 判据 | 怎么看 |
|---|---|---|
| 1 | **DNS 有数据源** | `/etc/resolv.conf` → 指向 `/usr/lib/systemd/resolv.conf`；`resolvectl status` 能解析出域名 |
| 2 | **有可登录账号** | `qm1` 用户存在、口令不是你猜的那个随机值 |
| 3 | **Wi-Fi 自动连上** | `iw dev wlan0 link` 显示已关联；绑定模块名必须是 `rtw88_qm1` |
| 4 | **时钟正确** | `timedatectl` 不再是 1970 年（否则 TLS 全废） |

其中第 1 条曾经是整条链路的**总开关**：Debian 13 的 systemd 与
systemd-resolved **都不提供 `/etc/resolv.conf`**，镜像里不自己挂上
stub 就没有 DNS，NTP 解析不了域名 → 时钟停在 1970 → HTTPS 全失败。

### 5.1 这些判据在 CI 里已经查过多少

流水线现在会在 QEMU 里**真的把出厂镜像启动一次**
（`scripts/boot-smoke.sh`），并在启动日志上做断言：

- 串口控制台里必须出现 `Reached target multi-user.target`
  （⇒ 内核起来了、initrd 找到了根、systemd 走完了开机流程）；
- `Started ssh.service`、`Started systemd-resolved.service`、
  `Finished qm1-firstboot.service`、`Started qm1-wifi@wlan0.service`
  四条必须出现
  （⇒ sshd / DNS 数据源 / 首启配置 / Wi-Fi 单元都挂上了）；
- `ssh.service`、`systemd-resolved.service`、`systemd-networkd.service`、
  `qm1-firstboot.service`、`qm1-hardware-fixups.service`
  **一个都不许出现 "Failed to start"**；
- 客户机关机后，再把它写进磁盘的 journal 导出来（debugfs + journalctl）
  离线读，断言 systemd 的启动收尾记录与 `[qm1-firstboot]` 的输出都在。

也就是说第 1、2 条与「内核/initrd/systemd 起得来」这一层，**在 CI 里
就有证据**，不用等刷机才发现。

> 为什么不用 `systemd.debug_shell=1` 进客户机里敲命令：systemd 从 v255
> 起把早期调试 shell 换成了 sulogin（`src/sulogin-shell/`），它要
> **口令登录**才给 shell —— 而出厂镜像里没有可登录账号（口令是安装时
> 才生成的），自动化根本进不去。上面这套是纯日志断言，不需要交互。

> 断言串为什么写成"单元名"而不是"描述"：systemd 从 v255 起改了控制台
> 状态行的格式 —— 单元名被插到描述前面并用 ANSI 高亮包住，描述还会按
> 终端宽度截断（`Q…rovisioning`）。拿描述去匹配，匹配不到时在 CI 上和
> "启动失败"长得一模一样，只能真跑一次 QEMU 才知道自己写错了。
> `scripts/boot-smoke-assert.sh` 把断言逻辑拆成独立脚本，
> `scripts/test-boot-smoke-assert.sh` 用带 ANSI 的 fixture 离线验证它：
> 正例必须过、反例必须挂。断言串腐化了当场发现，不用烧一轮 CI。

但 QEMU 里没有 RTL8723BS、没有 8250、没有真实 eMMC，所以：

- 第 3 条（Wi-Fi 真连上）、蓝牙、eMMC 掉卡 —— **只能真机验**；
- 第 4 条（时钟）需要真实网络与 NTP —— QEMU 里验不了。

这三项的逐条判据见 `15_实机验收清单.md`（在项目文档目录里）。

---

## 6. 装完之后（可选）

Hermes CLI 与 headless Chrome 由 `qm1-provision.timer` 在开机 60 秒后
拉起 `qm1-provision.service` 安装（需要网络 —— 它等
`network-online.target`，也就是等 wlan0 拿到地址）。

**为什么是 timer 而不是直接挂 multi-user.target**：服务本身要等网络就绪，
而 multi-user.target 会对它 Wants= 的成员隐式补 After= —— 直接挂上去等于
"整机开机必须等网络"，Wi-Fi 一有问题整台机器就到不了 multi-user.target，
表现为没有 SSH、像砖了。改成 timer 之后，机器先正常起来，安装在后台跑。
它只在成功一次之后才会跳过（标记 `/var/lib/qm1/provision-done`），
失败则下次开机自动重试。装完：

```sh
systemctl --user status hermes-gateway     # 常驻网关
curl -s http://127.0.0.1:9222/json/version # headless Chrome 调试端口
ls ~/.local/share/uv/python/*/bin/python3.14   # Hermes 用的解释器
```

内存预算（2 GiB 的机器）：zram 768M + mem=1900M + `/dev/shm` 256M +
`systemd-oomd`；headless Chrome 的用户单元带 `MemoryHigh/MemoryMax`
（350M/450M）。Hermes 网关的单元由官方 CLI 安装
（`hermes gateway install --if-missing`），带的是上游自己的重启与退出码
语义 —— 上游在网关启动时会刷新自己的单元，我们手写的同名单元会被它
改写并互相打架，所以不再手写。

网关常驻的前提是**已经配置好消息平台凭据**：上游网关在没有平台连上
时会自己退出（`Exit 1 if no platform connects`），这是它的设计，不是
故障。凭据由 `hermes setup` 写入，无终端的自动安装不会替你填，首次使用
请手工执行一次：

```sh
hermes setup                              # 选平台、填 token（交互）
systemctl --user restart hermes-gateway
```

---

## 7. 出问题怎么办

| 现象 | 先看 |
|---|---|
| 开机后连不上网 | `qm1-selftest`、`journalctl -u qm1-wifi@wlan0`、`iw dev wlan0 link` |
| Wi-Fi 一直连不上 | `dmesg | grep -i rtw`；确认绑定的是 `rtw88_qm1` 而不是发行版 `r8723bs`（后者有永久卡死路径） |
| 时间是 1970 | `resolvectl status` + `timedatectl`（DNS 没通） |
| 蓝牙没有 hci0 | `journalctl -u qm1-bluetooth`；`/run/qm1-bluetooth.failed` 里有 ACPI 归属线索 |
| eMMC 读写报 "Reset never completed" | `cat /sys/devices/platform/80860F14:00/power/control` 应为 `on`；udev 规则负责开机就关掉自动挂起 |
| 想看硬件事实 | `sudo qm1-hardware-survey --out /root`（只读，收集 DMI/ACPI/DSDT 线索） |
| 安装失败 | 安装器会说明停在哪一步；备份区里的整盘备份可以用 `dd` 还原 |

---

## 8. 这条链路上踩过的坑（供后来人）

按出现顺序，都是"看起来做完了、其实没有"：

1. **菜单项被 awk 吞掉头** → grub.cfg 里一条 `menuentry` 都没有（哑菜单）。
2. **wants 链接指向不存在的 `/lib`** → 「安装到 eMMC」是个空操作。
3. **wpa_supplicant 的 PSK 写法** → 64 位十六进制被当明文口令，认证失败。
4. **写入校验比的是整个分区** → 每次安装都误报"写入失败"。
5. **GRUB 里的卷标写死** → 改了卷标就起不来，而 CI 全绿。
6. **user 单元只写文件不 enable** → 验收命令永远 not found。
7. **构建期把 resolv.conf 换成 stub** → 构建阶段的 apt 全挂。

共同的教训：**做完的事要有一个"从外部看得见"的判据**（能回读、能断言、
能让 CI 验），否则"写了"和"生效了"之间永远隔着一层。
