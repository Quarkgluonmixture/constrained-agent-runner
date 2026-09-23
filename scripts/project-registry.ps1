<#
.SYNOPSIS
    Inspect, provision, and migrate GPT Loop machine-local project bindings.
.DESCRIPTION
    Safely manages the Phase-2 machine project registry without allowing broker
    input to choose filesystem placement.

    Existing project migration manages only:

      repository        canonical owner/repo identity for a registered project
      require_work_ref  optional central-broker enforcement gate

    New project provisioning is deliberately minimal. It can register an
    existing Git workspace only after verifying that workspace's origin matches
    the requested canonical repository. The new entry starts with the generic
    profile, empty file/path surfaces, no interpreters, and no Claude/Codex
    executor configuration. Capability grants remain a separate trusted machine
    operation.

    Mutations are backup-first, atomic, verified by full-registry round trip, and
    rolled back automatically on verification failure.

    Enabling require_work_ref is deliberately harder than binding a repository:
    it requires -ConfirmIngressProven so deployment cannot accidentally strand a
    legacy ingress before a real work_ref packet has been verified end-to-end.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'List')]
    [switch]$Json,

    [Parameter(ParameterSetName = 'Bind', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Requirement', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Provision', Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$ProjectKey,

    [Parameter(ParameterSetName = 'Bind', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Provision', Mandatory = $true)]
    [string]$BindRepository,

    [Parameter(ParameterSetName = 'Provision', Mandatory = $true)]
    [string]$ProvisionWorkspace,

    [Parameter(ParameterSetName = 'Requirement', Mandatory = $true)]
    [ValidateSet('enabled', 'disabled')]
    [string]$SetWorkRefRequirement,

    [Parameter(ParameterSetName = 'Requirement')]
    [switch]$ConfirmIngressProven
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'runner/lib/Common.ps1')
. (Join-Path $repoRoot 'runner/lib/SafePath.ps1')
. (Join-Path $repoRoot 'runner/lib/Registry.ps1')

$stateRoot = Get-GptLoopStateRoot
$registryPath = Join-Path $stateRoot 'projects.json'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "project registry not found: $registryPath"
}

function Read-Registry {
    $raw = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
    try {
        $value = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw "project registry is not valid JSON: $registryPath"
    }
    if (-not $value.ContainsKey('projects') -or $value.projects -isnot [System.Collections.IDictionary]) {
        throw 'projects.json has no projects object'
    }
    return $value
}

function Convert-CanonicalJson($Value) {
    return ($Value | ConvertTo-Json -Depth 50 -Compress)
}

function Get-ProjectEntry($Registry, [string]$Key) {
    if (-not $Registry.projects.Contains($Key)) {
        throw "project is not registered on this machine: $Key"
    }
    $entry = $Registry.projects[$Key]
    if ($entry -isnot [System.Collections.IDictionary]) {
        throw "project '$Key' registry entry is not an object"
    }
    return $entry
}

function Write-RegistryAtomic($Registry, [string]$Reason) {
    $expected = Convert-CanonicalJson $Registry
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmssfffZ')
    $backup = "$registryPath.bak-$stamp"
    Copy-Item -LiteralPath $registryPath -Destination $backup -Force

    $unixMode = ''
    if (-not $IsWindows) {
        try { $unixMode = (& stat -f '%Lp' $registryPath).Trim() } catch { }
    }

    $tmp = "$registryPath.tmp-$PID-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        [IO.File]::WriteAllText(
            $tmp,
            ($Registry | ConvertTo-Json -Depth 50),
            [Text.UTF8Encoding]::new($false)
        )
        [IO.File]::Move($tmp, $registryPath, $true)
        if ($unixMode -match '^\d{3,4}$') {
            try { & chmod $unixMode $registryPath } catch { }
        }

        $written = Read-Registry
        $actual = Convert-CanonicalJson $written
        if ($actual -ne $expected) {
            throw 'round-trip registry content did not match the intended mutation'
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath $backup -Destination $registryPath -Force
        if ($unixMode -match '^\d{3,4}$') {
            try { & chmod $unixMode $registryPath } catch { }
        }
        throw "registry verification failed; restored backup $backup : $($_.Exception.Message)"
    }

    Write-Host $Reason
    Write-Host "registry: $registryPath"
    Write-Host "backup  : $backup"
}

function Get-Listing($Registry) {
    $rows = @()
    foreach ($key in @($Registry.projects.Keys | Sort-Object)) {
        $entry = $Registry.projects[$key]
        $workspace = [string](Get-Prop $entry 'workspace' '')
        $repository = [string](Get-Prop $entry 'repository' '')
        $rows += [pscustomobject][ordered]@{
            project          = [string]$key
            repository       = $repository
            require_work_ref = [bool](Get-Prop $entry 'require_work_ref' $false)
            profile          = [string](Get-Prop $entry 'profile' 'generic')
            workspace        = $workspace
            workspace_exists = (-not [string]::IsNullOrWhiteSpace($workspace) -and (Test-Path -LiteralPath $workspace -PathType Container))
        }
    }
    return @($rows)
}

function Get-WorkspaceRepositoryIdentity([string]$Workspace) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw 'git is required to provision a project workspace'
    }

    $output = @(& $git.Source -C $Workspace remote get-url origin 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
        throw "workspace is not a Git repository with an origin remote: $Workspace"
    }
    $origin = $output[0].Trim()

    $match = [regex]::Match(
        $origin,
        '(?i)github\.com[:/](?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?/?$'
    )
    if (-not $match.Success) {
        throw "workspace origin is not a supported GitHub repository URL: $origin"
    }

    $identity = "$($match.Groups['owner'].Value)/$($match.Groups['repo'].Value)"
    if (-not (Test-GitHubRepositoryIdentity -Repository $identity)) {
        throw "workspace origin resolved to an invalid repository identity: $identity"
    }
    return $identity
}

