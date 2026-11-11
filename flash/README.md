# 烧写指南（工具篇）

> 面向"手上有一张卡 + 一块 Radxa Zero 3W"的人。想先看整机怎么用，看 [`docs/03-烧写指南.md`](../../docs/03-烧写指南.md)。

三个脚本一套流程，别混用：

| 系统 | 脚本 | 做法 |
|---|---|---|
| Windows | `flash-windows.ps1` | 有 Etcher/Rufus 就调它们（帮你校验 sha256）；没有就自己 raw 写盘（带进度 + 回读校验） |
| Linux | `flash-linux.sh` | `dd` + 进度 + 回读 sha256 |
| macOS | `flash-macos.sh` | 选盘 + `diskutil unmountDisk`，其余复用 `flash-linux.sh`（内部走 `/dev/rdiskN`） |

**三个脚本都不会格式化任何东西，也不需要你手动格式化。**
Windows 弹「需要格式化才能使用」时点**取消**——它只是不认识 Linux 分区。

---

## 1. 先搞清楚你要写到哪

Radxa Zero 3W 的存储有几种可能，别写错地方：

| 介质 | 是什么 | 怎么烧 | 注意 |
|---|---|---|---|
| **microSD 卡** | 最常见。整机系统都在这 | 本目录的脚本 / Etcher | 拔卡插读卡器；板子断电 |
| **eMMC**（部分版本/3E） | 板载存储，比 SD 快且不掉卡 | ⚠ 不能用读卡器，只能**板子上跑**：USB 连电脑进 maskrom，用 `rkdeveloptool`/`rkflashtool` 写，或先在 SD 上启动系统再 `dd` 到 `/dev/mmcblk0` | 写 eMMC 会覆盖板载系统，操作前先备份 |
| **SPI NOR Flash**（16 MB 级） | 只放 **bootloader**，不放系统 | `rkdeveloptool db/wl` 写 `*spi*.img` | 一般不用动；只有"SD 卡明明烧好了却起不来"才考虑 |

判断你手上是哪种：插上卡、上电、接 HDMI 看 U-Boot 打印，或进系统后 `lsblk`：

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
# mmcblk1     29.7G  disk        <- SD 卡（有 p1/p2）
# mmcblk0     14.6G  disk        <- eMMC（如果板子有）
```

**第一次做，优先用 SD 卡**：写坏了换一张就行，不会把板子搞成砖。

---

## 2. 卡怎么选（这条最容易省钱省出问题）

- **容量 ≥ 16 GB**。镜像解压后约 4 GB，首启要装依赖、留模型和照片，8 GB 会很紧张。
- **速度等级 A2 / U3**（不是"Class 10"就够）。随机写差的小卡表现是：开机 5 分钟、pip 装依赖卡死、网页一卡一卡。
- **买正品**。扩容卡（标 64 GB 实际 8 GB）的症状是：烧写成功、开机一半文件系统只读。
- 不建议用"送的那张卡"。一张 32 GB A2 卡的钱，比排查三天"为什么开不了机"便宜。

---

## 3. Windows

```powershell
# 1) 先列盘（不会写任何东西）
.\flash-windows.ps1 -Image .\zelux-duck-1.0.0-zero3w.img.xz -ListOnly

# 2) 正式烧（自动选 Etcher / Rufus / raw）
.\flash-windows.ps1 -Image .\zelux-duck-1.0.0-zero3w.img.xz

# 3) 指定盘 + 自己 raw 写（需要管理员 PowerShell）
.\flash-windows.ps1 -Image D:\img\zelux.img -Drive 2 -Method raw
```

- `.img.xz` 用 **Etcher** 最省事（它直接认 xz，而且自带写后校验）。
- `-Method raw` 只吃 `.img`：Windows 没有内置 xz 解压，先 7-Zip 解压或用 WSL `xz -dk`。
- 脚本会先算镜像 sha256（有 `.sha256` 就对比），再让你**输入磁盘号确认**，然后才动盘。

## 4. Linux

```bash
# 看有哪些盘（不要选到系统盘）
lsblk -dno NAME,SIZE,TYPE,TRAN,MODEL

