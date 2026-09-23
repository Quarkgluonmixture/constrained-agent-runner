# Durable.ps1 -- packet-level continuation and owned long-running jobs.
#
# This layer is opt-in per project. Legacy actions keep their existing bounded
# process semantics. Durable mode uses runner/durable_job.py for persistent state
# and POSIX process-group ownership; it fails closed on unsupported platforms.

Set-StrictMode -Version Latest

# Durable statuses extend the shared taxonomy only when this opt-in layer is loaded.
$script:GptLoopStatus['Continuation'] = 'continuation'
$script:GptLoopStatus['HardBlocker'] = 'hard_blocker'
$script:GptLoopDurableTimeoutControlFailure = ''

function Get-ClaudeDurableConfig {
    param($Context)
    $claude = Get-Prop $Context.Project.entry 'claude' $null
    return (Get-Prop $claude 'durable' $null)
}

function Test-ClaudeDurableEnabled {
    param($Context)
    return [bool](Get-Prop (Get-ClaudeDurableConfig $Context) 'enabled' $false)
}

function Get-DurablePython {
    param($Context)
    $cfg = Get-ClaudeDurableConfig $Context
    $python = [string](Get-Prop $cfg 'python_executable' '')
    if ([string]::IsNullOrWhiteSpace($python)) {
        Throw-EnvironmentError "claude.durable.python_executable is required when durable mode is enabled"
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        Throw-EnvironmentError "configured claude.durable.python_executable does not exist: $python"
    }
    return $python
}

function Get-DurableHelperPath {
    param($Context)
    $path = Join-Path $Context.RepoRoot 'runner\durable_job.py'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-EnvironmentError "durable helper not found: $path"
    }
    return $path
}

function Invoke-DurableJson {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 20
    )
    $python = Get-DurablePython $Context
    $helper = Get-DurableHelperPath $Context
    $step = Invoke-CapturedProcess -FilePath $python -Arguments (@($helper) + $Arguments) `
        -WorkingDirectory $Context.Project.workspace -TimeoutSeconds $TimeoutSeconds `
        -Name 'durable_control' -Environment @{} -StdoutLimit 30000 -StderrLimit 8000
    if ($step.exit_code -ne 0) {
        $detail = [string](Get-Prop $step 'full_stderr' $step.stderr)
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = [string](Get-Prop $step 'full_stdout' $step.stdout) }
        Throw-EnvironmentError ("durable control command failed: {0}" -f (Limit-Text $detail 2000))
    }
    $raw = [string](Get-Prop $step 'full_stdout' $step.stdout)
    try { return ($raw | ConvertFrom-Json) }
    catch { Throw-EnvironmentError "durable control command returned invalid JSON" }
}

function Save-DurableRequest {
    param($Context)
    $dir = Join-Path $Context.StateRoot 'requests'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ("{0}.json" -f $Context.JobId)
    $canonical = $Context.Request | ConvertTo-Json -Depth 20 -Compress

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        # The workflow persists the exact first request. Other callers may have
        # persisted canonical JSON instead. Compare parsed semantics so a UUID can
        # never be reused with a different prompt/action merely because formatting
        # changed between transports.
        try {
            $existingRaw = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $existingText = $existingRaw.Trim()
            if ($existingText -match '(?s)^```(?:json)?\s*(.*?)\s*```\s*$') { $existingText = $Matches[1].Trim() }
            $existingCanonical = ($existingText | ConvertFrom-Json) | ConvertTo-Json -Depth 20 -Compress
        } catch {
            Throw-EnvironmentError "persisted durable request is unreadable: $path"
        }
        if ($existingCanonical -ne $canonical) {
            Throw-InvalidRequest "job_id collision: persisted durable request differs for $($Context.JobId)"
        }
        return $path
    }

    # Direct/manual callers do not have the stock workflow's exact-body capture;
    # persist the already-validated request canonically and make later slices prove
    # semantic identity against it.
    $tmp = "$path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, $canonical, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Initialize-DurableExecution {
    param($Context)
    $cfg = Get-ClaudeDurableConfig $Context
    $requestPath = Save-DurableRequest $Context
    $requestRaw = [IO.File]::ReadAllText($requestPath, [System.Text.Encoding]::UTF8)
    $requestSha = Get-Sha256Hex $requestRaw

    $maxSeconds = [int](Get-Prop $cfg 'execution_timeout_seconds' 21600)
    $maxSlices = [int](Get-Prop $cfg 'max_slices' 12)
    $logMax = [int](Get-Prop $cfg 'log_max_bytes' 8388608)
    if ($maxSeconds -lt 300 -or $maxSeconds -gt 86400) { Throw-EnvironmentError 'claude.durable.execution_timeout_seconds must be 300..86400' }
    if ($maxSlices -lt 1 -or $maxSlices -gt 100) { Throw-EnvironmentError 'claude.durable.max_slices must be 1..100' }
    if ($logMax -lt 65536 -or $logMax -gt 67108864) { Throw-EnvironmentError 'claude.durable.log_max_bytes must be 65536..67108864' }

    $profiles = Get-Prop $cfg 'command_profiles' $null
    if ($null -eq $profiles) { $profiles = [pscustomobject]@{} }
    $profilesJson = $profiles | ConvertTo-Json -Depth 12 -Compress

    return Invoke-DurableJson $Context @(
        'init', '--state-root', $Context.StateRoot, '--execution-id', $Context.JobId,
        '--project', $Context.Project.key, '--workspace', $Context.Project.workspace,
        '--request-sha', $requestSha,
        '--max-seconds', [string]$maxSeconds, '--max-slices', [string]$maxSlices,
        '--log-max-bytes', [string]$logMax, '--profiles-json', $profilesJson
    )
}

