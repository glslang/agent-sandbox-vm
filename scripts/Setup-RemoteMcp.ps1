# scripts/Setup-RemoteMcp.ps1
# Run INSIDE the VM as Administrator. Configures Windows OpenSSH so an MCP
# client on another machine can run a stdio MCP server on this VM over ssh.
#
# This is the zero-code way to split a Windows-only MCP server from the harness
# driving it: ssh already carries a pair of pipes, so the server is registered
# on the client as `ssh -T <host> <server.exe>` and neither side needs transport
# code. A kernel debugger is the usual reason to want it -- the debugger has to
# be where Windows is, the model does not.
#
# Four things have to be true, and three of them fail silently when they are
# not, so this script does all four and -Disable puts them back:
#   1. OpenSSH Server installed, running, and starting automatically
#   2. The port open to the client -- and every other rule on that port
#      narrowed to the same allowlist, so -ClientAddress is the boundary it
#      claims to be
#   3. The sshd default shell pointed at cmd.exe, the only one that leaves
#      line-delimited JSON-RPC alone
#   4. The client's public key in the file sshd will actually read, with the
#      ACL sshd insists on

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "Enable")]
param(
    # OpenSSH public key line the client authenticates with, e.g. the contents
    # of ~/.ssh/id_ed25519.pub. Without it (or -PublicKeyPath) the transport is
    # configured but no key is installed, and the run says where to put one.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$PublicKey,

    # File holding that key, when copying the file in is easier than the line.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$PublicKeyPath,

    # Account the client logs in as. Decides which authorized-keys file sshd
    # reads, which is not the same file for a member of Administrators.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$User = $env:USERNAME,

    # Remote IP, CIDR range, or firewall keyword allowed to reach sshd on this
    # VM. Scope this to the client machine when possible.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string[]]$ClientAddress = @("LocalSubnet"),

    # Firewall profiles where sshd is reachable. Defaults to Any because a
    # hypervisor's guest network usually comes up Public, while the rule the
    # OpenSSH capability installs covers only Domain and Private.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateSet("Domain", "Private", "Public", "Any")]
    [string[]]$FirewallProfile = @("Any"),

    # TCP port the firewall rule opens and the printed client config targets.
    # This script does not edit sshd_config, so anything other than 22 needs a
    # Port line you set there yourself; the run warns when nothing is bound.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateRange(1, 65535)]
    [int]$Port = 22,

    # Path to the MCP server on this VM, e.g. C:\tools\windbg-mcp.exe. Used
    # only to print the client-side registration and handshake probe.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$ServerCommand,

    # Name the printed client config uses for this VM, both as the ssh_config
    # Host alias and as the MCP server name.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$SshHostAlias = "agent-sandbox-vm",

    # Leave the firewall untouched. On enable, this script normally opens its
    # own rule and narrows competing ones; on disable, it normally removes and
    # restores them.
    [Parameter(ParameterSetName = "Enable")]
    [Parameter(ParameterSetName = "Disable")]
    [switch]$SkipFirewall,

    # Leave the sshd default shell untouched, for a VM where something else
    # owns that setting.
    [Parameter(ParameterSetName = "Enable")]
    [Parameter(ParameterSetName = "Disable")]
    [switch]$SkipDefaultShell,

    # On disable, leave the keys this script installed in place -- useful when
    # only the network exposure is being closed.
    [Parameter(ParameterSetName = "Disable")]
    [switch]$SkipKeys,

    # Close remote MCP access again.
    [Parameter(Mandatory = $true, ParameterSetName = "Disable")]
    [switch]$Disable
)

$ErrorActionPreference = "Stop"

