/**
 * gpt-loop wake -- MV3 service worker.
 *
 * Long-polls the local wake daemon, drives the target ChatGPT conversation
 * through content.js, and only acknowledges an event once the content script
 * has OBSERVED the marker in a user message.
 *
 * Exactly-once rests on two rules:
 *   1. This worker never advances any cursor of its own. The daemon owns
 *      delivery state; a claim is a lease that expires if we die.
 *   2. `verified` is reported only on observed delivery. Anything else is
 *      reported as `failed`, which re-queues the SAME event.
 *
 * A service-worker restart is therefore always safe: at worst the in-flight
 * event is delivered once, later.
 */

const DEFAULTS = {
  baseUrl: 'http://127.0.0.1:8777',
  token: '',
  targetUrl: '',
  enabled: true,
};

const POLL_ALARM = 'gptloop-poll';
const STATUS_KEY = 'gptloop_status';

// Guards against two concurrent poll cycles inside one worker instance.
let cycleRunning = false;

// --- configuration -----------------------------------------------------------

/**
 * Seeds configuration from a bundled `config.local.json` the first time the
 * extension runs.
 *
 * Loading an unpacked extension is an unavoidable manual step, but pasting a
 * token and a conversation URL afterwards is not: the installer writes that file
 * into the staged extension directory. It is gitignored and never committed.
 * Values already in chrome.storage always win, so this never clobbers a choice
 * made in the options page.
 */
async function seedConfigIfEmpty() {
  const stored = await chrome.storage.local.get(['token', 'targetUrl']);
  if (stored.token && stored.targetUrl) return;

  try {
    const response = await fetch(chrome.runtime.getURL('config.local.json'));
    if (!response.ok) return;
    const seed = await response.json();
    const patch = {};
    for (const key of ['token', 'targetUrl', 'baseUrl']) {
      if (seed[key] && !stored[key]) patch[key] = seed[key];
    }
    if (Object.keys(patch).length) {
      await chrome.storage.local.set(patch);
    }
  } catch (_) {
    // No seed file is a normal, supported state.
  }
}

async function getConfig() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  return { ...DEFAULTS, ...stored };
}

async function setStatus(patch) {
  const current = (await chrome.storage.local.get(STATUS_KEY))[STATUS_KEY] || {};
  const next = { ...current, ...patch, updatedAt: Date.now() };
  await chrome.storage.local.set({ [STATUS_KEY]: next });
  return next;
}

// --- daemon client -----------------------------------------------------------

