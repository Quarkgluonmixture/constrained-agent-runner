# Troubleshooting

Every entry below is a failure that actually happened. Each has a regression
test; the test id is in brackets.

---

## Job execution

### A job ran a different request than the one I meant to send `[T001]`

**Cause.** The issue was created with body A and edited to body B. The workflow
triggers on `issues.opened` and reads the body from that payload, so the runner
had already taken A.

**Fix.** Executable issue bodies are immutable. Put the complete request in the
initial creation, always. Compare `request_sha256` in the result against the
hash of the body you believe you sent.

### A queued job vanished without a trace `[T015]`

**Cause.** A shared GitHub `concurrency` group. Its semantics allow a newer
pending job to replace an older pending one — fine for CI, unacceptable for a
job queue.

**Fix.** There is no concurrency group. Serialization is a machine-level mutex,
so a second job waits. If the lock cannot be acquired within the timeout, the
result is `environment_error` — visible, never silent.

### `No module named pytest` reported as a quality failure `[T019]`

**Cause.** The dispatcher used `<workspace>\.venv\Scripts\python.exe` if it
existed and PATH `python` otherwise. The project's `.venv` was its *runtime*
environment and had no test dependencies.

**Fix.** Interpreters are configured per role in `projects.json`:

```json
"python": { "runtime": "C:\\...\\python.exe", "test": "C:\\...\\python.exe" }
```

If a role is unset, the result is `environment_error` naming the missing key.
The control plane never guesses an interpreter and never installs a dependency
into a project environment to make its own check pass.

### A benchmark's nonzero exit was reported as a regression

**Cause.** Every nonzero exit was forced into "quality failure". The curated
evaluation set was incompatible with the current corpus — 0 of 12 required pages
present — so it could not evaluate anything, and said so with exit code 3.

**Fix.** Profiles map exit codes to statuses:

```json
"exit_status_map": { "0": "success", "3": "inapplicable" }
```

**Corpus incompatibility is not a model regression.** See
`docs/CHATGPT_BRAIN_PROTOCOL.md`, invariant 4.

### The dispatcher crashed on a request that omitted an optional field `[T009]`

**Cause.** Under `Set-StrictMode -Version Latest`, reading an absent property
throws. `$params.limit` blew up whenever `limit` was not supplied.

**Fix.** All optional access goes through `Get-Prop` / `Get-IntProp`, which
return a default for absent-or-null and raise `invalid_request` for out-of-range
values. Tests cover requests with and without optional params.

> This class of bug recurred *during* the rewrite: `$script:GptLoopLastStep` was
> read in an error handler without being initialised, which made every action
> report `failure`. Initialise every `$script:` variable at definition.

---

### A job failed in exactly ten minutes with no steps and no logs

**Cause.** The machine slept between the moment the runner accepted the job and
the moment it spawned a worker. The listener stops mid-handshake, GitHub's job
lease expires ten minutes later, and the run is marked `failure`. Nothing ever
ran, so there is no step list, no `_diag/Worker_<start>-utc.log`, and
`gh run view --log` answers `log not found`.

**Signature** — the three together, none of which a real task failure produces:

| Check | Sleep-interrupted | Real failure |
| --- | --- | --- |
| `started_at` → `completed_at` | exactly 600s | anything |
| `steps` | `0` | > 0 |
| matching `_diag/Worker_*.log` | absent | present |

```bash
gh api repos/<owner>/<repo>/actions/runs/<id>/jobs \
  --jq '.jobs[] | "\(.started_at) \(.completed_at) steps=\(.steps|length)"'
pmset -g log | grep -E "Sleep |Wake "      # macOS: what the machine did then
```

Confirmed in a real incident: sleep was logged one second before the job was
accepted.

