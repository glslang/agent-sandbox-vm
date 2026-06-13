# scripts/Setup-KernelDebugger.ps1
# Run on the debugger machine. Optionally installs WinDbg and opens the KDNET
# firewall port needed to debug another VM. Hyper-V firmware switches only work
# when this is run on the Hyper-V host.

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # UDP port used by KDNET. Must match the debuggee BCD configuration.
    [ValidateRange(49152, 65535)]
    [int]$Port = 50000,

    # Remote VM IP, CIDR range, or firewall keyword allowed to reach the KDNET port.
    [ValidateNotNullOrEmpty()]
    [string[]]$RemoteAddress = @("LocalSubnet"),

    # Firewall profiles where the KDNET listener is allowed.
    [ValidateSet("Domain", "Private", "Public", "Any")]
    [string[]]$FirewallProfile = @("Domain", "Private"),

    # Hyper-V VM to prepare for BCDEdit-based kernel debugging. Host only.
    [string]$VMName,

    # Path to the agent sandbox config used to find the default VM name.
    [string]$ConfigPath = "$env:USERPROFILE\.agent-sandbox\config.json",

    # Install WinDbg on this debugger machine via winget.
    [switch]$InstallWinDbg,

    # Skip KDNET firewall setup. Useful for Hyper-V-host-only Secure Boot changes.
    [switch]$SkipFirewall,

    # Turn off VM Secure Boot before running Setup-KernelDebuggee.ps1. Host only.
    [switch]$DisableVmSecureBoot,

    # Turn VM Secure Boot back on after kernel debugging is disabled. Host only.
    [switch]$EnableVmSecureBoot,

    # Shared KDNET key. If omitted, the script prints a generated key.
    [ValidatePattern('^[0-9a-zA-Z]{1,13}(\.[0-9a-zA-Z]{1,13}){3}$')]
    [string]$Key
)

$ErrorActionPreference = "Stop"

function New-KdNetKey {
    $alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    $bytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

    $parts = for ($group = 0; $group -lt 4; $group++) {
        $chars = for ($i = 0; $i -lt 12; $i++) {
            $alphabet[$bytes[($group * 12) + $i] % $alphabet.Length]
        }

        -join $chars
    }

    $parts -join "."
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Test-UdpPortExcluded {
    param([Parameter(Mandatory = $true)][int]$Port)

    $output = & netsh int ipv4 show excludedportrange protocol=udp 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not query IPv4 UDP excluded port ranges; continuing without reserved-port validation."
        return $false
    }

    foreach ($line in $output) {
        if ($line -match '^\s*(\d+)\s+(\d+)(?:\s|$)') {
            $start = [int]$matches[1]
            $end = [int]$matches[2]
            if ($Port -ge $start -and $Port -le $end) {
                return $true
            }
        }
    }

    $false
}

function Resolve-VMName {
    if ($VMName) {
        return $VMName
    }

    if (-not (Test-Path $ConfigPath)) {
        throw "VMName was not provided and config was not found at $ConfigPath."
    }

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.VMName) {
        throw "Config at $ConfigPath does not contain VMName."
    }

    $cfg.VMName
}

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Kernel Debugger Host Setup"
Write-Host "----------------------------------------------"
Write-Host ""

if ($DisableVmSecureBoot -and $EnableVmSecureBoot) {
    throw "Use only one of -DisableVmSecureBoot or -EnableVmSecureBoot."
}

if ($FirewallProfile -contains "Any" -and $FirewallProfile.Count -gt 1) {
    throw "Use -FirewallProfile Any by itself, or choose one or more of Domain, Private, Public."
}

