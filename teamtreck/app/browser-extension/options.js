const serverUrlInput = document.getElementById('serverUrl');
const apiTokenInput = document.getElementById('apiToken');
const saveButton = document.getElementById('save');
const statusEl = document.getElementById('status');

async function load() {
  const { serverUrl, apiToken } = await chrome.storage.local.get(['serverUrl', 'apiToken']);
  if (serverUrl) serverUrlInput.value = serverUrl;
  if (apiToken) apiTokenInput.value = apiToken;
}

async function save() {
  const serverUrl = serverUrlInput.value.trim().replace(/\/$/, '');
  const apiToken = apiTokenInput.value.trim();

  if (!serverUrl || !apiToken) {
    statusEl.textContent = 'Both fields are required.';
    statusEl.style.color = '#dc2626';
    return;
  }

  await chrome.storage.local.set({ serverUrl, apiToken });

  // quick connectivity check
  try {
    const res = await fetch(`${serverUrl}/sync/api/ping`, {
      headers: { Authorization: `Bearer ${apiToken}` },
    });
    if (res.ok) {
      statusEl.textContent = 'Saved and connected successfully.';
      statusEl.style.color = '#059669';
    } else {
      statusEl.textContent = 'Saved, but the token or URL looks wrong (server responded with an error).';
      statusEl.style.color = '#d97706';
    }
  } catch (e) {
    statusEl.textContent = 'Saved, but could not reach the server to verify.';
    statusEl.style.color = '#d97706';
  }
}

saveButton.addEventListener('click', save);
load();
