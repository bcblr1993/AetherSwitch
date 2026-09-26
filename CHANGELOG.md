# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-26

### Added
- **Core Toggles**: 初始发布 4 大系统级核心快捷开关（保持常亮、隐藏桌面、显示隐藏文件、黑暗模式）。
- **IOKit Power Assertion**: 保持屏幕常亮采用系统原生 `IOPMAssertion` 电源断言，无僵尸子进程，应用退出自动安全释放。
- **Live Hardware Metrics**: 原生 Mach 内核与 IOKit 硬件监控引擎，支持实时 CPU、Apple Silicon GPU、RAM、SSD 存储及实时网络上下行速率。
- **Adaptive Frequency Scheduling**: 自适应能耗采样调度器，面板折叠时休眠 CPU 与 GPU 高频采样，面板展开时激活 1.0s 全量指标。
- **Ultra-Lightweight MenuBar UI**: 原生 SwiftUI + AppKit 毛玻璃（`.ultraThinMaterial`）面板，等宽数字排版杜绝菜单栏刷新抖动。
- **Release Automation**: 集成 `./scripts/build_app.sh` 自动化门禁、Developer ID 签名与 SHA256 校验流水线。
