## 2026-11-22 舵机维护配套更新

组件锁已升级到 robotd 0.15.0+servo.v38.20261122 与 drivers 1.4.0。构建时必须使用新 ARM 候选包及锁定清单哈希，不得沿用 API v37 包。配套当前 Agent/Studio 后，固定支撑确认可以进入未归位维护，不会自动归位或改变扭矩。当前候选包在 zelux-robotd/target/servo-v38-20261122/，构建与测试记录在 zelux-robotd/docs/test-results/servo-session-v38-20261122/。尚未部署或进行本次真机验收。

# robotd 独立发布、统一交付

2026-11-21。源码和编译仍归 zelux-robotd；本仓库只消费已构建产物，不编译源码、不调用上游网络/provision/install hook。

## 发布交付目录契约

提供已解包的交付目录，必须包括：

```
bin/robotd                     ARM64 ELF
bin/robotctl                   ARM64 ELF
lib/libonnxruntime.so           ARM64 ELF 实体文件
lib/<额外动态依赖>              ARM64 ELF 实体文件
systemd/robotd.service          原生 current/bin/robotd、Group=robot
config/robotd.toml              经过板卡/协议选择的初装默认配置
robotd-component.json           全目录文件哈希、版本、来源、revision
```

本入口接收目录而非任意压缩包，不自行解包不可信 tar 或执行 hook；交付目录不允许符号链接，发布方在 staging 时须将 ONNX soname 链接实体化，且包含所需别名文件。原生 xtask tar.zst 只有其包含的文件，不保证携带 ONNX、默认配置；不能直接冒充此完整交付目录。需由 robotd 发布流水线合入依赖与配置后交付。额外辅助进程/模型可随交付扩展，但本轮仅安装 robotd.service，不接管整套上游 updater/network 服务。

发布侧准备已构建目录后可用以下命令生成内容清单（示例占位符需换真实值）：

```sh
python tools/robotd_component.py seal --source /artifacts/robotd --version <robotd版本> --source-revision <构建提交> --origin <发布来源> --lock components.lock.yaml
```

该命令输出清单 SHA-256。seal 是发布方生成清单的步骤，不是对未知下载物的身份认证；消费者必须从可信渠道取得该哈希，而非对任意设备现存文件重新计算后绕过校验。

完整组件装配见 README 的 PowerShell/Bash 入口；或单独运行：

```sh
python tools/robotd_component.py assemble --source /artifacts/robotd --manifest-sha256 <可信哈希> --output components/robotd --lock components.lock.yaml
```

装配输出必须尚不存在，不递归删除已有产物。单独装配后将仓库 lock 复制到 components/components.lock.yaml；完整装配脚本自动完成。版本/hash 自动取真实清单，不使用镜像版本冒充 robotd 版本。pending 表示没有实际产物，默认打包及安装将拒绝。

## 安装与安全边界

增量安装、离线包、两条镜像构建路径均调用相同工具。校验 manifest pin、逐文件 hash、ELF 架构、服务布局；安装时用 readelf 检查动态 NEEDED 依赖在目标 root 或随包 lib 中存在。构建主机/设备安装环境需 Python3、binutils/readelf。此检查不证明 glibc 符号版本或 ONNX API 兼容，仍须 ARM64 构建/运行验收。

路径为 /opt/robot/daemon/releases/<robotd版本>/bin、lib、systemd、config，current 原子切换，旧 release 保留。拒绝同版本不同内容。原生布局支持继续独立升级；独立升级的新 release 也须携带 lib，或同步管理 runtime drop-in。/etc/robot/robotd.toml 已存在就保留，不强改飞特/IMU配置；初装使用交付目录审核过的默认配置。安装 robotctl 命令包装器，服务和命令显式设置 ONNX 路径与 LD_LIBRARY_PATH。

只安装服务，不自动 enable/start robotd、不发运动指令。增量安装发现 robotd 在运行会拒绝，用户须先安全停机再停止服务。创建 robot sysusers 声明，设备重启由 systemd-sysusers 建组；现有增量流程也创建 robot 组。确认依赖、接线、协议、IMU IPC、急停策略后，再由操作者决定 enable/start。Armbian 镜像构建不再把新 robotd 服务加入旧服务屏蔽列表。

增量安装将 current、service、runtime drop-in、robotctl 包装器、sysusers 声明、初装配置纳入原有文件备份清单；旧发布目录保留供回退。机器人服务不自动重启，回滚后也须人工审查再启动。完整断电事务、配置/发布同步回滚及独立 updater 与整机更新协调并未在此实现。

同时修复 PWM 清单安装根目录参数：此前传 /usr 导致 /usr/usr/share，现传 / 生成正确的 /usr/share/zelux/pwm-overlays.sha256。

## 本轮验证与待办

已从独立 robotd 源码提交交叉构建真实 ARM64 交付，锁定版本及清单；整合离线包也已生成，详见 [构建记录](robotd-build-20261121.md)。测试 fixture 使用假 ELF 检查拒绝路径，实际产物另经 QEMU 验证，不混同两类证据。

Linux unittest 共 23 项，21 通过、2 项因缺少真实 dtc 跳过，包含临时 root 安装和保留配置测试。Windows 原生 Python 缺少 grp，不能直接运行完整 Linux 测试集；完整结果以 Linux 为准。发布 lock 校验及 diff 检查通过。真实 ARM64 二进制帮助/版本及 ONNX 动态加载/API23 探针通过，目标运行根目录的 NEEDED 依赖存在性检查通过。尚未构建完整磁盘镜像，也未进行目标机器人启动、真实策略推理、整机回滚或重启恢复测试。
