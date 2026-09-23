<#
.SYNOPSIS
    Stages the Chrome extension into the state root with its local config seeded.

.DESCRIPTION
    Chrome loads an unpacked extension from a fixed path and remembers that path,
    so the extension is staged at a stable location OUTSIDE the git checkout:

        %LOCALAPPDATA%\GPTLoop\extension

    That keeps a machine-local `config.local.json` (token + private conversation
    URL) out of the repository entirely, and means a `git pull` cannot silently
    change what Chrome is running -- re-run this script to publish an update.

    Re-run after changing extension source, then press Reload on
    chrome://extensions.

.PARAMETER TargetUrl
    The ChatGPT conversation the brain lives in. Stored locally only.

.EXAMPLE
    pwsh -File scripts\stage-extension.ps1 -TargetUrl https://chatgpt.com/c/xxxx
#>

[CmdletBinding()]
param(
    [string]$TargetUrl = '',
    [string]$Destination = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 'GPTLoop'
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $stateRoot 'extension'
}

$source = Join-Path $repoRoot 'wake\extension'
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "extension source not found: $source"
}

$tokenPath = Join-Path $stateRoot 'token.txt'
if (-not (Test-Path -LiteralPath $tokenPath)) {
    throw "no daemon token; run scripts\install-windows.ps1 first"
}
$token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()

$port = 8777
$configPath = Join-Path $stateRoot 'config\daemon.json'
if (Test-Path -LiteralPath $configPath) {
    try { $port = [int](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).port } catch { }
}

# Preserve an existing target URL across re-stages unless a new one is given.
$existingSeed = Join-Path $Destination 'config.local.json'
if ([string]::IsNullOrWhiteSpace($TargetUrl) -and (Test-Path -LiteralPath $existingSeed)) {
    try { $TargetUrl = [string](Get-Content -LiteralPath $existingSeed -Raw | ConvertFrom-Json).targetUrl } catch { }
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Get-ChildItem -LiteralPath $source -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force
}

$seed = [ordered]@{
    baseUrl   = "http://127.0.0.1:$port"
    token     = $token
    targetUrl = $TargetUrl
}
[IO.File]::WriteAllText($existingSeed, ($seed | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))

# The seed file carries the daemon token; keep it to the current user.
try {
    $acl = Get-Acl -LiteralPath $existingSeed
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'None', 'None', 'Allow'))
    Set-Acl -LiteralPath $existingSeed -AclObject $acl
} catch {
    Write-Warning "could not tighten the seed-file ACL: $($_.Exception.Message)"
}

$manifest = Get-Content -LiteralPath (Join-Path $Destination 'manifest.json') -Raw | ConvertFrom-Json

Write-Host 'Extension staged.' -ForegroundColor Green
Write-Host "  path    : $Destination"
Write-Host "  version : $($manifest.version)"
Write-Host "  daemon  : http://127.0.0.1:$port"
Write-Host "  target  : $(if ($TargetUrl) { $TargetUrl } else { '(not set -- configure in the options page)' })"
Write-Host ''
Write-Host 'In Chrome:' -ForegroundColor Cyan
Write-Host '  1. open  chrome://extensions'
Write-Host '  2. turn on "Developer mode" (top right)'
Write-Host '  3. click "Load unpacked"'
Write-Host "  4. select exactly this folder:  $Destination"
Write-Host ''
Write-Host 'No further configuration is needed; the token and conversation URL are seeded.'
