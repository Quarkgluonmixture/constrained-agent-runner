/**
 * Local configuration only. Nothing here is ever committed: the conversation
 * URL is private and the token is a credential.
 */

const FIELDS = ['targetUrl', 'baseUrl', 'token', 'enabled'];

async function load() {
  const stored = await chrome.storage.local.get(FIELDS);
  document.getElementById('targetUrl').value = stored.targetUrl || '';
  document.getElementById('baseUrl').value = stored.baseUrl || 'http://127.0.0.1:8777';
  document.getElementById('enabled').checked = stored.enabled !== false;
  // The token is deliberately not echoed back into the form.
  document.getElementById('token').placeholder = stored.token
    ? 'stored — leave blank to keep'
    : 'paste from %LOCALAPPDATA%\\GPTLoop\\token.txt';
}

document.getElementById('save').addEventListener('click', async () => {
  const patch = {
    targetUrl: document.getElementById('targetUrl').value.trim(),
    baseUrl: document.getElementById('baseUrl').value.trim() || 'http://127.0.0.1:8777',
    enabled: document.getElementById('enabled').checked,
  };
  const token = document.getElementById('token').value.trim();
  if (token) patch.token = token;

  await chrome.storage.local.set(patch);
  document.getElementById('token').value = '';
  document.getElementById('saved').textContent = 'saved';
  setTimeout(() => { document.getElementById('saved').textContent = ''; }, 1500);
  load();
});

load();
