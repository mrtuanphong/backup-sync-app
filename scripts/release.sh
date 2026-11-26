#!/usr/bin/env bash
# Build the app and publish it as a GitHub release (tag v<CFBundleShortVersionString> from src/Info.plist).
# Usage: ./scripts/release.sh [--draft]
# Requires: gh (logged in), a clean working tree, and the version bumped in src/Info.plist for each new release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/Info.plist)"
TAG="v$VERSION"
ZIP="build/Backup-and-Sync-$VERSION.zip"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean; commit first." >&2; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; bump CFBundleShortVersionString in src/Info.plist." >&2; exit 1
fi

./scripts/build.sh --no-install
rm -f "$ZIP"
# ditto keeps the bundle's permissions, symlinks and code signature intact (plain zip can break them).
ditto -c -k --sequesterRsrc --keepParent "build/Backup & Sync.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

NOTES="$(cat <<EOF
## Cài đặt

1. Tải **$(basename "$ZIP")** bên dưới, mở file zip.
2. Kéo **Backup & Sync.app** vào thư mục **Applications** rồi mới mở (lịch hẹn giờ ghi nhớ vị trí của app, nên đừng chạy thẳng từ Downloads).
3. Lần mở đầu tiên macOS sẽ chặn vì app chưa được Apple công chứng: vào **System Settings → Privacy & Security**, kéo xuống, bấm **Open Anyway**.
   Hoặc chạy trong Terminal: \`xattr -dr com.apple.quarantine "/Applications/Backup & Sync.app"\`
4. Nếu macOS hỏi cài **Command Line Tools** thì bấm Install (app cần \`python3\` của Apple).

Yêu cầu: macOS 13 trở lên, chip Apple Silicon hoặc Intel.

SHA-256: \`$SHA\`
EOF
)"

git push origin HEAD
gh release create "$TAG" "$ZIP" --title "Backup & Sync $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)" ${1:+"$1"}
echo "Released $TAG"
