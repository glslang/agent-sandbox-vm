# scripts/Setup-KernelDebugger.ps1
# Run on HOST/debugger machine. Optionally installs WinDbg and opens the KDNET
# firewall port needed to debug the VM/debuggee.

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # UDP port used by KDNET. Must match the debuggee BCD configuration.
    [ValidateRange(49152, 65535)]
    [int]$Port = 50000,

    # Install WinDbg on this debugger machine via winget.
    [switch]$InstallWinDbg,

    # Shared KDNET key. If omitted, the script prints a generated key.
    [ValidatePattern('^[0-9a-zA-Z]{1,13}(\.[0-9a-zA-Z]{1,13}){3}$')]
    [string]$Key
)

$ErrorActionPreference = "Stop"

function New-KdNetKey {
    $alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

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

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Kernel Debugger Host Setup"
Write-Host "----------------------------------------------"
Write-Host ""

if (-not $Key) {
    $Key = New-KdNetKey
} else {
    $Key = $Key.ToLowerInvariant()
}

if ($InstallWinDbg) {
    if (-not (Test-CommandExists -Name "winget")) {
        throw "winget was not found. Install App Installer from Microsoft Store, then rerun this script."
    }

    if ($PSCmdlet.ShouldProcess("Microsoft.WinDbg", "Install WinDbg via winget")) {
        winget install --silent --accept-package-agreements --accept-source-agreements Microsoft.WinDbg
    }
} else {
    Write-Host "WinDbg install skipped. Pass -InstallWinDbg to install Microsoft.WinDbg via winget."
}

$ruleName = "Agent Sandbox KDNET Debugger UDP $Port"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($existingRule) {
    Write-Host "Firewall rule already exists: $ruleName"
} elseif ($PSCmdlet.ShouldProcess($ruleName, "Create inbound UDP firewall rule")) {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol UDP `
        -LocalPort $Port `
        -Profile Any | Out-Null

    Write-Host "Firewall rule created: $ruleName"
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
