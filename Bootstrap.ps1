# Bootstrap.ps1
# Run this ONCE on your host as Administrator to set everything up.

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\scripts\AgentSandboxConfig.ps1"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Agent Sandbox VM -- Bootstrap Setup"
Write-Host "----------------------------------------------"
Write-Host ""

# -- Config --
$defaultVMName = "AgentDevSandbox"
$vmNameInput = Read-Host "  VM name [$defaultVMName]"
$vmName = if ([string]::IsNullOrWhiteSpace($vmNameInput)) { $defaultVMName } else { $vmNameInput.Trim() }

if ($vmName -match '[<>:"/\\|?*]') {
    throw "VM name cannot contain any of these characters: < > : `" / \ | ? *"
}

$vmStatePath = Get-AgentSandboxVMStatePath -VMName $vmName

$config = @{
    VMName        = $vmName
    VMPath        = "D:\Hyper-V\$vmName"
    SharedDrive   = "D:\Hyper-V\$vmName\Shared"
    ShareName     = Get-AgentSandboxShareName -VMName $vmName
    CacheRoot     = "D:\AgentSandboxCache"
    CredPath      = $vmStatePath
    ProjectsRoot  = "D:\workspace"
}

# -- Step 1: Prerequisites --
Write-Host "[1/6] Checking prerequisites..."

if (-not (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All | Where-Object State -eq "Enabled")) {
    Write-Host "  Hyper-V is not enabled. Enabling now (requires reboot)..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    Write-Host "  REBOOT REQUIRED. Re-run Bootstrap.ps1 after rebooting."
    exit 0
}
Write-Host "  Hyper-V: OK"

# -- Step 2: Create folder structure --
Write-Host "[2/6] Creating folder structure..."

$folders = @(
    $config.VMPath,
    $config.SharedDrive,
    "$($config.CacheRoot)\rust",
    "$($config.CacheRoot)\vs-layout",
    $config.CredPath,
    $config.ProjectsRoot
)
foreach ($f in $folders) {
    if (-not $f) { Write-Warning "Skipping null path"; continue }
    New-Item -ItemType Directory -Force -Path $f | Out-Null
    Write-Host "  Created: $f"
}

# Lock down credentials folder
$aclTarget = $config.CredPath
Protect-AgentSandboxPath -Path $aclTarget
Write-Host "  Locked down: $aclTarget"

# Write per-VM config and update the current/default config for compatibility.
$migratedConfigPath = Save-AgentSandboxLegacyConfigSnapshot -SkipVMName $config.VMName
if ($migratedConfigPath) {
    Write-Host "  Migrated previous VM config to: $migratedConfigPath"
}
$savedConfigPath = Save-AgentSandboxConfig -Config $config -SetCurrent
Write-Host "  VM config saved to: $savedConfigPath"
Write-Host "  Current config saved to: $(Get-AgentSandboxLegacyConfigPath)"

# -- Step 3: Download VS Build Tools offline layout --
Write-Host "[3/6] Downloading VS Build Tools offline layout (~3-4 GB)..."
Write-Host "      This is a one-time download and will be reused on every VM provision."

$vsBootstrapper = "$($config.CacheRoot)\vs-layout\vs_buildtools.exe"

# Validate any existing download is a real PE (first 2 bytes == "MZ").
# If it's an HTML error page from a failed download, delete and re-fetch.
if (Test-Path $vsBootstrapper) {
    $magic = [System.IO.File]::ReadAllBytes($vsBootstrapper) | Select-Object -First 2
    if ($magic.Count -lt 2 -or $magic[0] -ne 0x4D -or $magic[1] -ne 0x5A) {
        Write-Warning "  Existing vs_buildtools.exe is not a valid executable (bad PE header) -- deleting and re-downloading."
        Remove-Item $vsBootstrapper -Force
    }
}

if (-not (Test-Path $vsBootstrapper)) {
    Write-Host "  Downloading vs_buildtools.exe bootstrapper..."
    Invoke-WebRequest "https://aka.ms/vs/18/stable/vs_buildtools.exe" -OutFile $vsBootstrapper -UseBasicParsing
    # Remove Zone.Identifier so Windows won't block execution of the downloaded exe.
    Unblock-File -Path $vsBootstrapper
    # Validate the download succeeded and produced a real PE.
    $magic = [System.IO.File]::ReadAllBytes($vsBootstrapper) | Select-Object -First 2
    if ($magic.Count -lt 2 -or $magic[0] -ne 0x4D -or $magic[1] -ne 0x5A) {
        throw "Downloaded vs_buildtools.exe is not a valid executable. The URL may be wrong or the download was interrupted. Check: https://aka.ms/vs/18/stable/vs_buildtools.exe"
    }
}

