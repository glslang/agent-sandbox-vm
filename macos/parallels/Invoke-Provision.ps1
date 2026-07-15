# macos/parallels/Invoke-Provision.ps1
#
# ARM64 toolchain provisioner. Runs INSIDE the Windows 11 ARM64 guest.
#
# Start-Provision.sh writes this script into the Parallels shared folder and
# launches it with a NON-interactive (batch) scheduled task -- run as Admin with
# a full token, but NOT tied to an interactive logon. That matters because a
# fresh guest may be sitting at the Windows OOBE/EULA screen with nobody signed
# in: a batch task still runs (and still has \\Mac\<share> + internet), whereas
# an /IT interactive task would not run until someone logs in. (`prlctl exec`
# is unusable for this -- it runs in a raw Session 0 where installers misbehave,
# large/long execs orphan on the host, and \\Mac\<share> is not even mapped.)
#
# It installs everything via DIRECT DOWNLOADS -- never winget -- for pinned,
# deterministic installs that don't depend on the winget source or a per-user App
# Execution Alias. (This is the key difference from the Hyper-V provisioner
# scripts/Invoke-Provision.ps1, which uses winget.) Node uses the ARM64 zip
# because nodejs.org ships no ARM64 MSI.
#
# Assumes internet access (Start-Provision sets net0 to shared) and that UAC
# admin-approval mode is off (set by autounattend.arm64.xml) so this runs with a
# full admin token.

$ErrorActionPreference = "Stop"
# Injected by the Start-Provision.sh wrapper (--rearm-updates); default to OFF
# when this script is run standalone.
if (-not (Test-Path variable:RearmWindowsUpdate)) { $RearmWindowsUpdate = $false }
# Windows PowerShell 5.1 needs TLS 1.2 explicitly for these HTTPS endpoints.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$GhHeaders = @{ 'User-Agent' = 'agent-sandbox-vm' }

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Agent Sandbox VM (Parallels/ARM64) -- Provisioning"
Write-Host "----------------------------------------------"
Write-Host ""

function Update-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Add-MachinePath {
    param([Parameter(Mandatory)][string]$Dir)
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    if (($machine -split ';') -notcontains $Dir) {
        [System.Environment]::SetEnvironmentVariable("PATH", "$machine;$Dir", "Machine")
    }
    Update-Path
}

function Assert-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name, [string]$InstallHint = "")
    Update-Path
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        $message = "Expected command '$Name' was not found on PATH after installation."
        if ($InstallHint) { $message += " $InstallHint" }
        throw $message
    }
    return $command
}

function Invoke-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    Unblock-File -Path $OutFile -ErrorAction SilentlyContinue
}

# -- 0. Execution policy (best-effort) --
# We are already launched with `-ExecutionPolicy Bypass`, so this only persists a
# sane machine default for later interactive use. It must NOT be fatal: because
# the active Process-scope Bypass overrides LocalMachine, Set-ExecutionPolicy
# raises a TERMINATING error ("...overridden by a policy defined at a more
# specific scope"). That is thrown via ThrowTerminatingError, so -ErrorAction
# SilentlyContinue does NOT suppress it -- only try/catch does.
Write-Host "[1/9] Setting execution policy..."
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host "  ExecutionPolicy set to RemoteSigned (LocalMachine)."
} catch {
    Write-Host "  ExecutionPolicy left as-is (already running under -ExecutionPolicy Bypass)."
}

# -- 0b. Windows Update: no automatic install/restart --
# A fresh install starts downloading updates immediately, and Windows will
# auto-restart to finish them -- interrupting this provisioner mid-flight. (The
# ONSTART task relaunches it after a reboot, but a surprise restart still
# throws away a long VS install and makes runs nondeterministic.)
# autounattend.arm64.xml sets this policy from first boot; re-assert it here for
# guests installed without it, and stop any in-flight update cycle. Manual
# "Check for updates" in Settings still works -- only AUTOMATIC download/
# install/restart is off, deliberately, so snapshot restores stay deterministic
# and agent sessions never get surprise-rebooted.
Write-Host "[2/9] Disabling automatic Windows Update (no mid-provision restart)..."
$au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
Stop-Service -Name wuauserv, UsoSvc -Force -ErrorAction SilentlyContinue
Write-Host "  Automatic updates disabled (manual check still available)."

