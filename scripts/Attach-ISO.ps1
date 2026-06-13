# scripts/Attach-ISO.ps1
# Attaches the Windows ISO to the VM and configures firmware.
# DVD lives on SCSI controller 1 (separate from HDD on controller 0).
# Secure Boot ON with MicrosoftWindows template (required for Win11).
#
# Boot order is set to DVD ONLY (HDD removed from boot order).
# This avoids the "Press any key to boot from CD/DVD" timeout problem --
# with no fallback device the VM boots straight from DVD.
# After Windows is installed, the installer writes its own boot entry to the HDD.

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [string]$ISOPath,

    [string]$VMName = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName -RequireVM

if (-not (Test-Path $ISOPath)) {
    Write-Error "ISO not found at: $ISOPath"
    exit 1
}

if ((Get-VM -Name $cfg.VMName -ErrorAction SilentlyContinue).State -ne "Off") {
    Stop-VM -Name $cfg.VMName -Force
    Start-Sleep -Seconds 2
}

# Remove any existing DVD drives to avoid stale state
Get-VMDvdDrive -VMName $cfg.VMName -ErrorAction SilentlyContinue | Remove-VMDvdDrive

# Ensure SCSI controller 1 exists (for DVD -- separate from HDD on controller 0)
$controllers = Get-VMScsiController -VMName $cfg.VMName
if ($controllers.Count -lt 2) {
    Add-VMScsiController -VMName $cfg.VMName
    Write-Host "  Added SCSI controller 1 for DVD."
}

# Attach ISO to controller 1
Add-VMDvdDrive -VMName $cfg.VMName `
               -ControllerNumber 1 `
               -ControllerLocation 0 `
               -Path $ISOPath
Write-Host "  ISO attached on controller 1: $ISOPath"

# Firmware: Secure Boot on, DVD ONLY in boot order (no HDD fallback)
# This forces direct DVD boot -- no "Press any key" timeout
$dvd = Get-VMDvdDrive -VMName $cfg.VMName

Set-VMFirmware -VMName $cfg.VMName `
               -EnableSecureBoot On `
               -SecureBootTemplate MicrosoftWindows `
               -BootOrder $dvd

Write-Host "  Firmware: Secure Boot on (MicrosoftWindows), DVD only boot."
Write-Host ""
Write-Host "  Boot order:"
Get-VMFirmware -VMName $cfg.VMName | Select-Object -ExpandProperty BootOrder | Format-Table BootType, Device

Write-Host "Starting VM..."
Start-VM -Name $cfg.VMName
& "$PSScriptRoot\Open-VMConsole.ps1" -VMName $cfg.VMName
