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

    input.addEventListener('keydown', async (e) => {
      if (e.key !== 'Enter') return;
      const code = input.value.trim();
      input.value = '';
      if (!code) return;
      resetIdleTimer();

      const { data } = await postJSON('/api/scan-code', { code });
      if (!data.ok) {
        showMessage(data.error || 'Scan not recognised.');
        return;
      }
      if (data.type === 'user_switch') {
        window.location.reload();
        return;
      }
      if (data.type === 'item') {
        openQuantityModal(data.item);
        return;
      }
      // tool / project — read-only info message
      showMessage(data.message || 'Scanned.');
    });

    doneBtn.addEventListener('click', async () => {
      await postJSON('/api/logout', {});
      window.location.reload();
    });

    initQuantityModal(resetIdleTimer, showMessage);
  }

  // ── Quantity modal ───────────────────────────────────────────────────
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
    initIdleScreen, initDashboard, initPairing, initLiveUpdates,
    openQuantityModalExternal, showDashMessageExternal,
  };
})();
