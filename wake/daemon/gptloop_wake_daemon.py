"""gpt-loop wake daemon.

Receives job-completion events from the GitHub Actions runner and hands them to
the Chrome extension, which submits a wake marker into the target ChatGPT
conversation.

Design constraints, all of them learned the hard way:

* Python standard library only. This is control-plane infrastructure; it must
  keep working when a project's virtualenv does not.
* Bind to 127.0.0.1 only, behind a shared token. Never a remote webhook.
* Exactly-once from the user's point of view. An event is only *consumed* once
  the extension has verified that the ChatGPT user message actually appeared.
  A crash, reload, or service-worker restart at any earlier stage re-delivers
  the same event rather than losing it or duplicating the message.

The event state machine::

    received -> queued -> claimed -> submitted -> verified -> acknowledged
                  ^                     |
                  +---------------------+   (verification failed / lease expired)

`acknowledged` is terminal. Anything short of it returns to `queued` on restart,
because a message we cannot prove was delivered must be retried.

State is an append-only JSONL journal: every transition is one line, and the
in-memory view is rebuilt by replaying it. That survives a hard kill without
needing a database.
"""

from __future__ import annotations

import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

DAEMON_VERSION = "1.0.0"
PROTOCOL_VERSION = 1

# --- terminal and non-terminal states ---------------------------------------
STATE_QUEUED = "queued"
STATE_CLAIMED = "claimed"
STATE_SUBMITTED = "submitted"
STATE_VERIFIED = "verified"
STATE_ACKNOWLEDGED = "acknowledged"

# States that mean "delivery is finished; never hand this out again".
TERMINAL_STATES = {STATE_ACKNOWLEDGED}

# How long a claim is honoured before the event is offered again. Covers the
# case where Chrome is closed between claiming and verifying.
DEFAULT_CLAIM_LEASE_SECONDS = 120

# How long an in-flight round may sit before the daemon calls it lost.
# ⚠️ Deliberately generous: the workflow's own cap is 120 minutes, so anything
# shorter would report healthy long rounds as dead. ⛔ This is the LAST resort,
# not the fast path —— the next round reports an orphaned marker within seconds
# of starting. This one exists for the case where there is no next round.
DEFAULT_STALL_AFTER_SECONDS = 7800
DEFAULT_STALL_POLL_SECONDS = 300

SECRET_KEYS = {"token", "x-gptloop-token", "authorization", "auth", "secret", "cookie"}


def state_root() -> Path:
    """Where this machine keeps its token, config, journal and results.

    ⚠️ This answer MUST equal ``Get-GptLoopStateRoot`` in runner/lib/Registry.ps1.
    The state root is one fact with two implementations — the dispatcher is
    PowerShell and this daemon is Python, so they cannot share the code — and a
    disagreement does not fail loudly: the runner would post a wake to a daemon
    reading a different token file, and the loop would simply stop waking with
    every component reporting itself healthy.

    ⇒ ``tests/wake/test_wake_daemon.py`` pins the two against each other.
    """
    override = os.environ.get("GPTLOOP_STATE_ROOT")
    if override:
        return Path(override)
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home())
        return Path(base) / "GPTLoop"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "GPTLoop"
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "gptloop"


