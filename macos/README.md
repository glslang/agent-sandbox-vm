# Agent Sandbox VM for macOS

This directory contains an experimental macOS host implementation backed by Apple's `Virtualization.framework`.

It is not a line-for-line Hyper-V replacement. macOS guests installed from Apple IPSW restore images are the supported path. Windows guests are experimental because Apple does not provide a Windows IPSW installer, Windows guest tools, PowerShell Direct, or a public vTPM API through `Virtualization.framework`.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer; macOS 15+ recommended for the generic EFI USB-controller path
- Xcode command line tools or Xcode
- A local macOS IPSW restore image, or use `--latest` to download the latest supported restore image
- For Windows experiments: ARM64 Windows media or a prepared ARM64 Windows raw boot disk image

The `vmctl` binary must be code-signed with the entitlement in `vmctl.entitlements`. The included wrapper does that automatically for the release build. Bridged networking additionally requires Apple's `com.apple.vm.networking` entitlement under an appropriate signing identity; the default ad-hoc signature only targets NAT/isolated operation.

## Build

```bash
./macos/scripts/Build-vmctl.sh
```

The signed binary is written to:

```bash
macos/.build/release/vmctl
```

Most scripts call `macos/scripts/vmctl.sh`, which builds and signs the binary if needed.

## macOS Guest Workflow

Create a VM from a local IPSW:

```bash
./macos/scripts/New-AgentVM.sh --guest macos --name AgentMacSandbox --ipsw /path/to/macOS.ipsw
```

Or fetch the latest supported restore image:

```bash
./macos/scripts/New-AgentVM.sh --guest macos --name AgentMacSandbox --latest
```

Install macOS into the raw disk:

```bash
./macos/scripts/Install-Guest.sh --name AgentMacSandbox
```

Save the clean base snapshot after first boot/provisioning and shutdown:

```bash
./macos/scripts/Save-BaseSnapshot.sh --name AgentMacSandbox
```

Start a session with an isolated guest:

```bash
./macos/scripts/Start-Session.sh --name AgentMacSandbox --project /path/to/project
```

Start with NAT internet access and restore first:

```bash
./macos/scripts/Start-Session.sh --name AgentMacSandbox --project /path/to/project --restore --internet
```

Projects are copied to the VM bundle's host-visible shared directory:

```text
~/.agent-sandbox/macos-vms/<name>.agentvm/Shared/workspace
```

For macOS guests, `vmctl run` attaches that directory through VirtioFS using Apple's macOS guest automount tag. Inside the guest it appears at:

```text
/Volumes/My Shared Files/workspace
```

## Artifact Extraction

If the build writes into the shared `workspace` directory, artifacts are already on the host. This wrapper copies a shared path to a destination:

```bash
./macos/scripts/Copy-Artifacts.sh --name AgentMacSandbox --from workspace/target/release --dest ./artifacts
```

## Windows Status

You can create a generic EFI VM bundle for Windows experiments:

```bash
./macos/scripts/New-AgentVM.sh --guest windows --name AgentWinArm --iso /path/to/windows-arm64.iso
```

Current limitations:

- `install --name AgentWinArm` intentionally fails with an explanation.
- A Windows ISO is recorded in VM metadata but is not automatically booted or installed.
- Raw `.img` or `.raw` media can be attached as USB mass storage during `run`, but Windows setup and drivers are outside this implementation.
- There is no PowerShell Direct equivalent; use WinRM, SSH, or a guest-supported shared-folder driver after the guest is provisioned.
- No KDNET/Secure Boot/vTPM parity is implemented.

Use Parallels, VMware Fusion, or UTM/QEMU if Windows parity is the primary requirement.

## CLI Reference

```bash
./macos/scripts/vmctl.sh create --guest macos --ipsw <file>|--latest --name <name> [--cpus 4] [--memory 8] [--disk-size 80]
./macos/scripts/vmctl.sh create --guest windows --iso <arm64-media> --name <name> [--cpus 4] [--memory 4] [--disk-size 80]
./macos/scripts/vmctl.sh install --name <name>
./macos/scripts/vmctl.sh run --name <name> [--internet isolated|nat|bridged] [--bridge-interface en0] [--share <path>]
./macos/scripts/vmctl.sh stop --name <name>
./macos/scripts/vmctl.sh snapshot save --name <name> --label CleanProvisionedBase
./macos/scripts/vmctl.sh snapshot restore --name <name> --label CleanProvisionedBase
./macos/scripts/vmctl.sh copy-out --name <name> --from <shared-relative-path> --to <host-path>
./macos/scripts/vmctl.sh list
./macos/scripts/vmctl.sh delete --name <name>
./macos/scripts/vmctl.sh path --name <name> [--shared]
./macos/scripts/vmctl.sh info --name <name>
```

Set `AGENT_SANDBOX_VM_ROOT` to override the default VM bundle root.
