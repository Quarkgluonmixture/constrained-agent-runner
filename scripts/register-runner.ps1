<#
.SYNOPSIS
    Registers a dedicated self-hosted GitHub Actions runner for gpt-loop.

.DESCRIPTION
    Deliberately creates a SEPARATE runner instance in its own directory with its
    own name and labels. Runners registered to a repository only receive that
    repository's jobs, so an existing runner for another repo cannot serve
    gpt-loop -- and must not be repurposed while it is still in use.

    The registration token is obtained through the already-authenticated GitHub
    CLI and is short-lived; nothing persistent is written into source.

.PARAMETER Repo
    owner/name of the repository the runner serves.

.EXAMPLE
    pwsh -File scripts\register-runner.ps1 -Repo <you>/<your-private-copy>

    SECURITY: -Repo must be a PRIVATE repository. A self-hosted runner attached
    to a public repository lets anyone who opens a pull request run code on
    this machine.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [string]$RunnerDir = '',
    [string]$Name = '',
    [string]$Labels = 'gpt-loop',
    [string]$Version = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $env:USERPROFILE 'actions-runner-gptloop'
}
if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = "gptloop-$env:COMPUTERNAME"
}

if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) was not found on PATH'
}

Write-Host "Registering a gpt-loop runner" -ForegroundColor Cyan
Write-Host "  repo   : $Repo"
Write-Host "  dir    : $RunnerDir"
Write-Host "  name   : $Name"
Write-Host "  labels : self-hosted, windows, x64, $Labels"

if (Test-Path -LiteralPath (Join-Path $RunnerDir '.runner')) {
    Write-Host 'a runner is already configured in that directory; nothing to do' -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Force -Path $RunnerDir | Out-Null

# --- download the runner package --------------------------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
    $latest = gh api repos/actions/runner/releases/latest --jq '.tag_name' 2>$null
    if ([string]::IsNullOrWhiteSpace($latest)) { throw 'could not determine the latest runner version' }
    $Version = $latest.TrimStart('v')
}
$package = "actions-runner-win-x64-$Version.zip"
$archive = Join-Path $RunnerDir $package

if (-not (Test-Path -LiteralPath (Join-Path $RunnerDir 'config.cmd'))) {
    $url = "https://github.com/actions/runner/releases/download/v$Version/$package"
    Write-Host "  downloading $package ..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $RunnerDir -Force
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}

# --- short-lived registration token -----------------------------------------
Write-Host '  requesting a registration token ...' -ForegroundColor DarkGray
$token = gh api -X POST "repos/$Repo/actions/runners/registration-token" --jq '.token' 2>$null
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "could not obtain a registration token for $Repo (does the gh token have 'repo' scope?)"
}

$configCmd = Join-Path $RunnerDir 'config.cmd'
& $configCmd --unattended `
    --url "https://github.com/$Repo" `
    --token $token `
    --name $Name `
    --labels $Labels `
    --work '_work' `
    --replace

if ($LASTEXITCODE -ne 0) { throw "runner configuration failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Runner registered.' -ForegroundColor Green
Write-Host 'It is started and kept alive by the wake daemon (supervise_runner in config\daemon.json).'
Write-Host "Start it now with:  pwsh -File scripts\start-daemon.ps1"
