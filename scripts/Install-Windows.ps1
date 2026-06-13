# scripts/Install-Windows.ps1
# Applies Windows 11 directly to the VM's VHDX -- no DVD boot required.
# Uses DISM to apply the install image and bcdboot to set up UEFI boot.
# Optionally injects an autounattend.xml to skip OOBE prompts.

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [string]$ISOPath,

    [string]$VMName = "",

    # Path to autounattend.xml (generate at https://schneegans.de/windows/unattend-generator/)
    [string]$UnattendPath = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName -RequireVM
$VHDPath = "$($cfg.VMPath)\$($cfg.VMName).vhdx"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Installing Windows directly to VHDX"
Write-Host "  (bypasses DVD boot entirely)"
Write-Host "----------------------------------------------"
Write-Host ""

# -- Validate inputs --
if (-not (Test-Path $ISOPath)) {
    Write-Error "ISO not found: $ISOPath"
    exit 1
}
if ($UnattendPath -and -not (Test-Path $UnattendPath)) {
    Write-Error "Unattend file not found: $UnattendPath"
    exit 1
}

# -- Ensure VM is off --
if ((Get-VM -Name $cfg.VMName -ErrorAction SilentlyContinue).State -ne "Off") {
    Stop-VM -Name $cfg.VMName -Force
    Start-Sleep -Seconds 2
}

# -- Mount the ISO --
Write-Host "[1/6] Mounting ISO..."
$mountResult = Mount-DiskImage -ImagePath $ISOPath -PassThru
$isoDrive = ($mountResult | Get-Volume).DriveLetter
Write-Host "  Mounted at ${isoDrive}:"

# -- Find the install image --
$wimPath = "${isoDrive}:\sources\install.wim"
$esdPath = "${isoDrive}:\sources\install.esd"

if (Test-Path $wimPath) {
    $imagePath = $wimPath
} elseif (Test-Path $esdPath) {
    $imagePath = $esdPath
} else {
    Dismount-DiskImage -ImagePath $ISOPath
    Write-Error "No install.wim or install.esd found in ISO"
    exit 1
}

# List available editions
Write-Host "[2/6] Available Windows editions:"
$editions = Get-WindowsImage -ImagePath $imagePath
$editions | Format-Table ImageIndex, ImageName
Write-Host ""

# Pick Pro if available, otherwise last entry
$proEdition = $editions | Where-Object {
    $_.ImageName -like "*Pro" -and
    $_.ImageName -notlike "*Education*" -and
    $_.ImageName -notlike "*Workstation*"
} | Select-Object -First 1

if ($proEdition) {
    $imageIndex = $proEdition.ImageIndex
    Write-Host "  Auto-selected: $($proEdition.ImageName) (index $imageIndex)"
} else {
    $imageIndex = $editions[-1].ImageIndex
    Write-Host "  Auto-selected: $($editions[-1].ImageName) (index $imageIndex)"
}

# -- Prepare the VHDX --
Write-Host "[3/6] Partitioning VHDX..."

# Detach VHDX from VM temporarily
$vmDisk = Get-VMHardDiskDrive -VMName $cfg.VMName
if ($vmDisk) {
    Remove-VMHardDiskDrive -VMName $cfg.VMName `
        -ControllerType SCSI `
        -ControllerNumber $vmDisk.ControllerNumber `
        -ControllerLocation $vmDisk.ControllerLocation
}

# Mount and partition the VHDX
Mount-VHD -Path $VHDPath
$diskNumber = (Get-VHD -Path $VHDPath).DiskNumber

# Create GPT layout
Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction SilentlyContinue

# EFI partition (260 MB, FAT32)
$efiPart = New-Partition -DiskNumber $diskNumber -Size 260MB `
    -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter
Start-Sleep -Seconds 2
$efiLetter = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $efiPart.PartitionNumber).DriveLetter
Format-Volume -DriveLetter $efiLetter -FileSystem FAT32 -NewFileSystemLabel "EFI" -Confirm:$false | Out-Null

