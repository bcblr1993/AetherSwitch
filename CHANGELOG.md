# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-09-27

### Fixed
- 内存使用量扣除可回收文件缓存，补计 speculative 页面，与 Stats 的内核口径一致。
- CPU tick 差值支持计数器回绕；网络接口按 AF_LINK 去重，短间隔刷新保留上一有效速率。
- GPU 展示原始驱动利用率，无可用计数器时明确显示不可用。
- 移除模拟磁盘读写、错误的磁盘进程排名、虚构 ANE 负载与预填历史。
- Finder 缺省配置不再误报桌面隐藏；电源断言生命周期与采样并发同步。
- 检查更新失败不再误报最新版本；改用系统浏览器下载安装包。
- 重新打开面板时 CPU 总体读数沿用连续采样基线，短间隔刷新保留有效读数。
- 原生面板即时同步开关、展示更新结果与失败重试，错误提示按内容调整高度。

### Changed
- 生产面板与菜单栏采用 AppKit 原生控件；收起后释放面板视图与弹出窗口。
- 启用 Swift 6 严格模式，测试截图输出到临时目录。
- 构建保留旧产物，Developer ID 显式使用安全时间戳。
- 正式构建在生成产物前校验主干、干净工作区与 Developer ID 证书。

## [1.0.0] - 2026-09-26

### Added
- **Core Toggles**: 初始发布 4 大系统级核心快捷开关（保持常亮、隐藏桌面、显示隐藏文件、黑暗模式）。
- **IOKit Power Assertion**: 保持屏幕常亮采用系统原生 `IOPMAssertion` 电源断言，无僵尸子进程，应用退出自动安全释放。
- **Live Hardware Metrics**: 原生 Mach 内核与 IOKit 硬件监控引擎，支持实时 CPU、Apple Silicon GPU、RAM、SSD 存储及实时网络上下行速率。
- **Adaptive Frequency Scheduling**: 自适应能耗采样调度器，面板折叠时休眠 CPU 与 GPU 高频采样，面板展开时激活 1.0s 全量指标。
- **Ultra-Lightweight MenuBar UI**: 原生 SwiftUI + AppKit 毛玻璃（`.ultraThinMaterial`）面板，等宽数字排版杜绝菜单栏刷新抖动。
- **Release Automation**: 集成 `./scripts/build_app.sh` 自动化门禁、Developer ID 签名与 SHA256 校验流水线。
