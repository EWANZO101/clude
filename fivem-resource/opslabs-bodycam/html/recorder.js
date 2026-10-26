'use strict';

/*
 * Bodycam recorder (NUI). Reads the game view through WebGL (FiveM exposes the game frame as a special texture —
 * the same trick screenshot-basic and the OPS Phone camera use), draws it with the date / time / officer / serial
 * overlay onto a canvas and records that canvas with MediaRecorder as webm.
 *  - long recordings are split into parts (Video.SegmentSeconds): the next part starts before the last one stops
 *  - each finished part gets its duration written in (MediaRecorder leaves it out, so players couldn't seek), then
 *    is handed to client/main.lua chunk by chunk; the server stores it and sends it to Xon Sight
 * The game picture as the player sees it, the game's own HUD (minimap) included; no NUI, no sound (no game audio in NUI).
 */

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-bodycam';
const IN_GAME = typeof GetParentResourceName === 'function';

async function post(name, data = {}) {
    const res = await fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(data) });
    const text = await res.text();
    return text ? JSON.parse(text) : null;
}

const cfg = { video: {}, hud: {}, beep: {}, voice: {}, upload: {} };
const S = { session: null, street: '', info: {}, part: 0, rec: null, partStart: 0, draw: null, segTimer: null, maxTimer: null, beepTimer: null, clock: null, startedAt: 0 };

/* ------------------------------------------------------------------ game view → canvas */

/**
 * One instance of this is the main (full-quality) recorder's capture pipeline; a second, independent instance
 * (Preroll, below) is the always-on rolling buffer - same technique, its own tiny canvas/GL context/MediaRecorder
 * so the two can run at completely different resolutions and start/stop independently of each other.
 */
function buildCapture() {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl', { antialias: false, alpha: false, depth: false, preserveDrawingBuffer: false });
    if (!gl) return null;
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, `
        attribute vec2 p; varying vec2 vUv; uniform vec4 uCrop;
        void main() { vUv = uCrop.xy + vec2(p.x * 0.5 + 0.5, p.y * 0.5 + 0.5) * uCrop.zw; gl_Position = vec4(p, 0.0, 1.0); }`));
    // downscaling the full-resolution game frame: 4 taps per output pixel instead of 1 (no shimmering edges)
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, `
        precision mediump float; varying vec2 vUv; uniform sampler2D uTex; uniform vec2 uStep;
        void main() {
            vec3 c = texture2D(uTex, vUv + vec2(-uStep.x, -uStep.y)).rgb + texture2D(uTex, vUv + vec2(uStep.x, -uStep.y)).rgb
                   + texture2D(uTex, vUv + vec2(-uStep.x, uStep.y)).rgb + texture2D(uTex, vUv + vec2(uStep.x, uStep.y)).rgb;
            gl_FragColor = vec4(c * 0.25, 1.0);
        }`));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
    gl.useProgram(prog);
    const u = { uCrop: gl.getUniformLocation(prog, 'uCrop'), uStep: gl.getUniformLocation(prog, 'uStep') };

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    // the game view texture: FiveM swaps the game frame into a texture set up exactly like this
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array(3));
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.uniform1i(gl.getUniformLocation(prog, 'uTex'), 0);

    const out = document.createElement('canvas');
    return { gl, glCanvas: c, out, ctx: out.getContext('2d', { alpha: false }), u };
}

