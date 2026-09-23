<#
.SYNOPSIS
    Canonical project-work reference regressions for the broker transport.
#>

[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

. (Join-Path $RepoRoot 'tests\lib\TestHarness.ps1')
. (Join-Path $RepoRoot 'tests\lib\DispatcherFixture.ps1')

$fixture = New-DispatcherFixture -RepoRoot $RepoRoot -CopyWorkspace

function Set-TestProjectBinding {
    param(
        [AllowNull()]$Repository,
        [bool]$RequireWorkRef = $false
    )

    $path = Join-Path $fixture.StateRoot 'projects.json'
    $registry = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    $entry = $registry.projects.'example-python'

    if ($null -eq $Repository) {
        [void]$entry.PSObject.Properties.Remove('repository')
    } else {
        $entry | Add-Member -NotePropertyName repository -NotePropertyValue ([string]$Repository) -Force
    }

    if ($RequireWorkRef) {
        $entry | Add-Member -NotePropertyName require_work_ref -NotePropertyValue $true -Force
    } else {
        [void]$entry.PSObject.Properties.Remove('require_work_ref')
    }

    $json = $registry | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

function New-WorkRefRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        $IssueNumber = $null,
        [string]$Path = ''
    )

    $req = New-JobRequest -Action 'ping'
    $ref = [ordered]@{ repository = $Repository }
    if ($null -ne $IssueNumber) { $ref['issue_number'] = $IssueNumber }
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $ref['path'] = $Path }
    $req['work_ref'] = $ref
    return $req
}

try {
    Invoke-TestCase 'W001' 'legacy packet may omit work_ref before project migration' {
        Set-TestProjectBinding -Repository 'example/example-python'
        $run = Invoke-Dispatcher -Fixture $fixture -Request (New-JobRequest -Action 'ping')
        Assert-Equal 'success' $run.Result.status
        Assert-True ($null -eq $run.Result.PSObject.Properties['work_ref']) 'legacy result should not invent a work_ref'
    }

    Invoke-TestCase 'W002' 'valid work_ref is normalized and echoed in the result' {
        Set-TestProjectBinding -Repository 'example/example-python'
        $req = New-WorkRefRequest -Repository 'example/example-python' -IssueNumber 42 -Path 'CHECKPOINT.md'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-Equal 'example/example-python' $run.Result.work_ref.repository
        Assert-Equal 42 ([int]$run.Result.work_ref.issue_number)
        Assert-Equal 'CHECKPOINT.md' $run.Result.work_ref.path
    }

    Invoke-TestCase 'W003' 'work_ref repository mismatch fails closed after registry binding' {
        Set-TestProjectBinding -Repository 'example/example-python'
        $req = New-WorkRefRequest -Repository 'example/other-project' -IssueNumber 42
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'does not match.*canonical repository'
    }

    Invoke-TestCase 'W004' 'repository comparison is case-insensitive but otherwise exact' {
        Set-TestProjectBinding -Repository 'Example/Example-Python'
        $req = New-WorkRefRequest -Repository 'example/example-python'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
    }

    Invoke-TestCase 'W005' 'require_work_ref rejects omission only after project opt-in' {
        Set-TestProjectBinding -Repository 'example/example-python' -RequireWorkRef $true
        $run = Invoke-Dispatcher -Fixture $fixture -Request (New-JobRequest -Action 'ping')
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'requires request.work_ref'
    }

    Invoke-TestCase 'W006' 'malformed repository identity is invalid_request' {
        Set-TestProjectBinding -Repository $null
        $req = New-WorkRefRequest -Repository '../not-a-repo'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'repository has an invalid form'
    }

    Invoke-TestCase 'W007' 'work_ref path cannot look like machine path authority' {
        Set-TestProjectBinding -Repository 'example/example-python'
        foreach ($bad in @('../CHECKPOINT.md', '/etc/passwd', 'C:\Windows\win.ini', 'docs\CHECKPOINT.md')) {
            $req = New-WorkRefRequest -Repository 'example/example-python' -Path $bad
            $run = Invoke-Dispatcher -Fixture $fixture -Request $req
            Assert-Equal 'invalid_request' $run.Result.status "work_ref path '$bad' must fail closed"
        }
    }

    Invoke-TestCase 'W008' 'invalid trusted registry repository binding is environment_error' {
        Set-TestProjectBinding -Repository '../broken-binding'
        $req = New-WorkRefRequest -Repository 'example/example-python'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'environment_error' $run.Result.status
        Assert-Match $run.Result.error 'invalid repository binding'
    }

    Invoke-TestCase 'W009' 'issue_number must be a positive integer' {
        Set-TestProjectBinding -Repository 'example/example-python'
        foreach ($bad in @(0, -1, 'abc')) {
            $req = New-WorkRefRequest -Repository 'example/example-python' -IssueNumber $bad
            $run = Invoke-Dispatcher -Fixture $fixture -Request $req
            Assert-Equal 'invalid_request' $run.Result.status "issue_number '$bad' must fail closed"
        }
    }

    Invoke-TestCase 'W010' 'work_ref must be an object' {
        Set-TestProjectBinding -Repository 'example/example-python'
        $req = New-JobRequest -Action 'ping'
        $req['work_ref'] = 'example/example-python'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'work_ref must be an object'
    }

    Invoke-TestCase 'W011' 'unknown work_ref fields fail closed like the schema says' {
        Set-TestProjectBinding -Repository 'example/example-python'
        $req = New-WorkRefRequest -Repository 'example/example-python'
        $req.work_ref['workspace'] = 'C:\Windows'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'unsupported field'
    }

} finally {
    Remove-DispatcherFixture $fixture
}

$failed = Write-TestSummary -Suite 'work-ref'
if ($failed -eq 0) {
    Write-Host 'work-ref tests passed' -ForegroundColor Green
    exit 0
}
exit 1
