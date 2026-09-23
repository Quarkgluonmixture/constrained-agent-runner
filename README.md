# constrained-agent-runner

A control plane that lets a web-based chat agent (the ChatGPT web app, used as
the "brain") send **constrained** jobs to your own machine, using GitHub as the
durable transport and audit log, and get structured results back into the same
conversation.

The interesting part is not the plumbing but the boundary: what a job is
allowed to do, what it can never do, and how every run stays auditable and
recoverable when processes, networks or machines fail.

Internally the project is called **GPT Loop**; that name appears in code,
state directories and headers (`GPTLoop`, `X-GPTLoop-Token`).

> Status: a personal tool, built for and run on the author's own Windows and
> macOS machines. It is published as a code sample, not as a hosted service or
> a supported product.

## How it works

```text
 ChatGPT web conversation (reasoning, no API key)
        │ 1. opens an issue whose body is one immutable JSON request
        ▼
 GitHub issue ──▶ Actions workflow on a self-hosted runner (PRIVATE repo only)
                         │ 2. persist request by UUID, hash it
                         ▼
                 runner/dispatch.ps1  ── machine-local registry (projects.json)
                         │ 3. validate schema, resolve project key → workspace,
                         │    check path allowlist, take the machine mutex
                         ▼
                 allowlisted action: read_file / git_diff / apply_patch /
                 profile test / claude_task / codex_task ...
                         │ 4. bounded, timed, process-tree-killed on timeout
                         ▼
                 result JSON (full copy kept locally, bounded excerpt + hash
                 commented on the issue; issue closed)
                         │ 5. terminal results only
                         ▼
 local wake daemon (127.0.0.1, token) ──▶ browser extension posts a wake
 message into the conversation and confirms it actually appeared
```

- **Brain**: the chat agent plans and writes requests. It never gets a shell.
- **Transport**: GitHub issues and Actions give a durable, owner-authenticated
  queue and a permanent audit trail without opening any inbound port.
- **Executor**: a PowerShell dispatcher on your machine, plus optional
  Claude Code / Codex CLI executors run under locally fixed policy.
- **Wake**: a loopback-only daemon and a Chrome extension tell the conversation
  when a job reaches a terminal state.

## Capability boundary

What a request **can** do:

- name a registered **project key** and one **allowlisted action**;
- read files, show `git status` / `git diff`, make exact text replacements or
  apply a unified diff, all inside paths the project's profile allows;
- run project-defined profile actions (e.g. a test command) whose command line,
  interpreter and exit-code meaning are declared locally;
- where a project opts in, run a bounded Claude Code or Codex CLI task inside
  that project's workspace, with model, sandbox and permission mode taken from
  local configuration.

What a request **can never** do:

- supply a filesystem path outside the registered workspace, an absolute path,
  a UNC path, traversal, or a symlink/junction that resolves outside it;
- touch `.git`, `.github`, `.env`, `secrets` or `node_modules` in any project,
  so a job cannot rewrite the workflow that grants it execution;
- run an arbitrary shell command (there is no shell action);
- choose the workspace, executable, interpreter, model, sandbox level,
  approval policy or credential (`work_ref` provenance is checked, never
  trusted for placement);
- bypass executor safety flags (`--dangerously-skip-permissions` and Codex's
  approval/sandbox bypass are unreachable);
- run without a timeout, or leave detached background processes behind in
  durable mode (they are audited and killed).

Full trust model: [`docs/SECURITY.md`](docs/SECURITY.md).

## Audit and recovery

- **Immutable requests.** The executable request is the issue body at creation
  time; its SHA-256 is echoed in the result. Later continuations reload the
  locally persisted request by UUID and never re-read GitHub.
- **Nothing silently dropped.** The execution workflow has no GitHub
  concurrency group (which could replace a pending run); jobs wait on a machine
  mutex and fail visibly if they cannot get it.
- **Results survive the run.** Full results are stored locally and can be
  fetched later by a separate job (`read_result`).
- **Specific statuses.** `success`, `failure`, `inapplicable`,
  `environment_error`, `denied`, `timeout`, `invalid_request`, `quota_wait`,
  `continuation` and `hard_blocker` each tell the brain what to do next.
- **Durable continuation (POSIX, opt-in).** Long work spans several workflow
  runs under one packet UUID. An executor exiting ends a slice, not the job;
  success needs an explicit terminal declaration plus a clean process audit.
- **Wake confirmed on delivery.** An event counts as delivered only once its
  marker is seen in the conversation; unconfirmed events are retried, in order.

