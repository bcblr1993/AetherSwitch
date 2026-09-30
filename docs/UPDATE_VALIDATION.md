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
