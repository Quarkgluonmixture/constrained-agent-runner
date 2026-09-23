/**
 * gpt-loop wake -- ChatGPT page agent.
 *
 * Ported from an earlier prototype's wake extension, whose DOM handling was hardened
 * against a series of real failures. The comments record why each defence
 * exists; do not simplify them away without reproducing the original failure.
 *
 * The contract with background.js: this script submits a marker into the
 * composer and reports whether the marker was OBSERVED in a user-role message.
 * Nothing else counts as delivery -- in particular, a successful click does not.
 */
(() => {
  const VERSION = '1.0.0';
  if (window.__gptLoopWakeVersion === VERSION) return;
  window.__gptLoopWakeVersion = VERSION;

  const sleep = ms => new Promise(r => setTimeout(r, ms));

  // --- structured logging ---------------------------------------------------
  // Records go to the background worker, which mirrors them to the daemon so a
  // failure can be diagnosed without opening a devtools console.
  let CTX = { wake_id: '', marker_before: false };

  function dlog(stage, fields = {}) {
    const entry = {
      ts: Date.now() / 1000,
      stage,
      side: 'content',
      wake_id: CTX.wake_id,
      href: location.href,
      visibility: document.visibilityState,
      doc_focus: document.hasFocus(),
      ...fields,
    };
    try { chrome.runtime.sendMessage({ type: 'GPTLOOP_LOG', entry }); } catch (_) {}
    return entry;
  }

  // --- DOM discovery --------------------------------------------------------
  const INPUT_SELECTORS = [
    '#prompt-textarea',
    'div[contenteditable="true"][data-lexical-editor="true"]',
    'form div[contenteditable="true"]',
    'div[contenteditable="true"][role="textbox"]',
    'div[contenteditable="true"]',
    'textarea',
  ];

  const SEND_SELECTORS = [
    'button[data-testid="send-button"]',
    'button#composer-submit-button',
    'button[data-testid="composer-send-button"]',
    'button[aria-label="Send prompt"]',
    'button[aria-label*="Send" i]',
    'button[aria-label*="发送"]',
    'form button[type="submit"]',
  ];

  const STOP_SELECTORS = [
    'button[data-testid="stop-button"]',
    'button[data-testid="composer-stop-button"]',
    'button[aria-label*="Stop streaming" i]',
    'button[aria-label*="Stop generating" i]',
    'button[aria-label*="停止"]',
  ];

  function findWith(selectors) {
    for (const sel of selectors) {
      try {
        const el = document.querySelector(sel);
        if (el) return { el, selector: sel };
      } catch (_) {}
    }
    return { el: null, selector: null };
  }

  // ChatGPT reuses ONE element (#composer-submit-button) for send and stop,
  // swapping data-testid / aria-label. Matching it by id alone can click Stop
  // and abort the reply, so send lookups must reject anything stop-shaped.
  function isStopish(b) {
    if (!b) return false;
    const t = (b.getAttribute('data-testid') || '').toLowerCase();
    const a = (b.getAttribute('aria-label') || '').toLowerCase();
    return t.includes('stop') || a.includes('stop') || a.includes('停止');
  }

  const findInput = () => findWith(INPUT_SELECTORS);
  const findStop = () => findWith(STOP_SELECTORS);

  function findSend() {
    for (const sel of SEND_SELECTORS) {
      try {
        for (const el of document.querySelectorAll(sel)) {
          if (!isStopish(el)) return { el, selector: sel };
        }
      } catch (_) {}
    }
    return { el: null, selector: null };
  }

  function isEnabled(b) {
    return !!b && !b.disabled && !b.hasAttribute('disabled') &&
      b.getAttribute('aria-disabled') !== 'true';
  }

  function readInput(input) {
    if (!input) return '';
    if (input instanceof HTMLTextAreaElement || input instanceof HTMLInputElement) {
      return input.value || '';
    }
    return input.innerText ?? input.textContent ?? '';
  }

  const norm = s => (s ?? '').replace(/\s+/g, ' ').trim();
  const squash = s => (s ?? '').replace(/\s+/g, '');

  const userMessages = () =>
    Array.from(document.querySelectorAll('[data-message-author-role="user"]'));
  const assistantMessages = () =>
    Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));

  function nodeText(n) { return n ? (n.innerText ?? n.textContent ?? '') : ''; }

  // --- readiness ------------------------------------------------------------
  // Never submit while the model is still streaming: the send control is the
  // stop control at that moment, and clicking it aborts the previous turn.
  async function waitIdle(timeoutMs = 90 * 1000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const { el: input } = findInput();
      const streaming = !!findStop().el;
      if (input && !streaming) return input;
      await sleep(250);
    }
    throw new Error('composer did not become idle in time');
  }

  function selectAll(input) {
    try {
      const sel = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(input);
      sel.removeAllRanges();
      sel.addRange(range);
      return true;
    } catch (_) { return false; }
  }

  function focusInput(input) {
    try { input.focus({ preventScroll: true }); } catch (_) {
      try { input.focus(); } catch (_) {}
    }
    return document.activeElement === input;
  }

  function clearInput(input) {
    focusInput(input);
    if (input instanceof HTMLTextAreaElement || input instanceof HTMLInputElement) {
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), 'value')?.set;
      if (setter) setter.call(input, ''); else input.value = '';
      input.dispatchEvent(new Event('input', { bubbles: true }));
      return;
    }
    selectAll(input);
    try { document.execCommand('delete', false); } catch (_) {}
    if (squash(readInput(input))) {
      // Lexical ignored the command; fall back to a synthetic deletion event.
      try {
        input.dispatchEvent(new InputEvent('beforeinput', {
          inputType: 'deleteContentBackward', bubbles: true, cancelable: true, composed: true,
        }));
        input.dispatchEvent(new InputEvent('input', {
          inputType: 'deleteContentBackward', bubbles: true, composed: true,
        }));
      } catch (_) {}
    }
  }

  // Each injector returns a label; the caller verifies by reading the composer
  // back, because React state and DOM text can disagree.
  const INJECTORS = [
    ['execCommand-insertText', (input, value) => {
      focusInput(input);
      selectAll(input);
      document.execCommand('insertText', false, value);
    }],
    ['paste-event', (input, value) => {
      focusInput(input);
      selectAll(input);
      const dt = new DataTransfer();
      dt.setData('text/plain', value);
      input.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: dt, bubbles: true, cancelable: true, composed: true,
      }));
    }],
    ['input-events', (input, value) => {
      focusInput(input);
      clearInput(input);
      input.dispatchEvent(new InputEvent('beforeinput', {
        inputType: 'insertText', data: value, bubbles: true, cancelable: true, composed: true,
      }));
      input.dispatchEvent(new InputEvent('input', {
        inputType: 'insertText', data: value, bubbles: true, composed: true,
      }));
    }],
    ['textarea-setter', (input, value) => {
      if (!(input instanceof HTMLTextAreaElement || input instanceof HTMLInputElement)) return;
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), 'value')?.set;
      if (setter) setter.call(input, value); else input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }],
  ];

  async function injectPrompt(input, value) {
    const before = readInput(input);
    for (const [label, fn] of INJECTORS) {
      try {
        clearInput(input);
        fn(input, value);
      } catch (err) {
        dlog('PROMPT_INJECT_TRY', { method: label, error: String(err?.message || err) });
        continue;
      }
      await sleep(180);
      const after = readInput(input);
      const ok = squash(after) === squash(value);
      const send = findSend();
      dlog('PROMPT_INJECT_TRY', {
        method: label,
        matched: ok,
        composer_after: norm(after).slice(0, 120),
        send_selector: send.selector,
        send_disabled: send.el ? !isEnabled(send.el) : 'no-button',
      });
      if (ok) return { method: label, before, after };
    }
    return { method: null, before, after: readInput(input) };
  }

  // --- verification ---------------------------------------------------------
  // The ONLY definition of success: the wake's unique marker appears in a
  // user-role message that was not there before.
  async function verify(marker, beforeUserCount, timeoutMs = 8000) {
    const start = Date.now();
    let sawGrowth = false;
    // ChatGPT virtualizes the transcript, so the rendered user-node count can
    // FALL even when a send succeeds. Count growth is corroboration only; the
    // unique marker appearing in a user-role node is the actual proof, and
    // CTX.marker_before guarantees it was not already on screen beforehand.
    while (Date.now() - start < timeoutMs) {
      const xs = userMessages();
      if (xs.length > beforeUserCount && !sawGrowth) {
        sawGrowth = true;
        dlog('USER_MESSAGE_DETECTED', {
          user_before: beforeUserCount,
          user_after: xs.length,
          detail: norm(nodeText(xs[xs.length - 1])).slice(0, 120),
        });
      }
      if (!CTX.marker_before && xs.some(n => nodeText(n).includes(marker))) {
        return {
          verified: true,
          user_before: beforeUserCount,
          user_after: xs.length,
          count_grew: xs.length > beforeUserCount,
          marker_found: true,
        };
      }
      await sleep(120);
    }
    const xs = userMessages();
    const send = findSend();
    return {
      verified: false,
      user_before: beforeUserCount,
      user_after: xs.length,
      marker_found: false,
      saw_growth: sawGrowth,
      composer_after: norm(readInput(findInput().el)).slice(0, 120),
      send_disabled: send.el ? !isEnabled(send.el) : 'no-button',
      streaming: !!findStop().el,
    };
  }

  // --- submit strategies ----------------------------------------------------
  // Ordinary UI affordances only. If all of them fail we report failure and the
  // daemon retries the same event; we do not attempt to defeat any platform
  // control.
  async function strategyClick() {
    const { el: btn, selector } = findSend();
    if (!btn) return { attempted: false, detail: 'no send button in DOM' };
    if (!isEnabled(btn)) return { attempted: false, detail: 'send button disabled' };
    btn.click();
    dlog('SEND_CLICKED', { send_selector: selector });
    return { attempted: true };
  }

  async function strategyRequestSubmit() {
    const { el: input } = findInput();
    const form = input ? input.closest('form') : null;
    if (!form || typeof form.requestSubmit !== 'function') {
      return { attempted: false, detail: 'no form / no requestSubmit' };
    }
    const submitBtn = form.querySelector('button[type="submit"]');
    try {
      if (submitBtn && !submitBtn.disabled) form.requestSubmit(submitBtn);
      else form.requestSubmit();
    } catch (err) {
      return { attempted: false, detail: `requestSubmit threw: ${String(err?.message || err)}` };
    }
    dlog('SEND_CLICKED', { method: 'requestSubmit' });
    return { attempted: true };
  }

  async function strategyEnter() {
    const { el: input } = findInput();
    if (!input) return { attempted: false, detail: 'no composer' };
    focusInput(input);
    const opts = {
      key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: 13,
      bubbles: true, cancelable: true, composed: true, view: window,
    };
    input.dispatchEvent(new KeyboardEvent('keydown', opts));
    input.dispatchEvent(new KeyboardEvent('keypress', opts));
    input.dispatchEvent(new KeyboardEvent('keyup', opts));
    dlog('ENTER_SENT', {});
    return { attempted: true };
  }

  const STRATEGIES = {
    click: strategyClick,
    requestSubmit: strategyRequestSubmit,
    enter: strategyEnter,
  };

  // --- orchestration --------------------------------------------------------
  async function prepare(prompt, marker) {
    const input = await waitIdle();
    dlog('IDLE_CONFIRMED', { input_selector: findInput().selector });

    const beforeUserCount = userMessages().length;
    const beforeAssistant = assistantMessages().length;

    // Baseline for the marker test. If the marker were somehow already on
    // screen, no submit could be credited -- a stale marker must never be able
    // to manufacture a false verification.
    CTX.marker_before = userMessages().some(n => nodeText(n).includes(marker));
    if (CTX.marker_before) {
      dlog('MARKER_ALREADY_PRESENT', { detail: 'marker visible before submit; wake cannot be credited' });
      throw new Error('marker already present in conversation; refusing to credit this wake');
    }

    clearInput(input);
    await sleep(120);

    const r = await injectPrompt(input, prompt);
    const send = findSend();
    dlog('PROMPT_INJECTED', {
      method: r.method || 'FAILED',
      composer_after: norm(r.after).slice(0, 160),
      send_selector: send.selector,
      send_disabled: send.el ? !isEnabled(send.el) : 'no-button',
    });
    if (!r.method) {
      throw new Error(`prompt did not enter composer (readback="${norm(r.after).slice(0, 80)}")`);
    }

    focusInput(input);
    return { beforeUserCount, beforeAssistant, injectMethod: r.method };
  }

  async function runStrategies(prompt, marker, order, beforeUserCount) {
    for (const name of order) {
      const run = STRATEGIES[name];
      if (!run) continue;

      // Re-establish composer contents if a previous attempt cleared them.
      const { el: input } = findInput();
      if (input && squash(readInput(input)) !== squash(prompt)) {
        dlog('COMPOSER_REFILL', { strategy: name });
        await injectPrompt(input, prompt);
        await sleep(150);
      }

      let attempt;
      try {
        attempt = await run();
      } catch (err) {
        dlog('WAKE_STRATEGY_ERROR', { strategy: name, error: String(err?.message || err) });
        continue;
      }
      if (!attempt.attempted) {
        dlog('WAKE_STRATEGY_SKIPPED', { strategy: name, detail: attempt.detail });
        continue;
      }

      const v = await verify(marker, beforeUserCount, 8000);
      if (v.verified) {
        dlog('MARKER_VERIFIED', { strategy: name, ...v });
        return { verified: true, strategy: name, ...v };
      }
      dlog('WAKE_STRATEGY_FAILED', { strategy: name, ...v });
    }
    return { verified: false };
  }

  async function runWake(msg) {
    CTX = { wake_id: String(msg.eventId || ''), marker_before: false };
    const prompt = String(msg.prompt || '');
    const marker = String(msg.marker || '');
    if (!marker) throw new Error('wake marker is required');

    const prep = await prepare(prompt, marker);
    const result = await runStrategies(prompt, marker, ['click', 'requestSubmit', 'enter'], prep.beforeUserCount);
    return { ...prep, ...result };
  }

  // --- message surface ------------------------------------------------------
  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg !== 'object') return;

    if (msg.type === 'GPTLOOP_PING') {
      sendResponse({ ok: true, version: VERSION, href: location.href });
      return;
    }

    if (msg.type === 'GPTLOOP_WAKE') {
      runWake(msg)
        .then(result => sendResponse({ ok: true, ...result }))
        .catch(err => sendResponse({ ok: false, verified: false, error: String(err?.message || err) }));
      return true; // async response
    }
  });

  dlog('CONTENT_READY', { detail: `v${VERSION}` });
})();
