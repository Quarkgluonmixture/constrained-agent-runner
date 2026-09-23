# Durable continuation and long-running jobs

This document defines the **shared GPT Loop control-plane contract** for work
that can outlive one executor round or one workflow run.

It deliberately does not define any consumer repository's rollout plan,
workflow trigger, round log, timeout choice, or project authority. Those facts
belong to the consumer repository that owns the work.

The load-bearing rule is:

> **executor slice ended ≠ packet completed**

A Claude/Codex process can exit while a build, benchmark, mutation shard, or
other child it started is still alive. Increasing a timeout does not solve that
ownership problem.

Durable continuation is opt-in through trusted machine-local project policy.
Projects that do not enable it retain the bounded executor path.

## Vocabulary

- **packet** — one immutable authorized execution request, identified by
  `job_id` and request hash;
- **execution** — persistent machine-local state for one packet UUID; it may span
  several workflow/process slices;
- **slice** — one bounded executor invocation;
- **durable job** — a long-lived command started through a trusted local command
  profile and owned by the execution across slices.

Transport placement is orthogonal. The packet may have entered through a
project-native adapter or the central `gpt-loop` broker; durable ownership starts
once the trusted dispatcher accepts the immutable packet.

## Packet state machine

```text
                  ┌──────────── continuation ─────────────┐
                  │                                       │
OPEN ── slice ────┼── quota_wait ── adapter re-entry ──────┤
                  │                                       │
                  └── explicit terminal handshake ────────┘
                                      │
                         closed_pass | hard_blocker | failure
                                      │
                                   TERMINAL
```

`continuation` and `quota_wait` are **nonterminal control states**, not verdicts.
They do not authorize a new packet and must not be turned into project success or
failure.

`closed_pass` maps to public result status `success`. A zero executor exit in
durable mode is insufficient: terminal success requires an explicit terminal
declaration plus successful ownership finalization.

## Persistent machine state

Under the platform GPT Loop state root:

```text
requests/<job_uuid>.json                   immutable executable request
execution-leases/<project>.json            persistent project execution lease
executions/<job_uuid>/
  execution.json                           project/workspace/request hash/deadline
  checkpoint.json                          last slice checkpoint
  terminal.json                            closed_pass | hard_blocker | failure
  finalized.json                           ownership audit complete
  jobs/<stable-name>/
    request.json                           trusted profile + args + cwd identity
    state.json                             worker/child PID + process identity/PGID
    stdout.log
    stderr.log
    rc.json                                terminal rc, or explicit lost_rc
```

This is **machine runtime state**, not project backlog/checkpoint state. A
consumer may retain a compact result identity/link as project evidence, but it
must not copy live PIDs, leases, or mutable runtime state into project authority.

The current dispatcher still has a machine-wide mutex. The persistent project
execution lease is a separate, longer-lived invariant: a slice may release the
mutex, but another packet may not acquire the same durable project while the
first execution remains nonterminal.

Phase 3 will refine ordinary machine-wide serialization into explicit resource
ownership; it must preserve this persistent packet/project ownership property.

## Finalization and lease recovery

Lease recovery is fail-closed. A terminal declaration alone does **not** release
its lease.

The executor can declare terminal while descendants are still alive, so GPT Loop
performs the ownership audit, records `finalized.json`, and only then releases
the lease. A nonterminal or terminal-but-unfinalized execution is never displaced
merely because its previous workflow/process slice vanished.

Rollback and recovery must never manufacture success from an execution whose
ownership cannot be proved clean.

## Durable job ownership

`runner/durable_job.py` is standard-library-only and is invoked using an
explicit interpreter configured by trusted machine-local policy. An untrusted
execution envelope cannot select an arbitrary executable, cwd, environment, or
shell command.

Durable jobs use named trusted `command_profiles`. Starting the same stable job
name with the same command identity is idempotent; reusing that stable name for
a different command fails closed.

On POSIX, each durable command receives its own process group. The helper records
worker PID, child PID, process-start identity and PGID before `job-start`
returns. This publication handshake prevents a killed waiter from leaving a
process that exists but has no durable identity.

When the root child exits, the helper checks the entire owned process group. A
remaining descendant is killed and the job becomes nonzero; `cmd & exit 0`
cannot fake completion.

When an executor **slice** reaches its budget, the durable slice runner kills the
executor and unregistered descendants while preserving PIDs belonging to
registered durable process groups. The whole point is that authorized long work
may survive the reasoning slice that launched it.