function Open-DurableSlice {
    param($Context)
    $runId = if ($env:GITHUB_RUN_ID) { [string]$env:GITHUB_RUN_ID } else { '' }
    return Invoke-DurableJson $Context @('slice-open','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId,'--run-id',$runId)
}

function Get-DurableSummary {
    param($Context)
    return Invoke-DurableJson $Context @('summary','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId)
}

function Set-DurableCheckpoint {
    param($Context, [string]$Note)
    return Invoke-DurableJson $Context @('checkpoint','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId,'--note',$Note)
}

function Audit-DurableEscapes {
    param($Context)
    return Invoke-DurableJson $Context @('audit','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId,'--kill')
}

function Abort-DurableExecution {
    param($Context, [string]$Message)
    return Invoke-DurableJson $Context @('abort','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId,'--message',$Message)
}

function Finalize-DurableExecution {
    param($Context, [string]$Reason = 'ownership audit passed')
    return Invoke-DurableJson $Context @('finalize','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId,'--reason',$Reason)
}

function Get-DurableOwnedProcessIds {
    param($Context)
    $owned = Invoke-DurableJson $Context @('owned-pids','--state-root',$Context.StateRoot,'--execution-id',$Context.JobId)
    return @((Get-Prop $owned 'pids' @()) | ForEach-Object { [int]$_ })
}

function Convert-DurableTerminalStatus {
    param([string]$TerminalStatus)
    switch ($TerminalStatus) {
        'closed_pass'  { return $script:GptLoopStatus.Success }
        'hard_blocker' { return 'hard_blocker' }
        'failure'      { return $script:GptLoopStatus.Failure }
        default        { Throw-EnvironmentError "unknown durable terminal status: $TerminalStatus" }
    }
}

function Stop-DurableClaudeTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int[]]$PreserveProcessIds = @()
    )
    $preserve = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $PreserveProcessIds) { if ($id -gt 0) { [void]$preserve.Add([int]$id) } }

    # Snapshot descendants before the root is killed; otherwise reparenting erases
    # provenance. Get-DescendantProcessId already returns leaves first.
    $descendants = @(Get-DescendantProcessId -ProcessId $ProcessId)
    foreach ($childId in $descendants) {
        if ($preserve.Contains([int]$childId)) { continue }
        try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch { }
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    foreach ($childId in $descendants) {
        if ($preserve.Contains([int]$childId)) { continue }
        try {
            $still = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($null -ne $still) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}

function Invoke-DurableClaudeProcess {
    <#
    .SYNOPSIS
        Bounded Claude slice that preserves already-registered durable jobs.
    .DESCRIPTION
        Legacy Invoke-CapturedProcess intentionally kills the entire descendant
        tree on timeout. That is correct for legacy actions and wrong for a
        durable slice: a registered long job is supposed to outlive Claude. This
        variant snapshots the Claude descendants, asks the durable registry for
        the exact owned PIDs/process groups, kills Claude plus every unregistered
        descendant, and leaves registered groups alive for the next slice.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 2400,
        [hashtable]$Environment = @{},
        [int]$StdoutLimit = 40000,
        [int]$StderrLimit = 12000
    )

    $script:GptLoopDurableTimeoutControlFailure = ''
    if (-not (Test-Path -LiteralPath $FilePath)) {
        $resolved = Get-Command $FilePath -ErrorAction SilentlyContinue
        if ($null -eq $resolved) { Throw-EnvironmentError "executable not found: $FilePath" }
        $FilePath = $resolved.Source
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath; $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add([string]$arg) }
    foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }

    $sw = [Diagnostics.Stopwatch]::StartNew(); $proc = [Diagnostics.Process]::new(); $proc.StartInfo = $psi
    try { [void]$proc.Start() } catch { Throw-EnvironmentError "failed to start claude_task: $($_.Exception.Message)" }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync(); $stderrTask = $proc.StandardError.ReadToEndAsync()
    try { $proc.StandardInput.Close() } catch { }

    $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        $preserve = @()
        try { $preserve = @(Get-DurableOwnedProcessIds -Context $Context) }
        catch {
            $script:GptLoopDurableTimeoutControlFailure = "could not enumerate durable owned processes at slice timeout: $($_.Exception.Message)"
        }
        if ([string]::IsNullOrWhiteSpace($script:GptLoopDurableTimeoutControlFailure)) {
            Stop-DurableClaudeTree -ProcessId $proc.Id -PreserveProcessIds $preserve
        } else {
            # Fail closed: if ownership cannot be enumerated, the legacy whole-tree
            # kill is safer than leaving an unknown detached process alive. The
            # caller converts this into a durable hard_blocker.
            Stop-ProcessTree -ProcessId $proc.Id
        }
        $sw.Stop(); $partialOut=''; $partialErr=''
        try { if ($stdoutTask.Wait(2000)) { $partialOut=$stdoutTask.Result } } catch { }
        try { if ($stderrTask.Wait(2000)) { $partialErr=$stderrTask.Result } } catch { }
        $step = New-Step -Name 'claude_task' -ExitCode 124 -DurationMs ([int]$sw.ElapsedMilliseconds) `
            -Stdout (Limit-Text $partialOut $StdoutLimit) -Stderr (Limit-Text $partialErr $StderrLimit) -Truncated $true
        $script:GptLoopLastStep = $step
        Throw-Timeout "claude_task durable slice timed out after $TimeoutSeconds seconds"
    }

    $stdout=''; $stderr=''
    try { $stdoutTask.Wait(10000) | Out-Null; $stdout=$stdoutTask.Result } catch { }
    try { $stderrTask.Wait(10000) | Out-Null; $stderr=$stderrTask.Result } catch { }
    $sw.Stop(); $truncated=($stdout.Length -gt $StdoutLimit) -or ($stderr.Length -gt $StderrLimit)
    $step=New-Step -Name 'claude_task' -ExitCode $proc.ExitCode -DurationMs ([int]$sw.ElapsedMilliseconds) `
        -Stdout (Limit-Text $stdout $StdoutLimit) -Stderr (Limit-Text $stderr $StderrLimit) -Truncated $truncated
    Add-Member -InputObject $step -NotePropertyName 'full_stdout' -NotePropertyValue $stdout -Force
    Add-Member -InputObject $step -NotePropertyName 'full_stderr' -NotePropertyValue $stderr -Force
    try { $proc.Dispose() } catch { }
    return $step
}

function Get-DurableClaudePrompt {
    param($Context, [string]$OriginalPrompt, $Summary)
    $python = Get-DurablePython $Context
    $helper = Get-DurableHelperPath $Context
    $state = $Context.StateRoot
    $eid = $Context.JobId
    $summaryJson = $Summary | ConvertTo-Json -Depth 12 -Compress

    return @"
$OriginalPrompt

---
GPT-LOOP DURABLE EXECUTION CONTRACT (machine-enforced)
execution_id: $eid

This is one execution slice, not a fresh packet. A normal Claude exit does NOT
mean the packet is complete. The control plane will automatically schedule
another slice unless you explicitly declare a terminal state.

Current durable state:
$summaryJson

Long-running commands must use ONLY a trusted durable command profile. Do not
use nohup, '&', disown, tmux/screen, or any other detached/unregistered work.
Examples (quote paths exactly):
  '$python' '$helper' summary --state-root '$state' --execution-id '$eid'
  '$python' '$helper' job-start --state-root '$state' --execution-id '$eid' --job <stable-name> --profile <configured-profile> --arg=<arg>
  '$python' '$helper' job-status --state-root '$state' --execution-id '$eid' --job <stable-name>
  '$python' '$helper' job-wait --state-root '$state' --execution-id '$eid' --job <stable-name> --timeout 300
  '$python' '$helper' job-tail --state-root '$state' --execution-id '$eid' --job <stable-name> --bytes 8192
  '$python' '$helper' job-adopt --state-root '$state' --execution-id '$eid' --job <stable-name>

Use --arg=<value> when an argument begins with '-'. Reusing a stable job name is
idempotent only when the command is identical; a changed command is rejected.

When and only when the packet is truly terminal, declare exactly one:
  '$python' '$helper' complete --state-root '$state' --execution-id '$eid' --status closed_pass --message '<why complete>'
  '$python' '$helper' complete --state-root '$state' --execution-id '$eid' --status hard_blocker --message '<blocker>'
  '$python' '$helper' complete --state-root '$state' --execution-id '$eid' --status failure --message '<failure>'

closed_pass is rejected while any durable job is unresolved. If work remains,
do not fake a terminal status: leave a concise checkpoint and end this slice.
"@
}