Why these choices were made, and what is still missing:
[`docs/DESIGN.md`](docs/DESIGN.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `protocol/` | JSON schemas for job, result and wake events |
| `runner/` | dispatcher, path safety, registry, actions, executors, durable job worker |
| `runner/profiles/` | example project profiles (allowlists, profile actions) |
| `wake/` | loopback wake daemon (Python stdlib) and Chrome extension |
| `scripts/` | install, runner registration, daemon, doctor, registry helper |
| `tests/` | PowerShell and Python regression suites |
| `examples/python-project/` | small fixture project used by the tests |
| `deploy/private-fork/` | the self-hosted execution workflow, as an **inactive** template |
| `docs/` | architecture, security, design notes, troubleshooting, setup |

## Running the tests

Requirements: PowerShell 7 (`pwsh`), Python 3.9+, Git. The browser test also
needs Playwright (`pip install playwright && python -m playwright install chromium`)
and is skipped without it.

The dispatcher suites need a small fixture environment:

```powershell
cd examples/python-project
python -m venv .venv
.venv/Scripts/python -m pip install pytest      # macOS/Linux: .venv/bin/python
cd ../..
```

Then either run everything:

```powershell
pwsh -File tests/Run-AllTests.ps1
```

or the Windows-meaningful subset used by CI:

```powershell
pwsh -File tests/Run-WindowsControlPlaneCi.ps1
```

The durable-worker suite relies on POSIX process groups and fails closed on
Windows by design; run it on Linux or macOS:

```sh
python3 tests/durable/test_durable_job.py
```

CI (`.github/workflows/control-plane-tests.yml`) runs on GitHub-hosted
`windows-latest` and `ubuntu-latest` runners only.

## Deploying it for yourself

> **Only ever connect a self-hosted runner to a PRIVATE repository.** In a
> public repository anyone can open a pull request, and a workflow running on
> your self-hosted runner would execute their code on your machine. This public
> repository deliberately contains no active `self-hosted` workflow, and a
> static test fails if one is added.

1. Create a **private** copy of this repository.
2. Copy `deploy/private-fork/loop-runner.yml` to `.github/workflows/` in the
   private copy. It only runs for issues opened by the repository owner with a
   `[GPT-LOOP]` title.
3. On your machine: `pwsh -File scripts/install-windows.ps1` (or
   `install-macos.ps1`) creates the machine-local state root with a fresh
   random wake token, the project registry, and an example project.
4. `pwsh -File scripts/register-runner.ps1 -Repo <you>/<private-copy>`
   registers a dedicated runner; it needs an authenticated `gh` CLI and fetches
   a short-lived registration token.
5. `pwsh -File scripts/start-daemon.ps1 -Register` starts the wake daemon.
6. `pwsh -File scripts/stage-extension.ps1 -TargetUrl https://chatgpt.com/c/<conversation-id>`
   and load the extension from `chrome://extensions`.
7. `pwsh -File scripts/doctor.ps1` checks the installation.

What you need to provide, none of which is stored in this repository:

| Item | Where it lives |
| --- | --- |
| Wake token | generated by the installer into the local state root (`token.txt`, user-only ACL) |
| Wake daemon port | local config; defaults to `127.0.0.1:8777`, loopback only |
| Project registry | `projects.json` in the local state root: project keys, absolute workspace paths, interpreters, executor policy |
| Target conversation URL | local extension config (`config.local.json`, git-ignored) |
| GitHub auth | your own `gh` login; the runner registration token is short-lived |
| Claude Code / Codex CLI | optional; their own existing logins on the machine. No API keys are read or stored |

The local state root is `%LOCALAPPDATA%\GPTLoop` on Windows and
`~/Library/Application Support/GPTLoop` on macOS (overridable with
`GPTLOOP_STATE_ROOT`). Detailed Windows walkthrough:
[`docs/WINDOWS_SETUP.md`](docs/WINDOWS_SETUP.md).

## Documentation

- [`docs/DESIGN.md`](docs/DESIGN.md): design rationale and known limitations.
- [`docs/SECURITY.md`](docs/SECURITY.md): trust boundaries and what is not defended.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components and state machines.
- [`docs/DURABLE_CONTINUATION.md`](docs/DURABLE_CONTINUATION.md): long-running packet and process ownership.
- [`docs/OPERATING_MODEL.md`](docs/OPERATING_MODEL.md), [`docs/BROKER_TRANSPORT.md`](docs/BROKER_TRANSPORT.md): ownership model and transport topologies.
- [`docs/CHATGPT_BRAIN_PROTOCOL.md`](docs/CHATGPT_BRAIN_PROTOCOL.md), [`docs/CHATGPT_BOOTSTRAP_PROMPT.md`](docs/CHATGPT_BOOTSTRAP_PROMPT.md): instructions given to the chat agent.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md): failures that actually happened, with their regression tests.
- [`docs/WINDOWS_SETUP.md`](docs/WINDOWS_SETUP.md): Windows node setup.

## License

MIT. See [`LICENSE`](LICENSE).