$layoutPath = "$($config.CacheRoot)\vs-layout\layout"
if (-not (Test-Path "$layoutPath\Response.json")) {
    Write-Host "  Creating offline layout (this may take 10-15 minutes)..."
    Write-Host "  Please wait..."
    $proc = Start-Process $vsBootstrapper -ArgumentList @(
        "--layout", $layoutPath,
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
        "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
        "--includeRecommended",
        "--lang", "en-US",
        "--quiet"
    ) -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "  VS Build Tools layout returned exit code $($proc.ExitCode)."
        Write-Warning "  The provisioner can still download from internet instead."
    } else {
        Write-Host "  VS Build Tools layout ready."
    }
} else {
    Write-Host "  VS Build Tools layout already exists, skipping."
}

# -- Step 4: Create VM --
Write-Host "[4/6] Creating Hyper-V VM..."

if (Get-VM -Name $config.VMName -ErrorAction SilentlyContinue) {
    Write-Host "  VM '$($config.VMName)' already exists, skipping creation."
} else {
    & "$PSScriptRoot\scripts\New-AgentVM.ps1" -VMName $config.VMName
    Write-Host "  VM created: $($config.VMName)"
}
Ensure-AgentSandboxShare -Config ([pscustomobject]$config)

# -- Step 5: Install Windows directly to VHDX --
Write-Host ""
Write-Host "[5/6] Install Windows to VM"
Write-Host "      This applies Windows directly to the VHDX -- no DVD boot needed."
Write-Host ""
Write-Host "      You need a Windows ISO. Either supply your own (e.g. Windows 11 via"
Write-Host "      Media Creation Tool: https://www.microsoft.com/software-download/windows11)"
Write-Host "      or build one from UUP dump (uupdump.net) -- downloads straight from"
Write-Host "      Microsoft's update servers. Default build: Windows Server 2025, amd64."
Write-Host ""
$buildChoice = Read-Host "  Build ISO from UUP dump? (y/N)"

$isoPath = ""
$uupArgs = $null
if ($buildChoice.Trim() -match '^[Yy]') {
    $uupVersion = Read-Host "  Windows version to search for [Windows Server 2025]"
    $uupArch = Read-Host "  Architecture: amd64, arm64 or x86 [amd64]"
    $uupArgs = @{}
    if (-not [string]::IsNullOrWhiteSpace($uupVersion)) { $uupArgs.Version = $uupVersion.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($uupArch)) { $uupArgs.Architecture = $uupArch.Trim() }
} else {
    $isoPath = Read-Host "  Enter full path to your Windows ISO"
}

Write-Host ""
Write-Host "      Optional: provide an autounattend.xml to skip OOBE prompts."
Write-Host "      Generate one at: https://schneegans.de/windows/unattend-generator/"
Write-Host ""
$unattendPath = Read-Host "  Enter path to autounattend.xml (or press Enter to skip)"

if ($null -ne $uupArgs) {
    try {
        $isoPath = & "$PSScriptRoot\scripts\New-UUPDumpISO.ps1" @uupArgs | Select-Object -Last 1
    } catch {
        Write-Warning "  UUP dump ISO build failed: $_"
        Write-Host "  Retry manually with: .\scripts\New-UUPDumpISO.ps1"
    }
}

if ([string]::IsNullOrWhiteSpace($isoPath) -or -not (Test-Path $isoPath)) {
    Write-Host "  ERROR: ISO not found at '$isoPath'."
    Write-Host "  Run manually once you have the ISO:"
    Write-Host "    .\scripts\Install-Windows.ps1 -VMName '$($config.VMName)' -ISOPath <path>"
} else {
    $installArgs = @{ ISOPath = $isoPath }
    if ($unattendPath -and (Test-Path $unattendPath)) {
        $installArgs.UnattendPath = $unattendPath
    }
    $installArgs.VMName = $config.VMName
    & "$PSScriptRoot\scripts\Install-Windows.ps1" @installArgs
}

# -- Step 6: Next steps --
Write-Host ""
Write-Host "[6/6] Bootstrap complete. Next steps:"
Write-Host ""
Write-Host "  1. Complete Windows setup in the VM console (OOBE)."
Write-Host "     (Skipped automatically if you provided autounattend.xml)"
Write-Host ""
Write-Host "  2. Provision the VM (switches network, copies files, installs tools):"
Write-Host "     .\scripts\Start-Provision.ps1 -VMName '$($config.VMName)'"
Write-Host ""
Write-Host "  3. After provisioning, shut down the VM and run on the host:"
Write-Host "     .\scripts\Save-BaseSnapshot.ps1 -VMName '$($config.VMName)'"
Write-Host ""
Write-Host "  4. Start your first dev session:"
Write-Host "     .\Start-Session.ps1 -VMName '$($config.VMName)' -ProjectPath C:\Projects\myapp"
Write-Host ""
