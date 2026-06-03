# scripts/Start-Provision.ps1
# Run on HOST. Prepares the VM for provisioning and copies files in.
# Handles:
#   1. Switching VM to Default Switch (internet access)
#   2. Copying VS Build Tools cache + provision script into the VM
#   3. Opening vmconnect so you can run the provisioner inside the VM

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$configPath = "$env:USERPROFILE\.agent-sandbox\config.json"
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Preparing VM for provisioning"
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
$credPath = "$env:USERPROFILE\.agent-sandbox\vm-cred.xml"
if (Test-Path $credPath) {
    $cred = Import-Clixml $credPath
} else {
    Write-Host ""
    Write-Host "  Enter the VM Windows username and password."
    $cred = Get-Credential -Message "VM credentials"
    # Save for later
    $cred | Export-Clixml $credPath
    & icacls $credPath /inheritance:r /grant:r "${env:USERNAME}:(F)" 2>&1 | Out-Null
    Write-Host "  Credentials saved for future use."
}

# -- Copy files into VM --
Write-Host "[2/3] Copying files into VM via PowerShell Direct..."

$session = New-PSSession -VMName $cfg.VMName -Credential $cred

# Copy provision script
Copy-Item -ToSession $session `
          -Path "$PSScriptRoot\Invoke-Provision.ps1" `
          -Destination "C:\Invoke-Provision.ps1"
Write-Host "  Copied: Invoke-Provision.ps1"

# Copy optional VM-side kernel debuggee setup script
Copy-Item -ToSession $session `
          -Path "$PSScriptRoot\Setup-KernelDebuggee.ps1" `
          -Destination "C:\Setup-KernelDebuggee.ps1"
Write-Host "  Copied: Setup-KernelDebuggee.ps1"

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

Remove-PSSession $session

# -- Open console --
Write-Host ""
Write-Host "[3/3] Ready to provision."
Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  In the VM console, run as Administrator:"
Write-Host ""
Write-Host "    powershell -ExecutionPolicy Bypass -File C:\Invoke-Provision.ps1"
Write-Host ""
Write-Host "  After it completes, shut down the VM and run:"
Write-Host "    .\scripts\Save-BaseSnapshot.ps1"
Write-Host "----------------------------------------------"
Write-Host ""

& "$PSScriptRoot\Open-VMConsole.ps1" -VMName $cfg.VMName