# -- 1. Node.js (ARM64 zip -- nodejs.org ships no arm64 MSI) --
Write-Host "[3/9] Installing Node.js (ARM64 zip)..."
$nodeIndex = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -UseBasicParsing
$nodeRel = $nodeIndex | Where-Object { $_.lts -and ($_.files -contains 'win-arm64-zip') } | Select-Object -First 1
if (-not $nodeRel) { throw "No LTS Node.js release with a win-arm64-zip was found." }
$nv = $nodeRel.version
Write-Host "  Latest LTS with ARM64 build: $nv ($($nodeRel.lts))"
$nodeZip = "$env:TEMP\node-$nv-arm64.zip"
Invoke-Download "https://nodejs.org/dist/$nv/node-$nv-win-arm64.zip" $nodeZip
$nodeExtract = "$env:TEMP\node-extract"
Remove-Item $nodeExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $nodeZip -DestinationPath $nodeExtract -Force
$nodeDest = "C:\Program Files\nodejs"
New-Item -ItemType Directory -Force -Path $nodeDest | Out-Null
Copy-Item -Path "$nodeExtract\node-$nv-win-arm64\*" -Destination $nodeDest -Recurse -Force
Add-MachinePath $nodeDest
# Global npm bin dir (npm install -g lands here); put it on PATH for the guest's
# interactive session too, so `claude`/`codex` resolve when the agent runs.
$npmPrefix = Join-Path $env:APPDATA "npm"
New-Item -ItemType Directory -Force -Path $npmPrefix | Out-Null
& "$nodeDest\npm.cmd" config set prefix "$npmPrefix" | Out-Null
Add-MachinePath $npmPrefix
Assert-CommandAvailable -Name "node" | Out-Null
Assert-CommandAvailable -Name "npm"  | Out-Null
Write-Host "  Node installed: $(node --version)  npm: $(npm --version)"

# -- 2. VS Build Tools (with native ARM64 compilers) --
# Launch WITHOUT -NoNewWindow. `Start-Process -Wait -NoNewWindow` waits not just
# for the process but for its inherited (shared-console) stdout/stderr handles to
# close, and the VS installer spawns background children (msiexec / ServiceHub /
# PerfWatson) that inherit that handle and linger after the install finishes --
# so -Wait NEVER returns even though VS is fully installed. That is the "stuck at
# VS Build Tools" hang. Giving the installer its own console (no -NoNewWindow)
# makes -Wait return as soon as the --wait bootstrapper exits, i.e. exactly when
# the install is done. (Verified: identical args hang with -NoNewWindow, finish
# in ~7 min without it.)
Write-Host "[4/9] Installing VS Build Tools (ARM64) -- this takes ~10-20 min..."
$vsInstaller = "$env:TEMP\vs_buildtools.exe"
Invoke-Download "https://aka.ms/vs/18/stable/vs_buildtools.exe" $vsInstaller
$proc = Start-Process $vsInstaller -ArgumentList @(
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--includeRecommended",
    "--quiet", "--wait", "--norestart"
) -Wait -PassThru
if ($proc.ExitCode -notin 0, 3010) {
    throw "VS Build Tools installer failed with exit code $($proc.ExitCode). Check dd_*.log in $env:TEMP."
}
# A bad/partial install must fail LOUDLY, not silently leave the sandbox with no
# compiler -- verify the native ARM64 cl.exe actually landed before continuing.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath 2>$null | Select-Object -First 1
if (-not $vsPath) { throw "VS Build Tools: VC.Tools.ARM64 workload not present after install." }
$clExe = Get-ChildItem "$vsPath\VC\Tools\MSVC\*\bin\Hostarm64\arm64\cl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clExe) { throw "VS Build Tools: native ARM64 cl.exe not found under $vsPath after install." }
Write-Host "  VS Build Tools installed. cl.exe: $($clExe.FullName)"

# -- 3. Rust (aarch64 MSVC toolchain) --
Write-Host "[5/9] Installing Rust (aarch64-pc-windows-msvc)..."
Invoke-Download "https://static.rust-lang.org/rustup/dist/aarch64-pc-windows-msvc/rustup-init.exe" "$env:TEMP\rustup-init.exe"
& "$env:TEMP\rustup-init.exe" -y --default-toolchain stable --default-host aarch64-pc-windows-msvc
Update-Path
rustup component add clippy rustfmt
Write-Host "  Rust installed: $(rustc --version)"

# -- 4. uv + Python (uv-managed CPython, native ARM64) --
# uv ships an aarch64-pc-windows-msvc build, and uv itself provisions the Python
# toolchain (python-build-standalone, which has native win-arm64 builds) -- so we
# get both the package/venv manager AND Python without a python.org ARM64 MSI.
# Use `uv venv` (the uv equivalent of `python -m venv`) / `uv run` for envs.
Write-Host "[6/9] Installing uv + Python (aarch64)..."
$uvRel = Invoke-RestMethod -Uri "https://api.github.com/repos/astral-sh/uv/releases/latest" -Headers $GhHeaders -UseBasicParsing
$uvAsset = $uvRel.assets | Where-Object { $_.name -eq 'uv-aarch64-pc-windows-msvc.zip' } | Select-Object -First 1
if (-not $uvAsset) { throw "No aarch64 uv asset found in the latest uv release." }
$uvZip = "$env:TEMP\uv-arm64.zip"
Invoke-Download $uvAsset.browser_download_url $uvZip
$uvDest = "C:\Program Files\uv"
New-Item -ItemType Directory -Force -Path $uvDest | Out-Null
Expand-Archive -Path $uvZip -DestinationPath $uvDest -Force
Add-MachinePath $uvDest
Assert-CommandAvailable -Name "uv" | Out-Null
Write-Host "  uv installed: $(uv --version)"
# Provision a managed CPython. `--default` drops `python`/`python3` shims into
# uv's Python *bin* directory (NOT $uvDest) -- by default %USERPROFILE%\.local\bin
# -- so pin it via UV_PYTHON_BIN_DIR to a known location and put THAT on the
# machine PATH, otherwise later sessions resolve `uv` but not a bare `python`.
$uvPythonBin = Join-Path $uvDest "python-bin"
New-Item -ItemType Directory -Force -Path $uvPythonBin | Out-Null
[System.Environment]::SetEnvironmentVariable("UV_PYTHON_BIN_DIR", $uvPythonBin, "Machine")
$env:UV_PYTHON_BIN_DIR = $uvPythonBin
uv python install 3.13 --default
if ($LASTEXITCODE -ne 0) { throw "uv failed to install a managed Python (exit $LASTEXITCODE)." }
Add-MachinePath $uvPythonBin
Update-Path
# Fail hard if the global `python` shim did not actually land on PATH, so the
# README's promise that `python` resolves in-guest is enforced here.
Assert-CommandAvailable -Name "python" -InstallHint "uv --default installs the python shim into UV_PYTHON_BIN_DIR ($uvPythonBin); ensure that dir is on PATH." | Out-Null
Write-Host "  Python (uv-managed): $(python --version)"

