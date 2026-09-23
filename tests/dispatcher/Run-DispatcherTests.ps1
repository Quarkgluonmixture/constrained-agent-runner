<#
.SYNOPSIS
    Dispatcher, permission, and protocol regression suite (T001, T005-T015, T017).

.DESCRIPTION
    Every case here corresponds to a failure mode that was actually observed
    while bootstrapping this system on an earlier prototype. See docs/TROUBLESHOOTING.md.
#>

[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

. (Join-Path $RepoRoot 'tests\lib\TestHarness.ps1')
. (Join-Path $RepoRoot 'tests\lib\DispatcherFixture.ps1')
. (Join-Path $RepoRoot 'runner\lib\Common.ps1')

$fixture = New-DispatcherFixture -RepoRoot $RepoRoot -CopyWorkspace

try {
    # --- T007 unknown action --------------------------------------------------
    Invoke-TestCase 'T007' 'unknown action yields deterministic invalid_request' {
        $req = New-JobRequest -Action 'definitely_not_a_real_action'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Equal $false $run.Result.ok
        Assert-Equal 1 $run.ExitCode
    }

    # --- T008 malformed JSON --------------------------------------------------
    Invoke-TestCase 'T008' 'malformed JSON yields deterministic invalid_request' {
        $run = Invoke-Dispatcher -Fixture $fixture -RawBody '{ this is not json'
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'not valid JSON'
    }

    Invoke-TestCase 'T008b' 'unknown protocol_version is rejected, not guessed' {
        $req = New-JobRequest -Action 'ping' -ProtocolVersion 99
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'unsupported protocol_version'
    }

    Invoke-TestCase 'T008c' 'non-UUID job_id is rejected' {
        $req = New-JobRequest -Action 'ping' -JobId 'not-a-uuid'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
    }

    # --- T009 missing optional params (the StrictMode bug) --------------------
    Invoke-TestCase 'T009' 'action with no params object does not crash under StrictMode' {
        $req = New-JobRequest -Action 'ping'
        Assert-True (-not $req.Contains('params')) 'request should genuinely omit params'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-NotMatch ($run.Stderr + $run.Stdout) 'PropertyNotFound|StrictMode|because it does not exist'
    }

    Invoke-TestCase 'T009b' 'optional params present-but-partial does not crash' {
        # read_file supplies path but omits the optional max_bytes.
        $req = New-JobRequest -Action 'read_file' -Params @{ path = 'README.md' }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-Match $run.Result.steps[0].stdout 'example Python project'
    }

    Invoke-TestCase 'T009c' 'out-of-range optional param is an invalid_request, not a crash' {
        $req = New-JobRequest -Action 'read_file' -Params @{ path = 'README.md'; max_bytes = 0 }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
    }

    # --- T005 traversal -------------------------------------------------------
    $traversals = @(
        '../foo',
        '..\foo',
        'src/../../foo',
        'src\..\..\foo',
        'C:\Windows\System32\drivers\etc\hosts',
        '/absolute/foo',
        '\\server\share\foo',
        'src/./../../etc/passwd'
    )
    foreach ($bad in $traversals) {
        $label = $bad
        Invoke-TestCase 'T005' "traversal rejected: $label" {
            $req = New-JobRequest -Action 'read_file' -Params @{ path = $label }
            $run = Invoke-Dispatcher -Fixture $fixture -Request $req
            Assert-Equal 'denied' $run.Result.status "path '$label' must be denied"
        }
    }

    # --- T006 denied surface --------------------------------------------------
    $deniedPaths = @('.git/config', '.github/workflows/loop-runner.yml', '.env', 'secrets/key.pem', 'src/../.git/config')
    foreach ($bad in $deniedPaths) {
        $label = $bad
        Invoke-TestCase 'T006' "denied surface rejected: $label" {
            $req = New-JobRequest -Action 'read_file' -Params @{ path = $label }
            $run = Invoke-Dispatcher -Fixture $fixture -Request $req
            Assert-Equal 'denied' $run.Result.status "path '$label' must be denied"
        }
    }

    Invoke-TestCase 'T006b' 'a write action cannot reach the control-plane workflow' {
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = '.github/workflows/loop-runner.yml'; old = 'self-hosted'; new = 'pwned'
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'denied' $run.Result.status
    }

    Invoke-TestCase 'T006c' 'a path outside the profile allowlist is denied' {
        $req = New-JobRequest -Action 'read_file' -Params @{ path = 'notes/private.txt' }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'denied' $run.Result.status
    }

    # --- T017 project isolation ----------------------------------------------
    Invoke-TestCase 'T017' 'project A cannot read project B workspace' {
        # 'other-project' holds src/secret.txt. Reading it via example-python
        # must fail: the workspace comes from the registry, not the request.
        $req = New-JobRequest -Action 'read_file' -Project 'example-python' -Params @{ path = 'src/secret.txt' }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-True ($run.Result.status -ne 'success') 'must not read the other project file'
        Assert-NotMatch ([string]($run.Result | ConvertTo-Json -Depth 8)) 'project B private data'
    }

    Invoke-TestCase 'T017b' 'unregistered project key is denied' {
        $req = New-JobRequest -Action 'ping' -Project 'not-registered'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'denied' $run.Result.status
    }

    Invoke-TestCase 'T017c' 'the request cannot supply a workspace of its own' {
        $body = @{
            protocol_version = 1
            job_id           = [Guid]::NewGuid().ToString()
            project          = 'example-python'
            workspace        = 'C:\Windows'
            action           = 'ping'
        } | ConvertTo-Json
        $run = Invoke-Dispatcher -Fixture $fixture -RawBody $body
        Assert-Equal 'success' $run.Result.status
        Assert-Equal $fixture.Workspace $run.Result.workspace 'workspace must come from the registry'
    }

    # --- T010 / T011 replace_text --------------------------------------------
    Invoke-TestCase 'T010' 'CRLF file keeps CRLF after an LF-authored replacement' {
        $target = Join-Path $fixture.Workspace 'src\crlf_fixture.txt'
        $original = "alpha`r`nbeta`r`ngamma`r`n"
        [IO.File]::WriteAllText($target, $original, [System.Text.UTF8Encoding]::new($false))

        # The JSON payload necessarily carries LF newlines.
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = 'src/crlf_fixture.txt'; old = "beta`ngamma"; new = "beta`ndelta`ngamma"
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status

        $after = [IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
        Assert-Match $after 'delta'
        # The inserted line legitimately adds one newline; the invariant that
        # matters is that EVERY newline is still CRLF, i.e. no bare LF crept in.
        $crlf = [regex]::Matches($after, "`r`n").Count
        $lf = [regex]::Matches($after, "`n").Count
        Assert-Equal 4 $crlf 'the inserted line should bring the file to 4 CRLF terminators'
        Assert-Equal $crlf $lf 'no bare LF may be introduced into a CRLF file'
    }

    Invoke-TestCase 'T010b' 'LF file keeps LF' {
        $target = Join-Path $fixture.Workspace 'src\lf_fixture.txt'
        [IO.File]::WriteAllText($target, "alpha`nbeta`ngamma`n", [System.Text.UTF8Encoding]::new($false))
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = 'src/lf_fixture.txt'; old = "beta"; new = "beta2"
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        $after = [IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
        Assert-Equal 0 ([regex]::Matches($after, "`r").Count) 'no CR may be introduced'
    }

    Invoke-TestCase 'T011' 'zero occurrences fails closed and writes nothing' {
        $target = Join-Path $fixture.Workspace 'src\count_zero.txt'
        $original = "hello world`n"
        [IO.File]::WriteAllText($target, $original, [System.Text.UTF8Encoding]::new($false))
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = 'src/count_zero.txt'; old = 'not present'; new = 'x'
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'failure' $run.Result.status
        Assert-Match $run.Result.steps[0].stderr 'found 0'
        Assert-Equal $original ([IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)) 'file must be untouched'
    }

    Invoke-TestCase 'T011b' 'two occurrences fails closed when one is expected' {
        $target = Join-Path $fixture.Workspace 'src\count_two.txt'
        $original = "dup`ndup`n"
        [IO.File]::WriteAllText($target, $original, [System.Text.UTF8Encoding]::new($false))
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = 'src/count_two.txt'; old = 'dup'; new = 'x'
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'failure' $run.Result.status
        Assert-Match $run.Result.steps[0].stderr 'found 2'
        Assert-Equal $original ([IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)) 'file must be untouched'
    }

    Invoke-TestCase 'T011c' 'expected_count=2 replaces both occurrences' {
        $target = Join-Path $fixture.Workspace 'src\count_two_ok.txt'
        [IO.File]::WriteAllText($target, "dup`ndup`n", [System.Text.UTF8Encoding]::new($false))
        $req = New-JobRequest -Action 'replace_text' -Params @{
            path = 'src/count_two_ok.txt'; old = 'dup'; new = 'x'; expected_count = 2
        }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        $after = [IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
        Assert-Equal 0 ([regex]::Matches($after, 'dup').Count)
    }

    # --- T012 patch validation ------------------------------------------------
    Invoke-TestCase 'T012' 'pseudo-diff dialect is rejected with a specific message' {
        $pseudo = "*** Begin Patch`n*** Update File: src/version.py`n-old`n+new`n*** End Patch"
        $req = New-JobRequest -Action 'apply_patch' -Params @{ patch = $pseudo }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'invalid_request' $run.Result.status
        Assert-Match $run.Result.error 'pseudo-diff'
    }

    Invoke-TestCase 'T012b' 'unified diff aimed at a denied path is rejected' {
        $patch = @(
            '--- a/.github/workflows/loop-runner.yml'
            '+++ b/.github/workflows/loop-runner.yml'
            '@@ -1 +1 @@'
            '-name: x'
            '+name: y'
        ) -join "`n"
        $req = New-JobRequest -Action 'apply_patch' -Params @{ patch = $patch }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'denied' $run.Result.status
    }

    Invoke-TestCase 'T012c' 'valid unified diff on an allowed path applies' {
        $target = Join-Path $fixture.Workspace 'src\patch_target.txt'
        [IO.File]::WriteAllText($target, "one`ntwo`nthree`n", [System.Text.UTF8Encoding]::new($false))
        # git apply needs a repository; the fixture workspace copy has none.
        & (Get-PlatformExecutable 'git') -C $fixture.Workspace init -q 2>&1 | Out-Null
        $patch = @(
            '--- a/src/patch_target.txt'
            '+++ b/src/patch_target.txt'
            '@@ -1,3 +1,3 @@'
            ' one'
            '-two'
            '+TWO'
            ' three'
            ''
        ) -join "`n"
        $req = New-JobRequest -Action 'apply_patch' -Params @{ patch = $patch }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-Match ([IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)) 'TWO'
    }

    # --- profile action semantics ---------------------------------------------
    Invoke-TestCase 'T018' 'profile test action runs with the configured interpreter' {
        $req = New-JobRequest -Action 'test'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-Match $run.Result.steps[0].stdout '2 passed'
    }

    Invoke-TestCase 'T018b' 'deliberate failure reports status failure' {
        $req = New-JobRequest -Action 'always_fails'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'failure' $run.Result.status
        Assert-Equal $false $run.Result.ok
    }

    Invoke-TestCase 'T018c' 'nonzero exit mapped to inapplicable is NOT a failure' {
        $req = New-JobRequest -Action 'not_applicable'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'inapplicable' $run.Result.status
    }

    # --- T013 timeout ---------------------------------------------------------
    Invoke-TestCase 'T013' 'hanging action times out and the process tree is killed' {
        $req = New-JobRequest -Action 'hang'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'timeout' $run.Result.status
        Assert-Match $run.Result.steps[0].stdout 'spawned child pid=(\d+)'
        $childId = [int]([regex]::Match([string]$run.Result.steps[0].stdout, 'pid=(\d+)').Groups[1].Value)
        # POSIX can expose a killed child briefly while it is being reaped.
        # Poll the exact PID for a bounded interval; never infer from the count
        # of every unrelated Python process on the machine.
        $leaked = $null
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $leaked = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($null -eq $leaked) { break }
            Start-Sleep -Milliseconds 500
        }
        Assert-True ($null -eq $leaked) "timed-out descendant PID $childId is still alive"
    }

    Invoke-TestCase 'T013b' 'a child that never reads stdin still reaches the timeout' {
        . (Join-Path $RepoRoot 'runner\lib\Process.ps1')
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $threw = $false
        try {
            Invoke-CapturedProcess -FilePath $fixture.RuntimePython `
                -Arguments @('-c', 'import time; time.sleep(30)') `
                -WorkingDirectory $fixture.Workspace -TimeoutSeconds 1 `
                -Name 'blocked_stdin' -StandardInputText ('x' * 200000) | Out-Null
        } catch {
            $threw = $true
            $status = Get-ErrorStatus $_
        }
        $watch.Stop()
        Assert-Equal $true $threw 'the blocked child must time out'
        Assert-Equal 'timeout' $status
        Assert-True ($watch.Elapsed.TotalSeconds -lt 5) "stdin blocked past the timeout: $($watch.Elapsed.TotalSeconds)s"
    }

    # --- T014 large stdout ----------------------------------------------------
    Invoke-TestCase 'T014' 'large output is bounded in the comment but kept locally' {
        $req = New-JobRequest -Action 'large_output'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'success' $run.Result.status
        Assert-Equal $true $run.Result.truncated
        $commentJson = $run.Result | ConvertTo-Json -Depth 12
        Assert-True ($commentJson.Length -lt 60000) "comment payload too large: $($commentJson.Length)"

        $stored = Join-Path $fixture.StateRoot "results\$($run.Result.job_id).json"
        Assert-True (Test-Path -LiteralPath $stored) 'full result must be stored locally'
        $full = [IO.File]::ReadAllText($stored, [System.Text.Encoding]::UTF8)
        Assert-True ($full.Length -gt 200000) "full local result should be large, was $($full.Length)"
        Assert-Match $full 'line 019999'
    }

    Invoke-TestCase 'T014b' 'read_result retrieves a bounded slice of the stored result' {
        $req = New-JobRequest -Action 'large_output'
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        $jobId = $run.Result.job_id

        $req2 = New-JobRequest -Action 'read_result' -Params @{ job_id = $jobId; offset = 0; length = 500 }
        $run2 = Invoke-Dispatcher -Fixture $fixture -Request $req2
        Assert-Equal 'success' $run2.Result.status
        Assert-True ($run2.Result.steps[0].stdout.Length -le 500) 'slice must respect length'
        Assert-Equal $true $run2.Result.steps[0].truncated
    }

    # --- T001 immutable creation request --------------------------------------
    Invoke-TestCase 'T001' 'result is bound to the sha256 of the executed body' {
        $bodyA = (New-JobRequest -Action 'ping' | ConvertTo-Json -Depth 8)
        $run = Invoke-Dispatcher -Fixture $fixture -RawBody $bodyA
        $expected = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($bodyA))).Replace('-', '').ToLowerInvariant()
        Assert-Equal $expected $run.Result.request_sha256 'request_sha256 must attest which body ran'

        # A different body must produce a different attestation, so a later issue
        # edit can never be mistaken for the payload that actually executed.
        $bodyB = (New-JobRequest -Action 'git_status' | ConvertTo-Json -Depth 8)
        $runB = Invoke-Dispatcher -Fixture $fixture -RawBody $bodyB
        Assert-True ($runB.Result.request_sha256 -ne $run.Result.request_sha256) 'distinct bodies must hash differently'
    }

    # --- T015 no silent job loss (local serialization) ------------------------
    Invoke-TestCase 'T015' 'concurrent jobs serialize; neither is discarded' {
        $reqA = New-JobRequest -Action 'test'
        $reqB = New-JobRequest -Action 'version'
        $a = Invoke-Dispatcher -Fixture $fixture -Request $reqA -Async
        Start-Sleep -Milliseconds 250
        $b = Invoke-Dispatcher -Fixture $fixture -Request $reqB -Async

        $ra = Complete-Dispatcher -Handle $a
        $rb = Complete-Dispatcher -Handle $b

        Assert-Equal 'success' $ra.Result.status 'first job must complete'
        Assert-Equal 'success' $rb.Result.status 'second job must complete, not be discarded'
        Assert-True ($ra.Result.job_id -ne $rb.Result.job_id) 'both jobs must be distinct'

        # Both full results must survive locally: nothing silently vanishes.
        foreach ($r in @($ra, $rb)) {
            $stored = Join-Path $fixture.StateRoot "results\$($r.Result.job_id).json"
            Assert-True (Test-Path -LiteralPath $stored) "missing stored result for $($r.Result.job_id)"
        }
    }

    Invoke-TestCase 'T015b' 'a job that cannot get the lock reports environment_error, not success' {
        # Hold the mutex from this process, then run a job with a 1s lock timeout.
        $mutex = [System.Threading.Mutex]::new($false, 'Global\gpt-loop-dispatcher')
        $held = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
        try {
            $req = New-JobRequest -Action 'ping'
            $run = Invoke-Dispatcher -Fixture $fixture -Request $req -LockTimeoutSeconds 1
            Assert-Equal 'environment_error' $run.Result.status
            Assert-Match $run.Result.error 'runner lock'
        } finally {
            if ($held) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }

    # --- interpreter is configured, never guessed -----------------------------
    Invoke-TestCase 'T019' 'missing test interpreter is environment_error with actionable text' {
        $bare = New-DispatcherFixture -RepoRoot $RepoRoot -OmitTestInterpreter
        try {
            $req = New-JobRequest -Action 'test'
            $run = Invoke-Dispatcher -Fixture $bare -Request $req
            Assert-Equal 'environment_error' $run.Result.status
            Assert-Match $run.Result.error 'python.test'
            Assert-NotMatch $run.Result.error 'No module named pytest'
        } finally {
            Remove-DispatcherFixture $bare
        }
    }

    # --- T020 the account's usage window is not a verdict ---------------------
    # ⭐ Observed 2026-08-21 17:11: an executor cut off one minute in reported
    # `failure`, the brain read that as "the packet is wrong", and spent a
    # recovery round on a packet that had never been judged.
    Invoke-TestCase 'T020' 'a usage-window cutoff classifies as quota_wait, not failure' {
        . (Join-Path $RepoRoot 'runner\lib\Registry.ps1')
        . (Join-Path $RepoRoot 'runner\actions\ClaudeAction.ps1')

        $real = "You've hit your session limit `u{00B7} resets 5:40pm (Europe/London)"
        $hit = Get-ClaudeQuotaWait -IsError $true -ResultText $real
        Assert-Equal $false ($null -eq $hit)
        Assert-Match $hit.Hint 'resets 5:40pm'
        # The reset instant is the NEXT occurrence, so it is always ahead of now.
        Assert-Equal $true ($hit.RetryAfter -gt [DateTimeOffset]::UtcNow)

        # ⛔ Neither half of the signal is sufficient on its own: an executor's
        # own report may discuss limits, and a successful turn is never a wait.
        Assert-Equal $true ($null -eq (Get-ClaudeQuotaWait -IsError $false -ResultText $real))
        Assert-Equal $true ($null -eq (Get-ClaudeQuotaWait -IsError $true -ResultText 'the 64-char limit assertion is red'))

        # No parseable time still yields a bounded wait rather than nothing.
        $vague = Get-ClaudeQuotaWait -IsError $true -ResultText 'rate limit reached; try later'
        Assert-Equal $false ($null -eq $vague)
        Assert-Equal $true ($vague.RetryAfter -gt [DateTimeOffset]::UtcNow)
    }

    # --- T021 a packet's tier may only pick what the machine already allows -----
    # ⭐ The tier decides how much of the account's 5-hour window a round spends.
    Invoke-TestCase 'T021' 'tier resolves from local config and fails closed on an unknown one' {
        . (Join-Path $RepoRoot 'runner\lib\Registry.ps1')
        . (Join-Path $RepoRoot 'runner\actions\ClaudeAction.ps1')

        $config = [pscustomobject]@{
            model  = 'opus'
            effort = 'high'
            tiers  = [pscustomobject]@{
                doc = [pscustomobject]@{ model = 'sonnet'; effort = 'high' }
                bare = [pscustomobject]@{ }
            }
        }
        $args = @{ ClaudeConfig = $config; ProjectKey = 'p'; DefaultModel = 'opus'; DefaultEffort = 'high' }

        # ⛔ No tier named ⇒ the configured default, NOT the cheapest tier.
        $d = Resolve-ClaudeTier -TierName '' @args
        Assert-Equal 'opus' $d.Model
        Assert-Equal 'high' $d.Effort

        $doc = Resolve-ClaudeTier -TierName 'doc' @args
        Assert-Equal 'sonnet' $doc.Model

        # A tier that omits a field inherits it rather than emptying it.
        $bare = Resolve-ClaudeTier -TierName 'bare' @args
        Assert-Equal 'opus' $bare.Model
        Assert-Equal 'high' $bare.Effort

        # ⚠️ Fail closed: silently running the default would make the round look
        # like it ran at the tier the packet asked for.
        $threw = $false
        try { Resolve-ClaudeTier -TierName 'cheap' @args } catch { $threw = $true; $err = $_ }
        Assert-Equal $true $threw
        Assert-Match ([string]$err.Exception.Message) 'unknown claude tier'
    }

    # --- T023 Codex is a first-class constrained executor --------------------
    Invoke-TestCase 'T023' 'codex_task is allowlisted but denied unless the project opts in' {
        $req = New-JobRequest -Action 'codex_task' -Params @{ prompt = 'do nothing' }
        $run = Invoke-Dispatcher -Fixture $fixture -Request $req
        Assert-Equal 'denied' $run.Result.status
        Assert-Match $run.Result.error 'codex.enabled=true'
    }

    Invoke-TestCase 'T023b' 'Codex tier resolution is local, inherited, sandbox-bounded, and fail-closed' {
        . (Join-Path $RepoRoot 'runner\actions\CodexAction.ps1')

        $config = [pscustomobject]@{
            model             = 'gpt-5.6-sol'
            reasoning_effort  = 'high'
            sandbox           = 'workspace-write'
            allowed_sandboxes = @('read-only', 'workspace-write')
            tiers             = [pscustomobject]@{
                doc  = [pscustomobject]@{ sandbox = 'read-only' }
                code = [pscustomobject]@{ model = 'gpt-5.6-sol'; reasoning_effort = 'high' }
            }
        }
        $args = @{
            CodexConfig = $config; ProjectKey = 'p'; DefaultModel = 'gpt-5.6-sol'
            DefaultReasoningEffort = 'high'; DefaultSandbox = 'workspace-write'
        }

        $default = Resolve-CodexTier -TierName '' @args
        Assert-Equal 'gpt-5.6-sol' $default.Model
        Assert-Equal 'high' $default.ReasoningEffort
        Assert-Equal 'workspace-write' $default.Sandbox

        $doc = Resolve-CodexTier -TierName 'doc' @args
        Assert-Equal 'gpt-5.6-sol' $doc.Model 'omitted tier fields inherit local defaults'
        Assert-Equal 'high' $doc.ReasoningEffort
        Assert-Equal 'read-only' $doc.Sandbox
        Assert-CodexResolvedConfig -CodexConfig $config -Resolved $doc -ProjectKey 'p'
        $docArgv = New-CodexExecArguments -Workspace '/trusted/project' -Model $doc.Model `
            -ReasoningEffort $doc.ReasoningEffort -Sandbox $doc.Sandbox -TrustedTempDirectory '/trusted/tmp'
        $docPermission = @($docArgv | Where-Object { $_ -like 'permissions.gptloop=*' })
        Assert-Match $docPermission[0] '":workspace_roots" = \{ "\." = "read" \}'
        Assert-Match $docPermission[0] '"/trusted/tmp" = "write"'

        $threw = $false
        try { Resolve-CodexTier -TierName 'unknown' @args } catch { $threw = $true; $err = $_ }
        Assert-Equal $true $threw
        Assert-Match ([string]$err.Exception.Message) 'unknown codex tier'

        $danger = [pscustomobject]@{ Model = 'gpt-5.6-sol'; ReasoningEffort = 'high'; Sandbox = 'danger-full-access' }
        $threw = $false
        try { Assert-CodexResolvedConfig -CodexConfig $config -Resolved $danger -ProjectKey 'p' } catch { $threw = $true; $err = $_ }
        Assert-Equal $true $threw
        Assert-Match ([string]$err.Exception.Message) 'permits only'
    }

    Invoke-TestCase 'T023c' 'codex_task uses stdin, fixed workspace, strict JSONL, and registry-owned identity' {
        $codexFixture = New-DispatcherFixture -RepoRoot $RepoRoot -CopyWorkspace -EnableCodex
        try {
            $prompt = "inspect safely`nsecond line"
            $req = New-JobRequest -Action 'codex_task' -Params @{ prompt = $prompt; tier = 'code' }
            $previousKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY')
            $previousClaudeToken = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN')
            $previousGitHubToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN')
            $previousGitSsh = [Environment]::GetEnvironmentVariable('GIT_SSH_COMMAND')
            try {
                [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', 'gpt-loop-test-sentinel')
                [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'gpt-loop-test-sentinel')
                [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'gpt-loop-test-sentinel')
                [Environment]::SetEnvironmentVariable('GIT_SSH_COMMAND', 'gpt-loop-test-sentinel')
                $run = Invoke-Dispatcher -Fixture $codexFixture -Request $req
            } finally {
                [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $previousKey)
                [Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', $previousClaudeToken)
                [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $previousGitHubToken)
                [Environment]::SetEnvironmentVariable('GIT_SSH_COMMAND', $previousGitSsh)
            }
            Assert-Equal 'success' $run.Result.status
            Assert-Equal 'codex_version' $run.Result.steps[0].name
            Assert-Equal 'codex_task' $run.Result.steps[1].name
            Assert-Equal 'codex_task_summary' $run.Result.steps[2].name

            $capture = $null
            foreach ($line in ([string]$run.Result.steps[1].stdout -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $event = $line | ConvertFrom-Json
                if ($event.type -eq 'mock.capture') { $capture = $event; break }
            }
            Assert-True ($null -ne $capture) 'the fake CLI must have captured the invocation'
            Assert-Equal $prompt $capture.prompt 'prompt must arrive over stdin'
            Assert-Equal $false $capture.has_openai_api_key 'Codex must use machine login rather than an inherited API key'
            Assert-Equal $false $capture.has_claude_oauth_token 'Codex must not inherit the runner Claude credential'
            Assert-Equal $false $capture.has_github_token 'Codex must not inherit the runner GitHub credential'
            Assert-Equal $false $capture.has_git_ssh_command 'Codex must not inherit the runner Git SSH credential bridge'
            Assert-Equal $true $capture.has_job_id 'non-secret dispatcher context must remain available'
            Assert-Equal $(if ($IsWindows) { 'NUL' } else { '/dev/null' }) $capture.git_config_global 'user Git config must be disabled'
            # macOS presents the same temporary directory as `/var/...` to
            # PowerShell and `/private/var/...` to the child after chdir.
            $cwdMatches = ([string]$capture.cwd -eq [string]$run.Result.workspace)
            if ($IsMacOS -and -not $cwdMatches) {
                $cwdMatches = ([string]$capture.cwd -eq ('/private' + [string]$run.Result.workspace))
            }
            Assert-True $cwdMatches 'working directory must be the registry workspace'

            $argv = @($capture.arguments)
            Assert-True ($argv -contains '--strict-config')
            Assert-True ($argv -contains '--ephemeral')
            Assert-True ($argv -contains '--ignore-user-config')
            Assert-True ($argv -contains '--json')
            Assert-Equal '-' $argv[-1] 'stdin marker must be the final argument'

            $cdIndex = [Array]::IndexOf($argv, '-C')
            $modelIndex = [Array]::IndexOf($argv, '--model')
            Assert-Equal $run.Result.workspace $argv[$cdIndex + 1]
            Assert-Equal 'gpt-5.6-sol' $argv[$modelIndex + 1]
            Assert-Equal -1 ([Array]::IndexOf($argv, '--sandbox')) 'legacy sandbox mode must not override the bounded permission profile'
            Assert-True ($argv -contains 'default_permissions="gptloop"')
            $permissionArg = @($argv | Where-Object { $_ -like 'permissions.gptloop=*' })
            Assert-Equal 1 $permissionArg.Count 'exactly one locally generated permission profile must run'
            Assert-Match $permissionArg[0] '":minimal" = "read"'
            Assert-Match $permissionArg[0] '":workspace_roots" = \{ "\." = "write" \}'
            Assert-Match $permissionArg[0] 'network = \{ enabled = false \}'
            Assert-True ($argv -contains 'model_reasoning_effort="high"')
            Assert-True ($argv -contains 'approval_policy="never"')
            Assert-True ($argv -contains 'shell_environment_policy.inherit="all"')
            Assert-Match $run.Result.steps[2].stdout 'model_configured=gpt-5.6-sol'
            Assert-Match $run.Result.steps[2].stdout 'model_argument_ran=gpt-5.6-sol'
            Assert-Match $run.Result.steps[2].stdout 'model_reported_by_cli=gpt-5.6-sol'
            Assert-Match $run.Result.steps[2].stdout 'permission_profile_argument_ran=gptloop'
            Assert-Match $run.Result.steps[2].stdout 'workspace_access_argument_ran=write'
            Assert-Match $run.Result.steps[2].stdout 'command_network_argument_ran=false'
            Assert-Match $run.Result.steps[2].stdout 'credential_environment_policy=sensitive_names_removed'
            Assert-Match $run.Result.steps[2].stdout 'git_global_config_environment=disabled'
            Assert-Match $run.Result.steps[2].stdout 'trusted_temp_write_argument_ran='

            # Runtime controls are not silently accepted from the packet.
            $bad = New-JobRequest -Action 'codex_task' -Params @{ prompt = 'x'; tier = 'code'; model = 'evil-model' }
            $rejected = Invoke-Dispatcher -Fixture $codexFixture -Request $bad
            Assert-Equal 'invalid_request' $rejected.Result.status
            Assert-Match $rejected.Result.error 'not request-controlled'
        } finally {
            Remove-DispatcherFixture $codexFixture
        }
    }

    Invoke-TestCase 'T023d' 'Codex quota signature is a wait only on a failed invocation' {
        . (Join-Path $RepoRoot 'runner\actions\CodexAction.ps1')
        $text = 'You have reached your usage limit; resets 5:40pm (Europe/London)'
        $wait = Get-CodexQuotaWait -ExitCode 1 -Text $text
        Assert-True ($null -ne $wait)
        Assert-True ($wait.RetryAfter -gt [DateTimeOffset]::UtcNow)
        Assert-Equal $true ($null -eq (Get-CodexQuotaWait -ExitCode 0 -Text $text))
        Assert-Equal $true ($null -eq (Get-CodexQuotaWait -ExitCode 1 -Text 'ordinary command failure'))
    }

    Invoke-TestCase 'T023e' 'one executor cannot clear the other executor quota marker' {
        . (Join-Path $RepoRoot 'runner\actions\ClaudeAction.ps1')
        . (Join-Path $RepoRoot 'runner\actions\CodexAction.ps1')

        $marker = Join-Path $fixture.StateRoot 'quota-wait.json'
        [IO.File]::WriteAllText($marker, '{"executor":"claude"}', [System.Text.UTF8Encoding]::new($false))
        Set-CodexQuotaMarker -StateRoot $fixture.StateRoot -QuotaWait $null | Out-Null
        Assert-True (Test-Path -LiteralPath $marker) 'Codex must preserve a Claude quota marker'

        [IO.File]::WriteAllText($marker, '{"executor":"codex"}', [System.Text.UTF8Encoding]::new($false))
        Set-ClaudeQuotaMarker -StateRoot $fixture.StateRoot -QuotaWait $null | Out-Null
        Assert-True (Test-Path -LiteralPath $marker) 'Claude must preserve a Codex quota marker'

        Set-CodexQuotaMarker -StateRoot $fixture.StateRoot -QuotaWait $null | Out-Null
        Assert-Equal $false (Test-Path -LiteralPath $marker) 'Codex may clear its own quota marker'
    }

    Invoke-TestCase 'T024' 'doctor uses the dispatcher state root and a platform-native git executable' {
        $previousStateRoot = [Environment]::GetEnvironmentVariable('GPTLOOP_STATE_ROOT')
        try {
            [Environment]::SetEnvironmentVariable('GPTLOOP_STATE_ROOT', $fixture.StateRoot)
            $raw = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/doctor.ps1') -Json
        } finally {
            [Environment]::SetEnvironmentVariable('GPTLOOP_STATE_ROOT', $previousStateRoot)
        }

        # An isolated fixture deliberately has no daemon token or runner, so
        # doctor exits nonzero. Its report must still be complete and parseable.
        $doctor = ($raw -join "`n") | ConvertFrom-Json
        Assert-Equal $fixture.StateRoot $doctor.state.root
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$doctor.repo.commit)) 'doctor must resolve git on this platform'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$doctor.repo.branch)) 'doctor must report the branch'
        $problemText = @($doctor.problems) -join "`n"
        Assert-NotMatch $problemText 'install-windows' 'a non-Windows doctor must not prescribe the Windows installer'
    }

} finally {
    Remove-DispatcherFixture $fixture
}

exit (Write-TestSummary -Suite 'dispatcher')
