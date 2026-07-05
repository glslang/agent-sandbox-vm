#!/usr/bin/env bash
# macos/parallels/lib/common.sh
# Shared helpers for the Parallels Desktop Windows-on-ARM workflow.
#
# This tree is the Parallels (prlctl) counterpart to the top-level Hyper-V
# PowerShell scripts. Unlike macos/ (which drives Apple Virtualization.framework
# through the `vmctl` Swift binary), Parallels manages its own VM registry, so
# these are thin shell wrappers over `prlctl`. There is no Swift build step.
#
# Per-VM config lives at:
#   ${AGENT_SANDBOX_PARALLELS_ROOT:-~/.agent-sandbox/parallels-vms}/<name>/config.json
# and holds a flat (non-nested) JSON object of string values.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
: "${GUEST_USER:=Admin}"          # created + auto-logged-in by autounattend.arm64.xml
: "${GUEST_PASSWORD:=Admin}"      # isolated sandbox; matches the checked-in answer file
: "${SHARED_NAME:=workspace}"     # Parallels shared-folder name -> guest \\Mac\workspace
: "${SNAPSHOT_LABEL:=CleanProvisionedBase}"

PARALLELS_ROOT="${AGENT_SANDBOX_PARALLELS_ROOT:-$HOME/.agent-sandbox/parallels-vms}"

# ---------------------------------------------------------------------------
# Logging -- all diagnostics go to stderr so a script's stdout stays reserved
# for machine-readable output (e.g. New-WindowsISO.sh prints the ISO path, which
# Bootstrap.sh captures while the human-facing progress streams to the terminal).
# ---------------------------------------------------------------------------
log()  { printf '  %s\n' "$*" >&2; }
info() { printf '\n== %s ==\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Tooling
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH.${2:+ $2}"
}

PRLCTL="${PRLCTL:-prlctl}"
require_cmd "$PRLCTL" "Install Parallels Desktop (https://www.parallels.com)."

