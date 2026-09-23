# ProfileActions.ps1 -- actions declared by a project profile, including composites.
#
# The core dispatcher knows nothing about pytest, doctors, or evaluation suites.
# A profile declares what its actions run, which explicitly-configured
# interpreter to use, and how to interpret each exit code. That last part is why
# a corpus-incompatible benchmark can report `inapplicable` instead of pretending
# the project regressed.

Set-StrictMode -Version Latest

function Get-ProfileAction {
    param([Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)][string]$Action)
    $actions = Get-Prop $Profile 'actions' $null
    if ($null -eq $actions) { return $null }
    return (Get-Prop $actions $Action $null)
}

function Resolve-ExitStatus {
    <#
    .SYNOPSIS
        Maps a child exit code onto the result taxonomy using profile rules.
    #>
    param([Parameter(Mandatory = $true)]$Definition, [Parameter(Mandatory = $true)][int]$ExitCode)
    $map = Get-Prop $Definition 'exit_status_map' $null
    if ($null -ne $map) {
        $mapped = Get-Prop $map ([string]$ExitCode) $null
        if ($null -ne $mapped) { return [string]$mapped }
    }
    if ($ExitCode -eq 0) { return $script:GptLoopStatus.Success }
    return [string](Get-Prop $Definition 'default_status' $script:GptLoopStatus.Failure)
}

function Get-ProfileEnvironment {
    <#
    .SYNOPSIS
        Builds the child environment for a profile action.
    .DESCRIPTION
        Merges the dispatcher's base environment with profile-level and
        action-level `env` blocks. The token {workspace} expands to the resolved
        workspace root, which is how a profile says PYTHONPATH={workspace}/src
        without committing a machine-specific path.

        ⚠️ Profiles write separators as `/`, ⛔ never `\`. A forward slash is
        accepted as a separator on both platforms; a backslash is a literal
        character on POSIX, so a profile written the Windows way silently
        produces a path that does not exist. ⇒ The expander deliberately does
        **no** separator rewriting: one direction works everywhere, so there is
        nothing to translate.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        $Definition
    )
    $merged = @{}
    foreach ($key in $Context.ChildEnvironment.Keys) { $merged[$key] = $Context.ChildEnvironment[$key] }

    foreach ($source in @((Get-Prop $Context.Project.profile 'env' $null), (Get-Prop $Definition 'env' $null))) {
        if ($null -eq $source) { continue }
        foreach ($prop in $source.PSObject.Properties) {
            $value = [string]$prop.Value
            $value = $value.Replace('{workspace}', $Context.Project.workspace)
            $merged[$prop.Name] = $value
        }
    }
    return $merged
}

function Invoke-ProfileStep {
    <#
    .SYNOPSIS
        Runs a single non-composite profile action definition.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Definition
    )

    $kind = [string](Get-Prop $Definition 'kind' 'process')
    $timeout = [int](Get-Prop $Definition 'timeout_seconds' 1200)
    $extraArgs = @(Get-Prop $Definition 'args' @())
    $childEnv = Get-ProfileEnvironment -Context $Context -Definition $Definition

    switch ($kind) {
        'python_module' {
            $module = [string](Get-Prop $Definition 'module' '')
            if ([string]::IsNullOrWhiteSpace($module)) {
                Throw-EnvironmentError "profile action '$Name' declares kind=python_module without a module"
            }
            $role = [string](Get-Prop $Definition 'interpreter' 'runtime')
            $exe = Resolve-Interpreter -Project $Context.Project -Language 'python' -Role $role
            $argv = @('-m', $module) + $extraArgs
            $step = Invoke-CapturedProcess -FilePath $exe -Arguments $argv `
                -WorkingDirectory $Context.Project.workspace -TimeoutSeconds $timeout -Name $Name `
                -Environment $childEnv
        }
        'process' {
            $file = [string](Get-Prop $Definition 'file' '')
            if ([string]::IsNullOrWhiteSpace($file)) {
                Throw-EnvironmentError "profile action '$Name' declares kind=process without a file"
            }
            $step = Invoke-CapturedProcess -FilePath $file -Arguments $extraArgs `
                -WorkingDirectory $Context.Project.workspace -TimeoutSeconds $timeout -Name $Name `
                -Environment $childEnv
        }
        default {
            Throw-EnvironmentError "profile action '$Name' has an unsupported kind: $kind"
        }
    }

    $status = Resolve-ExitStatus -Definition $Definition -ExitCode ([int]$step.exit_code)
    return [pscustomobject]@{ Status = $status; Steps = @($step) }
}

function Invoke-ProfileAction {
    <#
    .SYNOPSIS
        Runs a profile action, expanding composites.
    .DESCRIPTION
        A composite's overall status is the most severe of its parts, with
        `stop_on_failure` (default true) halting the sequence at the first
        non-success. Composites are how a project defines what "quality" means
        for itself -- the control plane refuses to define it globally.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Action
    )

    $definition = Get-ProfileAction -Profile $Context.Project.profile -Action $Action
    if ($null -eq $definition) { return $null }

    $kind = [string](Get-Prop $definition 'kind' 'process')
    if ($kind -ne 'composite') {
        return (Invoke-ProfileStep -Context $Context -Name $Action -Definition $definition)
    }

    $members = @(Get-Prop $definition 'steps' @())
    if ($members.Count -eq 0) {
        Throw-EnvironmentError "composite action '$Action' declares no steps"
    }
    $stopOnFailure = [bool](Get-Prop $definition 'stop_on_failure' $true)

    $allSteps = @()
    $worst = $script:GptLoopStatus.Success
    foreach ($member in $members) {
        $memberName = [string]$member
        $memberDef = Get-ProfileAction -Profile $Context.Project.profile -Action $memberName
        if ($null -eq $memberDef) {
            Throw-EnvironmentError "composite action '$Action' references unknown step '$memberName'"
        }
        if ([string](Get-Prop $memberDef 'kind' 'process') -eq 'composite') {
            Throw-EnvironmentError "composite action '$Action' may not nest composite step '$memberName'"
        }
        $outcome = Invoke-ProfileStep -Context $Context -Name $memberName -Definition $memberDef
        $allSteps += $outcome.Steps
        $worst = Get-WorstStatus $worst $outcome.Status
        if ($outcome.Status -ne $script:GptLoopStatus.Success -and $stopOnFailure) { break }
    }

    return [pscustomobject]@{ Status = $worst; Steps = $allSteps }
}

function Get-WorstStatus {
    # Ordering used only to summarise composites.
    param([string]$A, [string]$B)
    $rank = @{
        'success'           = 0
        'inapplicable'      = 1
        'environment_error' = 2
        'denied'            = 3
        'invalid_request'   = 3
        'timeout'           = 4
        'failure'           = 5
    }
    $ra = if ($rank.ContainsKey($A)) { $rank[$A] } else { 5 }
    $rb = if ($rank.ContainsKey($B)) { $rank[$B] } else { 5 }
    if ($rb -gt $ra) { return $B }
    return $A
}
