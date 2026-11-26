#!/usr/bin/env bash
# Regenerate src/AppIcon.icns (and docs/icon.png) from scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$TMP/icon_1024.png" >/dev/null
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/src/AppIcon.icns"
mkdir -p "$ROOT/docs"; sips -z 256 256 "$TMP/icon_1024.png" --out "$ROOT/docs/icon.png" >/dev/null
echo "Wrote src/AppIcon.icns and docs/icon.png"
