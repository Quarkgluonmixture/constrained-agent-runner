# Registry.ps1 -- trusted local project registry and profile loading.
#
# The GitHub broker envelope names a *project key*, never a workspace path. The
# mapping from key to filesystem root lives only on this machine, under the
# platform state root (see Get-GptLoopStateRoot), and is therefore trusted input.
# A project entry may additionally bind its canonical GitHub repository so a
# non-authorizing request work_ref cannot silently point at a different project.

Set-StrictMode -Version Latest

function Get-GptLoopStateRoot {
    <#
    .SYNOPSIS
        Where this machine keeps its registry, token, results and locks.
    .DESCRIPTION
        Per-platform on purpose. ⚠️ `[Environment]::GetFolderPath('LocalApplicationData')`
        answers on macOS too, but it answers `~/.local/share`, which is the XDG
        *data* location and not where a Mac user would look. The state root is
        something an operator has to find by hand when the loop misbehaves, so
        it follows each platform's own convention rather than whichever one .NET
        happens to return.

        `GPTLOOP_STATE_ROOT` overrides everything; the test fixtures rely on it.
    #>
    param([string]$Override = '')
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    if (-not [string]::IsNullOrWhiteSpace($env:GPTLOOP_STATE_ROOT)) { return $env:GPTLOOP_STATE_ROOT }

    if ($IsWindows) {
        $local = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($local)) { $local = [Environment]::GetFolderPath('LocalApplicationData') }
        return (Join-Path $local 'GPTLoop')
    }
    if ($IsMacOS) {
        return (Join-Path $HOME 'Library/Application Support/GPTLoop')
    }
    $xdg = $env:XDG_STATE_HOME
    if ([string]::IsNullOrWhiteSpace($xdg)) { $xdg = Join-Path $HOME '.local/state' }
    return (Join-Path $xdg 'gptloop')
}

function Get-GptLoopInstallHint {
    # ⛔ Naming the wrong installer is worse than naming none: it sends the
    # operator to a script that cannot run on their machine.
    if ($IsWindows) { return 'run scripts/install-windows.ps1' }
    return 'run scripts/install-macos.ps1'
}

function Test-GitHubRepositoryIdentity {
    <#
    .SYNOPSIS
        Conservative owner/repository syntax gate used for provenance metadata.
    .DESCRIPTION
        This is intentionally narrower than GitHub's complete naming grammar.
        GPT Loop only needs a stable canonical identity, so values such as '.' or
        '..' are rejected even though a permissive character-class regex would
        otherwise accept them. The value is metadata only and never a URL/path.
    #>
    param([Parameter(Mandatory = $true)][string]$Repository)

    if ($Repository.Length -gt 200) { return $false }
    # Plain -split is intentional. PowerShell 7 gives negative Max-substrings
    # values right-to-left semantics; using `-split '/', -1` therefore does NOT
    # mean "unbounded" and caused valid owner/repo identities to fail on Windows.
    $parts = @($Repository -split '/')
    if ($parts.Count -ne 2) { return $false }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { return $false }
        if ($part -in @('.', '..')) { return $false }
        if ($part -notmatch '^[A-Za-z0-9_.-]+$') { return $false }
    }
    return $true
}

function Get-ProjectRegistry {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $path = Join-Path $StateRoot 'projects.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-EnvironmentError "project registry not found: $path ($(Get-GptLoopInstallHint))"
    }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        Throw-EnvironmentError "project registry is not valid JSON: $path"
    }
    return $parsed
}

function Resolve-Project {
    <#
    .SYNOPSIS
        Looks up an untrusted project key in the trusted registry.
    .OUTPUTS
        A descriptor with resolved workspace, profile object, and interpreters.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectKey,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if ($ProjectKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        Throw-InvalidRequest "project key has an invalid form: $ProjectKey"
    }

    $registry = Get-ProjectRegistry -StateRoot $StateRoot
    $projects = Get-Prop $registry 'projects' $null
    if ($null -eq $projects) {
        Throw-EnvironmentError 'project registry has no "projects" object'
    }

    $entry = Get-Prop $projects $ProjectKey $null
    if ($null -eq $entry) {
        # Deliberately does not list known keys: the requester should already
        # know them, and enumeration is not something the issue body earns.
        Throw-Denied "project is not registered on this machine: $ProjectKey"
    }

    $workspaceRaw = [string](Get-Prop $entry 'workspace' '')
    if ([string]::IsNullOrWhiteSpace($workspaceRaw)) {
        Throw-EnvironmentError "project '$ProjectKey' has no workspace configured"
    }
    if (-not (Test-Path -LiteralPath $workspaceRaw -PathType Container)) {
        Throw-EnvironmentError "workspace for project '$ProjectKey' does not exist: $workspaceRaw"
    }
    $workspace = Resolve-RealPath $workspaceRaw

    $profileName = [string](Get-Prop $entry 'profile' 'generic')
    $profile = Get-Profile -Name $profileName -RepoRoot $RepoRoot

    # Profile supplies the default path surface; the registry entry may narrow or
    # extend it for this specific project.
    $allowedRoots = @(Get-Prop $profile 'allowed_roots' @())
    $allowedFiles = @(Get-Prop $profile 'allowed_files' @())
    $overrideRoots = Get-Prop $entry 'allowed_roots' $null
    if ($null -ne $overrideRoots) { $allowedRoots = @($overrideRoots) }
    $overrideFiles = Get-Prop $entry 'allowed_files' $null
    if ($null -ne $overrideFiles) { $allowedFiles = @($overrideFiles) }

    $repository = [string](Get-Prop $entry 'repository' '')
    if (-not [string]::IsNullOrWhiteSpace($repository) -and
        -not (Test-GitHubRepositoryIdentity -Repository $repository)) {
        Throw-EnvironmentError "project '$ProjectKey' has invalid repository binding in projects.json: $repository"
    }

    return [pscustomobject][ordered]@{
        key              = $ProjectKey
        workspace        = $workspace
        repository       = $repository
        require_work_ref = [bool](Get-Prop $entry 'require_work_ref' $false)
        profile_name     = $profileName
        profile          = $profile
        allowed_roots    = $allowedRoots
        allowed_files    = $allowedFiles
        entry            = $entry
    }
}

