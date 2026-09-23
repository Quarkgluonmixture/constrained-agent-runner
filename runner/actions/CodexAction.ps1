# CodexAction.ps1 -- run local Codex CLI as a bounded executor.
#
# Codex is an executor, not a second control plane. The request can supply a
# bounded prompt and select a locally declared tier; it cannot choose an
# executable, workspace, model, reasoning effort, sandbox, approval policy, or
# arbitrary command. Authentication comes from the machine's existing Codex
# login -- gpt-loop never reads, writes, or injects an OpenAI API key.
#
# Verified against codex-cli 0.149.0 on macOS:
#   codex exec --strict-config --ephemeral --ignore-user-config --json \
#     --color never -C <workspace> --model <model> \
#     -c default_permissions="gptloop" \
#     -c permissions.gptloop=<bounded-profile> \
#     -c model_reasoning_effort="high" -c approval_policy="never" -

Set-StrictMode -Version Latest

# `danger-full-access` exists in the CLI, but it is deliberately not part of
# this executor's vocabulary. Adding Codex must not create a route around the
# dispatcher's existing workspace boundary.
$script:GptLoopCodexSandboxes = @('read-only', 'workspace-write')

function Get-CodexRemovedEnvironmentNames {
    <#
    .SYNOPSIS
        Returns credential-bearing environment names that Codex must not inherit.
    .DESCRIPTION
        The CLI still inherits HOME so it can use its existing on-machine login.
        Runner/job credentials are a different trust domain: an issue-authored
        prompt must not be able to print or reuse them, even with command network
        disabled. Match names rather than values so no secret is ever inspected
        or copied by gpt-loop.
    #>
    $blocked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
            'GIT_ASKPASS', 'GIT_SSH', 'GIT_SSH_COMMAND',
            'SSH_ASKPASS', 'SSH_AUTH_SOCK', 'NETRC'
        )) {
        [void]$blocked.Add($name)
    }

    foreach ($entry in [Environment]::GetEnvironmentVariables().Keys) {
        $name = [string]$entry
        if ($name -match '(?i)(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|SESSION_KEY|PRIVATE_KEY|CREDENTIAL|CREDENTIALS|AUTH|OAUTH|JWT)(_|$)') {
            [void]$blocked.Add($name)
        }
    }
    return @($blocked)
}

function Resolve-CodexExecutable {
    param($Context)

    $codexConfig = Get-Prop $Context.Project.entry 'codex' $null
    $configured = [string](Get-Prop $codexConfig 'executable' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            Throw-EnvironmentError "configured codex.executable does not exist: $configured"
        }
        return $configured
    }

    $candidates = if ($IsWindows) { @('codex.cmd', 'codex.exe', 'codex') } else { @('codex') }
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) { continue }
        if ($IsWindows) {
            if ([IO.Path]::GetExtension($cmd.Source) -in @('.cmd', '.exe', '.bat')) { return $cmd.Source }
            continue
        }
        return $cmd.Source
    }
    Throw-EnvironmentError 'Codex CLI was not found; set codex.executable in projects.json'
}

function ConvertTo-CodexTomlString {
    # JSON strings are valid TOML basic strings for the registry values used
    # here, and this avoids hand-built quoting in a process argument.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Get-CodexConfigInt {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Default,
        [Parameter(Mandatory = $true)][int]$Min,
        [Parameter(Mandatory = $true)][int]$Max
    )

    $raw = Get-Prop $Config $Name $Default
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed) -or $parsed -lt $Min -or $parsed -gt $Max) {
        Throw-EnvironmentError "codex.$Name must be an integer between $Min and $Max"
    }
    return $parsed
}

function Resolve-CodexTier {
    <#
    .SYNOPSIS
        Resolves a request's tier name entirely through trusted local config.
    #>
    param(
        $CodexConfig,
        [string]$TierName,
        [string]$ProjectKey,
        [string]$DefaultModel,
        [string]$DefaultReasoningEffort,
        [string]$DefaultSandbox
    )

    $tier = $null
    if (-not [string]::IsNullOrWhiteSpace($TierName)) {
        $tiers = Get-Prop $CodexConfig 'tiers' $null
        $tier = Get-Prop $tiers $TierName $null
        if ($null -eq $tier) {
            Throw-InvalidRequest ("unknown codex tier '{0}' for project '{1}' (configure codex.tiers in projects.json)" -f $TierName, $ProjectKey)
        }
    }

    return [pscustomobject]@{
        Model           = [string](Get-Prop $tier 'model' $DefaultModel)
        ReasoningEffort = [string](Get-Prop $tier 'reasoning_effort' $DefaultReasoningEffort)
        Sandbox         = [string](Get-Prop $tier 'sandbox' $DefaultSandbox)
    }
}