Logs are continuously drained into stable bounded files. Credential-like
inherited environment values are scrubbed before the durable child starts.

## Inspect, join, and adopt

A later slice must not blindly rerun a known durable job. It may:

- inspect `summary` / `job-status`;
- tail bounded logs;
- wait for a bounded interval;
- adopt an orphan whose recorded child identity can still be proved alive.

If the original waiter vanished while the recorded child identity remains alive,
the job is `orphaned_running`. `job-adopt` attaches a new waiter to that same
child.

If a new waiter cannot recover an exit code that happened while nobody was
waiting, GPT Loop records `exit_code: null, lost_rc: true`; it never synthesizes
rc=0.

If neither worker nor recorded child can be proved alive and no rc exists, the
state is `orphaned_lost`. That is evidence requiring inspection or a blocker,
not permission to rerun the command.

## Escape audit: no disguised detached work

Helper ownership is not sufficient because an executor can invoke shell tools
itself. Every durable slice marks descendants with `GPTLOOP_EXECUTION_ID`.
Before a terminal packet is accepted, the control plane audits marked processes
against the registered durable workers/adopters/process groups.

An unregistered marked descendant is an ownership escape: it is terminated and
the execution becomes `hard_blocker`.

If the platform cannot perform reliable process-provenance enforcement, durable
mode fails closed. The current implementation is **POSIX-only**; Windows keeps
the bounded executor path until equivalent provenance enforcement exists.

## Budgets

The mechanism intentionally separates:

1. `claude.timeout_seconds` (or equivalent executor timeout) — emergency
   per-process ceiling;
2. `claude.durable.slice_seconds` — normal bounded reasoning/executor slice;
3. `claude.durable.execution_timeout_seconds` + `max_slices` — total packet
   lifetime.

Exact numbers are deployment policy. They must be chosen with the consumer
workflow ceiling and real workload in mind. A workflow timeout shorter than the
executor emergency ceiling is a configuration contradiction, not durable
continuation.

Do not encode consumer-, Mac-, or Windows-specific timeout numbers here.

## Immutable continuation contract

The first accepted durable slice persists the exact executable request to:

```text
<state>/requests/<job_uuid>.json
```

Any later adapter re-entry carries only the same UUID plus bookkeeping needed by
that adapter. The dispatcher reloads the persisted packet locally.

A continuation must **not**:

- reread a moving project pointer and treat it as the old packet;
- accept a replacement prompt for the same UUID;
- rebuild the packet from current repository state;
- mint a second project task because a slice ended;
- change canonical `work_ref`/request identity mid-execution.

For `status=continuation`:

- keep the packet nonterminal;
- do not emit a terminal project verdict;
- do not wake the reasoning conversation as if work finished;
- re-enter the same UUID through the deployment adapter.

For `status=quota_wait`:

- keep the same packet nonterminal;
- preserve the exact persisted request;
- let the deployment-specific retry owner re-enter the same UUID after the
  executor window opens.

Only an audited/finalized terminal result proceeds through that adapter's
terminal delivery surface (broker comment/close, project round log, commit
status, wake, or other project-defined evidence channel as applicable).

## Transport ownership

Durable continuation does not choose whether a consumer uses:

- a **project-native adapter**, or
- the **central `gpt-loop` broker**.

Both must preserve the same immutable UUID/request hash and nonterminal/terminal
semantics.

Adapter-specific facts stay with the adapter:

- issue number / issue close rules belong to the central broker adapter;
- project round-log / pointer / retry guards belong to the consumer adapter if
  that project owns them;
- machine-local command profiles/interpreters stay on the machine.

## Consumer deployment notes

Consumer-specific rollout truth must live in the consumer repository.

A consumer that adopts durable mode should keep its own deployment note (for
example `docs/GPT_LOOP_DURABLE_DEPLOYMENT.md` in the consumer repository) that
records, e.g., the distinction between an isolated smoke-test project and the
production adapter. This shared document must not be used to infer any
consumer's current workflow state.

## Generic rollback invariants

Rollback is deployment-specific, but every adapter must preserve these shared
rules:

1. inspect active execution ownership before disabling durable mode;
2. stop/abort owned durable jobs and prove no registered or escaped process
   remains before deleting anything;
3. disable durable policy only through trusted machine configuration;
4. leave execution/request records available for audit unless an explicit
   retention policy says otherwise;
5. restore adapter/runtime versions as an explicit deployment operation;
6. never convert a nonterminal or unfinalized execution into legacy `success`.
