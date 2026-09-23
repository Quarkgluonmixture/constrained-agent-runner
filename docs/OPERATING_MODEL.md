# GPT Loop Operating Model

## Purpose

GPT Loop is a shared execution control plane. It is **not** the workspace,
backlog, or source of truth for the projects it executes.

The core ownership rule is:

> **GPT Loop owns the mechanism. Project repositories own the work. Machines own runtime state.**

Transport placement is a separate concern. A project may reach the same shared
mechanism through a project-native adapter or through the central `gpt-loop`
broker. Neither topology changes who owns the work.

See [`BROKER_TRANSPORT.md`](BROKER_TRANSPORT.md) for the current transport
contract.

## The three ownership layers

### 1. GPT Loop — shared mechanism

The `gpt-loop` repository owns reusable control-plane behavior:

- request/result protocol and status taxonomy;
- constrained dispatch and executor policy;
- durable continuation and execution ownership;
- wake delivery;
- installer/setup/doctor behavior;
- project-registry schema and validation;
- scheduling, locking and resource-conflict semantics;
- cross-platform node capability semantics;
- security boundaries and reusable tests;
- the stock central broker workflow used by consumers that do not have a
  project-native adapter.

Issues in this repository that describe GPT Loop itself — product changes,
control-plane bugs, shared runtime incidents — remain normal GPT Loop product
issues.

A central `[GPT-LOOP]` issue for another project is only a short-lived execution
envelope/audit record. It is not project backlog, checkpoint, or coordination
truth.

### 2. Consumer project — canonical work and project policy

Each consumer repository owns:

- canonical task / issue / plan / research authority;
- project-specific scope and acceptance criteria;
- project checkpoint, TODO and project state;
- project-specific execution policy that must travel with the project;
- durable project evidence and interpretation of execution results;
- any project-local runbook describing how that project uses GPT Loop;
- a project-native transport adapter when that repository genuinely has one.

Examples in the docs below use placeholder names such as `native-app` (a
project-native consumer) and `brokered-app` (a brokered consumer).

A consumer repository may say *how this project uses GPT Loop*. It must not
silently redefine shared request/status, dispatcher security, durable ownership,
locking or wake semantics.

### 3. Machine — local runtime state

A machine owns ephemeral and machine-specific state:

- absolute workspace paths;
- installed executors and interpreter paths;
- runner identity and capabilities;
- active PIDs/process groups;
- packet/job runtime state;
- leases and locks;
- wake queues/tokens;
- machine-local project registry entries.

This state does not belong in a project issue or repository unless a sanitized
snapshot is retained as incident evidence.

## One mechanism, two valid ingress topologies

### Project-native adapter

A consumer with a repository-local runner/workflow may invoke the machine-
installed shared GPT Loop runtime directly from its own repository event.

In the reference deployment one consumer (`native-app`) uses this shape. Its
pointer/research/project round semantics remain consumer-owned, while the shared dispatcher/protocol/durable machinery
remains GPT Loop-owned.

Project-native does not mean "copy one consumer's workflow everywhere". It is valid only where
the actual runner/adapter topology supports it.

### Central broker

A consumer without a project-local runner/adapter may use the repository-scoped
runner attached to `gpt-loop`. In that case the central envelope points back to
canonical project work through `work_ref`.

In the reference deployment, consumers without their own runner (`brokered-app`)
use this shape.
The broker may own an execution envelope without owning the project work.

## Why transport cannot be normalized by aesthetics

The reference deployment lives under a personal (non-organization) GitHub
account. GitHub's runner
rules mean:

- repository-level self-hosted runners are dedicated to one repository;
- reusable workflows use self-hosted runners available to the caller context;
- organization-level runners are the normal mechanism for sharing a runner pool
  across many repositories.

Therefore:

- forcing every project through central `gpt-loop` would throw away valid
  project-native transport that already works;
- putting the workflow in every consumer would force runner duplication and
  mechanism drift.

Use the topology the real runner model supports. Keep the mechanism shared.

## Logical project identity vs machine placement

A logical project ID is stable across machines. A machine-local registry maps it
to a local workspace and capability policy.

```text
logical project: native-app

Mac node
  workspace: /path/on/mac/native-app
  capabilities: claude, codex, posix-durable, ...

Windows node
  workspace: D:\path\on\windows\native-app
  capabilities: claude, codex, windows-runtime, ...
```

Requests select a logical project and an allowed action. They must not gain
filesystem authority by supplying an arbitrary absolute path.

## Canonical work vs execution envelope

Two identities must remain separate:

1. **Canonical project work** — the project-owned issue/plan/checkpoint/research
   packet defining why the work exists and what counts as done.
2. **Execution envelope** — one immutable GPT Loop request and its execution
   lifecycle.