# Name is the stable identity used for lookup, update, and removal; DisplayName
# is only what the firewall UI shows and is not unique.
$SshRuleId = "AgentSandbox-RemoteMcp-SSH"
$SshRuleName = "Agent Sandbox Remote MCP SSH"
$OpenSshKeyPath = "HKLM:\SOFTWARE\OpenSSH"
$DefaultShellValueName = "DefaultShell"
$CmdPath = Join-Path $env:SystemRoot "System32\cmd.exe"
$SshProgramData = Join-Path $env:ProgramData "ssh"
$AdministratorsKeyFile = Join-Path $SshProgramData "administrators_authorized_keys"

# Well-known SIDs rather than group names: icacls takes localized names, so
# "Administrators" fails outright on a non-English Windows and the refusal
# reads as an ACL problem rather than a language one.
$AdministratorsSid = "S-1-5-32-544"
$SystemSid = "S-1-5-18"

# What this script changed, so -Disable can put the machine back the way it
# found it instead of guessing at defaults.
$StatePath = Join-Path $env:ProgramData "agent-sandbox\remote-mcp-ssh.json"

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

function Get-RemoteMcpState {
    if (-not (Test-Path $StatePath)) {
        return $null
    }

    try {
        Get-Content -Path $StatePath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not read $StatePath ($($_.Exception.Message)); -Disable will only remove this script's own settings."
        $null
    }
}

function Save-RemoteMcpState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $stateDir = Split-Path -Path $StatePath -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

function Resolve-PublicKey {
    param(
        [AllowEmptyString()]
        [string]$Key,

        [AllowEmptyString()]
        [string]$Path
    )

    if ($Key -and $Path) {
        throw "Use either -PublicKey or -PublicKeyPath, not both."
    }

    $line = $null

    if ($Path) {
        if (-not (Test-Path $Path)) {
            throw "Public key file not found: $Path"
        }

        # A .pub file is one line; take the first non-empty one so a trailing
        # newline or a stray blank line does not become the key.
        $line = @(Get-Content -Path $Path | Where-Object { $_.Trim() }) | Select-Object -First 1
        if (-not $line) {
            throw "Public key file is empty: $Path"
        }
    } elseif ($Key) {
        $line = $Key
    } else {
        return $null
    }

    $line = $line.Trim()

    # Catch the two easy mistakes here rather than at first login, where sshd
    # reports only "Permission denied (publickey)": a PRIVATE key pasted by
    # accident, and something that is not an OpenSSH key line at all.
    if ($line -match "^-+BEGIN ") {
        throw "That is a private key. Install the public half instead -- the .pub file, one line beginning with ssh-ed25519 or ssh-rsa."
    }

    if ($line -notmatch "^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+\S+") {
        throw "Does not look like an OpenSSH public key line: $line"
    }

    $line
}

function Get-UserSid {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        (New-Object System.Security.Principal.NTAccount($Name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Could not resolve account '$Name': $($_.Exception.Message)"
    }
}

function Test-UserIsAdministrator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    # sshd decides this from the logon token, which resolves nested groups;
    # this sees direct members only. Treat anything it cannot answer as
    # administrator, because that is the direction where guessing wrong is
    # silent: sshd would read the administrators file while the key sat in the
    # per-user one, and the login just never authenticates.
    try {
        $members = @(Get-LocalGroupMember -SID $AdministratorsSid -ErrorAction Stop)
    } catch {
        Write-Warning "  Could not enumerate the local Administrators group ($($_.Exception.Message)); assuming '$Name' is a member."
        return $true
    }

    foreach ($member in $members) {
        if ("$($member.SID)" -eq $Sid) {
            return $true
        }
    }

    $false
}

function Get-UserProfilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    $entry = Get-ItemProperty -Path $key -Name "ProfileImagePath" -ErrorAction SilentlyContinue
    if (-not $entry) {
        throw "No profile directory is registered for '$Name'. Sign in as that account once, then rerun."
    }

    [System.Environment]::ExpandEnvironmentVariables($entry.ProfileImagePath)
}

