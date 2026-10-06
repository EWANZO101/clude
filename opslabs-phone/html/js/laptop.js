'use strict';

/* =====================================================================
   OPS OS for laptops
   A desktop (menu bar, dock, windows) shown when a player uses a placed
   laptop. The phone's own apps run in the windows with the same accounts,
   so Ops-Networks, OPS Mobile, Mail, Messages... all work here. The only
   connection is the laptop's Ethernet port: the server refuses anything
   online while it isn't cabled to a router with internet (or a live ONT).
   ===================================================================== */

const LAPTOP_APPS = ['browser', 'academy', 'opswork', 'opsnet', 'opsmobile', 'mail', 'messages', 'contacts', 'notes', 'calendar', 'wallet', 'chirp', 'maps', 'photos', 'garage', 'services', 'weather', 'calculator'];
const LT_W = 1280, LT_H = 800;
const LT_NET_ID = 'lt-network';

const LT_REASON = {
    unplugged: ['Cable unplugged', 'Nothing is plugged into the Ethernet port. Run a CAT6 cable from a router, switch or the ONT and terminate it into this laptop.'],
    not_terminated: ['Cable not terminated', 'There is a cable in the port but it isn\'t terminated at both ends yet. Crimp an RJ45 on each end and plug it in.'],
    no_device: ['Nothing on the other end', 'The other end of the cable isn\'t plugged into a router or an ONT.'],
    router_off: ['Router offline', '{via} is switched off or has a fault.'],
    no_uplink: ['No internet', 'Connected to {via}, but it has no way out to the internet. Cable it through to a gateway (OPS Gateway, EdgeLink, HomeRouter…) with a live broadband line.'],
    ont_dark: ['No internet', 'Plugged straight into the ONT, but it has no light. The fibre back to the cabinet needs fixing.'],
    no_service: ['No internet', 'The ONT has light but no active internet service. An engineer needs to provision it.'],
};

const OPS_MARK = '<svg class="lt-mark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="12" cy="12" r="2.2" fill="currentColor" stroke="none"/><path d="M7.4 7.4a6.5 6.5 0 0 0 0 9.2M16.6 7.4a6.5 6.5 0 0 1 0 9.2M4.2 4.2a11 11 0 0 0 0 15.6M19.8 4.2a11 11 0 0 1 0 15.6"/></svg>';

const Laptop = {
    active: false,
    id: null,
    net: null,
    wins: new Map(),          // id -> { def, el, body, root, layer, ctx, mounted, offline }
    order: [],                // focus order, last = front
    z: 10,
    scale: 1,
    pollTimer: null,
    clockTimer: null,
    signedIn: false,

    online() { return !!(this.net && this.net.internet); },
    theme() { return screenEl().dataset.theme || 'light'; },
    focused() { const id = this.order[this.order.length - 1]; return id ? this.wins.get(id) : null; },
    /** where alerts / sheets / toasts go: the front window, or the desktop */
    layer() {
        const w = this.focused();
        if (w && !w.el.classList.contains('min')) return w.layer;
        return $('.lt-sys .overlay-layer', this.host);
    },
};

/* ---------------------------------------------------------------------
   build the desktop once
   --------------------------------------------------------------------- */

