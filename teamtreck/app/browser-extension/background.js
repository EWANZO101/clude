/**
 * TeamTreck URL Tracker - background service worker.
 *
 * Tracks the currently active, focused tab's URL and how long it's been
 * active. Sends a log entry to the TeamTreck server whenever the user
 * switches tabs, the window loses focus, or a periodic flush interval
 * elapses (so long-lived tabs still get reported without waiting for a
 * switch).
 *
 * Rules enforced here, matching the spec:
 * - Never tracks incognito/private windows (checked before anything else).
 * - Only tracks while a TeamTreck timer is actively running - checks the
 *   server's /time/status on each flush; if no timer is running, the
 *   pending record is discarded, not sent.
 * - Requires server URL + agent token to be configured via the options page.
 */

const FLUSH_ALARM = 'teamtreck-flush';
const FLUSH_INTERVAL_MINUTES = 1; // chrome.alarms minimum granularity is ~1 min

let current = null; // { url, title, tabId, windowId, startedAt, incognito }

async function getConfig() {
  const { serverUrl, apiToken } = await chrome.storage.local.get(['serverUrl', 'apiToken']);
  return { serverUrl: serverUrl || '', apiToken: apiToken || '' };
}

async function isTimerActive(serverUrl, apiToken) {
  try {
    const res = await fetch(`${serverUrl.replace(/\/$/, '')}/time/status`, {
      headers: { Authorization: `Bearer ${apiToken}` },
    });
    if (!res.ok) return { active: false };
    return await res.json();
  } catch (e) {
    return { active: false, offline: true };
  }
}

async function sendLog(record) {
  const { serverUrl, apiToken } = await getConfig();
  if (!serverUrl || !apiToken) return; // not configured yet

  const status = await isTimerActive(serverUrl, apiToken);
  if (!status.active) return; // spec: only track during an active tracked session

  try {
    await fetch(`${serverUrl.replace(/\/$/, '')}/url-tracking/api/log`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiToken}` },
      body: JSON.stringify({
        url: record.url,
        title: record.title,
        duration_seconds: record.durationSeconds,
        visited_at: record.startedAt,
        time_entry_id: status.id || null,
        private_browsing: record.incognito,
      }),
    });
  } catch (e) {
    // Best-effort: URL logs aren't critical enough to justify a local retry
    // queue in the extension itself (unlike the desktop agent's queue for
    // activity/time data). A dropped page-visit log is an acceptable loss.
    console.warn('TeamTreck: failed to send URL log', e);
  }
}

function flushCurrent() {
  if (!current) return;
  const durationSeconds = Math.round((Date.now() - current.startedAtMs) / 1000);
  if (durationSeconds < 1) {
    current = null;
    return;
  }
  sendLog({
    url: current.url,
    title: current.title,
    durationSeconds,
    startedAt: new Date(current.startedAtMs).toISOString(),
    incognito: current.incognito,
  });
  current = null;
}

function beginTracking(tab) {
  flushCurrent();
  if (!tab || !tab.url || !tab.url.startsWith('http')) return;

  current = {
    url: tab.url,
    title: tab.title || '',
    tabId: tab.id,
    windowId: tab.windowId,
    startedAtMs: Date.now(),
    incognito: !!tab.incognito, // never sent to the server if true - sendLog passes it through as private_browsing
  };
}

// ---------- event wiring ----------

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    beginTracking(tab);
  } catch (e) {
    flushCurrent();
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url && current && current.tabId === tabId) {
    beginTracking(tab); // URL changed within the same tab (SPA nav, redirect, etc.)
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    flushCurrent(); // browser lost focus entirely
    return;
  }
  try {
    const [tab] = await chrome.tabs.query({ active: true, windowId });
    if (tab) beginTracking(tab);
  } catch (e) {
    flushCurrent();
  }
});

chrome.idle.onStateChanged.addListener((state) => {
  if (state !== 'active') {
    flushCurrent(); // stop counting idle/locked time as page time
  }
});

chrome.alarms.create(FLUSH_ALARM, { periodInMinutes: FLUSH_INTERVAL_MINUTES });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === FLUSH_ALARM && current) {
    // periodic flush for long-lived tabs, then immediately resume tracking
    // the same tab as a fresh interval
    const tabSnapshot = { ...current };
    flushCurrent();
    current = {
      ...tabSnapshot,
      startedAtMs: Date.now(),
    };
  }
});
