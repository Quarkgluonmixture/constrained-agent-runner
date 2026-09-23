# ChatGPT brain protocol

This is the shared contract for the **reasoning side** of GPT Loop.

It deliberately separates two things that the original deployment mixed:

1. permanent reasoning/control-plane invariants; and
2. transport-specific instructions for reaching the shared runtime.

A project-native adapter and the central `gpt-loop` broker may use different
GitHub events, but both still obey the same safety/status/execution semantics.

Canonical ownership:

> **GPT Loop owns the mechanism. Project repositories own the work. Machines own runtime state.**

Before using this protocol, know:

- the **consumer repository** whose work you are doing;
- the logical `project` key registered on the target machine;
- the consumer's canonical work/checkpoint/runbook;
- the ingress topology: **project-native adapter** or **central broker**.

For transport placement see [`BROKER_TRANSPORT.md`](BROKER_TRANSPORT.md). For a
paste-ready conversation bootstrap see
[`CHATGPT_BOOTSTRAP_PROMPT.md`](CHATGPT_BOOTSTRAP_PROMPT.md).

---

## Invariant 0 — canonical project work comes before transport

GPT Loop is not the project backlog.

Before a consequential execution, identify the canonical consumer-owned work
surface: an existing project issue, checkpoint/phase entry, research packet,
TODO item, or another explicit project authority.

Do **not** create a new project issue merely because GPT Loop needs something to
point at. If the project already has a canonical checkpoint/packet, use it.

For a migrated central-broker execution, the immutable envelope points back to
that owner with `work_ref`. For a project-native adapter, the repository event or
project runbook may already provide repository provenance.

After execution, reconcile any meaningful state transition back into the
consumer repository. A broker issue/result may prove execution; it does not by
itself become project state.

---

## Invariant 1 — do not dispatch what you can already resolve

Dispatch only when the execution machine is actually required: real current
workspace state, actual execution, environment-dependent verification, or local
result retrieval.

Do not use GPT Loop as a slow remote filesystem browser when the required fact is
already in the conversation or canonical repository context available to the
brain.

Prefer the smallest targeted execution that answers the unresolved question.
Do not dispatch speculative surveys merely to feel safer.

Project-native autonomous protocols may authorize a repo-selected implementation
round. In that case follow the project's bounded-slice rules rather than applying
this paragraph as an excuse to stop at a plan.

---

## Invariant 2 — the executable packet identity is immutable

Once an execution packet has been accepted, its identity/content must not be
silently replaced.

The exact binding depends on ingress:

### Central broker

The stock broker consumes the body from `issues.opened`. Therefore the complete
request must be present **at issue creation**. Never create a placeholder issue
and edit its body afterward.

Every broker result carries `request_sha256`. If humans are reading body B while
the runner reports the hash of body A, treat that as an audit mismatch, not as a
successful replacement.

### Project-native adapter

Use the consumer's own immutable binding. A project may bind execution to an
issue body, commit SHA, persisted packet UUID, pointer commit, or another
repo-defined mechanism. Do not invent a central issue just to mimic the broker.

### Durable continuation

A continuation re-enters the **same persisted UUID/request**. It does not rebuild
a packet from a moving pointer or a fresh prompt.

---

## Invariant 3 — read the structured status, not just `ok`

`ok` is only a convenience mirror of `status == "success"`.

| status | Meaning | Brain action |
| --- | --- | --- |
| `success` | action/packet reached its success criteria | reconcile the evidence and continue |
| `failure` | action genuinely ran and failed | diagnose project/execution result |
| `hard_blocker` | durable packet ended at an explicit terminal blocker | surface the blocker; do not pretend partial progress is success |
| `continuation` | one durable slice ended; packet is still alive | do not adjudicate/close/wake as terminal |
| `quota_wait` | executor usage window is closed | retry/re-enter the same packet after reset; not a verdict |
| `inapplicable` | requested measurement could not meaningfully apply | fix the premise/fixture; not a regression |
| `environment_error` | interpreter/tool/runtime/config unavailable | fix environment; not a project-quality failure |
| `denied` | trusted policy rejected the request | re-scope; never route around the boundary |
| `timeout` | bounded action exceeded its limit | inspect partial evidence/ownership before retrying |
| `invalid_request` | malformed/unsupported request | fix the envelope; do not blame the project |

Two historical mistakes motivated these distinctions:

- corpus incompatibility was once reported as a quality regression;
- a missing test dependency was once reported as a project failure.

Do not collapse different control states back into pass/fail prose.

---

## Invariant 4 — executor/slice exit is not automatically packet completion

For legacy bounded actions, action completion may be terminal.

For durable execution:

> **executor slice ended ≠ packet completed**

`continuation` and `quota_wait` are nonterminal. Terminal success requires the
shared durable contract's explicit closure/finalization rules. Never report a
clean Claude exit as packet success while owned durable work is still alive.

See [`DURABLE_CONTINUATION.md`](DURABLE_CONTINUATION.md).

---

## Invariant 5 — a wake is notification, not the result

A wake tells the conversation that a terminal event needs attention. It is not a
replacement for the structured result/evidence.

Use the ingress-specific result locator:

- central broker: normally the broker issue named by the wake;
- project-native adapter: the consumer runbook may use a project issue, round log,
  commit status, evidence issue, or another explicit result channel.

Read the actual result before deciding what happened.

If a result is truncated, retrieve the stored local result through the shared
`read_result` action using a **new envelope job UUID** and the old
`full_result_id` as `params.job_id`.

Do not treat `continuation` or `quota_wait` as terminal wake-worthy verdicts.

---

