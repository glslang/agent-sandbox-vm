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

    # Which authorized-keys file sshd will read for -User. Auto works it out
    # from Administrators membership, which is what sshd itself goes by, and
    # refuses to guess when a group in that chain cannot be expanded -- name
    # the file yourself in that case. Getting it wrong is not an error
    # anywhere; it is a login that never authenticates.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateSet("Auto", "Administrators", "PerUser")]
    [string]$AuthorizedKeysFile = "Auto",

    # Path to the MCP server on this VM, e.g. C:\tools\windbg-mcp.exe. Used
    # only to print the client-side registration and handshake probe.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$ServerCommand,

    # Private key the printed client config points at. The key installed here
    # is a public half that could have come from anywhere, so assuming its
    # private half sits at the default path would hand out a config that
    # authenticates as the wrong identity -- and BatchMode makes that a silent
    # failure rather than a prompt.
    [Parameter(ParameterSetName = "Enable")]
    [ValidateNotNullOrEmpty()]
    [string]$ClientIdentityFile = "~/.ssh/id_ed25519",

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
$DefaultShellCommandOptionValueName = "DefaultShellCommandOption"
$CmdCommandOption = "/c"
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

# What -Disable did not put back this run, whether because a restore failed or
# because a -Skip switch held it back. Any entry keeps the state file: a record
# discarded while the machine is still changed cannot be retried.
$script:UnfinishedRestore = @()

function Set-FileContentAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    # Written beside the file and swapped in, never over it: a write that
    # cannot finish -- a full disk, a reset VM -- would otherwise leave a
    # truncated file where the only copy of something was. File::Replace also
    # keeps the destination's ACL, which for an authorized-keys file is the
    # tightened one this script put there.
    #
    # [NullString]::Value, not $null: PowerShell binds $null to a .NET string
    # parameter as an empty string, which Replace rejects.
    $temp = "$Path.new"
    [System.IO.File]::WriteAllBytes($temp, $Bytes)

    if (Test-Path $Path) {
        [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
    } else {
        Move-Item -Path $temp -Destination $Path -Force
    }
}

function Get-RemoteMcpState {
    # $null means there is no record. A record that exists but cannot be parsed
    # throws instead, because the two must never be confused: read as "no
    # record", a truncated file would be overwritten by the next enable with
    # the values this script had already written, and the machine's originals
    # would be gone for good.
    if (-not (Test-Path $StatePath)) {
        return $null
    }

    try {
        Get-Content -Path $StatePath -Raw | ConvertFrom-Json
    } catch {
        throw "$StatePath exists but could not be read ($($_.Exception.Message)). It records what this script changed, so it is not safe to carry on without it: restore or move the file, then rerun."
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

    # This record is the only way back for a machine this script has changed,
    # so it is swapped in rather than written over.
    $json = $State | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Set-FileContentAtomically -Path $StatePath -Bytes $utf8NoBom.GetBytes($json)
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

    # One line, not a pasted block. The pattern below is a prefix match, so a
    # second key on a second line would ride along unnoticed: both would be
    # written to the file and recorded as a single multi-line entry, which
    # -Disable then matches against no line at all and removes neither.
    if ($line -match "[`\r`\n]") {
        throw "Give one public key line. -PublicKey contained a line break, which usually means several keys were pasted at once -- add them one run at a time, or point -PublicKeyPath at a file."
    }

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

    # sshd decides this from the logon token, which resolves membership
    # through nested groups. Get-LocalGroupMember returns direct members only,
    # so walk the nesting: a user who is an administrator through a group would
    # otherwise get a confident "no", the key would go to the per-user file
    # while sshd read the administrators one, and every login would fail.
    #
    # A group that cannot be expanded does not end the walk. Domain groups sit
    # in Administrators on any domain-joined machine and none of them are local
    # groups, so bailing out there would answer "administrator" for every
    # account on the machine, standard users included -- trading one wrong
    # answer for a much more common one. Carry on, and report Unknown only if
    # the user was not found anywhere that could be read.
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($AdministratorsSid)
    $seen = @{}
    $unresolved = @()

    while ($pending.Count -gt 0) {
        $groupSid = "$($pending.Dequeue())"
        if ($seen.ContainsKey($groupSid)) {
            continue
        }

        $seen[$groupSid] = $true

        try {
            $members = @(Get-LocalGroupMember -SID $groupSid -ErrorAction Stop)
        } catch {
            $unresolved += $groupSid
            continue
        }

        foreach ($member in $members) {
            if ("$($member.SID)" -eq $Sid) {
                return [pscustomobject]@{ Result = "Yes"; Unresolved = @() }
            }

            if ("$($member.ObjectClass)" -eq "Group") {
                $pending.Enqueue("$($member.SID)")
            }
        }
    }

    if ($unresolved.Count -gt 0) {
        return [pscustomobject]@{ Result = "Unknown"; Unresolved = $unresolved }
    }

    [pscustomobject]@{ Result = "No"; Unresolved = @() }
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
        [string]$OwnerSid,

        [Parameter(Mandatory = $true)]
        [object]$Mutation,

        # $false when this run created the file, in which case there is no
        # prior DACL to put back.
        [Parameter(Mandatory = $true)]
        [bool]$FileExisted
    )

    # sshd refuses an authorized-keys file any other principal can write, and
    # logs the refusal nowhere an operator would think to look -- it presents
    # as "Permission denied (publickey)" with a correct key already in place.
    # This is the single most common way this step fails silently.
    #
    # The DACL is rebuilt rather than amended. `icacls /inheritance:r /grant`
    # reads like it tightens a file, but /inheritance:r drops only INHERITED
    # entries and /grant only adds or updates the trustees it names -- an
    # explicit entry for anyone else survives both. sshd would go on refusing
    # the file, or another account would keep write access to the login keys,
    # while this script reported the ACL tightened.
    #
    # By well-known SID rather than group name: a name is localized, and
    # "Administrators" does not exist on a non-English Windows.
    $grantSids = if ($IsAdministratorsFile) {
        @($AdministratorsSid, $SystemSid)
    } else {
        @($OwnerSid, $AdministratorsSid, $SystemSid)
    }

    $acl = Get-Acl -Path $Path

    # Rebuilding is destructive -- an explicit entry another account or a
    # management tool relied on goes with it -- so the DACL this replaces is
    # recorded first, and -Disable puts it back. Only the DACL: the owner and
    # the audit entries are not touched, so restoring them is not this
    # script's business either. Recorded before the rebuild, like every other
    # change here, and only when there was something to record.
    # Keyed by path: a rerun for a different -User or -AuthorizedKeysFile
    # rebuilds a second file's DACL, and a single slot would keep the first
    # record and drop the second, leaving -Disable unable to put that one back.
    $alreadyRecorded = @($Mutation.AuthorizedKeysAcls | Where-Object { $_.Path -eq $Path }).Count -gt 0

    if ($FileExisted -and -not $alreadyRecorded) {
        [void]$Mutation.AuthorizedKeysAcls.Add([pscustomobject]@{
            Path = $Path
            Sddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        })
    }

    # $true: protect from inheritance. $false: do not copy the inherited
    # entries down as explicit ones -- they leave the in-memory DACL here, so
    # the loop below sees only what was explicit to begin with.
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    foreach ($sid in @($grantSids | Select-Object -Unique)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)))
    }

    Set-Acl -Path $Path -AclObject $acl
}

