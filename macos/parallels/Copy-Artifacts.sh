#!/usr/bin/env bash
# macos/parallels/Copy-Artifacts.sh
#
# Pulls build outputs from the VM back to the host. Because the project workspace
# IS the Parallels shared folder (guest \\Mac\workspace == host <bundle>/Shared/
# workspace), extraction is a plain host-side file copy -- no PowerShell Direct
# equivalent needed. Counterpart to scripts/Copy-Artifacts.ps1.
#
# Defaults: copy *.exe, *.dll, *.pdb from workspace/target/release into ./artifacts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

NAME=""
FROM="target/release"
DEST="./artifacts"
PATTERNS="exe dll pdb"
EXTRA=""

usage() {
  cat >&2 <<EOF
Usage: Copy-Artifacts.sh --name <vm> [--from target/release] [--dest ./artifacts]
                         [--patterns "exe dll pdb"] [--extra "json toml"]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     NAME="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --dest)     DEST="$2"; shift 2 ;;
    --patterns) PATTERNS="$2"; shift 2 ;;
    --extra)    EXTRA="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
require_vm_config "$NAME"
load_config "$NAME"

SRC="$SHARED_HOST_PATH/workspace/$FROM"
[[ -d "$SRC" ]] || die "Source not found: $SRC
(Build inside the VM under $GUEST_SHARE_UNC first, or pass --from <subdir>.)"

mkdir -p "$DEST"

info "Extracting artifacts from $SRC"
count=0
for ext in $PATTERNS $EXTRA; do
  ext="${ext#\*.}"; ext="${ext#.}"   # accept "*.exe", ".exe" or "exe"
  while IFS= read -r -d '' f; do
    cp -f "$f" "$DEST"/
    log "  $(basename "$f")"
    count=$((count + 1))
  done < <(find "$SRC" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null)
done

info "Copied $count file(s) to $DEST"
