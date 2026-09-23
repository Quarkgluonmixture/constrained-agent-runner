# SafePath.ps1 -- allowlist-first path resolution.
#
# The issue body is untrusted input. It may never choose a filesystem root: the
# workspace comes from the local project registry, and the path inside it must
# survive every check below. Fail closed on anything ambiguous.

Set-StrictMode -Version Latest

# Denied anywhere in the path, regardless of profile allowlists. `.github` and
# `.git` protect the control plane from rewriting its own security surface.
$script:GptLoopAlwaysDenied = @(
    '.git',
    '.github',
    '.env',
    'secrets',
    'node_modules'
)

function Resolve-RealPath {
    <#
    .SYNOPSIS
        Fully resolves a path including symlinks/junctions/reparse points.
    .DESCRIPTION
        [IO.Path]::GetFullPath only performs lexical normalisation, so a junction
        inside the workspace pointing at C:\Windows would still look "inside".
        This walks the existing prefix of the path and resolves link targets so
        the containment check operates on the real location.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)

    # Find the deepest existing ancestor; only existing items can be links.
    $existing = $full
    $tail = @()
    while (-not [string]::IsNullOrEmpty($existing) -and -not (Test-Path -LiteralPath $existing)) {
        $parent = [IO.Path]::GetDirectoryName($existing)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $existing) { break }
        $tail = , ([IO.Path]::GetFileName($existing)) + $tail
        $existing = $parent
    }

    if (-not [string]::IsNullOrEmpty($existing) -and (Test-Path -LiteralPath $existing)) {
        # Resolve up to a bounded number of link hops to avoid cycles.
        for ($hop = 0; $hop -lt 16; $hop++) {
            $item = Get-Item -LiteralPath $existing -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) { break }
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { break }
            $target = $null
            try { $target = $item.ResolveLinkTarget($true) } catch { $target = $null }
            if ($null -eq $target) { break }
            $existing = $target.FullName
        }
        if ($tail.Count -gt 0) {
            $full = [IO.Path]::GetFullPath((Join-Path $existing ($tail -join [IO.Path]::DirectorySeparatorChar)))
        } else {
            $full = [IO.Path]::GetFullPath($existing)
        }
    }

    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathContained {
    <#
    .SYNOPSIS
        True when $Candidate is $Root itself or lives underneath it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )
    $rootNorm = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($Candidate.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootNorm + [IO.Path]::DirectorySeparatorChar
    return $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-SafePath {
    <#
    .SYNOPSIS
        Maps an untrusted relative path onto a concrete absolute path, or denies it.
    .PARAMETER RelativePath
        Untrusted, from the issue body.
    .PARAMETER Workspace
        Absolute, already-resolved workspace root from the project registry.
    .PARAMETER AllowedRoots
        Profile-configured directory prefixes (e.g. 'src/'), relative and slash-normalised.
    .PARAMETER AllowedFiles
        Profile-configured exact root-level filenames (e.g. 'README.md').
    #>
    param(
        [string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [string[]]$AllowedRoots = @(),
        [string[]]$AllowedFiles = @()
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        Throw-InvalidRequest 'path is required'
    }

    # Reject anything that is not a plain relative path before normalising, so a
    # UNC/drive/rooted form can never be silently reinterpreted.
    if ($RelativePath -match '^[a-zA-Z]:') {
        Throw-Denied "absolute (drive-qualified) paths are not allowed: $RelativePath"
    }
    if ($RelativePath.StartsWith('\\')) {
        Throw-Denied "UNC paths are not allowed: $RelativePath"
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        Throw-Denied "absolute paths are not allowed: $RelativePath"
    }
    if ($RelativePath -match '[\x00-\x1f]') {
        Throw-Denied 'path contains control characters'
    }
    # ADS / device names on Windows.
    if ($RelativePath -match ':') {
        Throw-Denied "path contains a drive or alternate-data-stream separator: $RelativePath"
    }

    # Normalise both slash styles, then reject traversal in either form.
    $normalized = ($RelativePath -replace '\\', '/').Trim()
    while ($normalized.StartsWith('/')) { $normalized = $normalized.Substring(1) }
    $segments = @($normalized -split '/' | Where-Object { $_ -ne '' -and $_ -ne '.' })
    foreach ($seg in $segments) {
        if ($seg -eq '..') {
            Throw-Denied "path traversal is not allowed: $RelativePath"
        }
        if ($seg.EndsWith(' ') -or $seg.EndsWith('.')) {
            # Windows silently strips these, which would defeat exact matching.
            Throw-Denied "path segment has a trailing dot or space: $RelativePath"
        }
    }
    if ($segments.Count -eq 0) { Throw-InvalidRequest 'path is required' }
    $normalized = $segments -join '/'

    # Always-denied surfaces, matched per segment so `.github` cannot be reached
    # as `app/../.github` (already blocked) nor as a nested `x/.github/y`.
    foreach ($seg in $segments) {
        foreach ($denied in $script:GptLoopAlwaysDenied) {
            if ($seg.Equals($denied, [StringComparison]::OrdinalIgnoreCase)) {
                Throw-Denied "path is denied by the control-plane denylist: $RelativePath"
            }
        }
    }

    # Allowlist: a configured directory prefix, or an exact root-level file.
    $allowed = $false
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $r = ($root -replace '\\', '/').TrimStart('/')
        if (-not $r.EndsWith('/')) { $r = $r + '/' }
        if ($normalized.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        foreach ($file in $AllowedFiles) {
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            $f = ($file -replace '\\', '/').TrimStart('/')
            if ($normalized.Equals($f, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
        }
    }
    if (-not $allowed) {
        Throw-Denied "path is outside the allowed project surface: $RelativePath"
    }

    # Final containment check against the real (link-resolved) location.
    $workspaceReal = Resolve-RealPath $Workspace
    $full = Resolve-RealPath (Join-Path $workspaceReal $normalized)
    if (-not (Test-PathContained -Root $workspaceReal -Candidate $full)) {
        Throw-Denied "resolved path escaped the workspace: $RelativePath"
    }

    return $full
}
