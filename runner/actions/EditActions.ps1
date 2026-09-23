# EditActions.ps1 -- constrained write actions (exact replacement, unified diff).

Set-StrictMode -Version Latest

function Get-DominantNewline {
    <#
    .SYNOPSIS
        Detects a file's line-ending convention without modifying it.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $crlf = ([regex]::Matches($Text, "`r`n")).Count
    $lf = ([regex]::Matches($Text, "`n")).Count - $crlf
    if ($crlf -gt 0 -and $crlf -ge $lf) { return "`r`n" }
    if ($lf -gt 0) { return "`n" }
    return [Environment]::NewLine
}

function ConvertTo-Newline {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Newline)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # Normalise to LF first so mixed input converges, then emit the target.
    $lfText = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if ($Newline -eq "`n") { return $lfText }
    return ($lfText -replace "`n", $Newline)
}

function Measure-Occurrence {
    param([Parameter(Mandatory = $true)][string]$Haystack, [Parameter(Mandatory = $true)][string]$Needle)
    $count = 0
    $index = 0
    while ($true) {
        $found = $Haystack.IndexOf($Needle, $index, [StringComparison]::Ordinal)
        if ($found -lt 0) { break }
        $count++
        $index = $found + $Needle.Length
    }
    return $count
}

function Invoke-ActionReplaceText {
    <#
    .SYNOPSIS
        Exact, count-checked text replacement that preserves line endings.
    .DESCRIPTION
        Newline semantics are deliberate rather than accidental:

          newline_mode = 'auto'  (default) -- the needle and replacement are
            translated to the FILE's existing convention before matching. The
            file itself is never normalised. This is what makes a CRLF file
            editable from a JSON payload that necessarily carries LF.

          newline_mode = 'exact' -- byte-exact matching with no translation, for
            callers that genuinely need to match mixed endings.

        Fails closed: if the number of occurrences found is not exactly
        `expected_count` (default 1), nothing is written.
    #>
    param($Context)
    $params = $Context.Params

    $relative = [string](Get-Prop $params 'path' '')
    if ([string]::IsNullOrWhiteSpace($relative)) { Throw-InvalidRequest 'replace_text requires params.path' }

    if (-not (Test-HasProp $params 'old')) { Throw-InvalidRequest 'replace_text requires params.old' }
    if (-not (Test-HasProp $params 'new')) { Throw-InvalidRequest 'replace_text requires params.new' }
    $old = [string](Get-Prop $params 'old' '')
    $new = [string](Get-Prop $params 'new' '')
    if ([string]::IsNullOrEmpty($old)) { Throw-InvalidRequest 'replace_text requires a non-empty params.old' }

    $expected = Get-IntProp $params 'expected_count' 1 1 1000
    $mode = [string](Get-Prop $params 'newline_mode' 'auto')
    if ($mode -notin @('auto', 'exact')) {
        Throw-InvalidRequest "params.newline_mode must be 'auto' or 'exact'"
    }

    $full = Resolve-SafePath -RelativePath $relative -Workspace $Context.Project.workspace `
        -AllowedRoots $Context.Project.allowed_roots -AllowedFiles $Context.Project.allowed_files

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{
            Status = $script:GptLoopStatus.Failure
            Steps  = @(New-Step -Name "replace_text $relative" -ExitCode 1 -Stderr "file not found: $relative")
        }
    }

    $bytes = [IO.File]::ReadAllBytes($full)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $content = [IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)

    $newline = Get-DominantNewline $content
    $needle = $old
    $replacement = $new
    if ($mode -eq 'auto') {
        $needle = ConvertTo-Newline -Text $old -Newline $newline
        $replacement = ConvertTo-Newline -Text $new -Newline $newline
    }

    $found = Measure-Occurrence -Haystack $content -Needle $needle
    if ($found -ne $expected) {
        $newlineName = if ($newline -eq "`r`n") { 'CRLF' } else { 'LF' }
        return [pscustomobject]@{
            Status = $script:GptLoopStatus.Failure
            # NOTE: -f binds tighter than +, so the concatenation must be
            # parenthesised or only the trailing literal gets formatted.
            Steps  = @(New-Step -Name "replace_text $relative" -ExitCode 1 -Stderr (
                    ("expected {0} occurrence(s) of params.old but found {1}; nothing was written " +
                    "(file newline convention is {2}, newline_mode={3})") -f $expected, $found, $newlineName, $mode))
        }
    }

    $updated = $content.Replace($needle, $replacement)

    # Write UTF-8, preserving whether the file originally carried a BOM.
    $encoding = [System.Text.UTF8Encoding]::new($hadBom)
    [IO.File]::WriteAllText($full, $updated, $encoding)

    $newlineName = if ($newline -eq "`r`n") { 'CRLF' } else { 'LF' }
    $step = New-Step -Name "replace_text $relative" -Stdout (@(
            "path=$relative"
            "occurrences_replaced=$found"
            "newline=$newlineName"
            "newline_mode=$mode"
            "old_chars=$($content.Length)"
            "new_chars=$($updated.Length)"
            "bom=$hadBom"
        ) -join "`n")
    return [pscustomobject]@{ Status = $script:GptLoopStatus.Success; Steps = @($step) }
}