A project task may require several envelopes. The envelope is transport evidence,
not the canonical plan.

For a central broker envelope, migrated requests normally carry:

```json
{
  "work_ref": {
    "repository": "owner/consumer-repo",
    "issue_number": 42
  }
}
```

For a project-native adapter, repository provenance may already be supplied by
the event/workflow location. `work_ref` remains available when a more specific
work item materially helps auditability, but decorative self-references are not
required by the ownership model.

`work_ref` is non-authorizing metadata. Workspace authority still comes only from
the trusted machine-local registry.

## Evidence ownership

An executor/control-plane result proves what one immutable packet reported. The
consumer repository owns what that result means for the project.

After consequential execution, reconcile the durable project fact back into the
canonical owner: issue/work item, checkpoint, research gate, evidence artifact,
or another project-defined surface.

Do not turn a broker issue into a standing project log. Do not treat a successful
executor result as automatic advancement of project state when the project has a
separate adjudication or persistence contract.

Historical broker/project-native runs remain historical evidence.

## Concurrency model

"One GPT Loop can address multiple projects" and "multiple projects can execute
in parallel" are different claims.

The target model is resource-based ownership:

- independent projects/workspaces may execute concurrently when their declared
  resources do not conflict;
- a project/workspace execution lease prevents overlapping ownership of the same
  mutable project resource;
- truly machine-global operations take a machine-global lock;
- durable packet ownership survives individual workflow slices.

Examples of machine-global operations include updating the shared GPT Loop
runtime, mutating the machine-local registry, restarting shared daemons, or
rebooting the node.

Until the current machine-wide dispatcher mutex is replaced, GPT Loop is
**multi-project addressable but machine-serialized** on a given node. GitHub
runner queueing and dispatcher resource ownership are separate concerns and must
not be conflated.

## Cross-platform node model

Mac and Windows are executor nodes, not project identities. Scheduling should be
based on trusted node capabilities and project policy rather than hard-coded
project-to-machine coupling.

A future request may therefore need constraints such as:

```text
project = brokered-app
requires = browser, claude
prefers = windows
```

The exact capability schema remains Phase-4 implementation work.

## Documentation authority rules

To prevent split-brain state:

- shared GPT Loop semantics live in `gpt-loop` docs;
- project-specific GPT Loop usage and project state live in the consumer repo;
- a central broker envelope/result lives in `gpt-loop` only as transport/audit;
- a project-native workflow remains project-owned but must invoke shared
  mechanism rather than clone its semantics;
- machine-specific deployment facts live in machine-local state or explicitly
  labeled deployment evidence;
- historical evidence remains historical and is not rewritten merely because
  the operating model changes;
- consumer docs link to shared semantics rather than copying them wholesale;
- GPT Loop consumer-specific docs are case studies/migration notes, never live
  project authority.

## Migration phases

### Phase 1 — semantic/docs refactor ✅

- established mechanism / project / machine ownership;
- separated current implementation truth from target architecture;
- inventoried consumer operating docs;
- preserved historical evidence instead of rewriting it.

### Phase 2 — transport-linked project ownership ← current

- support both project-native adapters and the central broker around one shared
  mechanism;
- add machine-readable `work_ref` for migrated broker envelopes and optional
  project-native use when it materially identifies canonical work;
- add optional machine-local canonical repository binding and fail-closed
  mismatch checking without changing workspace authority;
- split permanent brain protocol invariants from broker-specific instructions;
- update each consumer's live runbook so project work/evidence stays
  project-owned;
- stop using central broker issues as project backlog/checkpoint/coordination
  truth.

### Phase 3 — real multi-project concurrency

- replace unconditional machine-wide serialization with explicit
  project/workspace/resource locks;
- retain machine-global locking for genuinely global mutations;
- prove conflicting and non-conflicting concurrency separately.

### Phase 4 — cross-platform node scheduling

- model Mac/Windows as capability-bearing nodes;
- allow the same logical project to have machine-local placements;
- route only to nodes satisfying trusted project requirements;
- migrate current Mac/Windows special cases and update consumer docs.

## Migration rule for consumer repositories

Do not bulk-rewrite historical evidence. For each consumer repository:

1. identify live operating docs/workflows/checkpoints that define GPT Loop use;
2. classify every rule as shared mechanism, project policy, transport placement,
   machine state, or historical evidence;
3. replace copied shared semantics with contract references;
4. keep project-specific policy, canonical work and project evidence local;
5. for brokered consumers, ensure migrated envelopes point back through
   `work_ref`;
6. for project-native consumers, keep the adapter project-local without cloning
   shared mechanism;
7. migrate runtime behavior only in the phase that implements the corresponding
   mechanism change;
8. update checkpoint/TODO only after runtime change is actually verified.
