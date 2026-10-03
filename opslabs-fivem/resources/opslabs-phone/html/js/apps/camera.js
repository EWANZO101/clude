'use strict';

/*
 * Camera — works like the real phone camera app:
 *  - live viewfinder inside the phone screen: the game view is read through
 *    WebGL (FiveM exposes it as a special texture), cropped to the photo shape
 *  - Video / Photo / Portrait, .5× 1× 2× 5× lenses (+ scroll to zoom), selfie
 *  - flash (auto/on/off), timer, 4:3 / 1:1 / 16:9, exposure, grid, styles
 *  - tap to focus (refocuses Portrait depth of field), hold for AE/AF lock
 *  - shutter: on-screen button, Space/Enter, volume buttons, Camera Control
 *  - photos (jpg) and videos (webm) are uploaded to this server and appear in Photos
 * The Lua side (client/camera.lua) moves the scripted game camera.
 */

/* ---------------------------------------------------------------------
   game view renderer
   --------------------------------------------------------------------- */

const GameView = {
    canvas: null, gl: null, prog: null, tex: null, u: {}, fake: null,
    look: { yaw: 0, pitch: 0 },

    init(canvas) {
        const gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: false, preserveDrawingBuffer: false });
        if (!gl) return false;
        this.canvas = canvas;
        this.gl = gl;
        const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
        const prog = gl.createProgram();
        gl.attachShader(prog, sh(gl.VERTEX_SHADER, `
            attribute vec2 p; varying vec2 vUv; varying vec2 vPos;
            uniform vec4 uCrop; uniform float uMirror;
            void main() {
                vec2 t = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
                if (uMirror > 0.5) t.x = 1.0 - t.x;
                vUv = uCrop.xy + t * uCrop.zw;
                vPos = p;
                gl_Position = vec4(p, 0.0, 1.0);
            }`));
        gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, `
            precision mediump float;
            varying vec2 vUv; varying vec2 vPos;
            uniform sampler2D uTex;
            uniform float uExp, uSat, uCon, uMono, uVig;
            uniform vec3 uTint;
            void main() {
                vec3 c = texture2D(uTex, vUv).rgb * uExp;
                c = (c - 0.5) * uCon + 0.5;
                float l = dot(c, vec3(0.299, 0.587, 0.114));
                c = mix(vec3(l), c, uSat);
                c = mix(c, vec3(l), uMono) * uTint;
                c *= 1.0 - uVig * dot(vPos, vPos) * 0.32;
                gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
            }`));
        gl.linkProgram(prog);
        if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return false;
        gl.useProgram(prog);
        this.prog = prog;
        for (const n of ['uCrop', 'uMirror', 'uTex', 'uExp', 'uSat', 'uCon', 'uMono', 'uVig', 'uTint']) this.u[n] = gl.getUniformLocation(prog, n);

        const buf = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, buf);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
        const loc = gl.getAttribLocation(prog, 'p');
        gl.enableVertexAttribArray(loc);
        gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

        // the game view texture: the same setup screenshot-basic uses, FiveM swaps in the game frame
        const tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array(3));
        if (IN_GAME) {
            gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
            gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
        } else {
            this.fake = document.createElement('canvas');
            this.fake.width = 1280; this.fake.height = 720;
        }
        this.tex = tex;
        gl.uniform1i(this.u.uTex, 0);
        return true;
    },

    /** aspect of the full game frame (the NUI page covers the whole game window) */
    gameAspect() { return (window.innerWidth || 16) / (window.innerHeight || 9); },

    /** uv crop of the centre of the game frame with the given output aspect */
    crop(aspect) {
        const g = this.gameAspect();
        return aspect < g ? [(1 - aspect / g) / 2, 0, aspect / g, 1] : [0, (1 - g / aspect) / 2, 1, g / aspect];
    },

    draw(w, h, look) {
        const gl = this.gl;
        if (!gl) return;
        if (this.canvas.width !== w || this.canvas.height !== h) { this.canvas.width = w; this.canvas.height = h; }
        gl.viewport(0, 0, w, h);
        if (this.fake) this.paintFake();
        const s = look.style;
        gl.uniform4fv(this.u.uCrop, this.crop(w / h));
        gl.uniform1f(this.u.uMirror, look.mirror ? 1 : 0);
        gl.uniform1f(this.u.uExp, Math.pow(2, look.ev || 0));
        gl.uniform1f(this.u.uSat, s.sat);
        gl.uniform1f(this.u.uCon, s.con);
        gl.uniform1f(this.u.uMono, s.mono);
        gl.uniform1f(this.u.uVig, look.vignette ? 1 : s.vig || 0);
        gl.uniform3fv(this.u.uTint, s.tint);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    },

    /** average brightness of the frame (flash Auto) */
    brightness() {
        const gl = this.gl;
        if (!gl) return 1;
        const px = new Uint8Array(4 * 16);
        const w = this.canvas.width, h = this.canvas.height;
        let sum = 0;
        for (let i = 0; i < 4; i++) {
            gl.readPixels(Math.floor(w * (0.2 + i * 0.2)), Math.floor(h / 2), 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, px);
            for (let j = 0; j < px.length; j += 4) sum += (px[j] + px[j + 1] + px[j + 2]) / 3;
        }
        return sum / (16 * 4) / 255;
    },

    /** preview only (outside the game): a simple moving street scene */
    paintFake() {
        const c = this.fake, g = c.getContext('2d'), t = performance.now() / 1000;
        const yaw = this.look.yaw, pitch = this.look.pitch;
        const horizon = 400 + pitch * 6;
        const sky = g.createLinearGradient(0, 0, 0, horizon);
        sky.addColorStop(0, '#3a7bd5'); sky.addColorStop(1, '#f6d6a8');
        g.fillStyle = sky; g.fillRect(0, 0, 1280, 720);
        g.fillStyle = '#ffe9a8'; g.beginPath(); g.arc(((900 - yaw * 8) % 1600 + 1600) % 1600 - 160, horizon - 220, 50, 0, 7); g.fill();
        for (let i = -2; i < 14; i++) {
            const x = ((i * 130 - yaw * 12) % 1820 + 1820) % 1820 - 270;
            const hgt = 120 + ((i * 97) % 5) * 60;
            g.fillStyle = `hsl(${210 + (i % 4) * 8},18%,${22 + (i % 3) * 6}%)`;
            g.fillRect(x, horizon - hgt, 110, hgt);
            g.fillStyle = 'rgba(255,230,150,.55)';
            for (let wy = horizon - hgt + 14; wy < horizon - 12; wy += 26) for (let wx = x + 12; wx < x + 100; wx += 24) g.fillRect(wx, wy, 10, 12);
        }
        g.fillStyle = '#3b3f45'; g.fillRect(0, horizon, 1280, 720 - horizon);
        g.fillStyle = '#e8e8e8'; for (let x = -((t * 300) % 160); x < 1280; x += 160) g.fillRect(x, horizon + 150, 80, 10);
        g.fillStyle = '#d0312d'; g.fillRect(((t * 260) % 1700) - 300, horizon + 70, 180, 60);
        const gl = this.gl;
        gl.bindTexture(gl.TEXTURE_2D, this.tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, c);
    },

    destroy() {
        const ext = this.gl && this.gl.getExtension('WEBGL_lose_context');
        if (ext) ext.loseContext();
        Object.assign(this, { canvas: null, gl: null, prog: null, tex: null, fake: null, u: {} });
    },
};

