#!/bin/bash
set -euo pipefail

# ==============================================================================
# AetherSwitch 发版前只读预检门禁脚本 (Preflight Check)
#
# 用法:
#   ./scripts/preflight_check.sh [--allow-dirty] [--require-main]
#
# 只读检查项（绝不修改仓库或系统状态）：
#   1. Git 工作区干净状态（默认要求干净，开发期自检可传 --allow-dirty）
#   2. scripts/build_app.sh 的 VERSION / BUILD_NUMBER 与 CHANGELOG.md 顶部标题严格对齐
#   3. BUILD_NUMBER 严格大于 outputs/build-* 历史最大构建号（单调递增）
#   4. Developer ID Application 证书与钥匙串 AetherSwitch Sparkle 私钥可用且匹配公钥
#   5. 根分区可用磁盘空间充足（默认 >= 5 GiB，可通过 MIN_FREE_GIB 覆盖）
# ==============================================================================

ALLOW_DIRTY=0
REQUIRE_MAIN=0

usage() {
    cat <<'EOF'
Usage: ./scripts/preflight_check.sh [--allow-dirty] [--require-main]

Options:
  --allow-dirty   允许存在未提交的工作区改动（供开发/集成期只读自检）
  --require-main  额外强制当前 Git 分支必须为 main 或 master
  -h, --help      显示帮助信息
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --require-main)
            REQUIRE_MAIN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ 未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

BUILD_SCRIPT="$PROJECT_DIR/scripts/build_app.sh"
CHANGELOG_FILE="$PROJECT_DIR/CHANGELOG.md"
OUTPUTS_ROOT="${OUTPUTS_ROOT:-$PROJECT_DIR/outputs}"
MIN_FREE_GIB="${MIN_FREE_GIB:-5}"

echo "==> [1/5] 检查 Git 工作区与分支状态..."
CURRENT_BRANCH="$(git branch --show-current || true)"
if [ "$REQUIRE_MAIN" -eq 1 ]; then
    case "$CURRENT_BRANCH" in
        main|master) ;;
        *)
            echo "❌ 当前分支为 '${CURRENT_BRANCH:-detached}'，正式发布要求位于 main 或 master" >&2
            exit 1
            ;;
    esac
fi

DIRTY_STATUS="$(git status --porcelain)"
if [ -n "$DIRTY_STATUS" ]; then
    if [ "$ALLOW_DIRTY" -eq 1 ]; then
        echo "   ⚠️  工作区存在未提交改动 (--allow-dirty 已放行，分支: ${CURRENT_BRANCH:-detached})"
    else
        echo "❌ Git 工作区存在未提交改动（开发期自检可传 --allow-dirty）：" >&2
        printf '%s\n' "$DIRTY_STATUS" >&2
        exit 1
    fi
else
    case "$CURRENT_BRANCH" in
        main|master)
            echo "   ✓ Git 工作区干净 (分支: $CURRENT_BRANCH)"
            ;;
        *)
            echo "   ✓ Git 工作区干净 (当前分支: ${CURRENT_BRANCH:-detached}；注: build_app.sh 正式构建时要求 main/master)"
            ;;
    esac
fi

echo "==> [2/5] 检查构建脚本版本号与 CHANGELOG.md 顶部标题对齐..."
test -f "$BUILD_SCRIPT" || { echo "❌ 缺少构建脚本: $BUILD_SCRIPT" >&2; exit 1; }
test -f "$CHANGELOG_FILE" || { echo "❌ 缺少变更日志: $CHANGELOG_FILE" >&2; exit 1; }