**⛔ No wake is emitted either, and that is the part that stalls the loop.**
`Wake the conversation` is `if: always()`, but *always* still means "after the
job's earlier steps" — and there were none. The research side receives nothing
at all, which is indistinguishable from a round still in flight. ⇒ The loop does
not report a failure; it goes quiet. See *A job finished but no wake arrived*.

**Fix.** Do not let the machine sleep while the loop can be triggered — see
*macOS: the machine must not sleep while the loop is armed*. Re-kick the stalled
round with `workflow_dispatch` (`gh workflow run gpt-loop.yml --ref main`);
⚠️ that path does **not** comment on or close the originating issue, so an issue
opened for the dead round stays open and must be closed by hand.

---

### A round committed to a branch nobody was reading

**Cause.** `projects.json` points a project at a **workspace**, and for a
single-checkout project that workspace is the same directory a human works in.
The dispatcher creates no worktree and pins no branch — it runs the executor
wherever the checkout happens to be. ⇒ Whatever branch is checked out when the
next round fires is the branch that round commits to.

**⚠️ So `git checkout -b` in the workspace is a scheduling action, not a local
one.** A branch left checked out while the loop is armed hijacks the next round
silently: the run succeeds, the commit is real, the report-back is honest, and
none of it is where the research side is looking. Nothing reports an error,
because nothing went wrong — the executor did exactly what it was told, in a
place nobody named.

**Discipline.** Treat the workspace as owned by the loop, not by you.

- Edit, commit, and return the workspace to the branch the loop expects in one
  unbroken sequence. ⛔ Never end a turn with the workspace on your own branch.
- Before touching it at all: `git status --porcelain` empty **and** no run in
  flight (`gh run list --limit 1`). A dirty tree means a round is mid-flight or
  left partial work — in either case it is not yours to move.
- Need a branch to live for a while? Give it its own `git worktree` somewhere
  else and leave the project's workspace alone.

---

## File edits

### An exact replacement failed on a file that clearly contained the text `[T010]`

**Cause.** CRLF. The file used `\r\n`; a JSON payload necessarily carries `\n`,
so the needle never matched.

**Fix.** `newline_mode` defaults to `auto`: the needle and replacement are
translated to the file's existing convention before matching. **The file itself
is never normalised** — only the search strings are adapted, so a CRLF file stays
CRLF and no bare LF is introduced. Use `newline_mode: "exact"` for byte-exact
matching.

### A replacement hit more occurrences than intended `[T011]`

**Fix.** `expected_count` (default 1) is checked before anything is written. A
mismatch writes nothing and returns `failure` naming both counts and the file's
newline convention.

### `patch contains no recognized safe file targets` `[T012]`

**Cause.** The patch used the `*** Begin Patch` / `*** Update File` dialect. The
validator only recognises real unified-diff headers.

**Fix.** That dialect is now rejected with an explicit message naming the
supported format. Use:

```diff
--- a/path/to/file
+++ b/path/to/file
@@ -1,3 +1,3 @@
```

`apply_patch` also needs the workspace to be a git repository (it uses
`git apply --check` before applying).

---

## Permissions

### `denied` on a path that looks fine `[T005] [T006]`

Check, in order:

1. Is any segment `.git`, `.github`, `.env`, `secrets`, or `node_modules`?
   Those are permanently denied so a job cannot rewrite the control plane.
