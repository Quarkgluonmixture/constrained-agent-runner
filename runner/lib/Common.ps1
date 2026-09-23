# Common.ps1 -- shared primitives for the gpt-loop dispatcher.
#
# Everything here must be safe under `Set-StrictMode -Version Latest`. The old
# prototype dispatcher crashed when an optional JSON property was absent
# (see docs/TROUBLESHOOTING.md, "StrictMode optional property"), so optional
# access goes through Get-Prop and never through direct member access.

Set-StrictMode -Version Latest

# Result status taxonomy. Deliberately richer than ok/not-ok: a nonzero exit
# code is not automatically a quality failure.
$script:GptLoopStatus = @{
    Success          = 'success'           # action ran and met its success criteria
    Failure          = 'failure'           # action ran and genuinely failed
    Inapplicable     = 'inapplicable'      # action could not meaningfully apply (e.g. incompatible fixture)
    EnvironmentError = 'environment_error' # missing interpreter/tool: not the project's fault
    Denied           = 'denied'            # blocked by the permission model
    Timeout          = 'timeout'           # exceeded the action timeout
    InvalidRequest   = 'invalid_request'   # malformed or unknown request
    # ⭐ The executor was cut off by the account's own usage window, not by
    # anything about the job. ⚠️ Reporting this as `failure` is what makes the
    # brain spend a recovery round re-deriving a packet that was never judged:
    # the correct response is to WAIT for the reset and re-run the same packet,
    # so it needs a status of its own that no caller can read as a verdict.
    QuotaWait        = 'quota_wait'         # cut off by a usage/session limit; retry after the reset
}

# Holds the partial step captured when a child process is killed on timeout, so
# the error path can still report what the child managed to emit. Must be
# initialised here: reading an unset $script: variable throws under StrictMode.
$script:GptLoopLastStep = $null

# ⭐ The one place the dispatcher asks which platform it is on.
#
# gpt-loop was Windows-first, and the Windows assumptions were spread across
# four files: an executable-name convention, a state-root variable, a WMI
# process walk and `taskkill`. Each one is a different question, so each is
# answered by exactly one function below rather than by an `if ($IsWindows)`
# repeated at the call sites -- the second copy of a platform test is where a
# port rots.
function Get-PlatformExecutable {
    <#
    .SYNOPSIS
        The launchable name of a well-known tool on this platform.
    .DESCRIPTION
        `git.exe` does not exist on macOS, and `git` on Windows is a PATH shim
        that ProcessStartInfo cannot start without a shell. One name per
        platform, resolved here.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($IsWindows) { return "$Name.exe" }
    return $Name
}

function Get-Prop {
    <#
    .SYNOPSIS
        StrictMode-safe optional property read.
    .DESCRIPTION
        Returns $Default when the object is null, the property is absent, or the
        property exists but holds $null. Works for PSCustomObject (ConvertFrom-Json)
        and hashtables alike.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $Default }
        $value = $InputObject[$Name]
        if ($null -eq $value) { return $Default }
        return $value
    }

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Test-HasProp {
    # Distinguishes "absent" from "present but null/empty" where that matters.
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-IntProp {
    # Optional integer with range validation. Throws GptLoopDeniedException-free
    # plain errors that the dispatcher maps to invalid_request.
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Default,
        [int]$Min = [int]::MinValue,
        [int]$Max = [int]::MaxValue
    )
    $raw = Get-Prop $InputObject $Name $null
    if ($null -eq $raw) { return $Default }
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed)) {
        Throw-InvalidRequest "params.$Name must be an integer"
    }
    if ($parsed -lt $Min -or $parsed -gt $Max) {
        Throw-InvalidRequest "params.$Name must be between $Min and $Max"
    }
    return $parsed
}

function Limit-Text {
    param([string]$Text, [int]$Max = 45000)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n...[truncated]"
}

function Get-Sha256Hex {
    # AllowEmptyString: an empty issue body must hash to the well-defined digest
    # of "" and be rejected as invalid_request, not blow up parameter binding.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

function New-Step {
    <#
    .SYNOPSIS
        Builds one entry of the result `steps` array.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$ExitCode = 0,
        [int]$DurationMs = 0,
        [string]$Stdout = '',
        [string]$Stderr = '',
        [bool]$Truncated = $false
    )
    return [pscustomobject][ordered]@{
        name        = $Name
        exit_code   = $ExitCode
        duration_ms = $DurationMs
        stdout      = $Stdout
        stderr      = $Stderr
        truncated   = $Truncated
    }
}

# --- typed control-flow exceptions -------------------------------------------
# The dispatcher maps these onto result statuses. Using distinct exception
# "kinds" keeps `denied` from being reported as a generic `failure`.

function New-GptLoopError {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $ex = [System.Exception]::new($Message)
    $ex.Data['gptloop_status'] = $Status
    return $ex
}

function Throw-Denied {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw (New-GptLoopError $script:GptLoopStatus.Denied $Message)
}

function Throw-InvalidRequest {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw (New-GptLoopError $script:GptLoopStatus.InvalidRequest $Message)
}

function Throw-EnvironmentError {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw (New-GptLoopError $script:GptLoopStatus.EnvironmentError $Message)
}

function Throw-Timeout {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw (New-GptLoopError $script:GptLoopStatus.Timeout $Message)
}

function Get-ErrorStatus {
    # Recovers the tagged status from a caught error, defaulting to `failure`.
    param($ErrorRecord)
    $ex = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [System.Exception]) {
        $ex = $ErrorRecord
    }
    while ($null -ne $ex) {
        if ($ex.Data -and $ex.Data.Contains('gptloop_status')) {
            return [string]$ex.Data['gptloop_status']
        }
        $ex = $ex.InnerException
    }
    return $script:GptLoopStatus.Failure
}
