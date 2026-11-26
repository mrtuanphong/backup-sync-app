#!/usr/bin/env bash
# Install the command-line tools (folder-sync, folder-backup) into ~/.local/bin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$ROOT/engine/folder-sync" "$HOME/.local/bin/folder-sync"
install -m 755 "$ROOT/engine/folder-backup" "$HOME/.local/bin/folder-backup"
echo "Installed folder-sync and folder-backup to ~/.local/bin"