VERSION="$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$BUILD_SCRIPT" | head -n 1)"
BUILD_NUMBER="$(sed -n 's/^BUILD_NUMBER="\([^"]*\)"$/\1/p' "$BUILD_SCRIPT" | head -n 1)"
SPARKLE_PUBLIC_ED_KEY="$(sed -n 's/^SPARKLE_PUBLIC_ED_KEY="\([^"]*\)"$/\1/p' "$BUILD_SCRIPT" | head -n 1)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ scripts/build_app.sh 中 VERSION 格式非法: '${VERSION}'" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]{10}$ ]]; then
    echo "❌ scripts/build_app.sh 中 BUILD_NUMBER 必须为 10 位 YYYYMMDDNN 数字，当前: '${BUILD_NUMBER}'" >&2
    exit 1
fi
if [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; then
    echo "❌ scripts/build_app.sh 中未找到 SPARKLE_PUBLIC_ED_KEY" >&2
    exit 1
fi

TOP_HEADING="$(grep -m 1 -E '^## \[' "$CHANGELOG_FILE" || true)"
if [ -z "$TOP_HEADING" ]; then
    echo "❌ CHANGELOG.md 中未找到 '## [x.y.z]' 版本标题" >&2
    exit 1
fi

if [[ "$TOP_HEADING" =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+)\]\ -\ ([0-9]{4}-[0-9]{2}-[0-9]{2})(\ \(Build\ ([0-9]{10})\))?$ ]]; then
    CHANGELOG_VERSION="${BASH_REMATCH[1]}"
    CHANGELOG_DATE="${BASH_REMATCH[2]}"
    CHANGELOG_BUILD="${BASH_REMATCH[4]:-}"
else
    echo "❌ CHANGELOG.md 顶部版本标题格式不符合规范: '$TOP_HEADING'" >&2
    echo "   期望格式: ## [MAJOR.MINOR.PATCH] - YYYY-MM-DD 或 ## [MAJOR.MINOR.PATCH] - YYYY-MM-DD (Build YYYYMMDDNN)" >&2
    exit 1
fi

if [ "$CHANGELOG_VERSION" != "$VERSION" ]; then
    echo "❌ 版本号未对齐: build_app.sh VERSION=${VERSION}, CHANGELOG.md 顶部版本=${CHANGELOG_VERSION}" >&2
    exit 1
fi
if [ -n "$CHANGELOG_BUILD" ] && [ "$CHANGELOG_BUILD" != "$BUILD_NUMBER" ]; then
    echo "❌ 构建号未对齐: build_app.sh BUILD_NUMBER=${BUILD_NUMBER}, CHANGELOG.md 顶部 Build=${CHANGELOG_BUILD}" >&2
    exit 1
fi
echo "   ✓ 版本对齐通过: v${VERSION} (Build ${BUILD_NUMBER}, CHANGELOG 日期 ${CHANGELOG_DATE})"

echo "==> [3/5] 检查 BUILD_NUMBER 单调递增基线..."
MAX_HIST_BUILD=""
if [ -d "$OUTPUTS_ROOT" ]; then
    for dir in "$OUTPUTS_ROOT"/build-*; do
        [ -d "$dir" ] || continue
        base="$(basename "$dir")"
        num="${base#build-}"
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            if [ -z "$MAX_HIST_BUILD" ] || (( 10#$num > 10#$MAX_HIST_BUILD )); then
                MAX_HIST_BUILD="$num"
            fi
        fi
    done
fi

if [ -n "$MAX_HIST_BUILD" ]; then
    if (( 10#$BUILD_NUMBER <= 10#$MAX_HIST_BUILD )); then
        echo "❌ BUILD_NUMBER (${BUILD_NUMBER}) 必须严格大于历史最大构建号 (${MAX_HIST_BUILD}) [目录: $OUTPUTS_ROOT]" >&2
        exit 1
    fi
    echo "   ✓ 构建号递增通过: ${BUILD_NUMBER} > 历史最大 ${MAX_HIST_BUILD}"
else
    echo "   ✓ 构建号格式有效: ${BUILD_NUMBER} (${OUTPUTS_ROOT} 下无历史 build-* 目录)"
fi

echo "==> [4/5] 检查 Developer ID 签名证书与 Sparkle Ed25519 密钥..."
source "$PROJECT_DIR/scripts/signing_identity.sh"
CERT_NAME="$(resolve_signing_identity)" || {
    echo "❌ 无法解析 Developer ID Application 签名证书" >&2
    exit 1
}
security find-identity -v -p codesigning | grep -Fq "$CERT_NAME" || {
    echo "❌ 钥匙串中未找到有效代码签名身份" >&2
    exit 1
}

SPARKLE_DIR="${SPARKLE_DIR:-$PROJECT_DIR/.build/artifacts/sparkle/Sparkle}"
GENERATE_KEYS="$SPARKLE_DIR/bin/generate_keys"
if [ ! -x "$GENERATE_KEYS" ]; then
    COMMON_GIT_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$COMMON_GIT_DIR" ]; then
        FALLBACK_KEYS="$(cd "$COMMON_GIT_DIR/.." && pwd)/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
        if [ -x "$FALLBACK_KEYS" ]; then
            GENERATE_KEYS="$FALLBACK_KEYS"
        fi
    fi
fi

if [ ! -x "$GENERATE_KEYS" ]; then
    echo "❌ 未找到 Sparkle generate_keys 工具（请先运行 swift package resolve）" >&2
    exit 1
fi

KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" --account AetherSwitch -p 2>/dev/null || true)"
if [ "$KEYCHAIN_PUBLIC_KEY" != "$SPARKLE_PUBLIC_ED_KEY" ]; then
    echo "❌ 钥匙串账户 AetherSwitch 的 Sparkle 公钥与 SUPublicEDKey 不一致或不可访问" >&2
    exit 1
fi
echo "   ✓ Developer ID Application 证书与钥匙串 AetherSwitch Sparkle 密钥校验通过"

echo "==> [5/5] 检查根分区可用磁盘空间 (>= ${MIN_FREE_GIB} GiB)..."
AVAIL_KIB="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ ! "$AVAIL_KIB" =~ ^[0-9]+$ ]]; then
    echo "❌ 无法读取根分区可用空间" >&2
    exit 1
fi
MIN_FREE_KIB=$(( MIN_FREE_GIB * 1024 * 1024 ))
AVAIL_GIB="$(awk -v kib="$AVAIL_KIB" 'BEGIN { printf "%.2f", kib / 1048576 }')"
if (( AVAIL_KIB < MIN_FREE_KIB )); then
    echo "❌ 根分区可用空间不足: 当前 ${AVAIL_GIB} GiB < 门禁要求 ${MIN_FREE_GIB} GiB" >&2
    exit 1
fi
echo "   ✓ 根分区可用空间充足: ${AVAIL_GIB} GiB (门槛 >= ${MIN_FREE_GIB} GiB)"

echo "=============================================================================="
echo "✅ Preflight 预检全部通过 (v${VERSION}, Build ${BUILD_NUMBER})"
echo "=============================================================================="