function Set-AuthorizedKeysAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdministratorsFile,

        [Parameter(Mandatory = $true)]
        [string]$OwnerSid
    )

    # sshd refuses an authorized-keys file any other principal can write, and
    # logs the refusal nowhere an operator would think to look -- it presents
    # as "Permission denied (publickey)" with a correct key already in place.
    # This is the single most common way this step fails silently.
    $grants = if ($IsAdministratorsFile) {
        @("*$($AdministratorsSid):F", "*$($SystemSid):F")
    } else {
        @("*$($OwnerSid):F", "*$($AdministratorsSid):F", "*$($SystemSid):F")
    }

    $arguments = @($Path, "/inheritance:r")
    foreach ($grant in $grants) {
        $arguments += "/grant"
        $arguments += $grant
    }

    Invoke-NativeCommand -Command "icacls" -Arguments $arguments -Description "icacls on $Path" | Out-Null
}

function Add-AuthorizedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $existing = if (Test-Path $Path) {
        @(Get-Content -Path $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else {
        @()
    }

    if ($existing -contains $Key) {
        Write-Host "  Key already present in $Path"
        return $false
    }

    # ASCII on purpose: sshd does not read a UTF-16 file, which is what
    # Windows PowerShell's default redirection encoding would produce.
    Set-Content -Path $Path -Value (@($existing) + $Key) -Encoding Ascii
    Write-Host "  Key added to $Path"
    $true
}

function Remove-AuthorizedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $Path)) {
        Write-Host "  Authorized keys file already gone: $Path"
        return
    }

    $remaining = @(Get-Content -Path $Path | Where-Object { $_.Trim() -ne $Key })
    Set-Content -Path $Path -Value $remaining -Encoding Ascii
    Write-Host "  Key removed from $Path"
}

function Install-OpenSshServer {
    $capability = Get-WindowsCapability -Online -Name "OpenSSH.Server*" |
        Sort-Object -Property Name |
        Select-Object -Last 1

    if (-not $capability) {
        throw "This Windows image offers no OpenSSH.Server capability. Install OpenSSH for Windows by hand, then rerun."
    }

    if ($capability.State -eq "Installed") {
        Write-Host "  Already installed: $($capability.Name)"
        return $false
    }

    Write-Host "  Installing $($capability.Name)..."
    try {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    } catch {
        throw "Could not install $($capability.Name): $($_.Exception.Message). Features on Demand come from Windows Update, so start the session with -Internet and rerun."
    }

    Write-Host "  Installed: $($capability.Name)"
    $true
}

function Start-SshService {
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "The sshd service is missing even though the OpenSSH Server capability reports installed. Reboot this VM and rerun."
    }

    $prior = [pscustomobject]@{
        StartType  = "$($service.StartType)"
        WasRunning = ($service.Status -eq "Running")
    }

    Set-Service -Name sshd -StartupType Automatic

    if (-not $prior.WasRunning) {
        # The first start is also what generates the host keys and creates
        # C:\ProgramData\ssh, which the authorized-keys step below needs.
        Start-Service -Name sshd
        Write-Host "  sshd started; startup type Automatic (was $($prior.StartType))."
    } else {
        Write-Host "  sshd already running; startup type Automatic (was $($prior.StartType))."
    }

    $prior
}

