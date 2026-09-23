<#
.SYNOPSIS
    Starts the gpt-loop wake daemon in the background.

.DESCRIPTION
    The daemon is standard-library Python, so any reasonably recent interpreter
    works. -PythonExe pins one explicitly; otherwise `python` on PATH is used
    (acceptable here because the daemon has no third-party dependencies -- the
    "never guess an interpreter" rule exists for PROJECT code, which does).

    Use -Register to also install a per-user logon task so the daemon comes back
    after a reboot.
#>

[CmdletBinding()]
param(
    [string]$PythonExe = '',
    [switch]$Register,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 'GPTLoop'
$daemonScript = Join-Path $repoRoot 'wake\daemon\gptloop_wake_daemon.py'
$taskName = 'GPTLoopWakeDaemon'

function Get-DaemonPort {
    $configPath = Join-Path $stateRoot 'config\daemon.json'
    if (Test-Path -LiteralPath $configPath) {
        try { return [int](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).port } catch { }
    }
    return 8777
}

$port = Get-DaemonPort

if ($Stop) {
    $listeners = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($null -eq $listeners) {
        Write-Host "nothing is listening on 127.0.0.1:$port"
        exit 0
    }
    foreach ($listener in $listeners) {
        Write-Host "stopping PID $($listener.OwningProcess)"
        Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    # pythonw.exe runs without a console window, which suits a background daemon.
    $python = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue }
    if ($null -eq $python) { throw 'no Python interpreter found on PATH; pass -PythonExe' }
    $PythonExe = $python.Source
}

if (-not (Test-Path -LiteralPath $daemonScript)) { throw "daemon script not found: $daemonScript" }

$existing = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Write-Host "a process is already listening on 127.0.0.1:$port (PID $($existing[0].OwningProcess))" -ForegroundColor Yellow
    Write-Host 'use -Stop first if you want to restart it'
    exit 0
}

New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'logs') | Out-Null
$stdout = Join-Path $stateRoot 'logs\daemon.out.log'

Start-Process -FilePath $PythonExe -ArgumentList @($daemonScript) `
    -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError (Join-Path $stateRoot 'logs\daemon.err.log')

Start-Sleep -Seconds 2
$check = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($null -eq $check) {
    Write-Host 'daemon did not come up; see:' -ForegroundColor Red
    Write-Host "  $stdout"
    exit 1
}
Write-Host "wake daemon listening on 127.0.0.1:$port (PID $($check[0].OwningProcess))" -ForegroundColor Green

if ($Register) {
    # A logon task (not a service) keeps this admin-free and in the user's
    # session, which the runner supervision and Chrome interaction both need.
    $action = New-ScheduledTaskAction -Execute $PythonExe -Argument "`"$daemonScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description 'gpt-loop wake daemon' -Force | Out-Null
    Write-Host "registered logon task '$taskName'" -ForegroundColor Green
}