const View = {
    gl: null, glCanvas: null, out: null, ctx: null, u: {},

    init() {
        if (this.gl) return true;
        const p = buildCapture();
        if (!p) return false;
        Object.assign(this, p);
        return true;
    },

    size(w, h) {
        for (const c of [this.glCanvas, this.out]) if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    },

    /** one frame: the centre of the game view at the output aspect, then the overlay */
    frame() {
        const gl = this.gl, w = this.out.width, h = this.out.height;
        const g = (window.innerWidth || 16) / (window.innerHeight || 9), a = w / h;
        gl.viewport(0, 0, w, h);
        const crop = a < g ? [(1 - a / g) / 2, 0, a / g, 1] : [0, (1 - g / a) / 2, 1, g / a];
        gl.uniform4fv(this.u.uCrop, crop);
        gl.uniform2f(this.u.uStep, 0.25 * crop[2] / w, 0.25 * crop[3] / h);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        const x = this.ctx;
        x.drawImage(this.glCanvas, 0, 0);
        if (cfg.video.Overlay !== false) this.overlay(x, w, h);
    },

    /**
     * Evidence watermark, Axon-style: two dark bands with yellow, upper-case, labelled fields in a fixed-width font so
     * every recording reads the same way.
     *   top     ● REC  2026-10-14  20:35:07 UTC                          OPS BODY CAM  X10977901
     *           UNIT 1-ADAM-12   OFFICER BEN JJA   DEPT LSPD · CAPTAIN       REC BC-12-1792… · PART 1
     *   bottom  EVENT CASE 4471 · AUTO: SHOTS FIRED                (only when there is one)
     *           LOC ALHAMBRA DR / NILAND AVE, SANDY SHORES          GPS 1985.2, 3820.7   HDG 245° WSW
     */
    overlay(x, w, h) {
        const s = S.session || {};
        const I = S.info;
        const Y = cfg.video.OverlayColor || '#ffd60a';
        const fs = Math.max(13, Math.round(h / 34));
        const lh = Math.round(fs * 1.32);
        const pad = Math.round(fs * 0.55);
        const up = (t) => String(t || '').toUpperCase();
        const p2 = (n) => String(n).padStart(2, '0');
        const d = new Date();
        const date = `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}`;
        const time = `${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}:${p2(d.getUTCSeconds())} UTC`;
        const DIRS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
        const hdg = I.heading == null ? '' : `HDG ${String(Math.round(I.heading) % 360).padStart(3, '0')}° ${DIRS[Math.round(I.heading / 22.5) % 16]}`;
        const gps = I.x == null ? '' : `GPS ${I.x.toFixed(1)}, ${I.y.toFixed(1)}`;
        const dept = [s.dept, s.rank].filter(Boolean).join(' · ');
        const event = [s.note, s.trigger && s.trigger !== 'manual' ? 'AUTO: ' + s.trigger : ''].filter(Boolean).join(' · ');

        x.font = `bold ${fs}px Consolas, "Lucida Console", "DejaVu Sans Mono", "Courier New", monospace`;
        x.textBaseline = 'middle';
        x.lineJoin = 'round';
        // a field: grey label + yellow value, returns where it ended
        const field = (label, value, tx, ty, align) => {
            const lw = label ? x.measureText(label + ' ').width : 0;
            const vw = x.measureText(value).width;
            let sx = align === 'right' ? tx - lw - vw : tx;
            x.textAlign = 'left';
            x.lineWidth = Math.max(2, fs / 4.5);
            x.strokeStyle = 'rgba(0,0,0,.9)';
            if (label) { x.strokeText(label, sx, ty); x.fillStyle = 'rgba(255,255,255,.72)'; x.fillText(label, sx, ty); sx += lw; }
            x.strokeText(value, sx, ty); x.fillStyle = Y; x.fillText(value, sx, ty);
            return sx + vw;
        };
        const row = (items, tx, ty) => {
            let cx = tx;
            for (const [label, value] of items) { if (value) cx = field(label, up(value), cx, ty, 'left') + fs * 1.1; }
        };

        // top band
        const topH = pad * 2 + lh * 2;
        x.fillStyle = 'rgba(0,0,0,.62)';
        x.fillRect(0, 0, w, topH);
        const y1 = pad + lh / 2, y2 = pad + lh * 1.5;
        x.fillStyle = '#ff3b30';
        x.beginPath(); x.arc(pad + fs * 0.4, y1, fs * 0.36, 0, Math.PI * 2); x.fill();
        field('REC', `${date}  ${time}`, pad + fs * 1.0, y1, 'left');
        field('', `${up(cfg.video.OverlayTitle || 'BODY CAM')}  ${s.serial || ''}`.trim(), w - pad, y1, 'right');
        row([['UNIT', s.callsign], ['OFFICER', s.name || s.officer], ['DEPT', dept]], pad, y2);
        field('ID', `${up(s.id || '')} · PART ${S.part || 1}`, w - pad, y2, 'right');

        // bottom band
        const lines = event ? 2 : 1;
        const botH = pad * 2 + lh * lines;
        x.fillStyle = 'rgba(0,0,0,.62)';
        x.fillRect(0, h - botH, w, botH);
        const yb = h - pad - lh / 2;
        if (event) field('EVENT', up(event), pad, yb - lh, 'left');
        const right = [gps, hdg].filter(Boolean).join('   ');
        const rw = right ? x.measureText(right).width + fs * 2 : 0;
        let loc = up(I.street || '');
        while (loc && x.measureText('LOC ' + loc).width > w - pad * 2 - rw) loc = loc.slice(0, -2) + '…';
        if (loc) field('LOC', loc, pad, yb, 'left');
        if (right) field('', right, w - pad, yb, 'right');
    },
};

