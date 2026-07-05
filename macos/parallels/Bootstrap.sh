#!/usr/bin/env bash
# macos/parallels/Bootstrap.sh
#
# One-shot orchestrator for the Parallels Windows-on-ARM sandbox:
#   (optional) build ISO -> create VM -> install Windows -> provision -> snapshot.
# Counterpart to the top-level Bootstrap.ps1 (Hyper-V).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# Bootstrap drives VM create/install/provision/snapshot -- fail fast up front
# rather than after a potentially hour-long ISO build.
require_prlctl

NAME=""
ISO=""
BUILD_ISO="false"
VERSION="Windows 11, version 25H2"
ARCH="arm64"
SKIP_PROVISION="false"
SKIP_SNAPSHOT="false"
REARM_UPDATES="false"
SIZE_ARGS=()

usage() {
  cat >&2 <<EOF
Usage: Bootstrap.sh --name <vm> (--iso <win-arm64.iso> | --build-iso)
         [--version <name>] [--arch arm64|amd64]
         [--cpus N] [--memory GB] [--disk-size GB]
         [--skip-provision] [--skip-snapshot] [--rearm-updates]
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)           NAME="$2"; shift 2 ;;
    --iso)            ISO="$2"; shift 2 ;;
    --build-iso)      BUILD_ISO="true"; shift ;;
    --version)        VERSION="$2"; shift 2 ;;
    --arch)           ARCH="$2"; shift 2 ;;
    --cpus)           SIZE_ARGS+=(--cpus "$2"); shift 2 ;;
    --memory)         SIZE_ARGS+=(--memory "$2"); shift 2 ;;
    --disk-size)      SIZE_ARGS+=(--disk-size "$2"); shift 2 ;;
    --skip-provision) SKIP_PROVISION="true"; shift ;;
    --skip-snapshot)  SKIP_SNAPSHOT="true"; shift ;;
    --rearm-updates)  REARM_UPDATES="true"; shift ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
[[ -n "$ISO" || "$BUILD_ISO" == "true" ]] || { echo "Provide --iso <path> or --build-iso" >&2; usage; }

if [[ "$BUILD_ISO" == "true" ]]; then
  info "Step 1/4: Building Windows ISO from UUP dump"
  ISO="$("$SCRIPT_DIR/New-WindowsISO.sh" --version "$VERSION" --arch "$ARCH" | tail -1)"
  [[ -f "$ISO" ]] || die "ISO build did not produce a file."
else
  info "Step 1/4: Using provided ISO"
  log "$ISO"
fi

info "Step 2/4: Creating VM"
"$SCRIPT_DIR/New-AgentVM.sh" --name "$NAME" ${SIZE_ARGS[@]+"${SIZE_ARGS[@]}"}

info "Step 3/4: Installing Windows (unattended)"
"$SCRIPT_DIR/Install-Windows.sh" --name "$NAME" --iso "$ISO"

info "First-boot reminder"
log "Some Windows 11 ARM64 builds pause first boot at the license/OOBE screen"
log "despite the answer file's HideEULAPage. Provisioning below runs anyway (it"
log "uses a no-login batch task), but open the Parallels window for '$NAME' and"
log "click through that screen once so the clean-base snapshot captures an"
log "auto-logged-in desktop."

if [[ "$SKIP_PROVISION" != "true" ]]; then
  info "Step 4/4: Provisioning toolchain"
  PROV_ARGS=()
  [[ "$REARM_UPDATES" == "true" ]] && PROV_ARGS+=(--rearm-updates)
  "$SCRIPT_DIR/Start-Provision.sh" --name "$NAME" ${PROV_ARGS[@]+"${PROV_ARGS[@]}"}
else
  log "Skipping provisioning (--skip-provision)."
fi

if [[ "$SKIP_SNAPSHOT" != "true" && "$SKIP_PROVISION" != "true" ]]; then
  "$SCRIPT_DIR/Save-BaseSnapshot.sh" --name "$NAME"
fi

info "Bootstrap complete for '$NAME'"
log "Start a session with:"
log "  ./Start-Session.sh --name \"$NAME\" --project <dir> [--internet] [--restore]"
