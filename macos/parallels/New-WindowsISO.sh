#!/usr/bin/env bash
# macos/parallels/New-WindowsISO.sh
#
# Builds a Windows ISO from UUP dump (uupdump.net) on macOS -- the Apple-Silicon
# counterpart to scripts/New-UUPDumpISO.ps1. Same uupdump API, but it requests
# the macOS/Linux converter package (uup_download_macos.sh / uup_download_linux.sh,
# which use aria2c + wimlib + chntpw + an ISO builder) instead of the Windows
# DISM-based uup_download_windows.cmd.
#
# Defaults to Windows 11 25H2, ARM64 (the only architecture Apple Silicon can run
# natively). Outputs the full path of the finished ISO on the last stdout line
# (Bootstrap.sh captures it).
#
# Examples:
#   ./New-WindowsISO.sh
#   ./New-WindowsISO.sh --version "Windows 11, version 25H2" --arch arm64
#   ./New-WindowsISO.sh --build-id <uuid> --edition PROFESSIONAL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

VERSION="Windows 11, version 25H2"
ARCH="arm64"
EDITION=""
LANGUAGE="en-us"
BUILD_ID=""
OUTPUT=""

usage() {
  cat >&2 <<EOF
Usage: New-WindowsISO.sh [--version <name>] [--arch arm64|amd64] [--edition <CODE>]
                         [--language <lang>] [--build-id <uuid>] [--output <dir>]
Defaults: --version "Windows 11, version 25H2" --arch arm64 --language en-us
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --arch)     ARCH="$2"; shift 2 ;;
    --edition)  EDITION="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --build-id) BUILD_ID="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

API="https://api.uupdump.net"

# ---------------------------------------------------------------------------
# Preflight: the macOS UUP converter's toolchain (macOS has no built-in DISM).
# ---------------------------------------------------------------------------
require_cmd curl
require_cmd unzip
require_cmd jq "brew install jq"
require_cmd aria2c "brew install aria2"
require_cmd cabextract "brew install cabextract"
# chntpw was dropped from Homebrew core; the working Apple-Silicon formula lives
# in the minacle tap (or use MacPorts: sudo port install chntpw).
require_cmd chntpw "brew install minacle/chntpw/chntpw   (run 'brew tap minacle/chntpw' first)"

if ! command -v wimlib-imagex >/dev/null 2>&1 && ! command -v wimlib >/dev/null 2>&1; then
  die "wimlib not found. Install with: brew install wimlib"
fi
ISO_BUILDER=""
for t in xorrisofs mkisofs genisoimage xorriso; do
  if command -v "$t" >/dev/null 2>&1; then ISO_BUILDER="$t"; break; fi
done
[[ -n "$ISO_BUILDER" ]] || die "No ISO builder found. Install one with: brew install cdrtools   (or: brew install xorriso)"

# ---------------------------------------------------------------------------
# Output location
# ---------------------------------------------------------------------------
[[ -n "$OUTPUT" ]] || OUTPUT="$PARALLELS_ROOT/iso"
mkdir -p "$OUTPUT"
WORKDIR="$OUTPUT/uup-work"

info "Building Windows ISO from UUP dump ($VERSION, $ARCH)"

avail_gb=$(df -g "$OUTPUT" | awk 'NR==2 {print $4}')
if [[ -n "$avail_gb" && "$avail_gb" -lt 25 ]]; then
  warn "Less than 25 GB free at $OUTPUT -- the UUP download + ISO build may run out of space."
fi

# ---------------------------------------------------------------------------
# 1. Resolve the build UUID
# ---------------------------------------------------------------------------
if [[ -n "$BUILD_ID" ]]; then
  BUILD_UUID="$BUILD_ID"
  log "[1/4] Using pinned build: $BUILD_ID"
else
  log "[1/4] Searching UUP dump for '$VERSION' ($ARCH)..."
  search_json="$(curl -fsSL --connect-timeout 15 --max-time 120 "$API/listid.php?search=$(printf '%s' "$VERSION" | jq -sRr @uri)&sortByDate=1")" \
    || die "UUP dump search failed. Browse https://uupdump.net/known.php for valid names."
  BUILD_UUID="$(printf '%s' "$search_json" \
    | jq -r --arg arch "$ARCH" '[.response.builds[] | select(.arch==$arch)] | sort_by(.created) | reverse | .[0].uuid // empty')"
  [[ -n "$BUILD_UUID" ]] || die "No '$VERSION' builds found for $ARCH. Browse https://uupdump.net/known.php."
  title="$(printf '%s' "$search_json" | jq -r --arg u "$BUILD_UUID" '.response.builds[] | select(.uuid==$u) | .title' | head -1)"
  log "  Selected: $title ($ARCH, uuid $BUILD_UUID)"
