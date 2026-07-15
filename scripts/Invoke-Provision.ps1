# scripts/Invoke-Provision.ps1
# Run INSIDE the VM as Administrator after Windows is installed.
# Installs VS Build Tools, Rust, Node, TTD, Claude Code, and enables PSRemoting.
#
# Expects:
#   - Internet access (Default Switch must be active)
#   - VS Build Tools layout at C:\vs-cache\layout (copied in by Start-Provision.ps1)
#     OR falls back to downloading from internet

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Agent Sandbox VM -- Provisioning"
Write-Host "----------------------------------------------"
Write-Host ""

# -- Helper --
function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Assert-WinGetAvailable {
    # On a freshly provisioned VM this runs shortly after the user's first login,
    # and WinGet (Microsoft.DesktopAppInstaller) registration is asynchronous --
    # the `winget` command can be missing for a short window after OOBE. Wait for
    # it, re-registering the AppX package if it does not appear on its own.
    # See https://learn.microsoft.com/en-us/windows/package-manager/winget/#install-winget
    param(
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Refresh-Path
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Write-Host "  winget is available."
            return
        }

        Write-Host "  winget not available yet (attempt $attempt/$MaxAttempts); attempting to register..."
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" -ErrorAction Stop
        } catch {
            Write-Host "  Registration attempt failed: $($_.Exception.Message)"
        }

        Refresh-Path
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Write-Host "  winget is available."
            return
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    # Final check: winget may have finished registering during the last sleep.
    Refresh-Path
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host "  winget is available."
        return
    }

    throw "winget (Microsoft.DesktopAppInstaller) did not become available after $MaxAttempts attempts. " +
          "On a fresh VM, WinGet may still be registering after first login -- wait a moment and re-run this script."
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [string]$DisplayName = $Id
    )

    winget install `
        --id $Id `
        --exact `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $DisplayName ($Id) with exit code $LASTEXITCODE."
    }
}

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$InstallHint = ""
    )

    Refresh-Path
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        $message = "Expected command '$Name' was not found on PATH after installation."
        if ($InstallHint) {
            $message += " $InstallHint"
        }
        throw $message
    }

    return $command
}

# -- 0. Execution Policy --
# Set machine-wide policy so npm-installed .ps1 wrappers (e.g. claude.ps1) run
# in all future sessions without needing a per-process policy override each time.
Write-Host "[1/16] Setting execution policy..."
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
Write-Host "  ExecutionPolicy set to RemoteSigned (LocalMachine)."

# -- 1. PowerShell 7 --
# Install the modern cross-platform PowerShell (pwsh). Windows ships only with
# Windows PowerShell 5.1; pwsh is the preferred shell for agent tooling and is
# the host targeted by the Oh My Posh profile init configured below.
Write-Host "[2/16] Installing PowerShell 7..."

# This is the first winget call on the provisioning path, so make sure WinGet has
# finished registering before relying on it.
Assert-WinGetAvailable
Install-WingetPackage -Id "Microsoft.PowerShell" -DisplayName "PowerShell 7"
$pwshCommand = Assert-CommandAvailable -Name "pwsh.exe" -InstallHint "PowerShell 7 should be installed by winget; verify C:\Program Files\PowerShell\7 is on PATH."
Write-Host "  PowerShell 7 installed: $(pwsh --version)"

# -- 2. VS Build Tools --
Write-Host "[3/16] Installing VS Build Tools..."

$layoutInstaller = "C:\vs-cache\layout\vs_buildtools.exe"
$onlineInstaller = "$env:TEMP\vs_buildtools.exe"

if (Test-Path $layoutInstaller) {
    Write-Host "  Using offline layout (fast)..."
    $installer = $layoutInstaller
    $extraArgs = @("--noweb")
} else {
    Write-Host "  Offline layout not found -- downloading from internet..."
    Invoke-WebRequest "https://aka.ms/vs/18/stable/vs_buildtools.exe" -OutFile $onlineInstaller -UseBasicParsing
    Unblock-File -Path $onlineInstaller
    $installer = $onlineInstaller
    $extraArgs = @()
}

$proc = Start-Process $installer -ArgumentList (@(
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--includeRecommended",
    "--quiet", "--wait", "--norestart"
) + $extraArgs) -Wait -NoNewWindow -PassThru

if ($proc.ExitCode -notin 0, 3010) {
    Write-Warning "  VS Build Tools exited with code $($proc.ExitCode)"
} else {
    Write-Host "  VS Build Tools installed."
}

# -- 3. Rust (MSVC toolchain) --
Write-Host "[4/16] Installing Rust..."

Invoke-WebRequest "https://win.rustup.rs/x86_64" -OutFile "$env:TEMP\rustup-init.exe"
& "$env:TEMP\rustup-init.exe" -y --default-toolchain stable --default-host x86_64-pc-windows-msvc
Refresh-Path
rustup component add clippy rustfmt
Write-Host "  Rust installed: $(rustc --version)"

# -- 4. Node.js --
Write-Host "[5/16] Installing Node.js..."

Install-WingetPackage -Id "OpenJS.NodeJS" -DisplayName "Node.js"
Assert-CommandAvailable -Name "node" -InstallHint "If Node was installed by winget, open a new elevated PowerShell session or verify C:\Program Files\nodejs is on PATH." | Out-Null
Assert-CommandAvailable -Name "npm" -InstallHint "npm should be installed with Node.js." | Out-Null
Write-Host "  Node installed: $(node --version)"

# -- 5. Python --
# Install CPython system-wide. The winget package puts python.exe and its
# Scripts\ dir on PATH, giving the agent a stock `python`/`pip` plus the
# built-in `python -m venv` for virtual environments.
Write-Host "[6/16] Installing Python..."

Install-WingetPackage -Id "Python.Python.3.13" -DisplayName "Python 3.13"
Assert-CommandAvailable -Name "python" -InstallHint "Python should be installed by winget; verify the install dir and its Scripts folder are on PATH." | Out-Null
Write-Host "  Python installed: $(python --version)"

# -- 6. uv (Python package + venv manager) --
# uv is the fast, modern alternative to pip/virtualenv. It provides `uv venv`
# (the uv equivalent of `python -m venv`) and `uv run` for managed environments.
Write-Host "[7/16] Installing uv..."

Install-WingetPackage -Id "astral-sh.uv" -DisplayName "uv"
Assert-CommandAvailable -Name "uv" -InstallHint "uv should be installed by winget." | Out-Null
Write-Host "  uv installed: $(uv --version)"

# Verify end to end that a virtual environment can actually be created, so a
# broken Python/uv install fails here rather than in the agent's first session.
$uvVenvProbe = Join-Path $env:TEMP "uv-venv-probe"
Remove-Item $uvVenvProbe -Recurse -Force -ErrorAction SilentlyContinue
uv venv $uvVenvProbe | Out-Null
if (Test-Path (Join-Path $uvVenvProbe "Scripts\python.exe")) {
    Write-Host "  Verified: 'uv venv' creates a working virtual environment."
} else {
    Write-Warning "  'uv venv' did not produce the expected environment layout."
}
Remove-Item $uvVenvProbe -Recurse -Force -ErrorAction SilentlyContinue

# -- 7. Git for Windows (Git Bash) --
Write-Host "[8/16] Installing Git for Windows..."

Install-WingetPackage -Id "Git.Git" -DisplayName "Git for Windows"
Refresh-Path

# Locate bash.exe and pin it via CLAUDE_CODE_GIT_BASH_PATH so Claude Code can
# find it even when Git's bin dir is not first on PATH.
$gitBashCandidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe"
)
$gitBashExe = $gitBashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($gitBashExe) {
    [System.Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $gitBashExe, "Machine")
    $env:CLAUDE_CODE_GIT_BASH_PATH = $gitBashExe
    Write-Host "  Git Bash installed: $gitBashExe"
    Write-Host "  Set CLAUDE_CODE_GIT_BASH_PATH=$gitBashExe"
} else {
    Write-Warning "  bash.exe not found in expected locations -- set CLAUDE_CODE_GIT_BASH_PATH manually."
}

# -- 8. GitHub CLI --
Write-Host "[9/16] Installing GitHub CLI..."

Install-WingetPackage -Id "GitHub.cli" -DisplayName "GitHub CLI"
Assert-CommandAvailable -Name "gh" -InstallHint "GitHub CLI should be installed by winget." | Out-Null
Write-Host "  GitHub CLI installed: $(gh --version | Select-Object -First 1)"

# -- 9. Windows Terminal --
Write-Host "[10/16] Installing Windows Terminal..."

Install-WingetPackage -Id "Microsoft.WindowsTerminal" -DisplayName "Windows Terminal"
Write-Host "  Windows Terminal installed."

# -- 10. Oh My Posh --
Write-Host "[11/16] Installing Oh My Posh..."

Install-WingetPackage -Id "JanDeDobbeleer.OhMyPosh" -DisplayName "Oh My Posh"
Assert-CommandAvailable -Name "oh-my-posh" -InstallHint "Oh My Posh should be installed by winget." | Out-Null

# CascadiaCode Nerd Font is required for glyph rendering in most themes.
oh-my-posh font install CascadiaCode --user

# Add Oh My Posh init to the PowerShell profile using the jandedobbeleer theme.
# Configure both the Windows PowerShell 5.1 profile (this script's host) and the
# PowerShell 7 (pwsh) profile, since they live in separate locations.
$ompInit = 'oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\jandedobbeleer.omp.json" | Invoke-Expression'

# Resolve the pwsh profile path; fall back to none if pwsh is unavailable.
$pwshProfile = (& pwsh -NoProfile -Command '$PROFILE.CurrentUserCurrentHost') 2>$null

$profileTargets = @($PROFILE)
if ($pwshProfile) { $profileTargets += $pwshProfile }

foreach ($target in $profileTargets) {
    $profileDir = Split-Path $target -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    if (-not (Test-Path $target))     { New-Item -ItemType File    -Force -Path $target     | Out-Null }
    if (-not (Select-String -Path $target -SimpleMatch 'oh-my-posh init pwsh' -Quiet)) {
        Add-Content -Path $target -Value $ompInit
    }
}
Write-Host "  Oh My Posh installed (theme: jandedobbeleer, font: CascadiaCode NF)."
Write-Host "  Configured profiles: $($profileTargets -join ', ')"
Write-Host "  Themes directory: `$env:POSH_THEMES_PATH -- swap theme by editing your profile."