/* ---------------------------------------------------------------------
   options
   --------------------------------------------------------------------- */

const CAM_STYLES = [
    { id: 'standard', name: 'Standard', sat: 1, con: 1, mono: 0, tint: [1, 1, 1] },
    { id: 'vivid', name: 'Vivid', sat: 1.35, con: 1.08, mono: 0, tint: [1, 1, 1] },
    { id: 'warm', name: 'Vivid Warm', sat: 1.2, con: 1.04, mono: 0, tint: [1.08, 1, 0.88] },
    { id: 'cool', name: 'Vivid Cool', sat: 1.2, con: 1.04, mono: 0, tint: [0.9, 1, 1.1] },
    { id: 'dramatic', name: 'Dramatic', sat: 0.85, con: 1.28, mono: 0, tint: [0.97, 0.97, 0.97], vig: 0.8 },
    { id: 'mono', name: 'Mono', sat: 1, con: 1.05, mono: 1, tint: [1, 1, 1] },
    { id: 'silver', name: 'Silvertone', sat: 1, con: 1.2, mono: 1, tint: [1.02, 1, 0.97] },
    { id: 'noir', name: 'Noir', sat: 1, con: 1.55, mono: 1, tint: [0.95, 0.95, 0.95], vig: 1 },
];
const CAM_MODES = ['video', 'photo', 'portrait'];
const CAM_MODE_LABEL = { video: 'VIDEO', photo: 'PHOTO', portrait: 'PORTRAIT' };
const CAM_LENSES = { photo: [0.5, 1, 2, 5], video: [0.5, 1, 2, 5], portrait: [1, 2] };
const CAM_ASPECTS = { '4:3': 3 / 4, '1:1': 1, '16:9': 9 / 16 };

