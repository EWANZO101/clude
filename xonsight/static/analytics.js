(function () {
  "use strict";

  const tooltip = document.getElementById("chart-tooltip");

  function showTooltip(e, html) {
    if (!tooltip) return;
    tooltip.innerHTML = html;
    tooltip.classList.remove("hidden");
    const x = e.clientX + 14;
    const y = e.clientY + 14;
    tooltip.style.left = Math.min(x, window.innerWidth - tooltip.offsetWidth - 12) + "px";
    tooltip.style.top = Math.min(y, window.innerHeight - tooltip.offsetHeight - 12) + "px";
  }

  function hideTooltip() {
    if (tooltip) tooltip.classList.add("hidden");
  }

  function formatDay(iso) {
    const d = new Date(iso + "T00:00:00");
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  const CHIP_TONES = {
    accent: "background:rgba(236,72,153,0.15);color:#ec4899",
    accent2: "background:rgba(20,184,166,0.15);color:#14b8a6",
    sky: "background:rgba(56,189,248,0.15);color:#38bdf8",
    amber: "background:rgba(251,191,36,0.15);color:#fbbf24",
    emerald: "background:rgba(52,211,153,0.15);color:#34d399",
  };

  function statTile(label, value, iconPath, tone) {
    return `
      <div class="border border-border bg-panel rounded-2xl p-5">
        <div class="flex items-center justify-between mb-3">
          <span class="h-9 w-9 rounded-full flex items-center justify-center" style="${CHIP_TONES[tone] || CHIP_TONES.accent}">
            <svg viewBox="0 0 24 24" class="h-4 w-4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${iconPath}</svg>
          </span>
        </div>
        <div class="text-2xl font-bold text-white leading-none">${value}</div>
        <div class="card-label mt-1.5">${label}</div>
      </div>`;
  }

  const ICONS = {
    evidence: '<rect x="3" y="5" width="18" height="14" rx="2.5" />',
    live: '<path d="M12 21s-7-5.5-7-11a7 7 0 0 1 14 0c0 5.5-7 11-7 11z" /><circle cx="12" cy="10" r="2.6" />',
    cases: '<path d="M3 8.5a2 2 0 0 1 2-2h4l1.8 2.2H19a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8.5z" />',
    flag: '<path d="M6 3v18" /><path d="M6 4.5h10l-2 3.5 2 3.5H6" />',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2" /><path d="M4 6.5l8 6 8-6" />',
    alert: '<path d="M12 3.5l9.5 16.5H2.5L12 3.5z" /><path d="M12 10v4" /><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none" />',
  };

  function loadSummary() {
    fetch("/api/analytics/summary")
      .then((r) => r.json())
      .then((s) => {
        const el = document.getElementById("stat-tiles");
        if (!el) return;
        el.innerHTML = [
          statTile("Total evidence", s.totalEvidence, ICONS.evidence, "accent"),
          statTile("Active recorders", s.activeRecorders, ICONS.live, "accent2"),
          statTile("Open cases", s.openCases, ICONS.cases, "sky"),
          statTile("Active BOLOs", s.activeBolos, ICONS.flag, "amber"),
          statTile("Pending submissions", s.pendingSubmissions, ICONS.mail, "emerald"),
          statTile("Alerts (30d)", s.alerts30d, ICONS.alert, "accent"),
        ].join("");
      })
      .catch(() => {});
  }

  function loadEvidencePerDay() {
    fetch("/api/analytics/evidence-per-day?days=30")
      .then((r) => r.json())
      .then((series) => {
        const el = document.getElementById("evidence-chart");
        const totalEl = document.getElementById("evidence-chart-total");
        if (!el) return;
        const total = series.reduce((sum, d) => sum + d.count, 0);
        if (totalEl) totalEl.textContent = total + " total";
        const max = Math.max(1, ...series.map((d) => d.count));
        el.innerHTML = series
          .map((d) => {
            const h = Math.max(2, Math.round((d.count / max) * 100));
            return `<div class="flex-1 min-w-0 rounded-t bg-accent/60 hover:bg-accent transition-colors cursor-default" style="height:${h}%"
                      data-date="${d.date}" data-count="${d.count}"></div>`;
          })
          .join("");
        el.querySelectorAll("[data-date]").forEach((bar) => {
          bar.addEventListener("mousemove", (e) => {
            showTooltip(e, `<span class="text-white font-medium">${formatDay(bar.dataset.date)}</span> &middot; ${bar.dataset.count} submitted`);
          });
          bar.addEventListener("mouseleave", hideTooltip);
        });
      })
      .catch(() => {});
  }

  function hBarRow(label, count, max, colorClass) {
    const pct = Math.max(3, Math.round((count / max) * 100));
    return `
      <div>
        <div class="flex items-center justify-between text-xs mb-1">
          <span class="text-slate-300 truncate pr-2">${label}</span>
          <span class="text-slate-400 shrink-0">${count}</span>
        </div>
        <div class="h-2 rounded-full bg-white/5 overflow-hidden">
          <div class="h-full rounded-full ${colorClass}" style="width:${pct}%"></div>
        </div>
      </div>`;
  }

  const CATEGORICAL = ["#ec4899", "#14b8a6", "#38bdf8", "#fbbf24", "#a78bfa"];

  function loadAlertsByType() {
    fetch("/api/analytics/alerts-by-type?days=30")
      .then((r) => r.json())
      .then((rows) => {
        const el = document.getElementById("alerts-chart");
        if (!el) return;
        if (!rows.length) {
          el.innerHTML = `<p class="text-sm text-slate-500 text-center py-8">No alerts in the last 30 days.</p>`;
          return;
        }
        const max = Math.max(1, ...rows.map((r) => r.count));
        el.innerHTML = rows
          .map((r, i) => {
            const color = CATEGORICAL[i % CATEGORICAL.length];
            return `
              <div>
                <div class="flex items-center justify-between text-xs mb-1">
                  <span class="text-slate-300 truncate pr-2">${r.type}</span>
                  <span class="text-slate-400 shrink-0">${r.count}</span>
                </div>
                <div class="h-2 rounded-full bg-white/5 overflow-hidden">
                  <div class="h-full rounded-full" style="width:${Math.max(3, Math.round((r.count / max) * 100))}%;background:${color}"></div>
                </div>
              </div>`;
          })
          .join("");
      })
      .catch(() => {});
  }

  function loadTopOfficers() {
    fetch("/api/analytics/top-officers?days=30&limit=8")
      .then((r) => r.json())
      .then((rows) => {
        const el = document.getElementById("officers-chart");
        if (!el) return;
        if (!rows.length) {
          el.innerHTML = `<p class="text-sm text-slate-500 text-center py-8">No submissions in the last 30 days.</p>`;
          return;
        }
        const max = Math.max(1, ...rows.map((r) => r.count));
        el.innerHTML = rows.map((r) => hBarRow(r.name, r.count, max, "bg-accent2")).join("");
      })
      .catch(() => {});
  }

  function caseTile(label, value, colorClasses) {
    return `
      <div class="border border-border bg-panel2/60 rounded-xl p-4 text-center">
        <div class="text-xl font-bold ${colorClasses}">${value}</div>
        <div class="card-label mt-1.5">${label}</div>
      </div>`;
  }

  function loadCaseStatus() {
    fetch("/api/analytics/case-status")
      .then((r) => r.json())
      .then((s) => {
        const el = document.getElementById("case-status-tiles");
        if (!el) return;
        el.innerHTML = [
          caseTile("Open", s.open, "text-accent"),
          caseTile("Under review", s.underReview, "text-amber-400"),
          caseTile("Closed", s.closed, "text-accent2"),
        ].join("");
      })
      .catch(() => {});
  }

  loadSummary();
  loadEvidencePerDay();
  loadAlertsByType();
  loadTopOfficers();
  loadCaseStatus();
})();
