#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_PATH="$OUTPUT_DIR/AetherSwitch.app"
DMG_PATH="$OUTPUT_DIR/AetherSwitch-1.0.0-arm64.dmg"
TEMP_DMG_DIR="$OUTPUT_DIR/dmg_temp"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 找不到 $APP_PATH，请先构建"
    exit 1
fi

rm -rf "$TEMP_DMG_DIR" "$DMG_PATH"
mkdir -p "$TEMP_DMG_DIR"

cp -R "$APP_PATH" "$TEMP_DMG_DIR/"
ln -s /Applications "$TEMP_DMG_DIR/Applications"

echo "==> 正在创建 DMG 镜像: $DMG_PATH"
hdiutil create -volname "AetherSwitch" -srcfolder "$TEMP_DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$TEMP_DMG_DIR"

# 签名 DMG
CERT_NAME="Developer ID Application: YanNan Chen (5984KQD4D7)"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "使用官方证书签名 DMG..."
    codesign --force --sign "$CERT_NAME" "$DMG_PATH"
fi

echo "✅ DMG 创建成功: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
