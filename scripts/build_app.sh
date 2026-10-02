#!/bin/bash
set -euo pipefail

# ==============================================================================
# AetherSwitch (ControlLite) 构建与发布门禁脚本
# 对齐 AetherRoute / ApexTerm 工程标准 SOP
# ==============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="AetherSwitch"
BUNDLE_ID="com.aethernative.aetherswitch"
VERSION="1.5.0"
BUILD_NUMBER="2026100205"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/outputs/build-${BUILD_NUMBER}}"
# 在线更新（Sparkle）：清单地址与更新签名公钥。公钥可公开，对应私钥只存在发布者的登录钥匙串（账户 AetherSwitch）。
SPARKLE_FEED_URL="https://aethernative.com/apps/aetherswitch/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="Ks+dYalMGrthBEP6rSTv8Cjs9Um5R9a5VO6cXH6tDq0="
SPARKLE_DIR="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle"
source "$PROJECT_DIR/scripts/signing_identity.sh"
CERT_NAME="$(resolve_signing_identity)" || { echo "Required Developer ID certificate is unavailable"; exit 1; }

# 正式构建只接受已提交的主干源码与分发证书，失败时不生成半成品。
RELEASE_BRANCH="$(git branch --show-current)"
case "$RELEASE_BRANCH" in
    main|master) ;;
    *) echo "Release build requires main or master (current: $RELEASE_BRANCH)"; exit 1 ;;
esac
test -z "$(git status --porcelain)" || { echo "Release build requires a clean working tree"; exit 1; }
test ! -e "$OUTPUT_DIR" || { echo "Output already exists: $OUTPUT_DIR"; exit 1; }
security find-identity -v -p codesigning | grep -q "$CERT_NAME" || { echo "Required Developer ID certificate is unavailable"; exit 1; }

# 保留旧候选包与校验清单，供发布验收和回退使用。

# SwiftPM 的编译中间产物会随反复构建累积；每次从干净的编译目录开始。
# 仅触碰本项目 .build/out，保留 SwiftPM 的依赖与工作区元数据。
SWIFT_BUILD_OUTPUT="$PROJECT_DIR/.build/out"
if [ -d "$SWIFT_BUILD_OUTPUT" ] && [ ! -L "$SWIFT_BUILD_OUTPUT" ]; then
    rm -r -- "$SWIFT_BUILD_OUTPUT"
fi

echo "==> [1/5] 执行全量单元测试与质量门禁..."
swift test

echo "==> [2/5] 编译生产环境 Release 二进制 (Apple Silicon arm64)..."
swift build -c release --arch arm64

echo "==> [3/5] 组装 macOS App Bundle..."
mkdir -p "$OUTPUT_DIR/${APP_NAME}.app/Contents/MacOS"
mkdir -p "$OUTPUT_DIR/${APP_NAME}.app/Contents/Resources"

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_DIR/ControlLite" "$OUTPUT_DIR/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# 嵌入 Sparkle.framework（可执行文件的 rpath 指向 Contents/Frameworks）与许可证
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE_FRAMEWORK" || { echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK (run swift package resolve)"; exit 1; }
mkdir -p "$OUTPUT_DIR/${APP_NAME}.app/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$OUTPUT_DIR/${APP_NAME}.app/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIR/LICENSE" "$OUTPUT_DIR/${APP_NAME}.app/Contents/Resources/Sparkle-LICENSE"

# 生成生产级 Info.plist
cat <<EOF > "$OUTPUT_DIR/${APP_NAME}.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AetherSwitch 通过系统事件切换 macOS 的浅色与深色外观。</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_ED_KEY}</string>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUEnableSystemProfiling</key>
    <false/>
    <key>SUShowReleaseNotes</key>
    <false/>
</dict>
</plist>
EOF

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$OUTPUT_DIR/${APP_NAME}.app/Contents/Resources/AppIcon.icns"
fi

