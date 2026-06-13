#!/usr/bin/env bash
# Canonical build entrypoint: this is the one script permitted to run
# `swift build` + `codesign`. vmctl.sh invokes it on demand; all other scripts
# must go through vmctl.sh rather than building directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/macos"
BIN="$PACKAGE_DIR/.build/release/vmctl"

swift build -c release --package-path "$PACKAGE_DIR"
codesign --force --sign - --entitlements "$PACKAGE_DIR/vmctl.entitlements" "$BIN" >/dev/null

echo "$BIN"