function Resolve-ProjectWorkRef {
    <#
    .SYNOPSIS
        Validates and normalizes a broker envelope's canonical project-work link.
    .DESCRIPTION
        work_ref is provenance/ownership metadata only. It never selects the
        workspace. The trusted registry has already selected the Project.

        Migration is deliberately staged:
          * a legacy project may omit work_ref;
          * a project with repository configured rejects a mismatched work_ref;
          * require_work_ref=true rejects omission after that consumer is migrated.
    #>
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Project
    )

    $raw = Get-Prop $Request 'work_ref' $null
    if ($null -eq $raw) {
        if ([bool](Get-Prop $Project 'require_work_ref' $false)) {
            Throw-InvalidRequest "project '$($Project.key)' requires request.work_ref"
        }
        return $null
    }
    if ($raw -isnot [pscustomobject]) {
        Throw-InvalidRequest 'request.work_ref must be an object'
    }

    $allowed = @('repository', 'issue_number', 'path')
    $unknown = @($raw.PSObject.Properties.Name | Where-Object { $_ -notin $allowed })
    if ($unknown.Count -gt 0) {
        Throw-InvalidRequest ("request.work_ref contains unsupported field(s): {0}" -f ($unknown -join ', '))
    }

    $repository = [string](Get-Prop $raw 'repository' '')
    if ([string]::IsNullOrWhiteSpace($repository)) {
        Throw-InvalidRequest 'request.work_ref.repository is required'
    }
    if (-not (Test-GitHubRepositoryIdentity -Repository $repository)) {
        Throw-InvalidRequest "request.work_ref.repository has an invalid form: $repository"
    }

    $boundRepository = [string](Get-Prop $Project 'repository' '')
    if (-not [string]::IsNullOrWhiteSpace($boundRepository) -and
        -not $repository.Equals($boundRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-InvalidRequest ("request.work_ref.repository '{0}' does not match project '{1}' canonical repository '{2}'" -f $repository, $Project.key, $boundRepository)
    }

    $issueNumber = $null
    $issueRaw = Get-Prop $raw 'issue_number' $null
    if ($null -ne $issueRaw) {
        $parsedIssue = 0
        if (-not [int]::TryParse([string]$issueRaw, [ref]$parsedIssue) -or $parsedIssue -lt 1) {
            Throw-InvalidRequest 'request.work_ref.issue_number must be a positive integer'
        }
        $issueNumber = $parsedIssue
    }

    $path = [string](Get-Prop $raw 'path' '')
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        if ($path.Length -gt 500) {
            Throw-InvalidRequest 'request.work_ref.path exceeds 500 characters'
        }
        # Metadata only, but keep it unambiguously repository-relative so it can
        # never be misread later as machine path authority.
        if ($path.StartsWith('/') -or $path.StartsWith('\') -or
            $path -match '^[A-Za-z]:' -or $path.Contains('\') -or
            $path -match '(^|/)\.\.(/|$)') {
            Throw-InvalidRequest 'request.work_ref.path must be a repository-relative forward-slash path without traversal'
        }
    }

    return [pscustomobject][ordered]@{
        repository   = $repository
        issue_number = $issueNumber
        path         = $path
    }
}

function Get-Profile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        Throw-EnvironmentError "profile name has an invalid form: $Name"
    }
    $path = Join-Path $RepoRoot "runner\profiles\$Name.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-EnvironmentError "profile not found: $Name ($path)"
    }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        Throw-EnvironmentError "profile $Name is not valid JSON"
    }
}

function Resolve-Interpreter {
    <#
    .SYNOPSIS
        Resolves an explicitly-configured interpreter for a project.
    .DESCRIPTION
        This is the fix for an earlier `.venv` incident: the control plane
        never assumes a project's .venv is also its test environment. If the
        registry does not name an interpreter for the requested role, that is an
        `environment_error` with an actionable message -- not a silent fallback
        to whatever `python` happens to be on PATH, and never an implicit
        dependency install.
    .PARAMETER Role
        'runtime' or 'test' (or any role a profile action names).
    #>
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $langConfig = Get-Prop $Project.entry $Language $null
    if ($null -eq $langConfig) {
        Throw-EnvironmentError ("project '{0}' does not configure a '{1}' section; add {1}.{2} to projects.json" -f $Project.key, $Language, $Role)
    }
    $exe = [string](Get-Prop $langConfig $Role '')
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Throw-EnvironmentError ("project '{0}' does not configure {1}.{2}; the control plane will not guess an interpreter" -f $Project.key, $Language, $Role)
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Throw-EnvironmentError ("configured {0}.{1} for project '{2}' does not exist: {3}" -f $Language, $Role, $Project.key, $exe)
    }
    return $exe
}
