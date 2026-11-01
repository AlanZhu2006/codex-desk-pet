#!/bin/bash
set -euo pipefail

PET_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PET_BUILD_DIR="$PET_REPO_ROOT/macos/build"
if [[ $# -gt 0 ]]; then
  if [[ "$1" != "--output-dir" || $# -ne 2 ]]; then
    echo "Usage: $0 [--output-dir DIRECTORY]" >&2
    exit 2
  fi
  PET_BUILD_DIR="$2"
fi
mkdir -p "$PET_BUILD_DIR"
PET_BUILD_DIR="$(cd "$PET_BUILD_DIR" && pwd)"
PET_APP_PATH="$PET_BUILD_DIR/Claude Desktop Pet.app"
PET_WORK_DIR="$(mktemp -d "$PET_BUILD_DIR/.compile.XXXXXX")"
trap 'rm -rf "$PET_WORK_DIR"' EXIT
PET_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

for PET_ARCH in arm64 x86_64; do
  xcrun swiftc -parse-as-library -swift-version 5 -O \
    -sdk "$PET_SDK_PATH" -target "$PET_ARCH-apple-macos12.0" \
    "$PET_REPO_ROOT"/macos/Sources/*.swift \
    -framework AppKit -lsqlite3 -o "$PET_WORK_DIR/$PET_ARCH"
done

mkdir -p "$PET_APP_PATH/Contents/MacOS" "$PET_APP_PATH/Contents/Resources/sprites"
cp "$PET_REPO_ROOT/macos/Info.plist" "$PET_APP_PATH/Contents/Info.plist"
lipo -create "$PET_WORK_DIR/arm64" "$PET_WORK_DIR/x86_64" \
  -output "$PET_APP_PATH/Contents/MacOS/ClaudeDesktopPet"
cp "$PET_REPO_ROOT/macos/Resources/Atlas.png" "$PET_APP_PATH/Contents/Resources/Atlas.png"
cp "$PET_REPO_ROOT/codex/animation.json" "$PET_APP_PATH/Contents/Resources/animation.json"
cp "$PET_REPO_ROOT"/pet/sprites/*.png "$PET_APP_PATH/Contents/Resources/sprites/"
cp "$PET_REPO_ROOT/LICENSE" "$PET_APP_PATH/Contents/Resources/LICENSE"
cp "$PET_REPO_ROOT/codex/SOURCES.md" "$PET_APP_PATH/Contents/Resources/SOURCES.md"
codesign --force --sign - --timestamp=none "$PET_APP_PATH"
codesign --verify --deep --strict "$PET_APP_PATH"
"$PET_APP_PATH/Contents/MacOS/ClaudeDesktopPet" --self-test
echo "$PET_APP_PATH"
