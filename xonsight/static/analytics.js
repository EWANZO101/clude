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

  function statTile(label, value, iconPath) {
    return `
      <div class="tac-corners border border-border bg-panel p-5 relative">
        <div class="flex items-center justify-between">
          <span class="card-label">${label}</span>
          <svg viewBox="0 0 24 24" class="h-4 w-4 text-accent" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${iconPath}</svg>
        </div>
        <div class="text-[26px] font-semibold text-white mt-2.5 font-mono leading-none">${value}</div>
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
          statTile("Total evidence", s.totalEvidence, ICONS.evidence),
          statTile("Active recorders", s.activeRecorders, ICONS.live),
          statTile("Open cases", s.openCases, ICONS.cases),
          statTile("Active BOLOs", s.activeBolos, ICONS.flag),
          statTile("Pending submissions", s.pendingSubmissions, ICONS.mail),
          statTile("Alerts (30d)", s.alerts30d, ICONS.alert),
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

  const CATEGORICAL = ["#dc2626", "#7d8694", "#b6bec9", "#991b1b", "#4b5563"];

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
      <div class="border border-border bg-panel2/60 p-4 text-center">
        <div class="text-xl font-mono font-semibold ${colorClasses}">${value}</div>
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