function Assert-CodexResolvedConfig {
    param($CodexConfig, $Resolved, [string]$ProjectKey)

    if ([string]::IsNullOrWhiteSpace($Resolved.Model)) {
        Throw-EnvironmentError "project '$ProjectKey' must configure codex.model or a tier model"
    }
    if ([string]::IsNullOrWhiteSpace($Resolved.ReasoningEffort)) {
        Throw-EnvironmentError "project '$ProjectKey' must configure codex.reasoning_effort or a tier reasoning_effort"
    }
    if ($Resolved.Sandbox -notin $script:GptLoopCodexSandboxes) {
        Throw-EnvironmentError ("unsupported codex sandbox '{0}'; gpt-loop permits only: {1}" -f $Resolved.Sandbox, ($script:GptLoopCodexSandboxes -join ', '))
    }

    $allowed = @(Get-Prop $CodexConfig 'allowed_sandboxes' @((Get-Prop $CodexConfig 'sandbox' 'read-only')))
    if ($Resolved.Sandbox -notin $allowed) {
        Throw-EnvironmentError ("codex tier resolved sandbox '{0}', but project '{1}' does not include it in codex.allowed_sandboxes" -f $Resolved.Sandbox, $ProjectKey)
    }
}

function Assert-CodexRequestSurface {
    param($Params)

    $names = if ($Params -is [System.Collections.IDictionary]) {
        @($Params.Keys | ForEach-Object { [string]$_ })
    } elseif ($null -ne $Params) {
        @($Params.PSObject.Properties | ForEach-Object { [string]$_.Name })
    } else { @() }

    foreach ($name in $names) {
        if ($name -notin @('prompt', 'tier')) {
            Throw-InvalidRequest "codex_task params.$name is not request-controlled; only prompt and a locally configured tier are accepted"
        }
    }
}

function New-CodexExecArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$ReasoningEffort,
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [Parameter(Mandatory = $true)][string]$TrustedTempDirectory
    )

    # Translate the registry's stable sandbox vocabulary to one fixed profile.
    # The CLI's minimal runtime paths remain readable, workspace access follows
    # the selected tier, and only the OS-provided per-user temp directory is an
    # extra writable root. The latter is required by macOS xcrun/Swift/Git and
    # was verified with `codex sandbox` on codex-cli 0.149.0. Command network
    # stays off; the provider connection is outside this command sandbox.
    $workspaceAccess = if ($Sandbox -eq 'workspace-write') { 'write' } else { 'read' }
    $tempKey = ConvertTo-CodexTomlString $TrustedTempDirectory
    $permissionProfile = '{ description = "gpt-loop bounded workspace", filesystem = { ":minimal" = "read", ":workspace_roots" = { "." = "' + $workspaceAccess + '" }, ' + $tempKey + ' = "write" }, network = { enabled = false } }'

    return @(
        'exec',
        '--strict-config',
        '--ephemeral',
        '--ignore-user-config',
        '--json',
        '--color', 'never',
        '-C', $Workspace,
        '--model', $Model,
        '-c', 'default_permissions="gptloop"',
        '-c', ('permissions.gptloop=' + $permissionProfile),
        '-c', ('model_reasoning_effort=' + (ConvertTo-CodexTomlString $ReasoningEffort)),
        '-c', 'approval_policy="never"',
        # The process environment has already been scrubbed by name. Passing
        # the remaining values through makes GIT_CONFIG_GLOBAL=/dev/null and
        # the runner's stable PATH visible to model-generated commands.
        '-c', 'shell_environment_policy.inherit="all"',
        '-'
    )
}

