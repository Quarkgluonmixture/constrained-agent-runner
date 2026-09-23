# Process.ps1 -- bounded child-process execution with process-tree termination.

Set-StrictMode -Version Latest

function Invoke-CapturedProcess {
    <#
    .SYNOPSIS
        Runs a child process, capturing bounded stdout/stderr with a hard timeout.
    .DESCRIPTION
        Returns a step record. It does NOT throw on a nonzero exit code -- the
        caller decides whether a nonzero code means `failure`, `inapplicable`, or
        something else, because that judgement is project-specific.

        On timeout the whole process TREE is killed and a timeout error is
        raised, so a hung pytest cannot leave orphans holding the lock.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1200,
        [string]$Name = 'command',
        [hashtable]$Environment = @{},
        [string[]]$RemoveEnvironment = @(),
        [AllowEmptyString()][string]$StandardInputText = $null,
        [int]$StdoutLimit = 45000,
        [int]$StderrLimit = 12000
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        $resolved = Get-Command $FilePath -ErrorAction SilentlyContinue
        if ($null -eq $resolved) {
            Throw-EnvironmentError "executable not found: $FilePath"
        }
        $FilePath = $resolved.Source
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add([string]$arg) }
    foreach ($key in $Environment.Keys) {
        $psi.Environment[[string]$key] = [string]$Environment[$key]
    }
    foreach ($key in $RemoveEnvironment) {
        [void]$psi.Environment.Remove([string]$key)
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()
    } catch {
        Throw-EnvironmentError "failed to start ${Name}: $($_.Exception.Message)"
    }

    # Async reads prevent a full pipe buffer from deadlocking the child.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdinTimedOut = $false
    if ($null -ne $StandardInputText) {
        # WriteAsync matters for bounded execution: a child that never reads
        # stdin must not fill the pipe and block this process before the timeout
        # clock reaches WaitForExit.
        try {
            $stdinTask = $proc.StandardInput.WriteAsync($StandardInputText)
            try {
                $stdinTimedOut = -not $stdinTask.Wait($TimeoutSeconds * 1000)
            } catch {
                # A child can close stdin immediately after rejecting an option.
                # Its output and exit code below remain the source of truth.
            }
        } catch { }
    }
    if (-not $stdinTimedOut) {
        try { $proc.StandardInput.Close() } catch { }
    }

    $remainingMs = [Math]::Max(0, ($TimeoutSeconds * 1000) - [int]$sw.ElapsedMilliseconds)
    $timedOut = $stdinTimedOut -or -not $proc.WaitForExit($remainingMs)

    if ($timedOut) {
        Stop-ProcessTree -ProcessId $proc.Id
        $sw.Stop()
        # Give the pipes a moment to flush what the child already produced.
        $partialOut = ''
        $partialErr = ''
        try { if ($stdoutTask.Wait(2000)) { $partialOut = $stdoutTask.Result } } catch { }
        try { if ($stderrTask.Wait(2000)) { $partialErr = $stderrTask.Result } } catch { }
        $step = New-Step -Name $Name -ExitCode 124 -DurationMs ([int]$sw.ElapsedMilliseconds) `
            -Stdout (Limit-Text $partialOut $StdoutLimit) `
            -Stderr (Limit-Text $partialErr $StderrLimit) `
            -Truncated $true
        $script:GptLoopLastStep = $step
        Throw-Timeout "$Name timed out after $TimeoutSeconds seconds"
    }

    $stdout = ''
    $stderr = ''
    try { $stdoutTask.Wait(10000) | Out-Null; $stdout = $stdoutTask.Result } catch { }
    try { $stderrTask.Wait(10000) | Out-Null; $stderr = $stderrTask.Result } catch { }
    $sw.Stop()

    $truncated = ($stdout.Length -gt $StdoutLimit) -or ($stderr.Length -gt $StderrLimit)

    $step = New-Step -Name $Name -ExitCode $proc.ExitCode -DurationMs ([int]$sw.ElapsedMilliseconds) `
        -Stdout (Limit-Text $stdout $StdoutLimit) `
        -Stderr (Limit-Text $stderr $StderrLimit) `
        -Truncated $truncated

    # Keep the untruncated text available for the full local result file.
    Add-Member -InputObject $step -NotePropertyName 'full_stdout' -NotePropertyValue $stdout -Force
    Add-Member -InputObject $step -NotePropertyName 'full_stderr' -NotePropertyValue $stderr -Force

    try { $proc.Dispose() } catch { }
    return $step
}

