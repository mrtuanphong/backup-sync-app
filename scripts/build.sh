#!/usr/bin/env bash
# Build "Backup & Sync.app" into ./build/ and install it to /Applications (replacing the old copy) (pass --no-install to skip).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Backup & Sync.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
# Universal binary (Apple Silicon + Intel) so the released app runs on any Mac with macOS 13+.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    -o "$TMP/BackupSync-$arch" "$ROOT/src/BackupSync.swift"
done
lipo -create -output "$OUT/Contents/MacOS/BackupSync" "$TMP/BackupSync-arm64" "$TMP/BackupSync-x86_64"
cp "$ROOT/engine/fs-helper" "$ROOT/engine/folder-sync" "$ROOT/engine/folder-backup" "$OUT/Contents/Resources/"
chmod +x "$OUT/Contents/Resources/"{fs-helper,folder-sync,folder-backup}
cp "$ROOT/src/Info.plist" "$OUT/Contents/Info.plist"
# Build number = build time (YYYYMMDD.HHMM), so every build can be told apart in the app and in About.
BUILD="$(date +%Y%m%d.%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$OUT/Contents/Info.plist"
[ -f "$ROOT/src/AppIcon.icns" ] && cp "$ROOT/src/AppIcon.icns" "$OUT/Contents/Resources/"
codesign --force --deep -s - "$OUT" 2>/dev/null
codesign --verify --deep "$OUT"
echo "Built: $OUT (build $BUILD)"
if [[ "${1:-}" != "--no-install" ]]; then
  rm -rf "/Applications/Backup & Sync.app"
  ditto "$OUT" "/Applications/Backup & Sync.app"
  echo "Installed: /Applications/Backup & Sync.app"
fi
