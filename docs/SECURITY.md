# Security model

gpt-loop lets text written by a language model cause code to execute on a
personal machine. The whole design follows from taking that seriously.

## Deployment precondition: private repository only

The execution workflow runs on a **self-hosted** runner on your own machine. It
must only ever be installed in a **private** repository. In a public repository
anyone can open a pull request, and a workflow that runs on a self-hosted runner
would execute their code on your machine; the owner check below narrows who can
trigger a job but is defence in depth, not a substitute.

For that reason this public repository ships the runner workflow only as an
inactive template (`deploy/private-fork/loop-runner.yml`), its only active
workflow runs on GitHub-hosted runners, and a static test fails if any file in
`.github/workflows/` targets `self-hosted`.

## Trust boundaries

### Trusted

| Party | Why |
| --- | --- |
| The repository owner | Only their issues trigger execution (`issue.user.login == repository_owner`) |
| The local Windows user | Owns the state root, the token, and the registry |
| The local gpt-loop installation | `runner\`, `wake\`, and `scripts\` are control-plane code |
| `%LOCALAPPDATA%\GPTLoop\projects.json` | The registry defines what may be touched |

### Untrusted, always validated

| Input | Treatment |
| --- | --- |
| The GitHub issue body | Schema-validated; unknown versions/actions rejected |
| Model-generated action arguments | Type- and range-checked; paths resolved through the allowlist |
| Target project file contents | Read with size limits; never evaluated |
| Child-process stdout/stderr | Captured, bounded, never interpreted as control data |
| Anything the extension receives from the page | Only used to decide verified/not-verified |

## Enforced constraints

**Execution**

* Owner-only trigger, checked in the workflow `if:` condition (in the private
  deployment's `loop-runner.yml`).
* Every request is schema-validated before anything runs; unknown
  `protocol_version` or `action` fails as `invalid_request`.
* Allowlisted actions only. There is **no arbitrary-shell action**, and no
  action takes a command line from the request.
* One machine-level mutex serialises all jobs. A second job waits; it is never
  silently discarded.
* Every action has a timeout, and a timeout kills the whole **process tree**
  (descendants are enumerated *before* the kill, so a detached grandchild cannot
  survive).

**Filesystem**

* The request selects a project *key*. The workspace comes from the local
  registry — an issue body can never name a filesystem root.
* Paths are relative-only. Rejected: absolute, drive-qualified, UNC, traversal
  in either slash style, control characters, alternate data streams, and
  segments with trailing dots or spaces.
* Containment is checked against the **link-resolved** real path, so a junction
  or symlink inside the workspace cannot point out of it.
* A permanent denylist applies regardless of profile: `.git`, `.github`, `.env`,
  `secrets`, `node_modules`.
* Beyond the denylist, each profile declares an explicit allowlist of directory
  prefixes and root-level files. Anything else is `denied`.
* Writes fail closed: `replace_text` writes nothing unless the occurrence count
  matches exactly; `apply_patch` runs `git apply --check` first.

**Control-plane self-protection**

`.github` is denied to every project action. A runtime job cannot rewrite the
workflow that grants it execution, nor the dispatcher's own security code.
Changing gpt-loop itself is a separate, human-driven maintenance activity — not
something reachable through the job protocol.

**Wake channel**

* The daemon binds `127.0.0.1` only. There is no remote webhook, by design.
* Every endpoint requires the shared token, compared with `secrets.compare_digest`.
* `token.txt` and `config.local.json` are ACL'd to the current user only.
* The diagnostics sink scrubs anything token-shaped before persisting it.
* The token is never printed by `doctor.ps1` and never returned by `/health`.

**Output**

* stdout/stderr are bounded per step and again at the whole-comment level.
* Complete results stay local under `%LOCALAPPDATA%\GPTLoop\results\`; only a
  bounded excerpt plus a hash goes to GitHub.
* `read_result` validates its `job_id` shape, so it can only name a file the
  control plane itself wrote.

**Credentials**

* No brain API key. The brain is the user's existing logged-in ChatGPT session.
* No Claude API key. `claude_task` uses the machine's existing authenticated
  Claude Code installation.
* No OpenAI API key. `codex_task` uses the machine's existing authenticated
  Codex CLI installation. gpt-loop does not read, persist, inject, or report a
  key.
* The runner registration token is short-lived and fetched through `gh` at
  registration time; nothing persistent is written into source.
* `.gitignore` excludes `token.txt`, `projects.json`, `config.local.json`,
  events, results, and logs.

## The Claude Code executor

`claude_task` is opt-in per project (`claude.enabled`), and:

* runs with a fixed working directory (the project workspace) and no `--add-dir`;
* takes its permission mode from local configuration — the request may only
  select a mode already in `allowed_permission_modes`;
* has no path to `--dangerously-skip-permissions`;
* has a bounded prompt length and a timeout;
* is captured deterministically, so an autonomous executor still yields a
  structured result.

Claude Code is an executor. It is not a second control plane.

## The Codex CLI executor

`codex_task` is independently opt-in per project (`codex.enabled`), and:

* runs `codex exec` with both its working directory and `-C` fixed to the
  registry workspace, with no `--add-dir`;
* accepts only a bounded `prompt` and an optional locally declared `tier` from
  the request; model, reasoning effort, sandbox, executable, approval policy,
  path, and arbitrary arguments are explicitly not request-controlled;
* resolves the tier to local `model`, `reasoning_effort`, and `sandbox` values,
  then checks the sandbox against both the project allowlist and gpt-loop's hard
  allowlist (`read-only`, `workspace-write`);
* translates that sandbox value to a fixed Codex permission profile: only the
  registered workspace (plus minimal runtime paths) is readable, workspace
  writes are granted only for `workspace-write`, and command network is off;
  it deliberately does not combine this profile with the older `--sandbox`
  mode, because current Codex CLI treats the two systems as alternatives;
* always sets `approval_policy="never"`, `--strict-config`, `--ephemeral`, and
  `--json`; it never uses the dangerous approvals/sandbox bypass;
* explicitly removes an inherited `OPENAI_API_KEY` from the child environment,
  so authentication comes from the machine's existing Codex CLI login;
* passes the prompt over stdin, applies the existing timeout and process-tree
  kill, and records bounded JSONL stdout/stderr plus a summary of configured and
  CLI-reported identity.

Codex CLI is an executor. It is not a second control plane.

## What is deliberately not defended

* **A compromised GitHub account.** An attacker who can open issues as the owner
  can run allowlisted actions in registered projects. Mitigation is account
  security (2FA), plus the fact that the action surface is small and auditable.
* **Malicious project source.** `action: test` runs the project's own tests. If
  the project is hostile, so are its tests. Only register projects you trust.
* **A local user with your privileges.** Anyone who can read `token.txt` can post
  wake events. The ACL raises the bar; it is not a sandbox.

## Browser automation stance

The extension uses ordinary UI affordances: it types into the composer and
triggers send via a click, `form.requestSubmit()`, or an Enter key event. If all
of those fail it reports failure and the daemon retries later.

It does not attempt to defeat CAPTCHAs, bot detection, or any other platform
control, and it holds no `debugger` permission. A visible failure is the correct
outcome when the page will not accept ordinary input.

## Reporting

This started as a personal-use control plane. If you find a problem, open an
issue **without** a working exploit payload.
