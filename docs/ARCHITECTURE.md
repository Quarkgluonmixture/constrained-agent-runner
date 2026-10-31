# Architecture

**Scope update — 2026-10-31:** this is the architecture of the retained public GPT Loop reference. The Phase 2/3/4 target sections below preserve the earlier design, not a current implementation commitment for this repository. Long-term evolution belongs to QCP; no migration or runtime retirement is asserted here. See [project positioning](../README.md).

This document describes both the **current implementation** and the staged
target architecture. The ownership rules are canonicalized in
[`OPERATING_MODEL.md`](OPERATING_MODEL.md).

## Ownership planes

GPT Loop has three distinct ownership planes:

```text
┌───────────────────────────────────────────────────────────┐
│ GPT Loop control plane                                   │
│ protocol · dispatch · durable state machine · wake       │
│ registry schema · scheduling/locking · shared security   │
└───────────────────────┬───────────────────────────────────┘
                        │ executes under trusted policy
                        ▼
┌───────────────────────────────────────────────────────────┐
│ Consumer project                                         │
│ task/issue · project checkpoint · project policy         │
│ project evidence · thin invocation adapter               │
└───────────────────────┬───────────────────────────────────┘
                        │ placed locally on
                        ▼
┌───────────────────────────────────────────────────────────┐
│ Machine / executor node                                  │
│ absolute workspace path · runner · processes · leases    │
│ installed executors · local registry · wake runtime      │
└───────────────────────────────────────────────────────────┘
```

The same logical project may have different machine-local placements. A project
does not acquire authority to select an arbitrary local path merely because it
can name itself in a request.

## Current end-to-end stock loop

```text
ChatGPT conversation
      │ immutable request in a gpt-loop issue
      ▼
gpt-loop GitHub issue ──▶ Actions ──▶ self-hosted runner
                                      │
                                      ▼
                                runner/dispatch.ps1
                             validate / resolve / mutex
                                │              │
                         bounded action    durable Claude slice
                                │              │
                                │        persistent project lease
                                │              │
                                │        runner/durable_job.py
                                │        owned long-lived jobs
                                ▼              ▼
                              structured result
                                      │
                        terminal: comment/close issue
                                      │
                        terminal only: local wake
                                      ▼
                             loopback wake daemon
                                      ▼
                              Chrome extension
                                      ▼
                             ChatGPT conversation
```

GitHub transports requests/results; it is not the safety boundary for filesystem
access. The trusted local registry maps a logical project key to a
machine-local workspace/profile and executor policy.

The stock workflow currently lives in `gpt-loop` and therefore makes this
repository the temporary execution-packet transport owner. That is an
implementation fact, not the target semantic ownership model.

## Target transport shape

Phase 2 moves project execution evidence toward the consumer repository while
keeping the shared mechanism centralized:

```text
consumer project issue / work item
          │
          ├── thin GPT Loop adapter
          ▼
shared GPT Loop protocol/control plane
          ▼
trusted node registry + scheduler
          ▼
registered local project placement
          │
          └── result/evidence returns to consumer project
```

The exact GitHub reusable-workflow/API shape is intentionally not frozen by the
Phase-1 docs. The invariant is that project work/evidence is project-owned and
shared mechanism behavior is not copied into every repo.

## Runner components

| Path | Responsibility |
| --- | --- |
| `runner/dispatch.ps1` | protocol validation, project resolution, **current machine mutex**, one action, result emission |
| `runner/lib/Common.ps1` | status taxonomy, StrictMode-safe reads, typed errors |
| `runner/lib/SafePath.ps1` | allowlist-first, link-resolved path containment |
| `runner/lib/Process.ps1` | legacy bounded process capture and process-tree timeout kill |
| `runner/lib/Registry.ps1` | local project/profile/interpreter policy |
| `runner/lib/Durable.ps1` | PowerShell bridge, durable slice timeout semantics, persistent execution state |
| `runner/durable_job.py` | stdlib durable execution/job state machine and process ownership |
| `runner/actions/ClaudeAction.ps1` | legacy Claude or durable sliced Claude executor |
| `runner/actions/CodexAction.ps1` | independent bounded Codex executor |

The legacy process runner remains unchanged in meaning: when its parent action
returns, that child is done. Durable mode is a separate opt-in lifecycle rather
than silently changing every command in the system.

## Logical project identity

A request names a logical project key. The trusted local registry resolves that
key to machine-local state:

```text
logical project id
      │
      ▼
machine-local registry
      ├── workspace root
      ├── profile
      ├── executor/interpreter policy
      └── durable command profiles / capabilities
```

Target Phase 4 extends this concept so Mac/Windows are explicit
capability-bearing nodes rather than assumptions embedded in project identity.

Examples of node capabilities may include:

- `claude`
- `codex`
- `browser`
- `posix-durable`
- `windows-runtime`
- device-specific capabilities

Capability names/schema are implementation work, not yet a Phase-1 runtime
contract.

## Result/control status

```text
invalid_request ─┐
denied ──────────┤ terminal before/without useful project execution
environment_error┘

success | failure | inapplicable | timeout | hard_blocker   terminal result
continuation | quota_wait                                  nonterminal control
```