function Add-AuthorizedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    # A byte-order mark means this file is not what sshd reads. Windows
    # PowerShell's redirection writes UTF-16 by default, and Get-Content
    # decodes that quite happily -- so the duplicate check below would pass
    # while appending UTF-8 bytes onto a UTF-16 stream produced a file sshd
    # cannot parse at all, with the run reporting success over it.
    if (Test-Path $Path) {
        $head = [System.IO.File]::ReadAllBytes($Path)
        $encoding = $null

        if ($head.Length -ge 4 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE -and $head[2] -eq 0x00 -and $head[3] -eq 0x00) {
            $encoding = "UTF-32 little-endian"
        } elseif ($head.Length -ge 4 -and $head[0] -eq 0x00 -and $head[1] -eq 0x00 -and $head[2] -eq 0xFE -and $head[3] -eq 0xFF) {
            $encoding = "UTF-32 big-endian"
        } elseif ($head.Length -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
            $encoding = "UTF-16 little-endian"
        } elseif ($head.Length -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
            $encoding = "UTF-16 big-endian"
        } elseif ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $encoding = "UTF-8"
        }

        if ($encoding) {
            throw "$Path starts with a $encoding byte-order mark. sshd reads this file as plain bytes, so it is already not being read the way it looks, and appending to it would make a file in two encodings. Convert it first -- read it, then write it back without a BOM -- and rerun."
        }
    }

    $existing = if (Test-Path $Path) {
        @(Get-Content -Path $Path | ForEach-Object { $_.Trim() })
    } else {
        @()
    }

    if ($existing -contains $Key) {
        Write-Host "  Key already present in $Path"
        return $false
    }

    # Appended, never rewritten. The file is not this script's to normalise: it
    # can hold other keys, comments, blank lines and non-ASCII in a comment
    # field, and rewriting every line -- which trimming and re-encoding amounts
    # to -- would destroy content nothing here records for -Disable to restore.
    #
    # UTF-8 without a BOM, written through .NET rather than Set-Content:
    # Windows PowerShell's -Encoding UTF8 emits a BOM, which on a new file
    # would sit in front of the first key and stop sshd reading it, and its
    # default redirection encoding is UTF-16, which sshd cannot read at all.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # A file whose last line has no newline would otherwise get this key glued
    # onto the end of it. Checked as bytes, so no encoding guess is involved.
    $separator = ""
    if (Test-Path $Path) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) {
            $separator = [Environment]::NewLine
        }
    }

    [System.IO.File]::AppendAllText($Path, $separator + $Key + [Environment]::NewLine, $utf8NoBom)
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

    # Byte for byte, because taking a line out means writing the file back and
    # this one is not this script's to normalise. Decoding it and rejoining the
    # lines would rewrite bytes that have nothing to do with the managed key: an
    # LF file would come back CRLF, a missing final newline would be supplied,
    # and anything that is not valid UTF-8 -- a comment in some other encoding
    # -- would come back as replacement characters. Only the managed line's own
    # bytes are cut out; every other byte is copied through untouched.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $kept = New-Object System.IO.MemoryStream
    $start = 0

    for ($i = 0; $i -le $bytes.Length; $i++) {
        # A line runs to the next LF, or to the end of the file.
        if ($i -lt $bytes.Length -and $bytes[$i] -ne 10) {
            continue
        }

        $end = [Math]::Min($i + 1, $bytes.Length)
        $length = $end - $start

        if ($length -gt 0) {
            $line = New-Object byte[] $length
            [System.Array]::Copy($bytes, $start, $line, 0, $length)

            # Trim covers the CR of a CRLF ending as well as stray whitespace.
            if ($utf8NoBom.GetString($line).Trim() -ne $Key) {
                $kept.Write($bytes, $start, $length)
            }
        }

        $start = $end
    }

    # Swapped in rather than written over: unrelated keys and comments in this
    # file are not recorded anywhere, so a half-written file would lose them
    # with nothing able to put them back.
    Set-FileContentAtomically -Path $Path -Bytes $kept.ToArray()
    $kept.Dispose()
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
    param(
        [Parameter(Mandatory = $true)]
        [object]$Mutation
    )

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "The sshd service is missing even though the OpenSSH Server capability reports installed. Reboot this VM and rerun."
    }

    # Written into the record before the first change rather than returned
    # after the last: Start-Service throws on an invalid sshd_config, with the
    # startup type already changed, and a return value never reaches the caller
    # from a function that threw.
    $priorStartType = "$($service.StartType)"
    $Mutation.SshStartType = $priorStartType
    $Mutation.SshWasRunning = ($service.Status -eq "Running")

    Set-Service -Name sshd -StartupType Automatic

    if (-not $Mutation.SshWasRunning) {
        # The first start is also what generates the host keys and creates
        # C:\ProgramData\ssh, which the authorized-keys step below needs.
        Start-Service -Name sshd
        Write-Host "  sshd started; startup type Automatic (was $priorStartType)."
    } else {
        Write-Host "  sshd already running; startup type Automatic (was $priorStartType)."
    }
}

