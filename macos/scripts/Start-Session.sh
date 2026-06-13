#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMCTL="$SCRIPT_DIR/vmctl.sh"

NAME=""
PROJECT_PATH=""
NETWORK="isolated"
RESTORE="false"
LABEL="CleanProvisionedBase"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --project)
      PROJECT_PATH="$2"
      shift 2
      ;;
    --internet)
      NETWORK="nat"
      shift
      ;;
    --network)
      NETWORK="$2"
      shift 2
      ;;
    --restore)
      RESTORE="true"
      shift
      ;;
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

if [[ -z "$NAME" || -z "$PROJECT_PATH" ]]; then
  echo "Usage: Start-Session.sh --name <vm> --project <path> [--internet|--network isolated|nat|bridged] [--restore] [--label <snapshot>]" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project path does not exist: $PROJECT_PATH" >&2
  exit 1
fi

if [[ "$RESTORE" == "true" ]]; then
  "$VMCTL" snapshot restore --name "$NAME" --label "$LABEL"
fi

SHARED_DIR="$("$VMCTL" path --name "$NAME" --shared)"
WORKSPACE_DIR="$SHARED_DIR/workspace"
mkdir -p "$WORKSPACE_DIR"

rsync -a --delete \
  --exclude artifacts \
  --exclude .git \
  --exclude target \
  "$PROJECT_PATH"/ "$WORKSPACE_DIR"/

echo "Project synced to shared VM directory: $WORKSPACE_DIR"
echo "In a macOS guest, use the mounted shared directory and cd into workspace."

exec "$VMCTL" run --name "$NAME" --internet "$NETWORK" --share "$SHARED_DIR"
