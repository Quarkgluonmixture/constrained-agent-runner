<#
.SYNOPSIS
    Runs every gpt-loop regression suite and reports one verdict.

.DESCRIPTION
    Core suites, no external test dependencies except the optional content-script
    browser test:
      * dispatcher           -- PowerShell, drives runner\dispatch.ps1 in child processes
      * work-ref             -- PowerShell, broker -> canonical project ownership binding
      * project-registry     -- PowerShell, safe machine-local repository binding migration
      * project-provisioning -- PowerShell, safe minimal registration of existing Git workspaces
      * durable-worker       -- Python stdlib, persistent execution/job ownership
      * durable-static       -- Python stdlib, cross-file durable control-plane invariants
      * wake                 -- Python stdlib unittest, the delivery state machine
      * integration          -- Python stdlib unittest, the extension<->daemon protocol

.PARAMETER PythonExe
    Interpreter for the Python suites. Defaults to whichever of `python3` /
    `python` is on PATH; the suites import nothing outside the standard library.
    ⚠️ `python3` is tried first because macOS ships no bare `python`, and
    failing there would look like a broken suite rather than a naming difference.
#>

[CmdletBinding()]
param(
    [string]$PythonExe = '',
    # The content-script suite needs Playwright, which usually lives in a
    # different interpreter from the stdlib-only suites.
    [string]$ContentScriptPython = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0
$summary = [System.Collections.Generic.List[object]]::new()

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    $cmd = $null
    foreach ($candidate in @('python3', 'python')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { break }
    }
    if ($null -eq $cmd) { throw 'neither python3 nor python was found on PATH; pass -PythonExe' }
    $PythonExe = $cmd.Source
}
if ([string]::IsNullOrWhiteSpace($ContentScriptPython)) { $ContentScriptPython = $PythonExe }

function Invoke-Suite {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    & $Body
    $code = $LASTEXITCODE
    $summary.Add([pscustomobject]@{ Suite = $Name; ExitCode = $code; Passed = ($code -eq 0) })
    if ($code -ne 0) { $script:failures++ }
}

Invoke-Suite 'dispatcher' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\dispatcher\Run-DispatcherTests.ps1')
}

Invoke-Suite 'work-ref' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\dispatcher\Run-WorkRefTests.ps1')
}

Invoke-Suite 'project-registry' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\registry\Run-ProjectRegistryTests.ps1')
}

Invoke-Suite 'project-provisioning' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\registry\Run-ProjectProvisioningTests.ps1')
}

Invoke-Suite 'durable-worker' {
    & $PythonExe (Join-Path $repoRoot 'tests\durable\test_durable_job.py')
}

Invoke-Suite 'durable-static' {
    & $PythonExe (Join-Path $repoRoot 'tests\durable\test_durable_static.py')
}

Invoke-Suite 'wake' {
    & $PythonExe (Join-Path $repoRoot 'tests\wake\test_wake_daemon.py')
}

Invoke-Suite 'integration' {
    & $PythonExe (Join-Path $repoRoot 'tests\integration\test_extension_protocol.py')
}

# Optional: drives the real content.js in a headless browser against a mock
# ChatGPT composer. Skips cleanly (exit 0) when Playwright is unavailable, since
# it is the only suite with a dependency outside the standard library.
Invoke-Suite 'content-script' {
    & $ContentScriptPython (Join-Path $repoRoot 'tests\wake\test_content_script.py')
}

Write-Host ''
Write-Host '=== summary ===' -ForegroundColor Cyan
foreach ($row in $summary) {
    $tag = if ($row.Passed) { 'PASS' } else { "FAIL ($($row.ExitCode))" }
    Write-Host ("  {0,-22} {1}" -f $row.Suite, $tag) -ForegroundColor $(if ($row.Passed) { 'Green' } else { 'Red' })
}

if ($failures -eq 0) {
    Write-Host ''
    Write-Host 'All suites passed.' -ForegroundColor Green
    exit 0
}
Write-Host ''
Write-Host "$failures suite(s) failed." -ForegroundColor Red
exit 1