## Invariant 6 — repository provenance never grants filesystem authority

`project` is a logical key in the machine-local registry. It never means an
absolute path supplied by the conversation.

`work_ref` is project-work provenance. It also never means a path authority.

The security order is intentionally:

```text
untrusted request project key
    -> trusted machine registry selects workspace/profile
    -> optional work_ref is checked as provenance
    -> action executes inside allowlisted workspace surface
```

A request cannot choose its own workspace, interpreter, model, credential, or
runner by adding fields.

Paths inside action `params` are repository/workspace-relative and remain subject
to the shared safe-path policy. `.git`, `.github`, `.env`, secrets and traversal
surfaces remain denied where the dispatcher policy says so.

---

## Current scheduling discipline — not a permanent concurrency law

The current dispatcher still has a machine-wide mutex. Therefore a given node is
**multi-project addressable but machine-serialized** today.

Until Phase 3 replaces that with explicit resource ownership:

- do not burst independent substantive packets expecting parallel speedup on one
  node;
- diagnose/reconcile one wake before spawning a chain of reactive retries;
- do not use GitHub Actions execution `concurrency` groups as the queue because a
  newer pending execution may replace an older one.

This section is current implementation guidance, **not a timeless brain
invariant**. Phase 3 is expected to change it.

---

# Central broker adapter

Use this section only when the consumer is using the central `gpt-loop` broker.
Do not apply it to a project-native adapter merely because both use GPT Loop.

## Canonical work first

The consumer repository owns the task/checkpoint/evidence. The broker issue owns
only one immutable execution envelope.

For a migrated broker consumer, include:

```json
"work_ref": {
  "repository": "owner/consumer-repo"
}
```

Add `issue_number` only when a specific project issue is genuinely canonical.
Add `path` only when one exact repository-relative control document genuinely
owns the requested work. Do not manufacture false precision.

## Broker issue format

Title starts with `[GPT-LOOP]`. The body is the complete request JSON at creation
time:

```json
{
  "protocol_version": 1,
  "job_id": "3f2b9c1e-6a4d-4f8b-9c2a-1d5e7f0a3b6c",
  "project": "example-python",
  "work_ref": {
    "repository": "example/example-python",
    "issue_number": 42
  },
  "action": "test",
  "parent_event_id": "31442889834:1:1"
}
```

`job_id` must be fresh for a new packet. `parent_event_id` records the wake/event
that led to this packet when applicable.

The broker issue may receive result comments and close at terminal. Do not append
project planning, coordination, or checkpoint prose to it afterward.

## Broker-only issue-number anomaly check

If a brain is directly creating sequential broker issues and the next issue
number unexpectedly skips, inspect recent **broker-repo** issues before assuming
your intended packet owns that number. A duplicate/race/human/shared-product
issue may have consumed it.

This is a central-broker diagnostic, not a global GPT Loop invariant and not a
rule for consumer project issue numbering.

---

# Project-native adapter

A project-native consumer supplies its own ingress/runbook while invoking the
shared machine-installed GPT Loop mechanism.

Rules:

1. Read the consumer's repo-local GPT Loop/runbook contract first.
2. Keep canonical task/state/evidence in that consumer repository.
3. Do not create a central broker issue unless the project explicitly routes that
   operation through the broker.
4. Preserve the shared immutable packet/status/workspace/durable safety rules.
5. Keep project-specific pointer/retry/device/research semantics local; do not
   copy them into GPT Loop core merely because they exist in one consumer.

In the reference deployment, one consumer (`native-app`) uses this topology.

---

## Core actions

| Action | Params | Notes |
| --- | --- | --- |
| `ping` | — | liveness/environment echo |
| `git_status` | — | current registered workspace state |
| `git_diff` | — | uncommitted diff |
| `read_file` | `path`, `max_bytes?` | allowlisted relative paths only |
| `read_result` | `job_id`, `offset?`, `length?` | retrieve stored full result |
| `replace_text` | `path`, `old`, `new`, `expected_count?`, `newline_mode?` | fails closed on count mismatch |
| `apply_patch` | `patch` | real unified diff only |
| `claude_task` | `prompt`, `permission_mode?`, `tier?` | only if locally enabled |
| `codex_task` | `prompt`, `tier?` | independently enabled; request cannot invent model authority |

Anything else must be declared by the registered project profile.

### `replace_text`

`expected_count` defaults to 1. A mismatch writes nothing. `newline_mode: auto`
adapts LF-authored payload text to the existing file convention without
normalizing the file itself.

### `apply_patch`

Only real unified diff syntax is accepted:

```diff
--- a/src/thing.py
+++ b/src/thing.py
@@ -1,3 +1,3 @@
 unchanged
-old line
+new line
 unchanged
```

The `*** Begin Patch` dialect is not the shared action format.

---

## Reconcile after execution

After reading the structured result:

1. decide what it proves and what it does **not** prove;
2. update the consumer's canonical checkpoint/TODO/evidence only when project
   truth changed;
3. keep broker/run/job identifiers as audit links where useful, not as a second
   project ledger;
4. keep machine-local PIDs, leases, absolute paths and credentials out of project
   truth except sanitized incident evidence;
5. only then decide whether another bounded execution is warranted.

## When something looks wrong

- unexpected result → compare immutable request identity/hash and the actual
  transport event before blaming the dispatcher;
- repeated `denied` → change the approach, not the boundary;
- no wake → inspect the ingress's real result channel first, then wake delivery;
- truncated result → use `read_result`, not a guessed summary;
- project state and execution result disagree → reconcile in the **project owner**,
  never by editing transport history to make them match.
