#!/bin/bash
set -euo pipefail

# ==============================================================================
# AetherSwitch 公证装订与原子发版定稿脚本 (Finalize Release)
#
# 用法:
#   ./scripts/finalize_release.sh <build-dir> [--notary-profile <profile>]
#
# 原子执行顺序（消除公证/staple 前后 SHA256SUMS.txt 哈希失配窗口）：
#   1. 提交 DMG 至 Apple Notary Service 等待公证结果，写入 acceptance/notarization.json 并校验 Accepted
#   2. 对 AetherSwitch.app 与 DMG 分别执行 stapler staple / validate，并执行 spctl Gatekeeper 校验
#   3. 使用已 staple 的 AetherSwitch.app 重新打包 AetherSwitch-<VERSION>-arm64.tar.gz
#   4. 在全部二进制定稿后重新计算并原子覆盖最终 SHA256SUMS.txt（含立即回读自检）
#   5. 调用 ./scripts/generate_appcast.sh <build-dir> 生成并验签 appcast.xml
# ==============================================================================

usage() {
    cat <<'EOF'
Usage: ./scripts/finalize_release.sh <build-dir> [--notary-profile <profile>]

Arguments:
  <build-dir>                 构建产物目录（如 outputs/build-2026112301）

Options:
  --notary-profile <profile>  notarytool 钥匙串配置名（默认读取 AETHERSWITCH_NOTARY_PROFILE 或 AetherRoute-Notary）
  -h, --help                  显示帮助信息
EOF
}

BUILD_DIR_ARG=""
NOTARY_PROFILE="${AETHERSWITCH_NOTARY_PROFILE:-AetherRoute-Notary}"

while [ $# -gt 0 ]; do
    case "$1" in
        --notary-profile)
            [ $# -ge 2 ] || { echo "❌ --notary-profile 缺少参数值" >&2; usage >&2; exit 2; }
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notary-profile=*)
            NOTARY_PROFILE="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "❌ 未知选项: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$BUILD_DIR_ARG" ]; then
                echo "❌ 多余的位置参数: $1" >&2
                usage >&2
                exit 2
            fi
            BUILD_DIR_ARG="$1"
            shift
            ;;
    esac
done

if [ -z "$BUILD_DIR_ARG" ]; then
    echo "❌ 必须指定 <build-dir>" >&2
    usage >&2
    exit 2
fi
if [ -z "$NOTARY_PROFILE" ]; then
    echo "❌ notary profile 不能为空" >&2
    exit 2
fi
if [ ! -d "$BUILD_DIR_ARG" ]; then
    echo "❌ 构建目录不存在: $BUILD_DIR_ARG" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(cd "$BUILD_DIR_ARG" && pwd)"
APP_NAME="AetherSwitch"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

test -d "$APP_BUNDLE" || { echo "❌ 未找到应用包: $APP_BUNDLE" >&2; exit 1; }
test -f "$INFO_PLIST" || { echo "❌ 未找到 Info.plist: $INFO_PLIST" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_NAME="${APP_NAME}-${VERSION}-arm64.dmg"
TAR_NAME="${APP_NAME}-${VERSION}-arm64.tar.gz"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TAR_PATH="$BUILD_DIR/$TAR_NAME"
ACCEPTANCE_DIR="$BUILD_DIR/acceptance"
NOTARY_JSON="$ACCEPTANCE_DIR/notarization.json"

test -f "$DMG_PATH" || { echo "❌ 未找到 DMG 安装包: $DMG_PATH" >&2; exit 1; }

cleanup_tmp() {
    rm -f -- \
        "$NOTARY_JSON.tmp" \
        "$TAR_PATH.tmp" \
        "$BUILD_DIR/SHA256SUMS.txt.tmp"
}
trap cleanup_tmp EXIT

echo "==> [0/5] 校验待公证应用签名完整性 (v${VERSION}, Build ${BUILD_NUMBER})..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> [1/5] 提交 DMG 至 Apple Notary Service (Profile: ${NOTARY_PROFILE})..."
mkdir -p "$ACCEPTANCE_DIR"
if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$NOTARY_JSON.tmp"; then
    mv -f "$NOTARY_JSON.tmp" "$NOTARY_JSON"
else
    NOTARY_EXIT=$?
    if [ -s "$NOTARY_JSON.tmp" ]; then
        mv -f "$NOTARY_JSON.tmp" "$NOTARY_JSON"
    fi
    echo "❌ notarytool submit 执行失败 (exit $NOTARY_EXIT)" >&2
    if [ -f "$NOTARY_JSON" ]; then
        cat "$NOTARY_JSON" >&2
    fi
    exit "$NOTARY_EXIT"
fi

python3 - "$NOTARY_JSON" "$NOTARY_PROFILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
profile = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
status = data.get("status")
sub_id = data.get("id", "unknown")
message = data.get("message", "")
if status != "Accepted":
    print(f"❌ 公证未通过: status={status!r}, id={sub_id}, message={message!r}", file=sys.stderr)
    if sub_id and sub_id != "unknown":
        print(f"👉 查看详细日志: xcrun notarytool log {sub_id} --keychain-profile {profile}", file=sys.stderr)
    raise SystemExit(1)
print(f"   ✓ Apple 公证通过: status={status}, id={sub_id}")
PY

echo "==> [2/5] 装订公证票据 (Staple) 并执行 Gatekeeper 校验..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -t exec -vv "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> [3/5] 使用已装订公证票据的 ${APP_NAME}.app 重新打包归档..."
(
    cd "$BUILD_DIR"
    tar -czf "${TAR_NAME}.tmp" "${APP_NAME}.app"
    mv -f "${TAR_NAME}.tmp" "$TAR_NAME"
)

echo "==> [4/5] 重新计算并写入最终 SHA256SUMS.txt..."
(
    cd "$BUILD_DIR"
    shasum -a 256 "$DMG_NAME" "$TAR_NAME" > SHA256SUMS.txt.tmp
    shasum -a 256 -c SHA256SUMS.txt.tmp >/dev/null
    mv -f SHA256SUMS.txt.tmp SHA256SUMS.txt
)

echo "==> [5/5] 生成并验签 Sparkle appcast.xml..."
"$PROJECT_DIR/scripts/generate_appcast.sh" "$BUILD_DIR"
test -f "$BUILD_DIR/appcast.xml" || { echo "❌ appcast.xml 未生成" >&2; exit 1; }

echo "=============================================================================="
echo "✅ 正式发版产物定稿完成！(v${VERSION}, Build ${BUILD_NUMBER})"
echo "   App Bundle:    $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | cut -f1))"
echo "   Notarized DMG: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
echo "   Stapled Tar:   $TAR_PATH ($(du -sh "$TAR_PATH" | cut -f1))"
echo "   Sparkle Feed:  $BUILD_DIR/appcast.xml"
echo "   Notarization:  $NOTARY_JSON"
echo "   SHA256SUMS.txt (最终定稿校验和):"
cat "$BUILD_DIR/SHA256SUMS.txt"
echo "=============================================================================="
