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

# Stamped into the record. There is no version 1 in the wild -- this script has
# not shipped -- so nothing reads an older shape; the field is here so that a
# later change to it has somewhere to branch on.
$StateVersion = 2

# The key types sshd accepts on an authorized_keys line. One list, used both to
# validate what is handed in and to find the type within a line that may open
# with options -- two copies would drift, and a type missing from the second
# copy is a key -Disable cannot find.
$KeyTypePattern = "(?:ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)"
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

# Set only where a restore or a write actually failed -- not where a -Skip
# switch deliberately held one back. It decides this run's exit status, so
# automation can tell "closed" from "could not finish closing".
$script:RestoreFailed = $false

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


# ---------------------------------------------------------------------------
# The change ledger
# ---------------------------------------------------------------------------
#
# Every change this script makes to the machine is one entry here, and the same
# four rules apply to all of them. They were previously written out once per
# component -- the default shell, the sshd service, each competing firewall
# rule, each authorized-keys file and its DACL -- each with its own record
# shape and its own comparison code. That is what fifteen rounds of review
# found: not one broken rule, but the same rule missing from whichever
# component nobody had written it into yet. Adding a component meant
# reimplementing all four, and forgetting one was silent.
#
#   1. Record before mutating. A change made and not written down is one
#      -Disable can never put back.
#   2. Track what was applied, not what was planned. Applied starts equal to
#      Original and advances only as each individual write returns, so it
#      always describes the machine as this script actually left it -- however
#      far through a multi-field change it got.
#   3. Verify before reverting. Restore a field only where the machine still
#      holds the value this script wrote. Anything else belongs to whoever
#      changed it since; putting an original back over their value would undo
#      a deliberate decision, and for the firewall and the service that means
#      handing out access at the moment this script is taking its own away.
#   4. Drop what is restored, keep what is not. The record left behind is
#      exactly the work still outstanding, so a later -Disable resumes rather
#      than re-applying.
#
# A change is a value per field rather than a single value, because rules 2
# and 3 are per field: narrowing a firewall rule is an address write and a
# profile write, either of which can fail on its own.
#
#   Kind      selects the adapter that reads and writes this sort of thing
#   Id        which one (a rule name, a file path, a fixed name for singletons)
#   Scope     what it belongs to, for ordering; a file path, or $null
#   Original  the machine's own values, restored by -Disable
#   Applied   what this script last successfully wrote
#
# Restore order is by Kind, and within a Scope the lower Order goes first.
# That one rule produces the orderings that were previously special cases: a
# key comes out before the file's terminator, and both before the DACL that
# protects them -- because removing a key needs the write access the DACL
# restore gives away.
#
# The order is also the order a run that is CLOSING access has to work in.
# Everything that takes access away goes first, and everything that hands
# somebody else's broader configuration back goes last -- otherwise -Disable
# widens the firewall to the machine's original scope while the key it
# installed is still in the file and sshd is still listening, which is a few
# seconds of the machine being more open than at any point while remote access
# was deliberately on.
#
# The cost, worth knowing: sshd stops first, so a -Disable run OVER the very
# ssh access it is closing loses its session part way through. That is not the
# way this script is meant to be run -- it lives on the guest and is run there
# -- and the record it leaves is safe to retry, since a field already restored
# equals its Original and is skipped.
# Stands in for a field name when the thing a change describes no longer
# exists at all. Bracketed so it can never collide with one.
$ChangeGone = "(gone)"

$ChangeOrder = [ordered]@{
    SshService        = 10
    AuthorizedKey     = 20
    KeyFileTerminator = 30
    AuthorizedKeysAcl = 40
    DefaultShell      = 50
    FirewallRule      = 60
}

function New-ManagedChange {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$Ledger,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Id,

        # IDictionary, not hashtable: a [hashtable] parameter CONVERTS an
        # ordered dictionary passed to it into an unordered one, and the field
        # order is the order the fields are restored in. Typing this loosely
        # made restore order depend on hash bucketing.
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Original,

        [AllowNull()]
        [string]$Scope = $null,

        # What the change will be called in the run's output. The adapters
        # deal in field names; a person reading a -Disable wants the rule's
        # display name or the file's path.
        [AllowNull()]
        [string]$Label = $null
    )

    # Applied starts at Original: nothing has been written yet, so as far as
    # this record is concerned the machine still holds its own values. Each
    # write that returns advances one field. Registering first and advancing
    # after is what keeps rule 1 and rule 2 from pulling against each other --
    # the entry exists before anything changes, and never claims more than
    # actually happened.
    $change = [pscustomobject]@{
        Kind     = $Kind
        Id       = $Id
        Scope    = $Scope
        Label    = $(if ($Label) { $Label } else { $Id })
        Original = [ordered]@{}
        Applied  = [ordered]@{}
    }

    foreach ($field in $Original.Keys) {
        $change.Original[$field] = $Original[$field]
        $change.Applied[$field] = $Original[$field]
    }

    [void]$Ledger.Add($change)
    $change
}

function Set-ChangeApplied {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Change,

        [Parameter(Mandatory = $true)]
        [string]$Field,

        [AllowNull()]
        [object]$Value
    )

    $Change.Applied[$Field] = $Value
}

