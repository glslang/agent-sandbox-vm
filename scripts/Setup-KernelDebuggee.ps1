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

    # TCP port the firewall rule opens and the printed connect command targets.
    # This script creates no listener of its own, so anything other than 5985
    # (the HTTP listener Enable-PSRemoting sets up) needs a listener you
    # configured yourself; the run warns when none is bound to this port.
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

# Name is the stable identity used for lookup, update, and removal; DisplayName
# is only what the firewall UI shows and is not unique.
$WinRmRuleId = "AgentSandbox-Debuggee-WinRM"
$WinRmRuleName = "Agent Sandbox Debuggee WinRM"
$PolicyKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$TokenFilterPolicyName = "LocalAccountTokenFilterPolicy"

# What this script changed outside its own firewall rule, so -Disable can put
# the machine back the way it found it instead of guessing at defaults.
$RemotingStatePath = Join-Path $env:ProgramData "agent-sandbox\kernel-debuggee-remoting.json"

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

function Get-RemotingState {
    if (-not (Test-Path $RemotingStatePath)) {
        return $null
    }

    try {
        Get-Content -Path $RemotingStatePath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not read $RemotingStatePath ($($_.Exception.Message)); -Disable will only remove this script's own settings."
        $null
    }
}

function Save-RemotingState {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$TokenFilterPolicy,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$AdjustedRule
    )

    $stateDir = Split-Path -Path $RemotingStatePath -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    # A null TokenFilterPolicy records "the value did not exist", which is what
    # -Disable restores by deleting it again.
    [ordered]@{
        TokenFilterPolicy = $TokenFilterPolicy
        AdjustedRules     = @($AdjustedRule)
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $RemotingStatePath -Encoding UTF8
}

function Get-TokenFilterPolicyValue {
    $policy = Get-ItemProperty -Path $PolicyKeyPath -Name $TokenFilterPolicyName -ErrorAction SilentlyContinue
    if (-not $policy) {
        return $null
    }

    [int]$policy.$TokenFilterPolicyName
}

function Get-CompetingWinRmRule {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Port
    )

    # Windows Firewall allow rules are additive, so Enable-PSRemoting's own
    # exceptions keep the port open at their own wider scope no matter how
    # narrow this script's rule is. Match on the port filter rather than on rule
    # names, which are localized and vary by Windows version.
    $wantedPorts = @($Port | ForEach-Object { [string]$_ })

    Get-NetFirewallPortFilter -All |
        Where-Object {
            $_.Protocol -eq "TCP" -and
            @($_.LocalPort | Where-Object { $wantedPorts -contains $_ }).Count -gt 0
        } |
        Get-NetFirewallRule |
        Where-Object {
            $_.Name -ne $WinRmRuleId -and
            $_.Direction -eq "Inbound" -and
            $_.Action -eq "Allow" -and
            $_.Enabled -eq "True"
        }
}

function Get-WinRmListenerTransport {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    # "None" only when the WSMan config was readable and nothing is bound to
    # this port; "Unknown" whenever it could not be read, so callers fall back
    # to a port heuristic instead of asserting a transport this never saw.
    try {
        $listeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop)
    } catch {
        return "Unknown"
    }

    foreach ($listener in $listeners) {
        try {
            $settings = @(Get-ChildItem -Path $listener.PSPath -ErrorAction Stop)
        } catch {
            return "Unknown"
        }

        $listenerPort = ($settings | Where-Object { $_.Name -eq "Port" }).Value
        if (-not $listenerPort -or [int]$listenerPort -ne $Port) {
            continue
        }

        $transport = ($settings | Where-Object { $_.Name -eq "Transport" }).Value
        if ($transport) {
            return $transport.ToString().ToUpperInvariant()
        }

        return "Unknown"
    }

    "None"
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

    $priorPolicy = Get-TokenFilterPolicyValue

    # -SkipNetworkProfileCheck: the debuggee usually sits on a Hyper-V internal
    # switch, which Windows classifies as a Public network.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service WinRM -StartupType Automatic
    Write-Host "  PowerShell remoting enabled; WinRM starts automatically."

    # Narrow the exceptions Enable-PSRemoting just (re)created to the same
    # allowlist, otherwise -WinRmRemoteAddress would report a boundary the
    # firewall does not actually enforce. 5985 is always in scope because the
    # call above reopens the default HTTP listener there whatever -WinRmPort
    # says, and that endpoint would otherwise keep its wider exception.
    $scopedPorts = @(@($Port, 5985) | Select-Object -Unique)

    $adjustedRules = @()
    foreach ($rule in Get-CompetingWinRmRule -Port $scopedPorts) {
        $priorAddress = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)

        try {
            Set-NetFirewallRule -Name $rule.Name -RemoteAddress $RemoteAddress
        } catch {
            # Group-policy rules cannot be edited locally; say so rather than
            # letting the summary claim a scope this rule still overrides.
            Write-Warning "  Could not narrow existing WinRM exception '$($rule.DisplayName)': $($_.Exception.Message)"
            continue
        }

        $adjustedRules += [pscustomobject]@{
            Name          = $rule.Name
            RemoteAddress = $priorAddress
        }

        Write-Host "  Narrowed existing WinRM exception: $($rule.DisplayName) (was $($priorAddress -join ', '))"
    }

    # Carry a rule this script owns so -Disable has something unambiguous to
    # remove, and so the scope survives a later Enable-PSRemoting run.
    $existingRule = Get-NetFirewallRule -Name $WinRmRuleId -ErrorAction SilentlyContinue
    if ($existingRule) {
        Set-NetFirewallRule `
            -Name $WinRmRuleId `
            -Direction Inbound `
            -Action Allow `
            -Enabled True `
            -Profile $FirewallProfile

        Get-NetFirewallRule -Name $WinRmRuleId | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter `
            -Protocol TCP `
            -LocalPort $Port

        Get-NetFirewallRule -Name $WinRmRuleId | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter `
            -RemoteAddress $RemoteAddress

        Write-Host "  Firewall rule updated: $WinRmRuleName"
    } else {
        New-NetFirewallRule `
            -Name $WinRmRuleId `
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

    # Only the first run sees the machine's original settings. A rerun must not
    # overwrite that record with values this script already changed, or -Disable
    # would restore its own configuration instead of the machine's.
    $state = Get-RemotingState
    if ($state) {
        $knownRules = @(@($state.AdjustedRules) | ForEach-Object { $_.Name })
        $newRules = @($adjustedRules | Where-Object { $knownRules -notcontains $_.Name })
        if ($newRules.Count -gt 0) {
            Save-RemotingState `
                -TokenFilterPolicy $state.TokenFilterPolicy `
                -AdjustedRule (@($state.AdjustedRules) + $newRules)
        }
    } else {
        Save-RemotingState -TokenFilterPolicy $priorPolicy -AdjustedRule $adjustedRules
    }
}

