#!/usr/bin/env bash
# macos/parallels/Start-Session.sh
#
# Daily driver: optionally restore the clean base, sync the project into the
# shared folder, set the network mode, and boot the VM with its Parallels window.
# Counterpart to the top-level Start-Session.ps1 (Hyper-V) and macos/scripts/
# Start-Session.sh (VZ).
#
# The project is synced into the shared folder, which the guest sees at
# \\Mac\workspace -- run the agent there from inside the VM.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_prlctl

NAME=""
PROJECT=""
NETWORK="isolated"      # default: fully isolated (no internet), like the Hyper-V default
RESTORE="false"
LABEL=""
SNAP_ID_ARG=""

usage() {
  cat >&2 <<EOF
Usage: Start-Session.sh --name <vm> --project <path>
         [--internet | --network shared|host-only|isolated]
         [--restore] [--label <snapshot>] [--snapshot-id <id>]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --project)     PROJECT="$2"; shift 2 ;;
    --internet)    NETWORK="shared"; shift ;;
    --network)     NETWORK="$2"; shift 2 ;;
    --restore)     RESTORE="true"; shift ;;
    --label)       LABEL="$2"; shift 2 ;;
    --snapshot-id) SNAP_ID_ARG="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" && -n "$PROJECT" ]] || usage
require_vm_config "$NAME"
load_config "$NAME"
[[ -d "$PROJECT" ]] || die "Project path does not exist: $PROJECT"
[[ -n "$LABEL" ]] || LABEL="$SNAPSHOT_LABEL"

resolve_snapshot_id() {
  [[ -n "$SNAP_ID_ARG" ]] && { printf '%s\n' "$SNAP_ID_ARG"; return 0; }
  [[ -n "$SNAPSHOT_ID" ]] && { printf '%s\n' "$SNAPSHOT_ID"; return 0; }
  if command -v jq >/dev/null 2>&1; then
    "$PRLCTL" snapshot-list "$NAME" --json 2>/dev/null \
      | jq -r --arg n "$LABEL" 'if type=="array" then .[] else .[] end | select(.name==$n) | (.id // .snapshot_id)' 2>/dev/null \
      | head -1
  fi
}

# ---------------------------------------------------------------------------
# Restore the clean base (revert to a powered-off snapshot).
# ---------------------------------------------------------------------------
if [[ "$RESTORE" == "true" ]]; then
  sid="$(resolve_snapshot_id)"
  [[ -n "$sid" ]] || die "No snapshot id for label '$LABEL'. Run Save-BaseSnapshot.sh, or pass --snapshot-id <id> (see: prlctl snapshot-list \"$NAME\")."
  if [[ "$(vm_state "$NAME")" != "stopped" ]]; then
    "$PRLCTL" stop "$NAME" >/dev/null 2>&1 || "$PRLCTL" stop "$NAME" --kill >/dev/null 2>&1 || true
    # `prlctl stop` can return before shutdown completes; snapshot-switch on a
    # transitional VM is racy.
    wait_for_stopped "$NAME" 180 || die "VM '$NAME' did not stop within 180s; cannot restore the snapshot."
  fi
  info "Restoring snapshot '$LABEL' ($sid)"
  "$PRLCTL" snapshot-switch "$NAME" --id "$sid" --skip-resume
fi

# ---------------------------------------------------------------------------
# Sync the project into the shared folder.
# ---------------------------------------------------------------------------
WS="$SHARED_HOST_PATH/workspace"
mkdir -p "$WS"
info "Syncing project into the shared folder"
rsync -a --delete \
  --exclude artifacts \
  --exclude .git \
  --exclude target \
  "$PROJECT"/ "$WS"/
log "Synced $PROJECT -> $WS  (guest: $GUEST_SHARE_UNC)"

# ---------------------------------------------------------------------------
# Network mode.
# ---------------------------------------------------------------------------
case "$NETWORK" in
  shared|nat|internet)
    info "Networking: shared (internet)"
    "$PRLCTL" set "$NAME" --device-set net0 --type shared --connect >/dev/null ;;
  host-only)
    info "Networking: host-only (no internet)"
    "$PRLCTL" set "$NAME" --device-set net0 --type host-only --connect >/dev/null ;;
  isolated|none)
    info "Networking: isolated (adapter disconnected)"
    "$PRLCTL" set "$NAME" --device-disconnect net0 >/dev/null 2>&1 || true ;;
  *) die "Unknown network mode: $NETWORK (use shared|host-only|isolated)" ;;
esac

# ---------------------------------------------------------------------------
# Boot + show the console window.
# ---------------------------------------------------------------------------
info "Starting '$NAME'"
"$PRLCTL" start "$NAME"
open -a "Parallels Desktop" >/dev/null 2>&1 || true

info "Session ready"
log "Inside the VM (auto-logged in as $GUEST_USER):"
log "  1. Open the shared folder:  $GUEST_SHARE_UNC"
log "  2. Copy or cd into it, then run:  claude"
log ""
log "Extract build artifacts afterwards with:"
log "  ./Copy-Artifacts.sh --name \"$NAME\""
