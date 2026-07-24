#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="CodexQuotaMenuBar"
APP_DIR="$SCRIPT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$SCRIPT_DIR/.build_cache"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/codex.png" "$RESOURCES_DIR/codex.png"

swiftc \
  -O \
  -module-cache-path "$SCRIPT_DIR/.build_cache" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  "$SCRIPT_DIR/CodexQuotaMenuBar.swift" \
  -o "$MACOS_DIR/$APP_NAME"

chmod +x "$MACOS_DIR/$APP_NAME"
echo "$APP_DIR"
