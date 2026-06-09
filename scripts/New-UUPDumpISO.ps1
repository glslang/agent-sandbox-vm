# scripts/New-UUPDumpISO.ps1
# Builds a Windows ISO from UUP dump (uupdump.net) -- downloads UUP files
# straight from Microsoft's update servers and compiles them into an ISO.
# Optional alternative to supplying your own ISO during Bootstrap.
#
# Defaults to the newest Windows Server 2025 build for amd64 (x86_64).
#
# Examples:
#   .\scripts\New-UUPDumpISO.ps1
#   .\scripts\New-UUPDumpISO.ps1 -Version "Windows 11, version 25H2" -Architecture arm64
#   .\scripts\New-UUPDumpISO.ps1 -BuildId fd40a8e3-e717-4031-894c-53c5e8e29fdb -Edition SERVERDATACENTER
#
# Outputs the full path of the finished ISO (Bootstrap.ps1 captures this).

#Requires -RunAsAdministrator

param(
    # Search string matched against UUP dump's known builds (https://uupdump.net/known.php)
    [string]$Version = "Windows Server 2025",

    # amd64 == x86_64
    [ValidateSet("amd64", "arm64", "x86")]
    [string]$Architecture = "amd64",

    # UUP dump edition code (e.g. SERVERSTANDARD, SERVERDATACENTER, PROFESSIONAL, CORE).
    # Auto-selected when omitted: SERVERSTANDARD if available, else PROFESSIONAL.
    [string]$Edition = "",

    # Language pack to include
    [string]$Language = "en-us",

    # Exact UUP dump build UUID -- skips the version search when provided
    [string]$BuildId = "",

    # Where the finished ISO is placed. Defaults to <CacheRoot>\iso from config.json.
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$apiBase = "https://api.uupdump.net"

# -- Resolve output location --
if (-not $OutputPath) {
    $configPath = "$env:USERPROFILE\.agent-sandbox\config.json"
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $OutputPath = "$($cfg.CacheRoot)\iso"
    } else {
        $OutputPath = Join-Path (Split-Path $PSScriptRoot -Parent) "iso"
    }
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$workDir = Join-Path $OutputPath "uup-work"

Write-Host ""
Write-Host "----------------------------------------------"
Write-Host "  Building Windows ISO from UUP dump"
Write-Host "----------------------------------------------"
Write-Host ""

$drive = (Get-Item $OutputPath).PSDrive
if ($drive -and $drive.Free -lt 25GB) {
    Write-Warning "  Less than 25 GB free on $($drive.Name): -- the UUP download + ISO build may run out of space."
}

# -- Step 1: Resolve the build --
if ($BuildId) {
    $buildUuid = $BuildId
    Write-Host "[1/4] Using pinned build: $BuildId"
} else {
    Write-Host "[1/4] Searching UUP dump for '$Version' ($Architecture)..."
    $searchUrl = "$apiBase/listid.php?search=$([uri]::EscapeDataString($Version))&sortByDate=1"
    $result = (Invoke-RestMethod -Uri $searchUrl -UseBasicParsing).response
    if ($result.error) {
        throw "UUP dump API error: $($result.error)"
    }

    $builds = @($result.builds.PSObject.Properties.Value) |
        Where-Object { $_.arch -eq $Architecture } |
        Sort-Object created -Descending

    if (-not $builds) {
        throw "No '$Version' builds found for $Architecture. Browse https://uupdump.net/known.php for valid names."
    }

    $selected = $builds[0]
    $buildUuid = $selected.uuid
    Write-Host "  Selected: $($selected.title) $($selected.arch) (uuid $buildUuid)"
}

# -- Step 2: Pick the edition --
if (-not $Edition) {
    Write-Host "[2/4] Querying available editions..."
    $edUrl = "$apiBase/listeditions.php?lang=$Language&id=$buildUuid"
    $edResult = (Invoke-RestMethod -Uri $edUrl -UseBasicParsing).response
    if ($edResult.error) {
        throw "UUP dump API error: $($edResult.error)"
    }
    $available = @($edResult.editionList)
    if ($available -contains "SERVERSTANDARD") {
        $Edition = "SERVERSTANDARD"
    } elseif ($available -contains "PROFESSIONAL") {
        $Edition = "PROFESSIONAL"
    } elseif ($available) {
        $Edition = $available[0]
    } else {
        throw "No editions reported for build $buildUuid (language $Language)."
    }
    Write-Host "  Auto-selected edition: $Edition (available: $($available -join ', '))"
} else {
    Write-Host "[2/4] Using edition: $Edition"
}

# -- Step 3: Download the UUP dump conversion package --
Write-Host "[3/4] Downloading UUP dump conversion package..."
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$zipPath = Join-Path $workDir "uup-package.zip"

$getUrl = "https://uupdump.net/get.php?id=$buildUuid&pack=$Language&edition=$($Edition.ToLower())"
# autodl=2 -> package that downloads UUP files and converts them to an ISO;
# updates=1 -> integrate updates; cleanup=1 -> delete UUP files after conversion.
Invoke-WebRequest -Uri $getUrl -Method POST -Body "autodl=2&updates=1&cleanup=1" `
    -ContentType "application/x-www-form-urlencoded" -OutFile $zipPath -UseBasicParsing

# Validate the download is a real ZIP (first 2 bytes == "PK").
# An HTML/JSON error page means the request failed (rate limit, bad edition, ...).
$magic = [System.IO.File]::ReadAllBytes($zipPath) | Select-Object -First 2
if ($magic.Count -lt 2 -or $magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) {
    throw "Downloaded package is not a valid ZIP. UUP dump may be rate-limiting, or the edition '$Edition' is invalid for this build. Try again later or pick the build manually at https://uupdump.net"
}

Expand-Archive -Path $zipPath -DestinationPath $workDir -Force

# Make the converter exit instead of waiting for a keypress when done.
# No BOM: the cmd-side ini parser chokes on one.
$iniPath = Join-Path $workDir "ConvertConfig.ini"
if (Test-Path $iniPath) {
    (Get-Content $iniPath -Raw) -replace '(?m)^(\s*AutoExit\s*=\s*)\d', '${1}1' |
        Set-Content $iniPath -Encoding Ascii
}

# -- Step 4: Download UUP files and compile the ISO --
$cmdScript = Join-Path $workDir "uup_download_windows.cmd"
if (-not (Test-Path $cmdScript)) {
    throw "uup_download_windows.cmd not found in the package -- UUP dump may have changed its package layout."
}

Write-Host "[4/4] Downloading UUP files from Microsoft and compiling the ISO."
Write-Host "      This downloads several GB and typically takes 30-90 minutes..."
$proc = Start-Process cmd.exe -ArgumentList "/c", "uup_download_windows.cmd" `
    -WorkingDirectory $workDir -Wait -NoNewWindow -PassThru

$iso = Get-ChildItem -Path $workDir -Filter *.iso |
    Sort-Object Length -Descending | Select-Object -First 1
if (-not $iso) {
    throw "No ISO was produced (converter exit code $($proc.ExitCode)). The work directory is kept at '$workDir' -- re-run this script to resume; already-downloaded files are reused."
}

$finalPath = Join-Path $OutputPath $iso.Name
Move-Item $iso.FullName $finalPath -Force
Remove-Item $workDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ISO ready: $finalPath"
Write-Host ""
Write-Host "  Install it to the VM with:"
Write-Host "    .\scripts\Install-Windows.ps1 -ISOPath `"$finalPath`""
Write-Host ""

$finalPath