async function daemon(config, path, { method = 'GET', body = null, timeoutMs = 30000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${config.baseUrl}${path}`, {
      method,
      headers: {
        'X-GPTLoop-Token': config.token,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
      cache: 'no-store',
    });
    const text = await response.text();
    let parsed = null;
    try { parsed = JSON.parse(text); } catch (_) {}
    if (!response.ok) {
      throw new Error(`daemon ${path} -> HTTP ${response.status}${parsed?.error ? `: ${parsed.error}` : ''}`);
    }
    return parsed;
  } finally {
    clearTimeout(timer);
  }
}

async function pushLog(config, entries) {
  try {
    await daemon(config, '/log', { method: 'POST', body: { entries }, timeoutMs: 5000 });
  } catch (_) {
    // Diagnostics must never break delivery.
  }
}

// --- wake message ------------------------------------------------------------

/**
 * The marker is the unique, verifiable substring. The surrounding prompt is
 * deliberately compact: it tells the brain which issue to read, nothing more.
 */
function buildWake(event) {
  const marker = `[GPT_LOOP_WAKE event=${event.event_id}]`;
  const parts = [
    `go ${marker}`,
    `issue=${event.issue_number ?? '?'}`,
    `action=${event.action ?? '?'}`,
    `status=${event.status ?? (event.ok ? 'success' : 'unknown')}`,
  ];
  return { marker, prompt: parts.join(' ') };
}

// --- tab handling ------------------------------------------------------------

async function findOrOpenTab(config) {
  if (!config.targetUrl) throw new Error('no target conversation configured');

  const tabs = await chrome.tabs.query({ url: 'https://chatgpt.com/*' });
  // Prefer an exact match on the configured conversation.
  let tab = tabs.find(t => t.url && t.url.startsWith(config.targetUrl));
  if (!tab) {
    tab = await chrome.tabs.create({ url: config.targetUrl, active: true });
  }

  // ChatGPT throttles background tabs heavily, and a hidden tab's composer may
  // never settle. Activating is required for reliable submission.
  try {
    await chrome.tabs.update(tab.id, { active: true });
    await chrome.windows.update(tab.windowId, { focused: true });
  } catch (_) {}

  await waitForTabReady(tab.id);
  return tab;
}

async function waitForTabReady(tabId, timeoutMs = 60000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const tab = await chrome.tabs.get(tabId);
    if (tab.status === 'complete') return tab;
    await new Promise(r => setTimeout(r, 300));
  }
  throw new Error('target tab did not finish loading');
}

async function ensureContentScript(tabId) {
  try {
    const pong = await chrome.tabs.sendMessage(tabId, { type: 'GPTLOOP_PING' });
    if (pong && pong.ok) return pong;
  } catch (_) {
    // Not injected yet (or the worker restarted after a navigation).
  }
  await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
  await new Promise(r => setTimeout(r, 400));
  return chrome.tabs.sendMessage(tabId, { type: 'GPTLOOP_PING' });
}

// --- delivery ----------------------------------------------------------------

async function deliver(config, event) {
  const { marker, prompt } = buildWake(event);
  await setStatus({ lastClaimedEvent: event.event_id, lastError: '' });

  const tab = await findOrOpenTab(config);
  await ensureContentScript(tab.id);

  // Report `submitted` before touching the DOM. If we die mid-submit, the
  // daemon's lease expires and the same event is retried -- never dropped.
  await daemon(config, '/ack', {
    method: 'POST',
    body: { event_id: event.event_id, state: 'submitted' },
  });
  await setStatus({ lastSubmittedEvent: event.event_id });

  const result = await chrome.tabs.sendMessage(tab.id, {
    type: 'GPTLOOP_WAKE',
    eventId: event.event_id,
    marker,
    prompt,
  });

  if (result && result.verified) {
    await daemon(config, '/ack', {
      method: 'POST',
      body: { event_id: event.event_id, state: 'verified' },
    });
    await setStatus({
      lastVerifiedEvent: event.event_id,
      lastVerifiedAt: Date.now(),
      lastStrategy: result.strategy || '',
      lastError: '',
    });
    await pushLog(config, [{
      stage: 'WAKE_VERIFIED', side: 'background', wake_id: event.event_id, strategy: result.strategy,
    }]);
    return true;
  }

  const error = (result && (result.error || 'submission was not verified')) || 'no response from page';
  await daemon(config, '/ack', {
    method: 'POST',
    body: { event_id: event.event_id, state: 'failed', error },
  });
  await setStatus({ lastError: error, lastFailedEvent: event.event_id });
  await pushLog(config, [{
    stage: 'WAKE_FAILED', side: 'background', wake_id: event.event_id, error,
  }]);
  return false;
}

// --- poll cycle --------------------------------------------------------------

async function pollOnce() {
  if (cycleRunning) return;
  cycleRunning = true;
  try {
    const config = await getConfig();
    if (!config.enabled) {
      await setStatus({ daemonReachable: null, note: 'wake disabled' });
      return;
    }
    if (!config.token) {
      await setStatus({ daemonReachable: false, lastError: 'no daemon token configured' });
      return;
    }

    let claimed;
    try {
      claimed = await daemon(config, '/next?timeout=20', { timeoutMs: 30000 });
      await setStatus({ daemonReachable: true });
    } catch (err) {
      await setStatus({ daemonReachable: false, lastError: String(err?.message || err) });
      return;
    }

    const event = claimed && claimed.event;
    if (!event) {
      await setStatus({ pendingEvent: null });
      return;
    }
    await setStatus({ pendingEvent: event.event_id });

    try {
      await deliver(config, event);
    } catch (err) {
      const message = String(err?.message || err);
      // Any unexpected failure re-queues the event rather than consuming it.
      try {
        await daemon(config, '/ack', {
          method: 'POST',
          body: { event_id: event.event_id, state: 'failed', error: message },
        });
      } catch (_) {}
      await setStatus({ lastError: message, lastFailedEvent: event.event_id });
    }
  } finally {
    cycleRunning = false;
  }
}

// --- lifecycle ---------------------------------------------------------------
// MV3 workers are evicted aggressively, so the alarm is the real heartbeat.
// One minute is the shortest interval Chrome honours reliably.

function scheduleAlarm() {
  chrome.alarms.create(POLL_ALARM, { periodInMinutes: 1 });
}

chrome.runtime.onInstalled.addListener(() => { seedConfigIfEmpty().then(() => { scheduleAlarm(); pollOnce(); }); });
chrome.runtime.onStartup.addListener(() => { seedConfigIfEmpty().then(() => { scheduleAlarm(); pollOnce(); }); });
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === POLL_ALARM) pollOnce();
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || typeof msg !== 'object') return;

  if (msg.type === 'GPTLOOP_LOG') {
    getConfig().then(config => pushLog(config, [msg.entry]));
    return;
  }

  if (msg.type === 'GPTLOOP_POLL_NOW') {
    pollOnce().then(() => sendResponse({ ok: true })).catch(err => sendResponse({ ok: false, error: String(err) }));
    return true;
  }

  if (msg.type === 'GPTLOOP_HEALTH') {
    (async () => {
      try {
        const config = await getConfig();
        const health = await daemon(config, '/health', { timeoutMs: 5000 });
        sendResponse({ ok: true, health, config: { ...config, token: config.token ? '<set>' : '' } });
      } catch (err) {
        sendResponse({ ok: false, error: String(err?.message || err) });
      }
    })();
    return true;
  }
});

seedConfigIfEmpty().then(() => { scheduleAlarm(); pollOnce(); });
