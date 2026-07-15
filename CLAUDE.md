# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A PowerShell-based infrastructure toolkit that creates an isolated Hyper-V sandbox VM on Windows, purpose-built for running agent tools with a native MSVC toolchain. The agent runs inside the VM, builds real Windows binaries (C++, Rust), and artifacts are extracted back to the host via PowerShell Direct (VMBus — no network required).

**Requirements to use this project:** Windows 10/11 Pro/Enterprise with Hyper-V, a Windows 11 ISO, and a Claude Pro subscription. All scripts must be run as Administrator.

## Key Commands

### First-Time Setup

```powershell
# Step 1: Create VM, partition VHDX, apply Windows via DISM
# (prompts for an ISO path, or optionally builds one from UUP dump)
.\Bootstrap.ps1

# Optional: build a Windows ISO from UUP dump instead of supplying your own
.\scripts\New-UUPDumpISO.ps1                       # newest Windows Server 2025, amd64
.\scripts\New-UUPDumpISO.ps1 -Version "Windows 11, version 25H2" -Architecture arm64

# Step 2: Provision toolchain (run on host — switches network, copies files into VM)
.\scripts\Start-Provision.ps1 -VMName AgentDevSandbox
# Then inside the VM:
powershell -ExecutionPolicy RemoteSigned -File C:\Invoke-Provision.ps1

# Step 3: Save the clean snapshot (shut down VM first)
.\scripts\Save-BaseSnapshot.ps1 -VMName AgentDevSandbox
```

### Daily Development

```powershell
# Basic session (VM fully isolated, no internet)
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp

# With internet (needed for cargo fetch, npm install, etc.)
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Internet

# Restore to clean snapshot before starting (reproducible build)
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Restore -Internet

# Auto-extract artifacts when VM shuts down
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Internet -ExtractOnExit
```

Inside the VM after session starts:
```powershell
cd C:\workspace
claude
```

### Artifact Extraction

```powershell
# Extract .exe/.dll/.pdb from C:\workspace\target\release
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -DestPath C:\Projects\myapp\artifacts

# Wait for VM shutdown then extract
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -WaitForShutdown

# Include additional file types
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -ExtraPatterns "*.json","*.toml"
```

### VM Management

```powershell
# Manually restore to clean snapshot
Stop-VM -Name AgentDevSandbox -Force
Restore-VMCheckpoint -VMName AgentDevSandbox -Name CleanProvisionedBase -Confirm:$false

# Re-authenticate when OAuth expires (run inside VM with internet)
claude login
# Then shut down and re-snapshot
```

## Architecture

### Script Roles

| Script | Where It Runs | Purpose |
|--------|---------------|---------|
| `Bootstrap.ps1` | Host | One-time setup orchestrator |
| `scripts/New-AgentVM.ps1` | Host | Creates Gen 2 VM (TPM, Secure Boot, SCSI layout) |
| `scripts/Install-Windows.ps1` | Host | Applies Windows to VHDX via DISM (bypasses DVD boot) |
| `scripts/AgentSandboxConfig.ps1` | Host | Resolves per-VM config and credentials |
| `scripts/New-UUPDumpISO.ps1` | Host | Optional: builds a Windows ISO from UUP dump (defaults to Windows Server 2025 amd64; `-Version`/`-Architecture`/`-Edition` selectable) |
| `scripts/Start-Provision.ps1` | Host | Switches to Default Switch, copies VS layout + provisioner into VM |
| `scripts/Invoke-Provision.ps1` | **VM** | Installs VS Build Tools, Rust (MSVC), Node.js, Claude Code, enables PSRemoting |
| `scripts/Save-BaseSnapshot.ps1` | Host | Captures `CleanProvisionedBase` checkpoint |
| `scripts/Save-VMCredentials.ps1` | Host | Encrypts VM creds to `~/.agent-sandbox/vms/<VMName>/vm-cred.xml` |
| `Start-Session.ps1` | Host | Daily driver: restore/switch network/sync project/open console |
| `scripts/Copy-Artifacts.ps1` | Host | Pulls build outputs from VM via PowerShell Direct |
| `scripts/Open-VMConsole.ps1` | Host | Launches `vmconnect.exe`, pre-writing the saved-config XML to skip Hyper-V's display dialog |
| `vm/Start-Agent.ps1` | VM | Optional VM startup script |

### File Transfer Strategy

All host↔VM file transfer uses **PowerShell Direct** (VMBus), which works without any network configuration:
- Project sync into VM: `Copy-Item -ToSession` (excludes `artifacts/`, `.git/`, `target/`)
- Artifact extraction: `Copy-Item -FromSession`
- Pre-boot fallback: robocopy to the VM's configured SMB share

### Networking

Two modes, switched via `Connect-VMNetworkAdapter`:
- **`Agent-Internal`** (default): internal switch, VM can reach host but not internet
- **`Default Switch`**: NAT switch, gives VM internet access for package fetches

### Configuration

Bootstrap writes per-VM config to `~/.agent-sandbox/vms/<VMName>/config.json` and also updates `~/.agent-sandbox/config.json` as the current/default VM for commands that omit `-VMName`:

```json
{
  "VMName": "AgentDevSandbox",
  "VMPath": "D:\\Hyper-V\\AgentDevSandbox",
  "SharedDrive": "D:\\Hyper-V\\AgentDevSandbox\\Shared",
  "ShareName": "AgentSandboxShare-AgentDevSandbox-<hash>",
  "CacheRoot": "D:\\AgentSandboxCache",
  "CredPath": "%USERPROFILE%\\.agent-sandbox\\vms\\AgentDevSandbox",
  "ProjectsRoot": "D:\\workspace"
}
```

