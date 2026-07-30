# scripts/Start-Provision.ps1
# Run on HOST. Prepares the VM for provisioning and copies files in.
# Handles:
#   1. Switching VM to Default Switch (internet access)
#   2. Copying VS Build Tools cache + provision script into the VM
#   3. Opening vmconnect so you can run the provisioner inside the VM

#Requires -RunAsAdministrator

param(
    [string]$VMName = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName -RequireVM

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Preparing VM '$($cfg.VMName)' for provisioning"
Write-Host "----------------------------------------------"
Write-Host ""

# -- Ensure VM is running --
$vmState = (Get-VM -Name $cfg.VMName).State
if ($vmState -eq "Off") {
    Write-Host "Starting VM..."
    Start-VM -Name $cfg.VMName
    Write-Host "  Waiting for VM to boot (30 seconds)..."
    Start-Sleep -Seconds 30
} elseif ($vmState -ne "Running") {
    Write-Host "VM is in state: $vmState -- waiting..."
    Start-Sleep -Seconds 15
}

# -- Switch to Default Switch for internet --
Write-Host "[1/3] Switching VM to Default Switch (internet access)..."

$adapter = Get-VMNetworkAdapter -VMName $cfg.VMName
$currentSwitch = $adapter.SwitchName

if ($currentSwitch -eq "Default Switch") {
    Write-Host "  Already on Default Switch."
} else {
    Connect-VMNetworkAdapter -VMName $cfg.VMName -SwitchName "Default Switch"
    Write-Host "  Switched from '$currentSwitch' to 'Default Switch'."
    Write-Host "  Waiting for network to come up (15 seconds)..."
    Start-Sleep -Seconds 15
}

# -- Get VM credentials --
$cred = Import-AgentSandboxCredential -Config $cfg -PromptIfMissing -PromptMessage "VM credentials for $($cfg.VMName)"

# -- Copy files into VM --
Write-Host "[2/3] Copying files into VM via PowerShell Direct..."

$session = $null
try {
    $session = New-PSSession -VMName $cfg.VMName -Credential $cred

    # Copy provision script
    Copy-Item -ToSession $session `
              -Path "$PSScriptRoot\Invoke-Provision.ps1" `
              -Destination "C:\Invoke-Provision.ps1"
    Write-Host "  Copied: Invoke-Provision.ps1"

    # Invoke-Provision.ps1 runs this for the gh-stack (GitHub Stacked PRs) step,
    # and it stays in the VM so it can be re-run after `gh auth login`.
    Copy-Item -ToSession $session `
              -Path "$PSScriptRoot\Install-GhStack.ps1" `
              -Destination "C:\Install-GhStack.ps1"
    Write-Host "  Copied: Install-GhStack.ps1"

    # Copy optional kernel debugging setup scripts. Setup-KernelDebugger.ps1 is
    # useful when this VM is the debugger for another VM.
    Copy-Item -ToSession $session `
              -Path "$PSScriptRoot\Setup-KernelDebugger.ps1" `
              -Destination "C:\Setup-KernelDebugger.ps1"
    Write-Host "  Copied: Setup-KernelDebugger.ps1"

    Copy-Item -ToSession $session `
              -Path "$PSScriptRoot\Setup-KernelDebuggee.ps1" `
              -Destination "C:\Setup-KernelDebuggee.ps1"
    Write-Host "  Copied: Setup-KernelDebuggee.ps1"

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $vmStartAgentPath = Join-Path $repoRoot "vm\Start-Agent.ps1"
    if (Test-Path $vmStartAgentPath) {
        Copy-Item -ToSession $session `
                  -Path $vmStartAgentPath `
                  -Destination "C:\Start-Agent.ps1"
        Write-Host "  Copied: Start-Agent.ps1"
    }

    Invoke-Command -Session $session -ArgumentList $cfg.ShareName -ScriptBlock {
        param([string]$ShareName)
        @{ ShareName = $ShareName } | ConvertTo-Json | Set-Content -Path "C:\AgentSandboxVM.json" -Encoding UTF8
    }
    Write-Host "  Wrote: AgentSandboxVM.json"

    # Copy VS Build Tools offline layout if it exists on host
    $vsLayoutPath = "$($cfg.CacheRoot)\vs-layout\layout"
    if (Test-Path "$vsLayoutPath\vs_buildtools.exe") {
        Write-Host "  Copying VS Build Tools offline layout into VM..."
        Write-Host "  (This is ~3-4 GB and may take a few minutes)"

        # Create target dir in VM
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Force -Path "C:\vs-cache\layout" | Out-Null
        }

        # Copy the layout folder
        Copy-Item -ToSession $session `
                  -Path "$vsLayoutPath\*" `
                  -Destination "C:\vs-cache\layout\" `
                  -Recurse -Force
        Write-Host "  VS Build Tools layout copied."
    } else {
        Write-Host "  VS Build Tools offline layout not found on host."
        Write-Host "  The provisioner will download from the internet instead."
    }
} finally {
    if ($session) {
        Remove-PSSession $session
    }
}

# -- Open console --
Write-Host ""
Write-Host "[3/3] Ready to provision."
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  In the VM console, run as Administrator:"
Write-Host ""
Write-Host "    powershell -ExecutionPolicy RemoteSigned -File C:\Invoke-Provision.ps1"
Write-Host ""
Write-Host "  After it completes, shut down the VM and run:"
Write-Host "    .\scripts\Save-BaseSnapshot.ps1 -VMName '$($cfg.VMName)'"
Write-Host "----------------------------------------------"
Write-Host ""

& "$PSScriptRoot\Open-VMConsole.ps1" -VMName $cfg.VMName