function Get-CodexQuotaWait {
    # A failed CLI invocation plus an explicit service-limit signature is a
    # wait, not a verdict on the packet. The exit-code gate prevents a
    # successful agent report that merely discusses quotas from being misread.
    param([int]$ExitCode, [string]$Text)

    if ($ExitCode -eq 0 -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch '(?i)(usage limit|rate limit|too many requests|insufficient[_ ]quota|quota (?:has been )?exceeded|limit reached)') {
        return $null
    }

    $retryAfter = [DateTimeOffset]::UtcNow.AddMinutes(30)
    $hint = ''
    if ($Text -match '(?i)resets?\s+(?:at\s+)?(\d{1,2}):(\d{2})\s*(am|pm)?(?:\s*\(([^)]+)\))?') {
        $hint = $Matches[0]
        try {
            $hour = [int]$Matches[1]
            $minute = [int]$Matches[2]
            $meridiem = [string]$Matches[3]
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
    if ($retryAfter -le [DateTimeOffset]::UtcNow.AddMinutes(1)) {
        $retryAfter = [DateTimeOffset]::UtcNow.AddMinutes(30)
    }
    return [pscustomobject]@{
        RetryAfter = $retryAfter.ToUniversalTime()
        Hint       = $hint
        Text       = (Limit-Text $Text 400)
    }
}

function Set-CodexQuotaMarker {
    param([Parameter(Mandatory = $true)][string]$StateRoot, $QuotaWait)
    try {
        $path = Join-Path $StateRoot 'quota-wait.json'
        if ($null -eq $QuotaWait) {
            if (Test-Path -LiteralPath $path) {
                # A successful Codex round must not clear a Claude usage-window
                # marker. Both executors share this machine-state location so
                # the owner field is the isolation boundary.
                $owner = ''
                try { $owner = [string](Get-Prop (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json) 'executor' '') } catch { }
                if ($owner -eq 'codex') { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
            return ''
        }
        $payload = [ordered]@{
            executor    = 'codex'
            detected_at = ([DateTimeOffset]::UtcNow).ToString('o')
            retry_after = $QuotaWait.RetryAfter.ToString('o')
            hint        = $QuotaWait.Hint
            text        = $QuotaWait.Text
        }
        [IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        return $QuotaWait.RetryAfter.ToString('o')
    } catch { return '' }
}

function Get-CodexEventSummary {
    param([string]$JsonLines)

    $eventCount = 0
    $invalidCount = 0
    $threadId = ''
    $turnCompleted = $false
    $reportedModels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($line in ($JsonLines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { $invalidCount++; continue }
        $eventCount++
        $type = [string](Get-Prop $event 'type' '')
        if ($type -eq 'thread.started') { $threadId = [string](Get-Prop $event 'thread_id' '') }
        if ($type -eq 'turn.completed') { $turnCompleted = $true }
        if ($type -in @('error', 'turn.failed')) {
            $message = [string](Get-Prop $event 'message' (Get-Prop $event 'error' $type))
            [void]$errors.Add($message)
        }

        foreach ($candidate in @(
                (Get-Prop $event 'model' ''),
                (Get-Prop (Get-Prop $event 'response' $null) 'model' ''),
                (Get-Prop (Get-Prop $event 'item' $null) 'model' '')
            )) {
            $value = [string]$candidate
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$reportedModels.Add($value) }
        }
    }

    return [pscustomobject]@{
        EventCount     = $eventCount
        InvalidCount   = $invalidCount
        ThreadId       = $threadId
        TurnCompleted  = $turnCompleted
        ReportedModels = @($reportedModels)
        Errors         = @($errors)
    }
}

function Invoke-ActionCodexTask {
    <#
    .SYNOPSIS
        Delegates a bounded task to local Codex inside one registered project.
    #>
    param($Context)

    $codexConfig = Get-Prop $Context.Project.entry 'codex' $null
    if (-not [bool](Get-Prop $codexConfig 'enabled' $false)) {
        Throw-Denied ("project '{0}' has not enabled the codex executor (set codex.enabled=true in projects.json)" -f $Context.Project.key)
    }

    Assert-CodexRequestSurface -Params $Context.Params
    $prompt = [string](Get-Prop $Context.Params 'prompt' '')
    if ([string]::IsNullOrWhiteSpace($prompt)) { Throw-InvalidRequest 'codex_task requires params.prompt' }

    $maxPrompt = Get-CodexConfigInt -Config $codexConfig -Name 'max_prompt_chars' -Default 8000 -Min 1 -Max 200000
    if ($prompt.Length -gt $maxPrompt) {
        Throw-InvalidRequest "codex_task prompt exceeds the configured limit of $maxPrompt characters"
    }
    $timeout = Get-CodexConfigInt -Config $codexConfig -Name 'timeout_seconds' -Default 900 -Min 1 -Max 86400

    $model = [string](Get-Prop $codexConfig 'model' '')
    $reasoningEffort = [string](Get-Prop $codexConfig 'reasoning_effort' '')
    $sandbox = [string](Get-Prop $codexConfig 'sandbox' 'read-only')
    $tierName = [string](Get-Prop $Context.Params 'tier' '')
    $resolved = Resolve-CodexTier -CodexConfig $codexConfig -TierName $tierName `
        -ProjectKey $Context.Project.key -DefaultModel $model `
        -DefaultReasoningEffort $reasoningEffort -DefaultSandbox $sandbox
    Assert-CodexResolvedConfig -CodexConfig $codexConfig -Resolved $resolved -ProjectKey $Context.Project.key

    $exe = Resolve-CodexExecutable -Context $Context
    $steps = @()
    $removedEnvironment = @(Get-CodexRemovedEnvironmentNames)
    $codexEnvironment = @{}
    foreach ($key in $Context.ChildEnvironment.Keys) { $codexEnvironment[$key] = $Context.ChildEnvironment[$key] }
    # Do not expose user-level Git config or credential helpers to an
    # issue-authored prompt. Repository and system config remain available.
    $codexEnvironment['GIT_CONFIG_GLOBAL'] = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $trustedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())

    # Capture the binary identity actually launched. This remains useful even
    # when the JSONL protocol does not report a provider-side model identity.
    $version = Invoke-CapturedProcess -FilePath $exe -Arguments @('--version') `
        -WorkingDirectory $Context.Project.workspace -TimeoutSeconds 30 -Name 'codex_version' `
        -Environment $codexEnvironment -RemoveEnvironment $removedEnvironment `
        -StdoutLimit 2000 -StderrLimit 2000
    $steps += $version
    if ($version.exit_code -ne 0) {
        return [pscustomobject]@{ Status = $script:GptLoopStatus.EnvironmentError; Steps = $steps }
    }

    $argv = New-CodexExecArguments -Workspace $Context.Project.workspace -Model $resolved.Model `
        -ReasoningEffort $resolved.ReasoningEffort -Sandbox $resolved.Sandbox `
        -TrustedTempDirectory $trustedTemp

    # Prompt goes over stdin, not argv: it remains bounded but is absent from
    # the process list and does not consume command-line length.
    $step = Invoke-CapturedProcess -FilePath $exe -Arguments $argv `
        -WorkingDirectory $Context.Project.workspace -TimeoutSeconds $timeout -Name 'codex_task' `
        -Environment $codexEnvironment -RemoveEnvironment $removedEnvironment `
        -StandardInputText $prompt -StdoutLimit 40000
    $steps += $step

    $status = if ($step.exit_code -eq 0) { $script:GptLoopStatus.Success } else { $script:GptLoopStatus.Failure }
    $fullOut = [string](Get-Prop $step 'full_stdout' $step.stdout)
    $fullErr = [string](Get-Prop $step 'full_stderr' $step.stderr)
    $events = Get-CodexEventSummary -JsonLines $fullOut

    $summary = New-Step -Name 'codex_task_summary' -ExitCode ([int]$step.exit_code)
    $reported = if ($events.ReportedModels.Count -gt 0) { $events.ReportedModels -join ',' } else { '(not reported by codex-cli)' }
    $cliVersion = (([string](Get-Prop $version 'full_stdout' $version.stdout)) + ' ' + ([string](Get-Prop $version 'full_stderr' $version.stderr))).Trim()
    $summary.stdout = @(
        'executor=codex'
        "tier=$(if ($tierName) { $tierName } else { '(default)' })"
        "model_configured=$($resolved.Model)"
        "model_argument_ran=$($resolved.Model)"
        "reasoning_effort_configured=$($resolved.ReasoningEffort)"
        "reasoning_effort_argument_ran=$($resolved.ReasoningEffort)"
        "sandbox_configured=$($resolved.Sandbox)"
        'permission_profile_argument_ran=gptloop'
        "workspace_access_argument_ran=$(if ($resolved.Sandbox -eq 'workspace-write') { 'write' } else { 'read' })"
        'command_network_argument_ran=false'
        'credential_environment_policy=sensitive_names_removed'
        'git_global_config_environment=disabled'
        "trusted_temp_write_argument_ran=$trustedTemp"
        'approval_policy_configured=never'
        'approval_policy_argument_ran=never'
        "cli_version_ran=$cliVersion"
        "model_reported_by_cli=$reported"
        "thread_id=$($events.ThreadId)"
        "json_events=$($events.EventCount) invalid_json_lines=$($events.InvalidCount)"
        "turn_completed=$($events.TurnCompleted)"
    ) -join "`n"

    if ($step.exit_code -eq 0 -and ($events.EventCount -eq 0 -or -not $events.TurnCompleted)) {
        $status = $script:GptLoopStatus.Failure
        $summary.stderr = 'codex exited 0 without a parseable turn.completed JSONL event'
    }
    if ($events.Errors.Count -gt 0) {
        $status = $script:GptLoopStatus.Failure
        $summary.stderr = Limit-Text ($events.Errors -join "`n") 4000
    }

    $quota = Get-CodexQuotaWait -ExitCode ([int]$step.exit_code) -Text ($fullOut + "`n" + $fullErr)
    if ($null -ne $quota) {
        $status = $script:GptLoopStatus.QuotaWait
        $retryAfter = Set-CodexQuotaMarker -StateRoot $Context.StateRoot -QuotaWait $quota
        $summary.stdout += "`nquota_wait=true retry_after=$retryAfter hint=$($quota.Hint)"
    } else {
        Set-CodexQuotaMarker -StateRoot $Context.StateRoot -QuotaWait $null | Out-Null
    }

    $steps += $summary
    return [pscustomobject]@{ Status = $status; Steps = $steps }
}
