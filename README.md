# Agent Sandbox VM

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey.svg)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Hyper-V](https://img.shields.io/badge/Hyper--V-Gen%202%20VM-0078D6.svg?logo=windows&logoColor=white)](https://learn.microsoft.com/virtualization/hyper-v-on-windows/)
[![Swift](https://img.shields.io/badge/Swift-Virtualization.framework-F05138.svg?logo=swift&logoColor=white)](macos/README.md)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-ready-D97757.svg?logo=anthropic&logoColor=white)](https://claude.ai/code)

A fully scripted Hyper-V sandbox for running agent tools on Windows with native MSVC toolchain support. The agent runs inside an isolated VM, builds real Windows binaries, and artifacts are automatically extracted back to your host.

> macOS host note: this repository also includes an experimental Apple Silicon `Virtualization.framework` implementation under [`macos/`](macos/README.md). It supports macOS guests from Apple IPSW restore images and has an experimental generic EFI path for Windows ARM64 media. It is not feature-equivalent to the Hyper-V workflow because Apple does not expose Windows IPSW install, PowerShell Direct, Hyper-V checkpoints, or Windows vTPM parity through `Virtualization.framework`.
>
> For a full **Windows 11 ARM64** sandbox on Apple Silicon (unattended install, toolchain provisioning, clean-base snapshots, and agentless `prlctl exec` control — near parity with the Hyper-V path), see the **Parallels Desktop** workflow under [`macos/parallels/`](macos/parallels/README.md).

## Requirements

- Windows 10/11 **Pro or Enterprise** (Hyper-V required)
- A Windows ISO -- supply your own (e.g. [Media Creation Tool](https://www.microsoft.com/software-download/windows11)) or let Bootstrap build one from [UUP dump](https://uupdump.net) (defaults to Windows Server 2025, amd64)
- A [Claude Pro subscription](https://claude.ai) (no API key needed) to use Claude Code, and/or an [OpenAI API key](https://platform.openai.com/api-keys) to use Codex CLI — at least one is required
- ~15 GB free disk space
- Run everything as **Administrator**

---

## Setup (one-time)

### Step 1 -- Bootstrap

```powershell
.\Bootstrap.ps1
```

This creates the VM, partitions the VHDX, and applies Windows directly via DISM (no DVD boot). Optionally provide an `autounattend.xml` from [schneegans.de](https://schneegans.de/windows/unattend-generator/) to skip OOBE.

Bootstrap prompts for a VM name. Each VM gets its own config, credentials, and shared folder under `~\.agent-sandbox\vms\<VMName>\`; `~\.agent-sandbox\config.json` remains the current/default VM for commands that omit `-VMName`.

When asked for an ISO, you can either point at one you already have or answer `y` to build one from [UUP dump](https://uupdump.net). The build downloads UUP files straight from Microsoft's update servers and compiles them into an ISO (30-90 minutes, ~25 GB of free disk during the build). It defaults to the newest **Windows Server 2025** build on **amd64** (x86_64), and both the version and architecture can be changed at the prompt. The same step is available standalone:

```powershell
.\scripts\New-UUPDumpISO.ps1                                              # Windows Server 2025, amd64
.\scripts\New-UUPDumpISO.ps1 -Version "Windows 11, version 25H2" -Architecture arm64
.\scripts\New-UUPDumpISO.ps1 -BuildId <uuid> -Edition SERVERDATACENTER   # pin an exact build
```

### Step 2 -- Complete Windows OOBE

If you didn't provide `autounattend.xml`, complete the setup prompts in the VM console.

### Step 3 -- Provision the VM

```powershell
.\scripts\Start-Provision.ps1 -VMName AgentDevSandbox
```

This runs **on your host** and:
- Switches the VM to Default Switch (internet access)
- Copies VS Build Tools offline layout + VM-side setup scripts into the VM
- Opens the VM console

Then **inside the VM**, run:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Invoke-Provision.ps1
```

This installs PowerShell 7 (`pwsh`), VS Build Tools, Rust (MSVC), Node.js, Python (with the `uv` package/venv manager), Git, GitHub CLI (`gh`), Windows Terminal, Oh My Posh (with CascadiaCode Nerd Font), TTD command line utility, Claude Code, and OpenAI Codex CLI. It then prompts you to authenticate with Claude via OAuth — skip this if you only need Codex CLI.

### Step 4 -- Snapshot

After provisioning completes, **shut down the VM**, then on the host:

```powershell
.\scripts\Save-BaseSnapshot.ps1 -VMName AgentDevSandbox
```

---

## Daily usage

### Start a session

```powershell
# Basic session (no internet in VM -- full isolation)
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp

# With internet (for cargo fetch, npm install, etc.)
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Internet

# Clean session from snapshot
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Restore -Internet

# Auto-extract artifacts when VM shuts down
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Internet -ExtractOnExit
```

Your project is copied to `C:\workspace` inside the VM. Then:

```powershell
cd C:\workspace
claude   # Claude Code
codex    # OpenAI Codex CLI
```

### Extract artifacts

```powershell
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -DestPath C:\Projects\myapp\artifacts
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -WaitForShutdown
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -ExtraPatterns "*.json","*.toml"
```

### Kernel debugging

Kernel debugging uses KDNET between a debugger machine and a VM/debuggee. The debugger machine can be the Hyper-V host or another VM. WinDbg is only needed on the debugger machine.

On the debugger machine, optionally install WinDbg and open the KDNET firewall port. If the debugger is a provisioned VM, use the copy at `C:\Setup-KernelDebugger.ps1`; on the repository host, use `.\scripts\Setup-KernelDebugger.ps1`.

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-KernelDebugger.ps1 -InstallWinDbg
```

The firewall rule defaults to `LocalSubnet` on `Domain,Private` profiles; pass `-RemoteAddress <debuggee-ip-or-cidr>` to restrict it to a specific VM address or subnet, and `-FirewallProfile Any` only if the debugger intentionally listens on every network profile. If the default UDP port is reserved on the debugger machine, the script fails before creating the rule; rerun with a different `-Port` and use the same value on the debuggee script. This debugger-host script is the source of truth for the KDNET key and matching WinDbg command.

On the Hyper-V host, shut down the debuggee VM and disable Secure Boot so the guest can change BCDEdit debug settings:

```powershell
.\scripts\Setup-KernelDebugger.ps1 -VMName AgentDevSandbox -DisableVmSecureBoot -SkipFirewall
```

Inside the VM/debuggee, run as Administrator with the debugger machine IP and the key printed by `Setup-KernelDebugger.ps1`:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-KernelDebuggee.ps1 -DebuggerHostIp <debugger-ip> -Key <key>
```

This also enables test signing (`bcdedit /set testsigning on`) so test-signed drivers can load on the debuggee. Pass `-SkipTestSigning` to leave test signing untouched.

Reboot the debuggee VM, then start WinDbg on the debugger machine with the command printed by `Setup-KernelDebugger.ps1`:

```powershell
windbgx -k net:port=50000,key=<key>
```

To disable kernel debugging and test signing inside the VM:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-KernelDebuggee.ps1 -Disable
```

Pass `-SkipTestSigning` on the disable path too to turn off kernel debugging while leaving the current test-signing boot policy unchanged (for example, when test signing was enabled independently of this script).

After the debuggee VM shuts down, Secure Boot can be restored on the Hyper-V host:

```powershell
.\scripts\Setup-KernelDebugger.ps1 -VMName AgentDevSandbox -EnableVmSecureBoot -SkipFirewall
```

### Restore to clean state

```powershell
Stop-VM -Name AgentDevSandbox -Force
Restore-VMCheckpoint -VMName AgentDevSandbox -Name CleanProvisionedBase -Confirm:$false
```

---

## File structure

```
agent-sandbox-vm/
|-- Bootstrap.ps1              # One-time host setup
|-- Start-Session.ps1          # Daily session launcher
|
|-- scripts/
|   |-- New-AgentVM.ps1        # Creates the Hyper-V VM (Gen 2, TPM, Secure Boot)
|   |-- AgentSandboxConfig.ps1 # Shared per-VM config/credential resolver
|   |-- Install-Windows.ps1    # Applies Windows to VHDX via DISM (no DVD boot)
|   |-- New-UUPDumpISO.ps1     # Optional: builds a Windows ISO from UUP dump
|   |-- Attach-ISO.ps1         # Alternative: boot from DVD if DISM not needed
|   |-- Start-Provision.ps1    # Host-side: switches network, copies files into VM
|   |-- Invoke-Provision.ps1   # VM-side: installs toolchain + Claude Code
|   |-- Setup-KernelDebugger.ps1 # Host-side: WinDbg + KDNET firewall setup
|   |-- Setup-KernelDebuggee.ps1 # VM-side: BCD/KDNET debuggee setup
|   |-- Save-BaseSnapshot.ps1  # Takes the clean base snapshot
|   |-- Save-VMCredentials.ps1 # Stores VM credentials encrypted on host
|   +-- Copy-Artifacts.ps1     # Extracts build outputs from VM to host
|
+-- vm/
    +-- Start-Agent.ps1        # Optional: VM startup script
```

---

## How it works

**Windows installation**: Instead of booting from DVD (which can fail with certain ISOs on Gen 2 VMs), `Install-Windows.ps1` mounts the ISO on the host, partitions the VHDX, and applies the image via DISM.

**Provisioning**: `Start-Provision.ps1` switches the VM to Default Switch for internet, copies the VS Build Tools cache and provision script via PowerShell Direct (VMBus -- no network needed), then you run the provisioner inside the VM.

**Sessions**: `Start-Session.ps1` copies your project into the VM via PowerShell Direct, optionally enables internet, and connects you to the console. Use `-Restore` for a clean-room build from snapshot.

**Artifacts**: `Copy-Artifacts.ps1` pulls build outputs from the VM to your host via PowerShell Direct.

**Multiple VMs**: Host scripts accept `-VMName <name>` to target any VM created by Bootstrap. Without `-VMName`, scripts use the current/default config at `~\.agent-sandbox\config.json`.

**Configuration**: Bootstrap writes a per-VM config at `~\.agent-sandbox\vms\<VMName>\config.json` and also updates `~\.agent-sandbox\config.json` as the current/default VM. Credentials are stored per VM at `~\.agent-sandbox\vms\<VMName>\vm-cred.xml`; legacy root credentials remain valid only for migrated legacy-layout configs.

---

## Networking

| Mode | Switch | Use case |
|------|--------|----------|
| Isolated (default) | Agent-Internal | No internet -- full sandbox |
| Internet | Default Switch | cargo fetch, npm install, OAuth |

Use `-Internet` flag on `Start-Session.ps1` to enable internet access.

```powershell
.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Internet
```

---

## Customization

### Oh My Posh theme

Provisioning installs [Oh My Posh](https://ohmyposh.dev) with the `jandedobbeleer` theme and the CascadiaCode Nerd Font. To switch themes, edit the PowerShell profile inside the VM:

```powershell
notepad $PROFILE
```

Change the theme filename on the `oh-my-posh init` line:

```powershell
# Before
oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\jandedobbeleer.omp.json" | Invoke-Expression

# After (example: switch to the tokyo theme)
oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\tokyo.omp.json" | Invoke-Expression
```

List all bundled themes:

```powershell
Get-ChildItem $env:POSH_THEMES_PATH -Filter *.omp.json | Select-Object -ExpandProperty BaseName
```

Or browse previews at [ohmyposh.dev/docs/themes](https://ohmyposh.dev/docs/themes). Reload the profile after saving:

```powershell
. $PROFILE
```

To persist the change across sessions, shut down the VM and re-snapshot after editing the profile.

---

## Troubleshooting

**PowerShell Direct connection fails**
Ensure the VM has finished booting and you've logged in at least once. PSRemoting must be enabled (done by Invoke-Provision.ps1).

**VM has no internet**
Use `-Internet` flag or manually switch: `Connect-VMNetworkAdapter -VMName AgentDevSandbox -SwitchName "Default Switch"`

**Wrong VM starts**
Pass `-VMName <name>` explicitly. Commands without `-VMName` use the current/default config from the most recent `Bootstrap.ps1` run.

**Re-authentication when OAuth expires**
Start the VM with internet, run `claude login` inside it, shut down, take a new snapshot.