function Get-PatchTargets {
    <#
    .SYNOPSIS
        Validates that a patch is a real unified diff aimed only at allowed files.
    .DESCRIPTION
        Exactly one patch format is accepted: unified diff with `--- a/path` and
        `+++ b/path` headers. Pseudo-diff dialects such as
        `*** Begin Patch` / `*** Update File` are rejected explicitly rather than
        silently ignored, because an unrecognised header previously produced the
        confusing "patch contains no recognized safe file targets".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Patch,
        [Parameter(Mandatory = $true)]$Context
    )
    if ([string]::IsNullOrWhiteSpace($Patch)) { Throw-InvalidRequest 'apply_patch requires params.patch' }
    if ($Patch.Length -gt 200000) { Throw-InvalidRequest 'patch exceeds the 200 KB limit' }

    if ($Patch -match '(?m)^\*\*\*\s+(Begin Patch|Update File|Add File|Delete File|End Patch)') {
        Throw-InvalidRequest ('patch uses the unsupported "*** Begin Patch" pseudo-diff dialect; ' +
            'gpt-loop accepts unified diffs with "--- a/path" and "+++ b/path" headers only')
    }

    $targets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($Patch -split "`r?`n")) {
        if ($line -match '^(---|\+\+\+)\s+(.+)$') {
            $raw = $Matches[2].Trim()
            if ($raw -eq '/dev/null') { continue }
            $raw = ($raw -split "`t")[0].Trim()
            if ($raw -match '^"(.*)"$') { $raw = $Matches[1] }
            if ($raw.StartsWith('a/') -or $raw.StartsWith('b/')) { $raw = $raw.Substring(2) }
            # Denies on anything outside the project surface.
            [void](Resolve-SafePath -RelativePath $raw -Workspace $Context.Project.workspace `
                    -AllowedRoots $Context.Project.allowed_roots -AllowedFiles $Context.Project.allowed_files)
            [void]$targets.Add($raw)
        }
    }
    if ($targets.Count -eq 0) {
        Throw-InvalidRequest ('patch contains no recognized unified-diff file headers; ' +
            'expected lines of the form "--- a/path" and "+++ b/path"')
    }
    return @($targets)
}

function Invoke-ActionApplyPatch {
    param($Context)
    $patch = [string](Get-Prop $Context.Params 'patch' '')
    $targets = Get-PatchTargets -Patch $patch -Context $Context

    $tempDir = $env:RUNNER_TEMP
    if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = [IO.Path]::GetTempPath() }
    $patchFile = Join-Path $tempDir ("gptloop-" + [Guid]::NewGuid().ToString('N') + '.patch')
    [IO.File]::WriteAllText($patchFile, $patch, [System.Text.UTF8Encoding]::new($false))

    $steps = @()
    try {
        $check = Invoke-CapturedProcess -FilePath (Get-PlatformExecutable 'git') `
            -Arguments @('apply', '--check', '--whitespace=nowarn', $patchFile) `
            -WorkingDirectory $Context.Project.workspace -TimeoutSeconds 60 -Name 'git apply --check'
        $steps += $check
        if ($check.exit_code -ne 0) {
            return [pscustomobject]@{ Status = $script:GptLoopStatus.Failure; Steps = $steps }
        }

        $apply = Invoke-CapturedProcess -FilePath (Get-PlatformExecutable 'git') `
            -Arguments @('apply', '--whitespace=nowarn', $patchFile) `
            -WorkingDirectory $Context.Project.workspace -TimeoutSeconds 60 -Name 'git apply'
        $steps += $apply
        if ($apply.exit_code -ne 0) {
            return [pscustomobject]@{ Status = $script:GptLoopStatus.Failure; Steps = $steps }
        }

        $steps += New-Step -Name 'patch_targets' -Stdout ($targets -join "`n")
        return [pscustomobject]@{ Status = $script:GptLoopStatus.Success; Steps = $steps }
    } finally {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
    }
}
