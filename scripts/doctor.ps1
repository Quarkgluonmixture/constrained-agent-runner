<#
.SYNOPSIS
    Reports the health of the whole gpt-loop installation.

.DESCRIPTION
    Designed so the system is diagnosable without reading source. Reports repo
    version, state directory, daemon health, runner status, configured projects,
    extension source version, pending/last events, and lock state.

    Secrets are never printed -- only whether they are present.

.EXAMPLE
    pwsh -File scripts\doctor.ps1
#>

[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'runner\lib\Common.ps1')
. (Join-Path $repoRoot 'runner\lib\Registry.ps1')

# One source of truth with the dispatcher, installers, and wake daemon. The old
# LOCALAPPDATA-only calculation made every subsequent check a false negative on
# macOS and Linux.
$stateRoot = Get-GptLoopStateRoot
$installHint = Get-GptLoopInstallHint
$runnerHint = if ($IsWindows) {
    'run scripts\register-runner.ps1'
} else {
    'register a macOS Actions runner and set config/daemon.json runner_dir'
}
$report = [ordered]@{}
$problems = [System.Collections.Generic.List[string]]::new()

function Add-Problem([string]$Message) { [void]$problems.Add($Message) }

# --- repo --------------------------------------------------------------------
$commit = ''
$branch = ''
try {
    $gitExe = Get-PlatformExecutable -Name 'git'
    $commit = (& $gitExe -C $repoRoot rev-parse --short HEAD 2>$null)
    $branch = (& $gitExe -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null)
} catch { }
$report['repo'] = [ordered]@{
    root   = $repoRoot
    branch = $branch
    commit = $commit
}

# --- state root --------------------------------------------------------------
$tokenPath = Join-Path $stateRoot 'token.txt'
$configPath = Join-Path $stateRoot 'config/daemon.json'
$registryPath = Join-Path $stateRoot 'projects.json'

$port = 8777
if (Test-Path -LiteralPath $configPath) {
    try { $port = [int](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).port } catch { }
}

$resultsDir = Join-Path $stateRoot 'results'
$resultCount = 0
if (Test-Path -LiteralPath $resultsDir) {
    $resultCount = @(Get-ChildItem -LiteralPath $resultsDir -Filter '*.json' -ErrorAction SilentlyContinue).Count
}

$report['state'] = [ordered]@{
    root           = $stateRoot
    exists         = (Test-Path -LiteralPath $stateRoot)
    token_present  = (Test-Path -LiteralPath $tokenPath)   # value never printed
    config_present = (Test-Path -LiteralPath $configPath)
    port           = $port
    stored_results = $resultCount
}
if (-not (Test-Path -LiteralPath $tokenPath)) { Add-Problem "no daemon token; $installHint" }

# --- projects ----------------------------------------------------------------
$projects = [ordered]@{}
if (Test-Path -LiteralPath $registryPath) {
    try {
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($prop in (Get-Prop $registry 'projects' ([pscustomobject]@{})).PSObject.Properties) {
            $entry = $prop.Value
            $workspace = [string](Get-Prop $entry 'workspace' '')
            $python = Get-Prop $entry 'python' $null
            $runtime = [string](Get-Prop $python 'runtime' '')
            $test = [string](Get-Prop $python 'test' '')
            $projects[$prop.Name] = [ordered]@{
                workspace        = $workspace
                workspace_exists = (Test-Path -LiteralPath $workspace -PathType Container)
                profile          = [string](Get-Prop $entry 'profile' 'generic')
                python_runtime   = if ($runtime) { if (Test-Path -LiteralPath $runtime) { 'configured' } else { 'MISSING FILE' } } else { 'not configured' }
                python_test      = if ($test) { if (Test-Path -LiteralPath $test) { 'configured' } else { 'MISSING FILE' } } else { 'not configured' }
                claude_enabled   = [bool](Get-Prop (Get-Prop $entry 'claude' $null) 'enabled' $false)
                codex_enabled    = [bool](Get-Prop (Get-Prop $entry 'codex' $null) 'enabled' $false)
            }
            if (-not $projects[$prop.Name].workspace_exists) {
                Add-Problem "project '$($prop.Name)': workspace does not exist"
            }
        }
    } catch {
        Add-Problem "project registry is unreadable: $($_.Exception.Message)"
    }
} else {
    Add-Problem "no project registry; $installHint"
}
$report['projects'] = $projects

# --- daemon ------------------------------------------------------------------
$daemon = [ordered]@{ reachable = $false }
if (Test-Path -LiteralPath $tokenPath) {
    try {
        $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -Headers @{ 'X-GPTLoop-Token' = $token } -TimeoutSec 5
        $daemon['reachable'] = $true
        $daemon['version'] = [string](Get-Prop $health 'daemon_version' '')
        $daemon['pending_count'] = [int](Get-Prop $health 'pending_count' 0)
        $daemon['total_events'] = [int](Get-Prop $health 'total_events' 0)
        $daemon['runner_online'] = Get-Prop $health 'runner_online' $null
        $last = Get-Prop $health 'last_acknowledged' $null
        $daemon['last_acknowledged'] = if ($null -ne $last) { [string](Get-Prop $last 'event_id' '') } else { '(none)' }
        if ([int]$daemon['pending_count'] -gt 0) {
            Add-Problem "$($daemon['pending_count']) wake event(s) pending delivery"
        }
        if ($daemon['runner_online'] -eq $false) { Add-Problem 'the GitHub Actions runner is offline' }
    } catch {
        $daemon['error'] = $_.Exception.Message
        Add-Problem "wake daemon is not reachable on 127.0.0.1:$port"
    }
}
$report['daemon'] = $daemon