/** where the viewfinder sits on the 393×852 screen for an aspect */
function camLayout(mode, aspect) {
    if (mode === 'video' || aspect === '16:9') return { top: 76, h: 699 };
    if (aspect === '1:1') return { top: 178, h: 393 };
    return { top: 112, h: 524 };
}

/** upload a photo / video to the server; resolves with { id, url } */
async function uploadCameraMedia(dataUrl, type) {
    const tok = await rpc('cameraUploadToken');
    if (!tok) {
        // preview (no game server): keep it in the mock library
        if (!IN_GAME) { await rpc('savePhoto', { url: dataUrl }); return { url: dataUrl }; }
        throw new Error(I18N.t("Couldn't reach the server"));
    }
    if (tok.error) throw new Error(I18N.t('Saving photos needs a public address for this server (PublicUrl in config_server.lua).'));
    const res = await fetch(`${tok.url}&type=${type}`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: dataUrl.replace(/^data:[^,]*,/, '') });
    const out = await res.json().catch(() => ({}));
    if (!res.ok || !out.url) throw new Error(out.error === 'invalid_file' ? I18N.t('That file could not be saved') : I18N.t("Couldn't save to Photos"));
    RpcCache.markDirty();
    Phone.emit('photosChanged');
    return out;
}

const isVideoUrl = (u) => /\.webm(\?|$)|^data:video\//i.test(u || '');

/* ---------------------------------------------------------------------
   app
   --------------------------------------------------------------------- */

