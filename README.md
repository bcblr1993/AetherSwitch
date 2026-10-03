# AetherSwitch

Apple Silicon 上的原生 macOS 系统状态与快捷开关工具，使用 Swift 6、AppKit、Mach、IOKit；除原生在线更新组件 Sparkle 外无第三方依赖（见 `THIRD_PARTY_NOTICES.md`）。

提供 CPU、GPU、内存、APFS 共享容器容量、物理磁盘读写速率和网络接口速率，以及保持常亮、隐藏桌面、显示隐藏文件、深色模式开关。菜单栏与面板采用系统原生控件，支持浅色、深色外观和键盘操作。

在面板底部或菜单栏右键菜单开启「开机自启动」，登录 macOS 后自动运行。默认关闭，状态与系统登录项同步；需要系统审批时可直接打开登录项设置。

「保持常亮」会记住最后一次开启或关闭，重新启动应用时恢复电源断言；配合开机自启动，可在机器重启并登录后恢复常亮。退出应用时释放断言但保留选择。桌面图标、隐藏文件及外观沿用 macOS 保存的设置，界面读取系统真实状态。

面板的「屏幕亮度」滑条同步控制内置屏与支持 DDC/CI 的外接显示器，以各屏的亮度范围设置相同百分比。打开面板只读取当前亮度；拖动软件滑条，或使用 Mac 亮度键、系统亮度滑条调整原生屏幕后，软件读数与其余可控屏幕会跟随。面板关闭时也接收系统亮度变化通知，不做后台轮询；连接变化会重新识别。外接屏需要开启 DDC/CI，部分转接器、虚拟屏、HDR/图像模式可能不支持硬件调整，面板会提示具体失败。同一百分比不代表相同的实际亮度（nits）。

外接显示器的最低硬件亮度通常仍有背光。滑条下方 25% 区间使用系统 Gamma 曲线继续平滑调暗，到 0% 时使画面全黑；上方区间控制硬件亮度。进入全黑与恢复时使用约 200 ms 的渐变，内屏亮度与外屏 Gamma 共用过渡进度，新的拖动会中断旧动画；系统开启「减少动态效果」时立即调整。调高滑条或正常退出软件时恢复原色彩曲线，并保留系统或其他软件后来设置的新曲线。相同滑条百分比表示统一的调节范围，显示器 OSD 的硬件百分比可能不同。

「零亮度时关闭外屏背光」默认关闭，记住上次选项；只有亮度与电源接口可用的外屏才能开启。启用后在 0% 尝试 DDC DPMS Off，并核对读回；调高滑条、关闭此选项或正常退出时恢复。失败或无法验证的设备自动停用此能力，保留软件全黑。已发现不能可靠恢复的 LG HDR 4K（GSM7706/GSM7707）不会发送关闭背光指令。软件全黑不代表背光断电。内置屏仍使用系统原生亮度；内屏全黑后可用 Mac 的亮度键恢复。

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

第一条只读取。第二条通过实际滑条同步调整亮度、读回结果，再分别恢复每块屏幕的原亮度。第三条额外测试 20%、10%、2% 的连续软件调暗、0% 全黑与调高恢复，会短暂使所有屏幕变黑；背光关闭仅在相应选项开启且设备允许时执行，读回验证仍需结合真机目视验收。第四条只改变原生屏幕，验证系统变化通知能更新真实软件滑条、同步 DDC 外屏，并在释放面板后继续同步；结束时分别恢复原亮度。验收命令输出 JSON，失败返回非零；可用 `--acceptance-brightness-restore <验收 JSON 路径>` 再次按记录恢复原亮度。需要真实连接的屏幕，虚拟机不能替代外接硬件验收。底层使用系统 DisplayServices 与 IOAVService 接口；系统版本变化导致接口不可用时会停用对应控制。无法唯一识别的同型号同序列号显示器会标为不可用，避免控制错误屏幕。

实现参考：[MonitorControl](https://github.com/MonitorControl/MonitorControl) 的硬件与软件组合调暗、[ScreenControl](https://github.com/Grkmyldz148/ScreenControl) 的 DPMS 背光控制。未引入它们的第三方组件。Get/Set VCP 分别使用不同校验种子，所有 I2C 事务串行执行；只发送可恢复的电源值 1 / 4，不发送硬关闭值 5。

[MIT License](LICENSE) · [作者](https://github.com/bcblr1993) · [官网](https://aethernative.com)
