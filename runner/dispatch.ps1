<#
.SYNOPSIS
    gpt-loop constrained job dispatcher.

.DESCRIPTION
    Reads one immutable broker job request (captured from the GitHub
    `issues.opened` event), validates it against the protocol, resolves the
    project through the trusted local registry, validates any non-authorizing
    canonical work reference, executes exactly one allowlisted action, and
    writes a structured result.

    Two result files are produced:
      * $ResultPath        -- bounded, safe to paste into a GitHub comment
      * <state>\results\<job_id>.json -- complete, local only

    Execution is serialised by a machine-level mutex so two jobs can never
    interleave in the same workspace. Jobs WAIT for the lock; they are never
    silently discarded.

.NOTES
    The broker envelope is untrusted. It selects a project *key*, never a path.
    work_ref is provenance metadata only and can never select a workspace.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [int]$IssueNumber = 0,
    [string]$StateRoot = '',
    [string]$RepoRoot = '',
    [int]$LockTimeoutSeconds = 3600,
    [int]$CommentCharBudget = 55000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\SafePath.ps1')
. (Join-Path $PSScriptRoot 'lib\Process.ps1')
. (Join-Path $PSScriptRoot 'lib\Registry.ps1')
. (Join-Path $PSScriptRoot 'actions\CoreActions.ps1')
. (Join-Path $PSScriptRoot 'actions\EditActions.ps1')
. (Join-Path $PSScriptRoot 'actions\ProfileActions.ps1')
. (Join-Path $PSScriptRoot 'actions\ClaudeAction.ps1')
. (Join-Path $PSScriptRoot 'actions\CodexAction.ps1')

$PROTOCOL_VERSION = 1

# Core actions the dispatcher implements itself. Anything else must be declared
# by a project profile. There is deliberately no arbitrary-shell action.
$script:CoreActionHandlers = @{
    'ping'         = { param($ctx) Invoke-ActionPing $ctx }
    'git_status'   = { param($ctx) Invoke-ActionGitStatus $ctx }
    'git_diff'     = { param($ctx) Invoke-ActionGitDiff $ctx }
    'read_file'    = { param($ctx) Invoke-ActionReadFile $ctx }
    'read_result'  = { param($ctx) Invoke-ActionReadResult $ctx }
    'replace_text' = { param($ctx) Invoke-ActionReplaceText $ctx }
    'apply_patch'  = { param($ctx) Invoke-ActionApplyPatch $ctx }
    'claude_task'  = { param($ctx) Invoke-ActionClaudeTask $ctx }
    'codex_task'   = { param($ctx) Invoke-ActionCodexTask $ctx }
}

$startedAt = [DateTimeOffset]::UtcNow
$stateRootResolved = Get-GptLoopStateRoot -Override $StateRoot

# --- result emission ----------------------------------------------------------

