(function () {
  const PRIMARY = window.XON_SIGHT_EVIDENCE;
  const AGENCY = window.XON_SIGHT_AGENCY || "Unconfigured Agency";
  const TENANT_MODE = !!window.XON_SIGHT_TENANT_MODE;
  const MAX_CAMS = 4;
  const FRAME_SECONDS = 1 / 30; // Xon Sight doesn't report capture fps - 30fps is an estimate.

  const camGrid = document.getElementById("cam-grid");
  const cams = []; // {data, el, videoEl, isPrimary}

  function fmtTime(sec) {
    if (!isFinite(sec) || sec < 0) sec = 0;
    const m = Math.floor(sec / 60);
    const s = Math.floor(sec % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  }

  function gridClass(n) {
    return n <= 1 ? "grid-cols-1" : "grid-cols-1 sm:grid-cols-2";
  }

  function offsetSeconds(other) {
    return (new Date(other.createdAt).getTime() - new Date(PRIMARY.createdAt).getTime()) / 1000;
  }

  function buildCamEl(data, isPrimary) {
    const wrap = document.createElement("div");
    wrap.className = "cam-slot relative rounded-lg overflow-hidden bg-black aspect-video";
    wrap.innerHTML = `
      <video class="w-full h-full object-contain" ${isPrimary ? "" : "muted"} playsinline preload="metadata"></video>
      <div class="absolute inset-0 pointer-events-none">
        <div class="absolute top-2 left-2 text-[10px] font-mono text-white/90 bg-black/50 px-1.5 py-1 rounded leading-tight">
          <div>${AGENCY}</div>
          <div>${data.submitterName || "Unknown officer"}</div>
          <div class="serial-line">SN ${data.deviceSerial || "—"}</div>
        </div>
        <div class="clock absolute bottom-2 left-2 text-[10px] font-mono text-white/90 bg-black/50 px-1.5 py-1 rounded"></div>
      </div>
      <button type="button" class="audio-toggle absolute top-2 right-2 pointer-events-auto text-[11px] px-1.5 py-1 rounded bg-black/60 border border-white/10 text-white/80 hover:text-white">${isPrimary ? "🔊" : "🔇"}</button>
      ${isPrimary ? "" : '<button type="button" class="remove-cam absolute bottom-2 right-2 pointer-events-auto text-[11px] px-1.5 py-1 rounded bg-black/60 border border-white/10 text-white/80 hover:text-white">Remove</button>'}
    `;
    const videoEl = wrap.querySelector("video");
    videoEl.src = data.videoUrl;
    videoEl.muted = !isPrimary;
    videoEl.addEventListener("error", () => {
      wrap.querySelectorAll("video, .audio-toggle, .remove-cam").forEach((el) => el.classList.add("hidden"));
      const overlay = document.createElement("div");
      overlay.className = "absolute inset-0 flex flex-col items-center justify-center gap-2 bg-black/80 text-center px-3";
      overlay.innerHTML = `
        <svg viewBox="0 0 24 24" class="h-6 w-6 text-slate-500" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
          <path d="M12 3.5l9.5 16.5H2.5L12 3.5z" /><path d="M12 10v4" /><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none" />
        </svg>
        <span class="text-xs text-slate-400">Video unavailable - the source file no longer exists.</span>`;
      wrap.appendChild(overlay);
    });

    const cam = { data, el: wrap, videoEl, isPrimary };

    wrap.querySelector(".audio-toggle").addEventListener("click", () => setActiveAudio(cam));
    const removeBtn = wrap.querySelector(".remove-cam");
    if (removeBtn) removeBtn.addEventListener("click", () => removeCam(data.id));

    return cam;
  }

  function setActiveAudio(activeCam) {
    cams.forEach((c) => {
      c.videoEl.muted = c !== activeCam;
      const btn = c.el.querySelector(".audio-toggle");
      if (btn) btn.textContent = c.videoEl.muted ? "🔇" : "🔊";
    });
  }

  function renderGrid() {
    camGrid.className = `grid ${gridClass(cams.length)} gap-2 rounded-xl overflow-hidden border border-border bg-black p-1`;
    camGrid.innerHTML = "";
    cams.forEach((c) => camGrid.appendChild(c.el));
  }

  function addCam(data) {
    if (cams.length >= MAX_CAMS) return;
    if (cams.some((c) => c.data.id === data.id)) return;
    cams.push(buildCamEl(data, false));
    renderGrid();
    applyEnvironment();
    renderRelatedList();
  }

  function removeCam(id) {
    const idx = cams.findIndex((c) => c.data.id === id);
    if (idx === -1 || cams[idx].isPrimary) return;
    cams.splice(idx, 1);
    renderGrid();
    renderRelatedList();
  }

  function primary() {
    return cams[0];
  }

  // --- Playback sync ------------------------------------------------------

  let isPlaying = false;

  function playAll() {
    cams.forEach((c) => c.videoEl.play().catch(() => {}));
    isPlaying = true;
    document.getElementById("btn-playpause").textContent = "Pause";
  }

  function pauseAll() {
    cams.forEach((c) => c.videoEl.pause());
    isPlaying = false;
    document.getElementById("btn-playpause").textContent = "Play";
  }

  function seekAllTo(seconds) {
    cams.forEach((c) => {
      const target = c.isPrimary ? seconds : seconds + offsetSeconds(c.data);
      const dur = c.videoEl.duration || Infinity;
      c.videoEl.currentTime = Math.min(Math.max(target, 0), dur);
    });
  }

  function setSpeed(speed) {
    cams.forEach((c) => (c.videoEl.playbackRate = speed));
    document.querySelectorAll(".speed-btn").forEach((b) => {
      const match = parseFloat(b.dataset.speed) === speed;
      b.classList.toggle("bg-accent/10", match);
      b.classList.toggle("text-accent", match);
      b.classList.toggle("border-accent/40", match);
      b.classList.toggle("text-slate-400", !match);
    });
  }

  function stepFrame(delta) {
    pauseAll();
    seekAllTo(Math.max(0, primary().videoEl.currentTime + delta * FRAME_SECONDS));
  }

  // --- Environment ---------------------------------------------------------

  function applyEnvironment() {
    const b = document.getElementById("range-brightness").value;
    const c = document.getElementById("range-contrast").value;
    cams.forEach((cam) => {
      cam.videoEl.style.filter = `brightness(${b}%) contrast(${c}%)`;
    });
  }

  // --- Scrub bar -----------------------------------------------------------

  const scrubWrap = document.getElementById("scrub-wrap");
  const scrubPlayed = document.getElementById("scrub-played");
  const scrubHandle = document.getElementById("scrub-handle");
  const scrubPreview = document.getElementById("scrub-preview");
  const scrubPreviewCanvas = document.getElementById("scrub-preview-canvas");
  const scrubPreviewTime = document.getElementById("scrub-preview-time");
  const scrubMarkers = document.getElementById("scrub-markers");
  const scrubClipRange = document.getElementById("scrub-clip-range");

  const previewVideo = document.createElement("video");
  previewVideo.muted = true;
  previewVideo.preload = "metadata";

  function ratioFromEvent(evt) {
    const rect = scrubWrap.getBoundingClientRect();
    const x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
    return Math.min(1, Math.max(0, x / rect.width));
  }

  function updateScrubUI() {
    const dur = primary().videoEl.duration || 0;
    const cur = primary().videoEl.currentTime || 0;
    const pct = dur ? (cur / dur) * 100 : 0;
    scrubPlayed.style.width = pct + "%";
    scrubHandle.style.left = pct + "%";
    document.getElementById("time-current").textContent = fmtTime(cur);
    document.getElementById("time-duration").textContent = fmtTime(dur);
    updateClocks(cur);
  }

  function updateClocks(primaryCurrent) {
    cams.forEach((c) => {
      const el = c.el.querySelector(".clock");
      if (!el) return;
      const t = new Date(new Date(PRIMARY.createdAt).getTime() + primaryCurrent * 1000);
      el.textContent = t.toISOString().replace("T", " ").slice(0, 19) + "Z";
    });
  }

  let scrubbing = false;

  scrubWrap.addEventListener("mousedown", (evt) => {
    scrubbing = true;
    pauseAll();
    const dur = primary().videoEl.duration || 0;
    seekAllTo(ratioFromEvent(evt) * dur);
    updateScrubUI();
  });

  window.addEventListener("mousemove", (evt) => {
    if (!scrubbing) return;
    const dur = primary().videoEl.duration || 0;
    seekAllTo(ratioFromEvent(evt) * dur);
    updateScrubUI();
  });

  window.addEventListener("mouseup", () => {
    scrubbing = false;
  });

  scrubWrap.addEventListener("mousemove", (evt) => {
    const dur = primary().videoEl.duration || 0;
    if (!dur) return;
    const ratio = ratioFromEvent(evt);
    const t = ratio * dur;
    scrubPreview.style.left = ratio * 100 + "%";
    scrubPreview.classList.remove("hidden");
    scrubPreviewTime.textContent = fmtTime(t);

    if (previewVideo.src !== primary().data.videoUrl) {
      previewVideo.src = primary().data.videoUrl;
    }
    if (Math.abs(previewVideo.currentTime - t) > 0.2) {
      try {
        previewVideo.currentTime = t;
      } catch (e) {
        /* ignore - seek can fail mid-load */
      }
    }
  });

  scrubWrap.addEventListener("mouseleave", () => scrubPreview.classList.add("hidden"));

  previewVideo.addEventListener("seeked", () => {
    const ctx = scrubPreviewCanvas.getContext("2d");
    try {
      ctx.drawImage(previewVideo, 0, 0, scrubPreviewCanvas.width, scrubPreviewCanvas.height);
    } catch (e) {
      // Cross-origin video without CORS headers - preview just won't render.
    }
  });

  function renderMarkerTicks(markers, clips) {
    const dur = primary().videoEl.duration || 0;
    scrubMarkers.innerHTML = "";
    if (!dur) return;
    markers.forEach((m) => {
      const tick = document.createElement("div");
      tick.title = m.label;
      tick.className = "absolute top-0 w-0.5 h-full bg-amber-400/80";
      tick.style.left = `${(m.timestampSeconds / dur) * 100}%`;
      scrubMarkers.appendChild(tick);
    });
    if (clips.length) {
      const c = clips[clips.length - 1];
      scrubClipRange.style.left = `${(c.startSeconds / dur) * 100}%`;
      scrubClipRange.style.width = `${((c.endSeconds - c.startSeconds) / dur) * 100}%`;
      scrubClipRange.classList.remove("hidden");
    } else {
      scrubClipRange.classList.add("hidden");
    }
  }

  // --- API helpers -----------------------------------------------------------

  async function api(path, options) {
    // Single choke point: every notes/markers/clips/cases/draft/brief call runs through here, so
    // gating it here (rather than at each of the ~10 call sites below) is what actually guarantees
    // none of them can fire against the wrong database - see the TENANT_MODE comment in
    // evidence_detail.html.
    if (TENANT_MODE) throw new Error("not available for community-hosted evidence yet");
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return res.json();
  }

  let markersCache = [];
  let clipsCache = [];

  async function loadMarkersAndClips() {
    if (TENANT_MODE) {
      const msg = '<p class="text-slate-600">Not available for community-hosted evidence yet.</p>';
      document.getElementById("markers-list").innerHTML = msg;
      document.getElementById("clips-list").innerHTML = msg;
      return;
    }
    [markersCache, clipsCache] = await Promise.all([
      api(`/api/evidence/${PRIMARY.id}/markers`),
      api(`/api/evidence/${PRIMARY.id}/clips`),
    ]);
    renderMarkersClipsTab();
    renderMarkerTicks(markersCache, clipsCache);
  }

  function renderMarkersClipsTab() {
    const markersList = document.getElementById("markers-list");
    markersList.innerHTML = markersCache.length
      ? markersCache
          .map(
            (m) => `
      <div class="flex items-center justify-between gap-2 bg-base rounded-lg px-2 py-1.5">
        <button type="button" data-jump="${m.timestampSeconds}" class="text-left flex-1 text-slate-300 hover:text-white">
          <span class="text-accent font-medium">${fmtTime(m.timestampSeconds)}</span> ${m.label}
        </button>
        <button type="button" data-del-marker="${m.id}" class="text-slate-600 hover:text-red-400">✕</button>
      </div>`
          )
          .join("")
      : '<p class="text-slate-600">No markers yet.</p>';

    const clipsList = document.getElementById("clips-list");
    clipsList.innerHTML = clipsCache.length
      ? clipsCache
          .map(
            (c) => `
      <div class="flex items-center justify-between gap-2 bg-base rounded-lg px-2 py-1.5">
        <button type="button" data-jump="${c.startSeconds}" class="text-left flex-1 text-slate-300 hover:text-white">
          <span class="text-accent font-medium">${fmtTime(c.startSeconds)}–${fmtTime(c.endSeconds)}</span> ${c.label}
        </button>
        <button type="button" data-del-clip="${c.id}" class="text-slate-600 hover:text-red-400">✕</button>
      </div>`
          )
          .join("")
      : '<p class="text-slate-600">No clips yet.</p>';
  }

  document.getElementById("markers-list").addEventListener("click", async (evt) => {
    const jump = evt.target.closest("[data-jump]");
    if (jump) {
      seekAllTo(parseFloat(jump.dataset.jump));
      updateScrubUI();
      return;
    }
    const del = evt.target.closest("[data-del-marker]");
    if (del) {
      await api(`/api/markers/${del.dataset.delMarker}`, { method: "DELETE" });
      loadMarkersAndClips();
    }
  });

  document.getElementById("clips-list").addEventListener("click", async (evt) => {
    const jump = evt.target.closest("[data-jump]");
    if (jump) {
      seekAllTo(parseFloat(jump.dataset.jump));
      updateScrubUI();
      return;
    }
    const del = evt.target.closest("[data-del-clip]");
    if (del) {
      await api(`/api/clips/${del.dataset.delClip}`, { method: "DELETE" });
      loadMarkersAndClips();
    }
  });

  // --- Notes ---------------------------------------------------------------

  async function loadNotes() {
    if (TENANT_MODE) {
      document.getElementById("notes-list").innerHTML =
        '<p class="text-slate-600">Not available for community-hosted evidence yet.</p>';
      return [];
    }
    const notes = await api(`/api/evidence/${PRIMARY.id}/notes`);
    const list = document.getElementById("notes-list");
    list.innerHTML = notes.length
      ? notes
          .map(
            (n) => `
      <div class="bg-base rounded-lg px-3 py-2">
        <div class="flex items-center justify-between text-[11px] text-slate-500">
          <span>${n.author || "Unknown"}</span>
          <span>${new Date(n.createdAt).toLocaleString()}</span>
        </div>
        <p class="text-slate-200 mt-1 whitespace-pre-wrap">${n.body}</p>
      </div>`
          )
          .join("")
      : '<p class="text-slate-600">No case notes yet.</p>';
    return notes;
  }

  document.getElementById("note-form").addEventListener("submit", async (evt) => {
    evt.preventDefault();
    const author = document.getElementById("note-author").value;
    const body = document.getElementById("note-body").value.trim();
    if (!body) return;
    await api(`/api/evidence/${PRIMARY.id}/notes`, { method: "POST", body: JSON.stringify({ author, body }) });
    document.getElementById("note-body").value = "";
    loadNotes();
  });

  // --- Transcript ------------------------------------------------------------

  document.getElementById("transcript-text").value = PRIMARY.transcript || "";
  document.getElementById("btn-save-transcript").addEventListener("click", async () => {
    const value = document.getElementById("transcript-text").value;
    await api(`/api/evidence/${PRIMARY.id}/transcript`, { method: "PATCH", body: JSON.stringify({ transcript: value }) });
    PRIMARY.transcript = value;
    const saved = document.getElementById("transcript-saved");
    saved.classList.remove("hidden");
    setTimeout(() => saved.classList.add("hidden"), 1500);
  });

  // --- Device serial -----------------------------------------------------

  document.getElementById("btn-save-serial").addEventListener("click", async () => {
    const value = document.getElementById("device-serial").value;
    await api(`/api/evidence/${PRIMARY.id}/device-serial`, { method: "PATCH", body: JSON.stringify({ deviceSerial: value }) });
    PRIMARY.deviceSerial = value;
    const serialLine = cams[0].el.querySelector(".serial-line");
    if (serialLine) serialLine.textContent = `SN ${value || "—"}`;
  });

  // --- Add to case ---------------------------------------------------------

  async function loadCaseSelect() {
    const select = document.getElementById("case-select");
    if (TENANT_MODE) {
      select.innerHTML = '<option value="">Not available for community-hosted evidence yet</option>';
      return;
    }
    try {
      const cases = await api(`/api/cases?status=open`);
      select.innerHTML = cases.length
        ? cases.map((c) => `<option value="${c.id}">${c.title}</option>`).join("")
        : '<option value="">No open cases</option>';
    } catch (e) {
      select.innerHTML = '<option value="">Couldn’t load cases</option>';
    }
  }

  document.getElementById("btn-add-to-case").addEventListener("click", async () => {
    const caseId = document.getElementById("case-select").value;
    if (!caseId) return;
    await api(`/api/cases/${caseId}/evidence`, { method: "POST", body: JSON.stringify({ evidenceId: PRIMARY.id }) });
    const added = document.getElementById("case-added");
    added.classList.remove("hidden");
    setTimeout(() => added.classList.add("hidden"), 1500);
  });

  // --- Multicam picker -------------------------------------------------

  let relatedCache = [];

  async function loadRelated() {
    if (TENANT_MODE) {
      document.getElementById("related-list").innerHTML =
        '<p class="text-slate-600">Not available for community-hosted evidence yet.</p>';
      return;
    }
    relatedCache = await api(`/api/evidence/${PRIMARY.id}/related?window=600`);
    renderRelatedList();
  }

  function renderRelatedList() {
    const list = document.getElementById("related-list");
    if (!relatedCache.length) {
      list.innerHTML = '<p class="text-slate-600">No other evidence captured nearby in time.</p>';
      return;
    }
    list.innerHTML = relatedCache
      .map((r) => {
        const added = cams.some((c) => c.data.id === r.id);
        return `
      <div class="flex items-center justify-between gap-2 bg-base rounded-lg px-2 py-1.5">
        <div class="min-w-0">
          <div class="text-slate-200 truncate">${r.submitterName || "Unknown officer"}</div>
          <div class="text-slate-600 text-[10px]">${new Date(r.createdAt).toLocaleTimeString()}</div>
        </div>
        <button type="button" data-add-cam="${r.id}" ${added || cams.length >= MAX_CAMS ? "disabled" : ""}
          class="shrink-0 text-[11px] px-2 py-1 rounded border ${added ? "border-accent2/50 text-accent2" : "border-border hover:border-accent/60 text-slate-300"} disabled:opacity-40">
          ${added ? "Added" : "+ Add"}
        </button>
      </div>`;
      })
      .join("");
  }

  document.getElementById("related-list").addEventListener("click", (evt) => {
    const btn = evt.target.closest("[data-add-cam]");
    if (!btn) return;
    const item = relatedCache.find((r) => r.id === parseInt(btn.dataset.addCam, 10));
    if (item) addCam(item);
  });

  // --- AI tools --------------------------------------------------------------

  document.getElementById("btn-gen-draft").addEventListener("click", async (evt) => {
    const btn = evt.currentTarget;
    btn.disabled = true;
    btn.textContent = "Generating…";
    try {
      const result = await api(`/api/evidence/${PRIMARY.id}/draft`, { method: "POST" });
      const out = document.getElementById("draft-output");
      out.textContent = result.ok ? result.content : result.error;
      out.classList.remove("hidden");
    } finally {
      btn.disabled = false;
      btn.textContent = "Generate";
    }
  });

  document.getElementById("btn-gen-brief").addEventListener("click", async (evt) => {
    const btn = evt.currentTarget;
    btn.disabled = true;
    btn.textContent = "Generating…";
    try {
      const result = await api(`/api/evidence/${PRIMARY.id}/brief`, { method: "POST" });
      const out = document.getElementById("brief-output");
      const summaryEl = document.getElementById("brief-summary");
      const milestonesEl = document.getElementById("brief-milestones");
      if (!result.ok) {
        summaryEl.textContent = result.error;
        milestonesEl.innerHTML = "";
      } else {
        summaryEl.textContent = result.summary;
        milestonesEl.innerHTML = (result.milestones || [])
          .map(
            (m) => `
          <div class="bg-base rounded-lg px-3 py-2">
            <div class="text-amber-400 font-medium">${m.label}</div>
            <div class="text-slate-400 text-[11px] mt-0.5">${m.note || ""}</div>
          </div>`
          )
          .join("");
      }
      out.classList.remove("hidden");
    } finally {
      btn.disabled = false;
      btn.textContent = "Generate";
    }
  });

  // --- Tabs ------------------------------------------------------------------

  document.getElementById("tab-bar").addEventListener("click", (evt) => {
    const btn = evt.target.closest(".tab-btn");
    if (!btn) return;
    document.querySelectorAll(".tab-btn").forEach((b) => {
      b.classList.toggle("border-accent", b === btn);
      b.classList.toggle("text-white", b === btn);
      b.classList.toggle("border-transparent", b !== btn);
      b.classList.toggle("text-slate-400", b !== btn);
    });
    document.querySelectorAll(".tab-pane").forEach((p) => {
      p.classList.toggle("hidden", p.dataset.pane !== btn.dataset.tab);
    });
  });

  // --- Global controls ---------------------------------------------------

  document.getElementById("btn-playpause").addEventListener("click", () => (isPlaying ? pauseAll() : playAll()));
  document.getElementById("btn-step-back").addEventListener("click", () => stepFrame(-1));
  document.getElementById("btn-step-fwd").addEventListener("click", () => stepFrame(1));
  document.querySelectorAll(".speed-btn").forEach((btn) => btn.addEventListener("click", () => setSpeed(parseFloat(btn.dataset.speed))));
  document.getElementById("range-brightness").addEventListener("input", applyEnvironment);
  document.getElementById("range-contrast").addEventListener("input", applyEnvironment);

  let clipStart = null;
  document.getElementById("btn-marker").addEventListener("click", async () => {
    const label = prompt("Marker label", "Flagged moment");
    if (label === null) return;
    await api(`/api/evidence/${PRIMARY.id}/markers`, {
      method: "POST",
      body: JSON.stringify({ label, timestampSeconds: primary().videoEl.currentTime }),
    });
    loadMarkersAndClips();
  });

  document.getElementById("btn-clip-in").addEventListener("click", () => {
    clipStart = primary().videoEl.currentTime;
    alert(`Clip start set at ${fmtTime(clipStart)} - play to the end point and click "Clip out".`);
  });

  document.getElementById("btn-clip-out").addEventListener("click", async () => {
    if (clipStart === null) {
      alert('Set "Clip in" first.');
      return;
    }
    const end = primary().videoEl.currentTime;
    if (end <= clipStart) {
      alert("Clip out must be after clip in.");
      return;
    }
    const label = prompt("Clip label", "Clip");
    if (label === null) return;
    await api(`/api/evidence/${PRIMARY.id}/clips`, {
      method: "POST",
      body: JSON.stringify({ label, startSeconds: clipStart, endSeconds: end }),
    });
    clipStart = null;
    loadMarkersAndClips();
  });

  document.addEventListener("keydown", (evt) => {
    if (evt.target.tagName === "TEXTAREA" || evt.target.tagName === "INPUT") return;
    if (evt.code === "Space") {
      evt.preventDefault();
      isPlaying ? pauseAll() : playAll();
    } else if (evt.key === "a" || evt.key === "A") {
      stepFrame(-1);
    } else if (evt.key === "d" || evt.key === "D") {
      stepFrame(1);
    } else if (evt.key === "1") {
      setSpeed(1);
    } else if (evt.key === "2") {
      setSpeed(2);
    } else if (evt.key === "4") {
      setSpeed(4);
    }
  });

  // --- Bootstrap ---------------------------------------------------------

  const primaryCam = buildCamEl(PRIMARY, true);
  cams.push(primaryCam);
  renderGrid();

  primaryCam.videoEl.addEventListener("loadedmetadata", () => {
    updateScrubUI();
    renderMarkerTicks(markersCache, clipsCache);
  });
  primaryCam.videoEl.addEventListener("timeupdate", updateScrubUI);
  primaryCam.videoEl.addEventListener("play", () => {
    isPlaying = true;
    document.getElementById("btn-playpause").textContent = "Pause";
  });
  primaryCam.videoEl.addEventListener("pause", () => {
    isPlaying = false;
    document.getElementById("btn-playpause").textContent = "Play";
  });

  if (TENANT_MODE) {
    // Every one of these writes through control-plane-only models (Case/CaseNote/Marker/Clip/
    // Draft/Brief) keyed off this evidence row's id - meaningless (or cross-tenant-wrong) for
    // evidence that actually lives in a community's own MySQL database. api() throws for all of
    // them as a backstop; disabling the controls here is just so nothing looks clickable.
    [
      "btn-marker",
      "btn-clip-in",
      "btn-clip-out",
      "btn-save-transcript",
      "btn-save-serial",
      "btn-add-to-case",
      "btn-gen-draft",
      "btn-gen-brief",
    ].forEach((id) => {
      const el = document.getElementById(id);
      if (el) el.disabled = true;
    });
    const noteForm = document.getElementById("note-form");
    if (noteForm) noteForm.querySelector('button[type="submit"]').disabled = true;
  }

  applyEnvironment();
  loadNotes();
  loadMarkersAndClips();
  loadRelated();
  loadCaseSelect();
})();
