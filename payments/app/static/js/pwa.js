/* PWA bootstrap: service worker registration, install-to-home-screen
 * prompt, and a scoped offline queue.
 *
 * Offline queue scope (Part 10 — tracked as partial in REMAINING_WORK):
 * only checklist task-completion toggles are queued when offline and
 * replayed on reconnect. Broader "queue any safe-module change offline"
 * is not implemented — this covers the single most common offline
 * action (ticking something off a list) rather than every mutation.
 * Never queues anything under /finance, /merchant, /fuel, /backups.
 */
(function () {
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => {
      navigator.serviceWorker.register("/static/sw.js").catch(() => {});
    });
  }

  // ---- Install prompt ----
  let deferredPrompt = null;
  window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferredPrompt = e;
    const btn = document.getElementById("pwa-install-btn");
    if (btn) btn.classList.remove("hidden");
  });

  window.addEventListener("DOMContentLoaded", () => {
    const btn = document.getElementById("pwa-install-btn");
    if (btn) {
      btn.addEventListener("click", async () => {
        if (!deferredPrompt) return;
        deferredPrompt.prompt();
        await deferredPrompt.userChoice;
        deferredPrompt = null;
        btn.classList.add("hidden");
      });
    }
  });

  window.addEventListener("appinstalled", () => {
    const btn = document.getElementById("pwa-install-btn");
    if (btn) btn.classList.add("hidden");
  });

  // ---- Offline queue: checklist task-completion toggles only ----
  const QUEUE_KEY = "offline_queue_checklist_toggles";

  function readQueue() {
    try { return JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]"); } catch (e) { return []; }
  }
  function writeQueue(q) {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
  }

  function queueToggle(url, csrfToken) {
    const q = readQueue();
    q.push({ url, csrfToken, queued_at: Date.now() });
    writeQueue(q);
    updateQueueBadge();
  }

  function updateQueueBadge() {
    const badge = document.getElementById("offline-queue-badge");
    const q = readQueue();
    if (!badge) return;
    if (q.length > 0) {
      badge.textContent = q.length + " change" + (q.length === 1 ? "" : "s") + " will sync when you're back online";
      badge.classList.remove("hidden");
    } else {
      badge.classList.add("hidden");
    }
  }

  async function flushQueue() {
    let q = readQueue();
    if (q.length === 0) return;
    const remaining = [];
    for (const item of q) {
      try {
        const resp = await fetch(item.url, {
          method: "POST",
          headers: { "X-CSRFToken": item.csrfToken },
        });
        if (!resp.ok) remaining.push(item);
      } catch (e) {
        remaining.push(item); // still offline, keep it queued
      }
    }
    writeQueue(remaining);
    updateQueueBadge();
    if (remaining.length === 0 && q.length > 0) {
      // reload to reflect synced state
      window.location.reload();
    }
  }

  window.addEventListener("online", flushQueue);
  window.addEventListener("DOMContentLoaded", () => {
    updateQueueBadge();
    if (navigator.onLine) flushQueue();

    document.querySelectorAll("form[data-offline-toggle]").forEach((form) => {
      form.addEventListener("submit", function (e) {
        if (navigator.onLine) return; // let it submit normally
        e.preventDefault();
        const url = form.getAttribute("action");
        const csrfInput = form.querySelector('input[name="csrf_token"]');
        queueToggle(url, csrfInput ? csrfInput.value : "");
        // optimistic UI: let the checkbox/visual state flip via existing markup;
        // full row refresh happens on next successful sync/reload.
      });
    });
  });
})();