class WakeStore:
    """Append-only event journal with an in-memory projection."""

    def __init__(self, root: Path, claim_lease_seconds: int = DEFAULT_CLAIM_LEASE_SECONDS):
        self.root = root
        self.events_path = root / "events" / "events.jsonl"
        self.claim_lease_seconds = claim_lease_seconds
        self.events_path.parent.mkdir(parents=True, exist_ok=True)

        self._lock = threading.Condition()
        self._events: dict[str, dict[str, Any]] = {}
        self._order: list[str] = []
        self._seq = 0
        self._replay()

    # -- persistence ---------------------------------------------------------

    def _replay(self) -> None:
        if not self.events_path.exists():
            return
        with self.events_path.open("r", encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except Exception:
                    continue
                self._apply(record, persist=False)

        # Any event that was mid-flight when we died is not provably delivered,
        # so it goes back on the queue. Only `acknowledged` is trusted.
        for event in self._events.values():
            if event["state"] not in TERMINAL_STATES and event["state"] != STATE_QUEUED:
                event["state"] = STATE_QUEUED
                event["claimed_until"] = 0.0
                event["recovered"] = True

    def _append(self, record: dict[str, Any]) -> None:
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def _apply(self, record: dict[str, Any], persist: bool = True) -> dict[str, Any] | None:
        kind = record.get("kind")
        event_id = str(record.get("event_id") or "")
        if not event_id:
            return None

        if kind == "event":
            if event_id in self._events:
                # Duplicate POST of an event we already know about: no new
                # logical event, no second ChatGPT message.
                return self._events[event_id]
            self._seq = max(self._seq, int(record.get("seq", 0)))
            event = {
                "seq": int(record.get("seq", self._seq)),
                "event_id": event_id,
                "issue_number": record.get("issue_number"),
                "action": record.get("action") or "unknown",
                "status": record.get("status") or "unknown",
                "ok": bool(record.get("ok", False)),
                "job_id": record.get("job_id"),
                "run_id": record.get("run_id"),
                "timestamp": record.get("timestamp") or time.time(),
                "state": STATE_QUEUED,
                "attempts": 0,
                "claimed_until": 0.0,
                "last_error": "",
            }
            self._events[event_id] = event
            self._order.append(event_id)
            if persist:
                self._append(record)
            return event

        if kind == "transition":
            event = self._events.get(event_id)
            if event is None:
                return None
            event["state"] = record.get("state", event["state"])
            if "attempts" in record:
                event["attempts"] = int(record["attempts"])
            if "claimed_until" in record:
                event["claimed_until"] = float(record["claimed_until"])
            if "last_error" in record:
                event["last_error"] = str(record["last_error"])[:2000]
            if persist:
                self._append(record)
            return event

        return None

    # -- operations ----------------------------------------------------------

    def add_event(self, payload: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        """Idempotent by event_id. Returns (event, created)."""
        event_id = str(payload.get("event_id") or "").strip()
        if not event_id:
            raise ValueError("event_id is required")
        if len(event_id) > 200:
            raise ValueError("event_id is too long")

        with self._lock:
            existing = self._events.get(event_id)
            if existing is not None:
                return existing, False

            self._seq += 1
            record = {
                "kind": "event",
                "seq": self._seq,
                "event_id": event_id,
                "issue_number": payload.get("issue_number"),
                "action": payload.get("action"),
                "status": payload.get("status"),
                "ok": bool(payload.get("ok", False)),
                "job_id": payload.get("job_id"),
                "run_id": payload.get("run_id"),
                "timestamp": payload.get("timestamp") or time.time(),
                "recorded_at": time.time(),
            }
            event = self._apply(record)
            self._lock.notify_all()
            return event, True

    def _deliverable(self, now: float) -> dict[str, Any] | None:
        """Oldest event that is not finished and not under an active claim."""
        for event_id in self._order:
            event = self._events[event_id]
            if event["state"] in TERMINAL_STATES:
                continue
            if event["state"] in (STATE_CLAIMED, STATE_SUBMITTED) and event["claimed_until"] > now:
                continue
            return event
        return None

    def claim_next(self, timeout: float) -> dict[str, Any] | None:
        """Long-poll for the next deliverable event and claim it.

        The claim is a lease, not a handoff: if the browser dies before
        verifying, the lease expires and the same event is offered again.
        """
        deadline = time.time() + max(0.0, timeout)
        with self._lock:
            while True:
                now = time.time()
                event = self._deliverable(now)
                if event is not None:
                    event["attempts"] += 1
                    self._apply(
                        {
                            "kind": "transition",
                            "event_id": event["event_id"],
                            "state": STATE_CLAIMED,
                            "attempts": event["attempts"],
                            "claimed_until": now + self.claim_lease_seconds,
                            "at": now,
                        }
                    )
                    return dict(event)

                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._lock.wait(timeout=min(remaining, 1.0))

    def transition(self, event_id: str, state: str, error: str = "") -> dict[str, Any] | None:
        """Advance an event.

        `verified` is the only state that leads to `acknowledged`: the extension
        reports it after it has observed the user message in the conversation.
        Anything else returns the event to the queue for a retry of the SAME
        event -- the cursor never advances on an unverified submit.
        """
        with self._lock:
            event = self._events.get(event_id)
            if event is None:
                return None
            if event["state"] in TERMINAL_STATES:
                # Already delivered. Re-acking is a no-op, not a second message.
                return dict(event)

            now = time.time()
            if state == STATE_SUBMITTED:
                # Submitted but not yet proven; hold the lease while verifying.
                self._apply(
                    {
                        "kind": "transition",
                        "event_id": event_id,
                        "state": STATE_SUBMITTED,
                        "claimed_until": now + self.claim_lease_seconds,
                        "at": now,
                    }
                )
            elif state in (STATE_VERIFIED, STATE_ACKNOWLEDGED):
                self._apply(
                    {
                        "kind": "transition",
                        "event_id": event_id,
                        "state": STATE_ACKNOWLEDGED,
                        "claimed_until": 0.0,
                        "at": now,
                    }
                )
            else:
                # 'failed', 'released', or anything unrecognised: retry it.
                self._apply(
                    {
                        "kind": "transition",
                        "event_id": event_id,
                        "state": STATE_QUEUED,
                        "claimed_until": 0.0,
                        "last_error": error,
                        "at": now,
                    }
                )
                self._lock.notify_all()
            return dict(self._events[event_id])

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            now = time.time()
            pending = [
                dict(self._events[e])
                for e in self._order
                if self._events[e]["state"] not in TERMINAL_STATES
            ]
            recent = [dict(self._events[e]) for e in self._order[-10:]]
            acknowledged = [
                self._events[e] for e in self._order if self._events[e]["state"] == STATE_ACKNOWLEDGED
            ]
            return {
                "latest_seq": self._seq,
                "total_events": len(self._order),
                "pending_count": len(pending),
                "pending": pending[:20],
                "recent": recent,
                "last_acknowledged": dict(acknowledged[-1]) if acknowledged else None,
                "now": now,
            }


# --- debug sink --------------------------------------------------------------


class DebugLog:
    """Bounded, token-scrubbing sink for extension diagnostics."""

    def __init__(self, root: Path, token: str, max_entries: int = 2000):
        self.path = root / "logs" / "extension.jsonl"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.token = token
        self.max_entries = max_entries
        self.entries: list[dict[str, Any]] = []
        self.seq = 0
        self.lock = threading.Lock()

    def scrub(self, obj: Any, depth: int = 0) -> Any:
        if depth > 8:
            return "<deep>"
        if isinstance(obj, dict):
            return {
                key: ("<redacted>" if str(key).lower() in SECRET_KEYS else self.scrub(value, depth + 1))
                for key, value in obj.items()
            }
        if isinstance(obj, list):
            return [self.scrub(value, depth + 1) for value in obj[:200]]
        if isinstance(obj, str):
            text = obj.replace(self.token, "<redacted>") if self.token else obj
            return text[:4000]
        return obj

    def append(self, entries: list[Any]) -> int:
        written = 0
        with self.lock:
            with self.path.open("a", encoding="utf-8") as handle:
                for raw in entries[:200]:
                    if not isinstance(raw, dict):
                        continue
                    self.seq += 1
                    entry = self.scrub(raw)
                    entry["log_seq"] = self.seq
                    entry.setdefault("ts", time.time())
                    self.entries.append(entry)
                    handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    written += 1
            if len(self.entries) > self.max_entries:
                del self.entries[: -self.max_entries]
        return written

    def tail(self, after: int, limit: int) -> list[dict[str, Any]]:
        with self.lock:
            return [e for e in self.entries if int(e.get("log_seq", 0)) > after][-limit:]


# --- HTTP server -------------------------------------------------------------


class StallWatch:
    """Notices a round that started and never finished the workflow.

    ⭐ The mechanism this closes, measured 2026-08-21: a real-device round was
    killed by a network drop. Its steps ran on this machine —— the wake even went
    out over 127.0.0.1 and was delivered —— but the runner could no longer report
    to GitHub, so the round log got no entry and the commit status stayed
    **pending**. The research side's protocol reads pending as "still in flight",
    so it waits forever. Silence is the one outcome that stalls the loop, and it
    is indistinguishable from work in progress.

    ⇒ The workflow writes ``round-inflight.json`` when a round starts and deletes
    it in its last step. A marker that outlives any plausible round means the
    round died without publishing.

    ⚠️ This is the LAST resort. The fast path is the next round, which finds the
    orphaned marker and publishes the death using its own working GitHub token.
    This watch exists for the case where no next round ever comes —— exactly the
    case where nothing else would ever speak.

    ⛔ It does not delete the marker: the next round still needs to see it and
    report properly. Reporting is idempotent through the event id.
    """

    def __init__(
        self,
        store: WakeStore,
        root: Path,
        stall_after_seconds: int = DEFAULT_STALL_AFTER_SECONDS,
        poll_seconds: int = DEFAULT_STALL_POLL_SECONDS,
    ):
        self.store = store
        self.marker_path = root / "round-inflight.json"
        self.stall_after_seconds = stall_after_seconds
        self.poll_seconds = poll_seconds

    def _read_marker(self) -> dict[str, Any] | None:
        try:
            return json.loads(self.marker_path.read_text(encoding="utf-8"))
        except Exception:
            return None

    def _marker_age(self, now: float) -> float | None:
        """Age from the file's mtime, ⛔ not from the `started_at` string.

        ⚠️ The marker is written by PowerShell, whose round-trip format carries
        seven fractional digits and an offset —— a shape `fromisoformat` rejects
        on older Pythons, and this daemon runs under whatever launchd gives it.
        Parsing it would add a failure mode whose only symptom is a watch that
        silently never fires. The file's mtime answers the same question with no
        parsing at all: nothing rewrites the marker after the round claims it.
        (`started_at` is kept in the payload for the human reading the report.)
        """
        try:
            return max(0.0, now - self.marker_path.stat().st_mtime)
        except Exception:
            return None

    def state(self, now: float | None = None) -> dict[str, Any]:
        """What `/health` reports. ⭐ Visible immediately, long before the
        stall threshold —— an operator running the liveness checks can see that a
        round is in flight and how old it is, which no other local signal says."""
        now = time.time() if now is None else now
        marker = self._read_marker()
        if marker is None:
            return {"in_flight": None, "age_seconds": None, "stalled": False}
        age = self._marker_age(now)
        return {
            "in_flight": {
                "run_id": str(marker.get("run_id") or ""),
                "event": str(marker.get("event") or ""),
                "sha": str(marker.get("sha") or ""),
                "started_at": str(marker.get("started_at") or ""),
            },
            "age_seconds": None if age is None else int(age),
            # ⛔ Unknown age is NOT treated as stalled: a marker we cannot date is
            # a parsing problem, and reporting a live round as dead is worse than
            # reporting late.
            "stalled": bool(age is not None and age > self.stall_after_seconds),
        }

    def check_once(self, now: float | None = None) -> dict[str, Any] | None:
        """Emits at most one wake per stalled round (idempotent by event id)."""
        state = self.state(now)
        if not state["stalled"]:
            return None
        info = state["in_flight"] or {}
        run_id = info.get("run_id") or "unknown"
        event, created = self.store.add_event(
            {
                # One id per stalled round ⇒ re-checking every 5 minutes cannot
                # produce a second wake for the same death.
                "event_id": f"stall:{run_id}:{info.get('started_at') or ''}"[:200],
                "issue_number": int(self._read_marker().get("round_log_issue") or 0)
                if self._read_marker()
                else 0,
                "action": "round_lost",
                "status": "lost",
                "ok": False,
                "run_id": run_id,
            }
        )
        return event if created else None

    def loop(self) -> None:
        while True:
            try:
                self.check_once()
            except Exception:
                pass
            time.sleep(self.poll_seconds)


def make_handler(store: WakeStore, debug: DebugLog, token: str, config: dict[str, Any]):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"GPTLoopWake/{DAEMON_VERSION}"

        def log_message(self, fmt, *args):  # noqa: A003 - silence stderr spam
            return

        # -- helpers --------------------------------------------------------

        def _authorized(self) -> bool:
            supplied = self.headers.get("X-GPTLoop-Token", "")
            return bool(token) and secrets.compare_digest(supplied, token)

        def _send(self, code: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            try:
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
                # An abandoned long-poll is normal; not worth a traceback.
                pass

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 1_048_576:
                raise ValueError("invalid body length")
            return json.loads(self.rfile.read(length).decode("utf-8"))

        # -- routes ---------------------------------------------------------

        def do_GET(self):  # noqa: N802
            if not self._authorized():
                return self._send(401, {"ok": False, "error": "unauthorized"})
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)

            if parsed.path == "/health":
                snapshot = store.snapshot()
                supervisor = config.get("_supervisor")
                runner_online = bool(supervisor.online()) if supervisor is not None else None
                return self._send(
                    200,
                    {
                        "ok": True,
                        "runner_online": runner_online,
                        "daemon_version": DAEMON_VERSION,
                        "protocol_version": PROTOCOL_VERSION,
                        "state_root": str(store.root),
                        "latest_seq": snapshot["latest_seq"],
                        "pending_count": snapshot["pending_count"],
                        "total_events": snapshot["total_events"],
                        "last_acknowledged": snapshot["last_acknowledged"],
                        # ⭐ The in-flight round, visible without asking GitHub.
                        # ⚠️ `runner_online` above measures process existence and
                        # cannot see a round that died; this can.
                        "round": (
                            config["_stall_watch"].state()
                            if config.get("_stall_watch") is not None
                            else None
                        ),
                        "target_configured": bool(config.get("target_url")),
                    },
                )

            if parsed.path == "/next":
                try:
                    timeout = max(0, min(25, int(query.get("timeout", ["20"])[0])))
                except Exception:
                    timeout = 20
                event = store.claim_next(timeout)
                return self._send(200, {"ok": True, "event": event})

            if parsed.path == "/status":
                return self._send(200, {"ok": True, **store.snapshot()})

            if parsed.path == "/log":
                try:
                    after = int(query.get("after", ["0"])[0])
                except Exception:
                    after = 0
                try:
                    limit = max(1, min(500, int(query.get("limit", ["200"])[0])))
                except Exception:
                    limit = 200
                return self._send(200, {"ok": True, "entries": debug.tail(after, limit), "latest_log_seq": debug.seq})

            return self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):  # noqa: N802
            if not self._authorized():
                return self._send(401, {"ok": False, "error": "unauthorized"})
            parsed = urlparse(self.path)

            if parsed.path == "/event":
                try:
                    payload = self._read_json()
                    event, created = store.add_event(payload)
                except Exception as exc:
                    return self._send(400, {"ok": False, "error": str(exc)})
                return self._send(200, {"ok": True, "created": created, "event": event})

            if parsed.path == "/ack":
                try:
                    payload = self._read_json()
                    event_id = str(payload.get("event_id") or "")
                    state = str(payload.get("state") or "")
                    error = str(payload.get("error") or "")
                except Exception as exc:
                    return self._send(400, {"ok": False, "error": str(exc)})
                event = store.transition(event_id, state, error)
                if event is None:
                    return self._send(404, {"ok": False, "error": "unknown event_id"})
                return self._send(200, {"ok": True, "event": event})

            if parsed.path == "/log":
                try:
                    payload = self._read_json()
                except Exception as exc:
                    return self._send(400, {"ok": False, "error": str(exc)})
                entries = payload.get("entries")
                if not isinstance(entries, list):
                    entries = [payload]
                return self._send(200, {"ok": True, "written": debug.append(entries), "latest_log_seq": debug.seq})

            return self._send(404, {"ok": False, "error": "not found"})

    return Handler


# --- runner supervision ------------------------------------------------------
# The GitHub Actions runner on this machine is not installed as a Windows
# service (that needs admin), so the previous system kept it alive from the wake
# daemon. That behaviour is preserved: without it, a reboot silently leaves the
# loop with no executor and jobs simply queue forever in GitHub.


class RunnerSupervisor:
    def __init__(self, runner_dir: str, log_path: Path, enabled: bool = True):
        self.runner_dir = Path(runner_dir) if runner_dir else None
        self.log_path = log_path
        self.enabled = enabled
        self.child: Any = None
        self.lock = threading.Lock()
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

    def _listener_running(self) -> bool:
        """True only when a listener from OUR runner directory is running.

        Matching on the image name alone is wrong on a machine that hosts more
        than one runner: another repository's listener would make this
        supervisor believe its own runner was healthy and never start it. ⇒ Both
        branches below compare the executable's **path** against our directory.

        ⚠️ This was Windows-only until 2026-08-19 and the failure was the worst
        shape available: `powershell` and `Win32_Process` do not exist on macOS,
        the exception was swallowed, and the method returned False forever. A
        permanently-false health indicator is indistinguishable from a genuinely
        dead runner, so it could never be used to notice one. ⛔ An indicator
        that cannot be wrong is not conservative, it is decorative.
        """
        import subprocess

        if self.runner_dir is None:
            return False

        wanted = str(self.runner_dir).rstrip("\\/").lower()

        if sys.platform == "win32":
            argv = [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Get-CimInstance Win32_Process -Filter \"Name='Runner.Listener.exe'\" "
                "| Select-Object -ExpandProperty ExecutablePath",
            ]
        else:
            # `ps -Ao comm=` prints the executable path on macOS and Linux, which
            # is exactly what the directory comparison needs.
            argv = ["ps", "-Ao", "comm="]

        try:
            completed = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            for line in (completed.stdout or "").splitlines():
                path = line.strip().lower()
                if path and path.startswith(wanted) and "runner.listener" in path:
                    return True
            return False
        except Exception:
            # Unknown rather than "definitely running": returning False here only
            # risks an extra start attempt, which start_if_needed makes safe.
            return False

    def online(self) -> bool:
        if self._listener_running():
            return True
        with self.lock:
            return self.child is not None and self.child.poll() is None

    def start_if_needed(self) -> None:
        import subprocess

        if not self.enabled or self.runner_dir is None:
            return
        run_cmd = self.runner_dir / "run.cmd"
        if not run_cmd.exists():
            return
        if self._listener_running():
            return
        with self.lock:
            if self.child is not None and self.child.poll() is None:
                return
            try:
                handle = self.log_path.open("a", encoding="utf-8", errors="replace")
                self.child = subprocess.Popen(
                    ["cmd.exe", "/d", "/c", str(run_cmd)],
                    cwd=str(self.runner_dir),
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
                )
            except Exception:
                self.child = None

    def loop(self) -> None:
        backoff = 3
        while True:
            try:
                self.start_if_needed()
                if self.online():
                    backoff = 3
                    time.sleep(8)
                else:
                    time.sleep(backoff)
                    backoff = min(60, backoff * 2)
            except Exception:
                time.sleep(10)


def load_config(root: Path) -> dict[str, Any]:
    path = root / "config" / "daemon.json"
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"port": 8777, "claim_lease_seconds": DEFAULT_CLAIM_LEASE_SECONDS}


