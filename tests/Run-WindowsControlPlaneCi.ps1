<#
.SYNOPSIS
    Windows CI gate for shared GPT Loop control-plane changes.

.DESCRIPTION
    Runs the suites that are meaningful on the current Windows broker node.
    POSIX durable-worker execution is deliberately excluded because the durable
    implementation itself fails closed on Windows pending Phase-4 provenance
    support. `durable-static` remains required here so cross-file durable protocol
    invariants are still checked.

    The legacy dispatcher mega-suite currently contains T024, whose final doctor
    assertion is explicitly a non-Windows assertion but is not platform-guarded.
    Rather than turn a known test-harness bug into a fake product regression, this
    Windows gate drives the dispatcher end-to-end through the dedicated work-ref
    suite introduced by Phase 2A. T024 remains tracked debt and must be repaired
    before claiming the full legacy dispatcher suite is Windows-clean.
#>

[CmdletBinding()]
param(
    [string]$PythonExe = '',
    [string]$ContentScriptPython = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    $PythonExe = (Get-Command python -ErrorAction Stop).Source
}
if ([string]::IsNullOrWhiteSpace($ContentScriptPython)) {
    $ContentScriptPython = $PythonExe
}

$failures = 0
$summary = [System.Collections.Generic.List[object]]::new()

function Invoke-CiSuite {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    & $Body
    $code = $LASTEXITCODE
    $summary.Add([pscustomobject]@{ Suite = $Name; ExitCode = $code; Passed = ($code -eq 0) })
    if ($code -ne 0) { $script:failures++ }
}

Invoke-CiSuite 'schema-json' {
    & $PythonExe -m json.tool (Join-Path $repoRoot 'protocol\job.schema.json') | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $PythonExe -m json.tool (Join-Path $repoRoot 'protocol\result.schema.json') | Out-Null
    }
}

Invoke-CiSuite 'work-ref-dispatch' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\dispatcher\Run-WorkRefTests.ps1')
}

Invoke-CiSuite 'project-registry' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\registry\Run-ProjectRegistryTests.ps1')
}

Invoke-CiSuite 'project-provisioning' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\registry\Run-ProjectProvisioningTests.ps1')
}

Invoke-CiSuite 'durable-static' {
    & $PythonExe (Join-Path $repoRoot 'tests\durable\test_durable_static.py')
}

Invoke-CiSuite 'wake' {
    & $PythonExe (Join-Path $repoRoot 'tests\wake\test_wake_daemon.py')
}

Invoke-CiSuite 'integration' {
    & $PythonExe (Join-Path $repoRoot 'tests\integration\test_extension_protocol.py')
}

Invoke-CiSuite 'content-script' {
    & $ContentScriptPython (Join-Path $repoRoot 'tests\wake\test_content_script.py')
}

Write-Host ''
Write-Host '=== Windows CI summary ===' -ForegroundColor Cyan
foreach ($row in $summary) {
    $tag = if ($row.Passed) { 'PASS' } else { "FAIL ($($row.ExitCode))" }
    Write-Host ("  {0,-20} {1}" -f $row.Suite, $tag) -ForegroundColor $(if ($row.Passed) { 'Green' } else { 'Red' })
}

if ($failures -eq 0) {
    Write-Host ''
    Write-Host 'Windows control-plane gate passed.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "$failures Windows CI suite(s) failed." -ForegroundColor Red
exit 1
