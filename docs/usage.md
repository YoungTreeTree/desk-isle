# 使用指南

[返回首页](../README.md) · [硬件与接线](hardware.md) · [开发与构建](development.md)

## 多布局模式

「桌面布局」首先显示布局库。每张卡片代表一套完整画面：组件排布、屏幕方向、壁纸、图片／GIF 和桌宠皮肤。点击已有卡片会打开编辑器，并立即切换小屏；离线时记住请求，重连后同步。

- **新建／复制**：进入编辑，点击「应用到小屏」才切换设备。新建布局继承当前方向、使用默认壁纸，组件为空。
- **自动保存**：拖动松手或修改设置后自动存到 Mac；壁纸、图片、皮肤也遵循「应用到小屏」，不会提前改变设备。重启和重连恢复最后一次请求应用的画面，不会擅自应用后来只保存到 Mac 的改动。
- **管理**：卡片右下角菜单可复制、重命名和删除；正在使用或等待同步的布局不能删除，至少保留一套。
- **共用设置**：账号、数据源、亮度、锁屏联动、键盘／音频权限及输入开关在布局间共用。实时通知与用量等运行数据不归档。
- **首次升级**：连接小屏后，现有画面归档为「默认布局」。旧壁纸、图片和偏好设置保留；即使先离线创建了布局，也会先归档设备原画面。
- **同步失败**：布局仍保存在 Mac，可重试。缺失图片或皮肤时先在编辑器修复；设备已显示但保存失败会单独提示。

布局库保存在 `~/Library/Application Support/com.deskisle.layout/Layouts/`，包含版本化清单、上一份有效备份和独立资源。布局库属于本机私人配置，首版不提供导入导出、轮播或多设备管理。缩略图为静态示意，不运行实时组件，也不保存账号指标。

## 安装与启动

