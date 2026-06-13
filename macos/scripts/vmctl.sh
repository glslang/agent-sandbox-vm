#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/macos"
BIN="$PACKAGE_DIR/.build/release/vmctl"
SOURCE="$PACKAGE_DIR/Sources/vmctl/main.swift"
ENTITLEMENTS="$PACKAGE_DIR/vmctl.entitlements"
BUILD_SCRIPT="$SCRIPT_DIR/Build-vmctl.sh"

if [[ ! -x "$BIN" || "$SOURCE" -nt "$BIN" || "$PACKAGE_DIR/Package.swift" -nt "$BIN" || "$ENTITLEMENTS" -nt "$BIN" ]]; then
  "$BUILD_SCRIPT" >/dev/null
fi

exec "$BIN" "$@"
