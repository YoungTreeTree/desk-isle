# 硬件与接线

[返回首页](../README.md) · [使用指南](usage.md) · [固件构建与更新](development.md)

桌屿目前围绕 **OSPTEK ESP32-P4C5 V1.3 + YDP500BT004-V1** 这套组合开发和实测。相同分辨率并不代表其他屏幕可以直接使用；驱动 IC、MIPI 时序、引脚与排线定义都需要匹配。

## 已验证配置

| 项目 | 当前配置 | 依据 |
| --- | --- | --- |
| 开发板 | OSPTEK ESP32-P4C5 V1.3 | 当前实机与驱动适配目标 |
| 主控 | ESP32-P4；已验证实机芯片修订版 **v3.2** | 实机烧录识别；构建配置最低修订版为 v3.1 |
| Flash | **16 MiB** | 实机烧录核验与 [sdkconfig.defaults](../sdkconfig.defaults) |
| PSRAM | **32 MB** | [OSPTEK 核心板规格](https://github.com/osptek/esp32-p4c5-core-board#规格参数)；固件启用 PSRAM 与开机内存检查 |
| 应用分区 | **8 MiB**，起始地址 `0x10000` | [partitions.csv](../partitions.csv)；单 factory 应用分区，未配置双分区 OTA |
| 屏幕 | **5 英寸 TFT，YDP500BT004-V1** | [屏幕原厂资料](https://github.com/osptek/display-tft-5inch-720x1280/tree/main/versions/YDP500BT004-V1) |
| 驱动 IC | **JD9365** | 原厂资料与 [面板初始化代码](../main/display/jd9365_init_cmds.h) |
| 原生分辨率 | **720 × 1280**；横放 **1280 × 720** | [布局定义](../shared/include/layout.h) |
| 显示链路 | **MIPI-DSI，2 Lane，RGB565** | [当前固件配置](../main/display/display.c) |
| 布局网格 | **40 × 40 px**；竖放 18 × 32，横放 32 × 18 | 两端共用布局规则 |
| 背光 | GPIO 20，LEDC PWM；应用内 0–100% 调节 | [背光实现](../main/display/display.c) |

**板卡 V1.3 和芯片 v3.2 是两个不同的版本号。** 板卡版本看 PCB 丝印，芯片修订版由烧录工具识别。修改驱动或启动配置时，应分别核对。

## 需要准备

- 上述开发板、屏幕，以及与屏幕 FPC 定义匹配的转接板和排线。
- 一根支持数据传输的 USB 线。
- macOS 14 或更新版本的 Mac；当前运行验证以 Apple Silicon 为主。

屏幕外形为 **75.20 × 128.49 × 4.0 mm**，有效显示区域为 **61.78 × 109.85 mm**。机壳和安装孔设计请以 [YDP500BT004-V1 原厂 CAD 与规格书](https://github.com/osptek/display-tft-5inch-720x1280/tree/main/versions/YDP500BT004-V1)为准。排线和转接板也应按该型号核对，不能只看针数。

## 一根 USB 线怎么接

| 接口 | 桌屿日常使用 | 固件更新 | 说明 |
| --- | --- | --- | --- |
| **原生 USB 数据口** | 支持布局、组件数据、桌宠事件与图片传输 | 当前仓库的更新流程使用 CH343 | 数据密集的图片／GIF 场景优先使用此口 |
| **CH343 烧录／串口** | 同样支持完整桌屿连接 | **使用这个口** | 运行时采用 3,000,000 baud 的复用协议；烧录由脚本接管 |
| USB-A Host | 不作为 Mac 与桌屿的连接口 | 不用于本项目烧录流程 | 属于板卡其他扩展能力 |

日常使用只需连接前两种接口中的任意一个。两个都接上时，桌屿优先选择原生 USB；拔掉一个后会重新探测可用连接。CH343 连接由桌屿统一调度，MiucsCore 复用同一个连接。

通过 CH343 刷写时，开发板目标选择应为 **ESP32-P4**。以板卡丝印和[原厂调试接口说明](https://github.com/osptek/devboard-esp32p4c5_module#usb-与调试)为准；不要向 ESP32-C5 写入桌屿 P4 固件。

## 当前用到的能力

- **板端绘制**：Codex、佳明、Mac 负载、蓝牙电量与通知岛主要接收数据／事件，在 P4 上绘制。
- **板端桌宠**：Miucs 的 Lua 脚本和资源在连接后上传，P4 执行脚本；Mac 提供键盘和音频事件。
- **图片与 GIF**：Mac 准备资源并上传；新版固件缓存 GIF 帧和时间轴，由 P4 自主循环播放，见 [板端 GIF](pictures.md)。
- **壁纸与布局**：壁纸在连接后同步到板端内存；布局、方向和亮度保存到设备。壁纸不是烧入固件的固定图片。
- **背光联动**：可以随 Mac 锁屏熄灭，解锁后恢复用户亮度。

板卡搭载 ESP32-C5，并具备无线、音频和其他扩展接口，但桌屿当前使用 **USB 通信**，没有实现 Wi-Fi 同步。蓝牙电量组件读取的是 **Mac 已连接的配件**，不使用开发板扫描配件。屏幕原厂资料列有 CHSC5432 触摸驱动，当前桌屿固件尚未接入触摸操作。

## 固件兼容与首次刷机

构建基于 ESP-IDF **v5.5.6**。已验证的 ESP32-P4 v3.2 实机使用本地启动补丁，见 [启动补丁](../esp-idf-v5.5.6-osptek-startup.patch)。

当前 `tools/flash.py` 面向已识别的旧 1 MiB／现有 8 MiB 桌屿分区布局，会先备份再更新。**它不是适用于任意空白开发板的一键初始化工具。** 新板首次刷机需要核对芯片修订版、bootloader、分区表和屏幕接线，具体边界见[开发文档](development.md)与[开源准备清单](open-source-readiness.md)。

## 原厂资料

- [OSPTEK ESP32-P4C5 核心板](https://github.com/osptek/esp32-p4c5-core-board)：主控、存储和核心板引脚。
- [OSPTEK ESP32-P4C5-Module 开发板](https://github.com/osptek/devboard-esp32p4c5_module)：底板、USB 和调试接口。
- [YDP500BT004-V1 屏幕](https://github.com/osptek/display-tft-5inch-720x1280/tree/main/versions/YDP500BT004-V1)：屏幕、转接板、排线、CAD 和规格书。

硬件信息核对日期：2026-11-13。原厂仓库可能覆盖其他批次；桌屿已验证范围以上表为准。
