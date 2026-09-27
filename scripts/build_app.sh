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
VERSION="1.0.1"
BUILD_NUMBER="2026092705"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/outputs/build-${BUILD_NUMBER}}"

echo "==> [1/5] 执行全量单元测试与质量门禁..."
swift test

echo "==> [2/5] 编译生产环境 Release 二进制 (Apple Silicon arm64)..."
swift build -c release --arch arm64

echo "==> [3/5] 组装 macOS App Bundle..."
test ! -e "$OUTPUT_DIR" || { echo "Output already exists: $OUTPUT_DIR"; exit 1; }
mkdir -p "$OUTPUT_DIR/${APP_NAME}.app/Contents/MacOS"
mkdir -p "$OUTPUT_DIR/${APP_NAME}.app/Contents/Resources"

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_DIR/ControlLite" "$OUTPUT_DIR/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# 生成生产级 Info.plist
cat <<EOF > "$OUTPUT_DIR/${APP_NAME}.app/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
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
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$OUTPUT_DIR/${APP_NAME}.app/Contents/Resources/AppIcon.icns"
fi

echo "==> [4/5] 执行代码签名与完整性校验..."
CERT_NAME="Developer ID Application: YanNan Chen (5984KQD4D7)"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "使用官方证书签名: $CERT_NAME"
    codesign --force --deep --timestamp --options runtime --sign "$CERT_NAME" "$OUTPUT_DIR/${APP_NAME}.app"
else
    echo "未发现正式证书，使用本地开发签名 (Ad-Hoc)..."
    codesign --force --deep --sign - "$OUTPUT_DIR/${APP_NAME}.app"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT_DIR/${APP_NAME}.app"

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
