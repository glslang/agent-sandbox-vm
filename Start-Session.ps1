# Start-Session.ps1
# Your daily driver. Starts an agent dev session in the sandbox VM.

#Requires -RunAsAdministrator

param(
    # Path to your project on the host
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [string]$VMName = "",

    # Where to write artifacts on the host after the session
    [string]$ArtifactDest = "",

    # Path inside the VM where cargo puts release binaries
    [string]$VMBuildPath = "C:\workspace\target\release",

    # Restore VM to clean snapshot before starting
    [switch]$Restore,

    # Automatically extract artifacts when the VM shuts down
    [switch]$ExtractOnExit,

    # Give the VM internet access (Default Switch) for cargo fetch, npm install, etc.
    # Without this flag the VM uses the internal-only switch (no internet)
    [switch]$Internet,

    # Additional file patterns to copy out (e.g. "*.json", "*.toml")
    [string[]]$ExtraArtifactPatterns = @()
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\scripts\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName -RequireVM

# Default artifact destination: <project>\artifacts
if (-not $ArtifactDest) {
    $ArtifactDest = Join-Path $ProjectPath "artifacts"
}

# -- Restore snapshot --
if ($Restore) {
    Write-Host "Restoring VM '$($cfg.VMName)' to clean snapshot..."
    if ((Get-VM -Name $cfg.VMName -ErrorAction SilentlyContinue).State -ne "Off") {
        Stop-VM -Name $cfg.VMName -Force
    }
    Start-Sleep -Seconds 2
    Restore-VMCheckpoint -VMName $cfg.VMName -Name "CleanProvisionedBase" -Confirm:$false
    Write-Host "  Restored to: CleanProvisionedBase"
}

# -- Network switch --
if ($Internet) {
    Write-Host "Switching VM '$($cfg.VMName)' to Default Switch (internet access)..."
    Connect-VMNetworkAdapter -VMName $cfg.VMName -SwitchName "Default Switch"
} else {
    # Ensure internal switch (no internet -- full isolation)
    $adapter = Get-VMNetworkAdapter -VMName $cfg.VMName
    if ($adapter.SwitchName -ne "Agent-Internal") {
        Connect-VMNetworkAdapter -VMName $cfg.VMName -SwitchName "Agent-Internal"
    }
}

# -- Sync project into shared folder --
Write-Host "Syncing project to shared folder..."
$sharedProject = Join-Path $cfg.SharedDrive "project"
New-Item -ItemType Directory -Force -Path $sharedProject | Out-Null

$robocopyFlags = @("/MIR", "/NFL", "/NDL", "/NJH", "/XD", "artifacts", ".git", "target")
robocopy $ProjectPath $sharedProject @robocopyFlags | Out-Null
Write-Host "  Synced: $ProjectPath -> $sharedProject"

# -- Start VM --
$vmState = (Get-VM -Name $cfg.VMName).State
if ($vmState -eq "Off") {
    Write-Host "Starting VM..."
    Start-VM -Name $cfg.VMName
    Start-Sleep -Seconds 3
} else {
    Write-Host "VM is already running (state: $vmState)."
}

# -- Copy project into VM via PowerShell Direct --
Write-Host "Copying project into VM..."
$cred = Import-AgentSandboxCredential -Config $cfg -PromptIfMissing -PromptMessage "VM credentials for $($cfg.VMName)"

# Wait for VM to be ready for PowerShell Direct
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        $session = New-PSSession -VMName $cfg.VMName -Credential $cred -ErrorAction Stop
        $ready = $true
        break
    } catch {
        Write-Host "  Waiting for VM to be ready... ($($i * 5)s)"
        Start-Sleep -Seconds 5
    }
}

if ($ready) {
    # Ensure workspace exists and copy project
    Invoke-Command -Session $session -ScriptBlock {
        New-Item -ItemType Directory -Force -Path "C:\workspace" | Out-Null
    }
    Copy-Item -ToSession $session `
              -Path "$ProjectPath\*" `
              -Destination "C:\workspace\" `
              -Recurse -Force `
              -Exclude @("artifacts", ".git", "target")
    Remove-PSSession $session
    Write-Host "  Project copied to C:\workspace inside VM."
} else {
    Write-Host "  WARNING: Could not connect to VM via PowerShell Direct."
    Write-Host "  Copy your project manually or use the SMB share."
}

# -- Open VM console --
Write-Host "Opening VM console..."
& "$PSScriptRoot\scripts\Open-VMConsole.ps1" -VMName $cfg.VMName

Write-Host ""
Write-Host "Session started. Inside the VM:"
Write-Host "  cd C:\workspace"
Write-Host "  claude"

# -- Wait and extract artifacts --
if ($ExtractOnExit) {
    Write-Host ""
    Write-Host "Waiting for VM to shut down to extract artifacts..."
    Write-Host "(Shut down the VM from inside when you're done)"

    while ((Get-VM -Name $cfg.VMName).State -ne "Off") {
        Start-Sleep -Seconds 5
    }

    Write-Host "VM shut down. Extracting artifacts..."
    & "$PSScriptRoot\scripts\Copy-Artifacts.ps1" `
        -VMName $cfg.VMName `
        -DestPath $ArtifactDest `
        -VMBuildPath $VMBuildPath `
        -ExtraPatterns $ExtraArtifactPatterns
} else {
    Write-Host ""
    Write-Host "When done, extract artifacts with:"
    Write-Host "  .\scripts\Copy-Artifacts.ps1 -VMName '$($cfg.VMName)' -DestPath '$ArtifactDest'"
}
