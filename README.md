# AetherSwitch

Apple Silicon 上的原生 macOS 系统状态与快捷开关工具，使用 Swift 6、AppKit、Mach、IOKit；除原生在线更新组件 Sparkle 外无第三方依赖（见 `THIRD_PARTY_NOTICES.md`）。

提供 CPU、GPU、内存、APFS 共享容器容量、物理磁盘读写速率和网络接口速率，以及保持常亮、隐藏桌面、显示隐藏文件、深色模式开关。菜单栏与面板采用系统原生控件，支持浅色、深色外观和键盘操作。

在面板底部或菜单栏右键菜单开启「开机自启动」，登录 macOS 后自动运行。默认关闭，状态与系统登录项同步；需要系统审批时可直接打开登录项设置。

从面板右上角齿轮或菜单栏右键菜单打开「菜单栏外观设置」。CPU、GPU、RAM、SSD 可独立选择 Mini 数值、柱状图、饼图、标签与对齐方式；利用率颜色沿用 Stats（0–60% 蓝、超过 60% 至 80% 橙、超过 80% 红），也可选择黑白、系统强调色、固定颜色，RAM 额外支持按真实内存压力着色。默认使用 Stats 的 7pt 浅字重标签、12pt 常规数值，隐藏标签时数值为 14pt；可切换等宽数字，并调整指标间距。网络支持圆点、箭头、I/O、隐藏图标、单位和方向顺序。设置即时生效并持久保存。

「保持常亮」会记住最后一次开启或关闭，重新启动应用时恢复电源断言；配合开机自启动，可在机器重启并登录后恢复常亮。退出应用时释放断言但保留选择。桌面图标、隐藏文件及外观沿用 macOS 保存的设置，界面读取系统真实状态。

面板的「屏幕亮度」滑条同步控制内置屏与支持 DDC/CI 的外接显示器，以各屏的亮度范围设置相同百分比。打开面板只读取当前亮度；拖动软件滑条，或使用 Mac 亮度键、系统亮度滑条调整原生屏幕后，软件读数与其余可控屏幕会跟随。面板关闭时也接收系统亮度变化通知，不做后台轮询；连接变化会重新识别。外接屏需要开启 DDC/CI，部分转接器、虚拟屏、HDR/图像模式可能不支持硬件调整，面板会提示具体失败。同一百分比不代表相同的实际亮度（nits）。

外接显示器的最低硬件亮度通常仍有背光。滑条下方 25% 区间使用系统 Gamma 曲线继续平滑调暗，到 0% 时使画面全黑；上方区间控制硬件亮度。内屏使用 macOS 原生平滑亮度接口；外屏持续渐变跟随最新目标，DDC 硬件写入独立执行并合并过期目标，低亮度时进一步限制调暗步幅。过渡速度取决于显示器和连接方式；系统开启「减少动态效果」时立即调整。调高滑条或正常退出软件时恢复原色彩曲线，并保留系统或其他软件后来设置的新曲线。相同滑条百分比表示统一的调节范围，显示器 OSD 的硬件百分比可能不同。

「零亮度时关闭外屏背光」默认关闭，记住上次选项；只有亮度与电源接口可用的外屏才能开启。启用后在 0% 尝试 DDC DPMS Off，并核对读回；调高滑条、关闭此选项或正常退出时恢复。失败或无法验证的设备自动停用此能力，保留软件全黑。已发现不能可靠恢复的 LG HDR 4K（GSM7706/GSM7707）不会发送关闭背光指令。软件全黑不代表背光断电。内置屏仍使用系统原生亮度；内屏全黑后可用 Mac 的亮度键恢复。