function Get-OpenSshValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $entry = Get-ItemProperty -Path $OpenSshKeyPath -Name $Name -ErrorAction SilentlyContinue
    if (-not $entry) {
        return $null
    }

    [string]$entry.$Name
}

function Set-OpenSshValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    # A null means "this value did not exist", so putting that back is removing
    # it rather than writing an empty string.
    if ($null -eq $Value -or "$Value" -eq "") {
        if ($null -ne (Get-OpenSshValue -Name $Name)) {
            Remove-ItemProperty -Path $OpenSshKeyPath -Name $Name
        }

        return
    }

    New-ItemProperty `
        -Path $OpenSshKeyPath `
        -Name $Name `
        -Value "$Value" `
        -PropertyType String `
        -Force | Out-Null
}

function Set-SshDefaultShell {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Mutation
    )

    # OpenSSH runs an exec request through the default shell. cmd /c hands the
    # child the inherited pipe handles and stays out of the way; PowerShell
    # captures a native command's output through its own pipeline and applies
    # its output encoding, which can rewrite the line endings underneath
    # line-delimited JSON-RPC -- and serializes its progress and error streams
    # as CLIXML on stderr. Either one corrupts an MCP transport.
    if (-not (Test-Path $OpenSshKeyPath)) {
        New-Item -Path $OpenSshKeyPath -Force | Out-Null
    }

    $prior = Get-OpenSshValue -Name $DefaultShellValueName
    $priorOption = Get-OpenSshValue -Name $DefaultShellCommandOptionValueName

    # Recorded before the write, for the same reason as the service above. A
    # null prior records "the value did not exist", which -Disable restores by
    # deleting it again -- sshd falls back to cmd.exe on its own.
    $Mutation.DefaultShell = $prior
    $Mutation.DefaultShellCommandOption = $priorOption
    $Mutation.DefaultShellManaged = $true

    if ($prior -and $prior -ieq $CmdPath) {
        Write-Host "  Already $CmdPath"
    } else {
        Set-OpenSshValue -Name $DefaultShellValueName -Value $CmdPath

        if ($prior) {
            Write-Host "  Set to $CmdPath (was $prior)."
        } else {
            Write-Host "  Set to $CmdPath"
        }
    }

    # The switch sshd passes that shell. A machine set up for a Unix-style or
    # PowerShell default shell carries -c or -Command here, and changing only
    # DefaultShell would leave sshd running `cmd.exe -c ...` -- cmd wants /c, so
    # every exec request would fail while this step reported the shell
    # configured. Absent is right for cmd, which is sshd's own default, so only
    # a value that is there and wrong gets corrected.
    if ($priorOption -and $priorOption -ne $CmdCommandOption) {
        Set-OpenSshValue -Name $DefaultShellCommandOptionValueName -Value $CmdCommandOption
        Write-Host "  Command option set to $CmdCommandOption (was $priorOption)."
    }
}

function Restore-SshDefaultShell {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$CommandOption
    )

    if (-not (Test-Path $OpenSshKeyPath)) {
        Write-Host "  No OpenSSH registry key; default shell left alone."
        return
    }

    # Only if what is there now is what this script wrote. A record can outlive
    # the change it describes -- a partial -Disable whose reduced record could
    # not be saved leaves the full one on disk -- and putting a pre-enable value
    # over a shell somebody set in the meantime is the one outcome worse than
    # leaving it alone.
    $current = Get-OpenSshValue -Name $DefaultShellValueName
    if ($current -and -not ($current -ieq $CmdPath)) {
        Write-Host "  Default shell is now $current, which this script did not set; left alone."
        return
    }

    # Both halves, since setting a shell can have changed both.
    Set-OpenSshValue -Name $DefaultShellValueName -Value $Value
    Set-OpenSshValue -Name $DefaultShellCommandOptionValueName -Value $CommandOption

    if ($null -eq $Value -or "$Value" -eq "") {
        Write-Host "  Default shell value removed; sshd falls back to cmd.exe."
    } else {
        Write-Host "  Default shell restored to its previous value ($Value)."
    }
}

function Get-PortCoverage {
    param(
        [AllowNull()]
        [object]$LocalPort,

        [Parameter(Mandatory = $true)]
        [int[]]$Port
    )

    # A port filter is not always a number. -LocalPort takes a single port, a
    # range, or a keyword, so an exact-string test misses a rule whose range
    # spans the port and misses "Any" altogether -- and such a rule goes on
    # holding the port open at its own scope while this script reports
    # -ClientAddress as the boundary.
    #
    # "Specific" and "Any" are answered apart because they deserve different
    # treatment: see Enable-RemoteMcpFirewall.
    $sawAny = $false

    foreach ($entry in @($LocalPort)) {
        $text = "$entry".Trim()
        if (-not $text) {
            continue
        }

        if ($text -eq "Any") {
            $sawAny = $true
            continue
        }

        if ($text -match '^(\d+)\s*-\s*(\d+)$') {
            $low = [int]$matches[1]
            $high = [int]$matches[2]
            foreach ($wanted in $Port) {
                if ($wanted -ge $low -and $wanted -le $high) {
                    return "Specific"
                }
            }

            continue
        }

        $value = 0
        if ([int]::TryParse($text, [ref]$value)) {
            if ($Port -contains $value) {
                return "Specific"
            }

            continue
        }

        # A service keyword -- RPC, RPCEPMap, IPHTTPS, Teredo -- names no fixed
        # port to compare against, and none of them carry ssh.
    }

    if ($sawAny) {
        return "Any"
    }

    "None"
}

function Get-SshdReachReason {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Rule
    )

    # A rule on LocalPort Any covers ssh's port, but covering the port is not
    # the same as reaching sshd: most such rules are scoped to one program or
    # one service, which is why they are not rescoped. That was an assumption
    # until now -- ask instead. It reaches sshd only if BOTH filters admit it.
    try {
        $program = "$(($Rule | Get-NetFirewallApplicationFilter).Program)"
        $service = "$(($Rule | Get-NetFirewallServiceFilter).Service)"
    } catch {
        # A filter that cannot be read cannot be shown to exclude sshd.
        Write-Warning "  Could not read the program or service filter on '$($Rule.DisplayName)': $($_.Exception.Message)"
        return "allows any local port, and its program and service filters could not be read"
    }

    # $null when the rule cannot reach sshd; otherwise why it can, which is
    # what the operator needs in order to do something about it.
    $boundToSshd = ($program -match 'sshd\.exe$') -or ($service -eq "sshd")
    $programAdmits = (-not $program) -or $program -eq "Any" -or ($program -match 'sshd\.exe$')
    $serviceAdmits = (-not $service) -or $service -eq "Any" -or ($service -eq "sshd")

    if (-not ($programAdmits -and $serviceAdmits)) {
        return $null
    }

    if ($boundToSshd) {
        return "allows any local port and is bound to sshd itself"
    }

    "allows any local port and is bound to no program or service that would exclude sshd"
}

function Test-RuleWithinRequestedScope {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Rule,

        [Parameter(Mandatory = $true)]
        [string[]]$RemoteAddress,

        [Parameter(Mandatory = $true)]
        [string[]]$FirewallProfile
    )

    # A rule that reaches sshd is only a problem if it reaches it from somewhere
    # -ClientAddress did not ask for. One already inside the requested scope
    # widens nothing, and failing the run over it would be a refusal the error's
    # own remedy could not clear.
    #
    # Containment is decided by exact membership, not by working out whether one
    # CIDR sits inside another. That is deliberately conservative: this can only
    # ever fail to clear a rule that was in fact harmless, never clear one that
    # was not.
    try {
        $ruleAddresses = @(($Rule | Get-NetFirewallAddressFilter).RemoteAddress)
    } catch {
        return $false
    }

    if ($ruleAddresses.Count -eq 0) {
        return $false
    }

    foreach ($address in $ruleAddresses) {
        if ($RemoteAddress -notcontains "$address") {
            return $false
        }
    }

    $requested = Expand-FirewallProfile -Profile $FirewallProfile
    $ruleProfiles = Expand-FirewallProfile -Profile @("$($Rule.Profile)" -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    foreach ($profileName in $ruleProfiles) {
        if ($requested -notcontains $profileName) {
            return $false
        }
    }

    $true
}

function Get-CompetingSshRule {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Port,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Specific", "Any")]
        [string]$Coverage
    )

    # Windows Firewall allow rules are additive, so the rule the OpenSSH
    # capability installs keeps the port open at its own wider scope no matter
    # how narrow this script's rule is. Match on the port filter rather than on
    # rule names, which are localized and vary by Windows version.
    #
    # Protocol "Any" counts too: a rule that names no protocol carries TCP
    # along with everything else.
    $filters = @(
        Get-NetFirewallPortFilter -All |
            Where-Object {
                ("TCP", "Any") -contains "$($_.Protocol)" -and
                (Get-PortCoverage -LocalPort $_.LocalPort -Port $Port) -eq $Coverage
            }
    )

    if ($filters.Count -eq 0) {
        return
    }

    $filters |
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
        [string[]]$FirewallProfile,

        # Filled in as each rule is narrowed rather than returned at the end,
        # so a failure creating this script's own rule below cannot lose the
        # record of the exceptions already changed.
        # AllowEmptyCollection because a mandatory parameter otherwise refuses
        # an empty one -- which is exactly what the first run passes.
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$AdjustedRule
    )

    # 22 stays in scope even when -Port names another one, because the
    # capability's own exception sits there and would otherwise keep the
    # default port open wider than -ClientAddress says.
    $scopedPorts = @(@($Port, 22) | Select-Object -Unique)

    # A rule whose filter is LocalPort "Any" is reported, not rescoped. It is
    # usually scoped to a program or service instead of a port -- an app's
    # inbound rule, not an ssh hole -- and narrowing every one of them to the
    # ssh client would take the VM's other inbound traffic down with it. Say so
    # and let the operator judge, rather than silently doing either.
    # Exceptions that still reach sshd more widely than -ClientAddress asked
    # for. That is the whole claim this step makes, so any of these is a
    # failure rather than a warning to read past.
    $unnarrowed = @()

    foreach ($rule in Get-CompetingSshRule -Port $scopedPorts -Coverage Any) {
        $reason = Get-SshdReachReason -Rule $rule
        if (-not $reason) {
            Write-Host "  Ignored: '$($rule.DisplayName)' allows any local port but is bound to another program or service, so it cannot reach sshd."
            continue
        }

        if (Test-RuleWithinRequestedScope -Rule $rule -RemoteAddress $RemoteAddress -FirewallProfile $FirewallProfile) {
            Write-Host "  Ignored: '$($rule.DisplayName)' reaches sshd on any local port, but only from within the scope this run asked for."
            continue
        }

        Write-Warning "  Reaches sshd and is not narrowed: '$($rule.DisplayName)' -- $reason"
        $unnarrowed += "$($rule.DisplayName) ($($rule.Name)) -- $reason"
    }

    foreach ($rule in Get-CompetingSshRule -Port $scopedPorts -Coverage Specific) {
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

        # Recorded before the first call that changes anything, not after the
        # last. Narrowing a rule can take two calls -- the address, then the
        # profile or the enabled flag -- and the second throwing with the first
        # applied would otherwise leave the rule changed with its original
        # address written down nowhere. Restoring a rule this loop never got to
        # is a no-op; restoring one it half-changed is the whole point.
        [void]$AdjustedRule.Add([pscustomobject]@{
            Name          = $rule.Name
            RemoteAddress = $priorAddress
            Profile       = $priorProfile
            Enabled       = $priorEnabled
        })

        try {
            Set-NetFirewallRule -Name $rule.Name -RemoteAddress $RemoteAddress

            if ($disableRule) {
                Set-NetFirewallRule -Name $rule.Name -Enabled False
            } elseif ($narrowedProfile) {
                Set-NetFirewallRule -Name $rule.Name -Profile $narrowedProfile
            }
        } catch {
            # Group-policy rules cannot be edited locally. The run stops on
            # this below rather than carrying on to report a scope the rule
            # still overrides.
            Write-Warning "  Could not narrow existing SSH exception '$($rule.DisplayName)': $($_.Exception.Message)"
            $unnarrowed += "$($rule.DisplayName) ($($rule.Name))"
            continue
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

    # Thrown after this script's own rule exists and every narrowing that could
    # be done has been, so the record is complete and -Disable can put it all
    # back. Firewall allow rules are additive: while one of these still names a
    # wider scope, sshd is reachable from outside -ClientAddress no matter how
    # narrow this script's rule is, and reporting "setup ready" over that would
    # be claiming a boundary that is not there.
    if ($unnarrowed.Count -gt 0) {
        throw @"
$($unnarrowed.Count) existing inbound exception(s) still reach sshd more widely than -ClientAddress, so that is not the boundary this run would have reported:
  $($unnarrowed -join "`n  ")