function ltBuild() {
    if (Laptop.host) return;
    const host = el(`
        <div class="laptop lt-closed" id="laptop">
            <div class="lt-device">
                <div class="lt-lid">
                    <div class="lt-display">
                        <div class="lt-wall"></div>
                        <div class="lt-menubar">
                            <div class="lt-mb-logo">${OPS_MARK}<span data-no-i18n>OPS OS</span></div>
                            <div class="lt-mb-app" data-no-i18n></div>
                            <div class="grow"></div>
                            <button class="lt-mb-btn lt-eth" data-lt="network" title="Ethernet"><i class="fa-solid fa-network-wired"></i><span></span></button>
                            <div class="lt-mb-btn lt-bat" data-no-i18n><i class="fa-solid fa-battery-full"></i><span></span></div>
                            <div class="lt-mb-btn lt-clock-sm" data-no-i18n></div>
                            <div class="lt-mb-btn lt-user" data-no-i18n><i class="fa-solid fa-circle-user"></i><span></span></div>
                            <button class="lt-mb-btn" data-lt="power" title="Shut lid"><i class="fa-solid fa-power-off"></i></button>
                        </div>
                        <div class="lt-desk"></div>
                        <div class="lt-dock"></div>
                        <div class="lt-banners"></div>
                        <div class="screen lt-screen lt-sys"><div class="overlay-layer"></div></div>
                        <div class="lt-login">
                            <div class="lt-clock"><div></div><div></div></div>
                            <div>
                                <div class="lt-avatar" data-no-i18n></div>
                                <h2 data-no-i18n></h2>
                                <div class="lt-sub" data-no-i18n></div>
                                <button class="lt-go" data-lt="signin">${esc(I18N.t('Sign In'))} <i class="fa-solid fa-arrow-right"></i></button>
                            </div>
                            <div class="lt-hint">${esc(I18N.t('Signed in with your OPS ID'))} · Esc ${esc(I18N.t('to leave'))}</div>
                        </div>
                    </div>
                </div>
                <div class="lt-hinge"></div>
            </div>
        </div>`);
    document.body.appendChild(host);
    Laptop.host = host;

    host.addEventListener('click', (e) => {
        const a = e.target.closest('a[href]');
        if (a) e.preventDefault();
        const b = e.target.closest('[data-lt]');
        if (!b) return;
        const act = b.dataset.lt;
        if (act === 'power') ltClose();
        if (act === 'network') Laptop.openApp(LT_NET_ID);
        if (act === 'signin') ltSignIn();
    });
    $('.lt-dock', host).addEventListener('click', (e) => {
        const it = e.target.closest('[data-app]');
        if (it) Laptop.openApp(it.dataset.app);
    });
    window.addEventListener('resize', ltLayout);
    if (typeof I18N !== 'undefined' && I18N.watch) I18N.watch();
}

function ltLayout() {
    if (!Laptop.host) return;
    const s = Math.min(1, (window.innerWidth * 0.94) / 1320, (window.innerHeight * 0.95) / 856);
    Laptop.scale = s;
    const dev = $('.lt-device', Laptop.host);
    dev.style.setProperty('--lt-scale', s);
    dev.style.transform = `translate(-50%, -50%) scale(${s})`;
}

function ltInitials(name) {
    return String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('') || '?';
}

function ltClock() {
    if (!Laptop.host) return;
    const now = new Date();
    const time = typeof fmtTime === 'function' ? fmtTime(now) : now.toTimeString().slice(0, 5);
    const day = now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
    $('.lt-clock-sm', Laptop.host).textContent = now.toLocaleDateString(undefined, { weekday: 'short' }) + ' ' + time;
    const c = $$('.lt-clock div', Laptop.host);
    c[0].textContent = day;
    c[1].textContent = time;
}

function ltRenderDock() {
    const dock = $('.lt-dock', Laptop.host);
    const items = LAPTOP_APPS.filter((id) => Apps.byId[id]).map((id) => {
        const def = Apps.byId[id];
        const badge = Phone.badges[id] ? `<span class="lt-badge">${Phone.badges[id] > 99 ? '99+' : Phone.badges[id]}</span>` : '';
        return `<div class="lt-dock-item ${Laptop.wins.has(id) ? 'running' : ''}" data-app="${id}">${iconScaled(def, 52)}${badge}<span class="lt-tip" data-no-i18n>${esc(def.label || def.name)}</span><span class="lt-dot"></span></div>`;
    });
    items.push('<div class="lt-sep"></div>');
    items.push(`<div class="lt-dock-item ${Laptop.wins.has(LT_NET_ID) ? 'running' : ''}" data-app="${LT_NET_ID}"><div class="lt-net-icon"><i class="fa-solid fa-network-wired"></i></div><span class="lt-tip">${esc(I18N.t('Network'))}</span><span class="lt-dot"></span></div>`);
    dock.innerHTML = items.join('');
}

