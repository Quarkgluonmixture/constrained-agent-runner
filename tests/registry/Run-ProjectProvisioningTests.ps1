[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $repoRoot 'scripts/project-registry.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("gptloop-provision-tests-" + [Guid]::NewGuid().ToString('N'))
$registryPath = Join-Path $tempRoot 'projects.json'
$workspaceGood = Join-Path $tempRoot 'good-workspace'
$workspaceMismatch = Join-Path $tempRoot 'mismatch-workspace'
$workspaceNoOrigin = Join-Path $tempRoot 'no-origin-workspace'
$oldStateRoot = $env:GPTLOOP_STATE_ROOT

$script:passed = 0
$script:failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-HelperSuccess($Result, [string]$Message) {
    if ([int]$Result.ExitCode -ne 0) {
        throw "$Message (exit $($Result.ExitCode))`n--- child output ---`n$($Result.Output)"
    }
}

function Write-Fixture {
    Get-ChildItem -LiteralPath $tempRoot -Filter 'projects.json.bak-*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $fixture = [ordered]@{
        version = 1
        projects = [ordered]@{
            existing = [ordered]@{
                workspace = $workspaceGood
                profile = 'generic'
            }
        }
    }
    [IO.File]::WriteAllText(
        $registryPath,
        ($fixture | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-Fixture {
    return (Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
}

function Get-BackupCount {
    return @(Get-ChildItem -LiteralPath $tempRoot -Filter 'projects.json.bak-*' -ErrorAction SilentlyContinue).Count
}

function Invoke-Helper([string[]]$Arguments) {
    $output = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $helper @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $code
        Output = ($output -join "`n")
    }
}

function Run-Test([string]$Id, [string]$Name, [scriptblock]$Body) {
    try {
        Write-Fixture
        & $Body
        $script:passed++
        Write-Host "[PASS] $Id $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "[FAIL] $Id $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Initialize-GitWorkspace([string]$Path, [string]$Origin = '') {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    & git -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init failed for $Path" }
    if (-not [string]::IsNullOrWhiteSpace($Origin)) {
        & git -C $Path remote add origin $Origin
        if ($LASTEXITCODE -ne 0) { throw "git remote add failed for $Path" }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    Initialize-GitWorkspace $workspaceGood 'git@github.com:Owner/Good.git'
    Initialize-GitWorkspace $workspaceMismatch 'https://github.com/Owner/Other.git'
    Initialize-GitWorkspace $workspaceNoOrigin
    $env:GPTLOOP_STATE_ROOT = $tempRoot

    Run-Test 'P001' 'minimal provisioning verifies origin and writes only baseline authority' {
        $result = Invoke-Helper @(
            '-ProjectKey', 'good',
            '-ProvisionWorkspace', $workspaceGood,
            '-BindRepository', 'Owner/Good',
            '-Confirm:$false'
        )
        Assert-HelperSuccess $result 'valid provisioning should succeed'
        $after = Read-Fixture
        $entry = $after.projects.good
        Assert-Equal $entry.repository 'Owner/Good' 'canonical repository should be written'
        Assert-Equal $entry.profile 'generic' 'new project should start on generic profile'
        Assert-Equal ([bool]$entry.require_work_ref) $false 'work_ref enforcement must start disabled'
        Assert-Equal @($entry.allowed_roots).Count 0 'new project should receive no allowed roots'
        Assert-Equal @($entry.allowed_files).Count 0 'new project should receive no allowed files'
        Assert-True (-not $entry.Contains('python')) 'provisioning must not invent Python interpreters'
        Assert-True (-not $entry.Contains('claude')) 'provisioning must not grant Claude executor capability'
        Assert-True (-not $entry.Contains('codex')) 'provisioning must not grant Codex executor capability'
        Assert-Equal (Get-BackupCount) 1 'successful provisioning should create one backup'
    }

    Run-Test 'P002' 'existing logical project key cannot be overwritten' {
        $before = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
        $result = Invoke-Helper @(
            '-ProjectKey', 'existing',
            '-ProvisionWorkspace', $workspaceGood,
            '-BindRepository', 'Owner/Good',
            '-Confirm:$false'
        )
        Assert-True ($result.ExitCode -ne 0) 'existing key must fail closed'
        $after = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
        Assert-Equal $after $before 'existing-key failure must leave registry unchanged'
        Assert-Equal (Get-BackupCount) 0 'failed preflight must not create a backup'
    }

    Run-Test 'P003' 'missing workspace cannot be provisioned' {
        $result = Invoke-Helper @(
            '-ProjectKey', 'missing',
            '-ProvisionWorkspace', (Join-Path $tempRoot 'does-not-exist'),
            '-BindRepository', 'Owner/Missing',
            '-Confirm:$false'
        )
        Assert-True ($result.ExitCode -ne 0) 'missing workspace must fail'
        $after = Read-Fixture
        Assert-True (-not $after.projects.Contains('missing')) 'missing workspace must not create a key'
    }

    Run-Test 'P004' 'workspace origin mismatch fails closed' {
        $result = Invoke-Helper @(
            '-ProjectKey', 'mismatch',
            '-ProvisionWorkspace', $workspaceMismatch,
            '-BindRepository', 'Owner/Expected',
            '-Confirm:$false'
        )
        Assert-True ($result.ExitCode -ne 0) 'origin mismatch must fail'
        Assert-True ($result.Output -match 'does not match requested repository') 'mismatch should be explicit'
        $after = Read-Fixture
        Assert-True (-not $after.projects.Contains('mismatch')) 'mismatch must not create a key'
    }

    Run-Test 'P005' 'Git workspace without origin cannot be provisioned' {
        $result = Invoke-Helper @(
            '-ProjectKey', 'no-origin',
            '-ProvisionWorkspace', $workspaceNoOrigin,
            '-BindRepository', 'Owner/NoOrigin',
            '-Confirm:$false'
        )
        Assert-True ($result.ExitCode -ne 0) 'missing origin must fail'
        $after = Read-Fixture
        Assert-True (-not $after.projects.Contains('no-origin')) 'missing origin must not create a key'
    }

    Run-Test 'P006' 'malformed canonical repository is rejected before mutation' {
        $result = Invoke-Helper @(
            '-ProjectKey', 'bad-repo',
            '-ProvisionWorkspace', $workspaceGood,
            '-BindRepository', '../bad',
            '-Confirm:$false'
        )
        Assert-True ($result.ExitCode -ne 0) 'malformed repository must fail'
        Assert-Equal (Get-BackupCount) 0 'malformed repository must not create backup'
    }

    Run-Test 'P007' 'provisioned project appears in sanitized listing' {
        $provision = Invoke-Helper @(
            '-ProjectKey', 'good',
            '-ProvisionWorkspace', $workspaceGood,
            '-BindRepository', 'Owner/Good',
            '-Confirm:$false'
        )
        Assert-HelperSuccess $provision 'setup provisioning should succeed'
        $list = Invoke-Helper @('-List', '-Json')
        Assert-HelperSuccess $list 'listing should succeed after provisioning'
        $rows = @($list.Output | ConvertFrom-Json)
        $row = @($rows | Where-Object { $_.project -eq 'good' })[0]
        Assert-Equal $row.repository 'Owner/Good' 'listing should expose canonical repository'
        Assert-Equal ([bool]$row.workspace_exists) $true 'listing should report healthy workspace'
        Assert-Equal ([bool]$row.require_work_ref) $false 'listing should report enforcement disabled'
    }

} finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:GPTLOOP_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:GPTLOOP_STATE_ROOT = $oldStateRoot }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "project-provisioning: $script:passed passed, $script:failed failed, $($script:passed + $script:failed) total"
if ($script:failed -eq 0) {
    Write-Host 'project provisioning tests passed' -ForegroundColor Green
    exit 0
}
exit 1
