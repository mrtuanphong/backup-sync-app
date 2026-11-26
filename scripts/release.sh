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

Cần máy Mac chạy **macOS 13 (Ventura) trở lên**.

1. Bấm vào file **$(basename "$ZIP")** ở mục *Assets* bên dưới để tải.
2. Mở file zip vừa tải (thường nằm trong **Downloads**), sẽ thấy app **Backup & Sync**.
3. Kéo app vào thư mục **Applications** rồi mở app từ đó.

> [!IMPORTANT]
> **Lần mở đầu tiên, bạn phải bấm "Open Anyway" trong System Settings.**
> App không tải từ App Store nên macOS sẽ báo *"Backup & Sync" Not Opened*. Đây là cảnh báo bình thường, không phải lỗi hay virus.
> 1. Bấm **Done** để đóng thông báo.
> 2. Mở **System Settings → Privacy & Security**, kéo xuống mục **Security**.
> 3. Bấm **Open Anyway**, nhập mật khẩu máy, rồi bấm **Open Anyway** lần nữa.
>
> Chỉ cần làm một lần.

Nếu máy hỏi cài **Command Line Tools** thì bấm **Install** và chờ cài xong. App cần công cụ miễn phí này của Apple để chạy.

Hướng dẫn sử dụng đầy đủ: https://github.com/mrtuanphong/backup-sync-app#cách-dùng

<sub>SHA-256: \`$SHA\`</sub>
EOF
)"

git push origin HEAD
gh release create "$TAG" "$ZIP" --title "Backup & Sync $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)" ${1:+"$1"}
echo "Released $TAG"