# Resolve the Parallels Desktop app bundle Tools directory (holds igt_arm64.exe,
# prl_tg/, and the prl-tools-win-arm.iso used for the guest-tools bootstrap).
resolve_tools_dir() {
  if [[ -n "${PARALLELS_TOOLS_DIR:-}" ]]; then
    printf '%s\n' "$PARALLELS_TOOLS_DIR"; return 0
  fi
  local candidates=(
    "${PARALLELS_APP:-}/Contents/Resources/Tools"
    "/Applications/Parallels Desktop.app/Contents/Resources/Tools"
    "$HOME/Applications/Parallels Desktop.app/Contents/Resources/Tools"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c/igt_arm64.exe" ]] && { printf '%s\n' "$c"; return 0; }
  done
  die "Could not locate the Parallels Tools directory. Set PARALLELS_TOOLS_DIR or PARALLELS_APP."
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
vm_config_dir()  { printf '%s/%s\n' "$PARALLELS_ROOT" "$1"; }
vm_config_file() { printf '%s/%s/config.json\n' "$PARALLELS_ROOT" "$1"; }
vm_shared_dir()  { printf '%s/%s/Shared\n' "$PARALLELS_ROOT" "$1"; }

# Minimal reader for a flat JSON object of string values: json_get <file> <key>
json_get() {
  [[ -f "$1" ]] || return 0
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

require_vm_config() {
  local f; f="$(vm_config_file "$1")"
  [[ -f "$f" ]] || die "No config for VM '$1' at $f. Run New-AgentVM.sh first."
}

# Load config for a VM into the current shell (GUEST_USER, GUEST_PASSWORD,
# SHARED_NAME, SNAPSHOT_LABEL, SHARED_HOST_PATH, SNAPSHOT_ID, GUEST_SHARE_UNC).
load_config() {
  local name="$1" f
  f="$(vm_config_file "$name")"
  [[ -f "$f" ]] || die "No config for VM '$name' at $f."
  GUEST_USER="$(json_get "$f" GuestUser)";          : "${GUEST_USER:=Admin}"
  GUEST_PASSWORD="$(json_get "$f" GuestPassword)";  : "${GUEST_PASSWORD:=Admin}"
  SHARED_NAME="$(json_get "$f" SharedName)";        : "${SHARED_NAME:=workspace}"
  SNAPSHOT_LABEL="$(json_get "$f" SnapshotLabel)";  : "${SNAPSHOT_LABEL:=CleanProvisionedBase}"
  # shellcheck disable=SC2034  # consumed by sourcing scripts (Start-Session.sh)
  SNAPSHOT_ID="$(json_get "$f" SnapshotId)"
  SHARED_HOST_PATH="$(json_get "$f" SharedHostPath)"
  [[ -n "$SHARED_HOST_PATH" ]] || SHARED_HOST_PATH="$(vm_shared_dir "$name")"
  GUEST_SHARE_UNC="$(json_get "$f" GuestShareUNC)"
  [[ -n "$GUEST_SHARE_UNC" ]] || GUEST_SHARE_UNC="\\\\Mac\\${SHARED_NAME}"
}

# JSON-escape a string value (backslash + double-quote).
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# write_config <name> <k1> <v1> [<k2> <v2> ...] : merge keys into config.json.
# Bash 3.2 compatible (no associative arrays -- macOS ships /bin/bash 3.2). Only
# the fixed, known keys are stored; the guest share UNC is derived, not stored,
# because its backslashes cannot round-trip through the lightweight json_get.
write_config() {
  local name="$1"; shift
  local dir f; dir="$(vm_config_dir "$name")"; f="$dir/config.json"
  mkdir -p "$dir"

  # Seed from existing values (empty if the file does not exist yet).
  local v_VMName="$name"
  local v_GuestUser;      v_GuestUser="$(json_get "$f" GuestUser)"
  local v_GuestPassword;  v_GuestPassword="$(json_get "$f" GuestPassword)"
  local v_SharedName;     v_SharedName="$(json_get "$f" SharedName)"
  local v_SharedHostPath; v_SharedHostPath="$(json_get "$f" SharedHostPath)"
  local v_SnapshotLabel;  v_SnapshotLabel="$(json_get "$f" SnapshotLabel)"
  local v_SnapshotId;     v_SnapshotId="$(json_get "$f" SnapshotId)"

  # Defaults for anything still empty.
  [[ -n "$v_GuestUser" ]]      || v_GuestUser="$GUEST_USER"
  [[ -n "$v_GuestPassword" ]]  || v_GuestPassword="$GUEST_PASSWORD"
  [[ -n "$v_SharedName" ]]     || v_SharedName="$SHARED_NAME"
  [[ -n "$v_SharedHostPath" ]] || v_SharedHostPath="$(vm_shared_dir "$name")"
  [[ -n "$v_SnapshotLabel" ]]  || v_SnapshotLabel="$SNAPSHOT_LABEL"

  # Merge overrides.
  local k val
  while [[ $# -gt 0 ]]; do
    k="$1"; val="$2"; shift 2
    case "$k" in
      VMName)         v_VMName="$val" ;;
      GuestUser)      v_GuestUser="$val" ;;
      GuestPassword)  v_GuestPassword="$val" ;;
      SharedName)     v_SharedName="$val" ;;
      SharedHostPath) v_SharedHostPath="$val" ;;
      SnapshotLabel)  v_SnapshotLabel="$val" ;;
      SnapshotId)     v_SnapshotId="$val" ;;
      *) warn "write_config: ignoring unknown key '$k'" ;;
    esac
  done

  {
    printf '{\n'
    printf '  "VMName": "%s",\n'         "$(json_escape "$v_VMName")"
    printf '  "GuestUser": "%s",\n'      "$(json_escape "$v_GuestUser")"
    printf '  "GuestPassword": "%s",\n'  "$(json_escape "$v_GuestPassword")"
    printf '  "SharedName": "%s",\n'     "$(json_escape "$v_SharedName")"
    printf '  "SharedHostPath": "%s",\n' "$(json_escape "$v_SharedHostPath")"
    printf '  "SnapshotLabel": "%s",\n'  "$(json_escape "$v_SnapshotLabel")"
    printf '  "SnapshotId": "%s"\n'      "$(json_escape "$v_SnapshotId")"
    printf '}\n'
  } >"$f"
}

# ---------------------------------------------------------------------------
# VM helpers
# ---------------------------------------------------------------------------
vm_exists() { "$PRLCTL" status "$1" >/dev/null 2>&1; }

vm_state() { "$PRLCTL" status "$1" 2>/dev/null | awk '{print $NF}'; }

# Run a command inside the guest via Parallels Tools (requires Tools installed).
# Keep the command SHORT and fixed-size: `prlctl exec` runs in Session 0 and
# orphans on long-running or large-argument calls. Push data via the shared
# folder instead (see Start-Provision.sh), not through exec arguments.
guest_exec() {  # guest_exec <name> <command...>
  local name="$1"; shift
  "$PRLCTL" exec "$name" --user "$GUEST_USER" --password "$GUEST_PASSWORD" "$@"
}

# Wait until the guest answers over Parallels Tools (i.e. Tools + Toolgate are up).
wait_for_guest() {  # wait_for_guest <name> <timeout_seconds>
  local name="$1" timeout="${2:-2400}" waited=0 step=15
  info "Waiting for the guest to come up (Parallels Tools). Timeout: ${timeout}s"
  while (( waited < timeout )); do
    if guest_exec "$name" cmd /c "echo ready" >/dev/null 2>&1; then
      log "Guest is responding to prlctl exec after ${waited}s."
      return 0
    fi
    sleep "$step"; waited=$((waited + step))
    log "  ...still installing (${waited}s elapsed)"
  done
  die "Guest did not become reachable within ${timeout}s. Open the Parallels window to inspect Windows Setup."
}
