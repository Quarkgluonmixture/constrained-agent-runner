[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $repoRoot 'scripts/project-registry.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("gptloop-registry-tests-" + [Guid]::NewGuid().ToString('N'))
$workspaceAlpha = Join-Path $tempRoot 'alpha-workspace'
$workspaceBeta = Join-Path $tempRoot 'beta-workspace'
$registryPath = Join-Path $tempRoot 'projects.json'
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
            alpha = [ordered]@{
                workspace = $workspaceAlpha
                profile = 'generic'
                marker = [ordered]@{ keep = 'alpha-secret-shape' }
            }
            beta = [ordered]@{
                workspace = $workspaceBeta
                repository = 'Owner/Beta'
                require_work_ref = $false
                profile = 'generic'
                marker = [ordered]@{ keep = 'beta-secret-shape' }
            }
            stale = [ordered]@{
                workspace = (Join-Path $tempRoot 'missing-workspace')
                profile = 'generic'
                marker = [ordered]@{ keep = 'stale-secret-shape' }
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

try {
    New-Item -ItemType Directory -Force -Path $workspaceAlpha, $workspaceBeta | Out-Null
    $env:GPTLOOP_STATE_ROOT = $tempRoot

    Run-Test 'R001' 'list is sanitized and reports workspace health' {
        $result = Invoke-Helper @('-List', '-Json')
        Assert-HelperSuccess $result 'list command should succeed'
        $rows = @($result.Output | ConvertFrom-Json)
        Assert-Equal $rows.Count 3 'list should contain all registered projects'
        $alpha = @($rows | Where-Object { $_.project -eq 'alpha' })[0]
        $stale = @($rows | Where-Object { $_.project -eq 'stale' })[0]
        Assert-Equal $alpha.repository '' 'unbound project should show empty repository'
        Assert-Equal ([bool]$alpha.require_work_ref) $false 'missing requirement should render false'
        Assert-Equal ([bool]$alpha.workspace_exists) $true 'existing workspace should be reported healthy'
        Assert-Equal ([bool]$stale.workspace_exists) $false 'missing workspace should be reported unhealthy'
        Assert-True (-not ($alpha.PSObject.Properties.Name -contains 'marker')) 'listing must not dump arbitrary registry fields'
    }

    Run-Test 'R002' 'binding adds only repository provenance and creates a backup' {
        $before = Read-Fixture
        $result = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', 'Owner/Alpha', '-Confirm:$false')
        Assert-HelperSuccess $result 'valid binding should succeed'
        $after = Read-Fixture
        Assert-Equal $after.projects.alpha.repository 'Owner/Alpha' 'repository should be written'
        Assert-Equal $after.projects.alpha.marker.keep $before.projects.alpha.marker.keep 'unrelated project fields must be preserved'
        Assert-Equal $after.projects.alpha.workspace $before.projects.alpha.workspace 'workspace must not change'
        Assert-True (-not $after.projects.alpha.Contains('require_work_ref')) 'binding must not silently add enforcement'
        Assert-Equal (Get-BackupCount) 1 'one mutation should create one backup'
    }

    Run-Test 'R003' 'same binding is idempotent and does not create another backup' {
        $first = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', 'Owner/Alpha', '-Confirm:$false')
        Assert-HelperSuccess $first 'first binding should succeed'
        $backups = Get-BackupCount
        $second = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', 'owner/alpha', '-Confirm:$false')
        Assert-HelperSuccess $second 'case-insensitive same binding should succeed'
        Assert-True ($second.Output -match 'already bound') 'idempotent path should say no change'
        Assert-Equal (Get-BackupCount) $backups 'idempotent path must not write a new backup'
    }

    Run-Test 'R004' 'rebind to a different repository fails closed' {
        $first = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', 'Owner/Alpha', '-Confirm:$false')
        Assert-HelperSuccess $first 'initial binding should succeed'
        $backups = Get-BackupCount
        $result = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', 'Owner/Other', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'different rebind must fail'
        $after = Read-Fixture
        Assert-Equal $after.projects.alpha.repository 'Owner/Alpha' 'failed rebind must preserve original repository'
        Assert-Equal (Get-BackupCount) $backups 'failed preflight must not create a backup'
    }

    Run-Test 'R005' 'malformed repository identity is rejected before mutation' {
        $result = Invoke-Helper @('-ProjectKey', 'alpha', '-BindRepository', '../oops', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'malformed repository must fail'
        $after = Read-Fixture
        Assert-True (-not $after.projects.alpha.Contains('repository')) 'malformed input must not mutate project entry'
        Assert-Equal (Get-BackupCount) 0 'malformed input must not create a backup'
    }

    Run-Test 'R006' 'stale workspace cannot receive a repository binding' {
        $result = Invoke-Helper @('-ProjectKey', 'stale', '-BindRepository', 'Owner/Stale', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'stale workspace should fail normal trusted resolution'
        $after = Read-Fixture
        Assert-True (-not $after.projects.stale.Contains('repository')) 'stale project must remain unbound'
    }

    Run-Test 'R007' 'require_work_ref cannot change before repository binding exists' {
        $result = Invoke-Helper @('-ProjectKey', 'alpha', '-SetWorkRefRequirement', 'disabled', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'requirement operation without repository binding must fail'
        $after = Read-Fixture
        Assert-True (-not $after.projects.alpha.Contains('require_work_ref')) 'failed requirement operation must not add a field'
    }

    Run-Test 'R008' 'enabling require_work_ref needs explicit proven-ingress confirmation' {
        $result = Invoke-Helper @('-ProjectKey', 'beta', '-SetWorkRefRequirement', 'enabled', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'enable without proof flag must fail'
        $after = Read-Fixture
        Assert-Equal ([bool]$after.projects.beta.require_work_ref) $false 'failed enable must preserve disabled state'
        Assert-Equal (Get-BackupCount) 0 'failed enable must not create a backup'
    }

    Run-Test 'R009' 'confirmed enforcement enable is atomic and preserves unrelated fields' {
        $before = Read-Fixture
        $result = Invoke-Helper @('-ProjectKey', 'beta', '-SetWorkRefRequirement', 'enabled', '-ConfirmIngressProven', '-Confirm:$false')
        Assert-HelperSuccess $result 'confirmed enable should succeed'
        $after = Read-Fixture
        Assert-Equal ([bool]$after.projects.beta.require_work_ref) $true 'require_work_ref should become true'
        Assert-Equal $after.projects.beta.repository $before.projects.beta.repository 'repository binding must be preserved'
        Assert-Equal $after.projects.beta.marker.keep $before.projects.beta.marker.keep 'unrelated fields must be preserved'
        Assert-Equal (Get-BackupCount) 1 'confirmed mutation should create one backup'
    }

    Run-Test 'R010' 'enforcement can be disabled without proof flag' {
        $enable = Invoke-Helper @('-ProjectKey', 'beta', '-SetWorkRefRequirement', 'enabled', '-ConfirmIngressProven', '-Confirm:$false')
        Assert-HelperSuccess $enable 'setup enable should succeed'
        $result = Invoke-Helper @('-ProjectKey', 'beta', '-SetWorkRefRequirement', 'disabled', '-Confirm:$false')
        Assert-HelperSuccess $result 'disable should succeed without proof flag'
        $after = Read-Fixture
        Assert-Equal ([bool]$after.projects.beta.require_work_ref) $false 'require_work_ref should return false'
    }

    Run-Test 'R011' 'unknown project key fails without registry mutation' {
        $before = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
        $result = Invoke-Helper @('-ProjectKey', 'missing', '-BindRepository', 'Owner/Missing', '-Confirm:$false')
        Assert-True ($result.ExitCode -ne 0) 'unknown project should fail'
        $after = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
        Assert-Equal $after $before 'unknown project must leave registry bytes unchanged'
        Assert-Equal (Get-BackupCount) 0 'unknown project must not create a backup'
    }

} finally {
    if ($null -eq $oldStateRoot) { Remove-Item Env:GPTLOOP_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:GPTLOOP_STATE_ROOT = $oldStateRoot }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "project-registry: $script:passed passed, $script:failed failed, $($script:passed + $script:failed) total"
if ($script:failed -eq 0) {
    Write-Host 'project registry migration tests passed' -ForegroundColor Green
    exit 0
}
exit 1