def load_or_create_token(root: Path) -> str:
    path = root / "token.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        existing = path.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    token = secrets.token_hex(32)
    path.write_text(token, encoding="utf-8")
    return token


def main() -> int:
    root = state_root()
    root.mkdir(parents=True, exist_ok=True)
    config = load_config(root)
    token = load_or_create_token(root)

    store = WakeStore(root, int(config.get("claim_lease_seconds", DEFAULT_CLAIM_LEASE_SECONDS)))
    debug = DebugLog(root, token)
    port = int(os.environ.get("GPTLOOP_PORT") or config.get("port", 8777))

    supervisor = RunnerSupervisor(
        runner_dir=str(config.get("runner_dir") or ""),
        log_path=root / "logs" / "runner.log",
        enabled=bool(config.get("supervise_runner", True)),
    )
    if supervisor.enabled and supervisor.runner_dir is not None:
        threading.Thread(target=supervisor.loop, daemon=True).start()
    config["_supervisor"] = supervisor

    stall_watch = StallWatch(
        store,
        root,
        stall_after_seconds=int(config.get("stall_after_seconds", DEFAULT_STALL_AFTER_SECONDS)),
        poll_seconds=int(config.get("stall_poll_seconds", DEFAULT_STALL_POLL_SECONDS)),
    )
    threading.Thread(target=stall_watch.loop, daemon=True).start()
    config["_stall_watch"] = stall_watch

    handler = make_handler(store, debug, token, config)
    # 127.0.0.1 only. Never 0.0.0.0: this endpoint can drive a browser session.
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"gpt-loop wake daemon {DAEMON_VERSION} listening on 127.0.0.1:{port}", flush=True)
    print(f"state root: {root}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