sudo ./flash-linux.sh zelux-duck-1.0.0-zero3w.img.xz            # 交互
sudo ./flash-linux.sh zelux-duck-1.0.0-zero3w.img.xz /dev/sdb   # 指定
sudo ./flash-linux.sh img.xz /dev/sdb --no-verify                # 跳过回读（不推荐）
```

脚本会拒绝：非块设备、已挂载的设备、系统盘、容量不够的卡。写完后会把整盘读回来算 sha256。

## 5. macOS

```bash
diskutil list external physical        # 先看清楚是 disk4 还是 disk5
sudo ./flash-macos.sh zelux-duck-1.0.0-zero3w.img.xz
```

内部用 `/dev/rdiskN`（裸设备），比 `/dev/diskN` 快 5–10 倍；写完同样回读校验。

---

## 6. 第一次开机：等 2–3 分钟是正常的

上电后**不要**因为"网页打不开"就拔电。首启在做四件事：

1. `growpart` + `resize2fs` 把根分区撑满整张卡（32 GB 卡约 10–40 秒）
2. 装 Python 依赖（没有预置 wheel 时要联网，1–2 分钟）
3. 写 hostname / 初始口令
4. 等 30 秒看有没有已知 WiFi，没有就开热点 `ZELUX-Duck`

判断"它还活着"的土办法：

- 板子上的电源灯**常亮**（闪一下灭 = 供电不足，换 5V/3A 电源和粗一点的线）
- 卡上的活动灯在闪（说明在写盘，不是死机）
- 接 HDMI 能看到 `[ZELUX]` 开头的提示行

> LED 的具体颜色/闪烁模式以 Radxa 官方文档和你的板子丝印为准，本仓库不做假设。

超过 **5 分钟**还没反应，跳第 8 节。

---

## 7. 怎么找回 IP

按顺序试，哪条通用哪条：

1. **热点兜底（最省事）**：手机搜 WiFi `ZELUX-Duck`，密码 `zeluxduck`，连上后开 `http://192.168.4.1:8000`。
2. **路由器后台**：找主机名 `zelux-duck` 的设备。
3. **同一个局域网里扫**（电脑上跑）：
   ```bash
   # Linux / macOS：先看本机 ARP 表里有哪些新面孔，再逐个试 8000 端口
   arp -a
   for ip in 192.168.1.{2..254}; do
     (curl -fsS --max-time 1 "http://$ip:8000/" >/dev/null 2>&1 && echo "找到：$ip") &
   done; wait
   ```
   Windows：`arp -a`，或 `ping zelux-duck.local`（装了 Bonjour 才行）。
4. **HDMI 直接看**：首启完成时屏幕上会打印 `http://<ip>:8000`。
5. **串口**：⚠ 本镜像把 `/dev/ttyS2` 让给了舵机总线，串口控制台默认关闭。要救砖才临时改回来（见 `docs/02-硬件接线.md`）。

拿到 IP 后：浏览器打开 `http://<ip>:8000`，默认口令 `zelux`，**登录后第一件事是改口令**。

---

## 8. 常见故障对照表

| 现象 | 最可能的原因 | 怎么办 |
|---|---|---|
| 插电没任何反应，灯不亮 | 供电不足 / 线太细 | 换 5V/3A 电源，用能传数据的 Type-C 线 |
| 灯亮，但 5 分钟没热点也没 IP | 卡没烧好 / 卡是扩容卡 | 重烧并看 sha256；换正品 A2 卡 |
| Etcher 报 "source and target are the same" | 选成镜像本身了 | 重新选目标盘 |
| Windows 提示格式化 | 正常现象（它不认 ext4） | **点取消**，别格式化 |
| 烧完开机进 U-Boot 循环 | bootloader 在 SPI 上但 SD 启动顺序不对 | 见第 1 节 SPI 那行；或 `rkdeveloptool` 重写 SPI |
| 网页能开，但风扇不转 | PWM 通道号（chip/channel）还没实测 | `sudo fanctl --status` 看 `why`，按 `docs/02` 的 TODO 改 `/etc/zelux/zelux.toml` |
| 网页能开，ToF 显示 unsupported | 缺 `vl53l5cx-ctypes` | `sudo zelux-tof-install --install`（没网就 `--offline`） |
| 卡写进去后容量还是 4 GB | 首启扩容没跑完 | 等 1 分钟；或 `sudo zelux-firstboot` 手工跑一次（先删 `/var/lib/zelux/.initialized`） |

---

## 9. 校验与自检命令（出问题时先跑这三条）

```bash
# 镜像本身有没有坏（下载后、烧写前）
xz -t zelux-duck-1.0.0-zero3w.img.xz
sha256sum -c zelux-duck-1.0.0-zero3w.img.xz.sha256

# 板子上：服务活没活
systemctl status zeluxd zelux-fand --no-pager
journalctl -u zeluxd -n 50 --no-pager

# 板子上：网络和硬件
zelux-wifi status
fanctl --status
zelux-tof-install        # 默认就是诊断模式
```
