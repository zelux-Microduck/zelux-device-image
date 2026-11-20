# Studio 风扇 PWM 首次启用：实现状态与硬件验收

## 配置助手 /boot 只读的现场兼容修复

2026-11-20 现场证据：主机 `findmnt -T /boot/armbianEnv.txt` 为根分区 rw；配置助手 namespace 中 /boot 为 ro。daemon-reload + restart 后仍重复，排除仅旧进程残留。现场 unit 已包含 ReadWritePaths=/boot。尚未确定为何目标 systemd/kernel 没有按预期开放例外，不能归因为磁盘故障或宣称已确认某个 systemd 缺陷。

兼容方案仅调整 zelux-pwm-setupd：ProtectSystem=no，显式 ReadOnlyPaths=/usr /etc -/efi，保留 ReadWritePaths=/boot /run/zelux /var/lib/zelux-pwm-setup，以及 ProtectHome、PrivateTmp、NoNewPrivileges、capability allowlist。不关闭所有沙箱、不授予 CAP_SYS_ADMIN、不执行全局 remount。该方案避免隐式 /boot 只读规则，同时保留其他原 ProtectSystem=full 系统目录的只读保护。

可随 device-image 安装此 unit 后 daemon-reload/restart，或现场通过 `systemctl edit zelux-pwm-setupd.service` 添加相同三项配置。现场 drop-in 后续需与主 unit 一起管理。重启 helper 后用 nsenter + findmnt 验证 /boot 为 rw，并确认 /usr、/etc 仍为 ro；重新预览取得新 token，确认保存成功后才重启设备使 overlay 生效。若仍只读，不继续放宽权限，检查完整 namespace/mount 配置。当前仅本地静态 unit 回归与 helper 文件测试通过（17 项，2 项 dtc 环境测试跳过），不代表 Linux namespace 现场验证已完成。

## 2026-11-20 板卡识别修复

现场反馈 Studio 提示未识别 3W，无法选择 PWM 引脚。代码原先只匹配 model 中的 `radxa zero 3w`，但 Armbian linux-rockchip 的 `rk3566-radxa-zero3.dts` 与 `rk3566-radxa-zero3-ap6212.dts` 均使用 `Radxa ZERO 3`；根 compatible 分别为 `radxa,zero3-aic8800ds2` / `radxa,zero3`，并包含 `rockchip,rk3566`。已核对上游 rk-6.1-rkr5.1 分支源码；尚未读取用户设备的实际 model/compatible，因此这是已证实的软件兼容缺口，不等于已确认现场 DT 身份。

setup helper 与 fanctl 现在统一使用明确 compatible allowlist + RK3566 校验，兼容旧 Armbian 命名和 `radxa,zero-3w`。明确的 Zero 3E 身份优先拒绝；未知 compatible、仅有 SoC 标识或缺少身份的通用 `Radxa ZERO 3` 不放行。compatible 缺失时只接受明确的 3W model。错误返回实际 model/compatible，便于进一步诊断。控制器、pinmux、overlay 和启动链校验不变。

本修复需更新设备端 `zelux-pwm-setupd` 和 `fanctl`，重启 `zelux-pwm-setupd.service`、`zelux-fand.service` 后刷新 Studio；只更新网页不能修复后端识别。识别通过但尚未启用 overlay 时应显示待配置，而非直接 ready。已有待重启 overlay 配置仍需重启设备才生效。本轮不修改设备、不自动重启、不更改风扇 inventory。

验证：device-image 16 项（14 通过，2 项真实 dtc 测试因本轮环境无 PATH 中编译器跳过）；fanctl 51 项通过。回归包括旧 Armbian 双 Wi-Fi 变体、上游命名、3E/未知板卡拒绝、helper 引脚列表与 runtime 映射。真机部署后仍须确认型号识别和 PWM 输出。

更新时间：2026-11-20。本文件此前记录的“只读探测、尚无 overlay helper”是历史状态，已由当前实现推进；仍未在目标设备部署或验证。

## 已实现的软件路径

- device-image 提供 Radxa Zero 3 PWM12-M1 pin21、PWM13-M1 pin24 的受信 overlay source、构建脚本与 SHA-256 manifest。
- root-only zelux-pwm-setupd 使用固定 profile 和 pin ID，检查板卡、Armbian overlay hook、kernel family、DT symbol、运行 pinctrl phandle、PWM 控制器；提供状态、预览、一次性 token 确认应用和回滚。它不触碰 PWM runtime。
- 启动链只允许已识别的 Armbian boot.scr/user_overlays + overlay-user 流程；若发现 extlinux fdtoverlays 或 boot.cmd 不包含用户 overlay hook，helper fail closed，不会写可能未生效的 armbianEnv.txt。Radxa U-Boot/extlinux 要采用独立配置实现后才能开放。
- Device Agent 通过 zelux-device-drivers adapter 访问 setup socket。Studio 逐 pin 显示状态，支持预览 diff、二次确认应用、重启提示及重启后刷新；创建/更新/启用前由 Agent 再校验 ready 与 chip/channel。
- fanctl 保持唯一 PWM/FG runtime owner：通道按需 export，owner ledger 跨服务进程重启记录归属；禁用/删除/失败回滚只 unexport 自己登记的 PWM，不释放用户预先 export 的资源。重复占用由 inventory 拒绝。
- setup readiness 表示 controller + pinmux ready，不再把 export 作为 ready 条件；export 是 fanctl 实例生命周期动作。

## 尚未证明的现场条件

目标设备以前曾报告 Armbian 26.8.1 trixie、Linux 6.1.115-vendor-rk35xx，并观测到 fe700010.pwm controller，但该信息不证明 Armbian boot.scr 是实际启动链，也不证明 pin21/pin24 所映射控制器/通道、overlay 实际加载或 PWM 电气输出正确。profile 未识别、DT symbol 缺失、启动配置重复、overlay manifest 校验失败、检测到 extlinux overlay 加载时必须 fail closed。

Studio 不会远程重启。应用启动配置后用户需重启；回来刷新状态，只有运行设备树中预期 pinctrl phandle、controller 和通道数通过检查才允许创建。人工回滚仍需显式确认；变更前备份保存在 /var/lib/zelux-pwm-setup/。

## 测试与发布门槛

自动测试覆盖 setup helper 的启动档案冲突检查、预览/token/备份/回滚/重启 ID 验证/重复启动项拒绝、离线包包含 overlay 编译器及两份可信 DTS 源码、Agent 创建/更新/重新启用门控、fanctl PWM export ownership、Studio DOM 向导。全量镜像构建环境需要 `dtc`；直接/离线增量安装会在识别到 `/boot/armbianEnv.txt` 时检查 `dtc` 并编译 overlay，同时安装 SHA-256 manifest。CI 已安装 `device-tree-compiler` 并执行真实 DTS 编译测试；当前本地 Windows 环境无 `dtc`，该测试在本机跳过，而构建脚本产物与 manifest 的 smoke test 使用模拟编译器通过。目标 Armbian 的 U-Boot overlay hook 与部署路径仍须设备侧确认。

本地 fake sysfs/虚拟文件测试不证明真机板卡映射、pinmux 电气复用、周期/极性/频率或风扇 FG。设备侧验收应覆盖：部署包已有 dtbo；状态首次为 overlay_required；预览只改目标 user_overlays 行并保留其他内容；应用产生备份；重启后状态变为 runtime_available；创建风扇后 fanctl export；删除/禁用释放归属通道；用户预先 export 的通道保持导出；异常时能回滚且不重复创建实例。
