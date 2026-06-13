#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 2 || "$1" != "--name" ]]; then
  echo "Usage: Save-BaseSnapshot.sh --name <vm> [--label <snapshot>]" >&2
  exit 2
fi

NAME="$2"
LABEL="CleanProvisionedBase"
shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

exec "$SCRIPT_DIR/vmctl.sh" snapshot save --name "$NAME" --label "$LABEL"