if ($InstallWinDbg) {
    if (-not (Test-CommandExists -Name "winget")) {
        throw "winget was not found. Install App Installer from Microsoft Store, then rerun this script."
    }

    if ($PSCmdlet.ShouldProcess("Microsoft.WinDbg", "Install WinDbg via winget")) {
        Invoke-NativeCommand `
            -Command "winget" `
            -Arguments @("install", "--id", "Microsoft.WinDbg", "--exact", "--source", "winget", "--silent", "--accept-package-agreements", "--accept-source-agreements") `
            -Description "winget install Microsoft.WinDbg"
    }
} else {
    Write-Host "WinDbg install skipped. Pass -InstallWinDbg to install Microsoft.WinDbg via winget."
}

if ($DisableVmSecureBoot -or $EnableVmSecureBoot) {
    $targetVMName = Resolve-VMName
    $vm = Get-VM -Name $targetVMName -ErrorAction Stop
    if ($vm.State -ne "Off") {
        throw "VM '$targetVMName' must be Off before changing Secure Boot. Shut it down and rerun this script."
    }

    if ($DisableVmSecureBoot) {
        if ($PSCmdlet.ShouldProcess($targetVMName, "Disable Secure Boot for kernel debugging")) {
            Set-VMFirmware -VMName $targetVMName -EnableSecureBoot Off
            Write-Host "Secure Boot disabled for VM '$targetVMName'."
        }
    } else {
        if ($PSCmdlet.ShouldProcess($targetVMName, "Enable Secure Boot after kernel debugging")) {
            Set-VMFirmware -VMName $targetVMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
            Write-Host "Secure Boot enabled for VM '$targetVMName' (MicrosoftWindows template)."
        }
    }
}

if (-not $SkipFirewall) {
    if (Test-UdpPortExcluded -Port $Port) {
        throw "UDP port $Port is in a Windows excluded port range on this debugger machine. Rerun with a different -Port and use the same port on the debuggee."
    }

    if (-not $Key) {
        $Key = New-KdNetKey
    } else {
        $Key = $Key.ToLowerInvariant()
    }

    $firewallConfigured = $false
    $ruleName = "Agent Sandbox KDNET Debugger UDP $Port"
    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existingRule) {
        if ($PSCmdlet.ShouldProcess($ruleName, "Update inbound UDP firewall rule")) {
            foreach ($rule in $existingRule) {
                Set-NetFirewallRule `
                    -InputObject $rule `
                    -Direction Inbound `
                    -Action Allow `
                    -Enabled True `
                    -Profile $FirewallProfile

                $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter `
                    -Protocol UDP `
                    -LocalPort $Port

                $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter `
                    -RemoteAddress $RemoteAddress
            }

            Write-Host "Firewall rule updated: $ruleName"
            Write-Host "  RemoteAddress: $($RemoteAddress -join ', ')"
            Write-Host "  Profile: $($FirewallProfile -join ', ')"
            $firewallConfigured = $true
        }
    } elseif ($PSCmdlet.ShouldProcess($ruleName, "Create inbound UDP firewall rule")) {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol UDP `
            -LocalPort $Port `
            -RemoteAddress $RemoteAddress `
            -Profile $FirewallProfile | Out-Null

        Write-Host "Firewall rule created: $ruleName"
        Write-Host "  RemoteAddress: $($RemoteAddress -join ', ')"
        Write-Host "  Profile: $($FirewallProfile -join ', ')"
        $firewallConfigured = $true
    }

    if (-not $firewallConfigured) {
        Write-Host ""
        Write-Host "Debugger setup was not applied."
        exit 0
    }

    $windbgCommand = "windbgx -k net:port=$Port,key=$Key"

    Write-Host ""
    Write-Host "Debugger setup ready."
    Write-Host ""
    Write-Host "Use this KDNET key when configuring the debuggee:"
    Write-Host "  $Key"
    Write-Host ""
    Write-Host "Start WinDbg with:"
    Write-Host "  $windbgCommand"
    Write-Host ""
    Write-Host "If windbgx is not on PATH, launch WinDbg from Start and open:"
    Write-Host "  File > Start debugging > Attach to kernel > NET"
} else {
    Write-Host ""
    Write-Host "KDNET firewall setup skipped."
}
