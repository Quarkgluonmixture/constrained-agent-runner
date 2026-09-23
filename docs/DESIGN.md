# Design notes

This file collects the reasoning behind the main design choices and the known
gaps. It was distilled from the private working notes of the original
deployment; project names and machine details have been removed.

## Three ownership layers

> **The runner owns the mechanism. Project repositories own the work. Machines own runtime state.**

- The runner (this repository) owns the request/result protocol, the status
  taxonomy, dispatch and executor policy, durable continuation, wake delivery,
  and the security boundary.
- Each consumer project owns its backlog, acceptance criteria and the meaning of
  a result. A GitHub issue used to carry a job is an execution envelope and audit
  record, not project state.
- Each machine owns absolute paths, installed executables, runner identity,
  PIDs, leases and tokens. None of that is ever accepted from a request.

The practical consequence: a request names a **logical project key** and an
**allowlisted action**. The machine-local registry maps the key to a workspace,
a profile and interpreter paths. A request cannot supply a path, a command line,
a model, a sandbox mode or a credential.

## Why the request is immutable

An early incident: an issue was created with body A and edited to body B. The
workflow had already read A, while humans reviewed B. Since then the executable
request is whatever was present at creation, it is hashed into the result
(`request_sha256`), and a durable continuation reloads the persisted request by
UUID instead of re-reading anything from GitHub.

## Why there is no GitHub concurrency group on the execution workflow

GitHub's `concurrency` semantics allow a newer pending run to replace an older
pending run. For CI that is correct; for a job queue it silently drops work. The
execution workflow therefore has no concurrency group, and serialization is a
machine-wide mutex in the dispatcher: a second job waits, and if it cannot get
the lock in time it fails visibly as `environment_error`.

PR test workflows, by contrast, do use `cancel-in-progress`: a stale candidate
commit is intentionally superseded.

## Why interpreters are configured, never guessed

The dispatcher once used `<workspace>/.venv` if it existed and `python` on PATH
otherwise. The project's `.venv` was its runtime environment without test
dependencies, so a missing `pytest` was reported as a quality failure. The
registry now names an interpreter per role; an unset role is an
`environment_error` that names the missing key.

## Why there are many result statuses

`success` / `failure` is not enough for a reasoning agent to act on. The
protocol distinguishes `inapplicable` (the check could not apply, e.g. a
benchmark incompatible with the current corpus), `environment_error` (the
machine, not the project, is broken), `denied`, `invalid_request`,
`quota_wait`, `continuation` and `hard_blocker`, because each implies a
different next step.

## Durable continuation: an executor exiting is not the job finishing

Measured failure: a coding agent exited 0 while a long-running command it had
started was still running. Durable mode (opt-in, POSIX only) changes the
contract:

- a packet UUID owns persistent state across several workflow runs;
- one executor run is a bounded **slice**, not a completion signal;
- long commands run as registered jobs with stable identity, process-group
  ownership, bounded logs and a recorded exit code;
- `continuation` and `quota_wait` are non-terminal and do not notify the
  conversation;
- success requires an explicit terminal declaration, no unresolved jobs, and a
  clean audit showing that no unregistered background process escaped the
  execution (`nohup`, `&`, `disown`, `tmux` and similar are killed and turn the
  packet into `hard_blocker`).

## Wake delivery is consumed only after it is observed

Clicking "send" in a web page does not prove the message arrived. The local
daemon keeps an ordered, restart-safe event queue; the browser extension marks
an event delivered only after it sees the event's marker in the conversation,
and refuses to credit a marker that was already present. Duplicate posts
collapse into one logical event.

## Two ways a project can reach the runner

- **Project-native adapter**: the consumer repository has its own workflow that
  calls the machine-installed runner. Its events and evidence stay in that repo.
- **Central broker**: a consumer without its own runner files jobs in the
  runner's (private) repository. The request may carry a `work_ref` pointing
  back at the canonical work item. `work_ref` is provenance only: it can never
  choose a workspace, and if the registry binds a project to a repository, a
  mismatching `work_ref.repository` fails closed.

Both exist because repository-level self-hosted runners serve one repository,
and reusable workflows cannot borrow a runner that belongs to the called
repository. Forcing everything through one shape would either duplicate runners
or discard a working adapter.

## Known limitations and open work

- **Machine-serialized.** One node runs one job at a time. The target is
  resource-based locking: per-project leases, a separate machine-global lock for
  runtime/registry changes, and named shared resources (browser profile, GPU).
- **No node model yet.** Windows and macOS setups diverge; there is no trusted
  capability declaration for scheduling a project to a suitable node.
- **Large outputs travel through executor stdout.** An executor once silently
  dropped bytes from a long output while the result's own `truncated` flag was
  false (the runner had not truncated anything). Large deliverables should move
  to a controlled artifact surface reported by size and digest.
- **Health fields must name what they measure.** `runner_online` historically
  meant "a local listener process exists", which does not prove GitHub can reach
  the runner.
- **Whole-machine death is not observable from the same machine.** Any external
  dead-man's switch needs a deliberate decision about what data may leave it.
- **Windows test debt.** Dispatcher test T024 asserts a non-Windows detail
  without a platform guard and fails on Windows; the Windows CI script runs the
  dispatcher through the work-ref suite instead.