A rule that would not narrow is usually managed by group policy, which cannot be edited on the machine itself. A rule on any local port is not narrowed on purpose -- rescoping it would take this VM's other inbound traffic with it. Either way: narrow or disable them where they are defined and rerun, or rerun with -SkipFirewall if the wider exposure is deliberate.
Nothing after the firewall step was configured. -Disable puts back what this run did change.
"@
    }
}

function Save-EnableState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Mutation,

        # The record as it stood before this run. Passed in rather than read
        # here, because this runs in a finally: a read that threw there would
        # replace whatever exception brought us to it.
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State
    )

    # Only the first run to touch a component sees the machine's original
    # setting for it. A rerun must not overwrite that with a value this script
    # already wrote, or -Disable would restore this script's configuration
    # instead of the machine's.
    $state = $State

    if (-not $state) {
        Save-RemoteMcpState -State ([ordered]@{
            DefaultShell        = $Mutation.DefaultShell
            DefaultShellManaged = $Mutation.DefaultShellManaged
            SshStartType        = $Mutation.SshStartType
            SshWasRunning       = $Mutation.SshWasRunning
            CapabilityInstalled = $Mutation.CapabilityInstalled
            DefaultShellCommandOption = $Mutation.DefaultShellCommandOption
            AuthorizedKeysAcls  = @($Mutation.AuthorizedKeysAcls)
            AdjustedRules       = @($Mutation.AdjustedRules)
            AuthorizedKeys      = @($Mutation.AuthorizedKeys)
        })

        return
    }

    $knownRules = @(@($state.AdjustedRules) | ForEach-Object { $_.Name })
    $knownKeys = @(@($state.AuthorizedKeys) | ForEach-Object { "$($_.Path)|$($_.Key)" })

    # A stored value for a component an earlier run never touched is not an
    # original worth protecting: if that run skipped the default shell, or died
    # before reaching the service, what THIS run found is the machine's own.
    $defaultShell = if ($state.DefaultShellManaged) { $state.DefaultShell } else { $Mutation.DefaultShell }
    $serviceKnown = $null -ne $state.SshStartType

    # The first rebuild of a given file saw the machine's own DACL for it; a
    # later run would only capture what this script already wrote. Per path,
    # because a rerun can rebuild a different file's DACL entirely.
    $knownAclPaths = @(@($state.AuthorizedKeysAcls) | ForEach-Object { $_.Path })

    Save-RemoteMcpState -State ([ordered]@{
        DefaultShell        = $defaultShell
        DefaultShellManaged = ([bool]$state.DefaultShellManaged -or $Mutation.DefaultShellManaged)
        SshStartType        = $(if ($serviceKnown) { $state.SshStartType } else { $Mutation.SshStartType })
        SshWasRunning       = $(if ($serviceKnown) { $state.SshWasRunning } else { $Mutation.SshWasRunning })
        CapabilityInstalled = ([bool]$state.CapabilityInstalled -or $Mutation.CapabilityInstalled)
        DefaultShellCommandOption = $(if ($state.DefaultShellManaged) { $state.DefaultShellCommandOption } else { $Mutation.DefaultShellCommandOption })
        AuthorizedKeysAcls  = @(@($state.AuthorizedKeysAcls) + @($Mutation.AuthorizedKeysAcls | Where-Object { $knownAclPaths -notcontains $_.Path }))
        AdjustedRules       = @(@($state.AdjustedRules) + @($Mutation.AdjustedRules | Where-Object { $knownRules -notcontains $_.Name }))
        AuthorizedKeys      = @(@($state.AuthorizedKeys) + @($Mutation.AuthorizedKeys | Where-Object { $knownKeys -notcontains "$($_.Path)|$($_.Key)" }))
    })
}

