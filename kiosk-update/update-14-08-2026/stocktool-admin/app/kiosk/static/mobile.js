(function () {
  const API = {
    login: `/kiosk/mobile/${PAIRING_ID}/login`,
    scan: `/kiosk/mobile/${PAIRING_ID}/scan`,
  };

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

  const loginStep = document.getElementById('loginStep');
  const scanStep = document.getElementById('scanStep');
  const loginError = document.getElementById('loginError');
  const scanResult = document.getElementById('scanResult');
  const connectedUsername = document.getElementById('connectedUsername');

  function showLoginError(msg) {
    loginError.textContent = msg;
    loginError.style.display = 'block';
    setTimeout(() => { loginError.style.display = 'none'; }, 3500);
  }

  function showScanResult(msg) {
    scanResult.textContent = msg;
    scanResult.style.display = 'block';
    setTimeout(() => { scanResult.style.display = 'none'; }, 2500);
  }

  async function attemptLogin(code) {
    const { data } = await postJSON(API.login, { code });
    if (data.ok) {
      connectedUsername.textContent = data.user.username;
      loginStep.style.display = 'none';
      scanStep.style.display = 'block';
      startRelayScanner();
    } else {
      showLoginError(data.error || 'Could not connect.');
    }
    return data.ok;
  }

  document.getElementById('manualBadgeBtn').addEventListener('click', async () => {
    const input = document.getElementById('manualBadgeInput');
    const code = input.value.trim();
    if (!code) return;
    input.value = '';
    await attemptLogin(code);
  });

  // ── Camera-based badge scan (step 1) ──────────────────────────────────
  let badgeScanner = null;

  document.getElementById('scanBadgeBtn').addEventListener('click', async () => {
    if (badgeScanner) return;
    badgeScanner = new Html5Qrcode('qrReaderTemp', { verbose: false });
    // Reuse the reader container by injecting it temporarily above the button
    const container = document.createElement('div');
    container.id = 'qrReaderTemp';
    container.className = 'mobile-reader';
    document.getElementById('scanBadgeBtn').after(container);

    try {
      await badgeScanner.start(
        { facingMode: 'environment' },
        { fps: 10, qrbox: { width: 250, height: 150 },
          formatsToSupport: [Html5QrcodeSupportedFormats.CODE_128] },
        async (decodedText) => {
          await badgeScanner.stop();
          badgeScanner.clear();
          container.remove();
          badgeScanner = null;
          await attemptLogin(decodedText.trim().toUpperCase());
        },
        () => { /* ignore per-frame decode failures */ }
      );
    } catch (e) {
      showLoginError('Could not access camera. Use manual entry below instead.');
      container.remove();
      badgeScanner = null;
    }
  });

  // ── Continuous relay scanner (step 2) — actually single-shot: scans one
  //    code, stops the camera, and waits for an explicit tap before
  //    scanning again. Avoids accidentally firing on the wrong barcode
  //    while the phone is still being repositioned. ──────────────────────
  let relayScanner = null;
  const scanNextBtn = document.getElementById('scanNextBtn');

  const relayConfig = {
    fps: 10, qrbox: { width: 260, height: 160 },
    formatsToSupport: [Html5QrcodeSupportedFormats.CODE_128],
  };

  async function handleRelayDecode(decodedText) {
    const code = decodedText.trim().toUpperCase();
    await relayScanner.stop();
    scanNextBtn.style.display = 'block';

    const { data } = await postJSON(API.scan, { code });
    if (data.ok) {
      if (data.type === 'item') {
        showScanResult(`Sent to kiosk: ${data.item.name} — enter quantity there.`);
      } else if (data.type === 'user_switch') {
        connectedUsername.textContent = data.user.username;
        showScanResult(`Switched kiosk user to ${data.user.username}.`);
      } else {
        showScanResult(data.message || 'Scanned.');
      }
    } else {
      showScanResult(data.error || 'Scan not recognised.');
    }
  }

  async function startRelayScanner() {
    relayScanner = new Html5Qrcode('qrReader', { verbose: false });
    scanNextBtn.style.display = 'none';
    try {
      await relayScanner.start(
        { facingMode: 'environment' }, relayConfig,
        handleRelayDecode,
        () => { /* ignore per-frame decode failures */ }
      );
    } catch (e) {
      showScanResult('Could not access camera.');
    }
  }

  scanNextBtn.addEventListener('click', () => {
    scanNextBtn.style.display = 'none';
    startRelayScanner();
  });

  if (ALREADY_PAIRED) {
    startRelayScanner();
  }
})();