function Set-SshDefaultShell {
    # OpenSSH runs an exec request through the default shell. cmd /c hands the
    # child the inherited pipe handles and stays out of the way; PowerShell
    # captures a native command's output through its own pipeline and applies
    # its output encoding, which can rewrite the line endings underneath
    # line-delimited JSON-RPC -- and serializes its progress and error streams
    # as CLIXML on stderr. Either one corrupts an MCP transport.
    if (-not (Test-Path $OpenSshKeyPath)) {
        New-Item -Path $OpenSshKeyPath -Force | Out-Null
    }

    $entry = Get-ItemProperty -Path $OpenSshKeyPath -Name $DefaultShellValueName -ErrorAction SilentlyContinue
    $prior = if ($entry) { [string]$entry.$DefaultShellValueName } else { $null }

    if ($prior -and $prior -ieq $CmdPath) {
        Write-Host "  Already $CmdPath"
    } else {
        New-ItemProperty `
            -Path $OpenSshKeyPath `
            -Name $DefaultShellValueName `
            -Value $CmdPath `
            -PropertyType String `
            -Force | Out-Null

        if ($prior) {
            Write-Host "  Set to $CmdPath (was $prior)."
        } else {
            Write-Host "  Set to $CmdPath"
        }
    }

    # A null prior records "the value did not exist", which -Disable restores
    # by deleting it again -- sshd falls back to cmd.exe on its own.
    $prior
}

function Restore-SshDefaultShell {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    if (-not (Test-Path $OpenSshKeyPath)) {
        Write-Host "  No OpenSSH registry key; default shell left alone."
        return
    }

    if ($null -eq $Value -or "$Value" -eq "") {
        $entry = Get-ItemProperty -Path $OpenSshKeyPath -Name $DefaultShellValueName -ErrorAction SilentlyContinue
        if (-not $entry) {
            Write-Host "  Default shell not set."
        } else {
            Remove-ItemProperty -Path $OpenSshKeyPath -Name $DefaultShellValueName
            Write-Host "  Default shell value removed; sshd falls back to cmd.exe."
        }

        return
    }

    New-ItemProperty `
        -Path $OpenSshKeyPath `
        -Name $DefaultShellValueName `
        -Value "$Value" `
        -PropertyType String `
        -Force | Out-Null

    Write-Host "  Default shell restored to its previous value ($Value)."
}

function Get-CompetingSshRule {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Port
    )

    # Windows Firewall allow rules are additive, so the rule the OpenSSH
    # capability installs keeps the port open at its own wider scope no matter
    # how narrow this script's rule is. Match on the port filter rather than on
    # rule names, which are localized and vary by Windows version.
    $wantedPorts = @($Port | ForEach-Object { [string]$_ })

    Get-NetFirewallPortFilter -All |
        Where-Object {
            $_.Protocol -eq "TCP" -and
            @($_.LocalPort | Where-Object { $wantedPorts -contains $_ }).Count -gt 0
        } |
        Get-NetFirewallRule |
        Where-Object {
            $_.Name -ne $SshRuleId -and
            $_.Direction -eq "Inbound" -and
            $_.Action -eq "Allow" -and
            $_.Enabled -eq "True"
        }
}

function Expand-FirewallProfile {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Profile
    )

    # A rule's Profile is a flags value where "Any" stands for all three.
    if ($Profile -contains "Any") {
        return @("Domain", "Private", "Public")
    }

    @($Profile)
}

