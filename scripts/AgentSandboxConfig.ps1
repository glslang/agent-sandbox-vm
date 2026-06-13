# Shared config helpers for host-side Agent Sandbox scripts.

function Get-AgentSandboxRoot {
    Join-Path $env:USERPROFILE ".agent-sandbox"
}

function Get-AgentSandboxVMRoot {
    Join-Path (Get-AgentSandboxRoot) "vms"
}

function Get-AgentSandboxLegacyConfigPath {
    Join-Path (Get-AgentSandboxRoot) "config.json"
}

function Test-AgentSandboxVMName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    if ([string]::IsNullOrWhiteSpace($VMName)) {
        throw "VM name cannot be empty."
    }

    if ($VMName -match '[<>:"/\\|?*]') {
        throw "VM name cannot contain any of these characters: < > : `" / \ | ? *"
    }
}

function Get-AgentSandboxVMStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    Test-AgentSandboxVMName -VMName $VMName
    Join-Path (Get-AgentSandboxVMRoot) $VMName
}

function Get-AgentSandboxConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    Join-Path (Get-AgentSandboxVMStatePath -VMName $VMName) "config.json"
}

function Get-AgentSandboxShareName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    $safeName = $VMName -replace '[^A-Za-z0-9_.-]', '-'
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($VMName))
    $hash = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString("x2") })
    $prefix = "AgentSandboxShare-"
    $maxNameLength = 80
    $maxVmPartLength = $maxNameLength - $prefix.Length - $hash.Length - 1
    if ($safeName.Length -gt $maxVmPartLength) {
        $safeName = $safeName.Substring(0, $maxVmPartLength)
    }

    "$prefix$safeName-$hash"
}

function Add-AgentSandboxConfigMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $configDir = Split-Path -Path $ConfigPath -Parent
    $credentialDir = if ($Config.CredPath) { $Config.CredPath } else { $configDir }
    $credentialPath = Join-Path $credentialDir "vm-cred.xml"

    if (-not $Config.ShareName) {
        $shareName = if ((Split-Path -Path $ConfigPath -Leaf) -eq "config.json" -and $ConfigPath -eq (Get-AgentSandboxLegacyConfigPath)) {
            "AgentSandboxShare"
        } else {
            Get-AgentSandboxShareName -VMName $Config.VMName
        }
        $Config | Add-Member -NotePropertyName ShareName -NotePropertyValue $shareName -Force
    }

    $Config | Add-Member -NotePropertyName ConfigPath -NotePropertyValue $ConfigPath -Force
    $Config | Add-Member -NotePropertyName ConfigDir -NotePropertyValue $configDir -Force
    $Config | Add-Member -NotePropertyName CredentialPath -NotePropertyValue $credentialPath -Force
    $Config | Add-Member -NotePropertyName IsLegacyConfig -NotePropertyValue ($ConfigPath -eq (Get-AgentSandboxLegacyConfigPath)) -Force
    $Config
}

function Save-AgentSandboxLegacyConfigSnapshot {
    param(
        [string]$SkipVMName = ""
    )

    $legacyConfigPath = Get-AgentSandboxLegacyConfigPath
    if (-not (Test-Path $legacyConfigPath)) {
        return $null
    }

    $legacyConfig = Get-Content $legacyConfigPath -Raw | ConvertFrom-Json
    if (-not $legacyConfig.VMName -or ($SkipVMName -and $legacyConfig.VMName -eq $SkipVMName)) {
        return $null
    }

    $perVMConfigPath = Get-AgentSandboxConfigPath -VMName $legacyConfig.VMName
    if (Test-Path $perVMConfigPath) {
        return $null
    }

    if (-not $legacyConfig.ShareName) {
        $legacyConfig | Add-Member -NotePropertyName ShareName -NotePropertyValue "AgentSandboxShare" -Force
    }
    if (-not $legacyConfig.CredPath) {
        $legacyConfig | Add-Member -NotePropertyName CredPath -NotePropertyValue (Get-AgentSandboxRoot) -Force
    }

    $config = @{}
    foreach ($property in $legacyConfig.PSObject.Properties) {
        if ($property.Name -notin @("ConfigPath", "ConfigDir", "CredentialPath", "IsLegacyConfig")) {
            $config[$property.Name] = $property.Value
        }
    }

    Save-AgentSandboxConfig -Config $config
}

