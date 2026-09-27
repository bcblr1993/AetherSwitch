# AetherSwitch

Apple Silicon 上的原生 macOS 系统状态与快捷开关工具，使用 Swift 6、AppKit、Mach、IOKit，无第三方依赖。

提供 CPU、GPU、内存、系统卷容量和物理网络接口速率，以及保持常亮、隐藏桌面、显示隐藏文件、深色模式开关。菜单栏与面板采用系统原生控件，支持浅色、深色外观和键盘操作。

内存使用量扣除可回收文件缓存，参考 [Stats 内存采样实现](https://github.com/exelban/stats/blob/master/Modules/RAM/readers.swift)。GPU 为驱动瞬时读数，缺少计数器时显示不可用；磁盘读写速率暂不提供。网络速率汇总 `en*` 物理接口，不计虚拟隧道流量。

## 构建

需要 Apple Silicon、macOS 14 或更新版本、Swift 6 工具链。

```sh
swift test
./scripts/build_app.sh
```

产物位于 `outputs/build-构建号/`，包括 app、DMG、tar.gz 和 SHA256SUMS.txt。正式分发还需要 Apple 公证、staple、Gatekeeper 与安装验证。

```sh
AetherSwitch.app/Contents/MacOS/AetherSwitch --diagnose
```

诊断模式输出实时 CPU、GPU、RAM 与容量读数。内存和功耗结果以实际设备的 Physical Footprint 与运行监测记录为准。

[MIT License](LICENSE) · [作者](https://github.com/bcblr1993) · [官网](https://aethernative.com)