/* ---------------------------------------------------------------------
   open / close / sign in
   --------------------------------------------------------------------- */

function ltOpen(d) {
    ltBuild();
    // the phone's own open app is put away so nothing on the hidden phone answers queries meant for the laptop
    if (Phone.current) closeApp(true);
    Laptop.active = true;
    Laptop.id = d.id;
    Laptop.signedIn = false;
    ltSetNet(d.net);
    const p = Phone.profile || {};
    $('.lt-avatar', Laptop.host).textContent = ltInitials(p.name);
    $('.lt-login h2', Laptop.host).textContent = p.name || I18N.t('OPS user');
    $('.lt-login .lt-sub', Laptop.host).textContent = p.email || '';
    $('.lt-user span', Laptop.host).textContent = p.name || '';
    $('.lt-login', Laptop.host).classList.remove('gone');
    ltRenderDock();
    ltLayout();
    ltClock();
    clearInterval(Laptop.clockTimer);
    Laptop.clockTimer = setInterval(ltClock, 1000);
    clearInterval(Laptop.pollTimer);
    Laptop.pollTimer = setInterval(ltPoll, 3000);
    requestAnimationFrame(() => Laptop.host.classList.remove('lt-closed'));
    setTimeout(() => { const b = $('.lt-go', Laptop.host); if (b) b.focus(); }, 50);
}

function ltSignIn() {
    if (Laptop.signedIn) return;
    Laptop.signedIn = true;
    $('.lt-login', Laptop.host).classList.add('gone');
    Sound.play && Sound.play('unlock');
    // first time on this laptop: show the connection so it's obvious what Ethernet is doing
    if (!Laptop.wins.size) Laptop.openApp(LT_NET_ID);
}

/** the player walked away / pressed Esc: windows stay as they were for next time on this laptop */
function ltHide() {
    if (!Laptop.active) return;
    Laptop.active = false;
    clearInterval(Laptop.pollTimer);
    clearInterval(Laptop.clockTimer);
    Laptop.host.classList.add('lt-closed');
    $$('.lt-banner', Laptop.host).forEach((b) => b.remove());
}

function ltClose() { nui('laptopClose'); }

/* a different laptop (or character) gets a clean desktop */
function ltReset() {
    [...Laptop.wins.keys()].forEach((id) => Laptop.closeWin(id));
    Laptop.order = [];
}

Phone.on('laptop', (d) => {
    if (!d) return;
    if (d.open) {
        if (Laptop.id != null && Laptop.id !== d.id) ltReset();
        ltOpen(d);
    } else {
        ltHide();
    }
});
Phone.on('reset', () => { ltHide(); ltReset(); Laptop.id = null; });

document.addEventListener('keydown', (e) => {
    if (!Laptop.active || e.key !== 'Escape') return;
    if (e.target.matches('input, textarea, [contenteditable]')) { e.target.blur(); return; }
    ltClose();
});

/* ---------------------------------------------------------------------
   Ethernet state
   --------------------------------------------------------------------- */

async function ltPoll() {
    if (!Laptop.active) return;
    const net = await nui('rpc', { name: 'laptopNet', data: {} });
    if (!Laptop.active || !net) return;
    if (net.closed) {
        if (net.reason === 'battery') nui('notifyGame', { title: 'Laptop', body: I18N.t('The battery is flat. Put a laptop charger beside it, plugged into a live socket.'), type: 'error' });
        ltClose();
        return;
    }
    ltSetNet(net);
}

function ltReason(net) {
    const r = LT_REASON[net && net.reason] || LT_REASON.unplugged;
    const via = (net && net.via && net.via.name) || I18N.t('the router');
    return [I18N.t(r[0]), I18N.t(r[1]).replace('{via}', via)];
}

