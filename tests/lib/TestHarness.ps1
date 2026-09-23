# TestHarness.ps1 -- dependency-light assertion + runner helpers.
#
# The machine only ships Pester 3.4.0, whose syntax diverges sharply from modern
# Pester, and the control plane should not acquire a test dependency merely to
# test itself. This harness is a few dozen lines of plain PowerShell.

Set-StrictMode -Version Latest

$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:CurrentCase = ''

function Start-TestCase {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Name)
    $script:CurrentCase = "$Id $Name"
}

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Detail = ''
    )
    $script:TestResults.Add([pscustomobject]@{
            Id     = $Id
            Name   = $Name
            Passed = $Passed
            Detail = $Detail
        })
    $tag = if ($Passed) { 'PASS' } else { 'FAIL' }
    $colour = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} {2}" -f $tag, $Id, $Name) -ForegroundColor $colour
    if (-not $Passed -and $Detail) {
        Write-Host ("       {0}" -f $Detail) -ForegroundColor DarkYellow
    }
}

function Invoke-TestCase {
    <#
    .SYNOPSIS
        Runs one test body, converting an exception into a failure result.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    try {
        & $Body
        Add-TestResult -Id $Id -Name $Name -Passed $true
    } catch {
        Add-TestResult -Id $Id -Name $Name -Passed $false -Detail $_.Exception.Message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") {
        throw "expected '$Expected' but got '$Actual'. $Because"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because = '')
    if (-not $Condition) { throw "expected true. $Because" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -notmatch $Pattern) {
        throw "expected text to match /$Pattern/ but got: $(Limit-TestText $Text). $Because"
    }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -match $Pattern) {
        throw "expected text NOT to match /$Pattern/ but it did: $(Limit-TestText $Text). $Because"
    }
}

function Limit-TestText {
    param([string]$Text, [int]$Max = 400)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

function Write-TestSummary {
    param([string]$Suite = 'gpt-loop')
    $passed = @($script:TestResults | Where-Object { $_.Passed }).Count
    $failed = @($script:TestResults | Where-Object { -not $_.Passed }).Count
    Write-Host ''
    Write-Host ("{0}: {1} passed, {2} failed, {3} total" -f $Suite, $passed, $failed, $script:TestResults.Count) `
        -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
    return $failed
}

function Get-TestResults { return $script:TestResults }

function Get-ProcessCountByName {
    <#
    .SYNOPSIS
        Live processes whose executable name matches, on either platform.
    .DESCRIPTION
        ⚠️ `Get-Process -Name` is cross-platform in PowerShell 7, ⛔ unlike the
        WMI query this replaced. The name is matched without an extension, which
        is what `Get-Process` expects on both platforms.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
}