构建需要 Swift 6、uv 和 uv 管理的 Python 3.11（`uv python install 3.11`）。`Package.swift` 默认从独立的 Miucs 仓库获取固定提交的 `MiucsCore` 与皮肤资源，不要求同级目录存在 Miucs。联调本地 Miucs 时可设置 `MIUCS_LOCAL_PATH=/path/to/miucs`。将[小米官网](https://hyperos.mi.com/font/zh/download/)的 `MiSans-Regular.ttf` 放到 `build/assets/`，或用 `DESKISLE_MISANS_FONT` 指定文件。字体、佳明依赖、CPython 3.11 运行环境和相关许可证会随应用打包，最终用户不需要安装 Python 或设置开发者机器上的脚本路径。

```sh
zsh tools/build-macos.sh
open build/macos/DeskIsle.app
```

在桌屿主窗口顶部切换「桌面布局」「显示设置」和「插件配置」。「插件配置」左侧选择佳明、Codex、通知岛、Miucs 桌宠、Mac 负载、蓝牙电量或图片，右侧管理各自设置。「显示设置」可即时调整小屏亮度，并设置是否随 Mac 锁屏熄背光。小屏会保存亮度，解锁时恢复到设定值。

### 首次使用与插件配置

新安装会先显示使用向导。连接小屏后可直接添加 Mac 负载、蓝牙电量和图片等本机组件；Codex 与佳明读取默认关闭，桌宠键盘与音频响应也默认关闭。账号配置可以跳过，之后在「插件配置」继续。升级现有安装会迁移已有设置，不强制重新走向导。

「插件配置」集中管理数据源的启用状态、账号与偏好：

- **Codex 用量**：自动发现桌面版或 CLI，也可手动选择程序。高级设置中的 Codex 数据目录同时用于账号读取、本机 Token 统计与通知接入；默认遵循 `CODEX_HOME` 或 `~/.codex`。登录仍在 Codex 内完成，桌屿不保存密码。
- **Codex 通知**：可检查、连接、修复和断开桌屿自己的 Hook。连接前会说明将要修改的配置；安装后仍需在 Codex 中审核并信任。
- **佳明健康**：仅支持佳明中国区，参考 [BorisBW/garmin-mcp-cn](https://github.com/BorisBW/garmin-mcp-cn) 的认证流程。提供登录、按需验证码、检查连接、重新登录与退出账号；登录是否成功以实际中国区服务回执为准。也可在「迁移已有会话」导入旧 MCP 会话。账号密码只通过本机进程管道用于登录，不写入偏好设置、文件或命令行参数。
- **Miucs 桌宠**：设置皮肤、显示开关、键盘响应与系统音频权限。
- **Mac 负载／蓝牙电量**：分别设置采样／刷新间隔，只有布局使用对应组件时才采集。
- **图片与 GIF**：统一导入入口，每张图片的布局和显示方式独立设置。

切换数据源配置会清空之前显示的账号数据，并丢弃旧配置尚未完成的读取结果。配置仅保存开关、路径和会话 ID，存储在应用的 UserDefaults 中；不会把凭据写进布局或同步给开发板。阶段进度和剩余依赖见 [开源准备清单](open-source-readiness.md)。

佳明 OAuth 会话由桌屿保存到 `~/Library/Application Support/com.deskisle.layout/Connections/Garmin/sessions/<随机ID>/session.json`。会话目录权限为 `0700`、文件为 `0600`，偏好设置只保存随机 ID；这是本机私有文件存储，不是钥匙串加密存储。每次取数后原子保存更新的会话。升级时会复制原来的中国区会话，原目录保持不变；退出只清除桌屿的副本。取消登录会销毁候选会话，旧请求不能在退出后重新创建会话。

一根线接原生 USB 数据口或 CH343 烧录口都能连接桌屿。两个口都接上时，优先使用原生 USB。桌屿持有物理连接，内嵌 MiucsCore 通过进程内通道发送桌宠消息，无需另外启动 Miucs。预览中的每格为 40×40 像素，竖放时为 18 列×32 行，横放时为 32 列×18 行。拖动组件并松手即可对齐格线，也可以在右侧填写列和行、选择预设的占格尺寸。

选中 Miucs 桌宠后，可在「占格尺寸」切换小号（14×8 格，512×288 画面）和大号（18×10 格，704×400 画面）。切换时尽量保留桌宠的横向中心和底边，动画在占位中居中。大号需要支持尺寸预设的桌屿固件。

选好尺寸或小屏的摆放方向后，点「应用到小屏」保存。设备重启后会恢复组件的尺寸、位置和屏幕方向。固件读取旧布局时会将组件对齐到最接近的格子并保存。

桌宠与布局共用桌屿进程和设备调度器。自定义组件可先留位置，等待内容接入时会在小屏上显示色块。固件通过独立的布局接口接受其他组件的 JPEG 内容。点击「屏幕预览」旁的「壁纸」可以更换图片或恢复默认壁纸。桌屿按横放和竖放分别裁切图片，在 Mac 上保存选择，连接小屏后自动同步。开发板将解码后的壁纸保存在内存里。布局与内容格式见 [USB 协议](../USB-PROTOCOL.md)。

在「添加」菜单选择「添加佳明健康」。组件占 10×8 格，初始放在左下角，拖到合适位置后点「应用到小屏」。在「插件配置 → 佳明健康」连接账号后，每 10 分钟刷新，日期与时间跟随本机时区。临时读取失败时，应用运行期间保留同一配置下上次的健康数据。

「添加 Codex 用量」会在右下角放置 10×8 格的组件。旧版卡片会在编辑器中调整尺寸并以右下角为锚点，应用布局后保存到小屏。桌屿通过已登录的 `codex app-server` 读取订阅套餐、剩余额度和账号每日 Token 用量，每 3 分钟刷新。如果账号没有当天记录，组件会统计本机从零点开始的会话用量并标注「本机统计」。取数实现沿用 Dboard 的读取规则，参见 [Codex 用量许可](../THIRD_PARTY_LICENSE_CODEX_USAGE.txt)。

### Miucs 桌宠

在「插件配置 → Miucs 桌宠」选择七套内置皮肤、开关桌宠、键盘和系统音频。已有桌屿安装保留先前的 Miucs 设置迁移行为；新安装使用桌屿默认设置，按用户选择申请键盘和音频权限。小屏继续执行 Lua 和绘制，Mac 只上传资源包及输入；不加载桌面 Skia 渲染器或 worker。换肤不重启输入采集，移除/关闭组件会释放订阅与通道；设备断开时暂停采集，连接恢复后按 CRC 复用板端实例。

输入监控和音频权限归「桌屿」应用，需要单独授权。自定义构建优先使用本机已有的 `Miucs Dev` 稳定签名，可用 `DESKISLE_SIGN_IDENTITY` 指定其他签名；没有签名身份时使用临时签名。Swift Package 的资源包随应用复制到 `Contents/Resources`。

### Mac 负载

「Mac 负载」支持 8×4 和 10×6 格，显示 CPU/GPU 利用率、CPU 最高温、整机功耗、内存已用／总量和压力，以及 Miucs、桌屿的进程 CPU；大号另有一分钟趋势。组件存在时约每 4 秒采样一次，内嵌桌宠的 CPU 占用计入桌屿进程，仅发送数值，由开发板绘制。温度当前识别 M4 系列的 CPU 核心传感器，功耗读取 AppleSMC 的 PSTR；没有可用读数时显示「—」。读取无需管理员权限，不调用外部监控进程。

温度传感器映射和 PSTR 含义参考 [Stats 的 SMC 传感器表](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)，已用内存口径参考 [Stats 的内存读取](https://github.com/exelban/stats/blob/master/Modules/RAM/readers.swift)。

### 通知岛

选择「添加 → 添加通知岛」并应用到小屏。通知岛默认位于顶部，横放占 23×7 格，竖放占 12×4 格。旧的横放布局会在编辑器中调整通知岛的尺寸，应用后保存到小屏。关闭主窗口后，桌屿在后台继续接收本地通知。

推荐通过「插件配置 → 通知岛」完成 Codex 接入。应用会将命令复制到 `~/Library/Application Support/com.deskisle.layout/bin/deskisle`，移动应用不会改变 Hook 中的命令路径。已有指向当前应用包的旧命令可通过「连接 / 修复通知」迁移。通知配置仅调整完全匹配的桌屿命令，其他应用的 Hook 会保留。

构建后的命令也位于 `DeskIsle.app/Contents/Helpers/deskisle`。命令行接入方式仍可使用：

```sh
build/macos/DeskIsle.app/Contents/Helpers/deskisle notify \
  --source build --title '构建完成' --body '桌屿 macOS 构建通过' --level success
python3 helpers/notifications/install-codex-notifications.py --app /path/to/DeskIsle.app --codex-home ~/.codex
```

在 Codex CLI 用 `/hooks`，或在桌面版的 Hook 设置里审核并信任桌屿的条目。已打开的 Codex 桌面版可以退出重开，再用本地会话测试。安装脚本会备份已有配置，`--uninstall` 可移除桌屿的条目。通知岛会显示本轮任务和回复的短摘录、已知用时，以及 Hook 提供的审批说明。横屏展开时可同时显示其他运行中或待处理的会话。审批和回复在 Codex 处理。

`deskisle event --stdin` 从标准输入读一个 JSON 对象，成功时返回 `{"status":"accepted","event_id":"…"}`，表示桌屿已接收。事件共有 `version: 1`、`event_id`、`source` 和 `type`，可以附带纯文本 `title`、`body` 和 `project`。

| `type` | 其他字段 |
| --- | --- |
| `notification.post` | 必填 `title`。可选 `level` 为 `info`、`success`、`warning` 或 `error`，`ttl_ms` 为 1000–60000，默认 8000。 |
| `agent.session.opened`、`agent.session.closed` | `session_id`。 |
| `agent.turn.started`、`agent.turn.progress` | `session_id`、`turn_id`。 |
| `agent.attention.requested` | `session_id`、`turn_id`、`request_id`，以及 `request_kind` 为 `approval` 或 `question`。 |
| `agent.attention.resolved` | `session_id`、`turn_id`、`request_id`。 |
| `agent.turn.finished` | `session_id`、`turn_id`，以及 `outcome` 为 `completed`、`failed` 或 `interrupted`。 |
