# Parallels Windows-on-ARM sandbox (macOS host)

A `prlctl`-driven workflow that stands up an isolated **Windows 11 ARM64** agent
sandbox on Apple Silicon using **Parallels Desktop** — the piece the
`Virtualization.framework` path in [`../`](../README.md) deliberately cannot do
(no Windows install, no vTPM, no in-guest control channel).

This is the macOS analog of the top-level Hyper-V PowerShell workflow, and it
reaches near feature-parity because Parallels supplies everything VZ lacks:

| Capability | Hyper-V (`../../`) | Parallels (`prlctl`) |
|---|---|---|
| Create Win11 VM (TPM, Secure Boot) | `New-AgentVM.ps1` | `New-AgentVM.sh` → `prlctl create -d win-11` |
| Build ISO from UUP dump | `New-UUPDumpISO.ps1` (DISM) | `New-WindowsISO.sh` (macOS UUP converter) |
| Unattended install | DISM apply + `autounattend.xml` | `Install-Windows.sh` + `autounattend.arm64.xml` on removable media |
| Agentless in-guest exec | PowerShell Direct | `prlctl exec` (via Parallels Tools) |
| Host↔guest file transfer | `Copy-Item -ToSession` | Parallels shared folder (`\\Mac\workspace`) |
| Clean base + restore | checkpoints | `prlctl snapshot` / `snapshot-switch` |
| Isolated ↔ internet | `Connect-VMNetworkAdapter` | `prlctl set --device-set net0 --type ...` |

Because Parallels is the Microsoft-authorized Win11-ARM VMM, this also avoids the
licensing grey area of a home-grown VMM (see
[`../docs/Windows-VMM-Feasibility.md`](../docs/Windows-VMM-Feasibility.md),
Option D).

## Requirements

- Apple Silicon Mac with **Parallels Desktop** installed (`prlctl` on `PATH`).
- **Accept any pending Parallels license agreement first.** Launch Parallels
  Desktop once interactively and accept its EULA before running the automation.
  A pending EULA is a *modal* dialog that blocks the Parallels dispatcher, which
  makes `prlctl` operations (including `prlctl exec` during provisioning) hang
  indefinitely — the dialog appears after Parallels app updates introduce a new
  EULA version.
- For building an ISO from UUP dump (`New-WindowsISO.sh`), Homebrew tools — the
  macOS equivalent of Windows' built-in DISM:
  ```sh
  brew install aria2 wimlib cabextract jq cdrtools   # or: xorriso instead of cdrtools
  # chntpw is no longer in Homebrew core; use the tap that builds on Apple Silicon:
  brew tap minacle/chntpw && brew install minacle/chntpw/chntpw
  # (MacPorts alternative: sudo port install chntpw)
  ```
  You can skip this entirely by bringing your own Windows 11 **ARM64** ISO.

## Quick start

```sh
cd macos/parallels

# One shot: build ISO -> create VM -> unattended install -> provision -> snapshot
./Bootstrap.sh --name WinArmSandbox --build-iso

# ...or bring your own ARM64 ISO:
./Bootstrap.sh --name WinArmSandbox --iso ~/ISOs/Win11_ARM64.iso

# Daily use: restore clean base, sync a project, boot with internet
./Start-Session.sh --name WinArmSandbox --project ~/code/myapp --restore --internet

# Inside the VM (auto-logged in as Admin): open \\Mac\workspace, then run `claude`

# Pull build outputs back to the host
./Copy-Artifacts.sh --name WinArmSandbox --dest ~/code/myapp/artifacts
```

## Scripts

| Script | Purpose |
|--------|---------|
| `Bootstrap.sh` | Orchestrates build-iso → create → install → provision → snapshot |
| `New-WindowsISO.sh` | Builds a Win11 ARM64 ISO from UUP dump via the macOS converter |
| `New-AgentVM.sh` | `prlctl create -d win-11` + sizing + shared folder + network |
| `Install-Windows.sh` | Builds the answer/tools ISO, boots, waits for Parallels Tools |
| `Invoke-Provision.ps1` | ARM64 toolchain provisioner (runs in-guest, winget-free) |
| `Start-Provision.sh` | Runs the provisioner via a non-interactive batch scheduled task (shared-folder upload; no login required) |
| `Save-BaseSnapshot.sh` | Captures `CleanProvisionedBase` and records its id in config |
| `Start-Session.sh` | Restore / sync project / set network / boot + show window |
| `Copy-Artifacts.sh` | Copies build outputs from the shared folder to the host |
| `autounattend.arm64.xml` | Unattended answer file (install + Parallels Tools bootstrap) |
| `lib/common.sh` | Shared config/prlctl helpers |

Per-VM config is stored at
`~/.agent-sandbox/parallels-vms/<name>/config.json` (override the root with
`AGENT_SANDBOX_PARALLELS_ROOT`). The project is synced into that bundle's
`Shared/workspace`, which the guest mounts as `\\Mac\workspace`.

## How the unattended install works

Windows Setup auto-scans removable media for `Autounattend.xml` at boot — the
macOS analog of the Hyper-V path's offline DISM injection. `Install-Windows.sh`
builds a small ISO (`hdiutil makehybrid`) containing:

