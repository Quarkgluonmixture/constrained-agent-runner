<#
.SYNOPSIS
    Sets up the gpt-loop state root, token, daemon config, and project registry.

.DESCRIPTION
    Idempotent: safe to re-run. Never overwrites an existing token or an existing
    project registry entry unless -Force is given.

    Creates:
      %LOCALAPPDATA%\GPTLoop\
        token.txt          random 256-bit token, ACL'd to the current user
        config\daemon.json port and runner supervision settings
        projects.json      the trusted project registry
        events\  results\  logs\

    It does NOT register the GitHub Actions runner (see scripts\register-runner.ps1)
    and it does NOT configure Chrome (see docs\WINDOWS_SETUP.md).

.EXAMPLE
    pwsh -File scripts\install-windows.ps1
#>

[CmdletBinding()]
param(
    [int]$Port = 8777,
    [string]$RunnerDir = '',
    [switch]$NoSuperviseRunner,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 'GPTLoop'

Write-Host "gpt-loop installer" -ForegroundColor Cyan
Write-Host "  repo  : $repoRoot"
Write-Host "  state : $stateRoot"

foreach ($dir in @($stateRoot, (Join-Path $stateRoot 'config'), (Join-Path $stateRoot 'events'),
        (Join-Path $stateRoot 'results'), (Join-Path $stateRoot 'logs'))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# --- token -------------------------------------------------------------------
$tokenPath = Join-Path $stateRoot 'token.txt'
if ((Test-Path -LiteralPath $tokenPath) -and -not $Force) {
    Write-Host "  token : already present (left unchanged)" -ForegroundColor DarkGray
} else {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    [IO.File]::WriteAllText($tokenPath, $token, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  token : generated" -ForegroundColor Green
}

# Current-user-only ACL on the token: it authorises driving a browser session.
try {
    $acl = Get-Acl -LiteralPath $tokenPath
    $acl.SetAccessRuleProtection($true, $false)   # drop inherited rules
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'None', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $tokenPath -AclObject $acl
    Write-Host "  acl   : restricted to $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Green
} catch {
    Write-Warning "could not tighten the token ACL: $($_.Exception.Message)"
}

# --- daemon config -----------------------------------------------------------
$configPath = Join-Path $stateRoot 'config\daemon.json'
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $env:USERPROFILE 'actions-runner-gptloop'
}
$daemonConfig = [ordered]@{
    port                = $Port
    runner_dir          = $RunnerDir
    supervise_runner    = (-not $NoSuperviseRunner)
    claim_lease_seconds = 120
}
if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    Write-Host "  config: already present (left unchanged)" -ForegroundColor DarkGray
} else {
    [IO.File]::WriteAllText($configPath, ($daemonConfig | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    Write-Host "  config: written (port $Port)" -ForegroundColor Green
}

# --- project registry --------------------------------------------------------
# Seeded with the bundled example so `doctor` and the acceptance run have a
# target on a fresh machine. Real projects are added by editing this file.
$registryPath = Join-Path $stateRoot 'projects.json'
$examplePath = Join-Path $repoRoot 'examples\python-project'
$exampleVenv = Join-Path $examplePath '.venv\Scripts\python.exe'

if ((Test-Path -LiteralPath $registryPath) -and -not $Force) {
    Write-Host "  registry: already present (left unchanged)" -ForegroundColor DarkGray
} else {
    if (-not (Test-Path -LiteralPath $exampleVenv)) {
        Write-Host "  registry: creating the example fixture venv..." -ForegroundColor DarkGray
        $python = (Get-Command python -ErrorAction SilentlyContinue)
        if ($null -eq $python) { throw 'python was not found on PATH; cannot create the example fixture environment' }
        & $python.Source -m venv (Join-Path $examplePath '.venv')
        & $exampleVenv -m pip install --quiet --disable-pip-version-check pytest
    }

    $registry = [ordered]@{
        version  = 1
        projects = [ordered]@{
            'example-python' = [ordered]@{
                workspace = $examplePath
                profile   = 'example-python'
                # Interpreters are explicit, per role. The control plane will
                # NEVER infer these from a .venv it happens to find.
                python    = [ordered]@{
                    runtime = $exampleVenv
                    test    = $exampleVenv
                }
                claude    = [ordered]@{
                    enabled                  = $false
                    permission_mode          = 'plan'
                    allowed_permission_modes = @('plan')
                    timeout_seconds          = 900
                    max_prompt_chars         = 8000
                }
                codex     = [ordered]@{
                    enabled           = $false
                    timeout_seconds   = 1800
                    max_prompt_chars  = 12000
                    sandbox           = 'workspace-write'
                    allowed_sandboxes = @('read-only', 'workspace-write')
                    model             = 'gpt-5.6-sol'
                    reasoning_effort  = 'high'
                    tiers             = [ordered]@{
                        doc  = [ordered]@{
                            model            = 'gpt-5.6-sol'
                            reasoning_effort = 'high'
                            sandbox          = 'read-only'
                        }
                        code = [ordered]@{
                            model            = 'gpt-5.6-sol'
                            reasoning_effort = 'high'
                            sandbox          = 'workspace-write'
                        }
                    }
                }
            }
        }
    }
    [IO.File]::WriteAllText($registryPath, ($registry | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Write-Host "  registry: seeded with 'example-python'" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Register a runner:  pwsh -File scripts\register-runner.ps1'
Write-Host '  2. Start the daemon:   pwsh -File scripts\start-daemon.ps1'
Write-Host '  3. Load the extension: chrome://extensions -> Load unpacked -> wake\extension'
Write-Host "  4. Configure it with the token from: $tokenPath"
Write-Host '  5. Check everything:   pwsh -File scripts\doctor.ps1'
