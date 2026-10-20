(function () {
  const REQUEST_ID = window.XON_SIGHT_REQUEST_ID;

  async function api(path, options) {
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return res.json();
  }

  function fileIsVideo(name) {
    return /\.(mp4|webm|mov)$/i.test(name || "");
  }

  function renderSubmissions(items) {
    const list = document.getElementById("submissions-list");
    list.innerHTML = items.length
      ? items
          .map((s) => {
            let media = "";
            if (s.hasFile) {
              const src = `/api/community/submissions/${s.id}/file`;
              media = fileIsVideo(s.fileOriginalName)
                ? `<video src="${src}" controls class="w-full max-h-72 rounded-lg bg-black mt-2"></video>`
                : `<img src="${src}" class="w-full max-h-72 object-contain rounded-lg bg-black mt-2">`;
            }
            return `
      <div class="rounded-2xl border bg-panel p-4 ${s.reviewed ? "border-border opacity-70" : "border-amber-500/30"}">
        <div class="flex items-center justify-between gap-2">
          <div class="text-sm text-white font-medium">${s.submitterName || "Anonymous"}</div>
          <div class="flex items-center gap-2">
            ${s.reviewed ? '<span class="text-[11px] px-2 py-0.5 rounded-full border border-accent2/50 text-accent2">Reviewed</span>' : '<span class="text-[11px] px-2 py-0.5 rounded-full border border-amber-500/40 text-amber-400">New</span>'}
            <button type="button" data-toggle-review="${s.id}" class="text-[11px] px-2 py-1 rounded-lg border border-border hover:border-accent/60 text-slate-300">
              ${s.reviewed ? "Mark unreviewed" : "Mark reviewed"}
            </button>
          </div>
        </div>
        ${s.submitterContact ? `<div class="text-xs text-slate-500 mt-1.5">Contact: ${s.submitterContact}</div>` : ""}
        ${s.message ? `<p class="text-sm text-slate-300 mt-2 whitespace-pre-wrap">${s.message}</p>` : ""}
        ${s.externalLink ? `<a href="${s.externalLink}" target="_blank" rel="noopener" class="text-xs text-accent hover:underline block mt-2">${s.externalLink}</a>` : ""}
        ${media}
        <div class="text-[11px] text-slate-600 mt-2.5">${new Date(s.submittedAt).toLocaleString()}</div>
      </div>`;
          })
          .join("")
      : '<div class="rounded-xl border border-dashed border-border bg-panel/40 px-6 py-8 text-center text-slate-500 text-sm">No submissions yet.</div>';
  }

  async function load() {
    const data = await api(`/api/community/requests/${REQUEST_ID}`);
    renderSubmissions(data.submissions);
  }

  document.getElementById("submissions-list").addEventListener("click", async (evt) => {
    const btn = evt.target.closest("[data-toggle-review]");
    if (!btn) return;
    await api(`/api/community/submissions/${btn.dataset.toggleReview}/review`, { method: "POST" });
    load();
  });

  document.getElementById("btn-toggle-status").addEventListener("click", async () => {
    const updated = await api(`/api/community/requests/${REQUEST_ID}/toggle`, { method: "POST" });
    const badge = document.getElementById("status-badge");
    badge.textContent = updated.status;
    badge.className = `text-[11px] px-2 py-0.5 rounded-full border ${updated.status === "open" ? "border-accent2/50 text-accent2" : "border-slate-600 text-slate-400"}`;
    const toggleBtn = document.getElementById("btn-toggle-status");
    toggleBtn.textContent = updated.status === "open" ? "Close request" : "Reopen request";
  });

  const deleteBtn = document.getElementById("btn-delete-request");
  if (deleteBtn) {
    deleteBtn.addEventListener("click", async () => {
      if (!confirm("Delete this request and all its submissions? This can't be undone.")) return;
      await api(`/api/community/requests/${REQUEST_ID}`, { method: "DELETE" });
      window.location.href = "/community";
    });
  }

  document.getElementById("btn-copy-link").addEventListener("click", async () => {
    const input = document.getElementById("public-link");
    input.select();
    try {
      await navigator.clipboard.writeText(input.value);
      const btn = document.getElementById("btn-copy-link");
      const original = btn.textContent;
      btn.textContent = "Copied";
      setTimeout(() => (btn.textContent = original), 1200);
    } catch (e) {
      /* clipboard API unavailable - the input is still selected for manual copy */
    }
  });

  load();
})();
