/** Diagnostics panel. Shows delivery state without ever revealing the token. */

function set(id, text, cls) {
  const el = document.getElementById(id);
  el.textContent = text ?? '—';
  el.className = 'v' + (cls ? ' ' + cls : '');
}

function shortEvent(id) {
  if (!id) return '—';
  return id.length > 28 ? '…' + id.slice(-26) : id;
}

async function refresh() {
  const { gptloop_status: status = {} } = await chrome.storage.local.get('gptloop_status');
  const { targetUrl } = await chrome.storage.local.get('targetUrl');

  set('target', targetUrl ? new URL(targetUrl).pathname : 'not configured', targetUrl ? 'ok' : 'bad');
  set('submitted', shortEvent(status.lastSubmittedEvent), 'idle');
  set('verified', shortEvent(status.lastVerifiedEvent), status.lastVerifiedEvent ? 'ok' : 'idle');
  set('pending', shortEvent(status.pendingEvent), status.pendingEvent ? 'bad' : 'idle');
  set('error', status.lastError || 'none', status.lastError ? 'bad' : 'ok');

  chrome.runtime.sendMessage({ type: 'GPTLOOP_HEALTH' }, response => {
    if (chrome.runtime.lastError || !response || !response.ok) {
      const detail = response?.error || chrome.runtime.lastError?.message || 'unreachable';
      set('daemon', detail.slice(0, 60), 'bad');
      set('runner', '—', 'idle');
      return;
    }
    const health = response.health || {};
    set('daemon', `up (${health.daemon_version || '?'}) · ${health.pending_count ?? 0} pending`, 'ok');
    if (health.runner_online === true) set('runner', 'online', 'ok');
    else if (health.runner_online === false) set('runner', 'offline', 'bad');
    else set('runner', 'not supervised', 'idle');
  });
}

document.getElementById('poll').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'GPTLOOP_POLL_NOW' }, () => setTimeout(refresh, 600));
});

document.getElementById('options').addEventListener('click', () => {
  chrome.runtime.openOptionsPage();
});

refresh();
setInterval(refresh, 3000);
