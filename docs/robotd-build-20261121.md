# Robotd ARM64 构建与统一交付记录

日期：2026-11-21。仅使用用户提供的 Linux 编译机编译、打包、执行无硬件仿真检查；未部署到机器人，未启动 robotd 服务，未发送运动指令。

## 产物

- 独立交付：`out/robotd-20261121/zelux-robotd-0.15.0+build.20261121.5b9bde6-arm64.tar.gz`
- 统一离线包：`out/delivery-20261121/zelux-duck-1.0.0-arm64.tar.gz`
- 解包组件：`out/components-20261121/`
- 编译日志：`out/robotd-20261121/build.log`

这些目录被 Git 忽略，不作为源码提交。统一离线包不是可刷写的完整磁盘镜像。发布后须把包和校验值一同存入正式制品库。

| 对象 | SHA-256 |
| --- | --- |
| 独立 robotd tar.gz | `10c37deedba77ffa10e689c7921afdf8b5800bbe0b66c8e3529b9c108386170f` |
| robotd-component.json | `2efa9633c05bd3aa97b5fce3d996875429752971b9f5901d019ead97f2362450` |
| 统一离线 tar.gz | `f34f175b282338084b326f6e571a37dd93ff5df542059e10e4568b2dd68a3aee` |

## 独立构建来源

robotd 源码来自 `zelux-robotd` 提交 `5b9bde68234a66dd31dc0e3a1952615caca7c218` 的 Git archive，不混入工作区未提交文件。版本为 `0.15.0`，交付版本加构建元数据 `+build.20261121.5b9bde6`。源码归属仍在 robotd 仓库，镜像仓库只装配发布结果。

编译入口为 `tools/build-robotd-binaries.sh`，使用 cargo-zigbuild、ARM64 glibc 2.31 target、`--locked`，独立 target 目录。`tools/package-robotd-release.py` 组合已构建二进制、原生 service、审核配置、运行库、许可证和来源清单。清单记录源码提交；不以程序内置版本输出证明提交号。

ONNX Runtime 来自官方 PyPI `onnxruntime 1.28.0` ARM64 cp311 manylinux wheel，SHA-256 为 `8d66f9ceb29909c70839e4e4fb3435c7b490050d8f162bd5f3aba4ca01ee517f`。仅提取原生库和许可声明，不要求设备安装 Python wheel。精确下载来源保存在交付目录 `onnxruntime-provenance.json`。

初装配置为 `profiles/robotd/radxa-zero3w-feetech-qingmu-a1.toml`：串口 `/dev/ttyS2`、飞特协议、qingmu-a1。它是本机器人专用配置，不是所有机器的通用默认；现有 `/etc/robot/robotd.toml` 保留。

## 验证及边界

- 两个真实二进制均为 ARM64 ELF，QEMU 中 `robotd --help`、`robotctl --version` 成功。
- ARM64 原生探针成功 dlopen 随包 ONNX Runtime，输出 `ONNX Runtime 1.28.0; C API 23 available`；出现 QEMU CPU vendor 警告，但进程退出 0。
- 在独立下载、逐包 SHA 校验的 Debian trixie ARM64 运行根目录上，NEEDED 动态依赖存在性检查通过。下载和解包不修改编译机系统软件。
- Linux 回归 23 项：21 通过，2 项缺少真实 dtc 跳过；包括离线包、配置保留、哈希拒绝、架构拒绝、缺依赖拒绝、PWM 配置回归。
- 统一离线包归档中已检查存在 robotd、robotctl、ONNX 库、配置、service、组件清单和 lock。

以上不证明真实设备所有 ABI、策略模型或硬件行为。统一测试仍应覆盖：安全停机后安装、旧配置保留、依赖加载、IMU 状态、Studio 调用 robotctl、服务重启与回退；运动测试需操作者另行确认安全条件。本轮不自动 enable/start robotd。
