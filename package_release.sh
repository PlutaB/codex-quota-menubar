#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.0.0"
APP_DIR="$("$SCRIPT_DIR/build.sh")"
DIST_DIR="$SCRIPT_DIR/dist"
PACKAGE_DIR="$DIST_DIR/CodexQuotaMenuBar-$VERSION"
ZIP_PATH="$DIST_DIR/CodexQuotaMenuBar-$VERSION-macOS.zip"

mkdir -p "$PACKAGE_DIR"

ditto "$APP_DIR" "$PACKAGE_DIR/CodexQuotaMenuBar.app"

cat > "$PACKAGE_DIR/README.txt" <<'README'
Codex Quota Menu Bar

Install:
1. Move CodexQuotaMenuBar.app to Applications, or any stable folder.
2. Double-click the app.
3. Look for the quota indicator in the macOS menu bar.

Use "Displayed windows" in the menu to choose which quota windows appear in the indicator (up to two).

The app reads local Codex session logs from ~/.codex and does not use the network or an API key.

Start at Login is enabled by default. Click the menu bar item and toggle "Start at Login" to turn it on or off.

If macOS blocks the app because it is from an unidentified developer, right-click the app, choose Open, then confirm.
README

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$PACKAGE_DIR/CodexQuotaMenuBar.app" >/dev/null 2>&1 || true
fi

(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "CodexQuotaMenuBar-$VERSION" "$ZIP_PATH"
)

echo "$ZIP_PATH"
