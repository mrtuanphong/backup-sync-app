# Backup & Sync

App macOS chỉ có một màn hình, dùng để sao lưu, khôi phục và đồng bộ một thư mục bất kỳ. App chép mọi thứ, kể cả file ẩn, symlink, quyền file và thuộc tính macOS.

## Tính năng

- **Nguồn và Đích**: chọn bằng Finder, có nút đổi chỗ hai thư mục.
- **Kiểu sync**:
  - **Một chiều đi** (sao lưu): tạo `Đích/<tên nguồn>/<ngày_giờ>/` và cập nhật đường tắt `latest`. Giữ 20 bản gần nhất; file không đổi được dùng chung (hard link) nên không tốn thêm chỗ.
  - **Một chiều ngược** (khôi phục): chép từ `latest` về Nguồn những file bị thiếu, hoặc cũ hơn bản sao lưu ít nhất 1 giây và có nội dung khác. Không bao giờ ghi đè file mới hơn, không xoá gì.
  - **Hai chiều**: khôi phục như trên, rồi tạo một bản sao lưu mới.
- **Bỏ qua**: danh sách tên, cách nhau bằng dấu phẩy (ví dụ `node_modules`).
- **Thời điểm**: chạy ngay (xem trước rồi xác nhận), hoặc hẹn giờ mỗi ngày hay mỗi giờ qua launchd. Mỗi lịch giữ nguyên thiết lập tại lúc hẹn và báo thông báo khi chạy xong.

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `src/BackupSync.swift` | Giao diện SwiftUI (một file, chạy trên macOS 13 trở lên) |
| `src/Info.plist` | Thông tin bundle |
| `engine/fs-helper` | Cầu nối giữa app và phần xử lý (Python 3.9, có sẵn trên macOS): thiết lập, chạy, lịch hẹn |
| `engine/folder-backup` | Sao lưu theo phiên bản (bash, dùng rsync/openrsync) |
| `engine/folder-sync` | Đồng bộ hai thư mục A→B, B→A, hai chiều, có nhớ trạng thái (Python). App chưa dùng, có sẵn dạng lệnh |
| `scripts/build.sh` | Build vào `build/` và cài vào `~/Applications` (`--no-install` để chỉ build) |
| `scripts/install-cli.sh` | Cài `folder-sync` và `folder-backup` vào `~/.local/bin` |

## Build

Cần Xcode Command Line Tools (`swiftc`):

```
./scripts/build.sh
```

## Dữ liệu trên máy

- Thiết lập: `~/.config/folder-sync/app.json`
- Lịch hẹn: `~/Library/LaunchAgents/local.backupsync.*.plist`
- Log của các lần chạy theo lịch: `~/Library/Logs/BackupSync/`
- Nhật ký mỗi lần sao lưu: `Đích/<tên nguồn>/.backup-logs/`

## Lệnh dòng lệnh

```
folder-backup --snapshot --keep 20 -x node_modules <nguồn> <đích>
folder-sync -d both <A> <B>        # a2b | b2a | both, -n để chạy thử
```
