#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$("$SCRIPT_DIR/build.sh")"
"$APP_DIR/Contents/MacOS/CodexQuotaMenuBar"