function Enable-RemoteMcpFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string[]]$RemoteAddress,

        [Parameter(Mandatory = $true)]
        [string[]]$FirewallProfile
    )

    # 22 stays in scope even when -Port names another one, because the
    # capability's own exception sits there and would otherwise keep the
    # default port open wider than -ClientAddress says.
    $scopedPorts = @(@($Port, 22) | Select-Object -Unique)

    $adjustedRules = @()
    foreach ($rule in Get-CompetingSshRule -Port $scopedPorts) {
        $priorAddress = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
        $priorProfile = @("$($rule.Profile)" -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $priorEnabled = "$($rule.Enabled)"

        # A profile the caller did not ask for is as much of a hole as an
        # address they did not ask for. Only ever narrow -- widening someone
        # else's rule to match a broader request would hand out access this
        # script was never asked to grant.
        $narrowedProfile = $null
        $disableRule = $false

        if (-not ($FirewallProfile -contains "Any")) {
            $ruleProfiles = Expand-FirewallProfile -Profile $priorProfile
            $overlap = @($ruleProfiles | Where-Object { $FirewallProfile -contains $_ })

            if ($overlap.Count -eq 0) {
                $disableRule = $true
            } elseif ($overlap.Count -lt $ruleProfiles.Count) {
                $narrowedProfile = $overlap
            }
        }

        try {
            Set-NetFirewallRule -Name $rule.Name -RemoteAddress $RemoteAddress

            if ($disableRule) {
                Set-NetFirewallRule -Name $rule.Name -Enabled False
            } elseif ($narrowedProfile) {
                Set-NetFirewallRule -Name $rule.Name -Profile $narrowedProfile
            }
        } catch {
            # Group-policy rules cannot be edited locally; say so rather than
            # letting the summary claim a scope this rule still overrides.
            Write-Warning "  Could not narrow existing SSH exception '$($rule.DisplayName)': $($_.Exception.Message)"
            continue
        }

        $adjustedRules += [pscustomobject]@{
            Name          = $rule.Name
            RemoteAddress = $priorAddress
            Profile       = $priorProfile
            Enabled       = $priorEnabled
        }

        if ($disableRule) {
            Write-Host "  Disabled existing SSH exception outside the requested profiles: $($rule.DisplayName) (was $($priorProfile -join ', '))"
        } else {
            $scopeNow = if ($narrowedProfile) { $narrowedProfile -join ', ' } else { $priorProfile -join ', ' }
            Write-Host "  Narrowed existing SSH exception: $($rule.DisplayName) (was $($priorAddress -join ', ') on $($priorProfile -join ', '); now $($RemoteAddress -join ', ') on $scopeNow)"
        }
    }

    # Carry a rule this script owns so -Disable has something unambiguous to
    # remove, and so the scope survives a later capability repair. The
    # capability's own rule covers Domain and Private only, and a hypervisor's
    # guest network usually comes up Public -- the most confusing failure in
    # this whole setup, because sshd is running and listening and everything
    # looks right from inside the guest while the client's SYNs are dropped. It
    # presents as ssh HANGING after "Connecting to <address> port 22", where
    # nothing listening at all would have said "Connection refused" at once.
    #
    # Set-NetConnectionProfile -NetworkCategory Private is one line shorter and
    # also works, but it activates every other Private-scoped inbound rule as a
    # side effect -- file and printer sharing, network discovery. On a debugger
    # VM sharing a subnet with the target it is debugging, that is a lot of
    # surface bought for one port.
    $existingRule = Get-NetFirewallRule -Name $SshRuleId -ErrorAction SilentlyContinue
    if ($existingRule) {
        Set-NetFirewallRule `
            -Name $SshRuleId `
            -Direction Inbound `
            -Action Allow `
            -Enabled True `
            -Profile $FirewallProfile

        Get-NetFirewallRule -Name $SshRuleId | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter `
            -Protocol TCP `
            -LocalPort $Port

        Get-NetFirewallRule -Name $SshRuleId | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter `
            -RemoteAddress $RemoteAddress

        Write-Host "  Firewall rule updated: $SshRuleName"
    } else {
        New-NetFirewallRule `
            -Name $SshRuleId `
            -DisplayName $SshRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -RemoteAddress $RemoteAddress `
            -Profile $FirewallProfile | Out-Null

        Write-Host "  Firewall rule created: $SshRuleName"
    }

    $adjustedRules
}

function Disable-RemoteMcpFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State
    )

    $existingRule = Get-NetFirewallRule -Name $SshRuleId -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -Name $SshRuleId
        Write-Host "  Firewall rule removed: $SshRuleName"
    } else {
        Write-Host "  Firewall rule not present: $SshRuleName"
    }

    if (-not $State) {
        Write-Host "  No saved state at $StatePath; removed only this script's own firewall rule."
        return
    }

    foreach ($record in @($State.AdjustedRules)) {
        if (-not $record) {
            continue
        }

        try {
            Set-NetFirewallRule -Name $record.Name -RemoteAddress @($record.RemoteAddress)

            if ($record.Profile) {
                Set-NetFirewallRule -Name $record.Name -Profile @($record.Profile)
            }
            if ($record.Enabled) {
                Set-NetFirewallRule -Name $record.Name -Enabled $record.Enabled
            }

            Write-Host "  Restored SSH exception: $($record.Name) ($(@($record.RemoteAddress) -join ', ')$(if ($record.Profile) { " on $(@($record.Profile) -join ', ')" }))"
        } catch {
            Write-Warning "  Could not restore '$($record.Name)': $($_.Exception.Message)"
        }
    }
}

function Restore-SshService {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State
    )

    if (-not $State -or -not $State.SshStartType) {
        Write-Host "  No saved state; sshd left as it is."
        return
    }

    # Put sshd back where this script found it -- but never remove the
    # capability, because uninstalling it discards the host keys and changes
    # the fingerprint every client has already accepted.
    try {
        $startType = if ($State.CapabilityInstalled) { "Manual" } else { "$($State.SshStartType)" }
        Set-Service -Name sshd -StartupType $startType

        if ($State.CapabilityInstalled -or -not $State.SshWasRunning) {
            Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
            Write-Host "  sshd stopped; startup type $startType."
        } else {
            Write-Host "  sshd left running; startup type restored to $startType."
        }
    } catch {
        Write-Warning "  Could not restore the sshd service: $($_.Exception.Message)"
    }
}

function Get-VMIPv4Address {
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

function Test-PortListening {
    param([Parameter(Mandatory = $true)][int]$Port)

    # Get-NetTCPConnection throws rather than returning nothing when no
    # connection matches, so "nothing bound" and "could not ask" both land in
    # the catch. Callers only use this to decide whether to warn.
    try {
        @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop).Count -gt 0
    } catch {
        $false
    }
}

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Remote MCP over SSH -- VM Setup"
Write-Host "----------------------------------------------"
Write-Host ""

if ($Disable) {
    if (-not $PSCmdlet.ShouldProcess("OpenSSH remote MCP access", "Close remote MCP access")) {
        Write-Host "Remote MCP access was not changed."
        exit 0
    }

    $state = Get-RemoteMcpState

    Write-Host "Closing remote MCP access:"

    if ($SkipFirewall) {
        Write-Host "  Skipped firewall changes (-SkipFirewall specified)."
    } else {
        Disable-RemoteMcpFirewall -State $state
    }

    if ($SkipDefaultShell) {
        Write-Host "  Skipped default shell (-SkipDefaultShell specified)."
    } elseif ($state) {
        Restore-SshDefaultShell -Value $state.DefaultShell
    } else {
        Write-Host "  No saved state; default shell left alone."
    }

    if ($SkipKeys) {
        Write-Host "  Left installed keys in place (-SkipKeys specified)."
    } elseif ($state) {
        $records = @(@($state.AuthorizedKeys) | Where-Object { $_ })
        if ($records.Count -eq 0) {
            Write-Host "  No keys were installed by this script."
        }

        foreach ($record in $records) {
            try {
                Remove-AuthorizedKey -Path $record.Path -Key $record.Key
            } catch {
                Write-Warning "  Could not remove key from '$($record.Path)': $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "  No saved state; authorized keys left alone."
    }

    Restore-SshService -State $state

    if ($state) {
        Remove-Item -Path $StatePath -Force
    }

    Write-Host ""
    Write-Host "Remote MCP access closed. The OpenSSH Server capability and its host keys were left installed."
    exit 0
}

if ($FirewallProfile -contains "Any" -and $FirewallProfile.Count -gt 1) {
    throw "Use -FirewallProfile Any by itself, or choose one or more of Domain, Private, Public."
}

$resolvedKey = Resolve-PublicKey -Key $PublicKey -Path $PublicKeyPath

if ($ServerCommand -and -not (Test-Path $ServerCommand)) {
    Write-Warning "No file at -ServerCommand '$ServerCommand'. The client registration below is printed anyway; copy the server in before using it."
}

if (-not $PSCmdlet.ShouldProcess("OpenSSH server", "Open remote MCP access over ssh")) {
    Write-Host "Remote MCP setup was not applied."
    exit 0
}

Write-Host "[1/4] OpenSSH Server:"
$capabilityInstalled = Install-OpenSshServer
$priorService = Start-SshService

Write-Host ""
Write-Host "[2/4] Firewall:"
$adjustedRules = @()
if ($SkipFirewall) {
    Write-Host "  Skipped (-SkipFirewall specified)."
} else {
    $adjustedRules = @(Enable-RemoteMcpFirewall `
        -Port $Port `
        -RemoteAddress $ClientAddress `
        -FirewallProfile $FirewallProfile)
}

