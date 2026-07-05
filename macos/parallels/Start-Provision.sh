#!/usr/bin/env bash
# macos/parallels/Start-Provision.sh
#
# Provisions the toolchain inside the guest. Counterpart to
# scripts/Start-Provision.ps1 + Invoke-Provision.ps1 (Hyper-V).
#
# DESIGN (why this avoids `prlctl exec` for anything heavy, and does NOT need an
# interactive logon):
#   `prlctl exec` runs in a raw Session 0 where installers misbehave, long /
#   large-argument execs ORPHAN on the host, and \\Mac\<share> is not mapped.
#   An INTERACTIVE (/IT) scheduled task fixes the installer/share problems but
#   only runs when Admin is signed in to the desktop -- so on a fresh install
#   sitting at the Windows OOBE/EULA screen it silently never runs (no session).
#   So instead:
#     1. The provisioner script is written into the SHARED FOLDER by the host
#        (a plain file write -- no exec, no large argument).
#     2. It is launched via a NON-interactive scheduled task (a batch logon as
#        Admin -- NO /IT). Verified on Parallels 26.4: a batch task gets a full
#        admin token, has \\Mac\<share> mapped, and has internet -- and it runs
#        whether or not anyone is logged in, i.e. even while the guest is still
#        at OOBE. That is what lets a clean install provision unattended.
#     3. The provisioner writes its transcript + a DONE/FAILED marker back into
#        the shared folder, so the host follows progress by reading LOCAL files.
#     4. The task is ONSTART, not ONCE. A freshly installed guest can reboot on
#        its own right after provisioning starts (observed: Parallels Tools
#        finishing its install rebooted the guest ~70s in, killing a ONCE task
#        for good with nothing written). ONSTART re-launches the provisioner
#        after any such reboot; a DONE-guard at the top of the wrapper and a
#        self-delete at the end make re-fires a no-op once it has completed.
#   The only `prlctl exec` calls are a few short, fixed-size schtasks commands.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_prlctl

NAME=""
PROVISIONER="$SCRIPT_DIR/Invoke-Provision.ps1"
TIMEOUT=3600
TASK="AgentProvision"
REARM_UPDATES="false"

usage() {
  echo "Usage: Start-Provision.sh --name <vm> [--provisioner <path.ps1>] [--timeout <seconds>] [--rearm-updates]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          NAME="$2"; shift 2 ;;
    --provisioner)   PROVISIONER="$2"; shift 2 ;;
    --timeout)       TIMEOUT="$2"; shift 2 ;;
    --rearm-updates) REARM_UPDATES="true"; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$NAME" ]] || usage
require_vm_config "$NAME"
load_config "$NAME"
[[ -f "$PROVISIONER" ]] || die "Provisioner not found: $PROVISIONER"

# Host + guest views of the shared "agent" scratch dir.
HOST_AGENT="$SHARED_HOST_PATH/workspace/.agent"
mkdir -p "$HOST_AGENT"
HOST_SCRIPT="$HOST_AGENT/agent-provision.ps1"
HOST_LOG="$HOST_AGENT/agent-provision.log"
HOST_DONE="$HOST_AGENT/agent-provision.DONE"
HOST_FAILED="$HOST_AGENT/agent-provision.FAILED"
# Guest UNC equivalents (\\Mac\<share>\.agent\...).
UNC="\\\\Mac\\${SHARED_NAME}\\.agent"
G_SCRIPT="$UNC\\agent-provision.ps1"
G_LOG="$UNC\\agent-provision.log"
G_DONE="$UNC\\agent-provision.DONE"
G_FAILED="$UNC\\agent-provision.FAILED"

# Provisioning downloads packages -- ensure the VM is up, reachable, and online.
if [[ "$(vm_state "$NAME")" != "running" ]]; then
  info "Starting '$NAME'"
  "$PRLCTL" start "$NAME"
fi
info "Ensuring internet (shared networking)"
"$PRLCTL" set "$NAME" --device-set net0 --type shared --connect >/dev/null
wait_for_guest "$NAME" 900

