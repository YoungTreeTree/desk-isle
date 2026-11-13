# 应用图标

桌屿沿用 Miucs 的像素猫头，保留原图造型、配色和透明背景。

- `cat-head.png`：未经修改的 Miucs 原图，来自 [`apps/assets/cat-head.png`](https://github.com/YoungTreeTree/miucs/blob/d7a84e38377e156eb85660853ccc623b8f92704d/apps/assets/cat-head.png)。上游记录该图源自 pixel-keyboard 素材，见 [Miucs 图标说明](https://github.com/YoungTreeTree/miucs/blob/d7a84e38377e156eb85660853ccc623b8f92704d/apps/assets/README.md)。
- `../DeskIsle.icns`：macOS 图标包，包含 16、32、128、256、512 pt 的 1× / 2× 图像，最大 1024 × 1024 px。

在 macOS 上从仓库根目录重新生成：

```sh
zsh tools/make-app-icon.sh
```

`tools/build-macos.sh` 将图标放入应用资源目录，并通过 `CFBundleIconFile` 声明。图标与插件加载、桌宠开关相互独立。

猫头是沿用的 Miucs 素材，项目原创代码的 MIT 授权不替代原素材授权；相关边界见[项目许可证说明](../../README.md#许可证)。
