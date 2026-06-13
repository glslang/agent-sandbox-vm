#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMCTL="$SCRIPT_DIR/vmctl.sh"

NAME=""
GUEST="macos"
IPSW_ARGS=()
# Only forward sizing flags that were explicitly passed, so vmctl applies its
# own per-guest defaults (e.g. 4 GB RAM for Windows, 8 GB for macOS) otherwise.
SIZE_ARGS=()
INSTALL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --ipsw)
      IPSW_ARGS=(--ipsw "$2")
      shift 2
      ;;
    --latest)
      IPSW_ARGS=(--latest)
      shift
      ;;
    --guest)
      GUEST="$2"
      shift 2
      ;;
    --iso)
      IPSW_ARGS=(--iso "$2")
      shift 2
      ;;
    --cpus)
      SIZE_ARGS+=(--cpus "$2")
      shift 2
      ;;
    --memory)
      SIZE_ARGS+=(--memory "$2")
      shift 2
      ;;
    --disk-size)
      SIZE_ARGS+=(--disk-size "$2")
      shift 2
      ;;
    --install)
      INSTALL="true"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$NAME" || ${#IPSW_ARGS[@]} -eq 0 ]]; then
  echo "Usage: Bootstrap.sh --name <vm> (--ipsw <macos.ipsw>|--latest|--guest windows --iso <arm64-media>) [--cpus N] [--memory GB] [--disk-size GB] [--install]" >&2
  exit 2
fi

"$VMCTL" create --guest "$GUEST" --name "$NAME" ${SIZE_ARGS[@]+"${SIZE_ARGS[@]}"} "${IPSW_ARGS[@]}"

if [[ "$INSTALL" == "true" ]]; then
  "$VMCTL" install --name "$NAME"
fi
