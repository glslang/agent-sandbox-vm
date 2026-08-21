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

This installs PowerShell 7 (`pwsh`), VS Build Tools, Rust (MSVC), Node.js, Python (with the `uv` package/venv manager), Git, GitHub CLI (`gh`), [GitHub Stacked PRs](https://github.github.com/gh-stack/) (`gh stack`), Windows Terminal, Oh My Posh (with CascadiaCode Nerd Font), TTD command line utility, Claude Code, OpenAI Codex CLI, and [Ollama](https://docs.ollama.com/quickstart) for local models. It then prompts you to authenticate with Claude via OAuth — skip this if you only need Codex CLI.

Ollama is installed without any models — pull one before snapshotting if you want it in isolated sessions. See [Local models with Ollama](#local-models-with-ollama).

The `gh stack` step is best-effort: the extension always installs, but the matching agent skill is fetched through the GitHub API and needs an authenticated `gh`, which a fresh VM does not have. If the provisioner reports that, finish it before snapshotting — see [Stacked pull requests](#stacked-pull-requests).

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
ollama   # local models (see below)
```

### Extract artifacts

```powershell
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -DestPath C:\Projects\myapp\artifacts
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -WaitForShutdown
.\scripts\Copy-Artifacts.ps1 -VMName AgentDevSandbox -ExtraPatterns "*.json","*.toml"
```

### Stacked pull requests

The VM ships [GitHub Stacked PRs](https://github.github.com/gh-stack/) — the `gh stack` extension, which breaks a large change into a chain of small PRs that each build on the one below it. Provisioning also *tries* to install the gh-stack agent skill, so Claude Code and Codex know how to drive it, but that half needs an authenticated `gh` and so usually stays pending on a fresh VM until you finish it with the [recovery step](#if-the-skill-is-still-pending) below.

```powershell
gh stack init              # start a stack (first branch targets the trunk)
gh stack add api-endpoints # add a branch on top
gh stack push              # push every branch in the stack
gh stack submit            # open/update one PR per branch, linked as a stack
gh stack view              # show the stack with per-layer PR status
gh stack sync              # fetch, cascade-rebase, and push in one step
```

`gh stack` talks to GitHub, so start the session with `-Internet` and authenticate once inside the VM:

```powershell
gh auth login
```

#### If the skill is still pending

If provisioning warned that the gh-stack skill was skipped (it needs an authenticated `gh`), install it after logging in and then re-take the base snapshot so it persists:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Install-GhStack.ps1 -SkipExtension
```

`C:\Install-GhStack.ps1` is idempotent, so re-running it to upgrade the extension is always safe. It installs the skill at user scope (`~\.claude\skills`, `~\.codex\skills`), which is why it applies to every project you sync into `C:\workspace`.

### Local models with Ollama

[Ollama](https://docs.ollama.com/quickstart) runs open-weight models on the VM itself and serves them over HTTP on `127.0.0.1:11434`. The server starts at login; models live in `%USERPROFILE%\.ollama\models`.

Provisioning installs the runtime but **no models** — pulling one needs internet, so start the session with `-Internet` the first time:

```powershell
ollama pull gemma3:1b   # download a model
ollama run gemma3:1b    # chat with it
ollama list             # show what is downloaded
ollama ps               # show what is currently loaded in memory
```

Once a model is pulled it answers with no internet at all, which is the point: pull it **before** taking the base snapshot and every isolated session starts with it already there.

```powershell
# inside the VM, with -Internet, before shutting down to snapshot
ollama pull gemma3:1b
```

Anything on the VM can then reach it over the local API:

```powershell
$body = '{"model":"gemma3:1b","prompt":"why is the sky blue?","stream":false}'
(Invoke-RestMethod http://127.0.0.1:11434/api/generate -Method Post -Body $body).response
```

Size the model to the VM, not to your host. The sandbox uses dynamic memory that grows on demand between 2 GB and a **4 GB ceiling** (`New-AgentVM.ps1` sets `-MaximumBytes 4GB`), and it is that ceiling — not the current allocation — that caps model size: a model has to fit in roughly 3 GB alongside the toolchain, which puts 1B–4B parameter models at default quantization in range. Larger models either swap badly or fail to load. Raise the ceiling before reaching for a bigger one:

```powershell
# on the host, with the VM shut down
Set-VMMemory -VMName AgentDevSandbox -MaximumBytes 8GB
```

Every pulled model also consumes VHDX space, which counts against the 80 GB disk.

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

The same run opens host access so binaries can be copied onto the debuggee: it enables PowerShell remoting, adds an inbound WinRM firewall rule (`Agent Sandbox Debuggee WinRM`, TCP 5985), and sets `LocalAccountTokenFilterPolicy` to 1 so a local admin account keeps its elevated token over the network.

The rule defaults to `LocalSubnet` on every firewall profile, since a Hyper-V internal switch is usually classified Public; narrow it with `-WinRmRemoteAddress <debugger-ip>` and `-WinRmFirewallProfile Private`. Firewall allow rules are additive, so a narrow rule cannot claw back the wider exceptions `Enable-PSRemoting` creates — the script therefore rescopes those to the same allowlist. A requested profile is enforced the same way: an exception overlapping the requested profiles is narrowed to that overlap, and one entirely outside them is disabled, so `-WinRmFirewallProfile Private` cannot be defeated by a Public exception left enabled. The default `Any` means no profile restriction was requested and leaves profiles as found — this only ever narrows other rules, never widens them.

Prior scope, profile, and enabled state of every rule it touches, plus any previous `LocalAccountTokenFilterPolicy` value, go to `C:\ProgramData\agent-sandbox\kernel-debuggee-remoting.json` so `-Disable` puts them back exactly. Rerunning enable never overwrites that record.

`-WinRmPort` points the rule and the printed connect command at another port; the script creates no listener of its own, so anything other than 5985 needs a listener you configured yourself, and the run warns when nothing is bound to the port. Port 5985 is rescoped either way, because `Enable-PSRemoting` reopens the default HTTP listener there whatever port you pick. The printed command's transport follows the listener actually configured on the port, falling back to the port number only when the WSMan config cannot be read. Pass `-SkipRemoting` to leave remoting configuration untouched.

From the debugger host, copy test binaries in with:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value <debuggee-ip> -Concatenate -Force
$session = New-PSSession -ComputerName <debuggee-ip> -Credential (Get-Credential)
Copy-Item -ToSession $session C:\build\driver.sys -Destination C:\workspace\
```

If KDNET claims the debuggee's only network adapter and guest networking stops working, add a second network adapter for WinRM, or copy over PowerShell Direct from the Hyper-V host (`New-PSSession -VMName <vm-name>`), which needs no guest network.

Reboot the debuggee VM, then start WinDbg on the debugger machine with the command printed by `Setup-KernelDebugger.ps1`:

```powershell
windbgx -k net:port=50000,key=<key>
```

To disable kernel debugging and test signing inside the VM:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-KernelDebuggee.ps1 -Disable
```

Pass `-SkipTestSigning` on the disable path too to turn off kernel debugging while leaving the current test-signing boot policy unchanged (for example, when test signing was enabled independently of this script).

The disable path also removes the script's WinRM firewall rule and restores the rescoped WinRM exceptions and the `LocalAccountTokenFilterPolicy` value from the recorded state, leaving WinRM itself running because provisioned sandbox VMs enable it during provisioning. Without that state file there is no evidence the script set any of it, so it removes only its own firewall rule and reports the `LocalAccountTokenFilterPolicy` value it found rather than deleting one that was configured independently. Pass `-SkipRemoting` to leave everything in place.

After the debuggee VM shuts down, Secure Boot can be restored on the Hyper-V host:

```powershell
.\scripts\Setup-KernelDebugger.ps1 -VMName AgentDevSandbox -EnableVmSecureBoot -SkipFirewall
```

### Remote MCP over SSH

An MCP server that has to run on Windows -- a debugger, above all -- does not have to run where the
harness driving it runs. `Setup-RemoteMcp.ps1` opens ssh into the VM so a client on another machine
can start a **stdio** MCP server here and talk to it over the ssh channel, which is already a pair of
pipes. Neither side needs transport code, and a client disconnect still releases whatever the server
was holding: closing the channel closes the remote stdin.

Inside the VM, run as Administrator with the client's public key:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-RemoteMcp.ps1 `
    -PublicKey "ssh-ed25519 AAAA... you@client" `
    -ClientAddress <client-ip> `
    -ServerCommand C:\tools\windbg-mcp.exe
```

`-PublicKeyPath <file>` takes the key from a `.pub` file instead. `-ServerCommand` is only used to
print the client-side registration, so it can be left off and filled in later, and
`-ClientIdentityFile` names the private half in the printed `~/.ssh/config` block when it is not the
default `~/.ssh/id_ed25519` -- with `BatchMode yes`, pointing at the wrong key fails authentication
without a prompt. The run ends with the
`~/.ssh/config` block, the handshake probe, and the `claude mcp add` line to paste on the client.

Four things have to be true for this to work, and three of them fail silently, which is why they are
scripted rather than described:

- **The firewall.** The rule the OpenSSH capability installs covers `Domain` and `Private` only, and
  a hypervisor's guest network usually comes up `Public` -- so sshd is running and listening and
  looks correct from inside the guest while the client's SYNs are dropped. That presents as ssh
  *hanging* after `Connecting to <address> port 22`, where nothing listening at all would have said
  `Connection refused` at once. The script adds its own rule on `-FirewallProfile` (default `Any`)
  scoped to `-ClientAddress`, and narrows every other inbound rule on that port to the same
  allowlist -- firewall allow rules are additive, so a narrow rule cannot claw back a wider one.
  A rule counts as being on that port whether its filter names the port exactly or a range spanning
  it, and a rule that cannot be narrowed -- one managed by group policy, typically -- fails the run
  rather than letting it report a boundary the rule still overrides. One whose filter is `LocalPort Any` is *reported* rather than rescoped: such a rule is usually
  scoped to a program rather than to a port, making it an app's inbound rule rather than an ssh
  hole, and narrowing every one of them to the ssh client would take the VM's other inbound traffic
  down with it. Reclassifying the network to `Private` instead would work in one line, at the cost of activating
  every other `Private` inbound rule: file and printer sharing, network discovery.
- **The default shell.** OpenSSH runs an exec request through it. `cmd /c` hands the child the
  inherited pipe handles and stays out of the way; PowerShell captures the output through its own
  pipeline and applies its output encoding, which can rewrite the line endings underneath
  line-delimited JSON-RPC, and serializes its progress and error streams as CLIXML on stderr. Either
  one corrupts the transport. The script points `HKLM:\SOFTWARE\OpenSSH\DefaultShell` at `cmd.exe`,
  and corrects `DefaultShellCommandOption` beside it when it is set to something else -- a machine
  configured for a Unix-style or PowerShell shell carries `-c` or `-Command` there, and sshd would
  then run `cmd.exe -c ...`, which cmd does not understand. `-SkipDefaultShell` leaves both alone
  for a VM where something else owns that setting.
- **Which authorized-keys file.** For a member of the Administrators group -- which the VM user is if
  you are kernel debugging -- sshd ignores `~/.ssh/authorized_keys` and reads
  `C:\ProgramData\ssh\administrators_authorized_keys`. A key in the other file is not an error
  anywhere; it is just a login that never authenticates. Membership is resolved through nested
  groups, since sshd reads it off the logon token. Where it cannot be resolved -- a domain group in
  the chain, which no local lookup can expand -- the run refuses to guess and stops before changing
  anything, naming the group it could not read; `-AuthorizedKeysFile Administrators` or
  `-AuthorizedKeysFile PerUser` settles it. The summary always names the file it used.
- **Its ACL.** sshd refuses an authorized-keys file any other principal can write, and logs the
  refusal nowhere you would think to look. The script rebuilds the file's DACL to grant only
  Administrators and SYSTEM, by well-known SID rather than by group name so it works on a
  non-English Windows too. Rebuilt rather than amended: `icacls /inheritance:r /grant` reads like it
  tightens a file, but `/inheritance:r` drops only *inherited* entries and `/grant` only adds or
  updates the trustees it names, so an explicit entry for anyone else would survive both. Since
  rebuilding is destructive -- an entry another account or a management tool relied on goes with it
  -- the DACL being replaced is recorded first, and `-Disable` puts it back.

Environment matters differently over ssh: the session inherits machine and user variables from the
registry but **nothing** from a PowerShell `$PROFILE`, so a server configured by environment variable
needs those set machine-wide. One configured by a file under the user profile -- windbg-mcp's
`%USERPROFILE%\.windbg-mcp\profiles.json`, for instance -- is immune to how the process was started,
and is the better place for anything secret.

Windows OpenSSH hands a member of the Administrators group a full, unfiltered token, so a server's
elevation-only tools do work over this. That is the host's logon policy rather than a guarantee, and
the printed summary includes the one-line check.

To close it again:

```powershell
powershell -ExecutionPolicy RemoteSigned -File C:\Setup-RemoteMcp.ps1 -Disable
```

Prior scope, profile, and enabled state of every rule it touched, the previous default shell, the
sshd startup type and running state, the DACL of every authorized-keys file it rebuilt, and the keys
it installed go to
`C:\ProgramData\agent-sandbox\remote-mcp-ssh.json` so `-Disable` puts them back exactly. Rerunning
enable never overwrites that record, and a run that fails part way still records what it had already
changed -- a machine left modified with nothing written down is one `-Disable` cannot help, so a run
that changes the machine and then cannot write the record fails rather than reporting success. A record
that exists but cannot be parsed stops the run before it changes anything, rather than being taken
for no record at all: restore or move the file and rerun.

The record also tracks *which* components the script actually wrote, so `-Disable` only reverts
those: after an enable with `-SkipDefaultShell`, it leaves a `DefaultShell` someone else configured
alone rather than deleting it. And it survives a `-Disable` that could not finish -- a firewall rule
held by group policy, a `-Skip` switch -- so a later run can pick up where that one stopped; the run
says what is still outstanding. What that run *did* put back is dropped from the record rather than
carried, so a later `-Disable` cannot re-apply a value from before the first enable over whatever was
configured in the meantime.

`-Disable` leaves the OpenSSH capability and its host keys installed, because removing them would
change the fingerprint every client has already accepted; `-SkipKeys` keeps the installed keys when
only the network exposure is being closed.

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
|   |-- Install-GhStack.ps1    # VM-side: installs `gh stack` + the gh-stack skill
|   |-- Setup-KernelDebugger.ps1 # Host-side: WinDbg + KDNET firewall setup
|   |-- Setup-KernelDebuggee.ps1 # VM-side: BCD/KDNET debuggee setup
|   |-- Setup-RemoteMcp.ps1    # VM-side: ssh access for a remote MCP client
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