2. Is the path inside the profile's `allowed_roots` / `allowed_files`?
3. Is it relative? Absolute, drive-qualified, and UNC paths are rejected.
4. Does it traverse? `../` and `..\` are rejected in every form.
5. Does it cross a symlink or junction out of the workspace? Containment is
   checked against the link-resolved real path.

`denied` is the system working. Re-scope the request.

### `project is not registered on this machine` `[T017]`

The `project` key is not in `%LOCALAPPDATA%\GPTLoop\projects.json`. Add it
locally; there is no way to supply a workspace from the request, by design.

---

## Wake delivery

### The conversation received the same wake twice `[T002]`

Should be impossible. Delivery is keyed on `event_id`
(`<run_id>:<run_attempt>:<issue_number>`), duplicate POSTs are no-ops, and an
event is consumed only once. If you see this, capture
`%LOCALAPPDATA%\GPTLoop\events\events.jsonl` and report it.

Note that **re-running a workflow is a genuinely new wake** — `run_attempt`
increments, so the event id differs. That is intended.

### A job finished but no wake arrived

Work down the chain:

```powershell
pwsh -File scripts\doctor.ps1
```

0. **The job never emitted one.** Check the run's step list before the chain
   below: `steps == 0` means the job died before `Wake the conversation`, so
   there is nothing for the daemon or the extension to have lost. Everything
   downstream will look healthy and you will find nothing. See *A job failed in
   exactly ten minutes with no steps and no logs*.
1. **Daemon unreachable** — start it: `pwsh -File scripts\start-daemon.ps1`.
2. **Pending count > 0** — the daemon has the event; the browser side is not
   consuming it. Check the extension popup.
3. **Extension shows "daemon unreachable"** — the token or port in its settings
   is wrong. Re-run `scripts\stage-extension.ps1` and press Reload.
4. **Extension shows a pending event and a `lastError`** — read it. Common causes
   below.

The result is always on GitHub regardless; the wake is a convenience, not the
transport.

### `submission was not verified` `[T003] [T004]`

The extension typed the marker but never observed it in a user message. It
reports `failed`, the daemon re-queues the **same** event, and it retries.

Usual causes: the model was still streaming (submission waits for idle, but a
long generation can exceed the window); the composer was in an unexpected state;
the tab was backgrounded and throttled.

The cursor does **not** advance on an unverified submit. That is the point.

### `marker already present in conversation`

The wake marker was already visible before submission, so a successful send
could not be distinguished from a stale one. The attempt is refused rather than
credited. This usually means a previous delivery actually succeeded and the ack
was lost — check the conversation before forcing anything.

### The wake stops working after Chrome restarts

MV3 service workers are evicted aggressively. Recovery is by `chrome.alarms`
(one minute, the shortest interval Chrome honours reliably), so a wake can be up
to a minute late after an eviction. If it never arrives, open the popup — that
wakes the worker — and press **Poll now**.

---

## Runner

### `runner_online: true` but no gpt-loop runner exists

**Cause.** The supervisor matched `Runner.Listener.exe` by process name, so
another repository's runner satisfied the check.

**Fix.** It now matches the executable path under its own `runner_dir`. If you
host several runners, each daemon supervises only its own.

### The listener process is alive but GitHub says the runner is offline

**Cause.** macOS sleep can leave `Runner.Listener` running yet permanently
detached from the broker: the process never exits, never logs another line and
never accepts another job. On 2026-08-19 its last line was the token request
written at the instant of sleep; the following fourteen hours produced nothing.

**⚠️ `runner_online` cannot see this.** `RunnerSupervisor._listener_running()`
answers "a listener under our runner directory exists", which is process
existence — and a wedged listener exists. The field is honest about what it
measures and useless for this failure. ⇒ Ask GitHub, which is the only party
that knows whether the runner is actually reachable:

```bash
gh api repos/<owner>/<repo>/actions/runners \
  --jq '.runners[] | "\(.name) status=\(.status) busy=\(.busy)"'
