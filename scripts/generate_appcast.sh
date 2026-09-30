#!/bin/bash
set -euo pipefail

# ==============================================================================
# 生成并校验 Sparkle 签名更新清单 appcast.xml
#
# 用法: ./scripts/generate_appcast.sh outputs/build-<构建号>
#
# 必须在 DMG 已公证并 staple 之后运行：更新签名覆盖的是最终 DMG 的字节内容。
# 私钥只存在发布者登录钥匙串的 AetherSwitch 账户里（generate_keys --account AetherSwitch）；
# CI 等无钥匙串环境可通过环境变量 SPARKLE_PRIVATE_KEY 提供。
# 产物 appcast.xml 写入构建目录，随 DMG、SHA256SUMS.txt 一起上传到 GitHub Release；
# 官网同步工作流会把它原样镜像到 https://aethernative.com/apps/aetherswitch/appcast.xml，
# 切勿手改已签名的清单，改动后必须重新生成。
# ==============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: generate_appcast.sh outputs/build-<build number>}"
OUT="$(cd "$OUT" && pwd)"
APP="$OUT/AetherSwitch.app"
GENERATOR="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

test -x "$GENERATOR" || { echo "generate_appcast not found: run swift package resolve"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT/AetherSwitch-$VERSION-arm64.dmg"
test -f "$DMG" || { echo "DMG not found: $DMG"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null || { echo "DMG is not notarized and stapled yet: $DMG"; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/aetherswitch-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/"

ARGS=(--download-url-prefix "https://github.com/bcblr1993/AetherSwitch/releases/download/v$VERSION/" "$STAGE")
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATOR" --ed-key-file - "${ARGS[@]}"
else
    "$GENERATOR" --account AetherSwitch "${ARGS[@]}"
fi
cp "$STAGE/appcast.xml" "$OUT/appcast.xml"

python3 - "$OUT/appcast.xml" "$VERSION" "$BUILD" "$DMG" <<'PY'
import os, sys, xml.etree.ElementTree as E
path, version, build, dmg = sys.argv[1:]
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = E.parse(path).findall('./channel/item')
assert len(items) == 1, f'appcast must contain exactly one item, found {len(items)}'
item = items[0]
assert item.findtext('s:shortVersionString', namespaces=ns) == version, 'shortVersionString mismatch'
assert item.findtext('s:version', namespaces=ns) == build, 'build (sparkle:version) mismatch'
enclosure = item.find('enclosure')
assert enclosure.get('{' + ns['s'] + '}edSignature'), 'missing archive edSignature'
assert int(enclosure.get('length')) == os.path.getsize(dmg), 'enclosure length does not match the DMG'
expected = f'https://github.com/bcblr1993/AetherSwitch/releases/download/v{version}/AetherSwitch-{version}-arm64.dmg'
assert enclosure.get('url') == expected, f'unexpected download URL: {enclosure.get("url")}'
text = open(path, encoding='utf-8').read()
assert '<!-- sparkle-signatures:' in text and 'edSignature:' in text.rsplit('<!-- sparkle-signatures:', 1)[1], 'appcast itself is not signed'
print(f'Appcast verified: {version} (build {build}), archive signature and feed signature present.')
PY
echo "==> $OUT/appcast.xml"