Write-Host ""
Write-Host "[3/4] Default shell:"
$priorDefaultShell = $null
if ($SkipDefaultShell) {
    Write-Host "  Skipped (-SkipDefaultShell specified). An MCP transport needs cmd.exe here; PowerShell rewrites the stream."
} else {
    $priorDefaultShell = Set-SshDefaultShell
}

Write-Host ""
Write-Host "[4/4] Authorized key:"
$userSid = Get-UserSid -Name $User
$userIsAdministrator = Test-UserIsAdministrator -Name $User -Sid $userSid

# sshd ignores ~/.ssh/authorized_keys for a member of the Administrators group
# and reads the ProgramData file instead -- which it will be on a VM used for
# kernel debugging. A key in the wrong file is not an error anywhere; it is
# just a login that never authenticates.
$authorizedKeysPath = if ($userIsAdministrator) {
    $AdministratorsKeyFile
} else {
    Join-Path (Get-UserProfilePath -Name $User -Sid $userSid) ".ssh\authorized_keys"
}

$installedKeys = @()
if (-not $resolvedKey) {
    Write-Host "  No key given (-PublicKey / -PublicKeyPath). sshd will read:"
    Write-Host "    $authorizedKeysPath"
    Write-Host "  Put the client's public key there, then rerun this script so the ACL is set."
} else {
    $keyDir = Split-Path -Path $authorizedKeysPath -Parent
    if (-not (Test-Path $keyDir)) {
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    }

    $added = Add-AuthorizedKey -Path $authorizedKeysPath -Key $resolvedKey
    Set-AuthorizedKeysAcl -Path $authorizedKeysPath -IsAdministratorsFile $userIsAdministrator -OwnerSid $userSid
    Write-Host "  ACL tightened on $authorizedKeysPath"

    if ($added) {
        $installedKeys = @([pscustomobject]@{ Path = $authorizedKeysPath; Key = $resolvedKey })
    }
}

