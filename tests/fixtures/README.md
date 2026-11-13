# 重构兼容性基准

这些期望值由重构前的实现生成，不能随新实现自动更新。

- `layout-compatibility.json`：290 组方向、拖拽边界、尺寸切换和旧布局升级结果，以及原有名称、图标、尺寸选项和 USB 编码。
- `widget-render.sha256`：重构前 `widget.c` 执行 `tests/widget_test.c` 的标准输出摘要。覆盖五类数据组件的 11 种当前／历史尺寸、四个方向，以及通知展开、收起、超时回退的 100 帧。比较像素、透明度、重绘区域及下一次绘制状态。

测试使用合成数据，不连接账号或设备。板端绘制测试从 ESP-IDF 的 `components/json/cJSON` 编译依赖，并启用 AddressSanitizer 和 UndefinedBehaviorSanitizer。
