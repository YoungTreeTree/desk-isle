# 开发、构建与验证

[返回首页](../README.md) · [架构说明](architecture.md) · [硬件与接线](hardware.md)

## 构建 macOS 应用

构建需要 Swift 6、uv 和 uv 管理的 Python 3.11（`uv python install 3.11`）。`Package.swift` 默认从独立的 Miucs 仓库获取固定提交的 `MiucsCore` 与皮肤资源，不要求同级目录存在 Miucs。联调本地 Miucs 时可设置 `MIUCS_LOCAL_PATH=/path/to/miucs`。将[小米官网](https://hyperos.mi.com/font/zh/download/)的 `MiSans-Regular.ttf` 放到 `build/assets/`，或用 `DESKISLE_MISANS_FONT` 指定文件。字体、佳明依赖、CPython 3.11 运行环境和相关许可证会随应用打包，最终用户不需要安装 Python 或设置开发者机器上的脚本路径。

```sh
zsh tools/build-macos.sh
open build/macos/DeskIsle.app
```


## 构建与联调

使用 ESP-IDF **v5.5.6**，组件版本固定于 `dependencies.lock`。在已载入 ESP-IDF 环境的终端里执行。

```sh
idf.py build
```

板端桌宠使用固定版本 Lua 5.4.8，构建时校验并下载源代码。已有解压后的 Lua 源码可通过 `-D FETCHCONTENT_SOURCE_DIR_DESK_LUA=/path/to/lua-5.4.8` 指定。授权见 [Lua 许可证](../THIRD_PARTY_LICENSE_LUA.txt)。

输出为 `build/desk_isle.bin`。默认 [分区表](../partitions.csv) 在 `0x10000` 为应用预留 8 MiB。已有旧 `sdkconfig` 的工作树需要在 ESP-IDF 的 Partition Table 设置中选择 Custom partition table CSV，使用 `partitions.csv`。

已验证的 ESP32-P4 芯片 v3.2 实机使用带有本地启动补丁的 bootloader（见 [补丁](../esp-idf-v5.5.6-osptek-startup.patch)）。从旧 1 MiB 布局迁移时，通过 CH343 口运行下面的命令。脚本会核对 16 MiB Flash 并备份分区表、固件和 NVS，再写入分区表和应用。

```sh
python3 tools/flash.py --port /dev/cu.YOUR_CH343_PORT \
  --partition-table build/partition_table/partition-table.bin
```

后续更新应用时可省略 `--partition-table`。烧录脚本会临时接管 CH343，烧录结束后桌屿自动连接。脚本需要 esptool，备份及 SHA-256 位于 `build/hardware-backups/`。恢复迁移前的状态时，可把备份里的分区表和应用分别写回 `0x8000` 和 `0x10000`。

把线接到原生 USB 数据口后，用已安装 pyserial 的 Python 环境发送符合握手尺寸的 baseline JPEG。

```sh
python3 tools/send_card.py --port /dev/cu.YOUR_DESKISLE_PORT card.jpg
```

在动画接口上可传多张图片和 `--count 120` 来循环传帧。独立 Miucs macOS 版仍可通过「设置 → 硬件屏幕」连接动画接口；桌屿日常使用内嵌 MiucsCore，无需启动独立 Miucs。

## 验证

```sh
swift test
python3 tests/test_connections.py
python3 tests/test_protocol.py
# 以下绘制测试需先载入 ESP-IDF 环境
python3 tests/test_widgets.py
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I shared/include shared/layout.c tests/layout_test.c -o build/layout-test
build/layout-test
```

离线测试覆盖 USB 分片、CRC、超限、保活，以及不同尺寸组件的布局编码、裁剪、叠放和四个方向的像素映射。

面板初始化及其时序来自 [OSPTEK 示例](https://github.com/osptek/display-tft-5inch-720x1280)，沿用 [CC BY 4.0 许可](../OSPTEK-LICENSE.txt)。