function Test-ChangeValueEqual {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)

    # Compared as the adapters produce them: a scalar or a list of strings.
    # Order does not matter for a firewall rule's addresses or profiles, and
    # a scalar is compared as text so "True" from a CIM property and $true
    # from a record that has been through JSON are the same answer.
    $l = @($Left  | Where-Object { $null -ne $_ })
    $r = @($Right | Where-Object { $null -ne $_ })

    if ($l.Count -ne $r.Count) {
        return $false
    }
    if ($l.Count -eq 0) {
        return $true
    }
    if ($l.Count -eq 1) {
        return "$($l[0])" -eq "$($r[0])"
    }

    @(Compare-Object -ReferenceObject @($l | ForEach-Object { "$_" }) `
                     -DifferenceObject @($r | ForEach-Object { "$_" })).Count -eq 0
}

function Get-ChangeAdapter {
    param([Parameter(Mandatory = $true)][string]$Kind)

    if (-not $ChangeAdapters.Contains($Kind)) {
        throw "No adapter for change kind '$Kind'. This is a bug in this script: a change was recorded that nothing knows how to read back or restore."
    }

    $ChangeAdapters[$Kind]
}

function Get-ChangeDrift {
    param([Parameter(Mandatory = $true)][object]$Change)

    # Which fields the machine no longer holds as this script left them. An
    # empty list means the change is still this script's to undo; anything in
    # it belongs to whoever wrote it.
    #
    # A record from a run that predates a field cannot be checked against it,
    # so a field missing from Applied is not drift.
    $adapter = Get-ChangeAdapter -Kind $Change.Kind
    $live = & $adapter.Read $Change.Id

    if ($null -eq $live) {
        # The thing itself is gone -- a deleted rule, a removed file. There is
        # nothing to put back and recreating it is not this script's business.
        # Deliberately not a field name: the caller treats it as the whole
        # change having moved on, never as one field of it.
        return @($ChangeGone)
    }

    $drift = @()
    foreach ($field in @($Change.Applied.Keys)) {
        if (-not $live.Contains($field)) {
            continue
        }
        if (-not (Test-ChangeValueEqual -Left $live[$field] -Right $Change.Applied[$field])) {
            $drift += $field
        }
    }

    $drift
}

function Restore-ManagedChange {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Change,

        # The fields this script still owns. Anything not named here has been
        # changed by somebody else since and is left to them.
        #
        # Not $Field: PowerShell variable names are case-insensitive, so a
        # parameter by that name is clobbered by the $field loop variable
        # below on the first iteration.
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Owned
    )

    # Field by field, advancing Applied as each write returns. A write that
    # throws leaves the entry describing exactly how far this got, so the
    # -Disable that retries compares against that rather than against work it
    # has already done -- which is rule 2 doing the job it exists for on the
    # way back out as well as the way in.
    $adapter = Get-ChangeAdapter -Kind $Change.Kind

    foreach ($field in @($Change.Original.Keys)) {
        if ($Owned -notcontains $field) {
            continue
        }
        if (Test-ChangeValueEqual -Left $Change.Applied[$field] -Right $Change.Original[$field]) {
            continue
        }

        & $adapter.Write $Change.Id $field $Change.Original[$field]
        Set-ChangeApplied -Change $Change -Field $field -Value $Change.Original[$field]
    }
}

function Merge-ChangeLedger {
    param(
        [AllowNull()][object]$Stored,
        [AllowNull()][object]$Applied
    )

    # One rule for every kind of change, which is the whole point of the
    # ledger: the ORIGINAL belongs to the first run that touched a thing --
    # that is the machine's own value, and the only one worth protecting --
    # while APPLIED belongs to the latest run, because that is what the thing
    # looks like now. Getting this wrong in either direction was found four
    # separate times while each component kept its own copy of it: a rerun
    # that overwrote an original restored this script's configuration instead
    # of the machine's, and one that kept a stale applied value made -Disable
    # read its own second pass as somebody else's edit.
    $merged = @()
    $seen = @{}

    foreach ($entry in @(@($Stored) | Where-Object { $_ })) {
        $key = "$($entry.Kind)|$($entry.Id)"
        $latest = @(@($Applied) | Where-Object { $_ -and "$($_.Kind)|$($_.Id)" -eq $key }) |
            Select-Object -First 1

        if ($latest) {
            # Field by field, never wholesale. A rerun's Applied map carries a
            # value for EVERY field, including ones it only looked at --
            # Applied starts equal to Original. Copying the lot would write an
            # administrator's change into the record as this script's own work,
            # and then rule 3 finds no drift and puts the pre-enable value back
            # over it. For a firewall profile that means re-widening a rule
            # somebody deliberately tightened, in the run that is supposed to
            # be closing access.
            #
            # A field the rerun actually WROTE is one whose latest Applied
            # differs from its latest Original, because Applied only ever
            # advances on a write that returned. A field it merely observed
            # keeps whatever the earlier run recorded, so drift against that
            # earlier value is still detected.
            foreach ($field in @($latest.Applied.Keys)) {
                if (-not $entry.Applied.Contains($field)) {
                    $entry.Applied[$field] = $latest.Applied[$field]
                    continue
                }

                if (-not (Test-ChangeValueEqual -Left $latest.Applied[$field] -Right $latest.Original[$field])) {
                    $entry.Applied[$field] = $latest.Applied[$field]
                }
            }
        }

        $merged += $entry
        $seen[$key] = $true
    }

    foreach ($entry in @(@($Applied) | Where-Object { $_ })) {
        if (-not $seen.ContainsKey("$($entry.Kind)|$($entry.Id)")) {
            $merged += $entry
        }
    }

    $merged
}

function ConvertTo-ChangeLedger {
    param([AllowNull()][object]$Entries)

    # JSON gives back PSCustomObjects where the ledger wants indexable field
    # maps. Rehydrated once on the way in rather than guarded at every use.
    $ledger = New-Object System.Collections.ArrayList

    foreach ($entry in @(@($Entries) | Where-Object { $_ })) {
        $original = [ordered]@{}
        $applied = [ordered]@{}

        foreach ($field in @($entry.Original.PSObject.Properties)) {
            $original[$field.Name] = $field.Value
        }
        foreach ($field in @($entry.Applied.PSObject.Properties)) {
            $applied[$field.Name] = $field.Value
        }

        [void]$ledger.Add([pscustomobject]@{
            Kind     = "$($entry.Kind)"
            Id       = "$($entry.Id)"
            Scope    = $(if ($entry.Scope) { "$($entry.Scope)" } else { $null })
            Label    = $(if ($entry.Label) { "$($entry.Label)" } else { "$($entry.Id)" })
            Original = $original
            Applied  = $applied
        })
    }

    $ledger
}

function Get-OrderedChanges {
    param(
        [AllowNull()][object]$Ledger
    )

    # Restore order. Unknown kinds sort last rather than throwing here; the
    # adapter lookup is where that is reported, with the entry in hand.
    @(@($Ledger) | Where-Object { $_ } | Sort-Object `
        @{ Expression = { $(if ($ChangeOrder.Contains("$($_.Kind)")) { $ChangeOrder["$($_.Kind)"] } else { 999 }) } }, `
        @{ Expression = { "$($_.Id)" } })
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

    if ($line -notmatch "^$KeyTypePattern\s+\S+") {
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
    $alreadyRecorded = @($Mutation.Changes | Where-Object { $_.Kind -eq "AuthorizedKeysAcl" -and $_.Id -eq $Path }).Count -gt 0
    $change = $null

    if ($FileExisted -and -not $alreadyRecorded) {
        $change = New-ManagedChange -Ledger $Mutation.Changes -Kind AuthorizedKeysAcl -Id $Path -Scope $Path -Label "the ACL on $Path" -Original ([ordered]@{
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

    # After the write, so the entry never claims a DACL that was not replaced.
    if ($change) {
        Set-ChangeApplied -Change $change -Field Sddl -Value $acl.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access)
    }
}

function Get-AuthorizedKeyIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    # sshd authenticates on the key type and the base64 blob. The rest of the
    # line is a comment it does not read, so two lines differing only there are
    # the same credential -- and comparing whole lines would let an edited
    # comment hide a key this script installed from its own removal.
    #
    # The type is not necessarily the first field. An authorized_keys line may
    # open with options -- `restrict`, `from="10.0.0.1"`, `command="..."` --
    # which sshd applies to a key it still accepts. So the type is found rather
    # than assumed: an operator hardening this script's own entry with `restrict`
    # must not make it unrecognisable to -Disable, which would report a live
    # credential removed.
    $fields = @("$Line".Trim() -split "\s+" | Where-Object { $_ })

    for ($i = 0; $i -lt $fields.Count - 1; $i++) {
        # Both halves have to look right. An option value can hold anything in
        # quotes, `command="ssh-rsa AAAA"` included, so a field spelled like a
        # key type is only taken as one when what follows it is base64 and
        # nothing else -- the quote still attached to the end of a decoy's blob
        # is what rules it out. No length floor: this must accept exactly what
        # Resolve-PublicKey accepts, and two validators of the same thing that
        # disagree are the bug this ledger exists to stop making.
        #
        # A bare `ssh-rsa <base64>` inside a quoted option value would still
        # match. That is an operator's own option text, and the cost is a
        # wrongly computed identity for a line this script did not write.
        if ($fields[$i] -notmatch "^$KeyTypePattern$") {
            continue
        }
        if ($fields[$i + 1] -notmatch "^[A-Za-z0-9+/]+={0,2}$") {
            continue
        }

        return "$($fields[$i]) $($fields[$i + 1])"
    }

    $null
}

function Add-AuthorizedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [object]$Mutation
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

    $identity = Get-AuthorizedKeyIdentity -Line $Key
    if (-not $identity) {
        throw "Does not look like an OpenSSH public key line: $Key"
    }

    foreach ($line in $existing) {
        if ((Get-AuthorizedKeyIdentity -Line $line) -eq $identity) {
            Write-Host "  Key already present in $Path"
            return
        }
    }

    # Added, never rewritten. The file is not this script's to normalise: it
    # can hold other keys, comments, blank lines and non-ASCII in a comment
    # field, and rewriting every line -- which trimming and re-encoding amounts
    # to -- would destroy content nothing here records for -Disable to restore.
    # So the existing bytes are carried across untouched and the new line is
    # put after them.
    #
    # UTF-8 without a BOM: Windows PowerShell's -Encoding UTF8 emits one, which
    # on a new file would sit in front of the first key and stop sshd reading
    # it, and its default redirection encoding is UTF-16, which sshd cannot
    # read at all.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Assigned in two steps on purpose: an empty array coming out of an `if`
    # expression is unrolled to nothing, which leaves $null rather than a
    # zero-length byte[], and Array::Copy will not take that.
    $existingBytes = [byte[]]@()
    if (Test-Path $Path) {
        $existingBytes = [System.IO.File]::ReadAllBytes($Path)
    }

    # A file whose last line has no newline would otherwise get this key glued
    # onto the end of it. Checked as bytes, so no encoding guess is involved.
    $separator = ""
    if ($existingBytes.Length -gt 0 -and $existingBytes[$existingBytes.Length - 1] -ne 10) {
        $separator = [Environment]::NewLine
    }

    # Recorded before the write, so a key sshd would accept can never exist
    # without an entry saying so. Two entries where a terminator has to go in:
    # the key, and the file's ending. They are separate because they come back
    # out at different times -- see the KeyFileTerminator adapter.
    $keyChange = New-ManagedChange -Ledger $Mutation.Changes -Kind AuthorizedKey `
        -Id "$Path|$identity" -Scope $Path -Label "the key in $Path" `
        -Original ([ordered]@{ Present = "False" })

    $terminatorChange = $null
    if ($separator) {
        $alreadyRecorded = @($Mutation.Changes | Where-Object { $_.Kind -eq "KeyFileTerminator" -and $_.Id -eq $Path }).Count -gt 0
        if (-not $alreadyRecorded) {
            $terminatorChange = New-ManagedChange -Ledger $Mutation.Changes -Kind KeyFileTerminator `
                -Id $Path -Scope $Path -Label "the end of $Path" `
                -Original ([ordered]@{ Terminated = "False" })
        }
    }

    # Swapped in rather than appended in place. An append that failed part way
    # could leave a complete, working key line in the file while throwing --
    # and a key sshd accepts that this run never got to record is one -Disable
    # will never remove. Either the whole line is there and recorded, or
    # neither.
    $addition = $utf8NoBom.GetBytes($separator + $Key + [Environment]::NewLine)
    $combined = New-Object byte[] ($existingBytes.Length + $addition.Length)
    [System.Array]::Copy($existingBytes, 0, $combined, 0, $existingBytes.Length)
    [System.Array]::Copy($addition, 0, $combined, $existingBytes.Length, $addition.Length)

    Set-FileContentAtomically -Path $Path -Bytes $combined
    Write-Host "  Key added to $Path"

    Set-ChangeApplied -Change $keyChange -Field Present -Value "True"
    if ($terminatorChange) {
        Set-ChangeApplied -Change $terminatorChange -Field Terminated -Value "True"
    }
}

function Remove-AuthorizedKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        # Type plus base64 blob -- what sshd authenticates on, and what the
        # ledger keys this change by.
        [Parameter(Mandatory = $true)]
        [string]$Identity
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
    if (-not $Identity) {
        # Nothing here identifies a key. Matching on a null identity would take
        # out every line that is not a key either -- the comments and blank
        # lines this file is explicitly not allowed to lose.
        throw "No key identity to remove from $Path."
    }

    $identity = $Identity
    $removed = $false
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

            # By identity, not by the whole line: an edited comment must not
            # stop this from finding a key it installed.
            if ((Get-AuthorizedKeyIdentity -Line $utf8NoBom.GetString($line)) -eq $identity) {
                $removed = $true
            } else {
                $kept.Write($bytes, $start, $length)
            }
        }

        $start = $end
    }

    $result = $kept.ToArray()
    $kept.Dispose()

    if (-not $removed) {
        # Not a failure: the ledger has already established that this key is
        # this script's to remove, so finding it gone means somebody got there
        # first. Nothing to write.
        Write-Host "  Key already gone from $Path"
        return
    }

    # Swapped in rather than written over: unrelated keys and comments in this
    # file are not recorded anywhere, so a half-written file would lose them
    # with nothing able to put them back.
    Set-FileContentAtomically -Path $Path -Bytes $result
    Write-Host "  Key removed from $Path"
}

function Remove-AuthorizedKeySeparator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # The terminator an enable run put on this file's previous last line, which
    # had none. It goes back out so the file ends where it did before.
    #
    # A step of its own, run once the file holds no managed key at all, rather
    # than folded into removing the key that recorded it. Two enable runs can
    # append two keys, and only the first records a separator -- so trimming as
    # that first key came out would take the *second* key's terminator with it
    # and leave the separator sitting in the middle of the file. What is at the
    # end of the file is only this run's byte once everything this script put
    # there is gone.
    #
    # If something else has been appended since, the byte removed is that
    # line's terminator instead -- one trailing newline either way, which sshd
    # does not require.
    if (-not (Test-Path $Path)) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes[$bytes.Length - 1] -ne 10) {
        return
    }

    $trim = 1
    if ($bytes.Length -gt 1 -and $bytes[$bytes.Length - 2] -eq 13) {
        $trim = 2
    }

    $shortened = New-Object byte[] ($bytes.Length - $trim)
    [System.Array]::Copy($bytes, 0, $shortened, 0, $shortened.Length)

    Set-FileContentAtomically -Path $Path -Bytes $shortened
    Write-Host "  Restored the end of $Path (the terminator this script added)"
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
    $wasRunning = ($service.Status -eq "Running")

    # Where this run installed the capability, the machine's "own" startup type
    # is the one a fresh install leaves, not the Disabled a missing service
    # reports -- the capability is never removed, because uninstalling it
    # discards the host keys and changes the fingerprint every client has
    # already accepted.
    $originalStartType = if ($Mutation.CapabilityInstalled) { "Manual" } else { $priorStartType }
    $originalRunning = if ($Mutation.CapabilityInstalled) { "False" } else { "$wasRunning" }

    $change = New-ManagedChange -Ledger $Mutation.Changes -Kind SshService -Id sshd -Label "the sshd service" -Original ([ordered]@{
        StartType = $originalStartType
        Running   = $originalRunning
    })

    Set-Service -Name sshd -StartupType Automatic
    Set-ChangeApplied -Change $change -Field StartType -Value "Automatic"

    if (-not $wasRunning) {
        # The first start is also what generates the host keys and creates
        # C:\ProgramData\ssh, which the authorized-keys step below needs.
        Start-Service -Name sshd
        Write-Host "  sshd started; startup type Automatic (was $priorStartType)."
    } else {
        Write-Host "  sshd already running; startup type Automatic (was $priorStartType)."
    }

    Set-ChangeApplied -Change $change -Field Running -Value "True"
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
    $change = New-ManagedChange -Ledger $Mutation.Changes -Kind DefaultShell -Id shell -Label "the default shell" -Original ([ordered]@{
        Shell         = $prior
        CommandOption = $priorOption
    })

    if ($prior -and $prior -ieq $CmdPath) {
        Write-Host "  Already $CmdPath"
    } else {
        Set-OpenSshValue -Name $DefaultShellValueName -Value $CmdPath
        Set-ChangeApplied -Change $change -Field Shell -Value $CmdPath

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
        Set-ChangeApplied -Change $change -Field CommandOption -Value $CmdCommandOption
        Write-Host "  Command option set to $CmdCommandOption (was $priorOption)."
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
        [System.Collections.ArrayList]$Ledger
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
        #
        # That went for the profile but not, until now, for the address: this
        # loop assigned -ClientAddress unconditionally, so a rule already
        # scoped tighter than the request (10.0.0.5 against LocalSubnet) came
        # out WIDER than it went in.
        #
        # The address filter is only written where the result is demonstrably
        # narrower, which can be settled without doing subnet arithmetic:
        #
        #   "Any" alone    the universal set, so the request is narrower
        #   inside request every address already named in -ClientAddress: leave
        #   overlapping    narrow to the overlap, a subset of what it had
        #   otherwise      cannot be compared without guessing at containment
        #
        # The last case is left untouched and reported, because both of the
        # alternatives are worse: widening someone else's rule, or claiming a
        # boundary this script cannot show it enforced.
        $narrowedAddress = $null
        $uncomparableAddress = $false
        $addressWithinRequest = $true

        foreach ($address in $priorAddress) {
            if ($RemoteAddress -notcontains "$address") {
                $addressWithinRequest = $false
                break
            }
        }

        if ($priorAddress.Count -eq 1 -and "$($priorAddress[0])" -eq "Any") {
            $narrowedAddress = $RemoteAddress
        } elseif ($addressWithinRequest) {
            # Already inside the request: nothing to do, and writing the
            # request over it would only add addresses it did not have.
        } else {
            $overlap = @($priorAddress | Where-Object { $RemoteAddress -contains "$_" })
            if ($overlap.Count -gt 0) {
                $narrowedAddress = $overlap
            } else {
                $uncomparableAddress = $true
            }
        }

        if ($uncomparableAddress) {
            Write-Warning "  Left alone, scope not comparable: '$($rule.DisplayName)' is scoped to $($priorAddress -join ', '), which cannot be shown to sit inside $($RemoteAddress -join ', ') without guessing."
            $unnarrowed += "$($rule.DisplayName) ($($rule.Name)) -- scoped to $($priorAddress -join ', '), which this script cannot compare to $($RemoteAddress -join ', ') without guessing at containment"
            continue
        }

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

        # Nothing to do: the rule is already inside what was asked for, on a
        # profile that was asked for, so this run does not touch it -- and must
        # not record it either. A record is a claim of ownership, and -Disable
        # acts on it: an untouched rule that someone later disables would be
        # re-enabled from a value this script never set.
        if (-not $narrowedAddress -and -not $narrowedProfile -and -not $disableRule) {
            Write-Host "  Left as it is, already within the requested scope: $($rule.DisplayName)"
            continue
        }

        # Recorded before the first call that changes anything, not after the
        # last. Narrowing a rule can take two calls -- the address, then the
        # profile or the enabled flag -- and the second throwing with the first
        # applied would otherwise leave the rule changed with its original
        # address written down nowhere.
        # Both halves: what the rule was, and what this run is about to make
        # it. -Disable needs the second to tell whether the rule it finds later
        # is still the one this script left, or something an administrator has
        # since changed -- putting a broad, enabled original back over a rule
        # somebody deliberately tightened would hand out access at the very
        # moment this script is taking its own away.
        $record = New-ManagedChange -Ledger $Ledger -Kind FirewallRule -Id $rule.Name `
            -Label "firewall rule $($rule.DisplayName) ($($rule.Name))" `
            -Original ([ordered]@{
                RemoteAddress = $priorAddress
                Profile       = $priorProfile
                Enabled       = $priorEnabled
            })

        try {
            if ($narrowedAddress) {
                Set-NetFirewallRule -Name $rule.Name -RemoteAddress $narrowedAddress
                Set-ChangeApplied -Change $record -Field RemoteAddress -Value @($narrowedAddress)
            }

            if ($disableRule) {
                Set-NetFirewallRule -Name $rule.Name -Enabled False
                Set-ChangeApplied -Change $record -Field Enabled -Value "False"
            } elseif ($narrowedProfile) {
                Set-NetFirewallRule -Name $rule.Name -Profile $narrowedProfile
                Set-ChangeApplied -Change $record -Field Profile -Value @($narrowedProfile)
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
            $addressNow = if ($narrowedAddress) { $narrowedAddress -join ', ' } else { $priorAddress -join ', ' }
            Write-Host "  Narrowed existing SSH exception: $($rule.DisplayName) (was $($priorAddress -join ', ') on $($priorProfile -join ', '); now $addressNow on $scopeNow)"
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

    # One merge for every kind of change, in Merge-ChangeLedger. What used to
    # be here was that rule written out per component -- a shell clause, a
    # service clause, a rules clause, an ACL clause, a keys clause -- each with
    # its own idea of when a stored value outranks this run's.
    Save-RemoteMcpState -State ([ordered]@{
        Version             = $StateVersion
        CapabilityInstalled = ([bool]$State.CapabilityInstalled -or $Mutation.CapabilityInstalled)
        # Rehydrated first: the merge assigns into Applied field by field, and
        # what comes back from JSON is a PSCustomObject rather than something
        # indexable.
        Changes             = @(Merge-ChangeLedger -Stored (ConvertTo-ChangeLedger -Entries $State.Changes) -Applied $Mutation.Changes)
    })
}

function ConvertTo-SshConfigQuoted {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    # ssh_config splits an unquoted value on whitespace, so every value that
    # could contain a space is emitted quoted. Inside those quotes a backslash
    # escapes the next character, which two things follow from: a value holding
    # a double quote needs it escaped or ssh rejects the line outright
    # ("invalid quotes"), and a value holding a backslash needs it doubled or
    # the character after it is eaten. A client-side identity path is the one
    # that reaches both -- POSIX filenames may contain a double quote, and a
    # Windows-style path is all backslashes.
    #
    # Verified against OpenSSH 9.6: "/tmp/a\"b" resolves to /tmp/a"b, while
    # both "/tmp/a"b" and an unquoted /tmp/a"b are refused at parse time.
    '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
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

# ---------------------------------------------------------------------------
# Change adapters
# ---------------------------------------------------------------------------
#
# All a component supplies: how to read its current values, and how to write
# one of them. The four ownership rules above are the ledger's, so a component
# added later gets them without having to know they exist -- which is the
# whole reason this exists rather than a fifth hand-written restore path.
#
# Read returns a field map, or $null when the thing itself is gone.
# Write takes one field and one value, and is expected to throw on failure.

$ChangeAdapters = @{

    FirewallRule = @{
        Read = {
            param($Id)

            $rule = Get-NetFirewallRule -Name $Id -ErrorAction SilentlyContinue
            if (-not $rule) {
                return $null
            }

            $address = try {
                @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
            } catch {
                # The rule is there but its address filter will not read. Not
                # knowing the scope is not the same as the scope having
                # changed, but it is equally not a basis for writing over it.
                return $null
            }

            [ordered]@{
                RemoteAddress = $address
                Profile       = @("$($rule.Profile)" -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                Enabled       = "$($rule.Enabled)"
            }
        }
        Write = {
            param($Id, $Field, $Value)

            switch ($Field) {
                "RemoteAddress" { Set-NetFirewallRule -Name $Id -RemoteAddress @($Value) }
                "Profile"       { Set-NetFirewallRule -Name $Id -Profile @($Value) }
                "Enabled"       { Set-NetFirewallRule -Name $Id -Enabled "$Value" }
                default         { throw "Unknown firewall rule field '$Field'." }
            }
        }
    }

    DefaultShell = @{
        # All or nothing. The shell and its command option have to agree --
        # sshd runs `<shell> <option> ...`, and cmd.exe wants /c while pwsh
        # wants -Command -- so putting one back over an administrator's other
        # half produces a combination neither party chose and no exec request
        # survives. Every other kind's fields stand alone and are restored
        # one by one.
        Coupled = $true
        Read = {
            param($Id)

            if (-not (Test-Path $OpenSshKeyPath)) {
                return $null
            }

            [ordered]@{
                Shell         = Get-OpenSshValue -Name $DefaultShellValueName
                CommandOption = Get-OpenSshValue -Name $DefaultShellCommandOptionValueName
            }
        }
        Write = {
            param($Id, $Field, $Value)

            switch ($Field) {
                "Shell"         { Set-OpenSshValue -Name $DefaultShellValueName -Value $Value }
                "CommandOption" { Set-OpenSshValue -Name $DefaultShellCommandOptionValueName -Value $Value }
                default         { throw "Unknown default shell field '$Field'." }
            }
        }
    }

    SshService = @{
        Read = {
            param($Id)

            $service = Get-Service -Name $Id -ErrorAction SilentlyContinue
            if (-not $service) {
                return $null
            }

            [ordered]@{
                StartType = "$($service.StartType)"
                Running   = "$($service.Status -eq 'Running')"
            }
        }
        Write = {
            param($Id, $Field, $Value)

            switch ($Field) {
                "StartType" { Set-Service -Name $Id -StartupType "$Value" }
                "Running"   {
                    if ("$Value" -eq "True") {
                        Start-Service -Name $Id
                    } else {
                        # No -ErrorAction SilentlyContinue: a suppressed failure
                        # would report the service stopped while it ran on, and
                        # let the record be dropped with nothing to retry from.
                        # Stopping an already-stopped service is not an error.
                        Stop-Service -Name $Id -Force
                    }
                }
                default     { throw "Unknown sshd service field '$Field'." }
            }
        }
    }

    AuthorizedKey = @{
        # Id is "<path>|<type> <blob>": the file, and the credential sshd
        # actually authenticates on. Not the whole line -- a comment edited by
        # hand afterwards must not hide a key this script installed, which
        # would have -Disable report a live credential removed.
        Read = {
            param($Id)

            $path, $identity = "$Id" -split "\|", 2
            if (-not (Test-Path $path)) {
                return $null
            }

            $present = $false
            foreach ($line in @(Get-Content -Path $path)) {
                if ((Get-AuthorizedKeyIdentity -Line $line) -eq $identity) {
                    $present = $true
                    break
                }
            }

            [ordered]@{ Present = "$present" }
        }
        Write = {
            param($Id, $Field, $Value)

            $path, $identity = "$Id" -split "\|", 2
            if ($Field -ne "Present") {
                throw "Unknown authorized key field '$Field'."
            }
            if ("$Value" -eq "True") {
                throw "This script does not reinstall a key it removed."
            }

            Remove-AuthorizedKey -Path $path -Identity $identity
        }
    }

    KeyFileTerminator = @{
        # A file whose last line had no newline gets one, so the new key does
        # not land on the end of it. That byte is this script's too. It is a
        # change on the FILE rather than on any one key, which is why it is its
        # own entry: two enable runs append two keys and only the first records
        # a terminator, so trimming as that first key came out would take the
        # second key's newline instead. Ordered after every key on the same
        # path, so by the time it runs there is nothing of this script's left
        # in the file.
        Read = {
            param($Id)

            if (-not (Test-Path $Id)) {
                return $null
            }

            $bytes = [System.IO.File]::ReadAllBytes($Id)
            $terminated = $bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -eq 10

            [ordered]@{ Terminated = "$terminated" }
        }
        Write = {
            param($Id, $Field, $Value)

            if ($Field -ne "Terminated") {
                throw "Unknown key file field '$Field'."
            }
            if ("$Value" -eq "True") {
                throw "This script does not add a terminator on the way out."
            }

            Remove-AuthorizedKeySeparator -Path $Id
        }
    }

    AuthorizedKeysAcl = @{
        Read = {
            param($Id)

            if (-not (Test-Path $Id)) {
                return $null
            }

            # Only the DACL, which is the only part the rebuild replaced.
            [ordered]@{
                Sddl = (Get-Acl -Path $Id).GetSecurityDescriptorSddlForm(
                    [System.Security.AccessControl.AccessControlSections]::Access)
            }
        }
        Write = {
            param($Id, $Field, $Value)

            if ($Field -ne "Sddl") {
                throw "Unknown ACL field '$Field'."
            }

            $acl = Get-Acl -Path $Id
            $acl.SetSecurityDescriptorSddlForm("$Value", [System.Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -Path $Id -AclObject $acl
        }
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

    # Unreadable is not the same as absent here either: this run cannot restore
    # what it cannot read, so it removes only its own rule and keeps the file
    # for a later attempt rather than reporting there was nothing to put back.
    $stateUnreadable = $false
    $state = $null
    try {
        $state = Get-RemoteMcpState
    } catch {
        $stateUnreadable = $true
        $script:RestoreFailed = $true
        Write-Warning $_.Exception.Message
    }

    # What this run leaves undone, as ledger entries. A change that WAS put
    # back is dropped rather than carried, so a retry only retries what is
    # outstanding: keeping a restored change would let a later -Disable
    # re-apply the value from before the first enable over whatever was
    # configured in the meantime.
    $remaining = New-Object System.Collections.ArrayList
    $ledger = ConvertTo-ChangeLedger -Entries $(if ($state) { $state.Changes })

    # A -Skip switch holds back a whole kind. Named here rather than checked
    # inside the loop, so adding a kind does not mean finding every place a
    # switch might apply to it.
    $skipped = @{}
    if ($SkipFirewall)     { $skipped["FirewallRule"] = "-SkipFirewall" }
    if ($SkipDefaultShell) { $skipped["DefaultShell"] = "-SkipDefaultShell" }
    if ($SkipKeys)         { $skipped["AuthorizedKey"] = "-SkipKeys"; $skipped["KeyFileTerminator"] = "-SkipKeys" }

    Write-Host "Closing remote MCP access:"

    # This script's own rule is not a ledger entry: nothing else had it, so
    # there is nothing to put back and nothing to compare against.
    if ($SkipFirewall) {
        Write-Host "  Left this script's own firewall rule in place (-SkipFirewall specified)."
    } else {
        $existingRule = Get-NetFirewallRule -Name $SshRuleId -ErrorAction SilentlyContinue
        if ($existingRule) {
            Remove-NetFirewallRule -Name $SshRuleId
            Write-Host "  Firewall rule removed: $SshRuleName"
        } else {
            Write-Host "  Firewall rule not present: $SshRuleName"
        }
    }

    if ($stateUnreadable) {
        # Nothing else can be attempted: the record is the only thing that says
        # what to put back.
        $ledger = New-Object System.Collections.ArrayList
    } elseif (-not $state) {
        Write-Host "  No saved state at $StatePath; removed only this script's own firewall rule."
    } elseif (@($ledger).Count -eq 0) {
        Write-Host "  The record lists nothing outstanding."
    }

    # One loop. Ordered so that a key comes out before the file's terminator,
    # and both before the DACL that protects them -- restoring a DACL needs to
    # happen after the writes that need the access it gives away.
    foreach ($change in Get-OrderedChanges -Ledger $ledger) {
        if ($skipped.ContainsKey("$($change.Kind)")) {
            Write-Host "  Left as it is, $($skipped["$($change.Kind)"]) specified: $($change.Label)"
            $script:UnfinishedRestore += "$($change.Label) ($($skipped["$($change.Kind)"]))"
            [void]$remaining.Add($change)
            continue
        }

        # Anything of this script's on the same file that is still outstanding
        # holds this one back. That is what keeps a DACL tightened while a key
        # it protects is still installed -- handing back write access to live
        # credentials is worse than leaving the ACL alone -- and what keeps the
        # file's terminator until every key is out of it.
        if ($change.Scope) {
            $blocking = @(@($remaining) | Where-Object {
                $_.Scope -eq $change.Scope -and $ChangeOrder["$($_.Kind)"] -lt $ChangeOrder["$($change.Kind)"]
            })

            if ($blocking.Count -gt 0) {
                Write-Host "  Left as it is, $($blocking[0].Label) is still in place: $($change.Label)"
                $script:UnfinishedRestore += $change.Label
                [void]$remaining.Add($change)
                continue
            }
        }

        # Rule 3. Only where the machine still holds what this script wrote.
        # Anything else belongs to whoever changed it since, and is dropped
        # from the record as well as left alone: ownership has moved, so a
        # later run should not keep trying.
        try {
            $drift = Get-ChangeDrift -Change $change
        } catch {
            Write-Warning "  Could not read $($change.Label) to check it ($($_.Exception.Message)); left alone."
            $script:UnfinishedRestore += $change.Label
            $script:RestoreFailed = $true
            [void]$remaining.Add($change)
            continue
        }

        # Ownership is per field, not per change. Treating any drift as
        # ownership of the whole thing moving abandons fields nobody else
        # touched: an administrator setting sshd to Disabled would leave it
        # RUNNING for ever, because this run started it and then declined to
        # stop it. It also strands this script's own narrowing on a firewall
        # rule it has just disowned, with nothing left on record to undo it.
        #
        # A kind whose fields cannot be separated says so, and keeps the older
        # all-or-nothing behaviour.
        # "(gone)" is not a field: the thing itself has been deleted, so there
        # is no field of it to own and nothing to write.
        $coupled = [bool]((Get-ChangeAdapter -Kind $change.Kind).Coupled) -or ($drift -contains $ChangeGone)
        $owned = @(@($change.Original.Keys) | Where-Object { $drift -notcontains $_ })

        if ($drift.Count -gt 0 -and ($coupled -or $owned.Count -eq 0)) {
            Write-Host "  Left alone, changed since this script set it ($($drift -join ', ')): $($change.Label)"
            continue
        }

        # Rule 2 on the way out: Restore-ManagedChange advances Applied as each
        # field is written, so what lands in $remaining after a failure says
        # how far this got rather than where it started.
        try {
            Restore-ManagedChange -Change $change -Owned $owned

            if ($drift.Count -gt 0) {
                Write-Host "  Restored: $($change.Label) -- except $($drift -join ', '), changed since this script set it"
            } else {
                Write-Host "  Restored: $($change.Label)"
            }
        } catch {
            Write-Warning "  Could not restore $($change.Label): $($_.Exception.Message)"
            $script:UnfinishedRestore += $change.Label
            $script:RestoreFailed = $true
            [void]$remaining.Add($change)
        }
    }

    if ($stateUnreadable) {
        Write-Host ""
        Write-Warning "Kept $StatePath -- it could not be read, so nothing recorded in it was put back. Only this script's own firewall rule was removed."
    } elseif ($state) {
        # What is still changed is the only thing worth keeping, and a failure
        # here is usually transient -- a group-policy rule, a service
        # mid-transition. Write back just that, so a later -Disable picks up
        # where this one stopped without re-applying anything already restored.
        $reduced = [ordered]@{
            Version             = $StateVersion
            CapabilityInstalled = [bool]$state.CapabilityInstalled
            Changes             = @($remaining)
        }

        if (@($remaining).Count -gt 0) {
            Write-Host ""
            try {
                Save-RemoteMcpState -State $reduced
                Write-Warning "Kept $StatePath -- not put back: $($script:UnfinishedRestore -join '; '). Rerun -Disable once the cause is fixed; what it already restored has been dropped from the record."
            } catch {
                # The writer leaves the previous file intact when it cannot
                # swap in the new one -- which is right for the record, but
                # that file still lists changes this run has already put back,
                # and a later -Disable reading it would treat them as
                # outstanding. Say so rather than let that be discovered later.
                $script:RestoreFailed = $true
                Write-Warning "Could not write the reduced record to $StatePath ($($_.Exception.Message))."
                Write-Warning "$StatePath still describes the state before this run and now over-describes it: it lists changes this run already restored. Rerunning -Disable against it would try to put those back a second time. Not put back this run: $($script:UnfinishedRestore -join '; '). Reconcile or remove that file before rerunning."
            }
        } else {
            # Everything is back, so the record should go. If it cannot be
            # deleted -- locked, or its directory no longer writable -- leaving
            # the full one behind would tell a later -Disable that all of it is
            # still outstanding, and it would put those values back over
            # whatever has happened since. Empty it instead: a record that
            # claims nothing is one a later run reads and acts on correctly.
            try {
                Remove-Item -Path $StatePath -Force
            } catch {
                Write-Warning "Could not remove $StatePath ($($_.Exception.Message)); emptying it instead so a later -Disable does not act on it."
                try {
                    Save-RemoteMcpState -State $reduced
                    Write-Host "  $StatePath emptied; it records nothing outstanding. Remove it when you can."
                } catch {
                    $script:RestoreFailed = $true
                    Write-Warning "Could not empty $StatePath either ($($_.Exception.Message)). It still describes the state before this run, and a later -Disable reading it would try to restore changes this run already put back. Remove that file by hand."
                }
            }
        }
    }

    Write-Host ""
    if ($script:RestoreFailed) {
        # Not "closed": something this script changed is still in place. Said
        # in the exit status too, so a script driving this can tell the two
        # apart -- a -Skip switch is a choice and does not come through here.
        Write-Warning "Remote MCP access was NOT fully closed. Still in place: $($script:UnfinishedRestore -join '; ')."
        exit 1
    }

    if ($script:UnfinishedRestore.Count -gt 0) {
        Write-Host "Remote MCP access closed except where a -Skip switch held it back: $($script:UnfinishedRestore -join '; ')."
    } else {
        Write-Host "Remote MCP access closed. The OpenSSH Server capability and its host keys were left installed."
    }

    exit 0
}

if ($FirewallProfile -contains "Any" -and $FirewallProfile.Count -gt 1) {
    throw "Use -FirewallProfile Any by itself, or choose one or more of Domain, Private, Public."
}

# ssh will not take a destination containing whitespace -- it answers "hostname
# contains invalid characters" before reading any config -- so no amount of
# quoting in the block below would make such an alias usable. Refuse it here
# rather than print a config naming a host nothing can connect to.
if ($SshHostAlias -match "\s") {
    throw "-SshHostAlias '$SshHostAlias' contains whitespace. ssh refuses a destination with a space in it whatever the quoting, so this alias could never be connected to. Use one without."
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
    # Not a ledger entry: the capability is never uninstalled, because that
    # discards the host keys and changes the fingerprint every client has
    # already accepted. It is here because it decides what the sshd service's
    # "original" startup type is.
    CapabilityInstalled = $false
    Changes             = New-Object System.Collections.ArrayList
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
            -Ledger $mutation.Changes
    }

    Write-Host ""
    Write-Host "[3/4] Default shell:"
    if ($SkipDefaultShell) {
        # Records no change, which is what makes it safe: a value this script
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
        Add-AuthorizedKey -Path $authorizedKeysPath -Key $resolvedKey -Mutation $mutation

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
      HostName $(ConvertTo-SshConfigQuoted -Value $sshHostName)
      User $(ConvertTo-SshConfigQuoted -Value $User)$portLine
      IdentityFile $(ConvertTo-SshConfigQuoted -Value $ClientIdentityFile)
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
