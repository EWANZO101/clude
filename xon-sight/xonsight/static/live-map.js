(function () {
  if (!window.XON_SIGHT_LIVE_PAGE) return;

  // Approximate GTA V playable world bounds (Los Santos + Blaine County) -
  // Xon Sight only ever reports in-game x/y, there's no real GPS, so this
  // draws a schematic grid rather than a street map.
  const WORLD_BOUNDS = { minX: -4300, maxX: 4300, minY: -4300, maxY: 8200 };

  const canvas = document.getElementById("map-canvas");
  const ctx = canvas.getContext("2d");
  const tooltip = document.getElementById("map-tooltip");

  let recorders = [];
  let externalFeeds = [];
  let mode = "grid";
  let followId = null;
  let selectedId = null;
  let hoveredId = null;

  const view = { scale: 1, panX: 0, panY: 0 };

  function cssSize() {
    const rect = canvas.getBoundingClientRect();
    return { w: rect.width, h: rect.height };
  }

  function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    canvas.width = rect.width * devicePixelRatio;
    canvas.height = rect.height * devicePixelRatio;
    ctx.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
    draw();
  }

  function worldToScreen(x, y) {
    const { w, h } = cssSize();
    const nx = (x - WORLD_BOUNDS.minX) / (WORLD_BOUNDS.maxX - WORLD_BOUNDS.minX);
    const ny = 1 - (y - WORLD_BOUNDS.minY) / (WORLD_BOUNDS.maxY - WORLD_BOUNDS.minY);
    return { x: nx * w * view.scale + view.panX, y: ny * h * view.scale + view.panY };
  }

  function drawBackground() {
    const { w, h } = cssSize();
    if (mode === "terrain") {
      const grad = ctx.createLinearGradient(0, 0, 0, h);
      grad.addColorStop(0, "#17171a");
      grad.addColorStop(1, "#0a0a0b");
      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, w, h);
    } else {
      ctx.fillStyle = "#0a0a0c";
      ctx.fillRect(0, 0, w, h);
    }

    ctx.strokeStyle = mode === "terrain" ? "rgba(255,255,255,0.08)" : "rgba(255,255,255,0.07)";
    ctx.lineWidth = 1;
    const step = 500;
    for (let x = Math.ceil(WORLD_BOUNDS.minX / step) * step; x <= WORLD_BOUNDS.maxX; x += step) {
      const a = worldToScreen(x, WORLD_BOUNDS.minY);
      const b = worldToScreen(x, WORLD_BOUNDS.maxY);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    }
    for (let y = Math.ceil(WORLD_BOUNDS.minY / step) * step; y <= WORLD_BOUNDS.maxY; y += step) {
      const a = worldToScreen(WORLD_BOUNDS.minX, y);
      const b = worldToScreen(WORLD_BOUNDS.maxX, y);
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    }

    ctx.save();
    ctx.translate(w - 36, 70);
    ctx.strokeStyle = "rgba(226,232,240,0.6)";
    ctx.fillStyle = "rgba(226,232,240,0.8)";
    ctx.font = "11px sans-serif";
    ctx.beginPath();
    ctx.moveTo(0, -16);
    ctx.lineTo(0, 16);
    ctx.stroke();
    ctx.fillText("N", -4, -20);
    ctx.restore();
  }

  function statusColor(r) {
    if (r.isStale) return "#52525b";
    if (r.status === "buffering") return "#14b8a6";
    return "#ef4444";
  }

  function drawRecorders() {
    recorders.forEach((r) => {
      if (!r.lastFrame) return;
      const p = worldToScreen(r.lastFrame.x, r.lastFrame.y);
      const color = statusColor(r);

      ctx.beginPath();
      ctx.strokeStyle = "rgba(255,255,255,0.3)";
      ctx.lineWidth = 1;
      ctx.arc(p.x, p.y, 10, 0, Math.PI * 2);
      ctx.stroke();

      ctx.beginPath();
      ctx.fillStyle = color;
      ctx.arc(p.x, p.y, r.id === hoveredId || r.id === selectedId ? 7 : 5, 0, Math.PI * 2);
      ctx.fill();

      if (r.id === selectedId || r.id === followId) {
        ctx.beginPath();
        ctx.strokeStyle = "#e5e7eb";
        ctx.lineWidth = 2;
        ctx.arc(p.x, p.y, 11, 0, Math.PI * 2);
        ctx.stroke();
      }

      if (typeof r.lastFrame.heading === "number") {
        const rad = (r.lastFrame.heading * Math.PI) / 180;
        ctx.beginPath();
        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(p.x + Math.sin(rad) * 14, p.y - Math.cos(rad) * 14);
        ctx.stroke();
      }

      ctx.fillStyle = "rgba(226,232,240,0.85)";
      ctx.font = "10px sans-serif";
      ctx.fillText(r.name || r.id, p.x + 10, p.y - 10);
    });
  }

  function drawExternalFeeds() {
    externalFeeds.forEach((f) => {
      if (!f.position) return;
      const p = worldToScreen(f.position.x, f.position.y);
      ctx.beginPath();
      ctx.fillStyle = f.status === "offline" ? "#52525b" : "#38bdf8";
      ctx.rect(p.x - 4, p.y - 4, 8, 8);
      ctx.fill();
      ctx.fillStyle = "rgba(226,232,240,0.7)";
      ctx.font = "10px sans-serif";
      ctx.fillText(f.label || f.id, p.x + 8, p.y - 6);
    });
  }

  function draw() {
    drawBackground();
    drawExternalFeeds();
    drawRecorders();
  }

  function markerAt(sx, sy) {
    return recorders.find((r) => {
      if (!r.lastFrame) return false;
      const p = worldToScreen(r.lastFrame.x, r.lastFrame.y);
      return Math.hypot(p.x - sx, p.y - sy) <= 9;
    });
  }

  // --- Pan / zoom ---------------------------------------------------------

  let dragging = false;
  let dragMoved = false;
  let lastX = 0;
  let lastY = 0;

  canvas.addEventListener("mousedown", (e) => {
    dragging = true;
    dragMoved = false;
    lastX = e.clientX;
    lastY = e.clientY;
  });

  window.addEventListener("mousemove", (e) => {
    const rect = canvas.getBoundingClientRect();
    const sx = e.clientX - rect.left;
    const sy = e.clientY - rect.top;

    if (dragging) {
      const dx = e.clientX - lastX;
      const dy = e.clientY - lastY;
      if (Math.abs(dx) + Math.abs(dy) > 2) dragMoved = true;
      view.panX += dx;
      view.panY += dy;
      lastX = e.clientX;
      lastY = e.clientY;
      if (dragMoved) {
        followId = null;
        updateFollowButtons();
      }
      draw();
      return;
    }

    const hit = markerAt(sx, sy);
    hoveredId = hit ? hit.id : null;
    if (hit) {
      tooltip.innerHTML = `<div class="text-white font-medium">${hit.name || "Unknown"}</div>
        <div class="text-slate-400">${hit.job || "—"} &middot; unit ${hit.id}</div>
        <div class="text-slate-500 mt-1">${hit.status === "buffering" ? "Camera on, buffering" : "Recording"}${hit.isStale ? " &middot; feed stale" : ""}</div>`;
      tooltip.style.left = sx + 14 + "px";
      tooltip.style.top = sy + 14 + "px";
      tooltip.classList.remove("hidden");
    } else {
      tooltip.classList.add("hidden");
    }
    draw();
  });

  window.addEventListener("mouseup", (e) => {
    if (dragging && !dragMoved) {
      const rect = canvas.getBoundingClientRect();
      const hit = markerAt(e.clientX - rect.left, e.clientY - rect.top);
      if (hit) {
        selectedId = hit.id;
        highlightRoster(hit.id);
      }
    }
    dragging = false;
  });

  canvas.addEventListener(
    "wheel",
    (e) => {
      e.preventDefault();
      const rect = canvas.getBoundingClientRect();
      zoomAt(e.clientX - rect.left, e.clientY - rect.top, e.deltaY < 0 ? 1.15 : 1 / 1.15);
    },
    { passive: false }
  );

  function zoomAt(sx, sy, factor) {
    const { w, h } = cssSize();
    const newScale = Math.min(10, Math.max(1, view.scale * factor));
    const nx = (sx - view.panX) / (w * view.scale);
    const ny = (sy - view.panY) / (h * view.scale);
    view.panX = sx - nx * w * newScale;
    view.panY = sy - ny * h * newScale;
    view.scale = newScale;
    draw();
  }

  document.getElementById("map-zoom-in").addEventListener("click", () => {
    const { w, h } = cssSize();
    zoomAt(w / 2, h / 2, 1.3);
  });
  document.getElementById("map-zoom-out").addEventListener("click", () => {
    const { w, h } = cssSize();
    zoomAt(w / 2, h / 2, 1 / 1.3);
  });
  document.getElementById("map-reset").addEventListener("click", () => {
    view.scale = 1;
    view.panX = 0;
    view.panY = 0;
    followId = null;
    updateFollowButtons();
    draw();
  });

  document.getElementById("map-mode-grid").addEventListener("click", () => setMode("grid"));
  document.getElementById("map-mode-terrain").addEventListener("click", () => setMode("terrain"));

  function setMode(next) {
    mode = next;
    ["grid", "terrain"].forEach((m) => {
      const btn = document.getElementById(`map-mode-${m}`);
      btn.classList.toggle("bg-accent/10", m === next);
      btn.classList.toggle("text-accent", m === next);
      btn.classList.toggle("border-accent/40", m === next);
    });
    draw();
  }

  // --- Follow / tether -----------------------------------------------------

  function panToRecorder(r) {
    if (!r.lastFrame) return;
    const { w, h } = cssSize();
    const nx = (r.lastFrame.x - WORLD_BOUNDS.minX) / (WORLD_BOUNDS.maxX - WORLD_BOUNDS.minX);
    const ny = 1 - (r.lastFrame.y - WORLD_BOUNDS.minY) / (WORLD_BOUNDS.maxY - WORLD_BOUNDS.minY);
    view.panX = w / 2 - nx * w * view.scale;
    view.panY = h / 2 - ny * h * view.scale;
  }

  function updateFollowButtons() {
    document.querySelectorAll("[data-follow]").forEach((btn) => {
      const active = btn.dataset.follow === followId;
      btn.textContent = active ? "Following" : "Follow";
      btn.classList.toggle("text-accent", active);
      btn.classList.toggle("border-accent/40", active);
    });
  }

  function highlightRoster(id) {
    document.querySelectorAll("[data-roster-row]").forEach((row) => {
      row.classList.toggle("bg-white/5", row.dataset.rosterRow === id);
    });
  }

  // --- Roster sidebar --------------------------------------------------------

  function timeAgo(iso) {
    if (!iso) return "just now";
    const diff = (Date.now() - new Date(iso).getTime()) / 1000;
    if (diff < 60) return `${Math.max(0, Math.floor(diff))}s`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m`;
    return `${Math.floor(diff / 3600)}h`;
  }

  function renderRoster() {
    const q = document.getElementById("roster-search").value.trim().toLowerCase();
    const list = document.getElementById("roster-list");
    const filtered = recorders.filter(
      (r) => !q || (r.name || "").toLowerCase().includes(q) || (r.job || "").toLowerCase().includes(q) || r.id.toLowerCase().includes(q)
    );

    if (!filtered.length) {
      list.innerHTML = '<div class="text-slate-600 text-xs p-6 text-center">No active recorders.</div>';
      return;
    }

    list.innerHTML = filtered
      .map((r) => {
        const color = r.isStale ? "bg-slate-600" : r.status === "buffering" ? "bg-accent2 shadow-[0_0_6px_rgba(20,184,166,0.8)]" : "bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.8)]";
        const selected = r.id === selectedId;
        return `
      <div data-roster-row="${r.id}" class="p-3 text-xs transition ${selected ? "bg-accent/5 border-l-2 border-accent" : "border-l-2 border-transparent hover:bg-white/[0.02]"}">
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2 min-w-0">
            <span class="h-2 w-2 rounded-full ${color} shrink-0"></span>
            <span class="text-white font-medium truncate">${r.name || "Unknown officer"}</span>
          </div>
          <button type="button" data-follow="${r.id}" class="text-[11px] px-2 py-0.5 rounded-lg border border-border hover:border-accent/60 text-slate-400 shrink-0">Follow</button>
        </div>
        <div class="text-slate-500 mt-1.5">${r.job || "—"} &middot; unit ${r.id}</div>
        <div class="text-slate-600 mt-0.5">${r.status === "buffering" ? "Buffering" : "Recording"} for ${timeAgo(r.startedAt)}${r.isStale ? " &middot; stale" : ""}</div>
      </div>`;
      })
      .join("");
  }

  document.getElementById("roster-search").addEventListener("input", renderRoster);

  document.getElementById("roster-list").addEventListener("click", (evt) => {
    const followBtn = evt.target.closest("[data-follow]");
    if (followBtn) {
      followId = followId === followBtn.dataset.follow ? null : followBtn.dataset.follow;
      if (followId) {
        const r = recorders.find((x) => x.id === followId);
        if (r) panToRecorder(r);
      }
      updateFollowButtons();
      draw();
      return;
    }
    const row = evt.target.closest("[data-roster-row]");
    if (row) {
      selectedId = row.dataset.rosterRow;
      renderRoster();
      draw();
    }
  });

  // --- Alerts ------------------------------------------------------------

  async function pollAlerts() {
    let alerts = [];
    try {
      alerts = await fetch("/api/alerts?unacknowledged=1").then((r) => r.json());
    } catch (e) {
      alerts = [];
    }
    const banner = document.getElementById("alert-banner");
    if (!alerts.length) {
      banner.classList.add("hidden");
      banner.innerHTML = "";
      return;
    }
    banner.classList.remove("hidden");
    banner.innerHTML = alerts
      .map(
        (a) => `
      <div class="animate-pulse flex items-center justify-between gap-3 rounded-lg border border-red-500/50 bg-red-500/10 px-4 py-2.5">
        <div class="text-sm text-red-200">
          <span class="font-semibold">${a.alertType.replace(/_/g, " ")}</span> &middot;
          ${a.recorderName || a.recorderId} ${a.message ? "&middot; " + a.message : ""}
        </div>
        <button type="button" data-ack="${a.id}" class="text-xs px-2.5 py-1 rounded border border-red-400/40 text-red-200 hover:bg-red-500/20 shrink-0">Acknowledge</button>
      </div>`
      )
      .join("");
  }

  document.getElementById("alert-banner").addEventListener("click", async (evt) => {
    const btn = evt.target.closest("[data-ack]");
    if (!btn) return;
    await fetch(`/api/alerts/${btn.dataset.ack}/ack`, { method: "POST" });
    pollAlerts();
  });

  // --- Poll loop -----------------------------------------------------------

  async function tick() {
    try {
      recorders = await fetch("/api/recorders").then((r) => r.json());
    } catch (e) {
      recorders = [];
    }
    try {
      externalFeeds = await fetch("/api/external-feeds").then((r) => r.json());
    } catch (e) {
      externalFeeds = [];
    }
    if (followId) {
      const r = recorders.find((x) => x.id === followId);
      if (r) panToRecorder(r);
      else {
        followId = null;
        updateFollowButtons();
      }
    }
    renderRoster();
    draw();
    pollAlerts();
  }

  window.addEventListener("resize", resizeCanvas);
  resizeCanvas();
  tick();
  setInterval(tick, 3000);
})();
