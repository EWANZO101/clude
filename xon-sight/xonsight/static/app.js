// CSRF (Flask-WTF): every page extending base.html carries a <meta name="csrf-token"> tag. This patches
// window.fetch once, here, so every other static/*.js file's plain fetch() calls get X-CSRFToken attached to
// state-changing requests automatically - without editing each one of those files individually, and without
// missing one later. Safe for FormData/JSON bodies alike since it only ever touches headers.
(function () {
  const meta = document.querySelector('meta[name="csrf-token"]');
  if (!meta) return;
  const csrfToken = meta.content;
  const originalFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    init = init || {};
    const method = (init.method || "GET").toUpperCase();
    if (["POST", "PUT", "PATCH", "DELETE"].includes(method)) {
      const headers = new Headers(init.headers || {});
      if (!headers.has("X-CSRFToken")) headers.set("X-CSRFToken", csrfToken);
      init = Object.assign({}, init, { headers });
    }
    return originalFetch(input, init);
  };
})();

async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Request failed: ${res.status}`);
  return res.json();
}

async function tick() {
  let recorders = [];
  try {
    recorders = await fetchJSON("/api/recorders");
  } catch (err) {
    recorders = [];
  }

  const dot = document.getElementById("live-dot");
  if (dot) {
    const active = recorders.some((r) => !r.isStale);
    dot.classList.toggle("bg-slate-600", !active);
    dot.classList.toggle("is-live", active);
  }
}

tick();
setInterval(tick, 5000);

// Evidence card thumbnails (_evidence_card.html, used on Dashboard + Evidence list): a plain
// <video> with no poster shows solid black until something forces a frame to render, which reads
// as "every clip is broken" even when playback works fine - nudge it to paint one. A genuinely
// dead link (storage moved/deleted, as happened with the opsvoip-bridge voice-mixed recordings on
// 2026-10-18) fires the video element's own error event; swap in a clear placeholder for those
// instead of leaving a blank box that looks identical to "still loading."
document.querySelectorAll("video.evidence-thumb").forEach((video) => {
  video.addEventListener("loadeddata", () => {
    if (video.currentTime === 0) {
      try {
        video.currentTime = 0.1;
      } catch (err) {
        /* some browsers throw if metadata isn't fully ready yet - harmless, just skip the nudge */
      }
    }
  });
  video.addEventListener("error", () => {
    video.classList.add("hidden");
    const placeholder = video.nextElementSibling;
    if (placeholder && placeholder.classList.contains("evidence-thumb-error")) {
      placeholder.classList.remove("hidden");
      placeholder.classList.add("flex");
    }
  });
});