# -- 11. TTD command line utility --
Write-Host "[12/16] Installing TTD command line utility..."

Install-WingetPackage -Id "Microsoft.TimeTravelDebugging" -DisplayName "TTD command line utility"
$ttdCommand = Assert-CommandAvailable -Name "ttd.exe" -InstallHint "TTD should be installed by winget."
Write-Host "  TTD installed: $($ttdCommand.Source)"

# -- 12. Claude Code --
Write-Host "[13/16] Installing Claude Code..."

npm install -g @anthropic-ai/claude-code
Refresh-Path
Write-Host "  Claude Code installed: $(claude --version)"

# -- 13. OpenAI Codex CLI --
Write-Host "[14/16] Installing OpenAI Codex CLI..."

npm install -g @openai/codex
Refresh-Path
Write-Host "  Codex CLI installed: $(codex --version)"

# -- 14. Authenticate --
Write-Host "[15/16] Authenticating with Claude (optional)..."
Write-Host "  Skip this step if you are using OpenAI Codex CLI only."
Write-Host ""
$reply = Read-Host "  Authenticate with Claude now? [Y/n]"
if ($reply -eq '' -or $reply -match '^[Yy]') {
    Write-Host "  A browser window will open. Complete the OAuth flow."
    claude login
    Write-Host "  Authentication complete."
} else {
    Write-Host "  Skipped. Run 'claude login' inside the VM whenever you need it."
}

# -- 15. Enable PSRemoting (for artifact extraction from host) --
Write-Host "[16/16] Enabling PowerShell remoting..."

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service WinRM -StartupType Automatic
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Create workspace directory
New-Item -ItemType Directory -Force -Path "C:\workspace" | Out-Null

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Provisioning complete!"
Write-Host ""
Write-Host "  Shut down this VM now, then on your HOST:"
Write-Host "    .\scripts\Save-BaseSnapshot.ps1 -VMName <this-vm-name>"
Write-Host "----------------------------------------------"