# Only the first run sees the machine's original settings. A rerun must not
# overwrite that record with values this script already changed, or -Disable
# would restore its own configuration instead of the machine's.
$state = Get-RemoteMcpState
if ($state) {
    $knownRules = @(@($state.AdjustedRules) | ForEach-Object { $_.Name })
    $knownKeys = @(@($state.AuthorizedKeys) | ForEach-Object { "$($_.Path)|$($_.Key)" })

    Save-RemoteMcpState -State ([ordered]@{
        DefaultShell        = $state.DefaultShell
        SshStartType        = $state.SshStartType
        SshWasRunning       = $state.SshWasRunning
        CapabilityInstalled = ([bool]$state.CapabilityInstalled -or $capabilityInstalled)
        AdjustedRules       = @(@($state.AdjustedRules) + @($adjustedRules | Where-Object { $knownRules -notcontains $_.Name }))
        AuthorizedKeys      = @(@($state.AuthorizedKeys) + @($installedKeys | Where-Object { $knownKeys -notcontains "$($_.Path)|$($_.Key)" }))
    })
} else {
    Save-RemoteMcpState -State ([ordered]@{
        DefaultShell        = $priorDefaultShell
        SshStartType        = $priorService.StartType
        SshWasRunning       = $priorService.WasRunning
        CapabilityInstalled = $capabilityInstalled
        AdjustedRules       = @($adjustedRules)
        AuthorizedKeys      = @($installedKeys)
    })
}

