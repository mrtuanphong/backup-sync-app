# Backup & Sync — notes for Claude

Standalone macOS app (owner: Phong). Read README.md first.

## Architecture
- UI: `src/BackupSync.swift` (SwiftUI, single window, built with `swiftc -swift-version 5 -parse-as-library`, macOS 13+).
  It shells out to `/usr/bin/python3 Contents/Resources/fs-helper <cmd>`.
- `engine/fs-helper` (Python 3.9 — system python, no third-party modules): settings (`get`/`set`), `run [--dry-run]
  [--notify] [--cfg JSON]`, `schedule-add daily HH:MM | hourly MM`, `schedule-list`, `schedule-remove LABEL`.
- `engine/folder-backup` (bash 3.2 — macOS default; mind `set -u` with empty arrays): versioned snapshots via
  `rsync --link-dest`. macOS rsync is **openrsync**: it truncates mtimes to whole seconds.
- `engine/folder-sync` (Python): two-way sync engine with per-machine state; not wired into the UI yet.

## Rules learned the hard way
- Never overwrite a newer file on restore. Restore copies only missing files, or files whose source mtime is at least
  1 s older than the backup **and** whose content differs (same-second edits keep the source).
- Equal size + equal second is not proof of equal content — compare bytes before deciding.
- Dry-run must not create anything (the helper used to create the destination folder on preview).
- The user wants backups of everything, hidden files included; only `node_modules` is excluded by default.
- Do not delete at the top level of a mounted drive; the user confirms destructive actions.

## Build & test
`./scripts/build.sh` (installs to /Applications, replacing the old copy; CFBundleVersion = build time YYYYMMDD.HHMM, shown in the app footer). Test the engine against folders in a temp directory with
`HOME=<tmp>/home` so settings and schedules do not touch the user's real ones; remove any test launchd job afterwards.