`success` in durable mode is emitted only after the execution records
`closed_pass`. A zero Claude CLI exit alone cannot produce packet success.

`continuation` means the slice ended normally but the packet remains owned.
`quota_wait` means the account window, not the packet, prevented progress.
Neither may wake the brain in a durable deployment.

## Durable execution state

Each packet UUID binds to:

- immutable request SHA-256;
- one registered logical project / resolved workspace;
- an execution deadline and max slice count;
- one persistent project execution lease;
- zero or more stable named durable jobs;
- optional checkpoint and exactly one terminal declaration.

The next slice receives the existing execution summary. It can inspect, tail,
wait or adopt known jobs. It is not instructed to restart from scratch.

Durable jobs are selected by trusted `command_profiles`; a request cannot name an
executable or arbitrary cwd. Commands run in their own POSIX process group with
stable PID/process identity, bounded logs and terminal rc. The helper refuses
terminal `closed_pass` while any durable job remains unresolved.

### Orphan states

```text
starting → running → terminal
              │
              ├─ waiter lost, child identity alive → orphaned_running → adopt
              └─ neither child nor rc provable      → orphaned_lost
```

`orphaned_lost` is evidence, not a retry instruction. Adoption never fabricates
a historical rc that cannot be recovered.

### Escape audit

Every descendant of a durable Claude slice inherits an execution marker. Before
accepting terminal success, the control plane finds marked processes outside the
registered durable worker/adopter/child groups. Any escape is killed and turns
the packet into `hard_blocker`. On slice timeout, registered durable process
groups are preserved while Claude/unregistered descendants are killed. This is
what keeps direct `nohup`, `&`, `disown`, tmux, etc. from becoming an unowned
second execution plane without accidentally killing legitimate durable work.

## Concurrency and ownership

### Current implementation

Two ownership mechanisms exist today:

- **machine mutex** — only one dispatcher process mutates on a node at a time;
  later jobs wait rather than being replaced by GitHub concurrency;
- **persistent project execution lease** — a second durable execution cannot
  take the same registered project while packet A remains nonterminal.

The machine mutex means current deployments are:

> **multi-project addressable, machine-serialized**

It is incorrect to call this real multi-project parallel execution.

### Target Phase 3

The unconditional machine-wide serialization boundary becomes explicit resource
ownership:

```text
machine
  ├── machine-global lock        shared runtime/registry/restart/reboot
  ├── project A workspace lock   project A mutation
  ├── project B workspace lock   project B mutation
  └── named shared resources     browser/device/etc. where required
```

Non-conflicting project resources may execute concurrently. Conflicting work
must fail/wait according to one explicit policy rather than relying on a human
coordination issue.

The persistent durable project lease remains load-bearing: a packet between
slices still owns its project resource. Phase 3 changes the scope of
serialization, not the meaning of durable ownership.

## Machine-global vs project-local operations

Examples that normally require machine-global ownership:

- replacing/updating the shared GPT Loop runtime;
- mutating machine-local project registry structure/state;
- restarting a shared GPT Loop daemon/runner service;
- rebooting or otherwise changing the executor node itself.

Examples that should normally be project/workspace-scoped:

- repository code/docs edits;
- project tests/builds that do not consume an exclusive shared device;
- project-local durable jobs;
- project-specific evidence generation.

A later resource model may add named shared resources (browser profile, physical
device, simulator, GPU, etc.) where project-only locking is insufficient.

## Request durability and continuation transport

Initial stock issue bodies are immutable at the GitHub event level and carry
`request_sha256`. For durable continuation, the exact executable request is also
persisted locally under `requests/<job_id>.json`. The continuation workflow input
contains only that UUID plus bookkeeping such as an issue number. That prevents
a later dispatch or moving repository pointer from substituting a new prompt.

The stock workflow self-dispatches on `continuation`. If dispatch transport
fails, the local execution remains nonterminal and owned; the workflow fails
visibly rather than waking with a fake terminal verdict. Deployment
watchdog/recovery must inspect the existing UUID.

Phase 2 may relocate the GitHub packet/evidence surface but must preserve the
immutability and same-UUID continuation properties.

## Wake delivery state machine

```text
received → queued → claimed → submitted → verified → acknowledged
              ▲                    │
              └────────────────────┘
```

Only `acknowledged` is terminal. The extension advances only after it observes
the unique marker in a user message. Durable nonterminal states never enter this
state machine.

Wake is a shared mechanism. A consumer project may configure/invoke it but
should not redefine this state machine locally.

## Executor boundaries

Claude and Codex remain separate actions. Requests cannot choose a workspace or
executable. Claude durable mode additionally requires an explicit trusted Python
interpreter and command profile registry. It is currently POSIX-only because
process provenance must be enforceable before cross-slice background work is
allowed.

## Documentation boundaries

- `gpt-loop`: reusable mechanism and architecture.
- consumer repo: project policy, work, checkpoint, project evidence.
- machine-local state: paths, live leases/processes/tokens/node placement.
- historical evidence: preserve as evidence; do not rewrite into current
  authority.

See [`OPERATING_MODEL.md`](OPERATING_MODEL.md) before changing a
consumer workflow or moving a control-plane behavior between repositories.