Write-Host ""
Write-Host "Remote MCP setup ready."
Write-Host ""
Write-Host "SSH access:"
Write-Host "  Port:            $Port/tcp"
Write-Host "  Allowed remotes: $($ClientAddress -join ', ')"
Write-Host "  Profiles:        $($FirewallProfile -join ', ')"
Write-Host "  Login user:      $User$(if ($userIsAdministrator) { ' (Administrators member)' })"
Write-Host "  Authorized keys: $authorizedKeysPath"

if ($Port -ne 22) {
    Write-Host "  Also scoped:     22/tcp, where the OpenSSH capability's own exception sits"
}

$vmAddresses = Get-VMIPv4Address
if ($vmAddresses.Count -gt 0) {
    Write-Host "  This VM:         $($vmAddresses -join ', ')"
}

if (-not (Test-PortListening -Port $Port)) {
    Write-Warning "  Nothing is listening on port $Port. This script does not edit sshd_config, so a non-default port needs a 'Port $Port' line in $SshProgramData\sshd_config followed by 'Restart-Service sshd'."
}

$sshHostName = if ($vmAddresses.Count -gt 0) { $vmAddresses[0] } else { "<vm-address>" }
$remoteCommand = if ($ServerCommand) { $ServerCommand } else { "<path-to-mcp-server.exe>" }
$portLine = if ($Port -ne 22) { "`n      Port $Port" } else { "" }
$probeJson = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'

Write-Host ""
Write-Host @"
On the client, give this VM a stable name in ~/.ssh/config:

  Host $SshHostAlias
      HostName $sshHostName
      User $User$portLine
      IdentityFile ~/.ssh/id_ed25519
      RequestTTY no
      BatchMode yes
      ServerAliveInterval 30
      ServerAliveCountMax 6

RequestTTY no is load-bearing: a PTY would apply echo and line discipline to the
transport. BatchMode yes makes a missing key fail at once instead of hanging on a
prompt no one will see, because an MCP client's stdin belongs to the protocol.

Prove the handshake before registering anything:

  printf '%s\n' '$probeJson' \
      | ssh -T $SshHostAlias '$remoteCommand' | cat -vet | head -3

One line of JSON on stdout carrying serverInfo, and no ^M anywhere, is the pass.
A ^M, a shell banner, or a blank first line means the default shell is
interfering; rerun this script without -SkipDefaultShell. Nothing downstream
works if this does not, and the failure there is an unreadable parse error that
names no cause.

Register it -- local scope, because an address, a user name and an absolute path
are machine-specific and do not belong in a repository's .mcp.json:

  claude mcp add $SshHostAlias --scope local -- ssh -T $SshHostAlias '$remoteCommand'

Two things worth checking once, since guessing wrong costs a confusing failure
much later:

  ssh $SshHostAlias powershell -NoProfile -Command "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')"
    True means this session gets a full, unfiltered token, so a server's
    elevation-only tools work. That is this host's logon policy, not a promise.

  ssh $SshHostAlias "tasklist | findstr <server-exe>"    (after quitting the client)
    Empty is the answer. The channel closing has to reach the server's stdin, or
    a session it was holding open -- a live kernel target above all -- is left
    frozen rather than released.

An ssh session inherits machine and user environment variables from the registry
but nothing from a PowerShell `$PROFILE, so a server configured by environment
variable needs them set machine-wide:

  [Environment]::SetEnvironmentVariable('NAME', 'value', 'Machine')

A server configured by a file under the user profile -- windbg-mcp's
%USERPROFILE%\.windbg-mcp\profiles.json, for one -- is immune to how it started,
and is the better place for anything secret.
"@
