# Windows setup — central broker node

This guide installs the current **central `gpt-loop` broker** on a Windows user
account.

It is not a requirement that every consumer repository register its own runner
or use the central broker. GPT Loop supports two ingress topologies:

- **central broker** — consumer work stays in its repository; short-lived
  execution envelopes live in `gpt-loop` and point back with `work_ref`;
- **project-native adapter** — a consumer repository already owns a suitable
  runner/workflow and invokes the machine-installed shared GPT Loop runtime
  directly.

This document covers the first topology.

Canonical ownership:

> **GPT Loop owns the mechanism. Project repositories own the work. Machines own runtime state.**

See [`BROKER_TRANSPORT.md`](BROKER_TRANSPORT.md) before duplicating runner setup
into another repository.

## Prerequisites

| Requirement | Check |
| --- | --- |
| PowerShell 7+ | `pwsh -v` |
| Git | `git --version` |
| GitHub CLI, authenticated | `gh auth status` (needs the scopes required by your repo/workflow operations) |
| Python 3.9+ | `python --version` — daemon/tests use Python; core wake daemon is stdlib-only |
| Google Chrome 132+ | browser/extension deployment |
| A ChatGPT Web account you are logged into | wake target where used |

Claude Code and Codex CLI are optional and needed only for projects whose local
registry enables the corresponding executor actions.

## 1. Clone the shared control plane

```powershell
# Use your PRIVATE copy of this repository (see step 3).
git clone https://github.com/<you>/<your-private-copy>.git
cd <your-private-copy>
```

The GPT Loop checkout is shared mechanism code. Consumer project checkouts remain
separate workspaces.

## 2. Install the machine-local state root

```powershell
pwsh -File scripts\install-windows.ps1
```

Creates `%LOCALAPPDATA%\GPTLoop\` with machine-local state such as:

- wake token/config;
- project registry;
- results/execution state;
- local logs;
- bundled example fixture environment.

The machine-local registry is the authority for absolute workspace/interpreter
placement. Do not commit it into a consumer repository.

The installer is idempotent and does not overwrite an existing token/registry
unless explicitly forced.

## 3. Register the central broker runner

```powershell
pwsh -File scripts\register-runner.ps1 -Repo <owner>/<your-private-copy>
```

> **Security: only ever attach a self-hosted runner to a PRIVATE repository.**
> In a public repository anyone can open a pull request, and a workflow that
> runs on your self-hosted runner would execute their code on your machine.
> The public repository therefore ships no active `self-hosted` workflow; copy
> `deploy/private-fork/loop-runner.yml` into `.github/workflows/` of your private
> copy only.

This runner is intentionally repository-scoped to the **broker repository**. It
uses labels such as:

```text
self-hosted, windows, x64, gpt-loop
```

Important runner topology rule:

> Do not register a second equivalent runner in every consumer repository merely
> to make their YAML look project-native.

A repository-level self-hosted runner is scoped to its repository. Consumers
without their own legitimate project-native adapter use this broker instead.
If a future organization-level runner pool is introduced, transport placement
may change without changing the ownership model.

If this machine already hosts a different repository's runner, leave it alone;
separate runner processes may coexist when intentionally configured.

## 4. Start wake daemon / broker supervision

```powershell
pwsh -File scripts\start-daemon.ps1 -Register
```

The daemon binds loopback, manages wake delivery state, and in the current
Windows broker deployment supervises its configured runner. The logon task runs
in the user session rather than as an admin service because Chrome/session
interaction is user-scoped.

## 5. Stage the ChatGPT wake extension

```powershell
pwsh -File scripts\stage-extension.ps1 -TargetUrl "https://chatgpt.com/c/<conversation-id>"
```

This copies the extension to machine-local GPT Loop state and writes local
configuration containing the daemon token/target conversation. Private runtime
configuration stays outside git.

## 6. Load the extension once

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked**.
4. Select:

```text
C:\Users\<you>\AppData\Local\GPTLoop\extension
```

After extension-source updates, restage it and reload the extension card.

## 7. Verify the Windows broker node

First inspect machine health:

```powershell
pwsh -File scripts\doctor.ps1
```

Then run the **platform-honest Windows control-plane gate**:

```powershell
$python = (Get-Command python -ErrorAction Stop).Source
pwsh -File tests\Run-WindowsControlPlaneCi.ps1 -PythonExe $python -ContentScriptPython $python
```

Why not `tests\Run-AllTests.ps1` here?

The full repository suite contains POSIX-only durable-worker process-group tests.
The durable implementation intentionally fails closed on Windows until equivalent
process provenance exists. Running that POSIX worker suite as a Windows install
gate would manufacture expected failures and teach the operator to ignore red.

The Windows gate still verifies:

- request/result schema JSON;
- broker/work-ref dispatcher path end-to-end;
- safe machine-local repository-binding migration behavior;
- safe minimal provisioning of existing Git workspaces;
- durable static cross-file invariants;
- wake daemon semantics;
- extension/daemon protocol;
- content-script delivery behavior where its test dependency is available.

The repository's broader legacy dispatcher suite also contains known
cross-platform test-harness debt (T024) that is tracked separately; do not turn a
known assertion bug into a product diagnosis.

## 8. Register and bind real consumer projects

The machine-local file remains:

```text
%LOCALAPPDATA%\GPTLoop\projects.json
```

There are two different operations here and they should not be conflated.

### 8.1 Provision a new logical project

If the consumer checkout already exists on this machine but has **no logical
project key** yet, use the helper rather than hand-editing `projects.json`:

```powershell
pwsh -File scripts\project-registry.ps1 `
  -ProjectKey myproject `
  -ProvisionWorkspace C:\Users\you\code\myproject `
  -BindRepository owner/myproject
```