```

An offline-capable second signal: the newest `_diag/Runner_*.log` has had no
write for longer than a poll interval.

**⚠️ On macOS the supervisor could not restart it in any case.**
`start_if_needed` returns early unless `run.cmd` exists, and a macOS runner ships
`run.sh`. Where the runner is a launchd job the config sets
`supervise_runner: false` and launchd owns it — but note that `RunAtLoad`
without `KeepAlive` would not have helped here either, because the process did
not die.

**Fix.**

```bash
launchctl kickstart -k gui/$(id -u)/actions.runner.<owner>-<repo>.<runner-name>
```

Then confirm with the `gh api` call above that GitHub sees `status=online`, not
merely that a process is back.

---

### The runner does not come back after a reboot

It is not a Windows service (that needs admin). The wake daemon supervises it,
so the daemon must start at logon:

```powershell
pwsh -File scripts\start-daemon.ps1 -Register
```

After registering the runner, the supervisor can take up to ~60s to notice it —
its retry backoff grows to a minute while nothing is there to start.

---

## Diagnostics

```powershell
pwsh -File scripts\doctor.ps1            # human-readable
pwsh -File scripts\doctor.ps1 -Json      # machine-readable, exit 1 if unhealthy
```

Logs and state:

| Path | Contents |
| --- | --- |
| `%LOCALAPPDATA%\GPTLoop\events\events.jsonl` | Every delivery transition |
| `%LOCALAPPDATA%\GPTLoop\logs\extension.jsonl` | Extension diagnostics (token-scrubbed) |
| `%LOCALAPPDATA%\GPTLoop\logs\daemon.out.log` | Daemon stdout |
| `%LOCALAPPDATA%\GPTLoop\logs\runner.log` | Supervised runner output |
| `%LOCALAPPDATA%\GPTLoop\results\<job_id>.json` | Complete untruncated results |

An unexpected dispatcher error records its PowerShell stack trace in the
`dispatch_error` step of the stored result.

---

## macOS: the daemon cannot read a script under `~/Documents`

**Symptom.** The wake daemon's LaunchAgent dies immediately with
`can't open file '…': [Errno 1] Operation not permitted`, while running the very
same command from a terminal works.

**Mechanism.** macOS TCC protects `~/Documents`, `~/Desktop` and `~/Downloads`
per *process*. A terminal has usually been granted access; a LaunchAgent has
not, and the denial surfaces as a plain permission error rather than as anything
mentioning privacy.

⇒ **Rule.** The control plane lives outside those directories — `~/gpt-loop`,
not `~/Documents/gpt-loop`. ⛔ Do not "fix" this by copying the daemon into the
state root: that produces a second copy of the daemon which will drift from the
repository, and the drifted one is the one that runs.

⚠️ A project *workspace* under `~/Documents` is fine; the Actions runner reads
those successfully. It is the control plane's own files that must move.

---

## macOS: `claude_task` reports `Not logged in · Please run /login`

**Symptom.** Every other action succeeds. `claude_task` fails in ~2 seconds with
`"result": "Not logged in · Please run /login"` and `is_error: true`.

**Mechanism.** Claude Code's interactive credentials live in the login keychain.
A LaunchAgent-managed runner does not inherit the keychain grant the user's
terminal has, so the CLI starts, finds no usable credential, and exits cleanly.
⚠️ Nothing is misconfigured in gpt-loop, which is why the result looks like a
model failure rather than an environment one.

⇒ **Fix.** Give the runner a long-lived token instead of relying on the keychain:

```sh
claude setup-token                    # interactive, once
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN" >> ~/actions-runner-gptloop/.env
chmod 600 ~/actions-runner-gptloop/.env
cd ~/actions-runner-gptloop && ./svc.sh stop && ./svc.sh start   # re-read .env
```

⚠️ The runner reads `.env` **at start**. Editing it while the service is running
changes nothing, and the next failure looks identical to the first — which is
its own way to lose an afternoon.

---

## macOS: the machine must not sleep while the loop is armed

**Why it matters.** The loop is triggered by GitHub, not by the user, so it must
survive an idle machine. A default `pmset` of `sleep 1` on AC gives the runner a
one-minute window, and everything then happens inside brief DarkWake periods —
where a job can be accepted one second before the machine goes back to sleep.
Two distinct failures come from this: *A job failed in exactly ten minutes with
no steps and no logs*, and *The listener process is alive but GitHub says the
runner is offline*.

