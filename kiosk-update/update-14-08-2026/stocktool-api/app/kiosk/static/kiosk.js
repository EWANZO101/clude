const Kiosk = (function () {

  function keepFocused(input) {
    // A USB/Bluetooth barcode scanner in keyboard-wedge mode just types
    // into whatever has focus, then sends Enter. Refocusing aggressively
    // means a shop-floor operator never has to tap the field first.
    const refocus = () => { if (document.activeElement !== input) input.focus(); };
    refocus();
    document.addEventListener('click', refocus);
    document.addEventListener('touchend', refocus);
    setInterval(refocus, 800);
  }

  // ── Scanner test ─────────────────────────────────────────────────────
  // A self-contained "is the handheld scanner actually working" check.
  // Opens a modal, arms a short window, and reports 100% the instant ANY
  // scan comes through the shared #scanInput field (it doesn't need to
  // match a real badge/item — this tests the keyboard-wedge mechanism
  // itself, not barcode validity), or 0% if nothing arrives in time.
  const SCANNER_TEST_TIMEOUT_MS = 8000;
  let scannerTestActive = false;
  let scannerTestTimer = null;
  let scannerTestCountdownTimer = null;

  function feedScannerTest(code) {
    // Called first by every screen's Enter-key handler. Returns true if
    // an active test consumed this scan — callers must not also treat
    // it as a real badge/item scan in that case.
    if (!scannerTestActive) return false;
    clearTimeout(scannerTestTimer);
    clearInterval(scannerTestCountdownTimer);
    scannerTestActive = false;
    _showScannerTestResult(true, code);
    return true;
  }

  function _showScannerTestResult(success, code) {
    const title = document.getElementById('scannerTestTitle');
    const subtitle = document.getElementById('scannerTestSubtitle');
    const percent = document.getElementById('scannerTestPercent');
    const countdown = document.getElementById('scannerTestCountdown');
    const retryBtn = document.getElementById('scannerTestRetryBtn');
    if (!title) return;

    countdown.textContent = '';
    retryBtn.style.display = success ? 'none' : 'block';

    if (success) {
      title.textContent = 'Scanner Working';
      subtitle.textContent = `Received: ${code}`;
      percent.textContent = '100%';
      percent.className = 'scanner-test-result success';
    } else {
      title.textContent = 'No Scan Detected';
      subtitle.textContent = 'Nothing came through in time. Check the scanner and try again.';
      percent.textContent = '0%';
      percent.className = 'scanner-test-result fail';
    }
  }

  function startScannerTest() {
    const modal = document.getElementById('scannerTestModal');
    const title = document.getElementById('scannerTestTitle');
    const subtitle = document.getElementById('scannerTestSubtitle');
    const percent = document.getElementById('scannerTestPercent');
    const countdown = document.getElementById('scannerTestCountdown');
    const retryBtn = document.getElementById('scannerTestRetryBtn');
    if (!modal) return;

    title.textContent = 'Testing Scanner…';
    subtitle.textContent = 'Point the handheld scanner at any barcode and scan it.';
    percent.textContent = '—';
    percent.className = 'scanner-test-result pending';
    retryBtn.style.display = 'none';

    modal.classList.add('open');

    scannerTestActive = true;
    let remaining = Math.ceil(SCANNER_TEST_TIMEOUT_MS / 1000);
    countdown.textContent = `Waiting… ${remaining}s`;
    clearInterval(scannerTestCountdownTimer);
    scannerTestCountdownTimer = setInterval(() => {
      remaining -= 1;
      if (remaining > 0) countdown.textContent = `Waiting… ${remaining}s`;
    }, 1000);

    clearTimeout(scannerTestTimer);
    scannerTestTimer = setTimeout(() => {
      if (!scannerTestActive) return;
      scannerTestActive = false;
      clearInterval(scannerTestCountdownTimer);
      _showScannerTestResult(false);
    }, SCANNER_TEST_TIMEOUT_MS);
  }

  function initScannerTest() {
    const btn = document.getElementById('testScannerBtn');
    const modal = document.getElementById('scannerTestModal');
    const closeBtn = document.getElementById('scannerTestCloseBtn');
    const retryBtn = document.getElementById('scannerTestRetryBtn');
    if (!btn || !modal) return;

    btn.addEventListener('click', startScannerTest);
    closeBtn.addEventListener('click', () => {
      scannerTestActive = false;
      clearTimeout(scannerTestTimer);
      clearInterval(scannerTestCountdownTimer);
      modal.classList.remove('open');
    });
    retryBtn.addEventListener('click', startScannerTest);
  }

  async function postJSON(url, body) {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* ignore */ }
    return { status: res.status, data };
  }

  // ── Idle screen ──────────────────────────────────────────────────────
  function initIdleScreen() {
    const input = document.getElementById('scanInput');
    const errorBox = document.getElementById('idleError');
    keepFocused(input);

    input.addEventListener('keydown', async (e) => {
      if (e.key !== 'Enter') return;
      const code = input.value.trim();
      input.value = '';
      if (!code) return;

      if (feedScannerTest(code)) return;

      errorBox.style.display = 'none';
      const { data } = await postJSON('/api/scan-badge', { code });
      if (data.ok) {
        window.location.reload();
      } else {
        errorBox.textContent = data.error || 'Badge not recognised.';
        errorBox.style.display = 'block';
        setTimeout(() => { errorBox.style.display = 'none'; }, 3500);
      }
    });
  }

  // ── Dashboard screen ─────────────────────────────────────────────────
  let idleTimer = null;
  let idleDeadline = 0;
  let idleTimeoutSeconds = 60;
  let _dashShowMessage = null; // set by initDashboard, callable from SSE handlers

  function resetIdleTimer() {
    idleDeadline = Date.now() + idleTimeoutSeconds * 1000;
  }

  function startIdleLoop() {
    const bar = document.getElementById('idleProgressBar');
    resetIdleTimer();
    idleTimer = setInterval(async () => {
      const remainingMs = idleDeadline - Date.now();
      const pct = Math.max(0, Math.min(100, (remainingMs / (idleTimeoutSeconds * 1000)) * 100));
      if (bar) bar.style.width = pct + '%';
      if (remainingMs <= 0) {
        clearInterval(idleTimer);
        await postJSON('/api/logout', {});
        window.location.reload();
      }
    }, 250);
  }

  function initDashboard(idleTimeoutSecondsArg) {
    idleTimeoutSeconds = idleTimeoutSecondsArg || 60;
    const input = document.getElementById('scanInput');
    const messageBox = document.getElementById('dashMessage');
    const doneBtn = document.getElementById('doneBtn');

    keepFocused(input);
    startIdleLoop();

    ['click', 'touchend', 'keydown'].forEach((evt) =>
      document.addEventListener(evt, resetIdleTimer)
    );

    function showMessage(text) {
      messageBox.textContent = text;
      messageBox.style.display = 'block';
      setTimeout(() => { messageBox.style.display = 'none'; }, 4000);
    }
    _dashShowMessage = showMessage;

    // ── Scan-counting gesture ──────────────────────────────────────────
    // Scanning an item removes 1 unit by default — no keypad needed.
    // Scanning the SAME item three times in quick succession (within
    // SCAN_GESTURE_WINDOW_MS of each other) adds 1 unit instead.
    const SCAN_GESTURE_WINDOW_MS = 900;
    let pending = null; // { code, item, count, timer }

    async function finalizePending() {
      if (!pending) return;
      clearTimeout(pending.timer);
      const { item, count } = pending;
      pending = null;

      const isAdd = count >= 3;
      const endpoint = isAdd ? '/api/quick-add' : '/api/quick-remove';
      const { data } = await postJSON(endpoint, { item_id: item.id, quantity: 1 });
      if (!data.ok) {
        showMessage(data.error || 'Could not update stock.');
        return;
      }
      showMessage(
        isAdd
          ? `Added 1 — ${data.item.name} now at ${data.item.quantity}.`
          : `Removed 1 — ${data.item.name} now at ${data.item.quantity}.`
      );
    }

    function registerItemScan(item) {
      if (pending && pending.code === item.__scanCode) {
        pending.count += 1;
      } else {
        if (pending) finalizePending();
        pending = { code: item.__scanCode, item, count: 1 };
      }
      clearTimeout(pending.timer);
      if (pending.count >= 3) {
        finalizePending();
      } else {
        showMessage(`${item.name}: scan ${pending.count}/3 to add — wait to remove 1.`);
        pending.timer = setTimeout(finalizePending, SCAN_GESTURE_WINDOW_MS);
      }
    }

    input.addEventListener('keydown', async (e) => {
      if (e.key !== 'Enter') return;
      const code = input.value.trim();
      input.value = '';
      if (!code) return;
      resetIdleTimer();

      if (feedScannerTest(code)) return;

      const { data } = await postJSON('/api/scan-code', { code });
      if (!data.ok) {
        showMessage(data.error || 'Scan not recognised.');
        return;
      }
      if (data.type === 'user_switch') {
        if (pending) finalizePending();
        window.location.reload();
        return;
      }
      if (data.type === 'item') {
        data.item.__scanCode = code;
        registerItemScan(data.item);
        return;
      }
      // tool / project — read-only info message
      if (pending) finalizePending();
      showMessage(data.message || 'Scanned.');
    });

    doneBtn.addEventListener('click', async () => {
      if (pending) await finalizePending();
      await postJSON('/api/logout', {});
      window.location.reload();
    });

    initQuantityModal(resetIdleTimer, showMessage);
  }

  // ── Quantity modal (manual entry, opened via the item's info screen
  //    for anything other than the default ±1 scan gesture) ────────────
  let currentItem = null;
  let qtyValue = '';

  function openQuantityModal(item) {
    currentItem = item;
    qtyValue = '';
    document.getElementById('qtyItemName').textContent = item.name;
    document.getElementById('qtyItemStock').textContent =
      `Current stock: ${item.quantity}${item.unit ? ' ' + item.unit : ''}`;
    document.getElementById('qtyDisplay').textContent = '0';
    document.getElementById('quantityModal').classList.add('open');
  }

  function closeQuantityModal() {
    document.getElementById('quantityModal').classList.remove('open');
    currentItem = null;
    qtyValue = '';
  }

  function initQuantityModal(resetIdleTimer, showMessage) {
    document.querySelectorAll('.qty-key').forEach((btn) => {
      btn.addEventListener('click', () => {
        resetIdleTimer();
        const key = btn.getAttribute('data-key');
        if (key === 'clear') {
          qtyValue = '';
        } else if (key === 'back') {
          qtyValue = qtyValue.slice(0, -1);
        } else if (qtyValue.length < 5) {
          qtyValue += key;
        }
        document.getElementById('qtyDisplay').textContent = qtyValue || '0';
      });
    });

    document.getElementById('qtyCancelBtn').addEventListener('click', () => {
      resetIdleTimer();
      closeQuantityModal();
    });

    document.getElementById('qtyRemoveBtn').addEventListener('click', async () => {
      resetIdleTimer();
      const quantity = parseInt(qtyValue, 10);
      if (!currentItem || !quantity || quantity <= 0) {
        showMessage('Enter a quantity greater than zero.');
        return;
      }
      const { data } = await postJSON('/api/quick-remove', {
        item_id: currentItem.id, quantity,
      });
      closeQuantityModal();
      if (data.ok) {
        showMessage(`Removed ${quantity} — ${data.item.name} now at ${data.item.quantity}.`);
      } else {
        showMessage(data.error || 'Could not remove stock.');
      }
    });
  }

  // ── Phone pairing (Phase 2) ─────────────────────────────────────────
  let pairingRotateTimer = null;
  let pairingCountdownTimer = null;

  async function refreshPairingQr() {
    const res = await fetch('/kiosk/api/pairing/new');
    const data = await res.json();
    const img = document.getElementById('pairingQrImage');
    if (img) img.src = data.qr_image_url + '?t=' + Date.now();

    let remaining = data.expires_in;
    const countdownEl = document.getElementById('pairingCountdown');
    clearInterval(pairingCountdownTimer);
    pairingCountdownTimer = setInterval(() => {
      remaining -= 1;
      if (countdownEl) countdownEl.textContent = `Refreshes in ${Math.max(remaining, 0)}s`;
      if (remaining <= 0) clearInterval(pairingCountdownTimer);
    }, 1000);

    return data.expires_in;
  }

  function initPairing() {
    const btn = document.getElementById('pairPhoneBtn');
    const modal = document.getElementById('pairingModal');
    const closeBtn = document.getElementById('pairingCloseBtn');
    if (!btn || !modal) return;

    btn.addEventListener('click', async () => {
      modal.classList.add('open');
      const expiresIn = await refreshPairingQr();
      clearInterval(pairingRotateTimer);
      pairingRotateTimer = setInterval(refreshPairingQr, expiresIn * 1000);
    });

    closeBtn.addEventListener('click', () => {
      modal.classList.remove('open');
      clearInterval(pairingRotateTimer);
      clearInterval(pairingCountdownTimer);
    });
  }

  // ── Live updates from a paired phone (Phase 2) ──────────────────────
  function initLiveUpdates({ onLogin, onItemScan, onMessage } = {}) {
    if (typeof EventSource === 'undefined') return;
    const source = new EventSource('/kiosk/api/stream');
    source.addEventListener('login', (e) => {
      if (onLogin) onLogin(JSON.parse(e.data));
    });
    source.addEventListener('item_scan', (e) => {
      const payload = JSON.parse(e.data);
      if (onItemScan) onItemScan(payload.item);
    });
    source.addEventListener('message', (e) => {
      const payload = JSON.parse(e.data);
      if (onMessage) onMessage(payload.message);
    });
    // Reconnect automatically is EventSource's default behavior on drop;
    // nothing extra needed here.
  }

  function openQuantityModalExternal(item) {
    openQuantityModal(item);
  }

  function showDashMessageExternal(msg) {
    if (_dashShowMessage) _dashShowMessage(msg);
  }

  return {
    initIdleScreen, initDashboard, initPairing, initLiveUpdates, initScannerTest,
    openQuantityModalExternal, showDashMessageExternal,
  };
})();
