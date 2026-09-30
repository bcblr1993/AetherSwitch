# 1.3.0 在线更新验证

2026-10-01，Apple Silicon（M1 Max）/ macOS 27 本机。

## 构建与门禁
- `swift test`：32 项通过；Debug / Release 零警告；主干 CI 通过（含 CI 上拉取 Sparkle 2.9.6）。
- Developer ID 签名：`Installer.xpc`、`Downloader.xpc`、`Autoupdate`、`Updater.app` → `Sparkle.framework` → 应用，由内到外；`codesign --verify --deep --strict` 通过；DMG 与应用均通过 Apple 公证并 staple，`spctl` 显示 `Notarized Developer ID`。
- 打包自检：`Info.plist` 更新设置齐全、框架已嵌入、`rpath` 指向 `Contents/Frameworks`、`SUPublicEDKey` 与钥匙串私钥一致；故意换成错误公钥时打包失败，不产出 DMG、tar.gz 与校验清单（输出目录只留下未完成的 `.app`）。
- 内存（含已启动的 Sparkle）：弹窗逐页验收连续 5 次，进程峰值 27.7–28.1 MB（v1.2.0 签名版为 27.2–27.8 MB）；90 秒后台验收平均 CPU 0.0019%，后台物理内存峰值 14.5 MB。
- 清单：`generate_appcast.sh` 校验版本、构建号、下载地址、长度，以及包签名与清单签名；用 `sign_update --verify` 独立验证 DMG 签名通过，DMG 末尾追加 1 字节后验证失败。线上 `https://aethernative.com/apps/aetherswitch/appcast.xml`、Release 附件、本机生成文件三者逐字节一致。

## 端到端更新
测试对象是用 v1.3.0 正式产物制作的“低版本测试副本”：仅把 `CFBundleShortVersionString` / `CFBundleVersion` 改为 1.2.99 / 2026093099 后重新签名，放在 `/tmp`，不触碰 `/Applications` 里已安装的应用。它包含更新器，订阅线上真实 HTTPS 清单，不改写清单、不绕过签名。

- 两轮均从 1.2.99 更新到 **1.3.0（构建 2026100101）**：Sparkle 标准窗口显示“AetherSwitch 1.3.0 is now available—you have 1.2.99”，依次完成下载、校验、安装并自动重启。
- 安装后：版本与构建号正确；主程序 SHA256 与发布构建一致；`codesign --deep --strict` 通过；Gatekeeper 显示 `Notarized Developer ID`；新进程仍从原路径启动；无残留的更新辅助进程。
- 这两轮中“Install Update”与“Install & Relaunch”由在屏幕前的使用者手动点击，自动化脚本仅负责触发检查、读取窗口文字和截图；窗口文字为 Sparkle 的英文界面（应用尚未包含 Sparkle 的中文本地化）。

## 篡改清单被拒绝
用本地服务提供一份只改了版本号（1.3.0 → 9.9.9）、未重新签名的清单（测试副本放行了本地回环 HTTP）：

- 对照：提供未篡改的清单时，同一测试副本正常发现 1.3.0，说明测试环境本身可用。
- 篡改后：Sparkle 显示 “Update Error! The update feed is improperly signed and could not be validated.”，只有取消按钮，不提供安装。
- 首次篡改测试因使用者在对照窗口点击了“Install Update”而无效，已作废并重做；上表结果来自重做的一轮。

## 未验证与限制
- 没有验证历史 1.2.0 及更早版本的自更新：它们不含更新器，必须手动安装 1.3.0 一次。只改测试副本版本号不等于验证历史版本。
- 未做“干净机器 + 默认 Gatekeeper 策略”的首次安装验收。
- 未在沙盒、只读位置（App Translocation）或非管理员账户下测试；这些场景下 Sparkle 会给出自己的错误提示，本项目未额外处理。
- 1.3.0 的更新窗口是英文：应用只声明了 `en`，系统按英文处理整个应用，Sparkle 自带的简体中文翻译不会生效。1.3.1 起在 `Info.plist` 声明 `CFBundleLocalizations`（`en`、`zh-Hans`），窗口随系统语言显示中文，验证见下一节。从 1.3.0 升级到 1.3.1 这一步仍由旧版本的英文窗口引导。

# 1.3.1 更新窗口中文与真实历史升级

2026-10-01，同一台机器。

## 真实历史升级：v1.3.0 → v1.3.1
- 对象是 GitHub 上**真实发布**的 v1.3.0：下载 DMG（SHA256 `c5c8d229…` 与发布一致），取出应用，不做任何修改，签名完好、Gatekeeper 显示 `Notarized Developer ID`，放在 `/tmp`。这不是改版本号的测试副本，补上了前文“未验证历史版本自更新”中 1.3.0 → 新版本的部分（1.2.0 及更早版本仍需手动安装）。
- 订阅线上真实清单：窗口显示 “AetherSwitch 1.3.1 is now available—you have 1.3.0”（旧版本为英文，符合预期）→ “Downloading update… 179 KB of 1.9 MB” → “Ready to Install / Install and Relaunch” → 重启。
- 升级后：版本 1.3.1 / 构建 2026100102；主程序 SHA256 与发布的 v1.3.1 一致；`codesign --deep --strict` 通过；Gatekeeper 显示 `Notarized Developer ID`；`CFBundleLocalizations` 为 `en`、`zh-Hans`。

## 更新窗口中文
- 根因：应用只声明 `en`，系统按英文处理整个应用，`Sparkle.framework` 自带的 `zh_CN` 翻译不生效。`CFBundleLocalizations` 增加 `zh-Hans` 后生效，中文系统（`zh-Hans-CN`）下窗口为中文。
- 用 v1.3.1 正式产物仅把版本号降到 1.3.0 的副本，对线上真实清单检查，全程为中文：“新版本的AetherSwitch已经发布 / AetherSwitch 1.3.1可供下载，您现在的版本是1.3.0。要现在下载吗？”（稍后提醒我、安装更新、跳过这个版本）→ “正在下载更新… 672 KB / 1.9 MB” → “可以开始安装了 / 安装并重启应用” → 重启后版本 1.3.1，二进制与发布一致，签名与 Gatekeeper 通过。
- 打包自检：必须声明 `zh-Hans` 且框架含 `zh_CN` 资源；用去掉声明的构建验证，打包会失败。

## 关于点击的说明
本轮的“安装更新”由辅助功能脚本点击（回显 `clicked`）。点击“安装并重启”后应用会立即退出，辅助功能调用因连接中断报错，脚本回显为 `none`，所以这一下无法用回显单独证明；两次重启都发生在点击之后数秒内。由于使用者当时在屏幕前，不能排除其同时点击。其余观察（窗口文字、下载进度、最终版本、哈希、签名）均由脚本读取或命令核对。
