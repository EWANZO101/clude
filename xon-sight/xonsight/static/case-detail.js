(function () {
  const CASE_ID = window.XON_SIGHT_CASE_ID;

  async function api(path, options) {
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return res.json();
  }

  function renderEvidence(items) {
    const list = document.getElementById("case-evidence-list");
    list.innerHTML = items.length
      ? items
          .map(
            (e) => `
      <div class="rounded-2xl border border-border bg-panel overflow-hidden hover:border-accent/40 transition">
        <a href="/evidence/${e.id}" class="block aspect-video bg-black/40 relative group">
          <video src="${e.videoUrl}" class="w-full h-full object-cover" muted preload="metadata"></video>
          <div class="absolute inset-0 bg-gradient-to-t from-black/50 via-transparent to-transparent"></div>
        </a>
        <div class="p-3 flex items-center justify-between gap-2">
          <div class="min-w-0">
            <div class="text-sm text-white truncate">${e.submitterName || "Unknown officer"}</div>
            <div class="text-[11px] text-slate-500 mt-0.5">${new Date(e.createdAt).toLocaleString()}</div>
          </div>
          <button type="button" data-remove="${e.id}" class="text-slate-600 hover:text-red-400 shrink-0 h-6 w-6 flex items-center justify-center rounded-lg hover:bg-red-500/10">✕</button>
        </div>
      </div>`
          )
          .join("")
      : `<div class="col-span-full rounded-xl border border-dashed border-border bg-panel/40 px-6 py-8 text-center text-slate-500 text-sm">No evidence linked yet - add it from an evidence item&rsquo;s Metadata tab.</div>`;
  }

  function renderAudit(entries) {
    const list = document.getElementById("case-audit-list");
    list.innerHTML = entries.length
      ? `<div class="space-y-3 relative pl-4 border-l border-border">` +
        entries
          .map(
            (a) => `
      <div class="relative">
        <span class="absolute -left-[21px] top-1 h-2.5 w-2.5 rounded-full bg-accent shadow-[0_0_6px_rgba(236,72,153,0.6)]"></span>
        <div class="bg-base rounded-lg px-3 py-2">
          <div class="text-slate-200 font-medium">${a.fromStatus ? a.fromStatus.replace(/_/g, " ") : "created"} &rarr; ${a.toStatus.replace(/_/g, " ")}</div>
          <div class="text-slate-500 mt-0.5">${new Date(a.createdAt).toLocaleString()}</div>
          ${a.note ? `<div class="text-slate-400 mt-1">${a.note}</div>` : ""}
        </div>
      </div>`
          )
          .join("") +
        `</div>`
      : '<p class="text-slate-600">No status changes yet.</p>';
  }

  async function load() {
    const data = await api(`/api/cases/${CASE_ID}`);
    renderEvidence(data.evidence);
    renderAudit(data.audit);
  }

  document.getElementById("case-evidence-list").addEventListener("click", async (evt) => {
    const btn = evt.target.closest("[data-remove]");
    if (!btn) return;
    await api(`/api/cases/${CASE_ID}/evidence/${btn.dataset.remove}`, { method: "DELETE" });
    load();
  });

  document.getElementById("btn-update-status").addEventListener("click", async () => {
    const status = document.getElementById("status-select").value;
    const note = prompt("Note for this status change (optional)", "") || "";
    await api(`/api/cases/${CASE_ID}/status`, { method: "PATCH", body: JSON.stringify({ status, note }) });
    load();
  });

  load();
})();
