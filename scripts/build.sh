#!/usr/bin/env bash
# Build "Backup & Sync.app" into ./build/ and install it to ~/Applications (pass --no-install to skip).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Backup & Sync.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  -o "$OUT/Contents/MacOS/BackupSync" "$ROOT/src/BackupSync.swift"
cp "$ROOT/engine/fs-helper" "$ROOT/engine/folder-sync" "$ROOT/engine/folder-backup" "$OUT/Contents/Resources/"
chmod +x "$OUT/Contents/Resources/"{fs-helper,folder-sync,folder-backup}
cp "$ROOT/src/Info.plist" "$OUT/Contents/Info.plist"
[ -f "$ROOT/src/AppIcon.icns" ] && cp "$ROOT/src/AppIcon.icns" "$OUT/Contents/Resources/"
codesign --force --deep -s - "$OUT" 2>/dev/null
codesign --verify --deep "$OUT"
echo "Built: $OUT"
if [[ "${1:-}" != "--no-install" ]]; then
  rm -rf "$HOME/Applications/Backup & Sync.app"
  cp -R "$OUT" "$HOME/Applications/"
  echo "Installed: $HOME/Applications/Backup & Sync.app"
fi