function ltSetNet(net) {
    const was = Laptop.online();
    Laptop.net = net || { link: false, internet: false, reason: 'unplugged' };
    const now = Laptop.online();
    const eth = $('.lt-eth', Laptop.host);
    if (eth) {
        eth.classList.toggle('off', !Laptop.net.link);
        eth.classList.toggle('nointernet', Laptop.net.link && !now);
        $('span', eth).textContent = now ? I18N.t('Ethernet') : Laptop.net.link ? I18N.t('No internet') : I18N.t('Unplugged');
    }
    ltBattery(Laptop.net.power);
    Laptop.wins.forEach((w, id) => { if (id !== LT_NET_ID) ltApplyOffline(w); });
    const nw = Laptop.wins.get(LT_NET_ID);
    if (nw) ltRenderNetwork(nw);
    if (was !== now && Laptop.signedIn) {
        Laptop.banner({ app: LT_NET_ID, title: now ? I18N.t('Connected') : I18N.t('Internet connection lost'), body: now ? I18N.t('Ethernet is online.') : ltReason(Laptop.net)[0] });
    }
    if (was !== now) RpcCache.markDirty();
}

/** menu bar battery: level, charging bolt, and a warning when it's getting low on battery */
function ltBattery(p) {
    const b = Laptop.host && $('.lt-bat', Laptop.host);
    if (!b) return;
    b.classList.toggle('hidden', !p);
    if (!p) return;
    const lvl = Math.max(0, Math.min(100, p.level | 0));
    const icon = p.charging || p.plugged ? 'fa-plug-circle-bolt' : lvl > 80 ? 'fa-battery-full' : lvl > 55 ? 'fa-battery-three-quarters' : lvl > 30 ? 'fa-battery-half' : lvl > 10 ? 'fa-battery-quarter' : 'fa-battery-empty';
    $('i', b).className = 'fa-solid ' + icon;
    $('i', b).style.color = !p.plugged && lvl <= 10 ? '#ff6b61' : '';
    $('span', b).textContent = lvl + '%';
    b.title = p.charging ? I18N.t('Charging') : p.plugged ? I18N.t('On power adapter') : I18N.t('On battery');
    const prev = Laptop._batLvl;
    Laptop._batLvl = lvl;
    if (!p.plugged && prev != null && prev > 10 && lvl <= 10 && Laptop.signedIn) {
        Laptop.banner({ app: LT_NET_ID, title: I18N.t('Low Battery'), body: I18N.t('{n}% left. Put the laptop charger beside it.').replace('{n}', lvl) });
    }
}

/** cover a window while there's no internet; mount the app the first time it comes online */
function ltApplyOffline(w) {
    const off = !Laptop.online();
    w.offline.classList.toggle('hidden', !off);
    if (off) {
        const [title, msg] = ltReason(Laptop.net);
        $('h3', w.offline).textContent = title;
        $('p', w.offline).textContent = msg;
    } else if (!w.mounted) {
        ltMount(w);
    }
}

/* ---------------------------------------------------------------------
   windows
   --------------------------------------------------------------------- */

const LT_SIZES = { browser: [980, 680], academy: [560, 720], opswork: [480, 720], opsnet: [460, 700], opsmobile: [430, 700], maps: [760, 600], mail: [520, 660], messages: [460, 660], calculator: [340, 520], [LT_NET_ID]: [460, 640] };

