# AetherSwitch

Apple Silicon 上的原生 macOS 系统状态与快捷开关工具，使用 Swift 6、AppKit、Mach、IOKit；除原生在线更新组件 Sparkle 外无第三方依赖（见 `THIRD_PARTY_NOTICES.md`）。

提供 CPU、GPU、内存、APFS 共享容器容量、物理磁盘读写速率和网络接口速率，以及保持常亮、隐藏桌面、显示隐藏文件、深色模式开关。菜单栏与面板采用系统原生控件，支持浅色、深色外观和键盘操作。

在面板底部或菜单栏右键菜单开启「开机自启动」，登录 macOS 后自动运行。默认关闭，状态与系统登录项同步；需要系统审批时可直接打开登录项设置。

「保持常亮」会记住最后一次开启或关闭，重新启动应用时恢复电源断言；配合开机自启动，可在机器重启并登录后恢复常亮。退出应用时释放断言但保留选择。桌面图标、隐藏文件及外观沿用 macOS 保存的设置，界面读取系统真实状态。

面板的「屏幕亮度」滑条同步控制内置屏与支持 DDC/CI 的外接显示器，以各屏的亮度范围设置相同百分比。打开面板只读取当前亮度；拖动软件滑条，或使用 Mac 亮度键、系统亮度滑条调整原生屏幕后，软件读数与其余可控屏幕会跟随。面板关闭时也接收系统亮度变化通知，不做后台轮询；连接变化会重新识别。外接屏需要开启 DDC/CI，部分转接器、虚拟屏、HDR/图像模式可能不支持硬件调整，面板会提示具体失败。同一百分比不代表相同的实际亮度（nits）。

外接显示器的最低硬件亮度通常仍有背光。滑条到 0% 时，在最低硬件亮度之上使用系统 Gamma 曲线使外屏画面全黑，并明确显示「软件全黑」；调高滑条或正常退出软件时恢复原色彩曲线。这是画面调暗，不代表显示器已关机或背光断电。内置屏仍使用系统原生亮度；内屏全黑后可用 Mac 的亮度键先亮起内屏，再调高滑条。

内存使用量扣除可回收文件缓存，参考 [Stats 内存采样实现](https://github.com/exelban/stats/blob/master/Modules/RAM/readers.swift)。GPU 为驱动瞬时读数，缺少计数器时显示不可用；磁盘速率汇总已连接的物理设备。网络速率汇总 `en*` 物理接口，不计虚拟隧道流量。

## 构建

需要 Apple Silicon、macOS 14 或更新版本、Swift 6 工具链。

```sh
swift test
./scripts/build_app.sh
```

产物位于 `outputs/build-构建号/`，包括 app、DMG、tar.gz 和 SHA256SUMS.txt。正式分发还需要 Apple 公证、staple、Gatekeeper 与安装验证。

构建后用实际弹窗逐页检查物理内存峰值。脚本默认执行项目当前的 50 MB 门槛，超过上限会返回失败；更改门槛前须先更新项目验收规范。

```sh
python3 scripts/verify_popover_memory.py outputs/build-构建号/AetherSwitch.app/Contents/MacOS/AetherSwitch
python3 scripts/verify_login_item.py outputs/build-构建号/AetherSwitch.app/Contents/MacOS/AetherSwitch
```

```sh
AetherSwitch.app/Contents/MacOS/AetherSwitch --diagnose
```

诊断模式输出实时 CPU、GPU、RAM 与容量读数。内存和功耗结果以实际设备的 Physical Footprint 与运行监测记录为准。

显示器亮度诊断与真机验收：

```sh
AetherSwitch.app/Contents/MacOS/AetherSwitch --brightness-status
AetherSwitch.app/Contents/MacOS/AetherSwitch --acceptance-brightness-cycle
AetherSwitch.app/Contents/MacOS/AetherSwitch --acceptance-brightness-blackout
AetherSwitch.app/Contents/MacOS/AetherSwitch --acceptance-brightness-system-sync
```

第一条只读取。第二条通过实际滑条同步调整亮度、读回结果，再分别恢复每块屏幕的原亮度。第三条额外测试 0% 软件全黑与调高恢复，会短暂使所有屏幕变黑；读回验证仍需结合真机目视验收。第四条只改变原生屏幕，验证系统变化通知能更新真实软件滑条、同步 DDC 外屏，并在释放面板后继续同步；结束时分别恢复原亮度。验收命令输出 JSON，失败返回非零。需要真实连接的屏幕，虚拟机不能替代外接硬件验收。底层使用系统 DisplayServices 与 IOAVService 接口；系统版本变化导致接口不可用时会停用对应控制，0% 的 Gamma 调暗会明确标注，不作为外屏背光断电的证明。无法唯一识别的同型号同序列号显示器会标为不可用，避免控制错误屏幕。

[MIT License](LICENSE) · [作者](https://github.com/bcblr1993) · [官网](https://aethernative.com)