$registry = Read-Registry

if ($PSCmdlet.ParameterSetName -eq 'List') {
    $rows = Get-Listing $registry
    if ($Json) {
        $rows | ConvertTo-Json -Depth 6
    } else {
        $rows | Format-Table -AutoSize
    }
    exit 0
}

if ($PSCmdlet.ParameterSetName -eq 'Provision') {
    if (-not (Test-GitHubRepositoryIdentity -Repository $BindRepository)) {
        throw "repository has an invalid owner/repo form: $BindRepository"
    }
    if ($registry.projects.Contains($ProjectKey)) {
        throw "project is already registered on this machine: $ProjectKey"
    }
    if (-not (Test-Path -LiteralPath $ProvisionWorkspace -PathType Container)) {
        throw "workspace does not exist: $ProvisionWorkspace"
    }

    $workspace = Resolve-RealPath $ProvisionWorkspace
    [void](Get-Profile -Name 'generic' -RepoRoot $repoRoot)
    $originRepository = Get-WorkspaceRepositoryIdentity -Workspace $workspace
    if (-not $originRepository.Equals($BindRepository, [StringComparison]::OrdinalIgnoreCase)) {
        throw "workspace origin '$originRepository' does not match requested repository '$BindRepository'"
    }

    $entry = [ordered]@{
        workspace        = $workspace
        repository       = $BindRepository
        require_work_ref = $false
        profile           = 'generic'
        # A newly provisioned project receives identity and placement only.
        # Empty surfaces prevent file mutation/read_file until a later trusted
        # capability configuration deliberately grants them.
        allowed_roots     = @()
        allowed_files     = @()
    }

    if ($PSCmdlet.ShouldProcess($registryPath, "provision project '$ProjectKey' for '$BindRepository' at '$workspace'")) {
        $registry.projects[$ProjectKey] = $entry
        Write-RegistryAtomic $registry "provisioned project '$ProjectKey' -> '$BindRepository'"
        Write-Host "workspace        : $workspace"
        Write-Host 'profile          : generic (minimal baseline)'
        Write-Host 'file surfaces    : none'
        Write-Host 'executors        : none configured'
        Write-Host 'require_work_ref : False'
    }
    exit 0
}

# Existing-project operations resolve through the normal trusted path before
# mutating provenance. This proves the key names a currently usable registered
# workspace/profile rather than a stale JSON entry.
$resolved = Resolve-Project -ProjectKey $ProjectKey -StateRoot $stateRoot -RepoRoot $repoRoot
$entry = Get-ProjectEntry $registry $ProjectKey

if ($PSCmdlet.ParameterSetName -eq 'Bind') {
    if (-not (Test-GitHubRepositoryIdentity -Repository $BindRepository)) {
        throw "repository has an invalid owner/repo form: $BindRepository"
    }

    $existing = [string](Get-Prop $entry 'repository' '')
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        if (-not $existing.Equals($BindRepository, [StringComparison]::OrdinalIgnoreCase)) {
            throw "project '$ProjectKey' is already bound to '$existing'; refusing to rebind it to '$BindRepository'"
        }
        Write-Host "project '$ProjectKey' is already bound to '$existing'; no change"
        Write-Host "workspace: $($resolved.workspace)"
        exit 0
    }

    if ($PSCmdlet.ShouldProcess($registryPath, "bind project '$ProjectKey' to repository '$BindRepository'")) {
        $entry['repository'] = $BindRepository
        Write-RegistryAtomic $registry "bound project '$ProjectKey' -> '$BindRepository'"
        Write-Host "workspace : $($resolved.workspace)"
        Write-Host "require_work_ref remains: $([bool](Get-Prop $entry 'require_work_ref' $false))"
    }
    exit 0
}

$boundRepository = [string](Get-Prop $entry 'repository' '')
if ([string]::IsNullOrWhiteSpace($boundRepository)) {
    throw "project '$ProjectKey' has no repository binding; bind repository provenance before changing require_work_ref"
}
if (-not (Test-GitHubRepositoryIdentity -Repository $boundRepository)) {
    throw "project '$ProjectKey' has an invalid existing repository binding: $boundRepository"
}

$desired = ($SetWorkRefRequirement -eq 'enabled')
$current = [bool](Get-Prop $entry 'require_work_ref' $false)
if ($desired -and -not $ConfirmIngressProven) {
    throw 'enabling require_work_ref requires -ConfirmIngressProven after a real broker envelope with work_ref has been verified end-to-end'
}
if ($current -eq $desired) {
    Write-Host "project '$ProjectKey' require_work_ref is already $current; no change"
    exit 0
}

$verb = if ($desired) { 'enable' } else { 'disable' }
if ($PSCmdlet.ShouldProcess($registryPath, "$verb require_work_ref for project '$ProjectKey'")) {
    $entry['require_work_ref'] = $desired
    $pastTense = if ($desired) { 'enabled' } else { 'disabled' }
    Write-RegistryAtomic $registry "$pastTense require_work_ref for project '$ProjectKey'"
    Write-Host "repository: $boundRepository"
}