echo "==> [4/5] 执行代码签名与完整性校验..."
echo "使用官方证书签名: $CERT_NAME"
# 由内到外签名：先签 Sparkle 的辅助程序与框架，最后签应用本体（不使用 --deep，避免把应用的权限声明套到内嵌代码上）。
SPARKLE_EMBEDDED="$OUTPUT_DIR/${APP_NAME}.app/Contents/Frameworks/Sparkle.framework"
for COMPONENT in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --timestamp --options runtime --sign "$CERT_NAME" "$SPARKLE_EMBEDDED/Versions/B/$COMPONENT"
done
codesign --force --timestamp --options runtime --sign "$CERT_NAME" "$SPARKLE_EMBEDDED"
codesign --force --timestamp --options runtime --entitlements "$PROJECT_DIR/Resources/AetherSwitch.entitlements" --sign "$CERT_NAME" "$OUTPUT_DIR/${APP_NAME}.app"

codesign --verify --deep --strict --verbose=2 "$OUTPUT_DIR/${APP_NAME}.app"

# 在线更新链路自检：任何一项缺失或不匹配，已安装的用户就无法再在线升级，必须在发布前发现。
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"
for KEY in SUFeedURL SUPublicEDKey SURequireSignedFeed SUVerifyUpdateBeforeExtraction CFBundleLocalizations; do
    /usr/libexec/PlistBuddy -c "Print :$KEY" "$APP_BUNDLE/Contents/Info.plist" >/dev/null || { echo "Info.plist is missing $KEY"; exit 1; }
done
# 应用必须声明支持简体中文，否则系统把整个应用按英文处理，Sparkle 自带的中文翻译不会生效（更新窗口会显示英文）。
/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$APP_BUNDLE/Contents/Info.plist" | grep -q "zh-Hans" || { echo "Info.plist does not declare zh-Hans localization"; exit 1; }
test -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/zh_CN.lproj" || { echo "Sparkle.framework has no zh_CN localization"; exit 1; }
test -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" || { echo "Sparkle.framework is not embedded"; exit 1; }
otool -l "$APP_BUNDLE/Contents/MacOS/${APP_NAME}" | grep -q "@executable_path/../Frameworks" || { echo "Executable has no rpath to Contents/Frameworks"; exit 1; }
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account AetherSwitch -p 2>/dev/null || true)"
[ "$KEYCHAIN_PUBLIC_KEY" = "$SPARKLE_PUBLIC_ED_KEY" ] || { echo "SUPublicEDKey does not match the AetherSwitch signing key in the keychain"; exit 1; }
echo "Update configuration verified (feed, public key, framework, rpath, zh-Hans localization)."

echo "==> [5/5] 生成 DMG 安装包与发布校验清单 SHA256SUMS.txt..."
cd "$OUTPUT_DIR"
tar -czf "${APP_NAME}-${VERSION}-arm64.tar.gz" "${APP_NAME}.app"

DMG_ROOT="$(mktemp -d /tmp/aetherswitch-dmg.XXXXXX)"
mkdir -p "$DMG_ROOT"
cp -R "${APP_NAME}.app" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName "$APP_NAME" --format UDZO "$DMG_ROOT" "${APP_NAME}-${VERSION}-arm64.dmg"
else
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -format UDZO "${APP_NAME}-${VERSION}-arm64.dmg"
fi
rm -rf "$DMG_ROOT"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    codesign --force --timestamp --sign "$CERT_NAME" "${APP_NAME}-${VERSION}-arm64.dmg"
fi

shasum -a 256 "${APP_NAME}-${VERSION}-arm64.dmg" "${APP_NAME}-${VERSION}-arm64.tar.gz" > SHA256SUMS.txt

echo "=============================================================================="
echo "✅ 构建完成！产物路径："
echo "   App Bundle:  $OUTPUT_DIR/${APP_NAME}.app"
echo "   DMG Package: $OUTPUT_DIR/${APP_NAME}-${VERSION}-arm64.dmg"
echo "   Archive:     $OUTPUT_DIR/${APP_NAME}-${VERSION}-arm64.tar.gz"
echo "   Checksums: "
cat "$OUTPUT_DIR/SHA256SUMS.txt"
echo "   App Size:    $(du -sh "$OUTPUT_DIR/${APP_NAME}.app" | cut -f1)"
echo "=============================================================================="
