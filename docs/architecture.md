# 项目结构与组件开发

桌屿是一个双端仓库：macOS 负责配置、采集和同步，ESP32-P4 负责屏幕合成与原生组件绘制。MiucsCore 保留独立仓库，通过固定提交的 Swift Package 引入。根目录的 `Package.swift` 和 `CMakeLists.txt` 分别是两端构建入口。

| 目录 | 职责 |
| --- | --- |
| `macos/App` | 应用生命周期、窗口与页面导航 |
| `macos/LayoutEditor` | 草稿与已应用布局、用户操作、设备布局同步、壁纸导入和预览 |
| `macos/Device` | USB／UART 连接、串行请求、协议封装及内容去重 |
| `macos/Settings` | 首次使用、配置持久化、显示设置和插件配置入口 |
| `macos/Widgets/<组件>` | 组件注册、数据来源、刷新实现、预览和专属配置 |
| `macos/UI` | 通用样式与视图 |
| `macos/Native` | macOS 专属串口及传感器 C 接口 |
| `shared` | 两端共同编译的布局、旋转和磨砂算法；不依赖 AppKit 或 ESP-IDF |
| `main/transport` | 固件消息解析、USB／UART 接收与任务调度 |
| `main/display` | 面板驱动、背光和画面合成 |
| `main/layout` | 固件布局持久化与控制 |
| `main/widgets` | 组件注册、状态与字形管理，以及各组件独立绘制实现 |
| `main/pet` | Lua 桌宠运行时及场景绘制 |
| `helpers` | 随应用打包运行的通知 CLI、Hook 安装器及佳明 Python 程序 |
| `resources` | 默认壁纸和板端字形资源，授权边界见根目录 README |
| `tools` | 开发者使用的构建、烧录、资源生成与运行环境打包工具 |
| `tests` | Swift、Python 和本机 C 回归测试；不读真实账号或操作开发板 |

## 运行职责

`LayoutEditor` 管理草稿与设备已应用布局，两者保持分离。拖动、尺寸、叠放和方向修改只影响草稿；应用成功后才更新已应用布局。设备轮询和应用流程在 `LayoutEditor+Device`，文件选择与导入在 `LayoutEditor+Assets`，预览视图独立成文件。

`WidgetRuntime` 持有各数据源和通知状态，通过注册表调度组件刷新、编码与发送。每个组件的刷新实现与注册信息放在同一功能目录。`PictureRuntime` 管理图片缓存、加载和动画播放。两个运行管理器通过弱引用读取当前布局上下文，不持有编辑器；编辑器转发实际状态变化供界面观察。关闭预览不停止通知或板端组件，也不会新增预览刷新定时器。

数据刷新周期、配置键、账号会话路径、设备协议和固件存储格式不因目录迁移而变化。共用 `LayoutUSB` 的设备请求仍通过同一个 actor 调度。

## 增加内置组件

1. 在 `macos/Widgets/<组件>` 实现数据来源、预览与载荷，并定义 `WidgetDefinition`：固定协议 ID、名称／图标、默认尺寸、兼容尺寸、可选尺寸、放置策略、最低固件组件版本、刷新和发送回调。
2. 在 `BuiltInPlugin` 加入类型，将定义加入 `WidgetRegistry.all`；需要显示在添加菜单时加入 `menu`。插件配置侧栏自动读取注册信息，专属配置页面仍显式接入 `ConnectionSettingsView`。
3. 在 `main/widgets` 添加对应绘制文件，并在 `widget.c` 的 `definitions` 表登记 ID、兼容尺寸和绘制函数，在 CMake 源文件列表中加入实现。增加尺寸／协议兼容测试。

默认尺寸、兼容尺寸与可选尺寸是三个不同的概念：例如 Codex 的历史尺寸仍可以识别并迁移，但不因此在编辑器中增加新的尺寸选项。桌宠占格尺寸与实际内容像素也分别保存。

注册表用于内置组件，尚不提供动态插件安装或第三方代码加载。新增组件必须与固件约定稳定的 ID 和载荷版本；未知组件仍按原有占位组件处理。

## 构建与验证

- `swift test`：配置、会话、组件注册、运行状态隔离，以及 290 组重构前布局结果。
- `python3 tests/test_connections.py`：通知安装／迁移和佳明中国区认证模拟。
- `python3 tests/test_protocol.py`：USB／UART 分片、校验、消息边界。
- `python3 tests/test_widgets.py`：需先载入 ESP-IDF 环境，从其中获取 cJSON 源码；比较 100 帧板端绘制基准，启用 ASan／UBSan。
- `clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I shared/include shared/layout.c tests/layout_test.c -o build/layout-test && build/layout-test`：共用 C 布局实现。
- `zsh tools/build-macos.sh`、`idf.py build`：完整应用打包和固件构建。

打包脚本保持应用内资源名称、Helper 名称和 Bundle ID 不变。移动源码目录不要求用户重新登录、重设权限或迁移配置。构建产物和本机审计备份都放在被忽略的 `build/`。