function Write-JobResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Action = 'unknown',
        [string]$JobId = '',
        [string]$Project = '',
        $WorkRef = $null,
        [string]$Workspace = '',
        [string]$RequestSha = '',
        [string]$ErrorMessage = '',
        [object[]]$Steps = @()
    )

    $ok = ($Status -eq 'success')
    $finishedAt = [DateTimeOffset]::UtcNow

    # Full local record keeps untruncated stdout/stderr.
    $fullSteps = @()
    $commentSteps = @()
    foreach ($step in $Steps) {
        $fullOut = [string](Get-Prop $step 'full_stdout' ([string](Get-Prop $step 'stdout' '')))
        $fullErr = [string](Get-Prop $step 'full_stderr' ([string](Get-Prop $step 'stderr' '')))
        $fullSteps += [pscustomobject][ordered]@{
            name        = [string](Get-Prop $step 'name' '')
            exit_code   = [int](Get-Prop $step 'exit_code' 0)
            duration_ms = [int](Get-Prop $step 'duration_ms' 0)
            stdout      = $fullOut
            stderr      = $fullErr
            truncated   = $false
        }
        $commentSteps += [pscustomobject][ordered]@{
            name        = [string](Get-Prop $step 'name' '')
            exit_code   = [int](Get-Prop $step 'exit_code' 0)
            duration_ms = [int](Get-Prop $step 'duration_ms' 0)
            stdout      = [string](Get-Prop $step 'stdout' '')
            stderr      = [string](Get-Prop $step 'stderr' '')
            truncated   = [bool](Get-Prop $step 'truncated' $false)
        }
    }

    $base = [ordered]@{
        protocol_version = $PROTOCOL_VERSION
        job_id           = $JobId
        issue_number     = $IssueNumber
        request_sha256   = $RequestSha
        project          = $Project
        action           = $Action
        status           = $Status
        ok               = $ok
        workspace        = $Workspace
        started_at       = $startedAt.ToString('o')
        finished_at      = $finishedAt.ToString('o')
        error            = $ErrorMessage
    }
    if ($null -ne $WorkRef) { $base['work_ref'] = $WorkRef }

    # --- full local result ---
    $fullResult = [ordered]@{}
    foreach ($k in $base.Keys) { $fullResult[$k] = $base[$k] }
    $fullResult['steps'] = @($fullSteps)
    $fullJson = ($fullResult | ConvertTo-Json -Depth 12)

    $resultId = if ([string]::IsNullOrWhiteSpace($JobId)) { 'unassigned-' + [Guid]::NewGuid().ToString('N') } else { $JobId }
    $resultsDir = Join-Path $stateRootResolved 'results'
    $storedPath = ''
    try {
        New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
        $storedPath = Join-Path $resultsDir "$resultId.json"
        [IO.File]::WriteAllText($storedPath, $fullJson, [System.Text.UTF8Encoding]::new($false))
    } catch {
        $storedPath = ''
    }

    # --- bounded comment result ---
    $comment = [ordered]@{}
    foreach ($k in $base.Keys) { $comment[$k] = $base[$k] }
    $comment['full_result_sha256'] = Get-Sha256Hex $fullJson
    $comment['full_result_id'] = $resultId
    $comment['full_result_available'] = [bool]$storedPath
    $comment['steps'] = @($commentSteps)
    # `truncated` means "the comment does not contain everything", which is
    # already true when an individual step's output was clipped -- not only when
    # the whole payload overflows the comment budget.
    $anyStepTruncated = @($commentSteps | Where-Object { $_.truncated }).Count -gt 0
    $comment['truncated'] = $anyStepTruncated
    if ($anyStepTruncated) { $comment['retrieve_with'] = "action=read_result params.job_id=$resultId" }

    $json = ($comment | ConvertTo-Json -Depth 12)
    if ($json.Length -gt $CommentCharBudget) {
        # Shrink step output progressively rather than emitting a broken blob.
        $budget = [Math]::Max(500, [int]($CommentCharBudget / [Math]::Max(1, $commentSteps.Count * 2)))
        foreach ($step in $commentSteps) {
            $step.stdout = Limit-Text $step.stdout $budget
            $step.stderr = Limit-Text $step.stderr ([int]($budget / 2))
            $step.truncated = $true
        }
        $comment['truncated'] = $true
        $comment['steps'] = @($commentSteps)
        $comment['retrieve_with'] = "action=read_result params.job_id=$resultId"
        $json = ($comment | ConvertTo-Json -Depth 12)
        if ($json.Length -gt $CommentCharBudget) {
            $minimal = [ordered]@{}
            foreach ($k in $base.Keys) { $minimal[$k] = $base[$k] }
            $minimal['full_result_sha256'] = $comment['full_result_sha256']
            $minimal['full_result_id'] = $resultId
            $minimal['truncated'] = $true
            $minimal['steps'] = @()
            $minimal['note'] = 'result too large for a GitHub comment; use read_result'
            $json = ($minimal | ConvertTo-Json -Depth 12)
        }
    }

    [IO.File]::WriteAllText($ResultPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $Status
}

# --- main ---------------------------------------------------------------------

$jobId = ''
$projectKey = ''
$action = 'unknown'
$requestSha = ''
$workspace = ''
$workRef = $null
$mutex = $null
$mutexHeld = $false