function Disable-RemoteMcpFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State,

        # Rule records this run could not restore. What stays here is what a
        # later -Disable still has to do; anything restored is dropped, so it
        # is never re-applied over a scope someone set in the meantime.
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Remaining
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
            $script:UnfinishedRestore += "firewall rule $($record.Name)"
            [void]$Remaining.Add($record)
        }
    }
}

function Restore-AuthorizedKeysAcl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record
    )

    if (-not (Test-Path $Record.Path)) {
        Write-Host "  Authorized keys file already gone; ACL not restored: $($Record.Path)"
        return
    }

    # Only the DACL, which is the only part the rebuild replaced.
    $acl = Get-Acl -Path $Record.Path
    $acl.SetSecurityDescriptorSddlForm($Record.Sddl, [System.Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -Path $Record.Path -AclObject $acl

    Write-Host "  ACL restored on $($Record.Path)"
}

function Restore-SshService {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [object]$Remaining
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
            # No -ErrorAction SilentlyContinue: a suppressed failure here would
            # print "stopped" over a service still running, skip the catch
            # below, and let the state file be deleted with no record to retry
            # from. Stopping an already-stopped service is not an error.
            Stop-Service -Name sshd -Force
            Write-Host "  sshd stopped; startup type $startType."
        } else {
            Write-Host "  sshd left running; startup type restored to $startType."
        }
    } catch {
        Write-Warning "  Could not restore the sshd service: $($_.Exception.Message)"
        $script:UnfinishedRestore += "the sshd service"
        $Remaining.SshStartType = $State.SshStartType
        $Remaining.SshWasRunning = $State.SshWasRunning
        $Remaining.CapabilityInstalled = $State.CapabilityInstalled
    }
}