Credentials are stored per VM as encrypted `vm-cred.xml` files (only readable by the host Windows user who created them). Legacy `~/.agent-sandbox/vm-cred.xml` remains valid only for migrated legacy-layout configs.

### VM Spec (set in `New-AgentVM.ps1`)

- Gen 2, 80 GB dynamic VHDX, 4 vCPU, 4 GB RAM (dynamic 2–4 GB)
- Secure Boot + TPM 2.0 (required for Windows 11)
- HDD on SCSI controller 0, DVD on SCSI controller 1 — separated to avoid Gen 2 boot ordering issues
- Automatic checkpoints disabled; checkpoint type set to Production

### Toolchain Inside VM (installed by `Invoke-Provision.ps1`)

- PowerShell 7 (`pwsh` via winget `Microsoft.PowerShell`)
- VS Build Tools 2026 with `VCTools` workload + Windows 11 SDK 26100 + CMake
- Rust stable (`x86_64-pc-windows-msvc`) with clippy and rustfmt
- Node.js (latest via winget)
- Python 3.13 (`Python.Python.3.13` via winget)
- uv (`astral-sh.uv` via winget) — Python package/venv manager (`uv venv`, `uv run`)
- GitHub CLI (`gh` via winget)
- TTD command line utility (`Microsoft.TimeTravelDebugging` via winget)
- Claude Code (`@anthropic-ai/claude-code`) authenticated via OAuth
- OpenAI Codex CLI (`@openai/codex` via npm)

## macOS Host (Experimental)

`macos/` is a separate, experimental implementation for Apple Silicon hosts backed by
`Virtualization.framework`. It is **not** feature-equivalent to the Hyper-V workflow: macOS guests
(installed from Apple IPSW restore images) are the supported path, and Windows guests are limited
because Apple exposes no Windows IPSW install, PowerShell Direct, Hyper-V checkpoints, or vTPM. See
`macos/README.md` for the full story.

### Components

| Script | Where It Runs | Purpose |
|--------|---------------|---------|
| `macos/Sources/vmctl/main.swift` | Host | The `vmctl` Swift CLI — all VM logic (create/install/run/stop/snapshot/copy-out/list/delete) |
| `macos/scripts/vmctl.sh` | Host | Wrapper that rebuilds + re-signs `vmctl` on demand, then execs it — **all other scripts go through this** |
| `macos/scripts/Build-vmctl.sh` | Host | `swift build -c release` + ad-hoc `codesign` with `vmctl.entitlements` |
| `macos/scripts/Bootstrap.sh` | Host | `create` (+ optional `install`) orchestrator |
| `macos/scripts/New-AgentVM.sh` | Host | Thin alias for `vmctl create` |
| `macos/scripts/Install-Guest.sh` | Host | Thin alias for `vmctl install` |
| `macos/scripts/Start-Session.sh` | Host | Restore/sync project into the shared dir/`vmctl run` |
| `macos/scripts/Save-BaseSnapshot.sh` | Host | Thin alias for `vmctl snapshot save` |
| `macos/scripts/Copy-Artifacts.sh` | Host | Thin alias for `vmctl copy-out` |

### Conventions

- VM bundles live at `~/.agent-sandbox/macos-vms/<name>.agentvm/` (override the root with the
  `AGENT_SANDBOX_VM_ROOT` env var). A bundle holds `config.json`, `Disk.raw`, VZ platform metadata,
  `Shared/` (host↔guest VirtioFS), `Snapshots/`, and `run.pid` while running.
- Host↔guest transfer is via the VirtioFS shared directory (`Shared/workspace`), mounted in a macOS
  guest at `/Volumes/My Shared Files/workspace`. There is no PowerShell Direct equivalent.
- Snapshots are file copies of the bundle's disk/metadata into `Snapshots/<label>/` (cheap via APFS
  cloning); save/restore refuse while the VM is running.
- The binary must be code-signed with the `com.apple.security.virtualization` entitlement; bridged
  networking additionally needs `com.apple.vm.networking` under a real signing identity (ad-hoc
  signing only covers NAT/isolated).
- `macos/scripts/Build-vmctl.sh` is the **single** sanctioned place that runs `swift build` + `codesign`; `vmctl.sh` invokes it on demand. Other scripts must not call `swift build` or the `vmctl` binary directly — they go through `macos/scripts/vmctl.sh`.

## Conventions

- All scripts use `$ErrorActionPreference = "Stop"` — any uncaught error aborts execution.
- Scripts that create directories use `New-Item -Force` to be idempotent.
- `robocopy` exit codes 0–7 are success; the scripts treat non-zero robocopy exit as non-fatal (pipe to `Out-Null`).
- The VS Build Tools offline layout (`D:\AgentSandboxCache\vs-layout\`) is downloaded once during Bootstrap and reused on every provision — avoid deleting it.
- `Copy-Artifacts.ps1` defaults to extracting `*.exe`, `*.dll`, `*.pdb` from `C:\workspace\target\release`; pass `-ExtraPatterns` for additional types.
- All console launches go through `scripts/Open-VMConsole.ps1`, which pre-populates the per-VM `vmconnect.rdp.<GUID>.config` (windowed 1920x1080) so Hyper-V's display-configuration dialog is skipped on first launch. Don't add raw `vmconnect.exe` calls.
