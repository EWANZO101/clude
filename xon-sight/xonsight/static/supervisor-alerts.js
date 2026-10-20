// Site-wide shots-fired banner for supervisors/admins only - base.html only
// loads this script for current_user.is_supervisor. Polls the same
// /api/alerts endpoint live.html's roster view already uses, filtered to
// "shots_fired" specifically (other alert types still show as a normal
// toast via realtime.js, same as for every other user - this is strictly
// an extra, harder-to-miss layer on top for the most urgent alert type).
(function () {
  const banner = document.getElementById("supervisor-alert-banner");
  if (!banner) return;

  async function poll() {
    let alerts = [];
    try {
      alerts = await fetch("/api/alerts?unacknowledged=1").then((r) => r.json());
    } catch (err) {
      return; // leave whatever was already shown - don't flash it away on a transient network error
    }

    const shotsFired = alerts.filter((a) => a.alertType === "shots_fired");

    if (!shotsFired.length) {
      banner.classList.add("hidden");
      banner.innerHTML = "";
      return;
    }

    banner.classList.remove("hidden");
    banner.innerHTML = shotsFired
      .map(
        (a) => `
      <div class="flex items-center justify-between gap-4 rounded-2xl bg-red-500 px-5 py-3.5 shadow-lg shadow-red-900/30" style="animation: supervisorAlertPulse 1.4s ease-in-out infinite;">
        <div class="flex items-center gap-3 text-white">
          <svg viewBox="0 0 24 24" class="h-5 w-5 shrink-0" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5l9.5 16.5H2.5L12 3.5z" /><path d="M12 10v4" /><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none" /></svg>
          <span class="text-sm font-semibold">Shots fired &middot; ${a.recorderName || a.recorderId}${a.message ? " &middot; " + a.message : ""}</span>
        </div>
        <button type="button" data-ack="${a.id}" class="text-sm font-medium px-3.5 py-1.5 rounded-full bg-white/15 text-white hover:bg-white/25 shrink-0">Acknowledge</button>
      </div>`
      )
      .join("");
  }

  banner.addEventListener("click", async (evt) => {
    const btn = evt.target.closest("[data-ack]");
    if (!btn) return;
    btn.disabled = true;
    await fetch(`/api/alerts/${btn.dataset.ack}/ack`, { method: "POST" });
    poll();
  });

  if (!document.getElementById("supervisor-alert-style")) {
    const style = document.createElement("style");
    style.id = "supervisor-alert-style";
    style.textContent =
      "@keyframes supervisorAlertPulse{0%,100%{opacity:1}50%{opacity:0.85}}";
    document.head.appendChild(style);
  }

  poll();
  setInterval(poll, 4000);

  // A fresh alert.created event (pushed to everyone, see realtime.js) means
  // there's no reason to wait up to 4s for the next poll - check right away.
  window.addEventListener("xonsight:alert.created", poll);
})();