function ConvertTo-PosixSingleQuoted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # A POSIX single-quoted string can hold anything except a single quote, so
    # every quote is closed, escaped and reopened: ' becomes '\''. Windows
    # paths cannot contain a double quote, so nothing else needs escaping.
    "'" + $Value.Replace("'", "'\''") + "'"
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

    # Unreadable is not the same as absent here either: this run cannot restore
    # what it cannot read, so it removes only its own rule and keeps the file
    # for a later attempt rather than reporting there was nothing to put back.
    $stateUnreadable = $false
    $state = $null
    try {
        $state = Get-RemoteMcpState
    } catch {
        $stateUnreadable = $true
        Write-Warning $_.Exception.Message
    }

    # What this run leaves undone, in the shape of the record itself. A
    # component that WAS put back is dropped rather than carried, so a retry
    # only retries what is outstanding: keeping a restored component would let
    # a later -Disable re-apply the value from before the first enable over
    # whatever was configured in the meantime.
    $remaining = [ordered]@{
        DefaultShell              = $null
        DefaultShellManaged       = $false
        DefaultShellCommandOption = $null
        SshStartType              = $null
        SshWasRunning             = $null
        CapabilityInstalled       = $false
        AuthorizedKeysAcls        = New-Object System.Collections.ArrayList
        AdjustedRules             = New-Object System.Collections.ArrayList
        AuthorizedKeys            = New-Object System.Collections.ArrayList
    }

    Write-Host "Closing remote MCP access:"

    if ($SkipFirewall) {
        Write-Host "  Skipped firewall changes (-SkipFirewall specified)."
        $script:UnfinishedRestore += "the firewall (-SkipFirewall)"
        foreach ($record in @(@($state.AdjustedRules) | Where-Object { $_ })) {
            [void]$remaining.AdjustedRules.Add($record)
        }
    } else {
        Disable-RemoteMcpFirewall -State $state -Remaining $remaining.AdjustedRules
    }

    if ($SkipDefaultShell) {
        Write-Host "  Skipped default shell (-SkipDefaultShell specified)."
        $script:UnfinishedRestore += "the default shell (-SkipDefaultShell)"
        if ($state) {
            $remaining.DefaultShell = $state.DefaultShell
            $remaining.DefaultShellManaged = [bool]$state.DefaultShellManaged
            $remaining.DefaultShellCommandOption = $state.DefaultShellCommandOption
        }
    } elseif (-not $state) {
        Write-Host "  No saved state; default shell left alone."
    } elseif (-not $state.DefaultShellManaged) {
        # This script never wrote the value, so there is no evidence it owns
        # the one that is there now. Deleting it would silently undo a shell
        # configured independently.
        Write-Host "  Default shell was not set by this script; left alone."
    } else {
        try {
            Restore-SshDefaultShell -Value $state.DefaultShell -CommandOption $state.DefaultShellCommandOption
        } catch {
            Write-Warning "  Could not restore the default shell: $($_.Exception.Message)"
            $script:UnfinishedRestore += "the default shell"
            $remaining.DefaultShell = $state.DefaultShell
            $remaining.DefaultShellManaged = $true
            $remaining.DefaultShellCommandOption = $state.DefaultShellCommandOption
        }
    }

    # Files still holding a managed key after this step. Their ACLs stay
    # tightened: see below.
    $keysOutstanding = @()

    if ($SkipKeys) {
        Write-Host "  Left installed keys in place (-SkipKeys specified)."
        $script:UnfinishedRestore += "the installed keys (-SkipKeys)"
        foreach ($record in @(@($state.AuthorizedKeys) | Where-Object { $_ })) {
            [void]$remaining.AuthorizedKeys.Add($record)
        }
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
                $script:UnfinishedRestore += "key in $($record.Path)"
                [void]$remaining.AuthorizedKeys.Add($record)
                $keysOutstanding += $record.Path
            }
        }
    } else {
        Write-Host "  No saved state; authorized keys left alone."
    }

    # After the keys, not before: removing them needs the write access this is
    # about to give away.
    if ($SkipKeys) {
        # The keys are still in the files, so the ACLs that protect them stay.
        foreach ($record in @(@($state.AuthorizedKeysAcls) | Where-Object { $_ })) {
            [void]$remaining.AuthorizedKeysAcls.Add($record)
        }
    } elseif ($state) {
        foreach ($record in @(@($state.AuthorizedKeysAcls) | Where-Object { $_ })) {
            # Only for a file whose managed key is actually gone. Handing back
            # a DACL that let another principal write, while a login key this
            # script installed is still in the file, would leave that principal
            # able to edit live credentials -- so the tightened ACL stays until
            # the key it protects has been removed.
            if ($keysOutstanding -contains $record.Path) {
                Write-Host "  ACL left tightened on $($record.Path); the key in it is still installed."
                $script:UnfinishedRestore += "the ACL on $($record.Path)"
                [void]$remaining.AuthorizedKeysAcls.Add($record)
                continue
            }

            try {
                Restore-AuthorizedKeysAcl -Record $record
            } catch {
                Write-Warning "  Could not restore the ACL on '$($record.Path)': $($_.Exception.Message)"
                $script:UnfinishedRestore += "the ACL on $($record.Path)"
                [void]$remaining.AuthorizedKeysAcls.Add($record)
            }
        }
    }

    Restore-SshService -State $state -Remaining $remaining

    if ($stateUnreadable) {
        Write-Host ""
        Write-Warning "Kept $StatePath -- it could not be read, so nothing recorded in it was put back. Only this script's own firewall rule was removed."
    } elseif ($state) {
        # What is still changed is the only thing worth keeping, and a failure
        # here is usually transient -- a group-policy rule, a service
        # mid-transition. Write back just that, so a later -Disable picks up
        # where this one stopped without re-applying anything already restored.
        $stillChanged = (
            $remaining.DefaultShellManaged -or
            $null -ne $remaining.SshStartType -or
            @($remaining.AdjustedRules).Count -gt 0 -or
            @($remaining.AuthorizedKeys).Count -gt 0 -or
            @($remaining.AuthorizedKeysAcls).Count -gt 0
        )

        if ($stillChanged) {
            $remaining.AuthorizedKeysAcls = @($remaining.AuthorizedKeysAcls)
            $remaining.AdjustedRules = @($remaining.AdjustedRules)
            $remaining.AuthorizedKeys = @($remaining.AuthorizedKeys)

            Write-Host ""
            try {
                Save-RemoteMcpState -State $remaining
                Write-Warning "Kept $StatePath -- not put back: $($script:UnfinishedRestore -join '; '). Rerun -Disable once the cause is fixed; what it already restored has been dropped from the record."
            } catch {
                # The writer leaves the previous file intact when it cannot
                # swap in the new one -- which is right for the record, but
                # that file still lists components this run has already put
                # back, and a later -Disable reading it would treat them as
                # outstanding. Say so rather than let that be discovered later.
                Write-Warning "Could not write the reduced record to $StatePath ($($_.Exception.Message))."
                Write-Warning "$StatePath still describes the state before this run and now over-describes it: it lists components this run already restored. Rerunning -Disable against it would try to put those back a second time. Not put back this run: $($script:UnfinishedRestore -join '; '). Reconcile or remove that file before rerunning."
            }
        } else {
            Remove-Item -Path $StatePath -Force
        }
    }

    Write-Host ""
    Write-Host "Remote MCP access closed. The OpenSSH Server capability and its host keys were left installed."
    exit 0
}

