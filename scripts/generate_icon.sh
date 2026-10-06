#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/design/logo-v2.png}"
SOURCE="$(mktemp /tmp/aetherswitch-icon.XXXXXX.swift)"
trap 'rm -f "$SOURCE"' EXIT
cat "$ROOT/Sources/ControlLite/UI/BrandGlyph.swift" "$ROOT/scripts/generate_icon.swift" > "$SOURCE"
swift "$SOURCE" "$OUT"
