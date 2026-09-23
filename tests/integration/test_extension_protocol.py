"""Replays the exact HTTP sequence background.js performs (T002-T004, T016).

The browser leg cannot be automated here, but the *protocol* between the
extension and the daemon can be, and that is where exactly-once actually lives.
This drives a real daemon over real HTTP, in the same order and with the same
payloads as `background.js`, including the failure paths.

Run: python tests/integration/test_extension_protocol.py
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "wake" / "daemon"))

import gptloop_wake_daemon as wake  # noqa: E402


class ExtensionClient:
    """A faithful stand-in for background.js's daemon client."""

    def __init__(self, base: str, token: str):
        self.base = base
        self.token = token

    def _call(self, method: str, path: str, payload=None):
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(payload).encode("utf-8") if payload is not None else None,
            method=method,
        )
        request.add_header("X-GPTLoop-Token", self.token)
        if payload is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            return json.loads(exc.read().decode("utf-8"))

    # -- the three calls background.js makes -------------------------------
    def claim(self, timeout: int = 0):
        return self._call("GET", f"/next?timeout={timeout}").get("event")

    def report_submitted(self, event_id: str):
        return self._call("POST", "/ack", {"event_id": event_id, "state": "submitted"})

    def report_verified(self, event_id: str):
        return self._call("POST", "/ack", {"event_id": event_id, "state": "verified"})

    def report_failed(self, event_id: str, error: str):
        return self._call("POST", "/ack", {"event_id": event_id, "state": "failed", "error": error})

    def post_event(self, payload: dict):
        return self._call("POST", "/event", payload)

    def status(self):
        return self._call("GET", "/status")


class ExtensionProtocolTest(unittest.TestCase):
    """Each test gets a private daemon so the live installation is untouched."""

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="gptloop-integration-"))
        self.token = "integration-token-" + "b" * 16
        self.store = wake.WakeStore(self.root, claim_lease_seconds=1)
        self.debug = wake.DebugLog(self.root, self.token)
        handler = wake.make_handler(self.store, self.debug, self.token, {})
        self.server = wake.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self.thread.start()
        port = self.server.server_address[1]
        self.client = ExtensionClient(f"http://127.0.0.1:{port}", self.token)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.root, ignore_errors=True)

    @staticmethod
    def runner_event(run_id: str, attempt: int, issue: int, status: str = "success") -> dict:
        """Exactly the payload the workflow's wake step POSTs."""
        return {
            "event_id": f"{run_id}:{attempt}:{issue}",
            "issue_number": issue,
            "action": "ping",
            "status": status,
            "ok": status == "success",
            "job_id": "11111111-2222-3333-4444-555555555555",
            "run_id": run_id,
            "timestamp": 1700000000,
        }

    # -- cases -------------------------------------------------------------

    def test_happy_path_delivers_exactly_once(self):
        self.client.post_event(self.runner_event("900", 1, 10))

        event = self.client.claim()
        self.assertIsNotNone(event)
        self.client.report_submitted(event["event_id"])
        self.client.report_verified(event["event_id"])

        self.assertIsNone(self.client.claim(), "a verified event must never be re-offered")
        self.assertEqual(self.client.status()["pending_count"], 0)

    def test_duplicate_runner_post_yields_one_delivery(self):
        """T002: the workflow retrying its wake step must not double-wake."""
        payload = self.runner_event("901", 1, 11)
        first = self.client.post_event(payload)
        second = self.client.post_event(payload)
        self.assertTrue(first["created"])
        self.assertFalse(second["created"])

        deliveries = 0
        while True:
            event = self.client.claim()
            if event is None:
                break
            deliveries += 1
            self.client.report_verified(event["event_id"])
            if deliveries > 3:
                self.fail("event was delivered repeatedly")
        self.assertEqual(deliveries, 1)

    def test_unverified_submit_is_retried_not_consumed(self):
        """T003/T004: a click that could not be proven must retry the same event."""
        self.client.post_event(self.runner_event("902", 1, 12))

        first = self.client.claim()
        self.client.report_submitted(first["event_id"])
        # The content script could not find the marker.
        self.client.report_failed(first["event_id"], "submission was not verified")

        second = self.client.claim()
        self.assertIsNotNone(second)
        self.assertEqual(second["event_id"], first["event_id"], "must retry the SAME event")
        self.assertGreater(second["attempts"], first["attempts"])

        self.client.report_verified(second["event_id"])
        self.assertIsNone(self.client.claim())

    def test_worker_death_between_submit_and_verify_recovers(self):
        """T016: an MV3 service worker eviction mid-delivery must not lose the wake."""
        self.client.post_event(self.runner_event("903", 1, 13))
        event = self.client.claim()
        self.client.report_submitted(event["event_id"])
        # ...and the worker is evicted here, so no verify ever arrives.

        import time
        time.sleep(1.3)  # claim lease expires

        recovered = self.client.claim()
        self.assertIsNotNone(recovered, "the lease must expire and re-offer the event")
        self.assertEqual(recovered["event_id"], event["event_id"])

    def test_events_are_delivered_in_arrival_order(self):
        for issue in (20, 21, 22):
            self.client.post_event(self.runner_event(str(1000 + issue), 1, issue))

        seen = []
        while True:
            event = self.client.claim()
            if event is None:
                break
            seen.append(event["issue_number"])
            self.client.report_verified(event["event_id"])
        self.assertEqual(seen, [20, 21, 22])

    def test_a_rerun_is_a_distinct_event(self):
        """Re-running a workflow bumps run_attempt, which is a genuinely new wake."""
        self.client.post_event(self.runner_event("904", 1, 30))
        first = self.client.claim()
        self.client.report_verified(first["event_id"])

        self.client.post_event(self.runner_event("904", 2, 30))
        second = self.client.claim()
        self.assertIsNotNone(second, "attempt 2 is a different delivery")
        self.assertNotEqual(second["event_id"], first["event_id"])

    def test_failure_status_still_wakes_the_conversation(self):
        """A failed job must wake the brain -- silence would stall the loop."""
        self.client.post_event(self.runner_event("905", 1, 40, status="failure"))
        event = self.client.claim()
        self.assertIsNotNone(event)
        self.assertEqual(event["status"], "failure")
        self.assertFalse(event["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
