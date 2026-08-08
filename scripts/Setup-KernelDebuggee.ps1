# scripts/Setup-KernelDebuggee.ps1
# Run INSIDE the VM/debuggee as Administrator. Configures Windows kernel
# debugging over KDNET so the host/debugger can attach with WinDbg, and opens
# PowerShell remoting so the host can copy test binaries and drivers in.

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "Enable")]
param(
    # Host/debugger IP reachable from this VM.
    [Parameter(ParameterSetName = "Enable")]
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

    # Shared KDNET key printed by Setup-KernelDebugger.ps1 on the debugger machine.
    [Parameter(ParameterSetName = "Enable")]
    [ValidatePattern('^[0-9a-zA-Z]{1,13}(\.[0-9a-zA-Z]{1,13}){3}$')]
    [string]$Key,

    # Leave test signing untouched. On enable, this script normally turns test
    # signing on so test-signed drivers can load; on disable, it normally turns
    # it back off. Pass this switch on either path to leave the current
    # test-signing boot policy unchanged (for example, when test signing was
    # enabled independently of this script).
    [Parameter(ParameterSetName = "Enable")]
    [Parameter(ParameterSetName = "Disable")]
    [switch]$SkipTestSigning,

    # Remote IP, CIDR range, or firewall keyword allowed to reach WinRM on this
    # debuggee. Scope this to the debugger machine when possible.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string[]]$WinRmRemoteAddress = @("LocalSubnet"),

    # Firewall profiles where the WinRM listener is allowed. Defaults to Any
    # because a Hyper-V internal switch usually lands in the Public profile.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateSet("Domain", "Private", "Public", "Any")]
    [string[]]$WinRmFirewallProfile = @("Any"),

    # TCP port of the WinRM HTTP listener (5986 if the listener is HTTPS).
    [Parameter(ParameterSetName = "Enable")]
    [ValidateRange(1, 65535)]
    [int]$WinRmPort = 5985,

    # Leave PowerShell remoting untouched. On enable, this script normally turns
    # on PSRemoting, opens the WinRM firewall rule, and sets
    # LocalAccountTokenFilterPolicy; on disable, it normally removes the
    # firewall rule and that policy value. Pass this switch on either path to
    # leave the current remoting configuration unchanged (for example, when
    # remoting was configured independently of this script).
    [Parameter(ParameterSetName = "Enable")]
    [Parameter(ParameterSetName = "Disable")]
    [switch]$SkipRemoting,

    # Disable kernel debugging on this VM.
    [Parameter(Mandatory = $true, ParameterSetName = "Disable")]
    [switch]$Disable
)

$ErrorActionPreference = "Stop"

$WinRmRuleName = "Agent Sandbox Debuggee WinRM"
$PolicyKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$TokenFilterPolicyName = "LocalAccountTokenFilterPolicy"

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

function Assert-SecureBootDisabled {
    $cmd = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Warning "Confirm-SecureBootUEFI is unavailable; continuing without Secure Boot validation."
        return
    }

    try {
        $secureBootEnabled = Confirm-SecureBootUEFI
    } catch {
        Write-Warning "Could not determine Secure Boot state: $($_.Exception.Message)"
        return
    }

    if ($secureBootEnabled) {
        throw "Secure Boot is enabled. Shut down this VM, then run .\scripts\Setup-KernelDebugger.ps1 -DisableVmSecureBoot -SkipFirewall on the Hyper-V host from the agent-sandbox-vm repository. Do not run C:\Setup-KernelDebugger.ps1 inside this VM for the Secure Boot change. After that, start the VM and rerun this script."
    }
}

function Get-DebuggeeIPv4Address {
    try {
        $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
            Select-Object -ExpandProperty IPAddress
    } catch {
        Write-Warning "Could not enumerate IPv4 addresses: $($_.Exception.Message)"
        return @()
    }

    @($addresses)
}

