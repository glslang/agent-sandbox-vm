# scripts/Save-VMCredentials.ps1
# Run once on host. Saves VM login credentials securely for unattended artifact extraction.

function Protect-PathForCurrentUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in @($acl.Access)) {
        $acl.PurgeAccessRules($rule.IdentityReference)
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($item.PSIsContainer) {
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
        $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    } else {
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
        $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    }

    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritanceFlags,
        $propagationFlags,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($accessRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$credPath = "$env:USERPROFILE\.agent-sandbox\vm-cred.xml"

Write-Host "Enter the username and password for the VM Windows account."
Write-Host "(This is the account you created during Windows setup inside the VM.)"
Write-Host ""

$cred = Get-Credential -Message "VM credentials"
$cred | Export-Clixml -Path $credPath

# Restrict access to current user only
Protect-PathForCurrentUser -Path $credPath

Write-Host ""
Write-Host "Credentials saved to: $credPath"
Write-Host "Only your Windows account can read this file."
