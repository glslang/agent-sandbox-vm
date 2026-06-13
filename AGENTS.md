# Repository Guidelines

## Project Structure & Module Organization

This repository scripts isolated agent sandbox VMs. The Windows Hyper-V workflow is the primary path: root scripts such as `Bootstrap.ps1` and `Start-Session.ps1` orchestrate setup and daily use, while `scripts/` contains reusable host and guest helpers. VM-side startup logic lives in `vm/`. The experimental Apple Silicon implementation is under `macos/`, with the Swift CLI in `macos/Sources/vmctl/main.swift`, shell wrappers in `macos/scripts/`, and macOS-specific docs in `macos/README.md`.

## Build, Test, and Development Commands

- `.\Bootstrap.ps1`: create and configure a Windows sandbox VM. Run from an elevated Windows PowerShell session.
- `.\scripts\Start-Provision.ps1 -VMName AgentDevSandbox`: copy provisioning assets into a VM before running `C:\Invoke-Provision.ps1` inside it.
- `.\Start-Session.ps1 -VMName AgentDevSandbox -ProjectPath C:\Projects\myapp -Restore -Internet`: start a clean development session with internet access.
- `./macos/scripts/Build-vmctl.sh`: build and ad-hoc sign the `vmctl` release binary with the required entitlement.
- `./macos/scripts/vmctl.sh list`: build on demand, then list macOS VM bundles.

## Coding Style & Naming Conventions

PowerShell scripts use PascalCase file and function names, approved verbs, explicit parameters, and `$ErrorActionPreference = "Stop"` for fail-fast behavior. Keep host-side scripts in `scripts/` unless they are top-level entry points. Swift code uses four-space indentation, Foundation-style types, explicit error cases via `VMToolError`, and small command handlers dispatched from `VMCTL.run`.

## Testing Guidelines

There is no committed automated test suite. Validate changes with the narrowest real build or smoke test available. For macOS changes, run `./macos/scripts/Build-vmctl.sh` and exercise the affected wrapper through `./macos/scripts/vmctl.sh`. For Hyper-V changes, test on a disposable VM and document the command used, VM state, and host OS in the PR.

## Commit & Pull Request Guidelines

Git history uses short, imperative, lowercase subjects such as `support selecting created VMs` and `address lint review feedback`. Keep subjects focused on one change. Pull requests should include a concise summary, affected host platform, validation steps, and any VM lifecycle impact. Link related issues and include screenshots only when console or UI behavior changes.

## Security & Configuration Tips

Do not commit VM credentials, generated VM bundles, downloaded ISOs, IPSWs, or build artifacts. Treat `~/.agent-sandbox/` and `macos/.build/` as local state. Prefer isolated networking by default, and use `-Internet` or NAT only when a workflow requires downloads or authentication.
