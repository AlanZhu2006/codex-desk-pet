#!/bin/bash
set -euo pipefail
PET_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PET_APPS_DIR="$HOME/Applications"
PET_SHOULD_OPEN=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) PET_SHOULD_OPEN=0; shift ;;
    --destination)
      [[ $# -ge 2 ]] || { echo 'Missing destination directory' >&2; exit 2; }
      PET_APPS_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 [--no-open] [--destination DIRECTORY]" >&2; exit 2 ;;
  esac
done
"$PET_REPO_ROOT/macos/build.sh"
PET_SOURCE="$PET_REPO_ROOT/macos/build/Claude Desktop Pet.app"
PET_TARGET="$PET_APPS_DIR/Claude Desktop Pet.app"
mkdir -p "$PET_APPS_DIR"
if [[ -e "$PET_TARGET" ]]; then
  PET_EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PET_TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$PET_EXISTING_ID" != 'com.alanzhu.claude-desktop-pet' ]]; then
    echo "Refusing to replace a different application: $PET_TARGET" >&2
    exit 1
  fi
  if pgrep -x ClaudeDesktopPet >/dev/null; then
    echo 'Please quit Claude 娘桌宠 from its menu before updating.' >&2
    exit 1
  fi
  PET_BACKUPS_DIR="$HOME/Library/Application Support/Claude Desktop Pet/Backups"
  mkdir -p "$PET_BACKUPS_DIR"
  mv "$PET_TARGET" "$PET_BACKUPS_DIR/Claude Desktop Pet-$(date +%Y%m%dT%H%M%S)-$$.app"
fi
ditto "$PET_SOURCE" "$PET_TARGET"
codesign --verify --deep --strict "$PET_TARGET"
echo "Installed: $PET_TARGET"
if [[ "$PET_SHOULD_OPEN" -eq 1 ]]; then
  open "$PET_TARGET"
fi
