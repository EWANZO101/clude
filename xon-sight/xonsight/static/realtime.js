// One SSE connection per tab (/api/stream - see xonsight/realtime.py for why SSE
// instead of WebSockets). Shows a toast for every event and re-dispatches it as a
// DOM CustomEvent ("xonsight:<type>") so individual pages can react more richly -
// see dashboard.html for an example consumer. Toasts alone already make every
// authenticated page "live" at a baseline level; pages opt into more.
(function () {
  if (!document.querySelector('meta[name="csrf-token"]')) return; // unauthenticated pages (login, public report form)

  let stack = document.getElementById("rt-toast-stack");
  if (!stack) {
    stack = document.createElement("div");
    stack.id = "rt-toast-stack";
    stack.className = "fixed bottom-4 right-4 z-[60] flex flex-col gap-2 w-[300px] max-w-[calc(100vw-2rem)]";
    document.body.appendChild(stack);
  }

  const MESSAGES = {
    "evidence.created": (d) => ({
      icon: "evidence",
      tone: "text-accent",
      text: `New evidence from ${d.evidence.submitterName || "unknown officer"}`,
      href: `/evidence/${d.evidence.id}`,
    }),
    "alert.created": (d) => ({
      icon: "alert",
      tone: "text-red-400",
      text: `Alert: ${d.alert.alertType || d.alert.type || "trigger"} - ${d.alert.recorderName || d.alert.recorderId || ""}`,
      href: "/live",
    }),
    "bolo.created": (d) => ({
      icon: "flag",
      tone: "text-amber-400",
      text: `New BOLO: ${d.bolo.subject}`,
      href: "/cases",
    }),
    "case.created": (d) => ({
      icon: "cases",
      tone: "text-accent2",
      text: `New case opened: ${d.case.title}`,
      href: `/cases/${d.case.id}`,
    }),
    "submission.created": (d) => ({
      icon: "mail",
      tone: "text-accent2",
      text: `New community submission on "${d.submission.requestTitle || "a request"}"`,
      href: "/community",
    }),
  };

  const ICON_PATHS = {
    evidence: '<rect x="3" y="5" width="18" height="14" rx="2.5" />',
    alert: '<path d="M12 3.5l9.5 16.5H2.5L12 3.5z" /><path d="M12 10v4" /><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none" />',
    flag: '<path d="M6 3v18" /><path d="M6 4.5h10l-2 3.5 2 3.5H6" />',
    cases: '<path d="M3 8.5a2 2 0 0 1 2-2h4l1.8 2.2H19a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8.5z" />',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2" /><path d="M4 6.5l8 6 8-6" />',
  };

  function showToast(meta) {
    const el = document.createElement(meta.href ? "a" : "div");
    if (meta.href) el.href = meta.href;
    el.className =
      "flex items-center gap-2.5 rounded-xl border border-border bg-panel/95 backdrop-blur px-3.5 py-3 shadow-lg shadow-black/30 text-xs text-slate-200 hover:border-accent/50 transition";
    el.style.animation = "rtIn .2s ease both";
    el.innerHTML = `
      <svg viewBox="0 0 24 24" class="h-4 w-4 shrink-0 ${meta.tone}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICON_PATHS[meta.icon] || ""}</svg>
      <span class="flex-1 min-w-0">${meta.text}</span>`;
    stack.appendChild(el);
    setTimeout(() => {
      el.style.animation = "rtOut .2s ease both";
      el.addEventListener("animationend", () => el.remove(), { once: true });
    }, 6000);
  }

  if (!document.getElementById("rt-toast-style")) {
    const style = document.createElement("style");
    style.id = "rt-toast-style";
    style.textContent =
      "@keyframes rtIn{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}" +
      "@keyframes rtOut{from{opacity:1}to{opacity:0;transform:translateY(-4px)}}";
    document.head.appendChild(style);
  }

  function connect() {
    const source = new EventSource("/api/stream");
    source.onmessage = (evt) => {
      let data;
      try {
        data = JSON.parse(evt.data);
      } catch (err) {
        return;
      }
      const build = MESSAGES[data.type];
      if (build) {
        try {
          showToast(build(data));
        } catch (err) {
          /* malformed payload shape - skip the toast, still dispatch below */
        }
      }
      window.dispatchEvent(new CustomEvent(`xonsight:${data.type}`, { detail: data }));
    };
    source.onerror = () => {
      // EventSource auto-reconnects; nothing to do but let it retry.
    };
  }

  connect();
})();