⚠️ Do not rely on an editor or terminal holding the machine awake. Tools that
take a short power assertion (for example `caffeinate -i -t 300`) release it
minutes later, so the machine stays awake only while someone is actively typing
— which is exactly not when the loop needs it.

**Check what is actually asserted:**

```bash
pmset -g            # SleepDisabled, and who is currently preventing sleep
pmset -g custom     # the configured idle sleep timers
```

**Two independent measures; prefer both.**

| Measure | Covers | Notes |
| --- | --- | --- |
| `sudo pmset -c disablesleep 1` | idle sleep **and** closing the lid | needs sudo; the stronger of the two |
| a launchd agent running `caffeinate -s` | idle sleep on AC | no sudo; ⛔ does not stop clamshell sleep, ⛔ no effect on battery |

## The dispatcher test suite hangs while a real round is in flight

**Signature.** `tests/dispatcher/Run-DispatcherTests.ps1` produces **no output at
all** and never exits. It looks exactly like a newly added test case broke the
harness.

**Mechanism.** The suite's fixture spawns real `dispatch.ps1` processes, and every
dispatcher takes the **machine-level** mutex `Global\gpt-loop-dispatcher` — the
same one a live round holds — with `-LockTimeoutSeconds 3600`. The test
dispatchers therefore queue behind the executor for up to an hour.

```sh
ps -eo pid,etime,command | grep -E "claude -p|dispatch.ps1" | grep -v grep
```

⇒ ⛔ Check for a live `claude -p` before suspecting the tests. Run the suite only
when `gh api repos/<owner>/<repo>/actions/runners --jq '.runners[].busy'` is
`false`. The waiting is correct behaviour (serialization is the whole point);
only the diagnosis is hard.

## `continue-on-error` rewrites a failed step's conclusion to `success`

**Signature.** A step visibly failed in the log, yet
`gh api .../jobs --jq '.jobs[].steps[]'` reports `"conclusion": "success"` for it.
Anything keying on that field concludes the step did its job.

**Mechanism.** With `continue-on-error: true` GitHub sets the step's *outcome* to
`failure` and its *conclusion* to `success`. Only `outcome` is the truth, and the
jobs API exposes conclusion.

**Measured 2026-08-21.** The round-log POST died on a transient
`HttpError: fetch failed`; the API said the step concluded `success`; not one
character had been posted. That is the same class of lie the delivery gate exists
to kill, one layer down.

⇒ ⛔ Never put `continue-on-error` on a step that is the only path for
information out of the loop. Retry, then `core.setFailed`. Reserve it for
genuinely decorative steps (a commit status).

## ⛔ Do not write to the loop's workspace while a round is in flight (violated twice on 2026-08-21)

**Why it is tempting.** The workspace is a plain checkout that a human also uses,
so editing a file there feels local. It is not: `projects.json` points the
executor at that exact tree, and the delivery gate measures it.

**What it costs.** Both violations on 2026-08-21 were the same shape:

1. An uncommitted edit of `gpt-loop.yml` was in the tree when a real-device round
   ran ⇒ the gate reported `dirty_workspace`, the research side began a residue
   recovery packet for residue that did not exist, and a human had to correct the
   round log by hand.
2. Hours later, the same edit pattern again —— this time landed as a commit and a
   push **mid-round**, which forces the executor to rebase before it can push.
   That is the exact race the delivery gate was built to catch.

**⇒ The check before touching that tree, in this order:**

```sh
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[].busy'   # false, or stop
curl -s -H "X-GPTLoop-Token: $(cat "$HOME/Library/Application Support/GPTLoop/token.txt")" \
  http://127.0.0.1:8777/health --get | python3 -c 'import json,sys;print(json.load(sys.stdin)["round"])'
```

⭐ The daemon's `round.in_flight` answers this directly and without asking
GitHub —— it was added the same day for the stall watch, and this is its second
use. ⛔ `git status` is not the check: a round that has not written anything yet
leaves a clean tree.

