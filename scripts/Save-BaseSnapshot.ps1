# scripts/Save-BaseSnapshot.ps1
# Run on HOST after provisioning the VM. Takes the clean base snapshot
# and switches the network back to the internal-only switch for isolation.

#Requires -RunAsAdministrator

param(
    [string]$VMName = ""
)

. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName -RequireVM

Write-Host "Waiting for VM '$($cfg.VMName)' to be fully shut down..."
$timeout = 60
$elapsed = 0
while ((Get-VM -Name $cfg.VMName).State -ne "Off") {
    if ($elapsed -ge $timeout) {
        Write-Host "ERROR: VM did not shut down within $timeout seconds."
        Write-Host "Shut it down manually via: Stop-VM -Name '$($cfg.VMName)' -Force"
        exit 1
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
    Write-Host "  Still waiting... ($elapsed s)"
}

# Switch back to internal-only network for isolation
Write-Host "Switching network back to internal-only (Agent-Internal)..."
Get-VM -Name $cfg.VMName | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName "Agent-Internal"
Write-Host "  Network: Agent-Internal (isolated)"

Write-Host "Taking snapshot: CleanProvisionedBase..."
Checkpoint-VM -Name $cfg.VMName -SnapshotName "CleanProvisionedBase"

Write-Host ""
Write-Host "Snapshot saved. Your VM is ready."
Write-Host "Network is set to internal-only (no internet)."
Write-Host ""
Write-Host "To allow internet in a session (e.g. for cargo fetch), use:"
Write-Host "  .\Start-Session.ps1 -VMName '$($cfg.VMName)' -ProjectPath <path> -Internet"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Save VM credentials:  .\scripts\Save-VMCredentials.ps1 -VMName '$($cfg.VMName)'"
Write-Host "  2. Start a dev session:  .\Start-Session.ps1 -VMName '$($cfg.VMName)' -ProjectPath C:\Projects\myapp"
