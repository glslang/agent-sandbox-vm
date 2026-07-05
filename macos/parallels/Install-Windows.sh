#!/usr/bin/env bash
# macos/parallels/Install-Windows.sh
#
# Installs Windows 11 ARM64 into an existing Parallels VM, fully unattended, then
# waits until Parallels Tools is up so the guest is reachable over `prlctl exec`.
#
# Counterpart to scripts/Install-Windows.ps1 (Hyper-V). The Hyper-V path injects
# the answer file OFFLINE into the VHDX via DISM; macOS has no such path, so we
# deliver Autounattend.xml via a small removable-media ISO that Windows Setup
# auto-scans at boot. That answer ISO also carries the Parallels Guest Tools
# bootstrap (IGT_ARM64.exe + prl_tg\), which the answer file installs during the
# specialize pass -- bringing up the `prlctl exec` + shared-folder channel with
# no GUI interaction.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_prlctl

NAME=""
WIN_ISO=""
TIMEOUT=2400
ANSWER_XML="$SCRIPT_DIR/autounattend.arm64.xml"

usage() {
  echo "Usage: Install-Windows.sh --name <vm> --iso <windows-11-arm64.iso> [--timeout <seconds>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --iso)     WIN_ISO="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" && -n "$WIN_ISO" ]] || usage
require_vm_config "$NAME"
load_config "$NAME"
[[ -f "$WIN_ISO" ]] || die "Windows ISO not found: $WIN_ISO"
[[ -f "$ANSWER_XML" ]] || die "Answer file not found: $ANSWER_XML"
require_cmd hdiutil

TOOLS_DIR="$(resolve_tools_dir)"

# ---------------------------------------------------------------------------
# 1. Build the answer ISO: Autounattend.xml + Parallels Guest Tools bootstrap.
# ---------------------------------------------------------------------------
info "Building answer ISO (Autounattend.xml + Parallels Tools bootstrap)"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

cp "$ANSWER_XML" "$STAGE/Autounattend.xml"
cp "$TOOLS_DIR/igt_arm64.exe" "$STAGE/IGT_ARM64.exe"
cp -R "$TOOLS_DIR/prl_tg" "$STAGE/prl_tg"

ANSWER_ISO="$(vm_config_dir "$NAME")/answer.iso"
rm -f "$ANSWER_ISO"
hdiutil makehybrid -iso -joliet -default-volume-name UNATTEND -o "$ANSWER_ISO" "$STAGE" >/dev/null
log "Answer ISO: $ANSWER_ISO"

# ---------------------------------------------------------------------------
# 2. Attach media and boot.
# ---------------------------------------------------------------------------
info "Attaching install media and starting the VM"
# cdrom0 is created by `prlctl create -d win-11`; point it at the Windows ISO.
"$PRLCTL" set "$NAME" --device-set cdrom0 --image "$WIN_ISO" --connect
# Add the answer/tools ISO as a second optical drive.
"$PRLCTL" set "$NAME" --device-add cdrom --image "$ANSWER_ISO" --connect
"$PRLCTL" set "$NAME" --device-bootorder "cdrom0 hdd0"

"$PRLCTL" start "$NAME"
log "Windows Setup is running unattended (partition -> apply image -> install Parallels Tools)."
log "You can watch progress in the Parallels window; no interaction is required."
log ""
log "NOTE: if the VM stalls at 'Press any key to boot from CD or DVD', click the"
log "      Parallels window and press a key once (only the first boot needs it)."

# ---------------------------------------------------------------------------
# 3. Wait for the guest to become reachable (Parallels Tools installed).
# ---------------------------------------------------------------------------
wait_for_guest "$NAME" "$TIMEOUT"

# ---------------------------------------------------------------------------
# 4. Disconnect install media so later boots go straight to the installed OS.
# ---------------------------------------------------------------------------
info "Disconnecting install media"
"$PRLCTL" set "$NAME" --device-set cdrom0 --disconnect >/dev/null 2>&1 || true
"$PRLCTL" set "$NAME" --device-set cdrom1 --disconnect >/dev/null 2>&1 || true
"$PRLCTL" set "$NAME" --device-bootorder "hdd0 cdrom0" >/dev/null 2>&1 || true

info "Windows installed and reachable via prlctl exec"
log "Verify: prlctl exec \"$NAME\" --user $GUEST_USER --password $GUEST_PASSWORD cmd /c ver"
log ""
log "Next:"
log "  ./Start-Provision.sh --name \"$NAME\"      # install the toolchain"