Laptop.openApp = (id, params = {}) => {
    if (!Laptop.active) return;
    if (id === 'settings') id = LT_NET_ID;      // "Wi-Fi Settings" from a refused request → the Ethernet panel
    if (id !== LT_NET_ID && !Apps.byId[id]) return;
    if (!Laptop.signedIn) ltSignIn();
    const open = Laptop.wins.get(id);
    if (open) {
        open.el.classList.remove('min');
        ltFocus(id);
        if (open.mounted && open.def && open.def.onParams && Object.keys(params).length) open.def.onParams(params, open.ctx);
        return;
    }
    const def = id === LT_NET_ID ? { id, name: I18N.t('Network') } : Apps.byId[id];
    const [w, h] = LT_SIZES[id] || [440, 680];
    const n = Laptop.wins.size;
    const left = Math.min(LT_W - w - 20, 70 + n * 34 + (id === LT_NET_ID ? 700 : 0));
    const top = Math.min(LT_H - 30 - h - 90, 24 + n * 26);
    const theme = Laptop.theme();
    const win = el(`
        <div class="lt-win opening" data-theme="${theme}" style="left:${Math.max(10, left)}px;top:${Math.max(6, top)}px;width:${w}px;height:${h}px">
            <div class="lt-titlebar">
                <div class="lt-lights"><button data-w="close"><i class="fa-solid fa-xmark"></i></button><button data-w="min"><i class="fa-solid fa-minus"></i></button><button data-w="max"><i class="fa-solid fa-up-right-and-down-left-from-center"></i></button></div>
                <div class="lt-title" data-no-i18n>${esc(def.label || def.name)}</div>
            </div>
            <div class="screen lt-screen" data-theme="${theme}">
                <div class="app-window app-${id} ready"><div class="app-root" style="position:absolute;inset:0"></div></div>
                <div class="lt-offline hidden"><div><div class="lt-off-ic"><i class="fa-solid fa-ethernet"></i></div><h3></h3><p></p>
                    <button class="lt-btn" data-lt-net>${esc(I18N.t('Network'))}</button></div></div>
                <div class="overlay-layer"></div>
            </div>
        </div>`);
    $('.lt-desk', Laptop.host).appendChild(win);
    const unsubs = [];
    const rec = {
        id, def, el: win,
        root: $('.app-root', win),
        layer: $('.overlay-layer', win),
        offline: $('.lt-offline', win),
        mounted: false,
        params,
    };
    rec.ctx = {
        def, win: $('.app-window', win), root: rec.root, params,
        darkUI: false,
        on: (evt, fn) => { unsubs.push(Phone.on(evt, fn)); },
        close: () => Laptop.closeWin(id),
        _unsubs: unsubs,
    };
    Laptop.wins.set(id, rec);
    ltWireWindow(rec);
    ltFocus(id);
    requestAnimationFrame(() => win.classList.remove('opening'));
    if (id === LT_NET_ID) { rec.mounted = true; ltRenderNetwork(rec); } else ltApplyOffline(rec);
    ltRenderDock();
};

function ltMount(w) {
    w.mounted = true;
    try { w.def.open(w.root, w.params || {}, w.ctx); } catch (e) { console.error(e); }
}

Laptop.closeWin = (id) => {
    const w = Laptop.wins.get(id);
    if (!w) return;
    Laptop.wins.delete(id);
    Laptop.order = Laptop.order.filter((x) => x !== id);
    w.ctx._unsubs.forEach((u) => u());
    if (w.mounted && w.def.onClose) { try { w.def.onClose(w.ctx); } catch (e) { console.error(e); } }
    if (w.speedTimer) clearInterval(w.speedTimer);
    w.el.remove();
    ltFocus(Laptop.order[Laptop.order.length - 1]);
    if (Laptop.host) ltRenderDock();
};

function ltFocus(id) {
    Laptop.order = Laptop.order.filter((x) => x !== id);
    if (id) Laptop.order.push(id);
    Laptop.wins.forEach((w, wid) => w.el.classList.toggle('focused', wid === id));
    const w = id && Laptop.wins.get(id);
    if (w) w.el.style.zIndex = ++Laptop.z;
    $('.lt-mb-app', Laptop.host).textContent = w ? (w.def.label || w.def.name) : I18N.t('Desktop');
}

