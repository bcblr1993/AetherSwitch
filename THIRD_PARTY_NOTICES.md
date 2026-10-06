# 第三方声明

AetherSwitch 仅使用 macOS 系统框架（Darwin、Mach、IOKit、AppKit、Security），唯一的第三方组件是：

- [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle/tree/2.9.6) —— 原生在线更新（更新清单与更新包的签名校验、下载、安装与重启）。遵循其分发包 LICENSE（包含 Sparkle 及附带组件声明），完整许可证随应用 `Contents/Resources/Sparkle-LICENSE` 分发。

## Stats 参考实现

硬件传感器键、IOReport 通道、指标分解及菜单栏 Mini / 图表 / 网速组件的字体、尺寸、图标和利用率配色参考 [Stats v3.0.20](https://github.com/exelban/stats/tree/v3.0.20)，遵循 MIT 许可证。AetherSwitch 使用独立的 Swift 原生实现，未链接 Stats 或引入其辅助进程。完整许可见 `LICENSES/Stats-MIT.txt`，随应用打包。