/* ------------------------------------------------------------------ pre-event rolling buffer (Config.PreRoll)
 *
 * Always-on while an officer is eligible and not already recording: a separate, much smaller/cheaper capture
 * (own tiny canvas + GL context + MediaRecorder, built with the same buildCapture() as View above) that rotates
 * through short self-contained segments and keeps only the last few. A single MediaRecorder's later chunks
 * aren't independently playable (only the very first chunk of a session carries the WebM header), so a true
 * "trim old frames, keep new ones" buffer isn't possible with one continuous recorder - this restarts the
 * recorder itself every segment instead, so every kept segment is its own complete, valid, playable file.
 * On a real trigger (Preroll.flush), whatever's buffered ships as its own short "PRE-EVENT BUFFER" evidence
 * part(s) - not spliced into the real recording, but immediately before it and clearly labelled as what it is.
 */
const Preroll = {
    pipe: null, cfg: null, drawId: null, rec: null, segTimer: null, running: false,
    ring: [], ringMax: 3, segSeconds: 10,

    ensure() {
        if (this.pipe) return true;
        this.pipe = buildCapture();
        return !!this.pipe;
    },

    start(preCfg) {
        if (this.running || !preCfg || typeof MediaRecorder === 'undefined') return;
        if (!this.ensure() || !this.pipe.out.captureStream) return;
        this.cfg = preCfg;
        this.segSeconds = Math.max(5, Math.round((preCfg.Seconds || 30) / 3));
        this.ringMax = Math.max(1, Math.ceil((preCfg.Seconds || 30) / this.segSeconds));
        const w = preCfg.Width || 320, h = preCfg.Height || 180, fps = preCfg.Fps || 8;
        for (const c of [this.pipe.glCanvas, this.pipe.out]) { c.width = w; c.height = h; }
        this.running = true;
        this.ring = [];
        this.drawId = setInterval(() => this.frame(), Math.round(1000 / fps));
        this.beginSegment();
    },

    frame() {
        const p = this.pipe, w = p.out.width, h = p.out.height;
        const gl = p.gl;
        const g = (window.innerWidth || 16) / (window.innerHeight || 9), a = w / h;
        gl.viewport(0, 0, w, h);
        const crop = a < g ? [(1 - a / g) / 2, 0, a / g, 1] : [0, (1 - g / a) / 2, 1, g / a];
        gl.uniform4fv(p.u.uCrop, crop);
        gl.uniform2f(p.u.uStep, 0.25 * crop[2] / w, 0.25 * crop[3] / h);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        p.ctx.drawImage(p.glCanvas, 0, 0);
        if (cfg.video.Overlay !== false) View.overlay(p.ctx, w, h);
    },

    beginSegment() {
        if (!this.running) return;
        const v = this.cfg;
        const mime = MIME.find((m) => MediaRecorder.isTypeSupported(m));
        const stream = this.pipe.out.captureStream(v.Fps || 8);
        const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: v.Bitrate || 200000 });
        const chunks = [];
        const segStart = Date.now();
        rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
        rec.onstop = () => {
            stream.getTracks().forEach((t) => t.stop());
            const blob = new Blob(chunks, { type: 'video/webm' });
            if (blob.size > 2048) {
                this.ring.push({ blob, start: segStart, ms: Date.now() - segStart });
                if (this.ring.length > this.ringMax) this.ring.shift();
            }
            if (this.running && this.rec === rec) this.beginSegment();   // keep rotating
        };
        rec.start();
        this.rec = rec;
        clearTimeout(this.segTimer);
        this.segTimer = setTimeout(() => { if (this.rec === rec) rec.stop(); }, this.segSeconds * 1000);
    },

    /** eligibility gone (off duty, job change, ...) - stop without handing anything over */
    stop() {
        if (!this.running) return;
        this.running = false;
        clearInterval(this.drawId); this.drawId = null;
        clearTimeout(this.segTimer);
        const rec = this.rec;
        this.rec = null;
        if (rec && rec.state !== 'inactive') {
            rec.onstop = () => rec.stream && rec.stream.getTracks().forEach((t) => t.stop());
            rec.stop();
        }
        this.ring = [];
    },

    /** a real recording is starting: finish the in-flight segment (so the freshest few seconds aren't lost),
     * then hand every buffered segment over as its own short evidence part, oldest first. */
    flush(session) {
        const handOver = () => {
            const segs = this.ring.slice();
            this.ring = [];
            segs.forEach((seg, i) => {
                const part = { n: 0, session: session.id, street: S.street, start: seg.start, preroll: true, index: i + 1, of: segs.length };
                Uploader.add(seg.blob, part, seg.ms);
            });
        };
        if (!this.running || !this.rec || this.rec.state === 'inactive') {
            this.stop();
            handOver();
            return;
        }
        this.running = false;      // beginSegment()'s own onstop won't try to rotate again
        clearInterval(this.drawId); this.drawId = null;
        clearTimeout(this.segTimer);
        const rec = this.rec;
        this.rec = null;
        const original = rec.onstop;
        rec.onstop = (ev) => { original(ev); handOver(); };
        rec.stop();
    },
};