function Enable-DebuggeeRemoting {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string[]]$RemoteAddress,

        [Parameter(Mandatory = $true)]
        [string[]]$FirewallProfile
    )

    # -SkipNetworkProfileCheck: the debuggee usually sits on a Hyper-V internal
    # switch, which Windows classifies as a Public network.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service WinRM -StartupType Automatic
    Write-Host "  PowerShell remoting enabled; WinRM starts automatically."

    # Enable-PSRemoting's own Public-profile rule is pinned to the local subnet,
    # so carry a rule this script owns and can scope and remove on -Disable.
    $existingRule = Get-NetFirewallRule -DisplayName $WinRmRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        foreach ($rule in $existingRule) {
            Set-NetFirewallRule `
                -InputObject $rule `
                -Direction Inbound `
                -Action Allow `
                -Enabled True `
                -Profile $FirewallProfile

            $rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter `
                -Protocol TCP `
                -LocalPort $Port

            $rule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter `
                -RemoteAddress $RemoteAddress
        }

        Write-Host "  Firewall rule updated: $WinRmRuleName"
    } else {
        New-NetFirewallRule `
            -DisplayName $WinRmRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -RemoteAddress $RemoteAddress `
            -Profile $FirewallProfile | Out-Null

        Write-Host "  Firewall rule created: $WinRmRuleName"
    }

    # Without this, a non-builtin local admin connecting over the network gets a
    # filtered token, so copies into protected paths and elevated commands fail.
    if (-not (Test-Path $PolicyKeyPath)) {
        New-Item -Path $PolicyKeyPath -Force | Out-Null
    }

    New-ItemProperty `
        -Path $PolicyKeyPath `
        -Name $TokenFilterPolicyName `
        -Value 1 `
        -PropertyType DWord `
        -Force | Out-Null

    Write-Host "  $TokenFilterPolicyName set to 1."
}

function Disable-DebuggeeRemoting {
    $existingRule = Get-NetFirewallRule -DisplayName $WinRmRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        $existingRule | Remove-NetFirewallRule
        Write-Host "  Firewall rule removed: $WinRmRuleName"
    } else {
        Write-Host "  Firewall rule not present: $WinRmRuleName"
    }

    $policy = Get-ItemProperty -Path $PolicyKeyPath -Name $TokenFilterPolicyName -ErrorAction SilentlyContinue
    if ($policy) {
        Remove-ItemProperty -Path $PolicyKeyPath -Name $TokenFilterPolicyName
        Write-Host "  $TokenFilterPolicyName removed; network logons are filtered again."
    } else {
        Write-Host "  $TokenFilterPolicyName not present."
    }

    # WinRM itself stays on: provisioned sandbox VMs enable it during
    # provisioning and other host workflows expect it.
    Write-Host "  PowerShell remoting left enabled."
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

        if ($SkipTestSigning) {
            Write-Host ""
            Write-Host "Kernel debugging disabled; left test signing untouched (-SkipTestSigning specified). Reboot the VM for the change to take effect."
        } else {
            Invoke-NativeCommand `
                -Command "bcdedit" `
                -Arguments @("/set", "testsigning", "off") `
                -Description "bcdedit /set testsigning off"

            Write-Host ""
            Write-Host "Kernel debugging and test signing disabled. Reboot the VM for the change to take effect."
        }

        Write-Host ""
        if ($SkipRemoting) {
            Write-Host "Left remoting configuration untouched (-SkipRemoting specified)."
        } else {
            Write-Host "Reverting host access:"
            Disable-DebuggeeRemoting
        }
    } else {
        Write-Host ""
        Write-Host "Kernel debugging was not changed."
    }

    exit 0
}

if ($WinRmFirewallProfile -contains "Any" -and $WinRmFirewallProfile.Count -gt 1) {
    throw "Use -WinRmFirewallProfile Any by itself, or choose one or more of Domain, Private, Public."
}

Assert-SecureBootDisabled

if (-not $DebuggerHostIp) {
    throw "DebuggerHostIp is required when enabling kernel debugging. Rerun with -DebuggerHostIp <debugger-ip>."
}

if (-not $Key) {
    throw "Key is required when enabling kernel debugging. Use the KDNET key printed by Setup-KernelDebugger.ps1 on the debugger machine, then rerun with -Key <key>."
}

$Key = $Key.ToLowerInvariant()