try {
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        Throw-InvalidRequest "request file not found: $RequestPath"
    }
    $requestRaw = [IO.File]::ReadAllText($RequestPath, [System.Text.Encoding]::UTF8)
    $requestSha = Get-Sha256Hex $requestRaw
    if ([string]::IsNullOrWhiteSpace($requestRaw)) {
        Throw-InvalidRequest 'request body is empty'
    }

    # The body may be wrapped in a markdown fence when a human pastes it; accept
    # that, but never rewrite the request beyond unwrapping.
    $requestText = $requestRaw.Trim()
    if ($requestText -match '(?s)^```(?:json)?\s*(.*?)\s*```\s*$') {
        $requestText = $Matches[1].Trim()
    }

    try {
        $request = $requestText | ConvertFrom-Json
    } catch {
        Throw-InvalidRequest "request body is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $request -or $request -isnot [psobject]) {
        Throw-InvalidRequest 'request body must be a JSON object'
    }

    $version = Get-Prop $request 'protocol_version' $null
    if ($null -eq $version) { Throw-InvalidRequest 'request.protocol_version is required' }
    if ([int]$version -ne $PROTOCOL_VERSION) {
        Throw-InvalidRequest "unsupported protocol_version: $version (this runner speaks $PROTOCOL_VERSION)"
    }

    $jobId = [string](Get-Prop $request 'job_id' '')
    if ($jobId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Throw-InvalidRequest 'request.job_id must be a UUID'
    }

    $projectKey = [string](Get-Prop $request 'project' '')
    if ([string]::IsNullOrWhiteSpace($projectKey)) { Throw-InvalidRequest 'request.project is required' }

    $action = [string](Get-Prop $request 'action' '')
    if ([string]::IsNullOrWhiteSpace($action)) { Throw-InvalidRequest 'request.action is required' }
    if ($action -notmatch '^[a-z][a-z0-9_]{0,63}$') { Throw-InvalidRequest "request.action has an invalid form: $action" }

    $params = Get-Prop $request 'params' $null

    # Workspace authority is resolved first and only from trusted machine-local
    # registry policy. work_ref is validated *after* that lookup, so a repository
    # reference can never influence filesystem placement.
    $project = Resolve-Project -ProjectKey $projectKey -StateRoot $stateRootResolved -RepoRoot $RepoRoot
    $workspace = $project.workspace
    $workRef = Resolve-ProjectWorkRef -Request $request -Project $project

    $context = [pscustomobject]@{
        Project          = $project
        WorkRef          = $workRef
        Params           = $params
        Request          = $request
        StateRoot        = $stateRootResolved
        RepoRoot         = $RepoRoot
        JobId            = $jobId
        ChildEnvironment = @{
            PYTHONUTF8       = '1'
            PYTHONIOENCODING = 'utf-8'
            GPTLOOP_JOB_ID   = $jobId
        }
    }

    # Serialise across the machine. A second job blocks here instead of being
    # cancelled -- GitHub concurrency must never be the only queue discipline.
    $mutexName = 'Global\gpt-loop-dispatcher'
    try {
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    } catch {
        $mutex = [System.Threading.Mutex]::new($false, 'Local\gpt-loop-dispatcher')
    }
    try {
        $mutexHeld = $mutex.WaitOne([TimeSpan]::FromSeconds($LockTimeoutSeconds))
    } catch [System.Threading.AbandonedMutexException] {
        # Previous holder crashed; we now own it.
        $mutexHeld = $true
    }
    if (-not $mutexHeld) {
        Throw-EnvironmentError "another gpt-loop job held the runner lock for more than $LockTimeoutSeconds seconds"
    }

    # Dispatch: core handler first, then the project's profile.
    if ($script:CoreActionHandlers.ContainsKey($action)) {
        $outcome = & $script:CoreActionHandlers[$action] $context
    } else {
        $outcome = Invoke-ProfileAction -Context $context -Action $action
        if ($null -eq $outcome) {
            Throw-InvalidRequest "unsupported action '$action' for project '$projectKey' (profile: $($project.profile_name))"
        }
    }

    $status = [string]$outcome.Status
    $steps = @($outcome.Steps)
    $errorMessage = ''
    if ($status -ne $script:GptLoopStatus.Success) {
        $errorMessage = "action '$action' completed with status $status"
    }

    Write-JobResult -Status $status -Action $action -JobId $jobId -Project $projectKey `
        -WorkRef $workRef -Workspace $workspace -RequestSha $requestSha -ErrorMessage $errorMessage -Steps $steps | Out-Null

    if ($status -eq $script:GptLoopStatus.Success) { exit 0 } else { exit 1 }

} catch {
    $status = Get-ErrorStatus $_
    $message = $_.Exception.Message
    $steps = @()
    # A timeout still carries the partial output captured before the kill.
    if ($null -ne $script:GptLoopLastStep) { $steps = @($script:GptLoopLastStep) }
    # Keep the stack trace: an unexpected dispatcher error is a control-plane
    # bug, and the local result is where it has to be diagnosable from.
    $trace = ''
    try { $trace = [string]$_.ScriptStackTrace } catch { }
    $steps += New-Step -Name 'dispatch_error' -ExitCode 1 -Stderr ($message + "`n---`n" + $trace)

    Write-JobResult -Status $status -Action $action -JobId $jobId -Project $projectKey `
        -WorkRef $workRef -Workspace $workspace -RequestSha $requestSha -ErrorMessage $message -Steps $steps | Out-Null
    exit 1

} finally {
    if ($null -ne $mutex) {
        if ($mutexHeld) { try { $mutex.ReleaseMutex() } catch { } }
        try { $mutex.Dispose() } catch { }
    }
}