if ($FirewallProfile -contains "Any" -and $FirewallProfile.Count -gt 1) {
    throw "Use -FirewallProfile Any by itself, or choose one or more of Domain, Private, Public."
}

# Read before anything is changed. Get-RemoteMcpState throws on a record it
# cannot parse, and this is where that has to happen: from inside the run it
# would abort with the machine already half configured.
$existingState = Get-RemoteMcpState

$resolvedKey = Resolve-PublicKey -Key $PublicKey -Path $PublicKeyPath

if ($ServerCommand -and -not (Test-Path $ServerCommand)) {
    Write-Warning "No file at -ServerCommand '$ServerCommand'. The client registration below is printed anyway; copy the server in before using it."
}

# Resolved before anything is changed. Both of these throw on an account that
# does not exist or has never signed in, and doing that after sshd, the
# firewall and the default shell had been altered would leave a machine this
# script had changed with nothing recorded to change back.
$userSid = Get-UserSid -Name $User

# sshd ignores ~/.ssh/authorized_keys for a member of the Administrators group
# and reads the ProgramData file instead -- which it will be on a VM used for
# kernel debugging.
if ($AuthorizedKeysFile -eq "Auto") {
    $membership = Test-UserIsAdministrator -Name $User -Sid $userSid

    if ($membership.Result -eq "Unknown") {
        # Neither answer is safe to guess here. The key in the wrong file fails
        # every login; the administrators file for a non-administrator would on
        # top of that authorize a login this script was never asked to grant.
        # So say what could not be read and let the caller settle it.
        throw @"
Could not tell whether '$User' is an administrator, so which file sshd will read is unknown.
These groups in the Administrators chain could not be expanded (a domain group is the usual reason):
  $($membership.Unresolved -join "`n  ")
Rerun naming the file yourself:
  -AuthorizedKeysFile Administrators   for an account in the Administrators group
                                       ($AdministratorsKeyFile)
  -AuthorizedKeysFile PerUser          for a standard account
                                       (its own .ssh\authorized_keys)
"@
    }

    $userIsAdministrator = ($membership.Result -eq "Yes")
} else {
    $userIsAdministrator = ($AuthorizedKeysFile -eq "Administrators")
}

$authorizedKeysPath = if ($userIsAdministrator) {
    $AdministratorsKeyFile
} else {
    Join-Path (Get-UserProfilePath -Name $User -Sid $userSid) ".ssh\authorized_keys"
}

if (-not $PSCmdlet.ShouldProcess("OpenSSH server", "Open remote MCP access over ssh")) {
    Write-Host "Remote MCP setup was not applied."
    exit 0
}

# Filled in step by step below and persisted in the finally, so a run that
# throws half way still leaves -Disable able to put back what it did change.
# Recording nothing would strand the machine: the next enable would capture the
# already-modified firewall scope and default shell as the originals.
$mutation = [ordered]@{
    DefaultShell        = $null
    DefaultShellManaged = $false
    SshStartType        = $null
    SshWasRunning       = $null
    CapabilityInstalled = $false
    DefaultShellCommandOption = $null
    AuthorizedKeysAcls  = New-Object System.Collections.ArrayList
    AdjustedRules       = New-Object System.Collections.ArrayList
    AuthorizedKeys      = New-Object System.Collections.ArrayList
}

$setupFailed = $false