# ---------------------------------------------------------------------------
# Write the wrapped provisioner into the shared folder (transcript + markers).
# ---------------------------------------------------------------------------
info "Writing provisioner into the shared folder"
rm -f "$HOST_DONE" "$HOST_FAILED" "$HOST_LOG"
{
  # The ONSTART task re-fires on every boot until deleted: never re-run a
  # completed provision, and self-delete the task as the last act. (If a
  # reboot kills a run mid-flight, neither happens -- so the next boot
  # relaunches the provisioner, which is exactly the recovery we want.)
  printf "if (Test-Path '%s') { exit 0 }\n" "$G_DONE"
  printf "try { Start-Transcript -Path '%s' -Force | Out-Null } catch {}\n" "$G_LOG"
  # Provisioning disables automatic Windows Update so a surprise restart can't
  # interrupt the provision; --rearm-updates re-enables it as the last step.
  printf '$RearmWindowsUpdate = $%s\n' "$REARM_UPDATES"
  printf 'try {\n'
  cat "$PROVISIONER"
  printf "  Set-Content -Path '%s' -Value 'ok'\n" "$G_DONE"
  printf "} catch { \$_ | Out-String | Set-Content -Path '%s' }\n" "$G_FAILED"
  printf 'try { Stop-Transcript | Out-Null } catch {}\n'
  printf 'schtasks /delete /tn "%s" /f 2>$null | Out-Null\n' "$TASK"
} >"$HOST_SCRIPT"

# ---------------------------------------------------------------------------
# Launch it in the interactive session via a scheduled task, then detach.
# ---------------------------------------------------------------------------
info "Launching provisioner via a non-interactive (batch) scheduled task"
# NO /IT: a batch logon runs even when nobody is signed in (e.g. the guest is
# still at OOBE), yet still has a full admin token, \\Mac\<share>, and internet.
# ONSTART, not ONCE: first boots reboot at unpredictable moments (Parallels
# Tools completing its install, Windows Setup) and a reboot kills a ONCE task
# permanently -- ONSTART relaunches the provisioner after any mid-provision
# reboot, and the wrapper's DONE-guard/self-delete retire it once finished.
guest_exec "$NAME" schtasks /create /tn "$TASK" \
  /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $G_SCRIPT" \
  /sc ONSTART /ru "$GUEST_USER" /rp "$GUEST_PASSWORD" /rl HIGHEST /f >/dev/null 2>&1 \
  || die "Failed to create the provisioning scheduled task."
guest_exec "$NAME" schtasks /run /tn "$TASK" >/dev/null 2>&1 \
  || die "Failed to start the provisioning scheduled task."

delete_task() { guest_exec "$NAME" schtasks /delete /tn "$TASK" /f >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------------
# Follow progress by reading the shared-folder marker/log LOCALLY (no exec).
# ---------------------------------------------------------------------------
info "Provisioning (VS Build Tools is the long pole, ~15-30 min). Following progress..."
waited=0; step=20; last_shown=""
while (( waited < TIMEOUT )); do
  if [[ -s "$HOST_DONE" ]]; then
    [[ -f "$HOST_LOG" ]] && tail -8 "$HOST_LOG" | tr -d '\r' | sed 's/^/   /'
    delete_task
    info "Provisioning finished"
    log "Next: ./Save-BaseSnapshot.sh --name \"$NAME\""
    exit 0
  fi
  if [[ -s "$HOST_FAILED" ]]; then
    delete_task
    warn "Provisioner reported a failure:"
    tr -d '\r' <"$HOST_FAILED" | sed 's/^/   /'
    die "Provisioning failed. Full transcript: $HOST_LOG"
  fi
  # Heartbeat: last transcript line if present, else elapsed time.
  latest="$( { tail -1 "$HOST_LOG" 2>/dev/null || true; } | tr -d '\r' )"
  if [[ -n "$latest" && "$latest" != "$last_shown" ]]; then
    log "$latest"; last_shown="$latest"
  else
    log "...working (${waited}s elapsed)"
  fi
  sleep "$step"; waited=$((waited + step))
done

delete_task
die "Provisioning did not finish within ${TIMEOUT}s. Transcript: $HOST_LOG"