Provisioning is deliberately a **minimal identity + placement grant**, not an
executor setup shortcut. Before writing anything the helper requires:

- the logical key does not already exist;
- the workspace directory already exists;
- the workspace is a Git repository with an `origin` remote;
- that origin resolves to the exact requested canonical GitHub `owner/repo`;
- the shared `generic` profile exists.

The initial entry is equivalent to:

```json
{
  "workspace": "C:\\Users\\you\\code\\myproject",
  "repository": "owner/myproject",
  "require_work_ref": false,
  "profile": "generic",
  "allowed_roots": [],
  "allowed_files": []
}
```

It does **not** infer Python environments, enable Claude/Codex, grant file
surfaces, or install dependencies. Those are separate trusted capability
decisions. Core project-agnostic actions such as `ping` and `git_status` remain
available through the dispatcher, which is enough to prove placement and
provenance before granting anything broader.

Like provenance binding, provisioning is backup-first, atomically replaces the
registry, verifies a full JSON round trip, and restores the backup if verification
fails.

After provisioning, inspect the sanitized registry view:

```powershell
pwsh -File scripts\project-registry.ps1 -List
```

### 8.2 Migrate an existing registered project to repository provenance

For an existing logical project, **do not hand-edit the Phase-2 provenance fields
just to add repository binding**. Inspect the real machine first:

```powershell
pwsh -File scripts\project-registry.ps1 -List
```

The listing is deliberately bounded to project key, repository binding,
`require_work_ref`, profile, workspace and whether that workspace currently
exists. It does not dump arbitrary executor configuration.

Bind the already-registered project to its canonical repository:

```powershell
pwsh -File scripts\project-registry.ps1 `
  -ProjectKey myproject `
  -BindRepository owner/myproject
```

The helper:

- resolves the project through the normal trusted workspace/profile path first;
- refuses stale/missing workspaces;
- accepts the same binding idempotently;
- refuses to silently rebind a project to a different repository;
- creates a timestamped `projects.json.bak-*` before mutation;
- replaces the registry atomically and round-trip verifies the complete content;
- restores the backup automatically if write/verification fails;
- does not change workspace/profile/executor policy;
- leaves `require_work_ref` unchanged.

Re-list after binding:

```powershell
pwsh -File scripts\project-registry.ps1 -List
```

### What `repository` means

`repository` is a trusted machine-local canonical identity used to validate a
supplied `work_ref.repository`.

It does **not** choose the workspace. `workspace` remains the machine-local
placement authority.

### What `require_work_ref` means

This is an opt-in **central-broker transport gate**, not a universal project
setting.

Use this sequence for a central-broker consumer:

1. deploy GPT Loop code that understands `work_ref`;
2. provision or bind `repository` while leaving `require_work_ref: false`;
3. send/verify real broker envelopes containing the correct `work_ref`;
4. verify any continuation/retry ingress also preserves the immutable request;
5. only then, if desired, enable enforcement explicitly:

```powershell
pwsh -File scripts\project-registry.ps1 `
  -ProjectKey myproject `
  -SetWorkRefRequirement enabled `
  -ConfirmIngressProven
```

The proof flag is intentionally required by the helper. Do not use it as a
ceremonial switch: it means a real broker packet with `work_ref` has already been
verified end-to-end for that project.

If rollback of enforcement is needed, disabling does not require that proof flag:

```powershell
pwsh -File scripts\project-registry.ps1 `
  -ProjectKey myproject `
  -SetWorkRefRequirement disabled
```

For a project-native adapter, repository context may already provide provenance;
`require_work_ref` can remain false unless that project's adapter contract
explicitly requires every packet to carry one.

No daemon restart is required for normal registry changes; the registry is
resolved per execution.

## 9. First central-broker job

For the bundled example, a transport smoke can omit `work_ref` because it is not
consumer project work:

```powershell
$job = [guid]::NewGuid().ToString()
$body = @{
  protocol_version = 1
  job_id = $job
  project = 'example-python'
  action = 'ping'
} | ConvertTo-Json
Set-Content -LiteralPath .\job.json -Value $body -Encoding utf8NoBOM
gh issue create --repo <owner>/gpt-loop --title "[GPT-LOOP] first broker smoke" --body-file .\job.json
Remove-Item .\job.json
```

For real migrated consumer work, create/identify the **consumer-owned canonical
work first** and add `work_ref`, for example:

```json
{
  "protocol_version": 1,
  "job_id": "<fresh UUID>",
  "project": "myproject",
  "work_ref": {
    "repository": "owner/myproject",
    "issue_number": 42
  },
  "action": "git_status"
}
```

The broker issue is transport/audit only. Reconcile meaningful results back into
the consumer project's issue/checkpoint/evidence.

## 10. Bootstrap the conversation correctly

Use [`CHATGPT_BOOTSTRAP_PROMPT.md`](CHATGPT_BOOTSTRAP_PROMPT.md) and declare:

```text
Consumer repository: owner/myproject
Logical project key: myproject
Transport: central-broker
Broker repository: owner/gpt-loop
```

Do not bootstrap the conversation as if the broker repository owned the consumer
project.

## Uninstall

```powershell
pwsh -File scripts\uninstall-windows.ps1
```

This removes/stops GPT Loop machine runtime according to the script's options. It
must not delete consumer project workspaces.