- `Autounattend.xml` — [`autounattend.arm64.xml`](autounattend.arm64.xml),
  adapted from Parallels' own `Autounattend_arm64.xml`. It partitions the disk,
  installs the ARM64 image, creates an auto-logon `Admin` account, and — in the
  specialize pass — installs the **Parallels Toolgate driver** and the silent
  **Guest Tools** installer (`IGT_ARM64.exe`). It also disables UAC
  admin-approval mode so host-driven `prlctl exec` runs with a full admin token.
- `IGT_ARM64.exe` and `prl_tg/` — copied from the Parallels Desktop app bundle's
  `Tools/` directory (the same files Parallels' express install uses).

Once Parallels Tools is up, `prlctl exec` becomes the host→guest control
channel. `Start-Provision.sh` uses it only to launch the provisioner as a
non-interactive batch scheduled task (see the caveat below), which installs the
toolchain: VS Build Tools with native ARM64 compilers, `aarch64-pc-windows-msvc`
Rust, Node, Git, gh, Claude Code, and Codex.

## Notes / operational caveats

This workflow has been run **end-to-end on Parallels Desktop 26.4** with a
Windows 11 ARM64 guest: UUP-dump ISO build → unattended install → Parallels Tools
→ toolchain provision → `CleanProvisionedBase` snapshot, with `node`, `npm`,
`rustc`, `cargo`, `git`, `claude`, and the native ARM64 `cl.exe` all resolving
in-guest afterward. A few operational notes still apply:

- **Boot prompt.** If the VM stalls at "Press any key to boot from CD or DVD",
  click the window and press a key once (only the first boot). A promptless boot
  image in the ISO avoids this.
- **First-boot Windows license screen — one manual click.** The answer file sets
  `AcceptEula` + `HideEULAPage` and an auto-logon `Admin` account, which *should*
  take a fresh guest straight to the desktop. In practice some Windows 11 ARM64
  builds still stop first boot at the license-terms / OOBE screen. This does
  **not** block the toolchain install — the provisioner runs as a batch task that
  needs no login (see below), so `Start-Provision.sh` completes either way — but
  the guest won't reach an interactive desktop until you open the Parallels window
  once and click through that screen. Do this **before** `Save-BaseSnapshot.sh` so
  the clean base captures an auto-logged-in desktop; every later `--restore` then
  boots straight to the desktop (auto-logon persists via `LogonCount 999`). If you
  run `Bootstrap.sh` end-to-end, just accept the screen while the provisioner is
  installing — the snapshot is the last step.
- **Windows Update can restart the guest mid-provision.** A fresh install starts
  downloading updates immediately, and an automatic restart interrupts the
  provisioning task mid-install (the ONSTART task relaunches it after the
  reboot, but a restart in the middle of the VS Build Tools install is still
  wasted work). Two guards: the answer file disables *automatic* updates from first
  boot (specialize pass), and the provisioner re-asserts the policy and stops any
  in-flight update cycle before installing (covers guests installed with an older
  answer file). Automatic updates stay off by design — a snapshot-restored
  sandbox wants deterministic restores and no surprise restarts during agent
  sessions. Two ways to opt back in: pass `--rearm-updates` (to `Bootstrap.sh`
  or `Start-Provision.sh`) and the provisioner re-enables automatic updates as
  its **last** step, after the reboot-sensitive installs — the base snapshot
  then captures a self-patching guest; or keep the default and patch manually
  ("Check for updates" in Settings, reboot, re-run `Save-BaseSnapshot.sh`).
- **Shared-folder path.** Scripts assume the guest mount is `\\Mac\workspace`
  (override `GuestShareUNC` in `config.json` if your Parallels build differs).
- **Provisioning runs as a non-interactive (batch) scheduled task — no login
  required.** `prlctl exec` runs in a raw Session 0 where installers misbehave,
  large/long-running execs orphan on the host, and `\\Mac\workspace` is not even
  mapped. An interactive (`/IT`) task avoids that but only runs once `Admin` is
  signed in to the desktop — so on a fresh install stuck at the Windows OOBE/EULA
  screen it never runs. So `Start-Provision.sh` writes the provisioner into the
  shared folder and launches it with a **batch** scheduled task (no `/IT`):
  verified on Parallels 26.4 to run as `Admin` with a full token, with
  `\\Mac\workspace` mapped and internet, *whether or not anyone is logged in* — so
  a clean install provisions unattended even while OOBE is still on screen. The
  task is registered `ONSTART` (not `ONCE`) because a freshly installed guest can
  reboot on its own right after provisioning starts — observed: Parallels Tools
  completing its install rebooted the guest ~70 s in, which silently killed a
  `ONCE` task with nothing written. After any mid-provision reboot the task
  relaunches at boot and the installers re-run idempotently; a `DONE` marker
  guard stops re-runs after success and the task deletes itself when finished.
  The host follows progress by reading a transcript + `DONE`/`FAILED` markers the
  task writes back to the shared folder. Everything is installed by **direct download —
  never winget** (pinned and deterministic; Node uses the ARM64 **zip** since
  nodejs.org ships no ARM64 MSI). UAC admin-approval mode is disabled by the
  answer file so installs get a full admin token.
- **Building on a shared folder** can be slower than a local disk; move the
  project into `C:\workspace` inside the guest if build performance matters
  (then pass `--from` to `Copy-Artifacts.sh` accordingly).
