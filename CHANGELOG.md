# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-30

### Added
- 全新「叠放滑杆」App 图标，菜单栏、按钮图标与面板标题使用同一图形；`scripts/generate_icon.swift` 可重新生成图标。
- 面板内「关于」页面，提供版本、构建号与官网、GitHub、问题反馈入口，替代阻塞式对话框。
- 验收日志记录每一步的进程物理内存峰值，便于定位切页峰值。

### Changed
- 面板与菜单栏统一使用 70% / 85% 负载阈值；红色只表示过载，上传与磁盘写入不再使用告警红。
- 菜单栏常态数值跟随系统文字色，在任何壁纸下保持清晰。
- 面板改用 SF Symbols 图标、半透明卡片、等宽数字与统一字号；环形图按负载着色，图表增加网格线。
- 网络与磁盘速率统一显示为「数值 + 单位」。

### Fixed
- 内存卡片不论负载都显示红色。

### Removed
- 未参与编译的 SwiftUI 面板与组件（含写死的假温度读数）。

## [1.0.2] - 2026-09-30

### Fixed
- 详情图表复用固定尺寸的绘制区域，卡片文字采用系统 CoreText 绘制并及时归还临时内存，减少 Retina 屏幕切页时的内存峰值。
- 面板间距更紧凑，网络峰值与全部指标保持完整展示。
- 菜单栏直接绘制最新采样与样式值，修复指标延迟一轮及样式切换未即时生效。

### Changed
- 恢复概览指标四宫格、彩色进度条、网络卡片与带状态说明的快捷开关，并保持原生 AppKit 控件和真实采样逻辑。
- 对齐 Stats 的 CPU、GPU、内存、磁盘和网络弹出详情结构，加入真实历史曲线与系统分项；统一面板高度以避免切页抖动。
- 改进浅色与深色外观下的卡片排版、字段对比度、图标层级和开关对齐。
- 菜单栏恢复双行彩色指标列与末尾滑杆图标；磁盘容量明确标为 APFS 共享容器空间。
- 正式构建保留旧候选包和校验清单，便于验收与回退；清理 SwiftPM 编译中间产物。

## [1.0.1] - 2026-09-28

### Fixed
- 内存使用量扣除可回收文件缓存，补计 speculative 页面，与 Stats 的内核口径一致。
- CPU tick 差值支持计数器回绕；网络接口按 AF_LINK 去重，短间隔刷新保留上一有效速率。
- GPU 展示原始驱动利用率，无可用计数器时明确显示不可用。
- 移除模拟磁盘读写、错误的磁盘进程排名、虚构 ANE 负载与预填历史。
- Finder 缺省配置不再误报桌面隐藏；电源断言生命周期与采样并发同步。
- 检查更新失败不再误报最新版本；改用系统浏览器下载安装包。
- 重新打开面板时 CPU 总体读数沿用连续采样基线，短间隔刷新保留有效读数。
- 原生面板即时同步开关、展示更新结果与失败重试，错误提示按内容调整高度。
- 磁盘速率改用物理驱动累计计数，设备重置与重新展开时重新建立基线；只在磁盘页采样。
- 开关操作期间禁止重复请求，后台旧状态快照不再覆盖最新结果；增加操作失败反馈。

### Changed
- 生产面板与菜单栏采用 AppKit 原生控件；收起后释放面板视图与弹出窗口。
- 启用 Swift 6 严格模式，测试截图输出到临时目录。
- 构建保留旧产物，Developer ID 显式使用安全时间戳。
- 正式构建在生成产物前校验主干、干净工作区与 Developer ID 证书。
- 移除后台未使用的显示模式查询，明确后台采样临时对象的释放边界。

## [1.0.0] - 2026-09-26

### Added
- **Core Toggles**: 初始发布 4 大系统级核心快捷开关（保持常亮、隐藏桌面、显示隐藏文件、黑暗模式）。
- **IOKit Power Assertion**: 保持屏幕常亮采用系统原生 `IOPMAssertion` 电源断言，无僵尸子进程，应用退出自动安全释放。
- **Live Hardware Metrics**: 原生 Mach 内核与 IOKit 硬件监控引擎，支持实时 CPU、Apple Silicon GPU、RAM、SSD 存储及实时网络上下行速率。
- **Adaptive Frequency Scheduling**: 自适应能耗采样调度器，面板折叠时休眠 CPU 与 GPU 高频采样，面板展开时激活 1.0s 全量指标。
- **Ultra-Lightweight MenuBar UI**: 原生 SwiftUI + AppKit 毛玻璃（`.ultraThinMaterial`）面板，等宽数字排版杜绝菜单栏刷新抖动。
- **Release Automation**: 集成 `./scripts/build_app.sh` 自动化门禁、Developer ID 签名与 SHA256 校验流水线。
