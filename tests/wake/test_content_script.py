"""Browser test for the real content.js against a mock ChatGPT composer.

Chrome 137+ ignores `--load-extension`, so the packaged extension cannot be
loaded automatically. That blocks testing the extension as a whole -- but it does
not block testing the part that carries the risk: the DOM injection and, above
all, the *verification* logic that decides whether a wake was delivered.

This loads the actual `wake/extension/content.js` into a page with a stubbed
`chrome` API, captures the message listener it registers, and drives it exactly
as background.js would.

Requires Playwright:  python -m playwright install chromium
Run:                  python tests/wake/test_content_script.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTENT_JS = REPO / "wake" / "extension" / "content.js"
MOCK_PAGE = REPO / "tests" / "wake" / "mock_chatgpt.html"

try:
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover
    print("playwright is not installed; skipping content-script browser tests")
    sys.exit(0)

# Stubs chrome.* and captures the listener content.js registers, so the test can
# invoke the wake handler the same way the service worker does.
BRIDGE = """
() => {
  window.__logs = [];
  window.__listener = null;
  window.chrome = {
    runtime: {
      sendMessage: (msg) => { window.__logs.push(msg); },
      onMessage: { addListener: (fn) => { window.__listener = fn; } },
    },
  };
}
"""

INVOKE = """
(payload) => new Promise((resolve) => {
  const handled = window.__listener(payload, {}, resolve);
  if (!handled) resolve({ ok: false, error: 'listener did not take the message' });
})
"""


class ContentScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._pw = sync_playwright().start()
        try:
            cls.browser = cls._pw.chromium.launch()
        except Exception as exc:  # pragma: no cover
            cls._pw.stop()
            raise unittest.SkipTest(f"could not launch chromium: {exc}")
        cls.content_js = CONTENT_JS.read_text(encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls._pw.stop()

    def setUp(self):
        self.page = self.browser.new_page()
        self.page.goto(MOCK_PAGE.as_uri())
        self.page.evaluate(BRIDGE)
        self.page.evaluate(self.content_js)
        # content.js must have registered its listener on load.
        self.assertTrue(self.page.evaluate("() => typeof window.__listener === 'function'"))

    def tearDown(self):
        self.page.close()

    # -- helpers -----------------------------------------------------------

    def wake(self, event_id="900:1:5", timeout=25000):
        marker = f"[GPT_LOOP_WAKE event={event_id}]"
        prompt = f"go {marker} issue=5 action=ping status=success"
        self.page.set_default_timeout(timeout)
        return self.page.evaluate(
            INVOKE,
            {"type": "GPTLOOP_WAKE", "eventId": event_id, "marker": marker, "prompt": prompt},
        )

    def user_messages(self):
        return self.page.evaluate(
            "() => Array.from(document.querySelectorAll('[data-message-author-role=\"user\"]')).map(n => n.textContent)"
        )

    # -- cases -------------------------------------------------------------

    def test_ping_responds(self):
        pong = self.page.evaluate(INVOKE, {"type": "GPTLOOP_PING"})
        self.assertTrue(pong["ok"])
        self.assertEqual(pong["version"], "1.0.0")

    def test_submits_and_verifies_exactly_one_message(self):
        result = self.wake()
        self.assertTrue(result["verified"], result)
        self.assertTrue(result["marker_found"])

        messages = self.user_messages()
        self.assertEqual(len(messages), 1, f"expected exactly one user message, got {messages}")
        self.assertIn("[GPT_LOOP_WAKE event=900:1:5]", messages[0])
        self.assertTrue(messages[0].startswith("go "))

    def test_reports_unverified_when_the_page_swallows_the_submit(self):
        """The critical case: a submit that *looks* accepted but delivered nothing."""
        self.page.evaluate("() => { window.__mock.swallowSubmits = 99; }")
        result = self.wake(timeout=60000)

        self.assertFalse(result["verified"], result)
        self.assertEqual(self.user_messages(), [], "nothing should have been delivered")
        # It must have genuinely tried every strategy before giving up.
        self.assertGreaterEqual(self.page.evaluate("() => window.__mock.submitCount"), 3)

    def test_recovers_when_only_the_last_strategy_works(self):
        """Strategy fallback: the first attempts are swallowed, a later one lands."""
        self.page.evaluate("() => { window.__mock.swallowSubmits = 2; }")
        result = self.wake(timeout=60000)

        self.assertTrue(result["verified"], result)
        self.assertEqual(len(self.user_messages()), 1)

    def test_refuses_to_credit_a_marker_that_was_already_present(self):
        """A stale marker must never manufacture a false verification."""
        marker = "[GPT_LOOP_WAKE event=901:1:6]"
        self.page.evaluate(
            """(marker) => {
                const node = document.createElement('div');
                node.setAttribute('data-message-author-role', 'user');
                node.textContent = 'go ' + marker + ' issue=6 action=ping status=success';
                document.getElementById('transcript').appendChild(node);
            }""",
            marker,
        )
        result = self.wake(event_id="901:1:6")
        self.assertFalse(result["verified"], result)
        self.assertIn("already present", result.get("error", ""))
        # And it must not have sent anything on top of the existing message.
        self.assertEqual(len(self.user_messages()), 1)

    def test_never_clicks_the_stop_control_while_streaming(self):
        """The send and stop controls are the same element on the real page.

        While streaming, the wake must wait rather than click -- clicking would
        abort the assistant's in-flight reply.
        """
        self.page.evaluate("() => { window.__mock.streaming = true; window.__mock.refresh(); }")

        # waitIdle blocks, so run the wake without awaiting it, then observe.
        self.page.evaluate(
            """() => {
                const marker = '[GPT_LOOP_WAKE event=902:1:7]';
                window.__pending = window.__listener(
                    {type:'GPTLOOP_WAKE', eventId:'902:1:7', marker,
                     prompt:'go ' + marker + ' issue=7 action=ping status=success'},
                    {}, (r) => { window.__result = r; });
            }"""
        )
        self.page.wait_for_timeout(2000)

        self.assertEqual(self.page.evaluate("() => window.__mock.submitCount"), 0,
                         "must not press the control while streaming")
        self.assertEqual(self.user_messages(), [])

        # Once streaming ends it should proceed and verify normally.
        self.page.evaluate("() => { window.__mock.streaming = false; window.__mock.refresh(); }")
        self.page.wait_for_function("() => window.__result !== undefined", timeout=30000)
        result = self.page.evaluate("() => window.__result")
        self.assertTrue(result["verified"], result)
        self.assertEqual(len(self.user_messages()), 1)

    def test_emits_diagnostics_for_the_daemon(self):
        self.wake()
        stages = self.page.evaluate(
            "() => window.__logs.filter(l => l && l.type === 'GPTLOOP_LOG').map(l => l.entry.stage)"
        )
        self.assertIn("PROMPT_INJECTED", stages)
        self.assertIn("MARKER_VERIFIED", stages)


if __name__ == "__main__":
    unittest.main(verbosity=2)
