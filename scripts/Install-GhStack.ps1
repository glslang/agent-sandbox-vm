# scripts/Install-GhStack.ps1
# Run INSIDE the VM. Installs (or upgrades) GitHub Stacked PRs -- the `gh stack`
# CLI extension -- and the matching agent skill.
#
#   https://github.github.com/gh-stack/
#
# `Invoke-Provision.ps1` calls this during provisioning, where it is best-effort.
# Run it again by hand to pick up the skill: unlike the extension, `gh skill
# install` reads the repository through the API and needs an authenticated `gh`,
# which a freshly provisioned VM does not have until you run `gh auth login`.
#
#   powershell -ExecutionPolicy RemoteSigned -File C:\Install-GhStack.ps1
#
# Both halves are idempotent, so re-running is always safe.

param(
    # Agents to install the gh-stack skill for. These are `gh skill install
    # --agent` identifiers; the VM ships Claude Code and the Codex CLI, whose
    # user-scope skill directories are ~\.claude\skills and ~\.codex\skills.
    [string[]]$SkillAgents = @("claude-code", "codex"),

    # Install only the skill, or only the extension.
    [switch]$SkipExtension,
    [switch]$SkipSkill
)

$ErrorActionPreference = "Stop"

function Update-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

# Windows PowerShell 5.1 does not turn a native command's non-zero exit into a
# terminating error under $ErrorActionPreference = "Stop", so every `gh` call
# below checks $LASTEXITCODE explicitly.
function Test-GhSubcommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    & gh $Name --help *> $null
    return ($LASTEXITCODE -eq 0)
}

Update-Path
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') was not found on PATH. gh-stack is a gh extension, so install " +
          "the GitHub CLI first (winget install --id GitHub.cli) and re-run this script."
}

# -- 1. The `gh stack` extension --
# `gh extension install` does not require authentication (github/gh-stack is
# public), so this half works on a freshly provisioned VM.
if ($SkipExtension) {
    Write-Host "Skipping the gh-stack extension (-SkipExtension)."
} else {
    Write-Host "Installing the gh-stack extension..."

    # --force upgrades an existing install and is a no-op when the latest
    # version is already present, which makes this safe to re-run.
    gh extension install github/gh-stack --force
    if ($LASTEXITCODE -ne 0) {
        throw "'gh extension install github/gh-stack' failed with exit code $LASTEXITCODE."
    }

    # `gh` registers a hidden stub for `gh stack` that offers to install the
    # extension, so `gh stack --help` succeeding does not by itself prove the
    # extension is present -- check the installed list first.
    $entry = gh extension list 2>$null |
             Select-String -SimpleMatch "github/gh-stack" |
             Select-Object -First 1
    if (-not $entry) {
        throw "gh reported a successful install but github/gh-stack is not in 'gh extension list'."
    }

    # gh-stack ships prebuilt binaries per platform; run it once so an install
    # that picked an unusable binary fails here rather than in an agent session.
    if (-not (Test-GhSubcommand -Name "stack")) {
        throw ("The gh-stack extension is installed but 'gh stack --help' failed with exit code " +
               "$LASTEXITCODE. Check that github/gh-stack publishes a binary for this platform " +
               "($env:PROCESSOR_ARCHITECTURE).")
    }

    Write-Host "  gh-stack extension installed: $($entry.Line.Trim())"
}

# -- 2. The gh-stack agent skill --
# Teaches the agents in this VM how to drive `gh stack`. Installed at user scope
# so it applies to every project synced into C:\workspace and is captured by the
# base snapshot, rather than living in one project's working copy.
#
# Exit contract:
#   0 -- extension and skill are both in place
#   2 -- extension is in, but the skill is pending ONLY because `gh` is not
#        authenticated. That is the expected state on a fresh VM, not a failure,
#        and its remedy is specifically `gh auth login`, so it gets its own code
#        rather than a throw.
#   throw (1) -- anything else, including a `gh` too old for `gh skill` and a
#        skill install that failed while authenticated. Those are real errors
#        with different remedies, so they must not masquerade as "needs auth".
$skillPendingExit = 2

if ($SkipSkill) {
    Write-Host "Skipping the gh-stack skill (-SkipSkill)."
    exit 0
}

Write-Host "Installing the gh-stack agent skill..."

if (-not (Test-GhSubcommand -Name "skill")) {
    throw ("This GitHub CLI has no 'gh skill' command (it is a recent addition). " +
           "Upgrade gh (winget upgrade --id GitHub.cli) and re-run this script.")
}

# `gh skill install <owner>/<repo>` resolves the skill through the GitHub API and
# requires an authenticated gh, unlike `gh extension install`.
gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  'gh' is not authenticated, and 'gh skill install' needs API access. Run:"
    Write-Warning "      gh auth login"
    Write-Warning "      powershell -ExecutionPolicy RemoteSigned -File C:\Install-GhStack.ps1 -SkipExtension"
    exit $skillPendingExit
}

$failedAgents = @()
foreach ($agent in $SkillAgents) {
    # --all skips the interactive skill picker, --force overwrites a previously
    # installed copy; together they keep this non-interactive and re-runnable.
    gh skill install github/gh-stack --agent $agent --scope user --all --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  'gh skill install' failed for agent '$agent' (exit code $LASTEXITCODE)."
        $failedAgents += $agent
    } else {
        Write-Host "  gh-stack skill installed for '$agent' (user scope)."
    }
}

# `gh` was authenticated, so a failure here is a genuine error -- not the
# pending-auth case -- and telling the caller to run `gh auth login` would send
# them down the wrong path.
if ($failedAgents.Count -gt 0) {
    throw "'gh skill install' failed for: $($failedAgents -join ', '). See the errors above."
}

exit 0
