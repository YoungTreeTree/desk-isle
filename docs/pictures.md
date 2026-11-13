# 图片与板端 GIF

静态图片上传一次。支持 `DESKISLE_PICTURES 1` 的固件接收完整动画帧包并在 ESP32-P4 的 PSRAM 中缓存，由板端时间轴、JPEG 硬件解码器和合成器循环播放。Mac 在应用布局时做一次 GIF 解析和尺寸适配；上传完成后没有持续的图片帧发送任务。关闭 Mac 应用或断开数据连接不停止已缓存的动画；开发板掉电后，Mac 重连时重新上传已应用布局的资源。

壁纸独立上传，不包含在每一张角色动画帧里。透明 GIF 使用预乘颜色 JPEG 与独立透明度数据，继续支持背景、层级和四个屏幕方向。编译固件不包含用户图片或 GIF。

## 限制与恢复

- 图片组件维持 80、160、240、320 像素正方形；按比例留白适配原图。
- Mac 准备动画的上限为 30 FPS、144 帧，保留完整循环的时间轴；超出帧数时采样。12 帧、80 ms/帧的动画保留全部帧和 960 ms 周期。
- 单个动画帧包最多 4 MiB，所有帧包加未完成上传共用 8 MiB 缓存预算。JPEG 解码输出、屏幕缓冲及其他组件另外占用内存。
- 分块上传带偏移和 CRC。提交时检查整包 CRC、尺寸、时间轴、所有 JPEG 头和透明度长度；首帧解码成功后才替换原动画。失败保留旧动画并报告未完全同步，不改为持续传帧。
- 只有一个临时上传区；中断 30 秒后回收。组件删除、尺寸改变或替换为静态图片会释放对应动画；仅移动、旋转或重排可复用缓存。
- 亮度为零／锁屏熄屏时暂停解码开销，恢复时按当前时间轴继续。普通暂停命令则冻结时间轴。
- Mac 定期读取布局附带的资源指纹；资源仍在时不重传。资源缺失时恢复最近一次应用的快照，不发送未应用的编辑。
- 旧固件不声明此能力时仍使用兼容的 Mac 逐帧发送路径；更新固件后自动使用板端播放。

## 协议

沿用 `ISLE` v1 控制通道，组件 ID 为 `0x8100...0x81ff`，消息头宽高为零。

| 消息 | Kind | 载荷 |
| --- | --- | --- |
| 开始上传 | 22 | `uint32 size, crc32` |
| 上传分块 | 23 | `uint32 offset` + 最多 32 KiB 数据 |
| 提交 | 24 | 空 |
| 控制 | 25 | 一字节：0 恢复、1 暂停、2 重播、3 清除缓存（保留末帧） |
| 性能统计 | 26 | 空 |
| 放弃上传 | 27 | 空 |

失败返回 `DESKISLE_ACK <seq> 8 <ms>`。布局回执前附带能力和每个常驻动画的指纹：

```text
DESKISLE_PICTURES 1 <seq> <max_pack> <chunk> <total_budget> <max_frames>
DESKISLE_PICTURE 1 <seq> <id> <bytes> <crc32> <width> <height> <state>
```

`state` 为 0 播放、1 暂停、2 解码失败。统计回执分别给出解码帧数与提交到显示缓冲的动画帧数，后者不计其他组件引起的重复刷新：

```text
DESKISLE_PICTURE_STATS 1 <seq> <id> <bytes> <crc32> <frames> <duration_ms> <decoded> <presented> <elapsed_us> <decode_us> <max_decode_us> <state> <free_psram> <largest_psram>
```

### DIGA v1 帧包

所有整数为小端。16 字节头为 `DIGA`、`uint16 version=1, frame_count, width, height`、`uint32 duration_ms`。紧随其后的每个 16 字节帧条目为 `uint32 start_ms, jpeg_offset, jpeg_length, alpha_length`。

JPEG 起点均对齐 64 字节，后跟透明度数据，再补零对齐到 64 字节。无透明度时长度为零；透明度数据为逐像素 8 位 alpha，或现有 `(uint8 run, uint8 alpha)` RLE。尺寸、偏移、长度、循环时间和 RLE 覆盖范围必须通过校验。

## 测试

`python3 tests/test_pictures.py` 在 ASan／UBSan 下测试板端解析、独立时间轴、原子替换、中断回收和重复创建销毁。Swift 测试验证帧包、无持续传帧、旧固件回退及原布局回归。

2026-11-13 在 ESP32-P4、CH343 连接上实测：两张 240 × 240、12 帧／960 ms 的透明角色动图，同时保留布局中的 3D 模型。关闭整个 Mac 通信会话约 20 秒后，板端每张动画分别提交 12.49、12.51 FPS，达到源动画的 12.5 FPS；Mac 逐帧发送数为零，可用 PSRAM 无变化。两张压缩帧包共 326,720 字节，平均每帧解码及更新耗时分别约 3.30、2.14 ms。清除一张缓存后，应用快照可自动补传并恢复播放。此结果针对上述素材、尺寸与布局，不代表任意大尺寸或高帧率 GIF 的性能上限。

真机测试需先关闭桌屿，并显式设置输出路径。它只操作当前已应用布局里的 GIF，最后恢复其播放；会短暂清除一张 GIF 缓存来验证恢复，不修改布局库或刷固件：

```sh
DESKISLE_NATIVE_GIF_REPORT="$PWD/build/native-gif-report.json" \
  swift test --scratch-path build/swiftpm -c release --filter PicturePlaybackTests.testConnectedNativePicturePlayback
```