CPU、GPU、内存和磁盘面板参考 [Stats v3.0.20](https://github.com/exelban/stats/tree/v3.0.20/Modules) 的指标与信息结构，使用本项目的原生采样和位图绘制实现：

- CPU：温度 / 总负载 / 实时频率仪表、能效 / 性能核心频率、用户 / 系统 / 空闲占用、各核心占用、真实能效 / 性能核心分组、平均负载、运行时间及主要进程。
- GPU：设备 / 渲染 / Tiler 利用率、型号、核心数及历史、各屏幕合计呈现帧率、神经引擎功率；缺失的子指标单独显示不可用。
- 内存：应用 / 联结 / 压缩分段环、系统压力等级、可回收缓存、可用内存、交换已用 / 总量及主要进程物理占用。缓存属于可用内存，不能与可用量再次相加；压力等级不是内存使用百分比。
- 磁盘：可选择启动卷或外接卷，显示型号、文件系统、容量、对应物理设备读写历史和主要进程读写速率；支持设备的 NVMe SMART 健康、温度、寿命、备用空间与通电时长。APFS 容量由容器共享，I/O 属于物理设备，进程榜单汇总进程的所有设备 I/O。

面板展开时每秒刷新，历史保留最近 60 次采样；主要进程通过 libproc 每两秒刷新，只在 CPU、内存或磁盘页启用。进程 CPU 以单核心 100% 计量，可超过 100%；系统 CPU 按全部核心归一化。收起后每五秒更新菜单栏，停止核心详情、进程枚举及历史采样；GPU 缓存设备句柄，不反复扫描设备树。较矮屏幕中详情区域可滚动，亮度与开关仍保留在底部。

温度使用只读 AppleSMC；频率根据 IOReport 活跃状态驻留时间和硬件 DVFS 表计算，完全空闲时显示最低状态频率；呈现帧率来自 DCP 实际帧计数，多个屏幕合计可超过单屏刷新率。神经引擎显示原生能量计数折算的功率，不将其冒充精确利用率。SMART 使用只读原生 NVMe 接口，不支持的 SATA、USB 桥接设备或系统权限受限时明确显示不可用。Apple Silicon M1–M4 的能效和性能频率布局受支持；M5 不套用旧性能簇布局。本项目没有引入 Stats 或其辅助进程。网络默认跟随主接口，可手动选择物理或虚拟接口，不重复汇总隧道及其底层接口。

## 监测与能耗设置

菜单栏外观设置支持指标向左/右排序、1/2/5/10 秒后台刷新（默认 5 秒）；面板展开时每秒刷新。隐藏指标不再读取，只有图标且面板关闭时停止采样定时器。CPU 多核、温度/频率、进程排行、SMART 等详情按当前页面启停。

网络页自动跟随主接口，也可手动选择接口；显示 IPv4、系统允许读取的 Wi-Fi 名称、协商速率、信号强度和本次监测累计流量。选择虚拟接口时只统计该接口，避免叠加物理接口产生重复；断线、计数器重置或切换后重新建立速率基线。累计仅包含实际采样期间，切换接口重新计数。Wi-Fi 名称受系统定位权限限制，不可读时显示不可用。

电池页使用 IOKit 电源来源和内置电池信息，30 秒缓存一次电量、充电状态、预计剩余时间、最大容量和循环次数；台式 Mac 或缺少系统字段时明确显示不可用。图表展示面板展开期间最近 60 个采样点，收起后不保留跨时段连续曲线。

品牌图形为 S 形开关。`./scripts/generate_icon.sh` 由共享的原生 `BrandGlyph` 几何生成图标预览，应用图标与菜单栏使用同一套形状。

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
AetherSwitch.app/Contents/MacOS/AetherSwitch --acceptance-brightness-following
```

第一条只读取。第二条通过实际滑条同步调整亮度、读回结果，再分别恢复每块屏幕的原亮度。第三条额外测试 20%、10%、2% 的连续软件调暗、0% 全黑与调高恢复，会短暂使所有屏幕变黑；背光关闭仅在相应选项开启且设备允许时执行，读回验证仍需结合真机目视验收。第四条只改变原生屏幕，验证系统变化通知能更新真实软件滑条、同步 DDC 外屏，并在释放面板后继续同步；结束时分别恢复原亮度。第五条通过真实滑条连续输入和反向拖动，记录内屏即时读回、外屏渐变与 DDC 时序，并验证全黑、恢复及原亮度还原。时序读回和截图不能测量屏幕背光的实际光学变化。验收命令输出 JSON，失败返回非零；可用 `--acceptance-brightness-restore <验收 JSON 路径>` 再次按记录恢复原亮度。需要真实连接的屏幕，虚拟机不能替代外接硬件验收。底层使用系统 DisplayServices 与 IOAVService 接口；系统版本变化导致接口不可用时会停用对应控制。无法唯一识别的同型号同序列号显示器会标为不可用，避免控制错误屏幕。

实现参考：[MonitorControl](https://github.com/MonitorControl/MonitorControl) 的硬件与软件组合调暗、[ScreenControl](https://github.com/Grkmyldz148/ScreenControl) 的 DPMS 背光控制。未引入它们的第三方组件。Get/Set VCP 分别使用不同校验种子，所有 I2C 事务串行执行；只发送可恢复的电源值 1 / 4，不发送硬关闭值 5。

[MIT License](LICENSE) · [作者](https://github.com/bcblr1993) · [官网](https://aethernative.com)
