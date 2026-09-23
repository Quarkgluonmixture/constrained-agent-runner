<#
.SYNOPSIS
    Removes the local gpt-loop installation.

.DESCRIPTION
    Conservative by default: stops the daemon and removes the logon task, but
    leaves state and the runner in place. Opt in to the destructive parts.

    It NEVER touches registered project workspaces.

.EXAMPLE
    pwsh -File scripts\uninstall-windows.ps1                       # stop + untask
    pwsh -File scripts\uninstall-windows.ps1 -RemoveRunner -RemoveState -Repo <owner>/<name>
#>

[CmdletBinding()]
param(
    [switch]$RemoveRunner,
    [switch]$RemoveState,
    # owner/name of the private repository the runner was registered to;
    # required only with -RemoveRunner.
    [string]$Repo = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($RemoveRunner -and [string]::IsNullOrWhiteSpace($Repo)) {
    throw '-RemoveRunner requires -Repo <owner>/<name> (the repository the runner was registered to)'
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'GPTLoop'
$taskName = 'GPTLoopWakeDaemon'

# --- daemon ------------------------------------------------------------------
$port = 8777
$configPath = Join-Path $stateRoot 'config\daemon.json'
$runnerDir = Join-Path $env:USERPROFILE 'actions-runner-gptloop'
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $port = [int]$config.port
        if ($config.PSObject.Properties['runner_dir']) { $runnerDir = [string]$config.runner_dir }
    } catch { }
}

$listeners = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
foreach ($listener in $listeners) {
    Write-Host "stopping wake daemon (PID $($listener.OwningProcess))"
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "removed logon task '$taskName'"
}

# --- runner ------------------------------------------------------------------
if ($RemoveRunner) {
    if (Test-Path -LiteralPath (Join-Path $runnerDir '.runner')) {
        Write-Host "unregistering runner in $runnerDir"
        $listener = Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($runnerDir, [StringComparison]::OrdinalIgnoreCase) }
        foreach ($proc in $listener) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2

        $token = gh api -X POST "repos/$Repo/actions/runners/remove-token" --jq '.token' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            & (Join-Path $runnerDir 'config.cmd') remove --token $token
        } else {
            Write-Warning "could not obtain a removal token; unregister manually in the repository settings"
        }
    }
    if (Test-Path -LiteralPath $runnerDir) {
        Remove-Item -LiteralPath $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "removed $runnerDir"
    }
} else {
    Write-Host "runner left in place (pass -RemoveRunner to unregister and delete)" -ForegroundColor DarkGray
}

# --- state -------------------------------------------------------------------
if ($RemoveState) {
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "removed $stateRoot (token, events, results, logs, staged extension)"
    }
    Write-Host 'Remember to remove the extension at chrome://extensions.' -ForegroundColor Yellow
} else {
    Write-Host "state left in place (pass -RemoveState to delete $stateRoot)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Project workspaces were not touched.' -ForegroundColor Green