/* ------------------------------------------------------------------ live video (MediaMTX WHIP publish)
 *
 * Entirely separate from View/Preroll above: its own capture pipe (buildCapture(), same technique), own draw
 * loop, own small overlay - no MediaRecorder, no chunked upload, no Xon Sight evidence item. The picture goes
 * straight out over WebRTC to MediaMTX via WHIP (a plain SDP offer/answer POST - no library needed, every
 * evergreen browser's RTCPeerConnection does this natively). Kept fully independent of View's state so a live
 * broadcast and a real evidence recording can run at the same time without fighting over canvas size/fps.
 */
const Live = {
    pipe: null, pc: null, drawId: null, cfg: null, active: false, resource: null,

    ensure() {
        if (this.pipe) return true;
        this.pipe = buildCapture();
        return !!this.pipe;
    },

    frame() {
        const p = this.pipe, w = p.out.width, h = p.out.height;
        const gl = p.gl;
        const g = (window.innerWidth || 16) / (window.innerHeight || 9), a = w / h;
        gl.viewport(0, 0, w, h);
        const crop = a < g ? [(1 - a / g) / 2, 0, a / g, 1] : [0, (1 - g / a) / 2, 1, g / a];
        gl.uniform4fv(p.u.uCrop, crop);
        gl.uniform2f(p.u.uStep, 0.25 * crop[2] / w, 0.25 * crop[3] / h);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        p.ctx.drawImage(p.glCanvas, 0, 0);
        this.overlay(p.ctx, w, h);
    },

    /** one lean band top and bottom - not the full evidence watermark (no REC dot, no PART/unit/event fields
     * that don't apply here), kept deliberately separate from View.overlay so recording and live video never
     * share (and fight over) the same OverlayTitle/config. */
    overlay(x, w, h) {
        const Y = '#ff3b30';
        const fs = Math.max(13, Math.round(h / 34));
        const pad = Math.round(fs * 0.55);
        x.font = `bold ${fs}px Consolas, "Lucida Console", "DejaVu Sans Mono", "Courier New", monospace`;
        x.textBaseline = 'middle';
        x.lineJoin = 'round';
        x.lineWidth = Math.max(2, fs / 4.5);
        x.strokeStyle = 'rgba(0,0,0,.9)';

        const topH = pad * 2 + fs * 1.3;
        x.fillStyle = 'rgba(0,0,0,.62)';
        x.fillRect(0, 0, w, topH);
        const y = pad + fs * 0.65;
        x.fillStyle = '#ff3b30';
        x.beginPath(); x.arc(pad + fs * 0.4, y, fs * 0.36, 0, Math.PI * 2); x.fill();
        const d = new Date();
        const p2 = (n) => String(n).padStart(2, '0');
        const stamp = `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())} ${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}:${p2(d.getUTCSeconds())} UTC`;
        x.textAlign = 'left';
        x.strokeText(`LIVE  ${stamp}`, pad + fs * 1.0, y);
        x.fillStyle = Y; x.fillText(`LIVE  ${stamp}`, pad + fs * 1.0, y);
        const title = (this.cfg && this.cfg.OverlayTitle) || 'LIVE';
        x.textAlign = 'right';
        x.strokeStyle = 'rgba(0,0,0,.9)'; x.strokeText(title, w - pad, y);
        x.fillStyle = Y; x.fillText(title, w - pad, y);

        if (S.street) {
            const botH = pad * 2 + fs * 1.1;
            x.fillStyle = 'rgba(0,0,0,.62)';
            x.fillRect(0, h - botH, w, botH);
            const yb = h - pad - fs * 0.5;
            const loc = String(S.street).toUpperCase();
            x.textAlign = 'left';
            x.strokeStyle = 'rgba(0,0,0,.9)'; x.strokeText(loc, pad, yb);
            x.fillStyle = Y; x.fillText(loc, pad, yb);
        }
    },

    async start(cfg) {
        if (this.active) return;
        if (!this.ensure() || !this.pipe.out.captureStream || typeof RTCPeerConnection === 'undefined') {
            post('liveState', { state: 'error', error: 'no capture/WebRTC in this game client' });
            return;
        }
        this.cfg = cfg || {};
        this.active = true;
        const w = this.cfg.Width || 1280, h = this.cfg.Height || 720, fps = this.cfg.Fps || 24;
        for (const c of [this.pipe.glCanvas, this.pipe.out]) { c.width = w; c.height = h; }
        this.drawId = setInterval(() => this.frame(), Math.round(1000 / fps));
        const stream = this.pipe.out.captureStream(fps);
        this.pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
        for (const track of stream.getVideoTracks()) this.pc.addTrack(track, stream);
        this.pc.onconnectionstatechange = () => {
            const st = this.pc && this.pc.connectionState;
            if (this.active && (st === 'failed' || st === 'disconnected' || st === 'closed')) post('liveState', { state: 'error', error: st });
        };
        try {
            const offer = await this.pc.createOffer();
            await this.pc.setLocalDescription(offer);
            // non-trickle: wait for every ICE candidate so the offer is complete in one shot (simpler than
            // trickling candidates over separate PATCH requests, at the cost of a short delay here)
            await new Promise((resolve) => {
                if (this.pc.iceGatheringState === 'complete') return resolve();
                const check = () => {
                    if (this.pc.iceGatheringState === 'complete') { this.pc.removeEventListener('icegatheringstatechange', check); resolve(); }
                };
                this.pc.addEventListener('icegatheringstatechange', check);
                setTimeout(resolve, 4000);    // don't hang forever on a flaky network - send what we have
            });
            // the token rides the query string, not an Authorization header - verified live against MediaMTX's
            // authHTTPAddress webhook (every protocol forwards `query` reliably; a Bearer header's mapping
            // wasn't checked, so this sticks to the path that's actually confirmed to work)
            const sep = this.cfg.whip.includes('?') ? '&' : '?';
            const res = await fetch(`${this.cfg.whip}${sep}token=${encodeURIComponent(this.cfg.token || '')}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/sdp' },
                body: this.pc.localDescription.sdp,
            });
            if (!res.ok) throw new Error('HTTP ' + res.status);
            this.resource = res.headers.get('Location');
            const answer = await res.text();
            await this.pc.setRemoteDescription({ type: 'answer', sdp: answer });
        } catch (e) {
            const err = String((e && e.message) || e);
            this.teardown();
            post('liveState', { state: 'error', error: err });
        }
    },

    teardown() {
        this.active = false;
        if (this.drawId) { clearInterval(this.drawId); this.drawId = null; }
        if (this.pc) { try { this.pc.close(); } catch (_) { /* already closed */ } this.pc = null; }
    },

    async stop() {
        if (!this.active && !this.pc) return;
        const resource = this.resource;
        this.resource = null;
        this.teardown();
        if (resource) { try { await fetch(resource, { method: 'DELETE' }); } catch (_) { /* MediaMTX will time it out anyway */ } }
    },
};

/* ------------------------------------------------------------------ webm duration (so the portal's player can seek) */

const Webm = {
    vint(b, i) {
        const first = b[i];
        let len = 1, mask = 0x80;
        while (len <= 8 && !(first & mask)) { len++; mask >>= 1; }
        if (len > 8) return null;
        let v = first & (mask - 1), unknown = v === mask - 1;
        for (let k = 1; k < len; k++) { v = v * 256 + b[i + k]; if (b[i + k] !== 0xff) unknown = false; }
        return { len, value: v, unknown };
    },
    idLen(first) { let len = 1, mask = 0x80; while (len <= 4 && !(first & mask)) { len++; mask >>= 1; } return len; },
    encode(value, len) {
        const out = new Uint8Array(len);
        let v = value;
        for (let k = len - 1; k >= 0; k--) { out[k] = v % 256; v = Math.floor(v / 256); }
        out[0] |= 0x80 >> (len - 1);
        return out;
    },
    find(b, from, to, id) {
        for (let i = from; i + id.length <= to; i++) if (id.every((x, k) => b[i + k] === x)) return i;
        return -1;
    },

    /** blob with a Duration element added to Segment › Info; the original blob if anything looks unusual */
    async fix(blob, ms) {
        try {
            const headLen = Math.min(blob.size, 65536);
            const b = new Uint8Array(await blob.slice(0, headLen).arrayBuffer());
            const seg = this.find(b, 0, headLen, [0x18, 0x53, 0x80, 0x67]);
            if (seg < 0) return blob;
            const segSize = this.vint(b, seg + 4);
            const info = this.find(b, seg, headLen, [0x15, 0x49, 0xa9, 0x66]);
            if (info < 0 || !segSize) return blob;
            const infoSize = this.vint(b, info + 4);
            if (!infoSize || infoSize.unknown) return blob;
            const body = info + 4 + infoSize.len, end = body + infoSize.value;
            if (end > headLen) return blob;
            let scale = 1000000;
            for (let i = body; i < end;) {
                const il = this.idLen(b[i]);
                const id = Array.from(b.slice(i, i + il));
                const sz = this.vint(b, i + il);
                if (!sz) return blob;
                const val = i + il + sz.len;
                if (id.length === 2 && id[0] === 0x44 && id[1] === 0x89) return blob;     // already has a duration
                if (id.length === 3 && id[0] === 0x2a && id[1] === 0xd7 && id[2] === 0xb1) { scale = 0; for (let k = 0; k < sz.value; k++) scale = scale * 256 + b[val + k]; }
                i = val + sz.value;
            }
            const dur = new Uint8Array(11);
            dur.set([0x44, 0x89, 0x88]);
            new DataView(dur.buffer).setFloat64(3, ms * 1e6 / (scale || 1000000));
            const newInfo = infoSize.value + dur.length;
            const parts = [];
            if (segSize.unknown) {
                parts.push(b.slice(0, info));
            } else {        // a known segment size grows too
                parts.push(b.slice(0, seg + 4), this.encode(segSize.value + dur.length + (8 - infoSize.len), 8), b.slice(seg + 4 + segSize.len, info));
            }
            parts.push(b.slice(info, info + 4), this.encode(newInfo, 8), b.slice(body, end), dur, blob.slice(end));
            return new Blob(parts, { type: 'video/webm' });
        } catch (e) {
            return blob;
        }
    },
};

/* ------------------------------------------------------------------ recording */

const MIME = ['video/webm;codecs=vp8', 'video/webm;codecs=vp9', 'video/webm'];

function startPart() {
    const v = cfg.video;
    const mime = MIME.find((m) => MediaRecorder.isTypeSupported(m));
    const stream = View.out.captureStream(v.Fps || 20);
    const rec = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: v.Bitrate || 1200000 });
    const part = { n: ++S.part, chunks: [], start: Date.now(), session: S.session.id, street: S.street };
    rec.ondataavailable = (e) => { if (e.data && e.data.size) part.chunks.push(e.data); };
    rec.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        const blob = new Blob(part.chunks, { type: 'video/webm' });
        if (blob.size > 2048) Uploader.add(blob, part, Date.now() - part.start);
    };
    rec.start(1000);
    post('partStarted', { session: part.session, part: part.n }).catch(() => {});    // time zero for this part's voice
    S.rec = rec;
    clearTimeout(S.segTimer);
    S.segTimer = setTimeout(() => {         // next part first, then close this one: no gap
        if (S.rec !== rec) return;
        startPart();
        rec.stop();
    }, Math.max(30, v.SegmentSeconds || 180) * 1000);
}

function start(session) {
    if (S.session) return;
    if (!View.init() || typeof MediaRecorder === 'undefined' || !View.out.captureStream) {
        console.log('[opslabs-bodycam] this game client cannot record video (no WebGL / MediaRecorder)');
        post('cannotRecord');
        return;
    }
    S.session = session;
    S.part = 0;
    S.startedAt = Date.now();
    const v = cfg.video;
    View.size(v.Width || 960, v.Height || 540);
    View.frame();
    S.draw = setInterval(() => View.frame(), Math.round(1000 / (v.Fps || 20)));
    startPart();
    if (v.MaxMinutes > 0) S.maxTimer = setTimeout(() => post('maxLength'), v.MaxMinutes * 60000);
    if (cfg.beep.OnStartStop !== false) Beep.play(1);
    if (cfg.beep.Interval > 0) S.beepTimer = setInterval(() => Beep.play(2), cfg.beep.Interval * 1000);
    if (cfg.voice.Enabled !== false) Speech.say(cfg.voice.OnStart);
    Hud.show();
}

function stop() {
    if (!S.session) return;
    clearTimeout(S.segTimer); clearTimeout(S.maxTimer); clearInterval(S.beepTimer);
    const rec = S.rec, drawId = S.draw;
    S.rec = null;
    S.draw = null;
    S.session = null;
    if (rec && rec.state !== 'inactive') {      // keep drawing until the recorder has its last frames
        const done = rec.onstop;
        rec.onstop = () => { done(); clearInterval(drawId); };
        rec.stop();
    } else clearInterval(drawId);
    if (cfg.beep.OnStartStop !== false) Beep.play(1, 520);
    if (cfg.voice.Enabled !== false) Speech.say(cfg.voice.OnStop);
    Hud.update();
}

/* ------------------------------------------------------------------ upload: one part at a time, chunk by chunk */

const Uploader = {
    queue: [], running: false,

    add(blob, part, ms) { this.queue.push({ blob, part, ms }); Hud.update(); this.run(); },

    async run() {
        if (this.running) return;
        this.running = true;
        while (this.queue.length) {
            const job = this.queue[0];
            let error = null;
            try {
                error = await this.send(job);
            } catch (e) { error = String(e && e.message || e); }
            this.queue.shift();
            await post('partEnd', { part: job.part.n, error });
            Hud.update();
        }
        this.running = false;
    },

    async send({ blob, part, ms }) {
        const fixed = await Webm.fix(blob, ms);
        const b64 = await new Promise((ok, fail) => {
            const fr = new FileReader();
            fr.onload = () => ok(String(fr.result).replace(/^data:[^,]*,/, ''));
            fr.onerror = () => fail(fr.error);
            fr.readAsDataURL(fixed);
        });
        const size = Math.max(4, (cfg.upload.ChunkKB || 384) * 1024 & ~3);
        const chunks = Math.ceil(b64.length / size);
        const r = await post('partBegin', {
            session: part.session, part: part.n, size: fixed.size, chunks, duration: Math.round(ms / 1000), durationMs: Math.round(ms),
            startedAt: Math.floor(part.start / 1000), street: part.street,
            preroll: part.preroll || false, segIndex: part.index, segCount: part.of,
        });
        if (!r || !r.ok) return (r && r.reason) || 'refused';
        for (let i = 0; i < chunks; i++) {
            Hud.progress(part.n, i / chunks);
            const ok = await post('chunk', { upload: r.upload, index: i + 1, data: b64.slice(i * size, (i + 1) * size) });
            if (!ok) return 'upload interrupted';
        }
        return null;
    },
};

/* ------------------------------------------------------------------ HUD + beeps */

const Hud = {
    el: document.getElementById('hud'),
    time: document.getElementById('hud-time'),
    up: document.getElementById('hud-up'),
    pct: null,

    show() { this.update(); if (!S.clock) S.clock = setInterval(() => this.tick(), 500); },
    tick() {
        if (!S.session) return;
        const s = Math.floor((Date.now() - S.startedAt) / 1000);
        const p2 = (n) => String(n).padStart(2, '0');
        this.time.textContent = s >= 3600 ? `${Math.floor(s / 3600)}:${p2(Math.floor(s / 60) % 60)}:${p2(s % 60)}` : `${p2(Math.floor(s / 60))}:${p2(s % 60)}`;
    },
    progress(n, f) { this.pct = `part ${n} ${Math.round(f * 100)}%`; this.update(); },
    update() {
        const on = cfg.hud.Enabled !== false;
        const waiting = Uploader.queue.length;
        this.el.className = `hud ${cfg.hud.Position || 'top-right'}${S.session ? '' : ' idle'}`;
        this.el.hidden = !on || (!S.session && !waiting);
        this.up.hidden = !waiting;
        this.up.textContent = waiting ? `⇪ ${this.pct || 'uploading'}${waiting > 1 ? ` (+${waiting - 1})` : ''}` : '';
        if (!waiting) this.pct = null;
        if (!S.session) { this.time.textContent = waiting ? 'Uploading footage' : ''; if (!waiting) { clearInterval(S.clock); S.clock = null; } }
        else this.tick();
    },
};

const Beep = {
    ctx: null,
    play(times, freq = 960) {
        try {
            if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)();
            const t0 = this.ctx.currentTime + 0.02, vol = cfg.beep.Volume != null ? cfg.beep.Volume : 0.25;
            for (let i = 0; i < times; i++) {
                const o = this.ctx.createOscillator(), g = this.ctx.createGain();
                const t = t0 + i * 0.22;
                o.frequency.value = freq;
                g.gain.setValueAtTime(0, t);
                g.gain.linearRampToValueAtTime(vol, t + 0.01);
                g.gain.setValueAtTime(vol, t + 0.12);
                g.gain.linearRampToValueAtTime(0, t + 0.14);
                o.connect(g).connect(this.ctx.destination);
                o.start(t);
                o.stop(t + 0.16);
            }
        } catch (_) { /* no audio device */ }
    },
};

/** Config.Voice: a spoken line through whatever TTS voice the client's browser engine has, if any - not every
 * FiveM client build necessarily ships one, so this stays a silent no-op rather than erroring when it can't. */
const Speech = {
    say(text) {
        if (!text) return;
        try {
            if (!window.speechSynthesis || typeof SpeechSynthesisUtterance === 'undefined') return;
            const u = new SpeechSynthesisUtterance(text);
            u.rate = cfg.voice.Rate || 1.0;
            u.pitch = cfg.voice.Pitch || 1.0;
            u.volume = cfg.voice.Volume != null ? cfg.voice.Volume : 0.8;
            window.speechSynthesis.cancel();   // don't queue a stale line behind a fresh one if these fire close together
            window.speechSynthesis.speak(u);
        } catch (_) { /* no TTS available in this client */ }
    },
};

/* ------------------------------------------------------------------ /bodycammic: is the microphone usable from the NUI? */

async function micTest() {
    try {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('getUserMedia is not available');
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        const track = stream.getAudioTracks()[0];
        // a second of level metering, to tell a working mic from a silent one
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        const an = ctx.createAnalyser();
        ctx.createMediaStreamSource(stream).connect(an);
        const buf = new Float32Array(an.fftSize);
        let peak = 0;
        const end = Date.now() + 1500;
        while (Date.now() < end) { an.getFloatTimeDomainData(buf); for (const v of buf) peak = Math.max(peak, Math.abs(v)); await new Promise((r) => setTimeout(r, 50)); }
        const devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'audioinput').length;
        stream.getTracks().forEach((t) => t.stop());
        ctx.close();
        post('micResult', { ok: true, label: track ? track.label : '', devices, peak: Math.round(peak * 1000) / 1000 });
    } catch (e) {
        post('micResult', { ok: false, error: (e && (e.name + ': ' + e.message)) || String(e) });
    }
}

/* ------------------------------------------------------------------ messages from client/main.lua */

window.addEventListener('message', (e) => {
    const m = e.data || {};
    if (m.action === 'start') {
        start(m.session);                                          // the real recording starts right away -
        if (Preroll.running) Preroll.flush(m.session);              // the buffer hand-off runs alongside it, not before it
    }
    else if (m.action === 'stop') stop();
    else if (m.action === 'overlay') { S.street = m.street || ''; S.info = { street: S.street, x: m.x, y: m.y, heading: m.heading }; }
    else if (m.action === 'note' && S.session) S.session.note = m.note || '';
    else if (m.action === 'micTest') micTest();
    else if (m.action === 'preroll') { if (m.enabled) Preroll.start(m.config); else Preroll.stop(); }
    else if (m.action === 'liveStart') Live.start(Object.assign({}, m.config, { whip: m.whip, token: m.token }));
    else if (m.action === 'liveStop') Live.stop();
});

if (IN_GAME) post('ready').then((c) => { if (c) Object.assign(cfg, c); Hud.update(); }).catch(() => {});
