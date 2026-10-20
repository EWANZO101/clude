(function () {
  const list = document.getElementById("request-list");
  if (!list) return;

  async function api(path, options) {
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return res.json();
  }

  function renderRequests(items) {
    const sorted = [...items].sort((a, b) => (b.isGeneral ? 1 : 0) - (a.isGeneral ? 1 : 0));
    list.innerHTML = sorted.length
      ? sorted
          .map(
            (r) => `
      <a href="/community/${r.id}" class="block rounded-2xl border bg-panel p-4 hover:border-accent/50 hover:-translate-y-0.5 transition shadow-sm hover:shadow-lg hover:shadow-black/30 ${r.isGeneral ? "border-accent/30" : "border-border"}">
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2 min-w-0">
            <div class="text-white font-medium truncate">${r.title}</div>
            ${r.isGeneral ? '<span class="text-[11px] px-2 py-0.5 rounded-full border border-accent/40 text-accent shrink-0">General tip line</span>' : ""}
          </div>
          <span class="text-[11px] px-2 py-0.5 rounded-full border shrink-0 ${r.status === "open" ? "border-accent2/50 text-accent2" : "border-slate-600 text-slate-400"}">${r.status}</span>
        </div>
        <div class="text-xs text-slate-500 mt-1.5">${r.category} &middot; ${r.submissionCount} submission${r.submissionCount === 1 ? "" : "s"}</div>
        <div class="text-[11px] text-slate-600 mt-2">Created by ${r.createdBy || "unknown"} &middot; ${new Date(r.createdAt).toLocaleDateString()}</div>
      </a>`
          )
          .join("")
      : '<div class="rounded-xl border border-dashed border-border bg-panel/40 px-6 py-8 text-center text-slate-500 text-sm">No community requests yet.</div>';
  }

  async function loadRequests() {
    renderRequests(await api("/api/community/requests"));
  }

  async function loadCases() {
    const select = document.getElementById("case-select");
    try {
      const cases = await api("/api/cases?status=open");
      select.innerHTML =
        '<option value="">No case</option>' + cases.map((c) => `<option value="${c.id}">${c.title}</option>`).join("");
    } catch (e) {
      /* leave default option */
    }
  }

  document.getElementById("new-request-form").addEventListener("submit", async (evt) => {
    evt.preventDefault();
    const form = evt.target;
    const data = {
      title: form.title.value.trim(),
      category: form.category.value,
      description: form.description.value.trim(),
      instructions: form.instructions.value.trim(),
      caseId: form.caseId.value || null,
      requiresConsent: form.requiresConsent.checked,
    };
    if (!data.title) return;
    const created = await api("/api/community/requests", { method: "POST", body: JSON.stringify(data) });
    window.location.href = `/community/${created.id}`;
  });

  loadRequests();
  loadCases();
})();