# MSR partition (16 MB, required for GPT)
New-Partition -DiskNumber $diskNumber -Size 16MB `
    -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

# Windows partition (rest of disk, NTFS)
$winPart = New-Partition -DiskNumber $diskNumber -UseMaximumSize `
    -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -AssignDriveLetter
Start-Sleep -Seconds 2
$winLetter = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $winPart.PartitionNumber).DriveLetter
Format-Volume -DriveLetter $winLetter -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null

Write-Host "  EFI partition: ${efiLetter}:"
Write-Host "  Windows partition: ${winLetter}:"

if (-not $efiLetter -or -not $winLetter) {
    Write-Error "Failed to assign drive letters. Dismounting and aborting."
    Dismount-VHD -Path $VHDPath
    Dismount-DiskImage -ImagePath $ISOPath
    exit 1
}

# -- Apply Windows image --
Write-Host "[4/6] Applying Windows image (this takes 5-10 minutes)..."
& dism.exe /Apply-Image /ImageFile:"$imagePath" /Index:$imageIndex /ApplyDir:"${winLetter}:\"
if ($LASTEXITCODE -ne 0) {
    Write-Error "DISM failed with exit code $LASTEXITCODE"
    Dismount-VHD -Path $VHDPath
    Dismount-DiskImage -ImagePath $ISOPath
    exit 1
}
Write-Host "  Windows image applied."

# -- Set up UEFI boot --
Write-Host "[5/6] Configuring UEFI boot..."
& bcdboot "${winLetter}:\Windows" /s "${efiLetter}:" /f UEFI
if ($LASTEXITCODE -ne 0) {
    Write-Error "bcdboot failed with exit code $LASTEXITCODE"
    Dismount-VHD -Path $VHDPath
    Dismount-DiskImage -ImagePath $ISOPath
    exit 1
}
Write-Host "  Boot configuration written."

# -- Inject autounattend.xml if provided --
if ($UnattendPath) {
    Write-Host "  Injecting autounattend.xml..."
    New-Item -ItemType Directory -Force -Path "${winLetter}:\Windows\Panther" | Out-Null
    Copy-Item $UnattendPath "${winLetter}:\Windows\Panther\unattend.xml" -Force
    Copy-Item $UnattendPath "${winLetter}:\autounattend.xml" -Force
    Write-Host "  Unattend file injected."
}

# -- Clean up and reattach --
Write-Host "[6/6] Finalizing..."

# Remove drive letters before dismounting
Remove-PartitionAccessPath -DiskNumber $diskNumber `
    -PartitionNumber $efiPart.PartitionNumber `
    -AccessPath "${efiLetter}:\" -ErrorAction SilentlyContinue

Remove-PartitionAccessPath -DiskNumber $diskNumber `
    -PartitionNumber $winPart.PartitionNumber `
    -AccessPath "${winLetter}:\" -ErrorAction SilentlyContinue

Dismount-VHD -Path $VHDPath
Dismount-DiskImage -ImagePath $ISOPath

# Reattach VHDX to VM
Add-VMHardDiskDrive -VMName $cfg.VMName `
                    -ControllerType SCSI `
                    -ControllerNumber 0 `
                    -ControllerLocation 0 `
                    -Path $VHDPath

# Boot from HDD only now (no DVD needed)
$disk = Get-VMHardDiskDrive -VMName $cfg.VMName
Set-VMFirmware -VMName $cfg.VMName `
               -EnableSecureBoot On `
               -SecureBootTemplate MicrosoftWindows `
               -BootOrder $disk

# Remove DVD drive (no longer needed)
Get-VMDvdDrive -VMName $cfg.VMName -ErrorAction SilentlyContinue | Remove-VMDvdDrive

Write-Host ""
Write-Host "  Windows installed directly to VHDX -- no DVD boot needed."
Write-Host "  Boot order set to HDD only."
Write-Host ""
Write-Host "Starting VM..."
Start-VM -Name $cfg.VMName
& "$PSScriptRoot\Open-VMConsole.ps1" -VMName $cfg.VMName
