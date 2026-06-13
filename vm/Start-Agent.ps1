# vm/Start-Agent.ps1
# Optional: place this in the VM's startup folder so the agent
# launches automatically in the right directory when the VM boots.
# Path inside VM: C:\Users\<user>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\

$ErrorActionPreference = "Stop"

$workspacePath = "C:\workspace"
$shareName = "AgentSandboxShare"
$agentSandboxConfigPath = "C:\AgentSandboxVM.json"

if (Test-Path $agentSandboxConfigPath) {
    try {
        $agentSandboxConfig = Get-Content $agentSandboxConfigPath -Raw | ConvertFrom-Json
        if ($agentSandboxConfig.ShareName) {
            $shareName = $agentSandboxConfig.ShareName
        }
    } catch {
        Write-Warning "Could not read $agentSandboxConfigPath; using legacy share name."
    }
}

# Sync shared project files into workspace on boot
$sharedProject = "\\localhost\$shareName\project"
if (Test-Path $sharedProject) {
    Write-Host "Syncing project from host share..."
    robocopy $sharedProject $workspacePath /MIR /NFL /NDL /NJH | Out-Null
}

# Launch Windows Terminal with the agent
Start-Process "wt" -ArgumentList "powershell -NoExit -Command `"
    Set-Location '$workspacePath'
    Write-Host 'Agent Sandbox VM' -ForegroundColor Cyan
    Write-Host 'Project: $workspacePath' -ForegroundColor Gray
    Write-Host ''
    claude
`""