try {
    Write-Host "[1/4] OpenSSH Server:"
    $mutation.CapabilityInstalled = Install-OpenSshServer
    Start-SshService -Mutation $mutation

    Write-Host ""
    Write-Host "[2/4] Firewall:"
    if ($SkipFirewall) {
        Write-Host "  Skipped (-SkipFirewall specified)."
    } else {
        Enable-RemoteMcpFirewall `
            -Port $Port `
            -RemoteAddress $ClientAddress `
            -FirewallProfile $FirewallProfile `
            -AdjustedRule $mutation.AdjustedRules
    }

    Write-Host ""
    Write-Host "[3/4] Default shell:"
    if ($SkipDefaultShell) {
        # Deliberately leaves DefaultShellManaged false: a value this script
        # never wrote is not one -Disable may delete.
        Write-Host "  Skipped (-SkipDefaultShell specified). An MCP transport needs cmd.exe here; PowerShell rewrites the stream."
    } else {
        Set-SshDefaultShell -Mutation $mutation
    }

    Write-Host ""
    Write-Host "[4/4] Authorized key:"
    if (-not $resolvedKey) {
        Write-Host "  No key given (-PublicKey / -PublicKeyPath). sshd will read:"
        Write-Host "    $authorizedKeysPath"
        Write-Host "  Put the client's public key there, then rerun this script so the ACL is set."
    } else {
        $keyDir = Split-Path -Path $authorizedKeysPath -Parent
        if (-not (Test-Path $keyDir)) {
            New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        }

        # Asked before the key is written, since writing it creates the file.
        $keyFileExisted = Test-Path $authorizedKeysPath

        # Recorded before the ACL call, which can throw with the key already on
        # disk -- a key installed and not recorded is one -Disable never removes.
        if (Add-AuthorizedKey -Path $authorizedKeysPath -Key $resolvedKey) {
            [void]$mutation.AuthorizedKeys.Add([pscustomobject]@{ Path = $authorizedKeysPath; Key = $resolvedKey })
        }

        Set-AuthorizedKeysAcl `
            -Path $authorizedKeysPath `
            -IsAdministratorsFile $userIsAdministrator `
            -OwnerSid $userSid `
            -Mutation $mutation `
            -FileExisted $keyFileExisted

        Write-Host "  ACL tightened on $authorizedKeysPath"
    }
} catch {
    $setupFailed = $true
    throw
} finally {
    try {
        Save-EnableState -Mutation $mutation -State $existingState
    } catch {
        if ($setupFailed) {
            # Something already went wrong and is on its way up; replacing that
            # exception with this one would hide the cause.
            Write-Warning "Could not record what this run changed to $StatePath ($($_.Exception.Message)); -Disable will not be able to put it back."
        } else {
            # The machine was changed and the record was not written. Saying
            # "setup ready" here and exiting 0 would report a success that
            # cannot be undone, so this run fails on it.
            throw "Setup was applied but could not be recorded to $StatePath ($($_.Exception.Message)). -Disable cannot put back what it cannot read, so fix that path and rerun -- every step is idempotent."
        }
    }
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

# @() because the pipeline unrolls a one-element array into a bare string, and
# indexing a string picks a character: a VM with a single NIC -- the ordinary
# case -- would print "HostName 1" for 172.20.1.5.
$vmAddresses = @(Get-VMIPv4Address)
if ($vmAddresses.Count -gt 0) {
    Write-Host "  This VM:         $($vmAddresses -join ', ')"
}

if (-not (Test-PortListening -Port $Port)) {
    Write-Warning "  Nothing is listening on port $Port. This script does not edit sshd_config, so a non-default port needs a 'Port $Port' line in $SshProgramData\sshd_config followed by 'Restart-Service sshd'."
}

$sshHostName = if ($vmAddresses.Count -gt 0) { $vmAddresses[0] } else { "<vm-address>" }
# Quoted twice on purpose, and by different rules. ssh joins its remaining
# arguments into ONE string and hands that to the remote shell, so the client
# shell's own quotes are gone by then -- a path with a space would reach
# cmd.exe bare and run only the part before the first space. The inner double
# quotes are what survives the trip; the outer single quotes are what gets it
# past the client shell in one piece, and they are applied by the escaper
# rather than written into the text, because a path containing an apostrophe
# (C:\Users\O'Brien\...) would otherwise close them early and break the line
# before ssh ever ran.
$remoteCommand = if ($ServerCommand) { $ServerCommand } else { "<path-to-mcp-server.exe>" }
$remoteCommandArg = ConvertTo-PosixSingleQuoted -Value ('"' + $remoteCommand + '"')
$portLine = if ($Port -ne 22) { "`n      Port $Port" } else { "" }
$probeJson = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'

Write-Host ""
Write-Host @"
On the client, give this VM a stable name in ~/.ssh/config:

  Host $SshHostAlias
      HostName $sshHostName
      User $User$portLine
      IdentityFile "$ClientIdentityFile"
      RequestTTY no
      BatchMode yes
      ServerAliveInterval 30
      ServerAliveCountMax 6

RequestTTY no is load-bearing: a PTY would apply echo and line discipline to the
transport. BatchMode yes makes a missing key fail at once instead of hanging on a
prompt no one will see, because an MCP client's stdin belongs to the protocol.

Prove the handshake before registering anything:

  printf '%s\n' '$probeJson' \
      | ssh -T $SshHostAlias $remoteCommandArg | cat -vet | head -3

One line of JSON on stdout carrying serverInfo, and no ^M anywhere, is the pass.
A ^M, a shell banner, or a blank first line means the default shell is
interfering; rerun this script without -SkipDefaultShell. Nothing downstream
works if this does not, and the failure there is an unreadable parse error that
names no cause.

Register it -- local scope, because an address, a user name and an absolute path
are machine-specific and do not belong in a repository's .mcp.json:

  claude mcp add $SshHostAlias --scope local -- ssh -T $SshHostAlias $remoteCommandArg

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
