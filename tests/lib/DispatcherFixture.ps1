# DispatcherFixture.ps1 -- builds an isolated state root and drives dispatch.ps1.
#
# Every dispatcher test runs against a throwaway %GPTLOOP_STATE_ROOT% and a
# throwaway copy of the example workspace, so tests can freely write files
# without touching the real installation.

Set-StrictMode -Version Latest

function New-DispatcherFixture {
    <#
    .SYNOPSIS
        Creates a temporary state root, project registry, and workspace copy.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$CopyWorkspace,
        [switch]$OmitTestInterpreter,
        [switch]$EnableCodex
    )

    $root = Join-Path ([IO.Path]::GetTempPath()) ('gptloop-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $stateRoot = Join-Path $root 'state'
    New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'results') | Out-Null

    $sourceWorkspace = Join-Path $RepoRoot 'examples\python-project'
    $workspace = $sourceWorkspace
    $secondWorkspace = Join-Path $root 'other-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $secondWorkspace 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $secondWorkspace 'src\secret.txt') -Value 'project B private data' -Encoding utf8

    if ($CopyWorkspace) {
        # Copy everything except the venv, then point the copy at the original venv.
        $workspace = Join-Path $root 'workspace'
        New-Item -ItemType Directory -Force -Path $workspace | Out-Null
        Get-ChildItem -LiteralPath $sourceWorkspace -Force |
            Where-Object { $_.Name -ne '.venv' } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $workspace -Recurse -Force }
    }

    # ⚠️ A venv puts its interpreter in a different place on each platform —
    # `Scripts\python.exe` vs `bin/python`. ⛔ This is exactly the shape of the
    # `.venv` incident the registry exists to prevent, so the fixture states the
    # path rather than searching for something that looks like an interpreter.
    $venvRelative = if ($IsWindows) { '.venv/Scripts/python.exe' } else { '.venv/bin/python' }
    $runtimePython = Join-Path $sourceWorkspace $venvRelative
    $testPython = $runtimePython
    if (-not (Test-Path -LiteralPath $runtimePython)) {
        $hint = if ($IsWindows) { 'scripts/install-windows.ps1' } else { 'scripts/install-macos.ps1' }
        throw "fixture venv missing: $runtimePython (run $hint or create it)"
    }

    $pythonSection = [ordered]@{ runtime = $runtimePython }
    if (-not $OmitTestInterpreter) { $pythonSection['test'] = $testPython }

    if ($EnableCodex) {
        # The configured executable is Python and the first Codex argument is
        # `exec`, so this workspace-local script acts as a deterministic fake
        # CLI on every platform. It records argv/stdin/cwd in JSONL and never
        # touches a real Codex account.
        $mockCodex = @'
import json
import os
import sys

if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.test")
    raise SystemExit(0)

prompt = sys.stdin.read()
print(json.dumps({"type": "thread.started", "thread_id": "mock-thread", "model": "gpt-5.6-sol"}))
print(json.dumps({"type": "turn.started"}))
print(json.dumps({
    "type": "mock.capture",
    "arguments": sys.argv[1:],
    "prompt": prompt,
    "cwd": os.getcwd(),
    "has_openai_api_key": "OPENAI_API_KEY" in os.environ,
    "has_claude_oauth_token": "CLAUDE_CODE_OAUTH_TOKEN" in os.environ,
    "has_github_token": "GITHUB_TOKEN" in os.environ,
    "has_git_ssh_command": "GIT_SSH_COMMAND" in os.environ,
    "has_job_id": "GPTLOOP_JOB_ID" in os.environ,
    "git_config_global": os.environ.get("GIT_CONFIG_GLOBAL", ""),
}))
print(json.dumps({"type": "item.completed", "item": {"id": "item-1", "type": "agent_message", "text": "done"}}))
print(json.dumps({"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}}))
'@
        [IO.File]::WriteAllText((Join-Path $workspace 'exec'), $mockCodex, [System.Text.UTF8Encoding]::new($false))
    }

    $codexSection = [ordered]@{ enabled = [bool]$EnableCodex }
    if ($EnableCodex) {
        $codexSection = [ordered]@{
            enabled           = $true
            executable        = $runtimePython
            timeout_seconds   = 30
            max_prompt_chars  = 12000
            sandbox           = 'workspace-write'
            allowed_sandboxes = @('read-only', 'workspace-write')
            model             = 'gpt-5.6-sol'
            reasoning_effort  = 'high'
            tiers             = [ordered]@{
                doc  = [ordered]@{ sandbox = 'read-only' }
                code = [ordered]@{ model = 'gpt-5.6-sol'; reasoning_effort = 'high'; sandbox = 'workspace-write' }
            }
        }
    }

    $registry = [ordered]@{
        version  = 1
        projects = [ordered]@{
            'example-python' = [ordered]@{
                workspace = $workspace
                profile   = 'example-python'
                python    = $pythonSection
                claude    = [ordered]@{ enabled = $false }
                codex     = $codexSection
            }
            'other-project'  = [ordered]@{
                workspace = $secondWorkspace
                profile   = 'generic'
            }
        }
    }
    $registryJson = $registry | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $stateRoot 'projects.json'), $registryJson, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Root            = $root
        StateRoot       = $stateRoot
        Workspace       = $workspace
        SecondWorkspace = $secondWorkspace
        RepoRoot        = $RepoRoot
        RuntimePython   = $runtimePython
    }
}