function ltWireWindow(w) {
    const win = w.el;
    win.addEventListener('pointerdown', () => ltFocus(w.id), true);
    $('.lt-lights', win).addEventListener('click', (e) => {
        const b = e.target.closest('[data-w]');
        if (!b) return;
        e.stopPropagation();
        if (b.dataset.w === 'close') Laptop.closeWin(w.id);
        if (b.dataset.w === 'min') { win.classList.add('min'); ltFocus(Laptop.order.filter((x) => x !== w.id && !Laptop.wins.get(x).el.classList.contains('min')).pop()); }
        if (b.dataset.w === 'max') win.classList.toggle('max');
    });
    $('[data-lt-net]', win).addEventListener('click', () => Laptop.openApp(LT_NET_ID));
    // drag by the title bar (the desktop is scaled, so pointer deltas are divided by the scale)
    const bar = $('.lt-titlebar', win);
    bar.addEventListener('dblclick', (e) => { if (!e.target.closest('[data-w]')) win.classList.toggle('max'); });
    bar.addEventListener('pointerdown', (e) => {
        if (e.target.closest('[data-w]') || win.classList.contains('max')) return;
        const sx = e.clientX, sy = e.clientY;
        const ox = win.offsetLeft, oy = win.offsetTop;
        bar.setPointerCapture(e.pointerId);
        const move = (ev) => {
            const k = Laptop.scale || 1;
            const x = Math.min(LT_W - 80, Math.max(-win.offsetWidth + 80, ox + (ev.clientX - sx) / k));
            const y = Math.min(LT_H - 30 - 60, Math.max(0, oy + (ev.clientY - sy) / k));
            win.style.left = x + 'px';
            win.style.top = y + 'px';
        };
        const up = () => { bar.removeEventListener('pointermove', move); bar.removeEventListener('pointerup', up); };
        bar.addEventListener('pointermove', move);
        bar.addEventListener('pointerup', up);
    });
}

/* ---------------------------------------------------------------------
   Network window (Ethernet details + speed test)
   --------------------------------------------------------------------- */

function ltRenderNetwork(w) {
    const n = Laptop.net || {};
    const online = Laptop.online();
    const [title, msg] = online ? [I18N.t('Connected'), I18N.t('This laptop is online over Ethernet. Apps don\'t use your mobile plan here.')] : ltReason(n);
    const color = online ? '#34c759' : n.link ? '#ff9f0a' : '#ff3b30';
    const isp = n.isp || {};
    const row = (k, v) => `<div class="lt-net-row"><span>${esc(I18N.t(k))}</span><span data-no-i18n>${esc(v ?? '—')}</span></div>`;
    if (!online) w.speed = null;                 // old results mean nothing once the line drops
    const keepSpeed = w.speed && w.speed.html;
    w.root.innerHTML = `
        <div class="lt-net">
            <div class="lt-net-hero">
                <div class="lt-net-state" style="background:${color}"><i class="fa-solid ${online ? 'fa-network-wired' : n.link ? 'fa-triangle-exclamation' : 'fa-ethernet'}"></i></div>
                <div><h2>${esc(title)}</h2><p>${esc(msg)}</p></div>
            </div>
            <div class="lt-net-card">
                ${row('Port', 'Ethernet · RJ45')}
                ${row('Link', n.link ? `${n.speed || 1000} Mb/s full duplex` : I18N.t('No cable'))}
                ${row('Connected to', n.via ? n.via.name : null)}
                ${n.gateway ? row('Gateway', n.gateway) : ''}
                ${row('IP address', online || n.ip ? n.ip : null)}
                ${row('Router', n.router_ip)}
                ${row('DNS', online ? '1.1.1.1, 8.8.8.8' : null)}
                ${row('MAC address', n.mac)}
            </div>
            ${isp.provider ? `<div class="lt-net-card">
                ${row('Internet provider', isp.provider)}
                ${row('Plan', isp.plan ? `${isp.plan}${isp.down ? ` · ${isp.down}/${isp.up} Mb/s` : ''}` : null)}
            </div>` : ''}
            <div class="lt-net-card lt-speedcard">
                ${keepSpeed || `<div class="lt-speed"><div><b data-sp="down">—</b><small>${esc(I18N.t('Download Mb/s'))}</small></div><div><b data-sp="up">—</b><small>${esc(I18N.t('Upload Mb/s'))}</small></div></div><div class="lt-speed-bar"><i></i></div>`}
                <div style="padding:0 14px 14px;display:flex;gap:8px">
                    <button class="lt-btn" data-speed ${online ? '' : 'disabled style="opacity:.45"'}>${esc(I18N.t('Speed Test'))}</button>
                    <button class="lt-btn gray" data-refresh>${esc(I18N.t('Refresh'))}</button>
                </div>
            </div>
            ${online ? '' : `<div class="lt-net-help">${esc(I18N.t('Tip: engineers can see the whole line with the ONT diagnostic tester or the handheld network tester.'))}</div>`}
        </div>`;
    $('[data-refresh]', w.root).onclick = () => ltPoll();
    const sp = $('[data-speed]', w.root);
    if (sp) sp.onclick = () => ltSpeedTest(w);
}

