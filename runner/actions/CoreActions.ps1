# CoreActions.ps1 -- generic, project-agnostic read actions.

Set-StrictMode -Version Latest

function Invoke-ActionPing {
    param($Context)
    $steps = @()
    $steps += New-Step -Name 'environment' -Stdout (@(
            "computer=$env:COMPUTERNAME"
            "user=$env:USERNAME"
            "project=$($Context.Project.key)"
            "profile=$($Context.Project.profile_name)"
            "workspace=$($Context.Project.workspace)"
            "powershell=$($PSVersionTable.PSVersion)"
        ) -join "`n")
    return [pscustomobject]@{ Status = $script:GptLoopStatus.Success; Steps = $steps }
}

function Invoke-ActionGitStatus {
    param($Context)
    $step = Invoke-CapturedProcess -FilePath (Get-PlatformExecutable 'git') -Arguments @('status', '-sb') `
        -WorkingDirectory $Context.Project.workspace -TimeoutSeconds 60 -Name 'git status'
    $status = if ($step.exit_code -eq 0) { $script:GptLoopStatus.Success } else { $script:GptLoopStatus.Failure }
    return [pscustomobject]@{ Status = $status; Steps = @($step) }
}

function Invoke-ActionGitDiff {
    param($Context)
    $step = Invoke-CapturedProcess -FilePath (Get-PlatformExecutable 'git') -Arguments @('diff', '--no-ext-diff', '--') `
        -WorkingDirectory $Context.Project.workspace -TimeoutSeconds 120 -Name 'git diff'
    $status = if ($step.exit_code -eq 0) { $script:GptLoopStatus.Success } else { $script:GptLoopStatus.Failure }
    return [pscustomobject]@{ Status = $status; Steps = @($step) }
}

function Invoke-ActionReadFile {
    param($Context)
    $params = $Context.Params
    $relative = [string](Get-Prop $params 'path' '')
    if ([string]::IsNullOrWhiteSpace($relative)) { Throw-InvalidRequest 'read_file requires params.path' }

    $maxBytes = Get-IntProp $params 'max_bytes' 200000 1 2000000

    $full = Resolve-SafePath -RelativePath $relative -Workspace $Context.Project.workspace `
        -AllowedRoots $Context.Project.allowed_roots -AllowedFiles $Context.Project.allowed_files

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{
            Status = $script:GptLoopStatus.Failure
            Steps  = @(New-Step -Name "read_file $relative" -ExitCode 1 -Stderr "file not found: $relative")
        }
    }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -gt $maxBytes) {
        return [pscustomobject]@{
            Status = $script:GptLoopStatus.Failure
            Steps  = @(New-Step -Name "read_file $relative" -ExitCode 1 `
                    -Stderr ("file is {0} bytes, exceeding the {1}-byte read limit" -f $item.Length, $maxBytes))
        }
    }

    $content = [IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    $step = New-Step -Name "read_file $relative" -Stdout (Limit-Text $content 50000) `
        -Truncated ($content.Length -gt 50000)
    Add-Member -InputObject $step -NotePropertyName 'full_stdout' -NotePropertyValue $content -Force
    return [pscustomobject]@{ Status = $script:GptLoopStatus.Success; Steps = @($step) }
}

function Invoke-ActionReadResult {
    <#
    .SYNOPSIS
        Returns a bounded slice of a previously stored full local result.
    .DESCRIPTION
        GitHub comments are capped, so large results live in
        <state root>/results/<job_id>.json. This is the retrieval path.
        The job id is validated as a UUID so it can only ever name a file the
        control plane itself wrote.
    #>
    param($Context)
    $params = $Context.Params
    $targetJob = [string](Get-Prop $params 'job_id' '')
    if ($targetJob -notmatch '^[0-9a-fA-F-]{8,64}$') {
        Throw-InvalidRequest 'read_result requires params.job_id to be a job identifier'
    }
    $offset = Get-IntProp $params 'offset' 0 0 100000000
    $length = Get-IntProp $params 'length' 40000 1 200000

    $path = Join-Path (Join-Path $Context.StateRoot 'results') "$targetJob.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Status = $script:GptLoopStatus.Failure
            Steps  = @(New-Step -Name 'read_result' -ExitCode 1 -Stderr "no stored result for job $targetJob")
        }
    }
    $text = [IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($offset -ge $text.Length) {
        $slice = ''
    } else {
        $slice = $text.Substring($offset, [Math]::Min($length, $text.Length - $offset))
    }
    $step = New-Step -Name 'read_result' -Stdout $slice `
        -Truncated (($offset + $slice.Length) -lt $text.Length)
    Add-Member -InputObject $step -NotePropertyName 'total_chars' -NotePropertyValue $text.Length -Force
    return [pscustomobject]@{ Status = $script:GptLoopStatus.Success; Steps = @($step) }
}
