# ZELUX Device Image

当前跨仓库完成状态、未完成内容和恢复开发入口见 [项目阶段状态](docs/PROJECT_STATUS.md)。

ZELUX 设备镜像、增量安装、首启服务和烧写工具。本仓库不再拥有 Studio、Agent
或驱动源代码；正式构建应按 `components.lock.yaml` 下载并校验各组件 Release。

## 组件装配

### 开发环境组件

先装配独立 Agent、Studio 和 Drivers 组件：

```powershell
powershell -ExecutionPolicy Bypass -File tools/assemble-components.ps1 -RobotdReleaseDir C:/artifacts/robotd -RobotdManifestSha256 <可信清单哈希>
```

Linux/WSL：

```bash
ROBOTD_RELEASE_DIR=/artifacts/robotd ROBOTD_MANIFEST_SHA256=<可信清单哈希> bash tools/assemble-components.sh
```

### Robotd 运动服务

装配独立 zelux-robotd 发布产物（robotd + robotctl + service + 运行依赖）：

```bash
# 单独装配已解包、包含依赖及清单的发布交付目录（不能是源码目录）
python tools/robotd_component.py assemble --source /artifacts/robotd --manifest-sha256 <可信清单哈希> --output components/robotd --lock components.lock.yaml
```

详见 [Robotd 集成指南](docs/robotd-integration.md)。

当前已锁定真实 ARM64 交付 `0.15.0+build.20261121.5b9bde6`，包含 robotd、robotctl 和 ONNX Runtime 1.28.0。默认打包/安装拒绝缺失或未锁定的 robotd，不再静默生成不完整交付。装配完成后更新 components 中的 lock 副本。构建产物、哈希和验证边界见 [2026-11-21 构建记录](docs/robotd-build-20261121.md)。

## 镜像构建

```bash
# 完整镜像构建
sudo ./build-image.sh --base /path/base.img.xz

# 基于 Armbian 构建
sudo ./build-from-armbian.sh
```

构建脚本默认只读取本仓库的 `components/software`；CI 可通过
`ZELUX_COMPONENT_ROOT` 指向下载并校验后的 Release 解包目录。

## 增量安装

```bash
# 从当前仓库安装/升级（幂等，可以反复跑）
sudo ./install.sh

# 打离线包
./install.sh --pack

# 离线安装
sudo ./install.sh --offline zelux-duck-<ver>-arm64.tar.gz

# 回滚
sudo ./install.sh --rollback-last
```