if ($PSCmdlet.ShouldProcess("BCD kernel debugging", "Enable debugging and configure KDNET endpoint")) {
    Invoke-NativeCommand `
        -Command "bcdedit" `
        -Arguments @("/debug", "on") `
        -Description "bcdedit /debug on"

    Invoke-NativeCommand `
        -Command "bcdedit" `
        -Arguments @("/dbgsettings", "net", "hostip:$DebuggerHostIp", "port:$Port", "key:$Key") `
        -Description "bcdedit /dbgsettings net"

    if ($SkipTestSigning) {
        Write-Host ""
        Write-Host "Skipped test signing (-SkipTestSigning specified)."
    } else {
        Invoke-NativeCommand `
            -Command "bcdedit" `
            -Arguments @("/set", "testsigning", "on") `
            -Description "bcdedit /set testsigning on"

        Write-Host ""
        Write-Host "Test signing enabled; test-signed drivers can load after reboot."
    }

    $remotingWarning = ""

    Write-Host ""
    if ($SkipRemoting) {
        Write-Host "Skipped remoting configuration (-SkipRemoting specified)."
    } else {
        Write-Host "Opening host access for binary copies:"
        try {
            Enable-DebuggeeRemoting `
                -Port $WinRmPort `
                -RemoteAddress $WinRmRemoteAddress `
                -FirewallProfile $WinRmFirewallProfile
        } catch {
            # KDNET is already configured at this point. Host file copies are a
            # convenience on top of it, so a failure here must not abort the run
            # and bury the reboot and WinDbg instructions below.
            $remotingWarning = $_.Exception.Message
            Write-Warning "  Host access was not opened: $remotingWarning"
        }
    }

    Write-Host ""
    Write-Host "Kernel debuggee setup ready."
    Write-Host ""
    Write-Host "Reboot this VM, then start WinDbg on the debugger host with the command printed by Setup-KernelDebugger.ps1."
    Write-Host ""
    Write-Host "Debugger host IP:"
    Write-Host "  $DebuggerHostIp"
    Write-Host ""
    Write-Host "KDNET port:"
    Write-Host "  $Port"

    if ($remotingWarning) {
        Write-Host ""
        Write-Host "Host access needs another pass ($remotingWarning)"
        Write-Host "Run this in the VM as Administrator:"
        Write-Host "  Enable-PSRemoting -Force -SkipNetworkProfileCheck"
        Write-Host "  New-NetFirewallRule -DisplayName '$WinRmRuleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $WinRmPort -RemoteAddress $($WinRmRemoteAddress -join ',') -Profile $($WinRmFirewallProfile -join ',')"
        Write-Host "  New-ItemProperty -Path '$PolicyKeyPath' -Name $TokenFilterPolicyName -Value 1 -PropertyType DWord -Force"
    } elseif (-not $SkipRemoting) {
        Write-Host ""
        Write-Host "WinRM listener:"
        Write-Host "  Port:            $WinRmPort/tcp"
        Write-Host "  Allowed remotes: $($WinRmRemoteAddress -join ', ')"
        Write-Host "  Profiles:        $($WinRmFirewallProfile -join ', ')"

        $debuggeeAddresses = Get-DebuggeeIPv4Address
        if ($debuggeeAddresses.Count -gt 0) {
            Write-Host "  This VM:         $($debuggeeAddresses -join ', ')"
        }

        Write-Host ""
        Write-Host "Copy binaries in from the debugger host with:"
        Write-Host '  Set-Item WSMan:\localhost\Client\TrustedHosts -Value <debuggee-ip> -Concatenate -Force'
        Write-Host '  $session = New-PSSession -ComputerName <debuggee-ip> -Credential (Get-Credential)'
        Write-Host '  Copy-Item -ToSession $session C:\build\driver.sys -Destination C:\workspace\'
        Write-Host ""
        Write-Host "If KDNET claims this VM's only network adapter and guest networking stops working, add a second"
        Write-Host "network adapter for WinRM, or copy files over PowerShell Direct from the Hyper-V host instead:"
        Write-Host '  $session = New-PSSession -VMName <vm-name> -Credential (Get-Credential)'
    }
} else {
    Write-Host ""
    Write-Host "Kernel debuggee setup was not applied."
}