function Remove-DispatcherFixture {
    param($Fixture)
    if ($null -eq $Fixture) { return }
    Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
}

function New-JobRequest {
    <#
    .SYNOPSIS
        Builds a protocol-valid request object.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Project = 'example-python',
        $Params = $null,
        [string]$JobId = '',
        $ProtocolVersion = 1
    )
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = [Guid]::NewGuid().ToString() }
    $request = [ordered]@{
        protocol_version = $ProtocolVersion
        job_id           = $JobId
        project          = $Project
        action           = $Action
    }
    if ($null -ne $Params) { $request['params'] = $Params }
    return $request
}

function Invoke-Dispatcher {
    <#
    .SYNOPSIS
        Runs dispatch.ps1 in a child pwsh and returns the parsed bounded result.
    .DESCRIPTION
        A child process is used deliberately: it proves the script works from a
        cold start under StrictMode, exactly as the GitHub Actions step invokes it.
    #>
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        $Request = $null,
        # Deliberately untyped: [string]$RawBody = $null would coerce to '' and
        # silently take the raw-body branch for every request-object call.
        $RawBody = $null,
        [int]$IssueNumber = 0,
        [int]$LockTimeoutSeconds = 3600,
        [int]$CommentCharBudget = 55000,
        [switch]$Async
    )

    $id = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $Fixture.Root "request-$id.json"
    $resultPath = Join-Path $Fixture.Root "result-$id.json"

    if ($null -ne $RawBody) {
        [IO.File]::WriteAllText($requestPath, $RawBody, [System.Text.UTF8Encoding]::new($false))
    } else {
        $json = $Request | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($requestPath, $json, [System.Text.UTF8Encoding]::new($false))
    }

    $dispatch = Join-Path $Fixture.RepoRoot 'runner\dispatch.ps1'
    $argv = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $dispatch,
        '-RequestPath', $requestPath,
        '-ResultPath', $resultPath,
        '-IssueNumber', [string]$IssueNumber,
        '-StateRoot', $Fixture.StateRoot,
        '-RepoRoot', $Fixture.RepoRoot,
        '-LockTimeoutSeconds', [string]$LockTimeoutSeconds,
        '-CommentCharBudget', [string]$CommentCharBudget
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in $argv) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $handle = [pscustomobject]@{
        Process     = $proc
        OutTask     = $outTask
        ErrTask     = $errTask
        ResultPath  = $resultPath
        RequestPath = $requestPath
    }

    if ($Async) { return $handle }
    return (Complete-Dispatcher -Handle $handle)
}

function Complete-Dispatcher {
    param([Parameter(Mandatory = $true)]$Handle, [int]$TimeoutSeconds = 300)

    if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { & taskkill.exe /PID $Handle.Process.Id /T /F | Out-Null } catch { }
        throw "dispatcher did not exit within $TimeoutSeconds seconds"
    }
    $stdout = ''
    $stderr = ''
    try { $Handle.OutTask.Wait(5000) | Out-Null; $stdout = $Handle.OutTask.Result } catch { }
    try { $Handle.ErrTask.Wait(5000) | Out-Null; $stderr = $Handle.ErrTask.Result } catch { }

    $result = $null
    if (Test-Path -LiteralPath $Handle.ResultPath) {
        $text = [IO.File]::ReadAllText($Handle.ResultPath, [System.Text.Encoding]::UTF8)
        try { $result = $text | ConvertFrom-Json } catch { $result = $null }
    }

    return [pscustomobject]@{
        ExitCode = $Handle.Process.ExitCode
        Result   = $result
        Stdout   = $stdout
        Stderr   = $stderr
    }
}