**⚠️ If you are already mid-edit when a round starts**, the least-bad move is to
land the change (commit + push) so the tree is clean at the gate —— a stray
uncommitted file produces a false `dirty_workspace`, which costs the research
side a round. ⛔ But that is damage control, not the plan.


---

## Durable continuation / long-running execution

These entries are regression-backed design responses to a measured consumer
failure where `claude_task` exited successfully while a mutation shard was still
nonterminal. They are **not** production-smoke claims until the live Mac rollout
runs the full PowerShell suite and a harmless multi-slice job.

### Claude returned success while its long shard was still running

Legacy `claude_task` equated CLI exit 0 with action success. Durable mode changes
that boundary: Claude exit ends only one execution slice. Packet success requires
an explicit `closed_pass`, no unresolved durable jobs, a clean provenance audit,
and audited finalization. Without that terminal handshake the result is
`continuation`, never fake `success`.

Do not fix this by setting Claude to 180 minutes. The consumer in that incident
had a 120-minute outer workflow ceiling. Use bounded slices (recommended ~40 minutes),
a separately bounded multi-hour execution, and at most ~105–110 minutes as a
legacy/emergency executor ceiling.

### A durable job died exactly when the Claude slice hit its budget

That indicates the wrong timeout primitive. Legacy `Invoke-CapturedProcess`
intentionally kills the entire descendant tree; a durable Claude slice must
instead preserve PIDs/process groups already registered under the execution and
kill Claude plus unregistered descendants. If owned-PID enumeration itself
fails, the control plane fails closed, kills the whole tree, aborts the packet,
and returns `hard_blocker` rather than pretending continuation survived.

### `closed_pass` exists but the project lease is still present

This is intentional until ownership finalization. Claude calls `complete` while
Claude itself is still alive, so terminal declaration cannot release the lease.
The dispatcher audits marked processes first, writes `finalized.json`, and only
then releases `execution-leases/<project>.json`. If a workflow dies between
terminal declaration and finalization, the same execution UUID re-enters the
audit path; a foreign execution cannot steal that lease.

### A durable packet keeps returning `continuation`

Inspect the existing UUID; do not mint a replacement packet. Use
`summary`, `job-status`, `job-tail`, bounded `job-wait`, or `job-adopt`.
`running` means join the same child; `orphaned_running` means the original waiter
died but the recorded child identity is alive; `orphaned_lost` means neither a
living child nor terminal rc can be proven and must be investigated, never
blindly rerun or synthesized as rc=0.

### A root command exited zero but the durable job is nonzero

The helper found processes still alive in the command's owned process group. It
kills those descendants and records a nonzero rc; `cmd & exit 0` cannot fake job
completion. Make the command's root lifetime represent the real task, or model
the real long task as the registered durable job.

### Ownership audit reports escaped work

Every durable Claude descendant inherits `GPTLOOP_EXECUTION_ID`. Processes with
that marker that are outside registered durable worker/adopter/command groups are
unowned escapes (`nohup`, `&`, `disown`, tmux/screen, etc.). The audit kills them
and converts the execution to `hard_blocker`. If the platform cannot perform the
audit reliably, durable mode fails closed; current durable continuation is
POSIX-only and Windows remains on the legacy bounded path.

### `quota_wait` or `continuation` produced no wake

Correct. They are nonterminal control states. `continuation` self-dispatches the
same UUID. `quota_wait` is re-entered by the deployment retry owner after reset
(the consumer adapter must provide one). Only an audited/finalized packet terminal proceeds
to the conversation wake path.

State lives under the platform GPTLoop root: `requests/<uuid>.json`,
`execution-leases/<project>.json`, and `executions/<uuid>/` containing execution,
checkpoint, terminal/finalized markers, stable named jobs, logs and rc evidence.
Do not clear those files by hand while an owned process may still exist; inspect
and cancel/abort first.