Apps.register({
    id: 'camera',
    resumable: false, // live view: always start fresh
    name: 'Camera',
    dark: true,
    splash: '#000',
    icon: {
        bg: 'linear-gradient(180deg,#f0f0f2,#a9a9ae)',
        html: () => `<svg viewBox="0 0 64 64" width="46" height="46"><rect x="6" y="18" width="52" height="34" rx="7" fill="#2b2b2e"/><path d="M22 18l4-6h12l4 6" fill="#2b2b2e"/><circle cx="32" cy="35" r="11" fill="#9a9aa0" stroke="#2b2b2e" stroke-width="3"/><circle cx="32" cy="35" r="6.5" fill="#3b3b40"/><circle cx="49" cy="25" r="2" fill="#e8e8ea"/></svg>`,
    },

    open(root, params, app) {
        const saved = Phone.settings.camera || {};
        const S = {
            mode: 'photo', front: false, zoom: 1,
            flash: saved.flash || 'auto', aspect: saved.aspect || '4:3', grid: !!saved.grid,
            timer: 0, ev: 0, style: CAM_STYLES.find((s) => s.id === saved.style) || CAM_STYLES[0],
            panel: null, recording: null, busy: false, locked: !!params.fromLock, session: [],
            running: true, aeLock: false,
        };
        const remember = () => Phone.saveSetting('camera', { flash: S.flash, aspect: S.aspect, grid: S.grid, style: S.style.id });
        if (S.locked) screenEl().classList.add('lock-cam');

        root.innerHTML = `
            <div class="cam">
                <div class="cam-vf">
                    <canvas class="cam-canvas"></canvas>
                    <div class="cam-grid"></div>
                    <div class="cam-blink"></div>
                    <div class="cam-chip"></div>
                    <div class="cam-toast"></div>
                    <div class="cam-count"></div>
                    <div class="cam-focus"><i class="fa-solid fa-sun"></i></div>
                    <div class="cam-lenses"></div>
                    <div class="cam-err"></div>
                </div>
                <div class="cam-top">
                    <button class="ct-btn" data-act="flash"></button>
                    <button class="ct-chev" data-act="panel"><i class="fa-solid fa-chevron-up"></i></button>
                    <div class="ct-rec"><span></span><b>00:00</b></div>
                    <button class="ct-btn" data-act="styles"><i class="fa-solid fa-circle-half-stroke"></i></button>
                </div>
                <div class="cam-bottom">
                    <div class="cam-strip"><div class="cam-modes">${CAM_MODES.map((m) => `<button data-cam-mode="${m}">${I18N.t(CAM_MODE_LABEL[m])}</button>`).join('')}</div></div>
                    <div class="cam-panel"></div>
                    <div class="cam-controls">
                        <button class="cam-thumb" data-act="thumb"></button>
                        <button class="cam-shutter" data-act="shutter"><span></span></button>
                        <button class="cam-flip" data-act="flip"><i class="fa-solid fa-arrows-rotate"></i></button>
                    </div>
                </div>
                <div class="cam-retina"></div>
            </div>`;

        const cam = $('.cam', root), vf = $('.cam-vf', root), canvas = $('.cam-canvas', root);
        const focusEl = $('.cam-focus', root), lensesEl = $('.cam-lenses', root), panelEl = $('.cam-panel', root);
        const toast = (text, ms = 1300) => {
            const t = $('.cam-toast', root);
            t.textContent = text; t.classList.add('show');
            clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), ms);
        };

        if (!GameView.init(canvas)) {
            $('.cam-err', root).textContent = I18N.t("This game client can't show the camera.");
        }

        /* ---------------- render loop ---------------- */
        let raf = 0;
        const frame = () => {
            raf = 0;
            if (!S.running) return;
            drawPreview();
            raf = requestAnimationFrame(frame);
        };
        /** one viewfinder frame at the size it's shown on screen (or the recording size) */
        const drawPreview = () => {
            const r = vf.getBoundingClientRect();
            const rw = r.width || 393, rh = r.height || 524;
            const w = S.recording ? S.recording.w : Math.round(Math.min(900, rw * (window.devicePixelRatio || 1)));
            const h = S.recording ? S.recording.h : Math.round(w * (rh / rw));
            GameView.draw(Math.max(2, w), Math.max(2, h), { mirror: S.front, ev: S.ev, style: S.style, vignette: S.mode === 'portrait' });
        };
        const startLoop = () => { if (!raf && S.running) raf = requestAnimationFrame(frame); };

        const startGame = async () => {
            const r = await nui('cameraStart', { front: S.front });
            if (r === null && IN_GAME) $('.cam-err', root).textContent = I18N.t("Couldn't start the camera");
            nui('cameraSet', { zoom: S.zoom, portrait: S.mode === 'portrait', front: S.front, torch: S.mode === 'video' && S.flash === 'on' });
        };

        /* ---------------- UI state ---------------- */
        const setLayout = () => {
            const l = camLayout(S.mode, S.aspect);
            cam.style.setProperty('--vf-top', l.top + 'px');
            cam.style.setProperty('--vf-h', l.h + 'px');
            cam.classList.toggle('tall', l.h > 600);
        };
        const lensLabel = (v) => (v < 1 ? '.5' : String(v));
        const drawLenses = () => {
            if (S.front) { lensesEl.innerHTML = ''; return; }
            const list = CAM_LENSES[S.mode];
            // the active pill shows the exact zoom ("1.4×"), like the real one
            let active = list[0];
            for (const v of list) if (S.zoom >= v - 0.001) active = v;
            lensesEl.innerHTML = list.map((v) => {
                const on = v === active;
                const label = on ? `${S.zoom === v ? lensLabel(v) : (Math.round(S.zoom * 10) / 10).toString().replace(/^0/, '')}×` : lensLabel(v);
                return `<button class="${on ? 'on' : ''}" data-lens="${v}">${label}</button>`;
            }).join('');
        };
        const drawModes = () => {
            $$('[data-cam-mode]', root).forEach((b) => b.classList.toggle('on', b.dataset.camMode === S.mode));
            const on = $(`[data-cam-mode=${S.mode}]`, root);
            const strip = $('.cam-strip', root), track = $('.cam-modes', root);
            if (on && strip.clientWidth) track.style.transform = `translateX(${strip.clientWidth / 2 - (on.offsetLeft + on.offsetWidth / 2)}px)`;
        };
        const flashIcon = () => {
            const b = $('[data-act=flash]', root);
            b.innerHTML = `<i class="fa-solid fa-bolt${S.flash === 'off' ? '-lightning' : ''}"></i>${S.flash === 'off' ? '<span class="slash"></span>' : ''}`;
            b.classList.toggle('lit', S.flash === 'on');
        };
        const drawChip = () => {
            const chip = $('.cam-chip', root);
            const txt = S.mode === 'portrait' ? I18N.t('NATURAL LIGHT') : S.aeLock ? I18N.t('AE/AF LOCK') : S.timer ? `${S.timer}s` : '';
            chip.textContent = txt;
            chip.classList.toggle('show', !!txt);
        };
        const sync = () => {
            setLayout(); drawLenses(); drawModes(); flashIcon(); drawChip();
            cam.dataset.mode = S.mode;
            cam.classList.toggle('front', S.front);
            cam.classList.toggle('grid', S.grid);
            cam.classList.toggle('rec', !!S.recording);
            cam.classList.toggle('panel-open', !!S.panel);
            $('.ct-chev i', root).className = `fa-solid fa-chevron-${S.panel ? 'down' : 'up'}`;
        };

        const setZoom = (z, quiet) => {
            const min = S.mode === 'portrait' ? 1 : 0.5;
            S.zoom = Math.max(min, Math.min(15, Math.round(z * 100) / 100));
            drawLenses();
            nui('cameraSet', { zoom: S.zoom });
            if (!quiet && S.zoom !== Math.round(S.zoom) && S.zoom !== 0.5) toast(`${Math.round(S.zoom * 10) / 10}×`, 700);
        };
        const setMode = (m) => {
            if (S.recording || S.mode === m || !CAM_MODES.includes(m)) return;
            S.mode = m;
            S.panel = null;
            vf.classList.add('switching');
            setTimeout(() => vf.classList.remove('switching'), 260);
            if (m === 'portrait' && S.zoom < 1) S.zoom = 1;
            if (m === 'portrait' && S.front) toast(I18N.t('Portrait'));
            nui('cameraSet', { portrait: m === 'portrait', zoom: S.zoom, torch: m === 'video' && S.flash === 'on' });
            drawPanel(); sync();
        };
        const flip = () => {
            if (S.recording) return;
            S.front = !S.front;
            vf.classList.add('flipping');
            setTimeout(() => vf.classList.remove('flipping'), 420);
            nui('cameraSet', { front: S.front });
            sync();
        };

        /* ---------------- options panel (chevron) ---------------- */
        const PANEL_ITEMS = [
            { id: 'flash', icon: 'fa-bolt', label: () => I18N.t('Flash'), opts: ['auto', 'on', 'off'], get: () => S.flash, set: (v) => { S.flash = v; remember(); nui('cameraSet', { torch: S.mode === 'video' && v === 'on' }); } },
            { id: 'aspect', text: () => S.aspect, label: () => I18N.t('Aspect'), opts: Object.keys(CAM_ASPECTS), get: () => S.aspect, set: (v) => { S.aspect = v; remember(); }, hide: () => S.mode === 'video' },
            { id: 'ev', icon: 'fa-circle-plus', label: () => I18N.t('Exposure'), slider: true },
            { id: 'timer', icon: 'fa-stopwatch', label: () => I18N.t('Timer'), opts: [0, 3, 10], get: () => S.timer, set: (v) => { S.timer = v; }, hide: () => S.mode === 'video' },
            { id: 'style', icon: 'fa-circle-half-stroke', label: () => I18N.t('Styles'), opts: CAM_STYLES.map((s) => s.id), get: () => S.style.id, set: (v) => { S.style = CAM_STYLES.find((s) => s.id === v); remember(); toast(I18N.t(S.style.name)); } },
            { id: 'grid', icon: 'fa-table-cells', label: () => I18N.t('Grid'), opts: [false, true], get: () => S.grid, set: (v) => { S.grid = v; remember(); } },
        ];
        const optLabel = (item, v) => {
            if (item.id === 'flash') return I18N.t(v === 'auto' ? 'Auto' : v === 'on' ? 'On' : 'Off');
            if (item.id === 'timer') return v ? `${v}s` : I18N.t('Off');
            if (item.id === 'style') return I18N.t(CAM_STYLES.find((s) => s.id === v).name);
            if (item.id === 'grid') return I18N.t(v ? 'On' : 'Off');
            return String(v);
        };
        const drawPanel = () => {
            if (!S.panel) { panelEl.innerHTML = ''; return; }
            if (S.panel === 'main') {
                panelEl.innerHTML = PANEL_ITEMS.filter((i) => !(i.hide && i.hide())).map((i) => {
                    const active = i.id === 'ev' ? S.ev !== 0 : i.id === 'flash' ? S.flash === 'on' : i.id === 'timer' ? S.timer > 0 : i.id === 'style' ? S.style.id !== 'standard' : i.id === 'grid' ? S.grid : false;
                    return `<button class="cp-item ${active ? 'on' : ''}" data-panel="${i.id}">${i.text ? `<b>${esc(i.text())}</b>` : `<i class="fa-solid ${i.icon}"></i>`}</button>`;
                }).join('');
                return;
            }
            const item = PANEL_ITEMS.find((i) => i.id === S.panel);
            if (item.slider) {
                panelEl.innerHTML = `<div class="cp-slider"><span>${S.ev > 0 ? '+' : ''}${S.ev.toFixed(1)}</span><input type="range" min="-2" max="2" step="0.1" value="${S.ev}"></div>`;
                $('input', panelEl).addEventListener('input', (e) => { S.ev = +e.target.value; $('.cp-slider span', panelEl).textContent = `${S.ev > 0 ? '+' : ''}${S.ev.toFixed(1)}`; });
                return;
            }
            panelEl.innerHTML = `<div class="cp-label">${esc(item.label())}</div><div class="cp-opts">${item.opts.map((v) =>
                `<button class="${item.get() === v ? 'on' : ''}" data-opt="${esc(String(v))}">${esc(optLabel(item, v))}</button>`).join('')}</div>`;
        };

        /* ---------------- capture ---------------- */
        const outAspect = () => (S.mode === 'video' ? 9 / 16 : CAM_ASPECTS[S.aspect]);
        const outSize = (longSide) => {
            const a = outAspect();
            // never larger than the real crop of the game frame
            const gw = (window.innerWidth || 1280) * (window.devicePixelRatio || 1), gh = (window.innerHeight || 720) * (window.devicePixelRatio || 1);
            const crop = GameView.crop(a);
            const maxH = Math.min(longSide, gh * crop[3]);
            const h = Math.round(Math.min(maxH, (gw * crop[2]) / a));
            return { w: Math.round(h * a) & ~1, h: h & ~1 };
        };

        const setThumb = (url) => {
            const t = $('.cam-thumb', root);
            t.innerHTML = isVideoUrl(url) ? `<video src="${esc(url)}" muted preload="metadata"></video>` : '';
            t.style.backgroundImage = isVideoUrl(url) || !url ? '' : `url('${cssUrl(url)}')`;
            t.classList.remove('pop'); void t.offsetWidth; t.classList.add('pop');
        };

        // pixels can only be read in the same task the frame was drawn in
        const needsFlash = () => S.flash === 'on' || (S.flash === 'auto' && (drawPreview(), GameView.brightness() < 0.16));

        const takePhoto = async () => {
            if (S.busy || !GameView.gl) return;
            S.busy = true;
            try {
                if (needsFlash()) {
                    if (S.front) { $('.cam-retina', root).classList.add('on'); await sleep(260); }
                    else { nui('cameraFlash', { ms: 450 }); await sleep(160); }
                }
                const { w, h } = outSize(S.aspect === '16:9' ? 1920 : 1600);
                // render one full-size frame (the selfie preview is mirrored, the photo is not)
                GameView.draw(w, h, { mirror: false, ev: S.ev, style: S.style, vignette: S.mode === 'portrait' });
                const data = canvas.toDataURL('image/jpeg', 0.9);
                $('.cam-retina', root).classList.remove('on');
                Sound.play('shutter');
                const blink = $('.cam-blink', root);
                blink.classList.remove('on'); void blink.offsetWidth; blink.classList.add('on');
                setThumb(data);
                S.session.unshift(data);
                uploadCameraMedia(data, 'jpg').then((r) => { S.session[S.session.indexOf(data)] = r.url; }).catch((e) => toast(e.message, 3000));
            } finally {
                S.busy = false;
            }
        };

        const countdown = async () => {
            const el2 = $('.cam-count', root);
            for (let i = S.timer; i > 0; i--) {
                if (!S.running) return false;
                el2.textContent = i; el2.classList.remove('tick'); void el2.offsetWidth; el2.classList.add('tick');
                Sound.play('key', 1);
                await sleep(1000);
            }
            el2.textContent = '';
            return S.running;
        };

        const startRecording = () => {
            if (!GameView.gl || typeof MediaRecorder === 'undefined' || !canvas.captureStream) return toast(I18N.t("Video isn't supported on this game client"), 2500);
            const size = outSize(1280);
            const mime = ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'].find((m) => MediaRecorder.isTypeSupported(m));
            if (!mime) return toast(I18N.t("Video isn't supported on this game client"), 2500);
            S.recording = { w: size.w, h: size.h, chunks: [], start: Date.now() };
            GameView.draw(size.w, size.h, { mirror: S.front, ev: S.ev, style: S.style });
            const rec = new MediaRecorder(canvas.captureStream(30), { mimeType: mime, videoBitsPerSecond: 3500000 });
            S.recording.rec = rec;
            rec.ondataavailable = (e) => { if (e.data && e.data.size) S.recording && S.recording.chunks.push(e.data); };
            rec.start(1000);
            Sound.play('key', 1);
            const max = (Phone.config.cameraMaxVideo || 60) * 1000;
            S.recording.timer = setInterval(() => {
                const ms = Date.now() - S.recording.start;
                $('.ct-rec b', root).textContent = fmtDuration(Math.floor(ms / 1000));
                if (ms >= max) stopRecording();
            }, 250);
            Island.start('camrec', {
                priority: 90,
                compact: () => ({ left: '<span class="isl-recdot"></span>', right: `<span class="isl-num" style="color:#ff453a">${fmtDuration(Math.floor((Date.now() - S.recording.start) / 1000))}</span>` }),
                minimal: () => '<span class="isl-recdot"></span>',
                onTap: () => {},
            });
            sync();
        };
        const stopRecording = (silent) => new Promise((resolve) => {
            const r = S.recording;
            if (!r) return resolve();
            clearInterval(r.timer);
            Island.end('camrec');
            r.rec.onstop = async () => {
                S.recording = null;
                $('.ct-rec b', root).textContent = '00:00';
                if (root.isConnected) sync();
                const blob = new Blob(r.chunks, { type: 'video/webm' });
                resolve();
                if (blob.size < 1000) return;
                const data = await new Promise((ok) => { const fr = new FileReader(); fr.onload = () => ok(fr.result); fr.readAsDataURL(blob); });
                if (root.isConnected) setThumb(data);
                S.session.unshift(data);
                uploadCameraMedia(data, 'webm')
                    .then((res) => { S.session[S.session.indexOf(data)] = res.url; if (silent) UI.toast(I18N.t('Video saved'), 'fa-solid fa-video'); })
                    .catch((e) => (root.isConnected ? toast(e.message, 3000) : UI.toast(e.message, 'fa-solid fa-circle-exclamation')));
            };
            if (!silent) Sound.play('key', 1);
            r.rec.stop();
        });

        const shutter = async () => {
            if (S.panel) { S.panel = null; drawPanel(); sync(); }
            if (S.mode === 'video') return S.recording ? stopRecording() : startRecording();
            const btn = $('.cam-shutter', root);
            btn.classList.add('press'); setTimeout(() => btn.classList.remove('press'), 160);
            if (S.timer && !(await countdown())) return;
            takePhoto();
        };
        Phone.cameraShutter = shutter;

        /* ---------------- viewfinder gestures ---------------- */
        let down = null, holdTimer = null;
        vf.addEventListener('pointerdown', (e) => {
            if (e.target.closest('.cam-lenses')) return;
            down = { x: e.clientX, y: e.clientY, t: performance.now(), moved: false };
            vf.setPointerCapture(e.pointerId);
            nui('cameraDrag', { on: true });
            clearTimeout(holdTimer);
            holdTimer = setTimeout(() => { if (down && !down.moved) { down.held = true; focusAt(e, true); } }, 600);
        });
        vf.addEventListener('pointermove', (e) => {
            if (!down) return;
            const dx = e.clientX - down.x, dy = e.clientY - down.y;
            if (Math.hypot(dx, dy) > 6) down.moved = true;
            if (!IN_GAME && down.moved) { GameView.look.yaw -= dx * 0.05; GameView.look.pitch = Math.max(-30, Math.min(30, GameView.look.pitch + dy * 0.03)); down.x = e.clientX; down.y = e.clientY; }
        });
        const up = () => {
            if (!down) return;
            clearTimeout(holdTimer);
            nui('cameraDrag', { on: false });
            const d = down; down = null;
            if (!d.moved && !d.held && performance.now() - d.t < 450) focusAt(d, false);
        };
        vf.addEventListener('pointerup', up);
        vf.addEventListener('pointercancel', up);
        vf.addEventListener('wheel', (e) => { e.preventDefault(); if (!S.front) setZoom(S.zoom * Math.exp(-e.deltaY * 0.0016)); }, { passive: false });

        const focusAt = (p, lock) => {
            const r = vf.getBoundingClientRect();
            const x = (p.x ?? p.clientX) - r.left, y = (p.y ?? p.clientY) - r.top;
            const sx = 393 / (r.width || 393);
            focusEl.style.left = x * sx + 'px';
            focusEl.style.top = y * sx + 'px';
            focusEl.classList.remove('show', 'lock'); void focusEl.offsetWidth;
            focusEl.classList.add('show');
            if (lock) focusEl.classList.add('lock');
            clearTimeout(focusEl._h);
            if (!lock) focusEl._h = setTimeout(() => focusEl.classList.remove('show'), 1600);
            S.aeLock = lock;
            drawChip();
            // tapped point -> position on the full game frame
            const crop = GameView.crop(r.width / r.height);
            let u = x / r.width; if (S.front) u = 1 - u;
            nui('cameraFocus', { u: crop[0] + u * crop[2], v: crop[1] + (y / r.height) * crop[3] });
        };

        /* ---------------- mode strip swipe ---------------- */
        const bottom = $('.cam-bottom', root);
        let sw = null;
        bottom.addEventListener('pointerdown', (e) => { if (!e.target.closest('.cam-controls button, .cam-panel')) sw = { x: e.clientX }; });
        bottom.addEventListener('pointerup', (e) => {
            if (!sw) return;
            const dx = e.clientX - sw.x; sw = null;
            if (Math.abs(dx) < 30) return;
            const i = CAM_MODES.indexOf(S.mode) + (dx < 0 ? 1 : -1);
            if (CAM_MODES[i]) setMode(CAM_MODES[i]);
        });

        /* ---------------- buttons ---------------- */
        root.addEventListener('click', (e) => {
            const lens = e.target.closest('[data-lens]');
            if (lens) { e.stopPropagation(); return setZoom(+lens.dataset.lens, true); }
            const m = e.target.closest('[data-cam-mode]');
            if (m) return setMode(m.dataset.camMode);
            const pi = e.target.closest('[data-panel]');
            if (pi) { S.panel = pi.dataset.panel; drawPanel(); return; }
            const opt = e.target.closest('[data-opt]');
            if (opt) {
                const item = PANEL_ITEMS.find((i) => i.id === S.panel);
                const raw = opt.dataset.opt;
                item.set(raw === 'true' ? true : raw === 'false' ? false : /^\d+$/.test(raw) ? +raw : raw);
                S.panel = 'main'; drawPanel(); sync();
                return;
            }
            const a = e.target.closest('[data-act]');
            if (!a) return;
            switch (a.dataset.act) {
                case 'shutter': shutter(); break;
                case 'flip': flip(); break;
                case 'panel':
                    if (S.recording) break;
                    S.panel = S.panel ? null : 'main'; drawPanel(); sync(); break;
                case 'flash': {
                    const order = ['auto', 'on', 'off'];
                    S.flash = order[(order.indexOf(S.flash) + 1) % 3];
                    remember();
                    nui('cameraSet', { torch: S.mode === 'video' && S.flash === 'on' });
                    toast(`${I18N.t('Flash')} ${optLabel(PANEL_ITEMS[0], S.flash)}`);
                    sync(); break;
                }
                case 'styles':
                    if (S.recording) break;
                    S.panel = S.panel === 'style' ? null : 'style'; drawPanel(); sync(); break;
                case 'thumb':
                    if (S.recording) break;
                    if (S.locked) tryUnlock(() => Phone.openApp('photos'));
                    else Phone.openApp('photos');
                    break;
            }
        });

        // keyboard shutter
        const onKey = (e) => {
            if (e.target.matches('input, textarea') || e.repeat) return;
            if (e.code === 'Space' || e.key === 'Enter') { e.preventDefault(); shutter(); }
        };
        document.addEventListener('keydown', onKey);

        /* ---------------- lifecycle ---------------- */
        app.on('close', () => {
            // phone put away: stop the game camera and finish a recording
            S.running = false;
            if (S.recording) stopRecording(true);
            cancelAnimationFrame(raf); raf = 0;            // from the lock screen: putting the phone away goes back to the lock screen
            if (S.locked) setTimeout(() => { if (Phone.current && Phone.current.def.id === 'camera') Phone.closeApp(true); }, 400);
        });
        app.on('open', () => {
            if (S.running) return;
            S.running = true;
            startGame(); startLoop();
        });
        // the phone locked itself (Auto-Lock) while the camera was open normally
        app.on('locked', () => { if (!S.locked && Phone.current && Phone.current.def.id === 'camera') Phone.closeApp(true); });
        app.on('cameraClosed', () => { if (Phone.current && Phone.current.def.id === 'camera') Phone.closeApp(); });
        app._cam = {
            stop: () => {
                S.running = false;
                if (S.recording) stopRecording(true);
                cancelAnimationFrame(raf); raf = 0;
                document.removeEventListener('keydown', onKey);
                if (Phone.cameraShutter === shutter) Phone.cameraShutter = null;
            },
        };

        // last photo in the thumbnail (from the lock screen only this session's photos show)
        if (!S.locked) rpc('getPhotos').then((p) => { if (p && p[0] && root.isConnected && !S.session.length) setThumb(p[0].url); });

        sync();
        requestAnimationFrame(sync); // mode strip needs layout to centre
        startGame();
        startLoop();
    },

    onClose(ctx) {
        if (ctx && ctx._cam) ctx._cam.stop();
        nui('cameraStop');
        GameView.destroy();
        screenEl().classList.remove('lock-cam');
    },
});
