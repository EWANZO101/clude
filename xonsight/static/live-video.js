// Live video panel (/live page) - plays each active broadcast (MediaMTX WHIP publish from
// opslabs-bodycam's html/recorder.js Live module) over WebRTC/WHEP. Polls /api/live-streams on the
// same cadence as live-map.js's recorder/feed polling, plus an immediate refresh on the
// "live.started"/"live.stopped" SSE events (xonsight/realtime.py) for snappier updates.
//
// WHEP only, no HLS fallback in the browser yet: WHEP works unmodified in every evergreen browser
// (Chrome, Firefox, Edge), native HLS playback is Safari-only otherwise and would need hls.js for
// everyone else. hlsUrl still comes back from the API for that later if it's ever needed.
(function () {
  if (!window.XON_SIGHT_LIVE_PAGE) return;

  const panel = document.getElementById("live-video-panel");
  const grid = document.getElementById("live-video-grid");
  const empty = document.getElementById("live-video-empty");
  if (!panel || !grid) return;

  const players = new Map(); // recorder id -> { pc, video, path }

  function tile(stream) {
    const el = document.createElement("div");
    el.className = "rounded-xl border border-border bg-black/40 overflow-hidden relative";
    el.innerHTML = `
      <video autoplay playsinline muted class="w-full aspect-video bg-black object-contain"></video>
      <div class="absolute top-2 left-2 flex items-center gap-1.5 bg-black/60 backdrop-blur px-2 py-1 rounded-lg text-[11px] text-slate-200">
        <span class="h-1.5 w-1.5 rounded-full bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.8)] live-dot"></span>
        <span class="font-medium"></span>
      </div>
      <div class="absolute bottom-2 left-2 right-2 text-[10px] text-slate-400 status"></div>`;
    el.querySelector("span.font-medium").textContent = `${stream.kind === "bodycam" ? "Bodycam" : "Dashcam"} · ${stream.name || stream.id}`;
    return el;
  }

  async function connect(stream, video, statusEl) {
    if (!stream.whepUrl) {
      statusEl.textContent = "MediaMTX not configured on this portal";
      return null;
    }
    const pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.l.google.com:19302" }] });
    pc.addTransceiver("video", { direction: "recvonly" });
    pc.ontrack = (e) => {
      video.srcObject = e.streams[0];
    };
    pc.onconnectionstatechange = () => {
      statusEl.textContent = pc.connectionState === "connected" ? "" : pc.connectionState;
    };
    try {
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await new Promise((resolve) => {
        if (pc.iceGatheringState === "complete") return resolve();
        const check = () => {
          if (pc.iceGatheringState === "complete") {
            pc.removeEventListener("icegatheringstatechange", check);
            resolve();
          }
        };
        pc.addEventListener("icegatheringstatechange", check);
        setTimeout(resolve, 4000);
      });
      const res = await fetch(stream.whepUrl, {
        method: "POST",
        headers: { "Content-Type": "application/sdp" },
        body: pc.localDescription.sdp,
      });
      if (!res.ok) throw new Error(`WHEP ${res.status}`);
      const answer = await res.text();
      await pc.setRemoteDescription({ type: "answer", sdp: answer });
      return pc;
    } catch (err) {
      statusEl.textContent = "Could not connect";
      pc.close();
      return null;
    }
  }

  function stopPlayer(id) {
    const p = players.get(id);
    if (!p) return;
    if (p.pc) p.pc.close();
    if (p.el) p.el.remove();
    players.delete(id);
  }

  async function sync() {
    let streams = [];
    try {
      streams = await fetch("/api/live-streams").then((r) => r.json());
    } catch (err) {
      return;
    }
    const seen = new Set();
    for (const stream of streams) {
      seen.add(stream.id);
      if (players.has(stream.id)) continue;
      const el = tile(stream);
      grid.appendChild(el);
      const video = el.querySelector("video");
      const statusEl = el.querySelector(".status");
      players.set(stream.id, { el, pc: null, path: stream.path });
      connect(stream, video, statusEl).then((pc) => {
        const p = players.get(stream.id);
        if (p) p.pc = pc;
      });
    }
    for (const id of players.keys()) {
      if (!seen.has(id)) stopPlayer(id);
    }
    panel.hidden = streams.length === 0 && players.size === 0;
    if (empty) empty.hidden = streams.length > 0;
  }

  window.addEventListener("xonsight:live.started", sync);
  window.addEventListener("xonsight:live.stopped", sync);
  setInterval(sync, 3000);
  sync();
})();