function Get-DescendantProcessId {
    <#
    .SYNOPSIS
        Collects the full descendant PID set of a process, deepest first.
    .DESCRIPTION
        The snapshot must be taken BEFORE anything is killed. Once the root dies,
        its grandchildren are reparented and the tree can no longer be walked --
        which is how `taskkill /T` alone lets a detached grandchild survive.
    #>
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $byParent = Get-ParentChildProcessMap
    if ($byParent.Count -eq 0) { return @() }

    $ordered = [System.Collections.Generic.List[int]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $frontier = [System.Collections.Generic.List[int]]::new()
    [void]$frontier.Add($ProcessId)

    while ($frontier.Count -gt 0) {
        $next = [System.Collections.Generic.List[int]]::new()
        foreach ($current in $frontier) {
            if (-not $byParent.ContainsKey($current)) { continue }
            foreach ($child in $byParent[$current]) {
                if ($child -eq $current) { continue }
                if (-not $seen.Add($child)) { continue }
                [void]$ordered.Add($child)
                [void]$next.Add($child)
            }
        }
        $frontier = $next
    }

    # Reverse so leaves are killed before their parents.
    $ordered.Reverse()
    return @($ordered)
}

function Get-ParentChildProcessMap {
    <#
    .SYNOPSIS
        pid -> [child pids] for every process on this machine.
    .DESCRIPTION
        ⭐ The **only** platform-specific part of the tree walk. Everything above
        it -- snapshot before killing, leaves first, one more sweep for anything
        that reparented -- is the same scar on both platforms and stays written
        once.

        ⚠️ Windows answers through WMI. POSIX answers through `ps`, which is in
        POSIX.1 and present on macOS and Linux alike; ⛔ `pgrep -P` is not used
        because it would need one invocation per node and the whole point of the
        snapshot is that it is taken at a single instant, before anything dies.
    #>
    $byParent = @{}

    if ($IsWindows) {
        $all = @()
        try {
            $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
        } catch {
            return $byParent
        }
        foreach ($p in $all) {
            $parent = [int]$p.ParentProcessId
            if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = [System.Collections.Generic.List[int]]::new() }
            [void]$byParent[$parent].Add([int]$p.ProcessId)
        }
        return $byParent
    }

    $lines = @()
    try {
        # `-A` every process, `-o pid=,ppid=` values only. ⛔ No header to skip
        # and no locale-dependent column widths to parse.
        $lines = @(& ps -A -o pid=,ppid= 2>$null)
    } catch {
        return $byParent
    }
    foreach ($line in $lines) {
        $fields = ([string]$line).Trim() -split '\s+'
        if ($fields.Count -lt 2) { continue }
        $childId = 0; $parentId = 0
        if (-not [int]::TryParse($fields[0], [ref]$childId)) { continue }
        if (-not [int]::TryParse($fields[1], [ref]$parentId)) { continue }
        if (-not $byParent.ContainsKey($parentId)) { $byParent[$parentId] = [System.Collections.Generic.List[int]]::new() }
        [void]$byParent[$parentId].Add($childId)
    }
    return $byParent
}

function Stop-ProcessTree {
    <#
    .SYNOPSIS
        Kills a process and every descendant, leaves first.
    #>
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $descendants = Get-DescendantProcessId -ProcessId $ProcessId

    foreach ($childId in $descendants) {
        try { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue } catch { }
    }
    # ⚠️ `taskkill /T` is a belt-and-braces second pass on Windows only, and it
    # is ⛔ not the mechanism: it cannot see a grandchild that already
    # reparented, which is exactly why the snapshot above exists.
    if ($IsWindows) {
        try { $null = & taskkill.exe /PID $ProcessId /T /F 2>&1 } catch { }
    }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }

    # Anything that reparented mid-kill gets one more sweep.
    foreach ($childId in $descendants) {
        try {
            $still = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($null -ne $still) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
}
