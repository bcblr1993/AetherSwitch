#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_PNG="$ROOT/website_content/apps/aetherswitch/media/icon.png"
DEFAULT_ICNS="$ROOT/Resources/AppIcon.icns"

MASTER="${1:-$DEFAULT_PNG}"
swift "$ROOT/scripts/generate_icon.swift" \
    --master "$MASTER" \
    --png-out "$DEFAULT_PNG" \
    --icns-out "$DEFAULT_ICNS"
