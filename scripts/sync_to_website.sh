#!/bin/bash
set -euo pipefail

# ==============================================================================
# 一键同步 AetherSwitch 软件介绍至 aethernative-site 官网项目
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/../website_content/apps/aetherswitch"
TARGET_DIR="${1:-}"

if [ -z "$TARGET_DIR" ]; then
    # 尝试在周围目录寻找 aethernative-site
    CANDIDATES=(
        "$SCRIPT_DIR/../../aethernative-site"
        "$HOME/aethernative-site"
        "$HOME/Documents/aethernative-site"
        "$HOME/Documents/antigravity/aethernative-site"
    )
    for c in "${CANDIDATES[@]}"; do
        if [ -d "$c/src/content/apps" ]; then
            TARGET_DIR="$c"
            break
        fi
    done
fi

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR/src/content/apps" ]; then
    echo "⚠️  未自动找到 aethernative-site 本地目录。"
    echo "👉 使用方法：./scripts/sync_to_website.sh /path/to/aethernative-site"
    echo ""
    echo "或者直接手动复制本项目的 website_content/apps/aetherswitch 目录到网站仓库的 src/content/apps/ 下。"
    exit 0
fi

DEST="$TARGET_DIR/src/content/apps/aetherswitch"
echo "==> 同步网站资源至: $DEST"
mkdir -p "$DEST"
# 版本记录由官网仓库的 Release 同步工作流维护，这里只同步软件介绍，避免用旧的 releases.yaml 覆盖。
for item in "$SOURCE_DIR"/*; do
    [ "$(basename "$item")" = "releases.yaml" ] && continue
    cp -R "$item" "$DEST/"
done

echo "=============================================================================="
echo "✅ 同步成功！"
echo "   前往网站目录: cd $TARGET_DIR"
echo "   本地开发预览: npm run dev"
echo "   静态构建校验: npm run build"
echo "=============================================================================="
