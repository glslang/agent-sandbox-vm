# scripts/Setup-KernelDebuggee.ps1
# Run INSIDE the VM/debuggee as Administrator. Configures Windows kernel
# debugging over KDNET so the host/debugger can attach with WinDbg.

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "Enable")]
param(
    # Host/debugger IP reachable from this VM.
    [Parameter(Mandatory = $true, ParameterSetName = "Enable")]
    [ValidateScript({
        $addr = $null
        [System.Net.IPAddress]::TryParse($_, [ref]$addr) -and
            $addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    })]
    [string]$DebuggerHostIp,

    # UDP port used by KDNET. Must match the debugger command.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateRange(49152, 65535)]
    [int]$Port = 50000,

    # Shared KDNET key. If omitted, the script generates one.
    [Parameter(ParameterSetName = "Enable")]
    [ValidatePattern('^[0-9a-zA-Z]{1,13}(\.[0-9a-zA-Z]{1,13}){3}$')]
    [string]$Key,

    # Disable kernel debugging on this VM.
    [Parameter(Mandatory = $true, ParameterSetName = "Disable")]
    [switch]$Disable
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

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Kernel Debuggee VM Setup"
Write-Host "----------------------------------------------"
Write-Host ""

if ($Disable) {
    if ($PSCmdlet.ShouldProcess("BCD debug setting", "Disable kernel debugging")) {
        Invoke-NativeCommand `
            -Command "bcdedit" `
            -Arguments @("/debug", "off") `
            -Description "bcdedit /debug off"
    }

    Write-Host ""
    Write-Host "Kernel debugging disabled. Reboot the VM for the change to take effect."
    exit 0
}

if (-not $Key) {
    $Key = New-KdNetKey
} else {
    $Key = $Key.ToLowerInvariant()
}

if ($PSCmdlet.ShouldProcess("BCD debug setting", "Enable kernel debugging")) {
    Invoke-NativeCommand `
        -Command "bcdedit" `
        -Arguments @("/debug", "on") `
        -Description "bcdedit /debug on"
}

if ($PSCmdlet.ShouldProcess("BCD dbgsettings", "Configure KDNET endpoint")) {
    Invoke-NativeCommand `
        -Command "bcdedit" `
        -Arguments @("/dbgsettings", "net", "hostip:$DebuggerHostIp", "port:$Port", "key:$Key") `
        -Description "bcdedit /dbgsettings net"
}

$windbgCommand = "windbgx -k net:port=$Port,key=$Key"

Write-Host ""
Write-Host "Kernel debuggee setup ready."
Write-Host ""
Write-Host "Reboot this VM, then start WinDbg on the debugger host with:"
Write-Host "  $windbgCommand"
Write-Host ""
Write-Host "Debugger host IP:"
Write-Host "  $DebuggerHostIp"
Write-Host ""
Write-Host "KDNET key:"
Write-Host "  $Key"