# --- runner ------------------------------------------------------------------
$runnerDir = ''
if (Test-Path -LiteralPath $configPath) {
    try { $runnerDir = [string](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).runner_dir } catch { }
}
$listener = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)
$runnerInfo = [ordered]@{
    dir             = $runnerDir
    configured      = ($runnerDir -and (Test-Path -LiteralPath (Join-Path $runnerDir '.runner')))
    listener_count  = $listener.Count
}
if ($runnerInfo.configured) {
    try {
        $cfg = Get-Content -LiteralPath (Join-Path $runnerDir '.runner') -Raw | ConvertFrom-Json
        $runnerInfo['name'] = [string](Get-Prop $cfg 'agentName' '')
        $runnerInfo['scope'] = [string](Get-Prop $cfg 'gitHubUrl' '')
    } catch { }
}
if (-not $runnerInfo.configured) {
    Add-Problem "no gpt-loop runner is configured in $runnerDir; $runnerHint"
}
$report['runner'] = $runnerInfo

# --- extension ---------------------------------------------------------------
$manifestPath = Join-Path $repoRoot 'wake\extension\manifest.json'
$extension = [ordered]@{ source = $manifestPath }
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $extension['version'] = [string]$manifest.version
        $extension['name'] = [string]$manifest.name
        $extension['host_permissions'] = @($manifest.host_permissions)
    } catch { }
} else {
    Add-Problem 'extension source is missing'
}
$report['extension'] = $extension

# --- dispatcher lock ---------------------------------------------------------
$lockState = 'free'
try {
    $mutex = [System.Threading.Mutex]::new($false, 'Global\gpt-loop-dispatcher')
    if ($mutex.WaitOne(0)) { $mutex.ReleaseMutex() } else { $lockState = 'held (a job is running)' }
    $mutex.Dispose()
} catch {
    $lockState = "unknown: $($_.Exception.Message)"
}
$report['dispatcher_lock'] = $lockState

$report['problems'] = @($problems)
$report['healthy'] = ($problems.Count -eq 0)

# --- output ------------------------------------------------------------------
if ($Json) {
    $report | ConvertTo-Json -Depth 8
    exit $(if ($problems.Count -eq 0) { 0 } else { 1 })
}

function Write-Section([string]$Title) { Write-Host ''; Write-Host $Title -ForegroundColor Cyan }
function Write-Line([string]$Key, $Value, [string]$Colour = 'Gray') {
    Write-Host ("  {0,-20} {1}" -f $Key, $Value) -ForegroundColor $Colour
}

Write-Host 'gpt-loop doctor' -ForegroundColor White

Write-Section 'Repository'
Write-Line 'root' $report.repo.root
Write-Line 'branch' ("{0} @ {1}" -f $report.repo.branch, $report.repo.commit)

Write-Section 'State'
Write-Line 'root' $report.state.root
Write-Line 'token' $(if ($report.state.token_present) { 'present (not shown)' } else { 'MISSING' }) `
    $(if ($report.state.token_present) { 'Green' } else { 'Red' })
Write-Line 'port' $report.state.port
Write-Line 'stored results' $report.state.stored_results

Write-Section 'Daemon'
if ($report.daemon.reachable) {
    Write-Line 'status' ("up, v{0}" -f $report.daemon.version) 'Green'
    Write-Line 'events' ("{0} total, {1} pending" -f $report.daemon.total_events, $report.daemon.pending_count)
    Write-Line 'last delivered' $report.daemon.last_acknowledged
    Write-Line 'runner online' $report.daemon.runner_online
} else {
    Write-Line 'status' 'unreachable' 'Red'
}

Write-Section 'Runner'
Write-Line 'dir' $report.runner.dir
Write-Line 'configured' $report.runner.configured $(if ($report.runner.configured) { 'Green' } else { 'Red' })
Write-Line 'listeners' $report.runner.listener_count
if ($report.runner.Contains('name')) { Write-Line 'name' $report.runner.name }
if ($report.runner.Contains('scope')) { Write-Line 'scope' $report.runner.scope }

Write-Section 'Projects'
if ($projects.Count -eq 0) {
    Write-Line '(none)' ''
} else {
    foreach ($key in $projects.Keys) {
        $p = $projects[$key]
        Write-Host ("  {0}" -f $key) -ForegroundColor White
        Write-Line '  workspace' $p.workspace $(if ($p.workspace_exists) { 'Gray' } else { 'Red' })
        Write-Line '  profile' $p.profile
        Write-Line '  python.runtime' $p.python_runtime
        Write-Line '  python.test' $p.python_test
        Write-Line '  claude' $(if ($p.claude_enabled) { 'enabled' } else { 'disabled' })
        Write-Line '  codex' $(if ($p.codex_enabled) { 'enabled' } else { 'disabled' })
    }
}

Write-Section 'Extension'
Write-Line 'version' $(if ($extension.Contains('version')) { $extension.version } else { 'unknown' })
Write-Line 'source' $extension.source

Write-Section 'Dispatcher'
Write-Line 'lock' $report.dispatcher_lock

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$($problems.Count) problem(s):" -ForegroundColor Yellow
foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Yellow }
exit 1