function Resolve-AgentSandboxConfig {
    param(
        [string]$VMName = "",
        [switch]$RequireVM
    )

    $legacyConfigPath = Get-AgentSandboxLegacyConfigPath
    $configPath = $null

    if ($VMName) {
        Test-AgentSandboxVMName -VMName $VMName
        $perVMConfigPath = Get-AgentSandboxConfigPath -VMName $VMName
        if (Test-Path $perVMConfigPath) {
            $configPath = $perVMConfigPath
        } elseif (Test-Path $legacyConfigPath) {
            $legacyConfig = Get-Content $legacyConfigPath -Raw | ConvertFrom-Json
            if ($legacyConfig.VMName -eq $VMName) {
                $configPath = $legacyConfigPath
            }
        }

        if (-not $configPath) {
            throw "No saved config found for VM '$VMName'. Expected: $perVMConfigPath"
        }
    } elseif (Test-Path $legacyConfigPath) {
        $configPath = $legacyConfigPath
    } else {
        $configFiles = @(Get-ChildItem -Path (Get-AgentSandboxVMRoot) -Filter config.json -Recurse -ErrorAction SilentlyContinue)
        if ($configFiles.Count -eq 1) {
            $configPath = $configFiles[0].FullName
        } elseif ($configFiles.Count -gt 1) {
            throw "Multiple VM configs exist. Rerun with -VMName."
        } else {
            throw "No Agent Sandbox config found. Run Bootstrap.ps1 first."
        }
    }

    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $cfg.VMName) {
        throw "Config at $configPath does not contain VMName."
    }

    if ($VMName -and $cfg.VMName -ne $VMName) {
        throw "Config at $configPath is for VM '$($cfg.VMName)', not '$VMName'."
    }

    if (-not $cfg.ShareName) {
        $shareName = if ($configPath -eq $legacyConfigPath) { "AgentSandboxShare" } else { Get-AgentSandboxShareName -VMName $cfg.VMName }
        $cfg | Add-Member -NotePropertyName ShareName -NotePropertyValue $shareName -Force
    }

    if ($RequireVM) {
        Get-VM -Name $cfg.VMName -ErrorAction Stop | Out-Null
    }

    Add-AgentSandboxConfigMetadata -Config $cfg -ConfigPath $configPath
}

function Save-AgentSandboxConfig {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [switch]$SetCurrent
    )

    Test-AgentSandboxVMName -VMName $Config.VMName

    $vmStatePath = Get-AgentSandboxVMStatePath -VMName $Config.VMName
    New-Item -ItemType Directory -Force -Path $vmStatePath | Out-Null

    $configPath = Join-Path $vmStatePath "config.json"
    $Config | ConvertTo-Json -Depth 5 | Out-File $configPath -Encoding utf8

    if ($SetCurrent) {
        $root = Get-AgentSandboxRoot
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $Config | ConvertTo-Json -Depth 5 | Out-File (Get-AgentSandboxLegacyConfigPath) -Encoding utf8
    }

    $configPath
}

function Get-AgentSandboxCredentialPath {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    if ($Config.CredentialPath) {
        return $Config.CredentialPath
    }

    Join-Path (Get-AgentSandboxVMStatePath -VMName $Config.VMName) "vm-cred.xml"
}

function Protect-AgentSandboxPath {
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

function Import-AgentSandboxCredential {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [switch]$PromptIfMissing,

        [string]$PromptMessage = "VM credentials"
    )

    $credPath = Get-AgentSandboxCredentialPath -Config $Config
    if (Test-Path $credPath) {
        $cred = Import-Clixml $credPath
        Protect-AgentSandboxPath -Path $credPath
        return $cred
    }

    if (-not $PromptIfMissing) {
        throw "VM credentials not found. Run .\scripts\Save-VMCredentials.ps1 -VMName $($Config.VMName)."
    }

    Write-Host ""
    Write-Host "  Enter the Windows username and password for VM '$($Config.VMName)'."
    $cred = Get-Credential -Message $PromptMessage
    Save-AgentSandboxCredential -Config $Config -Credential $cred
    $cred
}

function Save-AgentSandboxCredential {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $credPath = Get-AgentSandboxCredentialPath -Config $Config
    $credDir = Split-Path -Path $credPath -Parent
    New-Item -ItemType Directory -Force -Path $credDir | Out-Null
    $Credential | Export-Clixml -Path $credPath
    Protect-AgentSandboxPath -Path $credPath
    $credPath
}

function Ensure-AgentSandboxShare {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    New-Item -ItemType Directory -Force -Path $Config.SharedDrive | Out-Null

    $shareName = $Config.ShareName
    $existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($existingShare -and $existingShare.Path -ne $Config.SharedDrive) {
        Remove-SmbShare -Name $shareName -Force
        $existingShare = $null
    }

    if (-not $existingShare) {
        New-SmbShare -Name $shareName `
                     -Path $Config.SharedDrive `
                     -FullAccess "$env:USERDOMAIN\$env:USERNAME" | Out-Null
        Write-Host "  SMB share created: \\localhost\$shareName -> $($Config.SharedDrive)"
    } else {
        Write-Host "  SMB share ready: \\localhost\$shareName -> $($Config.SharedDrive)"
    }
}
