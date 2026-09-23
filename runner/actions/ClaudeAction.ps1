# ClaudeAction.ps1 -- run local Claude Code as a bounded executor.
#
# Claude Code is an executor, not a second control plane. Durable continuation is
# opt-in: legacy projects retain the one-process/one-round semantics, while a
# durable project separates the Claude slice from packet/job lifetime.

Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Durable.ps1')

$script:GptLoopClaudePermissionModes = @('plan', 'manual', 'acceptEdits', 'dontAsk', 'auto')

function Resolve-ClaudeExecutable {
    param($Context)
    $claudeConfig = Get-Prop $Context.Project.entry 'claude' $null
    $configured = [string](Get-Prop $claudeConfig 'executable' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            Throw-EnvironmentError "configured claude.executable does not exist: $configured"
        }
        return $configured
    }
    $candidates = if ($IsWindows) { @('claude.cmd', 'claude.exe', 'claude') } else { @('claude') }
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) { continue }
        if ($IsWindows) {
            if ([IO.Path]::GetExtension($cmd.Source) -in @('.cmd', '.exe', '.bat')) { return $cmd.Source }
            continue
        }
        return $cmd.Source
    }
    Throw-EnvironmentError 'Claude Code CLI was not found; set claude.executable in projects.json'
}

function Get-ClaudeQuotaWait {
    param([bool]$IsError, [string]$ResultText)
    if (-not $IsError) { return $null }
    if ([string]::IsNullOrWhiteSpace($ResultText)) { return $null }
    if ($ResultText -notmatch '(?i)(session|usage|rate)\s+limit') { return $null }

    $retryAfter = [DateTimeOffset]::UtcNow.AddMinutes(30)
    $hint = ''
    if ($ResultText -match '(?i)resets\s+(?:at\s+)?(\d{1,2}):(\d{2})\s*(am|pm)?(?:\s*\(([^)]+)\))?') {
        $hint = $Matches[0]
        try {
            $hour = [int]$Matches[1]; $minute = [int]$Matches[2]; $meridiem = [string]$Matches[3]
            if ($meridiem -match '(?i)pm' -and $hour -lt 12) { $hour += 12 }
            if ($meridiem -match '(?i)am' -and $hour -eq 12) { $hour = 0 }
            $zone = [TimeZoneInfo]::Local
            if (-not [string]::IsNullOrWhiteSpace($Matches[4])) {
                try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($Matches[4].Trim()) } catch { }
            }
            $nowThere = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $zone)
            $reset = [DateTimeOffset]::new($nowThere.Year, $nowThere.Month, $nowThere.Day, $hour, $minute, 0, $nowThere.Offset)
            if ($reset -le [DateTimeOffset]::UtcNow) { $reset = $reset.AddDays(1) }
            $retryAfter = $reset
        } catch { }
    }
    if ($retryAfter -le [DateTimeOffset]::UtcNow.AddMinutes(1)) { $retryAfter = [DateTimeOffset]::UtcNow.AddMinutes(30) }
    return [pscustomobject]@{ RetryAfter=$retryAfter.ToUniversalTime(); Hint=$hint; Text=(Limit-Text $ResultText 400) }
}