function ltSpeedTest(w) {
    if (!Laptop.online() || w.speedTimer) return;
    const isp = (Laptop.net && Laptop.net.isp) || {};
    const down = isp.down || 300, up = isp.up || 50;
    const card = $('.lt-speedcard', w.root);
    const D = $('[data-sp=down]', card), U = $('[data-sp=up]', card), bar = $('.lt-speed-bar i', card);
    D.textContent = '0'; U.textContent = '—';
    let t = 0;
    const jitter = () => 0.9 + Math.random() * 0.08;
    w.speedTimer = setInterval(() => {
        t += 1;
        if (!Laptop.online()) { clearInterval(w.speedTimer); w.speedTimer = null; return; }
        if (t <= 30) {
            D.textContent = Math.round(down * Math.min(1, t / 12) * jitter());
            bar.style.width = (t / 60 * 100) + '%';
        } else if (t <= 60) {
            U.textContent = Math.round(up * Math.min(1, (t - 30) / 12) * jitter());
            bar.style.width = (t / 60 * 100) + '%';
        } else {
            clearInterval(w.speedTimer);
            w.speedTimer = null;
            w.speed = { html: $('.lt-speed', card).outerHTML + $('.lt-speed-bar', card).outerHTML };
        }
    }, 100);
}

/* ---------------------------------------------------------------------
   notifications, app links, overlays while the laptop is in use
   --------------------------------------------------------------------- */

Laptop.banner = (n) => {
    if (!Laptop.active || !Laptop.host) return;
    const def = Apps.byId[n.app];
    const icon = def ? iconScaled(def, 34) : `<div class="lt-net-icon" style="width:34px;height:34px;font-size:16px;border-radius:9px"><i class="fa-solid fa-network-wired"></i></div>`;
    const b = el(`<div class="lt-banner">${icon}<div><b data-no-i18n>${esc(n.title || (def && def.name) || '')}</b><span data-no-i18n>${esc(n.body || '')}</span></div></div>`);
    const list = $('.lt-banners', Laptop.host);
    list.prepend(b);
    const remove = () => { b.classList.add('out'); setTimeout(() => b.remove(), 300); };
    const t = setTimeout(remove, 5000);
    b.onclick = () => { clearTimeout(t); remove(); if (n.app) Laptop.openApp(n.app); };
    $$('.lt-banner', list).slice(4).forEach((x) => x.remove());
};
Phone.on('notify', (n) => { if (Laptop.active && n) Laptop.banner(n); });
const ltSetBadge = Phone.setBadge;
Phone.setBadge = (app, n) => { ltSetBadge(app, n); if (Laptop.active) ltRenderDock(); };

// links between apps open as windows; the phone stays put away while the laptop is in use
const ltPhoneOpenApp = Phone.openApp;
Phone.openApp = (id, params = {}, fromNode) => (Laptop.active ? Laptop.openApp(id, params) : ltPhoneOpenApp(id, params, fromNode));
const ltPhonePeek = Phone.peek;
Phone.peek = (ms) => { if (!Laptop.active) ltPhonePeek(ms); };
const ltPhoneLayer = UI.layer;
UI.layer = () => (Laptop.active && Laptop.layer()) || ltPhoneLayer();
