# AetherSwitch (ControlLite)

Created and maintained by **编程不良人 (BianChengBuLiangRen)**.

> [!IMPORTANT]
> AetherSwitch is an ultra-lightweight, native Apple Silicon macOS status monitor & quick toggle utility built with pure Swift 6, AppKit, SwiftUI, Mach Kernel, and IOKit. Zero external dependencies. Designed to completely replace heavy multi-hundred-megabyte tool stacks with a tiny, elegant native footprint.

---

## 🌟 核心理念与定位 (Design Philosophy)

在 macOS 上，日常最频繁使用的功能通常只有两类：
1. **实时硬件状态**：抬头看一眼当前的内存占用和瞬时网络上下行速率；
2. **核心快捷开关**：保持屏幕常亮、隐藏桌面图标、显示隐藏文件、切换深色模式。

以往为了实现上述功能，用户需要同时在后台常驻 **Stats.app (~126MB)** 与 **One Switch (~100MB)**，叠加占用近 **250MB+** 物理内存，且全天候高频轮询硬件产生多余发热。

**AetherSwitch** 专为追求极致性能与极简美学的 Mac 用户打造：
* 📦 **体积极致**：完整 App Bundle 仅 **~470 KB**；
* ⚡️ **内存极致**：物理内存占用仅 **~15 MB**，较传统组合降低 **85% 以上**；
* 🔋 **功耗极致**：独创**自适应双频采样**，面板收起时彻底休眠 GPU 与 CPU 多核计算，后台 CPU 占用 **≤ 0.1%**；
* 🎨 **原生质感**：严格遵循 Apple 官方人机交互指南（HIG），全毛玻璃面板、等宽防抖排版与触觉弹性动画。

---

## 🚀 功能矩阵 (Features)

### 1. 核心快捷开关 (4 Essential Quick Toggles)
* ☕️ **保持常亮 (Keep Screen Awake)**：基于系统原生 IOKit `IOPMAssertion` 电源管理断言，不产生任何后台僵尸脚本进程，退出即自动归还电源控制权；
* 🖥 **隐藏桌面 (Hide Desktop Icons)**：一键隐去桌面所有杂乱文件与图标，录屏、截屏、演讲必备；
* 📁 **显示隐藏文件 (Show Hidden Files)**：一键展开与收起 Finder 中的点号隐藏文件（`.` 开头文件）；
* 🌙 **黑暗模式 (Dark Mode)**：无缝在浅色与深色外观之间极速切换。

### 2. 实时硬件脉搏 (5 Core Live Metrics)
* 🧠 **CPU 负载**：读取 Mach 内核 `PROCESSOR_CPU_LOAD_INFO`，精确呈现整体利用率；
* 🔮 **GPU 负载**：直连 Apple Silicon `IOAccelerator` 性能计数器，秒级探查芯片图形核心利用率；
* 💾 **RAM 内存**：精确计算 Active、Wired 与 Compressed 真实已用内存与物理内存总量；
* 💿 **SSD 存储**：POSIX `statfs` 秒读根目录存储盘使用量与容量百分比；
* 🚀 **网络吞吐**：遍历物理网卡（`en*`），动态计算瞬时上行/下行速率（B/s, KB/s, MB/s 自动切换）。

---

## 📊 性能基准对比 (Performance Benchmark)

| 核心指标 | Stats.app + One Switch 组合 | **AetherSwitch (ControlLite)** | 优化幅度 |
| :--- | :--- | :--- | :--- |
| **物理驻留内存 (Footprint)** | ~250 MB | **~15 MB** | **-85% ⬇️** |
| **安装包体积 (Disk Size)** | ~80 MB | **~470 KB** | **-99% ⬇️** |
| **第三方库依赖** | 包含多个外部框架/音频/驱动 | **0 个（纯原生系统 API）** | **绝对纯净** |
| **后台空载 CPU 占用** | 0.8% ~ 1.5% | **≤ 0.1%** | **几乎零开销 ⬇️** |
| **后台采样策略** | 全量盲目持续轮询 | **自适应调度（折叠休眠/展开激活）** | **延长续航** |

---

## 🛠 构建与运行 (Build & Run)

### 环境要求
* Apple Silicon (M1 / M2 / M3 / M4) Mac
* macOS 14.0 (Sonoma) 或 macOS 15.0+ (Sequoia)
* Xcode 15.0+ / Swift 6.0+

### 一键构建与打包
项目遵循标准流水线，运行项目根目录脚本即可自动完成测试、Release 编译、Bundle 组装与官方 Developer ID 签名：

```bash
# 执行自动化质量门禁与打包流水线
./scripts/build_app.sh
```

构建产物将输出至 `outputs/` 目录：
- `outputs/AetherSwitch.app`（已完成签名，可直接拖入 `/Applications` 运行）
- `outputs/AetherSwitch-1.0.0-arm64.tar.gz`
- `outputs/SHA256SUMS.txt`

---

## ⚖️ 协议与鸣谢 (License)

本项目采用 [MIT License](LICENSE) 开源协议。
Created and maintained by [编程不良人 (bcblr1993)](https://github.com/bcblr1993)。
官网：[aethernative.com](https://aethernative.com)
