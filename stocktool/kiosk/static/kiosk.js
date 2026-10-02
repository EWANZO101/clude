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

  return { initIdleScreen, initDashboard };
})();