fi

# ---------------------------------------------------------------------------
# 2. Pick the edition
# ---------------------------------------------------------------------------
if [[ -z "$EDITION" ]]; then
  log "[2/4] Querying available editions..."
  ed_json="$(curl -fsSL --connect-timeout 15 --max-time 120 "$API/listeditions.php?lang=$LANGUAGE&id=$BUILD_UUID")" \
    || die "UUP dump edition listing failed for build $BUILD_UUID."
  editions="$(printf '%s' "$ed_json" | jq -r '.response.editionList[]?' 2>/dev/null || true)"
  [[ -n "$editions" ]] || die "No editions reported for build $BUILD_UUID (language $LANGUAGE)."
  for pref in PROFESSIONAL CORE SERVERSTANDARD; do
    if printf '%s\n' "$editions" | grep -qx "$pref"; then EDITION="$pref"; break; fi
  done
  [[ -n "$EDITION" ]] || EDITION="$(printf '%s\n' "$editions" | head -1)"
  log "  Auto-selected edition: $EDITION (available: $(printf '%s' "$editions" | tr '\n' ' '))"
else
  log "[2/4] Using edition: $EDITION"
fi

# ---------------------------------------------------------------------------
# 3. Download the UUP dump conversion package (macOS/Linux converter)
# ---------------------------------------------------------------------------
log "[3/4] Downloading UUP dump conversion package..."
mkdir -p "$WORKDIR"
ZIP="$WORKDIR/uup-package.zip"

# autodl=2 -> package that downloads UUP files and converts to ISO;
# updates=1 -> integrate updates; cleanup=1 -> delete UUP files after conversion.
edition_lc="$(printf '%s' "$EDITION" | tr '[:upper:]' '[:lower:]')"
# The package is a small script bundle (the multi-GB UUP download happens later
# via aria2 inside the converter), so a bounded overall timeout is safe here.
curl -fsSL --connect-timeout 15 --max-time 300 -X POST \
  "https://uupdump.net/get.php?id=$BUILD_UUID&pack=$LANGUAGE&edition=$edition_lc" \
  --data "autodl=2&updates=1&cleanup=1" -o "$ZIP" \
  || die "Failed to download the conversion package."

# Validate it is a real ZIP (first two bytes 'PK'); an HTML/JSON error page means
# uupdump is rate-limiting or the edition is invalid for this build.
if [[ "$(head -c2 "$ZIP")" != "PK" ]]; then
  die "Downloaded package is not a valid ZIP. UUP dump may be rate-limiting, or '$EDITION' is invalid for this build. Retry later or pick a build at https://uupdump.net"
fi

rm -rf "$WORKDIR/pkg"
mkdir -p "$WORKDIR/pkg"
unzip -q -o "$ZIP" -d "$WORKDIR/pkg"

# Make the converter exit instead of waiting for a keypress.
INI="$WORKDIR/pkg/ConvertConfig.ini"
if [[ -f "$INI" ]]; then
  # macOS sed in-place needs the empty backup arg.
  sed -i '' -E 's/^([[:space:]]*AutoExit[[:space:]]*=[[:space:]]*)[0-9]/\11/' "$INI" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Download UUP files and compile the ISO
# ---------------------------------------------------------------------------
CONVERTER=""
for c in uup_download_macos.sh uup_download_linux.sh; do
  if [[ -f "$WORKDIR/pkg/$c" ]]; then CONVERTER="$c"; break; fi
done
[[ -n "$CONVERTER" ]] || die "No macOS/Linux converter found in the package -- UUP dump may have changed its layout."

log "[4/4] Running $CONVERTER (downloads several GB from Microsoft; 30-90 min)..."
chmod +x "$WORKDIR/pkg/"*.sh 2>/dev/null || true
# Converter output goes to stderr so it streams to the terminal (visible even
# when Bootstrap.sh captures this script's stdout for the ISO path).
( cd "$WORKDIR/pkg" && ./"$CONVERTER" ) >&2

ISO="$(find "$WORKDIR/pkg" -maxdepth 1 -iname '*.iso' -type f -print0 \
        | xargs -0 ls -S 2>/dev/null | head -1)"
[[ -n "$ISO" ]] || die "No ISO was produced. Work dir kept at '$WORKDIR' -- re-run to resume (downloaded files are reused)."

FINAL="$OUTPUT/$(basename "$ISO")"
mv -f "$ISO" "$FINAL"
rm -rf "$WORKDIR"

info "ISO ready"
log "$FINAL"
log ""
log "Install it into a VM with:"
log "  ./New-AgentVM.sh --name <vm>"
log "  ./Install-Windows.sh --name <vm> --iso \"$FINAL\""

# Machine-readable last line for Bootstrap.sh.
printf '%s\n' "$FINAL"
