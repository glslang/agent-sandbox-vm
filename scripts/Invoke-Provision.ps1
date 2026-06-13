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
Write-Host "[1/13] Setting execution policy..."
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
Write-Host "  ExecutionPolicy set to RemoteSigned (LocalMachine)."

# -- 1. VS Build Tools --
Write-Host "[2/13] Installing VS Build Tools..."

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

# -- 2. Rust (MSVC toolchain) --
Write-Host "[3/13] Installing Rust..."

Invoke-WebRequest "https://win.rustup.rs/x86_64" -OutFile "$env:TEMP\rustup-init.exe"
& "$env:TEMP\rustup-init.exe" -y --default-toolchain stable --default-host x86_64-pc-windows-msvc
Refresh-Path
rustup component add clippy rustfmt
Write-Host "  Rust installed: $(rustc --version)"

# -- 3. Node.js --
Write-Host "[4/13] Installing Node.js..."

Install-WingetPackage -Id "OpenJS.NodeJS" -DisplayName "Node.js"
Assert-CommandAvailable -Name "node" -InstallHint "If Node was installed by winget, open a new elevated PowerShell session or verify C:\Program Files\nodejs is on PATH." | Out-Null
Assert-CommandAvailable -Name "npm" -InstallHint "npm should be installed with Node.js." | Out-Null
Write-Host "  Node installed: $(node --version)"

# -- 4. Git for Windows (Git Bash) --
Write-Host "[5/13] Installing Git for Windows..."

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

# -- 5b. GitHub CLI --
Write-Host "[6/13] Installing GitHub CLI..."

Install-WingetPackage -Id "GitHub.cli" -DisplayName "GitHub CLI"
Assert-CommandAvailable -Name "gh" -InstallHint "GitHub CLI should be installed by winget." | Out-Null
Write-Host "  GitHub CLI installed: $(gh --version | Select-Object -First 1)"

# -- 6. Windows Terminal --
Write-Host "[7/13] Installing Windows Terminal..."

Install-WingetPackage -Id "Microsoft.WindowsTerminal" -DisplayName "Windows Terminal"
Write-Host "  Windows Terminal installed."

# -- 7. Oh My Posh --
Write-Host "[8/13] Installing Oh My Posh..."

Install-WingetPackage -Id "JanDeDobbeleer.OhMyPosh" -DisplayName "Oh My Posh"
Assert-CommandAvailable -Name "oh-my-posh" -InstallHint "Oh My Posh should be installed by winget." | Out-Null

# CascadiaCode Nerd Font is required for glyph rendering in most themes.
oh-my-posh font install CascadiaCode --user

# Add Oh My Posh init to the PowerShell profile using the jandedobbeleer theme.
# The profile file may not exist yet; ensure its directory does.
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
if (-not (Test-Path $PROFILE))    { New-Item -ItemType File    -Force -Path $PROFILE    | Out-Null }
Add-Content -Path $PROFILE -Value 'oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\jandedobbeleer.omp.json" | Invoke-Expression'
Write-Host "  Oh My Posh installed (theme: jandedobbeleer, font: CascadiaCode NF)."
Write-Host "  Themes directory: `$env:POSH_THEMES_PATH -- swap theme by editing `$PROFILE."

# -- 8. TTD command line utility --
Write-Host "[9/13] Installing TTD command line utility..."

Install-WingetPackage -Id "Microsoft.TimeTravelDebugging" -DisplayName "TTD command line utility"
$ttdCommand = Assert-CommandAvailable -Name "ttd.exe" -InstallHint "TTD should be installed by winget."
Write-Host "  TTD installed: $($ttdCommand.Source)"

# -- 9. Claude Code --
Write-Host "[10/13] Installing Claude Code..."

npm install -g @anthropic-ai/claude-code
Refresh-Path
Write-Host "  Claude Code installed: $(claude --version)"

# -- 10. OpenAI Codex CLI --
Write-Host "[11/13] Installing OpenAI Codex CLI..."

npm install -g @openai/codex
Refresh-Path
Write-Host "  Codex CLI installed: $(codex --version)"

# -- 11. Authenticate --
Write-Host "[12/13] Authenticating with Claude (optional)..."
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

# -- 12. Enable PSRemoting (for artifact extraction from host) --
Write-Host "[13/13] Enabling PowerShell remoting..."

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
