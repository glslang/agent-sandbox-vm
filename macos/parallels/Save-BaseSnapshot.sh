#!/usr/bin/env bash
# macos/parallels/Save-BaseSnapshot.sh
#
# Captures the clean, provisioned base snapshot (default: CleanProvisionedBase)
# and records its snapshot id in the VM config so Start-Session.sh --restore can
# revert to it deterministically. Counterpart to scripts/Save-BaseSnapshot.ps1.
#
# The VM is shut down first so the snapshot is a clean powered-off state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

NAME=""
LABEL="$SNAPSHOT_LABEL"
DESCRIPTION="Clean provisioned base (Windows + toolchain + Parallels Tools)"

usage() {
  echo "Usage: Save-BaseSnapshot.sh --name <vm> [--label <name>] [--description <text>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
require_vm_config "$NAME"
load_config "$NAME"

state="$(vm_state "$NAME")"
if [[ "$state" != "stopped" ]]; then
  info "Shutting down '$NAME' for a clean snapshot"
  "$PRLCTL" stop "$NAME" >/dev/null 2>&1 || "$PRLCTL" stop "$NAME" --kill >/dev/null 2>&1 || true
fi

info "Creating snapshot '$LABEL'"
out="$("$PRLCTL" snapshot "$NAME" --name "$LABEL" -d "$DESCRIPTION" 2>&1)"
printf '%s\n' "$out"

# prlctl prints: "The snapshot with id {UUID} has been successfully created."
snap_id="$(printf '%s' "$out" | grep -oE '\{[0-9a-fA-F-]+\}' | head -1)"
if [[ -n "$snap_id" ]]; then
  write_config "$NAME" SnapshotLabel "$LABEL" SnapshotId "$snap_id"
  log "Recorded snapshot id $snap_id (label '$LABEL') in config."
else
  write_config "$NAME" SnapshotLabel "$LABEL"
  warn "Could not parse the snapshot id from prlctl output; Start-Session --restore will resolve '$LABEL' by name."
fi

info "Base snapshot saved"
log "Restore later with: ./Start-Session.sh --name \"$NAME\" --project <dir> --restore"