function Set-ClaudeQuotaMarker {
    param($QuotaWait, [string]$StateRoot = '')
    try {
        if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-GptLoopStateRoot }
        $path = Join-Path $StateRoot 'quota-wait.json'
        if ($null -eq $QuotaWait) {
            if (Test-Path -LiteralPath $path) {
                $owner = ''
                try { $owner = [string](Get-Prop (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json) 'executor' '') } catch { }
                if ($owner -eq 'claude') { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
            return ''
        }
        $payload = [ordered]@{ executor='claude'; detected_at=([DateTimeOffset]::UtcNow).ToString('o'); retry_after=$QuotaWait.RetryAfter.ToString('o'); hint=$QuotaWait.Hint; text=$QuotaWait.Text }
        [IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        return $QuotaWait.RetryAfter.ToString('o')
    } catch { return '' }
}

function Resolve-ClaudeTier {
    param($ClaudeConfig,[string]$TierName,[string]$ProjectKey,[string]$DefaultModel,[string]$DefaultEffort)
    if ([string]::IsNullOrWhiteSpace($TierName)) { return [pscustomobject]@{ Model=$DefaultModel; Effort=$DefaultEffort } }
    $tiers = Get-Prop $ClaudeConfig 'tiers' $null; $tier = Get-Prop $tiers $TierName $null
    if ($null -eq $tier) { Throw-InvalidRequest ("unknown claude tier '{0}' for project '{1}' (configure claude.tiers in projects.json)" -f $TierName,$ProjectKey) }
    return [pscustomobject]@{ Model=[string](Get-Prop $tier 'model' $DefaultModel); Effort=[string](Get-Prop $tier 'effort' $DefaultEffort) }
}

function Invoke-ActionClaudeTask {
    param($Context)

    $claudeConfig = Get-Prop $Context.Project.entry 'claude' $null
    if (-not [bool](Get-Prop $claudeConfig 'enabled' $false)) {
        Throw-Denied ("project '{0}' has not enabled the claude executor (set claude.enabled=true in projects.json)" -f $Context.Project.key)
    }

    $prompt = [string](Get-Prop $Context.Params 'prompt' '')
    if ([string]::IsNullOrWhiteSpace($prompt)) { Throw-InvalidRequest 'claude_task requires params.prompt' }
    $maxPrompt = [int](Get-Prop $claudeConfig 'max_prompt_chars' 8000)
    if ($prompt.Length -gt $maxPrompt) { Throw-InvalidRequest "claude_task prompt exceeds the configured limit of $maxPrompt characters" }

    $defaultMode = [string](Get-Prop $claudeConfig 'permission_mode' 'plan')
    $requested = [string](Get-Prop $Context.Params 'permission_mode' $defaultMode)
    $allowedModes = @(Get-Prop $claudeConfig 'allowed_permission_modes' @($defaultMode))
    if ($requested -notin $script:GptLoopClaudePermissionModes) { Throw-InvalidRequest "unsupported permission_mode: $requested" }
    if ($requested -notin $allowedModes) { Throw-Denied ("permission_mode '{0}' is not allowed for project '{1}'" -f $requested,$Context.Project.key) }

    $timeout = [int](Get-Prop $claudeConfig 'timeout_seconds' 900)
    $model = [string](Get-Prop $claudeConfig 'model' '')
    $effort = [string](Get-Prop $claudeConfig 'effort' '')
    $tierName = [string](Get-Prop $Context.Params 'tier' '')
    $resolved = Resolve-ClaudeTier -ClaudeConfig $claudeConfig -TierName $tierName -ProjectKey $Context.Project.key -DefaultModel $model -DefaultEffort $effort
    $model = $resolved.Model; $effort = $resolved.Effort

    # ----- durable packet lifetime -------------------------------------------
    $durable = Test-ClaudeDurableEnabled $Context
    $durableBefore = $null
    if ($durable) {
        Initialize-DurableExecution $Context | Out-Null
        $opened = Open-DurableSlice $Context
        $alreadyTerminal = Get-Prop $opened 'terminal' $null
        if ($null -ne $alreadyTerminal) {
            # Recovery path for a crash after Claude declared terminal but before
            # the previous slice completed its ownership audit/finalization. The
            # terminal declaration alone is deliberately not enough to release
            # the project lease.
            $audit = Audit-DurableEscapes $Context
            $auditSupported = [bool](Get-Prop $audit 'supported' $false)
            $escapes = @(Get-Prop $audit 'escapes' @())
            $auditExitCode = if ($auditSupported -and $escapes.Count -eq 0) { 0 } else { 1 }
            $auditStep = New-Step -Name 'durable_ownership_audit' -ExitCode $auditExitCode -Stdout ($audit | ConvertTo-Json -Depth 8 -Compress)
            if (-not $auditSupported) {
                $forced = Abort-DurableExecution $Context 'durable provenance audit is unavailable on this platform'
                return [pscustomobject]@{ Status=$script:GptLoopStatus.HardBlocker; Steps=@($auditStep,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
            }
            if ($escapes.Count -gt 0) {
                $forced = Abort-DurableExecution $Context ("unregistered detached work detected while finalizing recovered terminal execution: {0} process(es)" -f $escapes.Count)
                return [pscustomobject]@{ Status=$script:GptLoopStatus.HardBlocker; Steps=@($auditStep,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
            }
            Finalize-DurableExecution -Context $Context -Reason 'recovered terminal ownership audit passed' | Out-Null
            $mapped = Convert-DurableTerminalStatus ([string](Get-Prop $alreadyTerminal 'status' ''))
            $note = New-Step -Name 'durable_terminal' -Stdout ($alreadyTerminal | ConvertTo-Json -Depth 6 -Compress)
            return [pscustomobject]@{ Status=$mapped; Steps=@($auditStep,$note) }
        }
        $durableBefore = Get-DurableSummary $Context
        $prompt = Get-DurableClaudePrompt -Context $Context -OriginalPrompt $prompt -Summary $durableBefore
        $durableCfg = Get-ClaudeDurableConfig $Context
        $sliceSeconds = [int](Get-Prop $durableCfg 'slice_seconds' 2400)
        if ($sliceSeconds -lt 60 -or $sliceSeconds -gt 6600) { Throw-EnvironmentError 'claude.durable.slice_seconds must be 60..6600' }
        $timeout = [Math]::Min($timeout, $sliceSeconds)
    }

    $exe = Resolve-ClaudeExecutable -Context $Context
    $argv = @('-p',$prompt,'--output-format','json','--permission-mode',$requested)
    if (-not [string]::IsNullOrWhiteSpace($model)) { $argv += @('--model',$model) }
    if (-not [string]::IsNullOrWhiteSpace($effort)) { $argv += @('--effort',$effort) }

    $childEnv = @{}
    foreach ($key in $Context.ChildEnvironment.Keys) { $childEnv[$key] = $Context.ChildEnvironment[$key] }
    if ($durable) {
        $childEnv['GPTLOOP_EXECUTION_ID'] = $Context.JobId
        $childEnv['GPTLOOP_STATE_ROOT'] = $Context.StateRoot
        $childEnv['GPTLOOP_DURABLE_HELPER'] = Get-DurableHelperPath $Context
        $childEnv['GPTLOOP_DURABLE_PYTHON'] = Get-DurablePython $Context
    }

    $sliceTimedOut = $false
    try {
        if ($durable) {
            $step = Invoke-DurableClaudeProcess -Context $Context -FilePath $exe -Arguments $argv `
                -WorkingDirectory $Context.Project.workspace -TimeoutSeconds $timeout -Environment $childEnv -StdoutLimit 40000
        } else {
            $step = Invoke-CapturedProcess -FilePath $exe -Arguments $argv -WorkingDirectory $Context.Project.workspace `
                -TimeoutSeconds $timeout -Name 'claude_task' -Environment $childEnv -StdoutLimit 40000
        }
    } catch {
        if ($durable -and (Get-ErrorStatus $_) -eq $script:GptLoopStatus.Timeout) {
            $sliceTimedOut = $true
            $step = $script:GptLoopLastStep
            if ($null -eq $step) { $step = New-Step -Name 'claude_task' -ExitCode 124 -Stderr "durable slice ended at $timeout seconds" -Truncated $true }
            if (-not [string]::IsNullOrWhiteSpace($script:GptLoopDurableTimeoutControlFailure)) {
                $forced = Abort-DurableExecution $Context $script:GptLoopDurableTimeoutControlFailure
                Set-ClaudeQuotaMarker -QuotaWait $null | Out-Null
                return [pscustomobject]@{ Status=$script:GptLoopStatus.HardBlocker; Steps=@($step,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
            }
        } else { throw }
    }

    $status = if ($sliceTimedOut) { 'continuation' } elseif ($step.exit_code -eq 0) { $script:GptLoopStatus.Success } else { $script:GptLoopStatus.Failure }
    $quotaRetryAfter = ''
    $summary = New-Step -Name 'claude_task_summary' -ExitCode ([int]$step.exit_code)
    try {
        $full = [string](Get-Prop $step 'full_stdout' $step.stdout); $parsed = $full | ConvertFrom-Json
        $ran = ''; try { $ran = (($parsed.modelUsage.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') } catch { }
        $summary.stdout = @(
            "tier=$(if ($tierName) { $tierName } else { '(default)' })"
            "model_configured=$model effort=$effort"
            "model_ran=$ran"
            "is_error=$([bool](Get-Prop $parsed 'is_error' $false))"
            "num_turns=$([string](Get-Prop $parsed 'num_turns' ''))"
            "duration_ms=$([string](Get-Prop $parsed 'duration_ms' ''))"
            "session_id=$([string](Get-Prop $parsed 'session_id' ''))"
            "durable=$durable slice_timeout_seconds=$timeout"
        ) -join "`n"
        $isError = [bool](Get-Prop $parsed 'is_error' $false)
        if ($isError -and -not $sliceTimedOut) { $status = $script:GptLoopStatus.Failure }
        $quota = Get-ClaudeQuotaWait -IsError $isError -ResultText ([string](Get-Prop $parsed 'result' ''))
        if ($null -ne $quota) {
            $status = $script:GptLoopStatus.QuotaWait
            $quotaRetryAfter = Set-ClaudeQuotaMarker -QuotaWait $quota
            $summary.stdout += "`nquota_wait=true retry_after=$quotaRetryAfter hint=$($quota.Hint)"
        }
    } catch {
        $summary.stderr = 'claude did not emit parseable JSON output'
    }

    if (-not $durable) {
        if ($status -ne $script:GptLoopStatus.QuotaWait) { Set-ClaudeQuotaMarker -QuotaWait $null | Out-Null }
        return [pscustomobject]@{ Status=$status; Steps=@($step,$summary) }
    }

    # ----- post-slice ownership + terminal gate ------------------------------
    $audit = Audit-DurableEscapes $Context
    $auditSupported = [bool](Get-Prop $audit 'supported' $false)
    $escapes = @(Get-Prop $audit 'escapes' @())
    $auditExitCode = if ($auditSupported -and $escapes.Count -eq 0) { 0 } else { 1 }
    $auditStep = New-Step -Name 'durable_ownership_audit' -ExitCode $auditExitCode `
        -Stdout ($audit | ConvertTo-Json -Depth 8 -Compress)

    if (-not $auditSupported) {
        $forced = Abort-DurableExecution $Context 'durable provenance audit is unavailable on this platform'
        $summary.stderr += "`ndurable mode failed closed: provenance audit unavailable"
        return [pscustomobject]@{ Status=$script:GptLoopStatus.HardBlocker; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
    }
    if ($escapes.Count -gt 0) {
        $forced = Abort-DurableExecution $Context ("unregistered detached work detected after Claude slice: {0} process(es)" -f $escapes.Count)
        return [pscustomobject]@{ Status=$script:GptLoopStatus.HardBlocker; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
    }

    $after = Get-DurableSummary $Context
    $terminal = Get-Prop $after 'terminal' $null
    if ($null -ne $terminal) {
        if ($status -ne $script:GptLoopStatus.QuotaWait) { Set-ClaudeQuotaMarker -QuotaWait $null | Out-Null }
        # Release the persistent project lease only after the post-slice ownership
        # audit is clean. `complete` itself cannot release it because Claude calls
        # complete while Claude (and possibly escaped descendants) is still alive.
        Finalize-DurableExecution -Context $Context -Reason 'post-slice ownership audit passed' | Out-Null
        $mapped = Convert-DurableTerminalStatus ([string](Get-Prop $terminal 'status' ''))
        return [pscustomobject]@{ Status=$mapped; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_terminal' -Stdout ($terminal | ConvertTo-Json -Depth 6 -Compress))) }
    }

    # A non-quota Claude error is a real executor failure, not an invitation to
    # spin slices forever. Abort owned work before waking the conversation.
    if ($status -eq $script:GptLoopStatus.Failure) {
        $forced = Abort-DurableExecution $Context 'Claude executor failed before declaring a packet terminal state'
        Set-ClaudeQuotaMarker -QuotaWait $null | Out-Null
        return [pscustomobject]@{ Status=$script:GptLoopStatus.Failure; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_terminal' -Stderr ($forced | ConvertTo-Json -Compress))) }
    }

    if ($status -eq $script:GptLoopStatus.QuotaWait) {
        Set-DurableCheckpoint -Context $Context -Note "quota_wait retry_after=$quotaRetryAfter" | Out-Null
        return [pscustomobject]@{ Status=$script:GptLoopStatus.QuotaWait; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_state' -Stdout ($after | ConvertTo-Json -Depth 12 -Compress))) }
    }

    Set-ClaudeQuotaMarker -QuotaWait $null | Out-Null
    $checkpointNote = if ($sliceTimedOut) { 'slice budget elapsed; continue' } else { 'Claude slice ended without packet terminal declaration; continue' }
    Set-DurableCheckpoint -Context $Context -Note $checkpointNote | Out-Null
    $after = Get-DurableSummary $Context
    return [pscustomobject]@{ Status=$script:GptLoopStatus.Continuation; Steps=@($step,$summary,$auditStep,(New-Step -Name 'durable_state' -Stdout ($after | ConvertTo-Json -Depth 12 -Compress))) }
}
