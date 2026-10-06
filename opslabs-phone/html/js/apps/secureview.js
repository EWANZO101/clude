'use strict';

/* =====================================================================
   OPS Secure View — watch your CCTV from anywhere (opslabs-towers server/cctv.lua)
   Systems you own, that are shared with you, or that belong to your organisation (e.g. police).
   Remote viewing needs the system's remote viewing switched on and its NVR on the internet.
   ===================================================================== */

const SV_COLOR = '#ff375f';
const SV_EVENT = { motion: ['person-walking', '#0a84ff', 'Motion'], heat: ['fire', '#ff9f0a', 'Heat'], anpr: ['car', '#30d158', 'Plate'], ring: ['bell', '#ff9f0a', 'Doorbell'], view: ['eye', '#8e8e93', 'Viewed'] };
const svIcon = (icon, color) => `<span class="ri" style="background:${color}"><i class="fa-solid fa-${icon}"></i></span>`;
const svChip = (on, yes, no, color = '#30d158') => `<span class="on-pill" style="--c:${on ? color : '#8e8e93'}">${esc(on ? yes : no)}</span>`;
const svAgo = (t) => { const s = Math.max(0, Math.floor(Date.now() / 1000) - t); return s < 60 ? `${s}s ago` : s < 3600 ? `${Math.floor(s / 60)} min ago` : s < 86400 ? `${Math.floor(s / 3600)} h ago` : `${Math.floor(s / 86400)} d ago`; };
const svFix = (v) => (typeof onFix === 'function' ? onFix(v) : v);

const SecureView = {
    root: null,
    open(root) {
        this.root = root;
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: 'OPS Secure View', large: true, grouped: true,
            render(c, ctx) {
                const load = async () => {
                    const r = svFix(await nui('cctvList'));
                    if (!r || r.offline) { c.innerHTML = UI.empty('fa-solid fa-plug-circle-xmark', 'Offline', 'The CCTV service isn’t reachable right now.'); return; }
                    const list = r.systems || [];
                    c.innerHTML = list.length ? `<div class="group" style="margin-top:12px">${list.map((s) => `
                        <div class="row tap has-icon" data-sys="${s.id}" style="align-items:flex-start;padding-top:12px;padding-bottom:12px">${svIcon('video', s.powered ? SV_COLOR : '#8e8e93')}
                            <div class="grow"><div><b>${esc(s.name)}</b></div>
                            <div class="sub muted">${s.cams} camera${s.cams === 1 ? '' : 's'}${s.org_job ? ' · ' + esc(s.org_job) : ''}${s.owner ? ' · ' + esc(s.owner) : ''}</div>
                            <div style="display:flex;gap:5px;margin-top:6px;flex-wrap:wrap">${svChip(s.powered, 'Powered', 'No power')}${svChip(s.recording, 'Recording', 'Not recording')}${svChip(s.internet, 'Online', 'Offline', '#0a84ff')}${svChip(s.remote, 'Remote on', 'Remote off', '#bf5af2')}</div></div>
                            <i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}</div>
                        <div class="group-footer">Your systems, ones shared with you, and your organisation’s. Ask OPS Secure to fit one — OPS Work → Request a service.</div>`
                        : UI.empty('fa-solid fa-video-slash', 'No CCTV yet', 'When you own a system, or someone shares theirs with you, it shows up here.');
                };
                c.innerHTML = '<div class="spinner" style="margin:60px auto"></div>';
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => { const s = e.target.closest('[data-sys]'); if (s) SecureView.system(nav, +s.dataset.sys); });
            },
        });
    },

    system(nav, id) {
        nav.push({
            title: 'Cameras', grouped: true, backLabel: 'Systems',
            render(c, ctx) {
                let tab = 'cams';
                const draw = async () => {
                    c.innerHTML = '<div class="spinner" style="margin:60px auto"></div>';
                    const s = svFix(await nui('cctvSystem', { id }));
                    if (!s || s.error) {
                        c.innerHTML = UI.empty('fa-solid fa-lock', 'Can’t watch remotely', (s && s.error) || 'Try again in a moment.')
                            + '<div class="group-footer" style="text-align:center">Remote viewing needs the NVR cabled to a router that’s online, and remote viewing switched on at the NVR ([E] → Set up).</div>';
                        return;
                    }
                    ctx.setTitle(s.name);
                    c.innerHTML = `<div class="segmented" style="margin-top:12px"><button data-t="cams">Cameras</button><button data-t="events">Events</button><button data-t="anpr">Plates</button></div><div class="sv-body"></div>`;
                    $$('[data-t]', c).forEach((b) => b.classList.toggle('on', b.dataset.t === tab));
                    const body = $('.sv-body', c);
                    if (tab === 'cams') {
                        body.innerHTML = `<div class="group">${(s.cams || []).map((cam) => `
                            <div class="row tap has-icon" data-cam="${cam.id}">${svIcon(cam.ptz ? 'arrows-spin' : cam.anpr ? 'car' : cam.thermal ? 'fire' : cam.kind === 'wifi' ? 'wifi' : 'video', cam.online ? (cam.status === 'fault_lens' ? '#ff9f0a' : '#30d158') : '#ff3b30')}
                                <div class="grow"><div>${esc(cam.name)}</div><div class="sub muted">${esc(cam.statusText || '')}</div></div>
                                ${cam.online ? '<i class="fa-solid fa-play" style="color:#0a84ff"></i>' : ''}</div>`).join('') || '<div class="row"><div class="grow muted">No cameras</div></div>'}</div>
                            <div class="group-footer">Tap a camera to watch it live. ← → switch cameras, scroll to zoom, Backspace to come back.</div>`;
                    } else {
                        body.innerHTML = '<div class="spinner" style="margin:40px auto"></div>';
                        const ev = svFix(await nui('cctvEvents', { id, kind: tab === 'anpr' ? 'anpr' : null })) || [];
                        body.innerHTML = `<div class="group">${ev.map((e) => { const k = SV_EVENT[e.kind] || ['circle', '#8e8e93', e.kind];
                            return `<div class="row has-icon">${svIcon(k[0], k[1])}<div class="grow"><div>${esc(e.kind === 'anpr' ? (e.detail || '') : (k[2] + (e.detail ? ' · ' + e.detail : '')))}</div><div class="sub muted">${esc(e.camera || '')} · ${svAgo(e.at)}</div></div></div>`; }).join('')
                            || `<div class="row"><div class="grow muted">${tab === 'anpr' ? 'No plates read yet' : 'Nothing recorded yet'}</div></div>`}</div>`;
                    }
                };
                draw();
                c.addEventListener('click', (e) => {
                    const t = e.target.closest('[data-t]');
                    if (t) { tab = t.dataset.t; return draw(); }
                    const cam = e.target.closest('[data-cam]');
                    if (cam) nui('cctvWatch', { id, cam: +cam.dataset.cam });
                });
            },
        });
    },
};

Apps.register({
    id: 'secureview', name: 'Secure View', resumable: false, defaultInstalled: false,
    splash: `linear-gradient(160deg,#111,${SV_COLOR})`,
    icon: { bg: `linear-gradient(150deg,${SV_COLOR},#2a0610 130%)`, html: () => '<i class="fa-solid fa-video" style="font-size:28px;color:#fff"></i>' },
    open(root) { return SecureView.open(root); },
    onClose() { SecureView.root = null; },
});
