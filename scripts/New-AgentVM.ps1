# scripts/New-AgentVM.ps1
# Creates the Hyper-V VM. Called by Bootstrap.ps1.
# Gen 2 VM with Secure Boot + TPM (required for Windows 11).
# HDD and DVD on separate SCSI controllers to avoid boot issues.

#Requires -RunAsAdministrator

param(
    [string]$VMName = ""
)

. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName

$VHDPath    = "$($cfg.VMPath)\$($cfg.VMName).vhdx"
$VHDSizeGB  = 80
$MemoryGB   = 4
$CPUCount   = 4
$SwitchName = "Agent-Internal"

# Internal network switch (VM can reach host, not your LAN)
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal
    Write-Host "  Created internal network switch: $SwitchName"
}

# Virtual disk
New-Item -ItemType Directory -Force -Path $cfg.VMPath | Out-Null
New-VHD -Path $VHDPath -SizeBytes ($VHDSizeGB * 1GB) -Dynamic | Out-Null

# Create VM without attaching VHD -- we attach manually to control controller layout
New-VM -Name $cfg.VMName `
       -Path $cfg.VMPath `
       -MemoryStartupBytes ($MemoryGB * 1GB) `
       -Generation 2 `
       -SwitchName $SwitchName

Set-VM -Name $cfg.VMName `
       -ProcessorCount $CPUCount `
       -AutomaticCheckpointsEnabled $false `
       -CheckpointType Production

Set-VMMemory -VMName $cfg.VMName `
             -DynamicMemoryEnabled $true `
             -MinimumBytes 2GB `
             -MaximumBytes ($MemoryGB * 1GB)

# TPM -- required for Windows 11
Set-VMKeyProtector -VMName $cfg.VMName -NewLocalKeyProtector
Enable-VMTPM -VMName $cfg.VMName
Write-Host "  TPM 2.0 enabled."

# HDD on SCSI controller 0
Add-VMHardDiskDrive -VMName $cfg.VMName `
                    -ControllerType SCSI `
                    -ControllerNumber 0 `
                    -ControllerLocation 0 `
                    -Path $VHDPath

# DVD on its own SCSI controller 1 -- separate from HDD to avoid Gen 2 boot issues
Add-VMScsiController -VMName $cfg.VMName
Add-VMDvdDrive -VMName $cfg.VMName `
               -ControllerNumber 1 `
               -ControllerLocation 0

Write-Host "  HDD controller: $((Get-VMHardDiskDrive -VMName $cfg.VMName).ControllerNumber)"
Write-Host "  DVD controller: $((Get-VMDvdDrive -VMName $cfg.VMName).ControllerNumber)"

# Enable guest services (needed for PSRemoting over VM bus)
Enable-VMIntegrationService -VMName $cfg.VMName -Name "Guest Service Interface"

# SMB share (handy for file drops before PSRemoting is up)
$shareName = $cfg.ShareName
$existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
if (-not $existingShare) {
    New-SmbShare -Name $shareName `
                 -Path $cfg.SharedDrive `
                 -FullAccess "$env:USERDOMAIN\$env:USERNAME" | Out-Null
    Write-Host "  SMB share created: \\localhost\$shareName -> $($cfg.SharedDrive)"
} elseif ($existingShare.Path -ne $cfg.SharedDrive) {
    throw "SMB share '$shareName' already points to '$($existingShare.Path)', not '$($cfg.SharedDrive)'."
}

Write-Host "  VM '$($cfg.VMName)' created successfully."
Write-Host "  Secure Boot: On (MicrosoftWindows template)"
Write-Host "  TPM 2.0: Enabled"
Write-Host ""
Write-Host "  Next: attach your Windows ISO:"
Write-Host "    .\scripts\Attach-ISO.ps1 -VMName '$($cfg.VMName)' -ISOPath <path to your ISO>"
