# ZELUX Device Image

当前跨仓库完成状态、未完成内容和恢复开发入口见 [项目阶段状态](docs/PROJECT_STATUS.md)。

ZELUX 设备镜像、增量安装、首启服务和烧写工具。本仓库不再拥有 Studio、Agent
或驱动源代码；正式构建应按 `components.lock.yaml` 下载并校验各组件 Release。

开发环境先装配独立 Agent、Studio 和 Drivers 组件：

```powershell
powershell -ExecutionPolicy Bypass -File tools/assemble-components.ps1
```

Linux/WSL：

```bash
./tools/assemble-components.sh
sudo ./build-image.sh --base /path/base.img.xz
```

构建脚本默认只读取本仓库的 `components/software`；CI 可通过
`ZELUX_COMPONENT_ROOT` 指向下载并校验后的 Release 解包目录。