function Restore-TokenFilterPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        if ($null -eq (Get-TokenFilterPolicyValue)) {
            Write-Host "  $TokenFilterPolicyName not present."
        } else {
            Remove-ItemProperty -Path $PolicyKeyPath -Name $TokenFilterPolicyName
            Write-Host "  $TokenFilterPolicyName removed; network logons are filtered again."
        }

        return
    }

    New-ItemProperty `
        -Path $PolicyKeyPath `
        -Name $TokenFilterPolicyName `
        -Value ([int]$Value) `
        -PropertyType DWord `
        -Force | Out-Null

    Write-Host "  $TokenFilterPolicyName restored to its previous value ($Value)."
}

function Disable-DebuggeeRemoting {
    $state = Get-RemotingState

    $existingRule = Get-NetFirewallRule -Name $WinRmRuleId -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -Name $WinRmRuleId
        Write-Host "  Firewall rule removed: $WinRmRuleName"
    } else {
        Write-Host "  Firewall rule not present: $WinRmRuleName"
    }

    if (-not $state) {
        # No record means no evidence this script set the policy, so deleting it
        # could silently undo a value configured independently. Report it and
        # let the operator decide.
        Write-Host "  No saved state at $RemotingStatePath; removed only this script's own firewall rule."

        $currentPolicy = Get-TokenFilterPolicyValue
        if ($null -eq $currentPolicy) {
            Write-Host "  $TokenFilterPolicyName not present."
        } else {
            Write-Host "  $TokenFilterPolicyName is $currentPolicy and was left alone. Remove it with:"
            Write-Host "    Remove-ItemProperty -Path '$PolicyKeyPath' -Name $TokenFilterPolicyName"
        }
    } else {
        foreach ($record in @($state.AdjustedRules)) {
            if (-not $record) {
                continue
            }

            try {
                Set-NetFirewallRule -Name $record.Name -RemoteAddress @($record.RemoteAddress)
                Write-Host "  Restored WinRM exception scope: $($record.Name) ($(@($record.RemoteAddress) -join ', '))"
            } catch {
                Write-Warning "  Could not restore '$($record.Name)': $($_.Exception.Message)"
            }
        }

        Restore-TokenFilterPolicy -Value $state.TokenFilterPolicy
        Remove-Item -Path $RemotingStatePath -Force
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
        Write-Host "  New-NetFirewallRule -Name '$WinRmRuleId' -DisplayName '$WinRmRuleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $WinRmPort -RemoteAddress $($WinRmRemoteAddress -join ',') -Profile $($WinRmFirewallProfile -join ',')"
        Write-Host "  New-ItemProperty -Path '$PolicyKeyPath' -Name $TokenFilterPolicyName -Value 1 -PropertyType DWord -Force"
    } elseif (-not $SkipRemoting) {
        Write-Host ""
        Write-Host "WinRM access:"
        Write-Host "  Port:            $WinRmPort/tcp"
        Write-Host "  Allowed remotes: $($WinRmRemoteAddress -join ', ')"
        Write-Host "  Profiles:        $($WinRmFirewallProfile -join ', ')"

        if ($WinRmPort -ne 5985) {
            Write-Host "  Also scoped:     5985/tcp, the listener Enable-PSRemoting opens"
        }

        $debuggeeAddresses = Get-DebuggeeIPv4Address
        if ($debuggeeAddresses.Count -gt 0) {
            Write-Host "  This VM:         $($debuggeeAddresses -join ', ')"
        }

        $transport = Get-WinRmListenerTransport -Port $WinRmPort
        if ($transport -eq "None") {
            Write-Warning "  No WinRM listener is bound to port $WinRmPort. This script opens the firewall but creates no listener; configure one (for example 'winrm quickconfig -transport:https' for 5986) before connecting."
        }

        # Match the connect command to the port that was opened and to the
        # transport actually configured there. The port only decides it when the
        # WSMan config could not be read.
        $connectArgs = "-ComputerName <debuggee-ip>"
        if ($WinRmPort -ne 5985) {
            $connectArgs += " -Port $WinRmPort"
        }

        $useSsl = if ($transport -eq "HTTPS") {
            $true
        } elseif ($transport -eq "HTTP") {
            $false
        } else {
            $WinRmPort -eq 5986
        }

        if ($useSsl) {
            $connectArgs += " -UseSSL"
        }

        Write-Host ""
        Write-Host "Copy binaries in from the debugger host with:"
        Write-Host '  Set-Item WSMan:\localhost\Client\TrustedHosts -Value <debuggee-ip> -Concatenate -Force'
        Write-Host "  `$session = New-PSSession $connectArgs -Credential (Get-Credential)"
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
