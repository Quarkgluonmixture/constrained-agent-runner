"""Wake-delivery regression suite (T002, T003, T004, T016).

Runs on the standard library only -- `python tests/wake/test_wake_daemon.py`.

These cases encode the exactly-once contract. The expensive lesson behind them:
a wake is only safe to consume once the ChatGPT user message has been *observed*,
because a DOM click that appeared to work is not evidence of delivery.
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import threading
import time
import subprocess
import pathlib
import os
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "wake" / "daemon"))

import gptloop_wake_daemon as wake  # noqa: E402


def make_event(event_id: str, issue: int = 1, status: str = "success") -> dict:
    return {
        "event_id": event_id,
        "issue_number": issue,
        "action": "ping",
        "status": status,
        "ok": status == "success",
        "job_id": "00000000-0000-0000-0000-000000000000",
        "run_id": "123",
    }


class StoreTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="gptloop-wake-test-"))
        self.store = wake.WakeStore(self.root, claim_lease_seconds=2)

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def reopen(self) -> None:
        """Simulate a daemon restart by rebuilding from the journal."""
        self.store = wake.WakeStore(self.root, claim_lease_seconds=2)


class TestDuplicateDelivery(StoreTestCase):
    def test_t002_duplicate_post_is_one_logical_event(self):
        """T002: the runner POSTing the same event twice must not double-wake."""
        first, created_first = self.store.add_event(make_event("run:1:42"))
        second, created_second = self.store.add_event(make_event("run:1:42"))

        self.assertTrue(created_first)
        self.assertFalse(created_second, "second POST must not create a new event")
        self.assertEqual(first["seq"], second["seq"])
        self.assertEqual(self.store.snapshot()["total_events"], 1)

        # And only one delivery is offered.
        claimed = self.store.claim_next(timeout=0)
        self.assertIsNotNone(claimed)
        self.store.transition(claimed["event_id"], wake.STATE_VERIFIED)
        self.assertIsNone(self.store.claim_next(timeout=0), "no second delivery")

    def test_duplicate_after_acknowledgement_stays_acknowledged(self):
        self.store.add_event(make_event("run:1:42"))
        claimed = self.store.claim_next(timeout=0)
        self.store.transition(claimed["event_id"], wake.STATE_VERIFIED)

        event, created = self.store.add_event(make_event("run:1:42"))
        self.assertFalse(created)
        self.assertEqual(event["state"], wake.STATE_ACKNOWLEDGED)
        self.assertIsNone(self.store.claim_next(timeout=0))


class TestRetrySemantics(StoreTestCase):
    def test_t003_failed_verification_retries_the_same_event(self):
        """T003: a failed submit must re-offer the SAME event, not advance."""
        self.store.add_event(make_event("run:1:50"))

        first = self.store.claim_next(timeout=0)
        self.assertEqual(first["attempts"], 1)
        self.store.transition(first["event_id"], "failed", error="submit verification failed")

        second = self.store.claim_next(timeout=0)
        self.assertIsNotNone(second, "event must be offered again")
        self.assertEqual(second["event_id"], first["event_id"])
        self.assertEqual(second["attempts"], 2)
        self.assertEqual(second["last_error"], "submit verification failed")

    def test_t004_cursor_advances_only_after_verified(self):
        """T004: `submitted` is not enough; only `verified` consumes the event."""
        self.store.add_event(make_event("run:1:60"))
        claimed = self.store.claim_next(timeout=0)

        # Reporting 'submitted' holds the lease but does not finish the event.
        self.store.transition(claimed["event_id"], wake.STATE_SUBMITTED)
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot["pending_count"], 1, "submitted is not delivered")
        self.assertIsNone(snapshot["last_acknowledged"])

        # After the lease expires it becomes deliverable again, unchanged.
        time.sleep(2.2)
        again = self.store.claim_next(timeout=0)
        self.assertIsNotNone(again, "an unverified submit must be retried")
        self.assertEqual(again["event_id"], claimed["event_id"])

        self.store.transition(again["event_id"], wake.STATE_VERIFIED)
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot["pending_count"], 0)
        self.assertEqual(snapshot["last_acknowledged"]["event_id"], claimed["event_id"])

    def test_claim_lease_prevents_two_simultaneous_deliveries(self):
        self.store.add_event(make_event("run:1:61"))
        first = self.store.claim_next(timeout=0)
        self.assertIsNotNone(first)
        # A second consumer (e.g. a duplicated tab) must not get it immediately.
        self.assertIsNone(self.store.claim_next(timeout=0))


class TestRestartRecovery(StoreTestCase):
    def test_t016_acknowledged_event_is_not_resubmitted_after_restart(self):
        """T016: restart must not replay an event we already delivered."""
        self.store.add_event(make_event("run:1:70"))
        claimed = self.store.claim_next(timeout=0)
        self.store.transition(claimed["event_id"], wake.STATE_VERIFIED)

        self.reopen()

        self.assertIsNone(self.store.claim_next(timeout=0), "acknowledged event must stay delivered")
        snapshot = self.store.snapshot()
        self.assertEqual(snapshot["pending_count"], 0)
        self.assertEqual(snapshot["last_acknowledged"]["event_id"], "run:1:70")

    def test_t016b_unverified_event_survives_restart_and_is_retried(self):
        """A crash between claim and verify must not lose the wake."""
        self.store.add_event(make_event("run:1:71"))
        claimed = self.store.claim_next(timeout=0)
        self.store.transition(claimed["event_id"], wake.STATE_SUBMITTED)

        # Hard restart while the event was mid-flight.
        self.reopen()

        recovered = self.store.claim_next(timeout=0)
        self.assertIsNotNone(recovered, "in-flight event must be recovered")
        self.assertEqual(recovered["event_id"], "run:1:71")

    def test_ordering_is_preserved_across_restart(self):
        for n in range(3):
            self.store.add_event(make_event(f"run:1:{80 + n}", issue=80 + n))
        self.reopen()
        order = []
        for _ in range(3):
            event = self.store.claim_next(timeout=0)
            order.append(event["event_id"])
            self.store.transition(event["event_id"], wake.STATE_VERIFIED)
        self.assertEqual(order, ["run:1:80", "run:1:81", "run:1:82"])


class TestHttpSurface(unittest.TestCase):
    """End-to-end over real HTTP, including auth and the long-poll path."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.root = Path(tempfile.mkdtemp(prefix="gptloop-wake-http-"))
        cls.token = "test-token-" + "a" * 16
        cls.store = wake.WakeStore(cls.root, claim_lease_seconds=5)
        cls.debug = wake.DebugLog(cls.root, cls.token)
        handler = wake.make_handler(cls.store, cls.debug, cls.token, {"target_url": "https://example.invalid/c/x"})
        cls.server = wake.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.root, ignore_errors=True)

    def call(self, method: str, path: str, payload: dict | None = None, token: str | None = None):
        url = f"http://127.0.0.1:{self.port}{path}"
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("X-GPTLoop-Token", self.token if token is None else token)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))

    def test_requires_token(self):
        status, body = self.call("GET", "/health", token="wrong")
        self.assertEqual(status, 401)
        self.assertFalse(body["ok"])

    def test_binds_loopback_only(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def test_full_delivery_cycle_over_http(self):
        status, body = self.call("POST", "/event", make_event("http:1:90", issue=90))
        self.assertEqual(status, 200)
        self.assertTrue(body["created"])

        # Duplicate POST -> not created again (T002 at the HTTP layer).
        _, duplicate = self.call("POST", "/event", make_event("http:1:90", issue=90))
        self.assertFalse(duplicate["created"])

        _, claimed = self.call("GET", "/next?timeout=1")
        self.assertEqual(claimed["event"]["event_id"], "http:1:90")

        _, acked = self.call("POST", "/ack", {"event_id": "http:1:90", "state": "verified"})
        self.assertEqual(acked["event"]["state"], wake.STATE_ACKNOWLEDGED)

        _, empty = self.call("GET", "/next?timeout=0")
        self.assertIsNone(empty["event"], "acknowledged event must not be re-offered")

    def test_health_never_returns_the_token(self):
        _, body = self.call("GET", "/health")
        self.assertNotIn(self.token, json.dumps(body))

    def test_debug_log_scrubs_token(self):
        self.call("POST", "/log", {"entries": [{"stage": "TEST", "note": f"token={self.token}"}]})
        _, body = self.call("GET", "/log?after=0&limit=10")
        self.assertNotIn(self.token, json.dumps(body["entries"]))
        self.assertIn("<redacted>", json.dumps(body["entries"]))


class StateRootAgreementTest(unittest.TestCase):
    """⭐⭐ The state root is one fact with two implementations.

    ⚠️ The dispatcher is PowerShell and this daemon is Python, so the answer
    cannot be shared as code. ⛔ A disagreement fails silently in the worst
    possible way: the runner posts a wake to a daemon that read a different
    token file, every component reports itself healthy, and the loop just
    stops waking. ⇒ Pinned against the real PowerShell function.
    """

    def test_powershell_and_python_agree_on_the_state_root(self) -> None:
        pwsh = shutil.which("pwsh")
        if pwsh is None:
            self.skipTest("pwsh is not installed; the dispatcher half cannot be asked")
        repo_root = pathlib.Path(__file__).resolve().parents[2]
        script = (
            f". '{repo_root}/runner/lib/Common.ps1'; "
            f". '{repo_root}/runner/lib/Registry.ps1'; "
            "Get-GptLoopStateRoot"
        )
        env = {k: v for k, v in os.environ.items() if k != "GPTLOOP_STATE_ROOT"}
        proc = subprocess.run(
            [pwsh, "-NoProfile", "-Command", script],
            capture_output=True, text=True, timeout=120, env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        from_powershell = proc.stdout.strip()
        self.assertTrue(from_powershell, "precondition not met: PowerShell returned no path")

        saved = os.environ.pop("GPTLOOP_STATE_ROOT", None)
        try:
            from_python = str(wake.state_root())
        finally:
            if saved is not None:
                os.environ["GPTLOOP_STATE_ROOT"] = saved
        self.assertEqual(from_python, from_powershell)


class StallWatchTest(unittest.TestCase):
    """T022 —— silence is the one outcome that stalls the loop.

    Measured 2026-08-21: a real-device round was killed by a network drop. Its
    steps ran locally (the wake was delivered over 127.0.0.1) but the runner
    could not reach GitHub, so the round log stayed empty and the commit status
    stayed `pending` —— which the research side reads as "still in flight".
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.store = wake.WakeStore(self.root)
        self.watch = wake.StallWatch(self.store, self.root, stall_after_seconds=60, poll_seconds=1)
        self.marker = self.root / "round-inflight.json"

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def _write_marker(self, age_seconds: float = 0.0) -> None:
        self.marker.write_text(
            json.dumps(
                {
                    "run_id": "42",
                    "event": "push",
                    "sha": "abc",
                    # PowerShell round-trip form: seven fractional digits.
                    "started_at": "2026-08-21T17:19:18.0000000+00:00",
                    "round_log_issue": "66",
                }
            ),
            encoding="utf-8",
        )
        if age_seconds:
            past = time.time() - age_seconds
            os.utime(self.marker, (past, past))

    def test_no_marker_is_not_a_stall(self) -> None:
        state = self.watch.state()
        self.assertIsNone(state["in_flight"])
        self.assertFalse(state["stalled"])
        self.assertIsNone(self.watch.check_once())

    def test_a_running_round_is_visible_but_not_reported(self) -> None:
        # The point of exposing it: no other local signal says a round is in
        # flight. `runner_online` measures process existence.
        self._write_marker()
        state = self.watch.state()
        self.assertEqual("42", state["in_flight"]["run_id"])
        self.assertFalse(state["stalled"])
        self.assertIsNone(self.watch.check_once())

    def test_a_stalled_round_wakes_the_conversation_exactly_once(self) -> None:
        self._write_marker(age_seconds=3600)
        self.assertTrue(self.watch.state()["stalled"])

        event = self.watch.check_once()
        self.assertIsNotNone(event)
        self.assertEqual("lost", event["status"])
        self.assertEqual("round_lost", event["action"])
        # Routed at the round log, so the wake message tells the research side
        # where to look.
        self.assertEqual(66, event["issue_number"])
        self.assertEqual(1, self.store.snapshot()["pending_count"])

        # Idempotent: the watch re-checks every few minutes and must not wake the
        # conversation again for the same death.
        self.assertIsNone(self.watch.check_once())
        self.assertEqual(1, self.store.snapshot()["pending_count"])

    def test_the_marker_is_left_for_the_next_round(self) -> None:
        # The next round publishes the death properly (it has a GitHub token);
        # deleting the marker here would take that away.
        self._write_marker(age_seconds=3600)
        self.watch.check_once()
        self.assertTrue(self.marker.exists())

    def test_an_undatable_marker_is_not_called_dead(self) -> None:
        # Reporting a live round as dead is worse than reporting late.
        self._write_marker()
        self.marker.unlink()
        self.assertFalse(self.watch.state()["stalled"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

