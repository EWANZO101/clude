(function () {
  let currentSource = null;

  function closeStream() {
    if (currentSource) {
      currentSource.close();
      currentSource = null;
    }
  }

  async function openScanRelay(targetId, autoSubmit) {
    const modal = document.getElementById('scanRelayModal');
    const img = document.getElementById('scanRelayQrImage');
    const status = document.getElementById('scanRelayStatus');
    status.textContent = '';
    openModal('scanRelayModal');

    let data;
    try {
      const res = await fetch(`${window.API_PUBLIC_URL}/api/scan-relay/new`);
      data = await res.json();
    } catch (e) {
      status.textContent = 'Could not reach the scan service.';
      status.style.color = '#fca5a5';
      return;
    }

    img.src = `${window.API_PUBLIC_URL}${data.qr_image_url}?t=${Date.now()}`;

    closeStream();
    currentSource = new EventSource(`${window.API_PUBLIC_URL}/api/scan-relay/stream/${data.relay_id}`);
    currentSource.addEventListener('scan', (e) => {
      const payload = JSON.parse(e.data);
      const target = document.getElementById(targetId);
      if (target) {
        target.value = payload.code;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
      }
      status.textContent = `Filled with: ${payload.code}`;
      status.style.color = '#6ee7b7';

      setTimeout(() => {
        closeModal('scanRelayModal');
        closeStream();
        if (autoSubmit && target && target.form) {
          target.form.submit();
        }
      }, 700);
    });
  }

  document.addEventListener('click', (e) => {
    const btn = e.target.closest('.scan-relay-btn');
    if (!btn) return;
    e.preventDefault();
    openScanRelay(btn.dataset.target, btn.dataset.autosubmit === 'true');
  });

  document.addEventListener('click', (e) => {
    if (e.target.closest('[onclick*="scanRelayModal"]')) {
      closeStream();
    }
  });
})();
