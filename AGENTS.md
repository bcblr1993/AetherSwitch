# AetherSwitch (ControlLite) - Engineering, Verification & Release Standards (SOP)

本文档参考并对齐 **AetherRoute** 与 **ApexTerm** 行业顶级开源工程规范，定义 AetherSwitch 项目从日常开发、代码提交、自动化测试、质量门禁到正式签发构建的全生命周期标准作业程序（SOP）。AI 助手及所有参与开发者**必须无条件严格遵守**。

---

## 🛡️ 一、架构纯净与零依赖红线 (Zero External Dependencies)

1. **绝对原生零依赖**：
   - 全项目必须采用纯 Swift 6 + 原生系统框架（Darwin / Mach / IOKit / AppKit / SwiftUI）；
   - 严禁引入任何重量级第三方开源库或二进制框架（无 CocoaPods，无外部 Carthage/SPM 依赖）；
   - 所有硬件监控必须通过 POSIX、Mach 内核（`host_processor_info`, `host_statistics64`）及 IOKit（`IOAccelerator`）直接采样；
   - 开关控制必须直接通过 IOKit 电源断言（`IOPMAssertion`）与 macOS defaults API 驱动。
2. **内存与功耗门禁**：
   - 生产环境物理内存驻留集（Physical Footprint）必须严格控制在 **≤ 50 MB**，验收时同时检查实时值与进程峰值，保留完整的 Stats 风格详情面板；
   - 面板折叠状态下，CPU 与 GPU 高阶采样必须彻底休眠，后台空载 CPU 占用 **≤ 0.1%**，按连续监测间隔的内核累计 CPU 时间验证。

---

## 🌿 二、分支开发与 Git 提交规范 (Conventional Commits)

1. **分支基线与工作流**：
   - 所有新功能与重构在独立特性分支进行；
   - 严禁在存在未追踪脏工作区（dirty working tree）或测试未通过的状态下执行正式构建与打标；
   - 正式发布与 Tag 必须基于主干（`main` / `master`）签发。
2. **Conventional Commits 提交格式**：
   所有 Git 提交信息必须遵循语义化提交标准，格式为 `<type>(<scope>): <description>`：
   - `feat:` 新增功能（如 `feat(ui): 增加深色模式卡片触觉反馈与高亮边框`）
   - `fix:` 修复缺陷（如 `fix(core): 修复 CPU 多核 tick 溢出导致的计算偏差`）
   - `test:` 新增或调整自动化测试用例（如 `test(monitor): 新增网络吞吐单位格式化边界测试`）
   - `perf:` 性能与算法优化（如 `perf(sampling): 优化折叠状态下的定时器能耗调度`）
   - `refactor:` 代码重构（不改变外部功能）
   - `docs:` 文档与说明变更
   - `chore(release):` 版本发布、构建配置或依赖维护

---

## 📋 三、版本号与构建号规范 (Versioning & Build Numbers)

1. **语义化版本（Semantic Versioning）**：
   - 格式：`vMAJOR.MINOR.PATCH`（例如 `v1.0.0`）。
   - `PATCH`：纯 Bug 修复与小幅细节微调；
   - `MINOR`：新增产品特性、功能增强且向下兼容；
   - `MAJOR`：破坏性架构升级或底层协议重大重构。
2. **构建号（Build Number）**：
   - 格式：`YYYYMMDDNN`（例如 `2026092601` 表示 2026年9月26日第 1 次构建）。
   - 构建号必须单调递增，供 macOS 系统及网站发布记录准确判定构建序列。
3. **版本号全局原子对齐**：
   每次发布前，必须确保以下三处版本信息严格一致：
   - `Info.plist`（`CFBundleShortVersionString` 与 `CFBundleVersion`）
   - `CHANGELOG.md` 顶端版本标题与发布日期
   - Git Tag（带注释的 Tag，如 `git tag -a v1.0.0 -m "Release v1.0.0"`）

---

## 🧪 四、全量自动化测试与质量门禁 (Pre-Release Quality Gates)

在执行任何发布构建（Release Build）前，**必须无条件通过全部自动化测试门禁**，任何单一测试失败立即熔断，严禁带病发布：

```bash
# 1. 执行全量单元测试（必须 100% 通过，0 failures）
swift test

# 2. 自动化打包与签名验证门禁
./scripts/build_app.sh
```

### 质量验收标准：
1. **测试用例 100% 绿色**：涵盖指标格式化、边界值、轻量/全量采样调度、常亮断言生命周期管理；
2. **编译器状态**：Swift 6 模式下零警告（Zero Warnings）；
3. **签名验证状态**：`codesign --verify --deep --strict --verbose=2` 输出 `valid on disk` 且 `satisfies its Designated Requirement`。

---

## 🔏 五、构建、Apple 签名与安全规范 (Code Signing Standards)

1. **架构原生针对性**：
   - 面向 Apple Silicon (arm64) 架构独立编译生产级可执行文件，开启完整编译器优化（`-O`）。
2. **官方 Developer ID 签名**：
   - 签名证书优先使用官方凭证：`Developer ID Application: YanNan Chen (5984KQD4D7)`；
   - 启用 Hardened Runtime（`--options runtime`）。
3. **安全分发校验**：
   - 每次打包必须同时产出 `.app`、`.tar.gz` 独立包以及 `SHA256SUMS.txt` 校验清单。
