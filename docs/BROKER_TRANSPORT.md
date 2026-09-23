# GPT Loop transport topology contract

## Decision

GPT Loop has **one shared execution mechanism**, but it may be reached through
more than one GitHub transport topology.

The ownership rule is independent of transport placement:

> **GPT Loop owns the mechanism. Project repositories own the work. Machines own runtime state.**

Two ingress topologies are valid under the current personal-account setup.

### A. Project-native adapter

A consumer repository may already own a repository-scoped runner/workflow that
invokes the machine-installed shared GPT Loop runtime.

```text
consumer repo                         machine
-------------                         -------
issue/pointer/project event ────────▶ repo-local adapter
project policy                        shared GPT Loop runtime
project evidence ◀── reconcile ───── result / round evidence
                                            │
                                            ▼
                                        registry
                                        workspace
```

In the reference deployment, `native-app` works this way. The GitHub event, round log and project evidence
already live in the canonical project repository. It does **not** need to create
a second central broker envelope merely to point back to itself.

A project-native adapter is still an adapter, not a fork of GPT Loop. Shared
request/result, dispatcher, durable ownership, status, wake and future resource
semantics remain owned by `gpt-loop`.

### B. Central broker envelope

A consumer without a repository-local runner/adapter may use the repository-
scoped runner attached to `gpt-loop`.

```text
consumer repo                         gpt-loop repo                    machine
------------                         -------------                    -------
issue/plan/checkpoint  ── work_ref ─▶ execution envelope ───────────▶ registry
project policy                         request hash                     workspace
project evidence ◀── reconcile ────── result + wake ◀──────────────── executor
```

In the reference deployment, `brokered-app` consumers fit this topology.
The central broker issue is an immutable execution envelope. It is **not** the
project backlog, checkpoint, coordination issue, or durable project truth.

## Why there is no single mandatory GitHub topology

The reference deployment lives under a personal (non-organization) GitHub
account. GitHub runner
scope matters:

- a repository-level self-hosted runner is dedicated to one repository;
- an organization-level runner can serve multiple repositories in that
  organization;
- a reusable workflow called from another repository uses self-hosted runners
  available to the **caller** repository/context, not a repository-level runner
  that only belongs to the called workflow repository.

Therefore neither extreme is correct:

- forcing every project through the central broker would discard a working
  project-native topology;
- copying the shared workflow/runner into every consumer would create per-repo
  runner duplication and mechanism drift.

Transport placement follows the real runner topology. Mechanism ownership stays
shared.

GitHub references used for this decision:

- https://docs.github.com/en/actions/concepts/runners/self-hosted-runners
- https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations

## Three identities that must never collapse

### 1. Canonical project work

Lives in the consumer repository and defines why work exists and what counts as
done. It may be a project issue, checkpoint/phase entry, plan item, research
packet, or another explicit project-owned authority.

### 2. Execution envelope

One immutable GPT Loop request and its lifecycle. Its GitHub placement depends on
the ingress topology:

- project-native adapter: the request/event may already be owned by the consumer
  repository;
- central broker: the envelope lives in `gpt-loop` and must point back to the
  consumer through `work_ref` after migration.

An execution envelope is transport evidence, not the canonical project plan.

### 3. Machine execution

Lives under machine-local GPT Loop state and the registered project workspace:

- workspace placement;
- executor/interpreter policy;
- process identity;
- locks/leases;
- durable jobs/logs/results;
- local wake queue.

## `work_ref`

Protocol v1 gains an optional, non-authorizing project-work reference:

```json
{
  "work_ref": {
    "repository": "example-owner/brokered-app",
    "issue_number": 12,
    "path": "CHECKPOINT.md"
  }
}
```

`repository` identifies the canonical project owner. `issue_number` and `path`
are optional locators and should be included only when they are actually the
canonical work surface. False precision is worse than omission.

`work_ref` does **not** select a workspace, runner, executor, model or credential.
`project` still resolves only through trusted machine-local registry policy.

### Where `work_ref` is expected

For a migrated **central broker** envelope, `work_ref.repository` should normally
be present because the envelope lives outside the canonical consumer repository.

For a **project-native adapter**, repository provenance is already supplied by
the event/workflow location. A project may still include `work_ref` when a
specific issue/control item materially improves auditability, but Phase 2 does
not require decorative self-references on every project-native packet.

Machine-local `require_work_ref` therefore remains an **opt-in transport policy**,
not a universal definition of a migrated project.

## Registry binding

A machine-local project entry may declare its canonical repository:

```json
{
  "repository": "example-owner/brokered-app",
  "require_work_ref": false
}
```

The binding never places the workspace. It provides a trusted identity against
which a supplied `work_ref.repository` can be checked fail-closed.

Migration order:

1. deploy shared support;
2. add canonical `repository` binding;
3. verify every relevant ingress;
4. enable `require_work_ref` only for a topology whose valid ingress is proven to
   always send the reference.

Do not enable enforcement first.

## Central broker issue rules

When the broker topology is used, an envelope must:

- start with `[GPT-LOOP]` under the current issue-triggered workflow;
- contain the complete immutable request at creation;
- name exactly one registered logical project;
- point back to canonical work through `work_ref` for migrated broker consumers;
- carry no unrelated project coordination notes after creation;
- be closed at terminal result;
- never be a standing round log, project TODO, checkpoint, or cross-session human
  coordination board.

Standing project coordination belongs in the consumer repo. Shared GPT Loop
product coordination belongs in normal `gpt-loop` product issues.

## Project-native adapter rules

A project-native adapter must:

- keep project event/round semantics in the consumer repository;
- invoke the shared GPT Loop runtime rather than copying/reimplementing its
  dispatcher semantics;
- preserve immutable/same-packet semantics required by the shared protocol;
- keep project-specific state/retry/evidence policy local only when it genuinely
  belongs to that project;
- avoid turning machine-local paths/PIDs/leases into repository authority.

Project-native does **not** mean every project should copy one consumer's workflow.
It means transport may live with the project when a real runner/adapter topology
already supports that placement.

## Evidence reconciliation

An execution result proves what one packet reported. The consumer repository owns
what that evidence means for project state.

After consequential execution, reconcile the durable project fact into its
canonical owner — issue/work item, checkpoint, project evidence, research gate,
or another project-defined surface. Do not copy every stdout line, and do not
leave the only meaningful state transition inside a broker issue.

## Phase-2 acceptance

Phase 2 is complete when:

- both valid ingress topologies are explicit in shared docs;
- broker envelopes can carry validated non-authorizing `work_ref`;
- registry repository binding can fail closed on a mismatch without changing
  workspace authority;
- brain/bootstrap guidance distinguishes canonical project work from transport;
- project-native consumers keep their adapter without redefining shared mechanism;
- brokered consumers use broker-linked ownership without duplicate runners;
- central broker issues no longer serve as project backlog/checkpoint/coordination
  truth;
- historical evidence is preserved rather than rewritten to fit the new model.
