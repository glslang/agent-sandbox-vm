#!/usr/bin/env bash
# macos/parallels/New-AgentVM.sh
#
# Creates a Windows 11 ARM64 Parallels VM optimised for the agent sandbox, and
# records its config under ~/.agent-sandbox/parallels-vms/<name>/. Counterpart to
# scripts/New-AgentVM.ps1 (Hyper-V). `prlctl create -d win-11` provisions the
# Win11-appropriate machine (efi-arm64, Secure Boot, virtual TPM 2.0).
#
# The install itself is done separately by Install-Windows.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_prlctl

NAME=""
CPUS=4
MEMORY_GB=8
DISK_GB=80
SHARED_PATH=""

usage() {
  echo "Usage: New-AgentVM.sh --name <vm> [--cpus N] [--memory GB] [--disk-size GB] [--shared-path <dir>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --cpus)        CPUS="$2"; shift 2 ;;
    --memory)      MEMORY_GB="$2"; shift 2 ;;
    --disk-size)   DISK_GB="$2"; shift 2 ;;
    --shared-path) SHARED_PATH="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
# Validate sizing before arithmetic expansion: bash evaluates a non-numeric
# string in $(( )) as 0, which would silently configure a 0 MB VM.
[[ "$CPUS" =~ ^[1-9][0-9]*$ ]]      || die "--cpus must be a positive integer, got '$CPUS'."
[[ "$MEMORY_GB" =~ ^[1-9][0-9]*$ ]] || die "--memory must be a positive integer (GB), got '$MEMORY_GB'."
[[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]]   || die "--disk-size must be a positive integer (GB), got '$DISK_GB'."
vm_exists "$NAME" && die "A Parallels VM named '$NAME' already exists. Delete it first or pick another name."

[[ -n "$SHARED_PATH" ]] || SHARED_PATH="$(vm_shared_dir "$NAME")"
mkdir -p "$SHARED_PATH/workspace"

info "Creating Windows 11 ARM64 VM '$NAME'"

# Gen-2-equivalent Win11 machine: efi-arm64 + Secure Boot + virtual TPM.
"$PRLCTL" create "$NAME" -d win-11

log "Configuring $CPUS vCPU / ${MEMORY_GB} GB RAM / ${DISK_GB} GB disk..."
"$PRLCTL" set "$NAME" --cpus "$CPUS"
"$PRLCTL" set "$NAME" --memsize "$((MEMORY_GB * 1024))"
"$PRLCTL" set "$NAME" --device-set hdd0 --size "$((DISK_GB * 1024))"

# Belt-and-braces: ensure the Win11 firmware requirements are on.
"$PRLCTL" set "$NAME" --efi-secure-boot on >/dev/null 2>&1 || \
  warn "Could not confirm Secure Boot state (Parallels usually enables it for win-11)."

log "Sharing host folder into the guest as \\\\Mac\\${SHARED_NAME}..."
"$PRLCTL" set "$NAME" --shf-host on
"$PRLCTL" set "$NAME" --shf-host-add "$SHARED_NAME" --path "$SHARED_PATH/workspace" --mode rw

log "Enabling shared (NAT) networking for install + provisioning..."
"$PRLCTL" set "$NAME" --device-set net0 --type shared --connect

write_config "$NAME" \
  GuestUser "$GUEST_USER" \
  GuestPassword "$GUEST_PASSWORD" \
  SharedName "$SHARED_NAME" \
  SharedHostPath "$SHARED_PATH"

info "VM '$NAME' created"
log "Config: $(vm_config_file "$NAME")"
log ""
log "Next:"
log "  ./Install-Windows.sh --name \"$NAME\" --iso <windows-11-arm64.iso>"