# -- 5. Git for Windows (ARM64, silent) --
Write-Host "[7/9] Installing Git for Windows (ARM64)..."
try {
    $gitRel = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers $GhHeaders -UseBasicParsing
    $gitAsset = $gitRel.assets | Where-Object { $_.name -match '^Git-.*-arm64\.exe$' } | Select-Object -First 1
    if ($gitAsset) {
        $gitExe = "$env:TEMP\git-arm64.exe"
        Invoke-Download $gitAsset.browser_download_url $gitExe
        Start-Process $gitExe -ArgumentList "/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/SUPPRESSMSGBOXES" -Wait
        Update-Path
        $gitBashExe = @(
            "C:\Program Files\Git\bin\bash.exe",
            "C:\Program Files\Git\usr\bin\bash.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($gitBashExe) {
            [System.Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $gitBashExe, "Machine")
            $env:CLAUDE_CODE_GIT_BASH_PATH = $gitBashExe
            Write-Host "  Git Bash: $gitBashExe (set CLAUDE_CODE_GIT_BASH_PATH)"
        } else {
            Write-Warning "  bash.exe not found after Git install."
        }
    } else {
        Write-Warning "  No ARM64 Git asset found in the latest release; skipping Git."
    }
} catch {
    Write-Warning "  Git install failed: $($_.Exception.Message)"
}

# -- 6. GitHub CLI (ARM64 MSI, non-fatal) --
Write-Host "[8/9] Installing GitHub CLI (ARM64)..."
try {
    $ghRel = Invoke-RestMethod -Uri "https://api.github.com/repos/cli/cli/releases/latest" -Headers $GhHeaders -UseBasicParsing
    $ghAsset = $ghRel.assets | Where-Object { $_.name -match 'windows_arm64\.msi$' } | Select-Object -First 1
    if ($ghAsset) {
        $ghMsi = "$env:TEMP\gh-arm64.msi"
        Invoke-Download $ghAsset.browser_download_url $ghMsi
        Start-Process msiexec.exe -ArgumentList "/i", "`"$ghMsi`"", "/qn", "/norestart" -Wait
        Update-Path
        Write-Host "  GitHub CLI installed."
    } else {
        Write-Warning "  No ARM64 gh MSI found; skipping."
    }
} catch {
    Write-Warning "  GitHub CLI install failed: $($_.Exception.Message)"
}

# -- 7. Claude Code + Codex CLI (npm global) --
Write-Host "[9/9] Installing Claude Code + Codex CLI..."
& "$nodeDest\npm.cmd" install -g @anthropic-ai/claude-code
Update-Path
Write-Host "  Claude Code installed: $(claude --version)"
& "$nodeDest\npm.cmd" install -g @openai/codex
Update-Path
try { Write-Host "  Codex CLI installed: $(codex --version)" } catch { Write-Warning "  Codex CLI check failed: $($_.Exception.Message)" }

# -- Workspace --
New-Item -ItemType Directory -Force -Path "C:\workspace" | Out-Null

# -- Optional: re-arm automatic Windows Update --
# [2/9] turned automatic updates off so nothing could reboot the guest while
# this script runs. Default is to LEAVE them off (deterministic snapshot
# restores; no surprise restarts mid agent session). `Start-Provision.sh
# --rearm-updates` re-arms them here -- last, now that the reboot-sensitive
# part is over -- so the base snapshot captures a self-patching guest.
if ($RearmWindowsUpdate) {
    Write-Host "Re-arming automatic Windows Update (--rearm-updates)..."
    Remove-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Write-Host "  Automatic updates re-enabled."
} else {
    Write-Host "Automatic Windows Update left disabled (pass --rearm-updates to re-arm)."
}

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Provisioning complete!"
Write-Host ""
Write-Host "  On the HOST, capture the clean base snapshot:"
Write-Host "    ./Save-BaseSnapshot.sh --name <this-vm-name>"
Write-Host ""
Write-Host "  Authenticate later from inside a session (interactive):"
Write-Host "    claude login"
Write-Host "----------------------------------------------"
