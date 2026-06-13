#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME=""
FROM="workspace/target/release"
DEST="./artifacts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --from)
      FROM="$2"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Usage: Copy-Artifacts.sh --name <vm> [--from workspace/target/release] [--dest ./artifacts]" >&2
  exit 2
fi

exec "$SCRIPT_DIR/vmctl.sh" copy-out --name "$NAME" --from "$FROM" --to "$DEST"
