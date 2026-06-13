#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/macos"
BIN="$PACKAGE_DIR/.build/release/vmctl"

swift build -c release --package-path "$PACKAGE_DIR"
codesign --force --sign - --entitlements "$PACKAGE_DIR/vmctl.entitlements" "$BIN" >/dev/null

echo "$BIN"
