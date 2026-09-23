<#
.SYNOPSIS
    Sets up the gpt-loop state root, token, daemon config, and project registry on macOS.

.DESCRIPTION
    The macOS counterpart of install-windows.ps1. Idempotent: safe to re-run.
    Never overwrites an existing token or an existing project registry unless
    -Force is given.

    Creates:
      ~/Library/Application Support/GPTLoop/
        token.txt          random 256-bit token, mode 0600
        config/daemon.json port and runner supervision settings
        projects.json      the trusted project registry
        events/  results/  logs/

    It does NOT register the GitHub Actions runner (see scripts/register-runner-macos.ps1)
    and it does NOT configure Chrome.

    ## What actually differs from Windows, and what deliberately does not

    Only two things differ: where the state root lives, and how the token is
    restricted (POSIX mode instead of an ACL). Everything else -- the directory
    layout, the config keys, the registry shape, the refusal to guess an
    interpreter -- is identical on purpose. A port that also "improves" the
    layout produces two systems to reason about instead of one.

.EXAMPLE
    pwsh -File scripts/install-macos.ps1
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

if ($IsWindows) { throw 'this is the macOS installer; use scripts/install-windows.ps1' }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'runner/lib/Common.ps1')
. (Join-Path $repoRoot 'runner/lib/Registry.ps1')

# ⭐ Asked, never re-derived: Get-GptLoopStateRoot is the same function the
# dispatcher uses, so the installer cannot create a directory the runner will
# not read.
$stateRoot = Get-GptLoopStateRoot

Write-Host 'gpt-loop installer (macOS)' -ForegroundColor Cyan
Write-Host "  repo  : $repoRoot"
Write-Host "  state : $stateRoot"

foreach ($dir in @($stateRoot, (Join-Path $stateRoot 'config'), (Join-Path $stateRoot 'events'),
        (Join-Path $stateRoot 'results'), (Join-Path $stateRoot 'logs'))) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# --- token -------------------------------------------------------------------
$tokenPath = Join-Path $stateRoot 'token.txt'
if ((Test-Path -LiteralPath $tokenPath) -and -not $Force) {
    Write-Host '  token : already present (left unchanged)' -ForegroundColor DarkGray
} else {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    [IO.File]::WriteAllText($tokenPath, $token, [System.Text.UTF8Encoding]::new($false))
    Write-Host '  token : generated' -ForegroundColor Green
}

# ⛔ The token authorises driving a logged-in browser session, so it is not
# world-readable. The Windows script does this with an ACL; POSIX does it with
# a mode, and 0600 is the whole of it.
try {
    & chmod 600 $tokenPath
    $mode = (& stat -f '%Lp' $tokenPath).Trim()
    if ($mode -ne '600') { Write-Warning "token mode is $mode, expected 600" }
    else { Write-Host '  token : mode 0600' -ForegroundColor DarkGray }
} catch {
    Write-Warning "could not tighten the token permissions: $($_.Exception.Message)"
}

# --- daemon config -----------------------------------------------------------
$configPath = Join-Path $stateRoot 'config/daemon.json'
if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $RunnerDir = Join-Path $HOME 'actions-runner-gptloop'
}
$daemonConfig = [ordered]@{
    port                = $Port
    runner_dir          = $RunnerDir
    supervise_runner    = (-not $NoSuperviseRunner)
    claim_lease_seconds = 120
}
if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
    Write-Host '  config: already present (left unchanged)' -ForegroundColor DarkGray
} else {
    [IO.File]::WriteAllText($configPath, ($daemonConfig | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    Write-Host "  config: written (port $Port)" -ForegroundColor Green
}

# --- project registry --------------------------------------------------------
$registryPath = Join-Path $stateRoot 'projects.json'
$examplePath = Join-Path $repoRoot 'examples/python-project'
$exampleVenv = Join-Path $examplePath '.venv/bin/python'

if ((Test-Path -LiteralPath $registryPath) -and -not $Force) {
    Write-Host '  registry: already present (left unchanged)' -ForegroundColor DarkGray
} else {
    if (-not (Test-Path -LiteralPath $exampleVenv)) {
        Write-Host '  registry: creating the example fixture venv...' -ForegroundColor DarkGray
        # ⚠️ macOS ships no bare `python`, so `python3` is tried first. ⛔ Still
        # explicit: the control plane never infers an interpreter, it only
        # bootstraps its own bundled fixture.
        $python = $null
        foreach ($candidate in @('python3', 'python')) {
            $python = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($null -ne $python) { break }
        }
        if ($null -eq $python) { throw 'neither python3 nor python was found on PATH; cannot create the example fixture environment' }
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
Write-Host '  1. Register a self-hosted runner for your PRIVATE repository (GitHub > Settings > Actions > Runners; there is no macOS helper script yet)'
Write-Host '  2. Start the daemon:   python3 wake/daemon/gptloop_wake_daemon.py'
Write-Host '  3. Load the extension: chrome://extensions -> Load unpacked -> wake/extension'
Write-Host "  4. Configure it with the token from: $tokenPath"
