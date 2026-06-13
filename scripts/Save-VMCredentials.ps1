# scripts/Save-VMCredentials.ps1
# Run once on host. Saves VM login credentials securely for unattended artifact extraction.

param(
    [string]$VMName = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\AgentSandboxConfig.ps1"

$cfg = Resolve-AgentSandboxConfig -VMName $VMName
$credPath = Get-AgentSandboxCredentialPath -Config $cfg

Write-Host "Enter the username and password for VM '$($cfg.VMName)'."
Write-Host "(This is the account you created during Windows setup inside the VM.)"
Write-Host ""

$cred = Get-Credential -Message "VM credentials"
$savedPath = Save-AgentSandboxCredential -Config $cfg -Credential $cred

Write-Host ""
Write-Host "Credentials saved to: $savedPath"
Write-Host "Only your Windows account can read this file."
