'use strict';

/* =====================================================================
   Phone runtime: device state, lock screen, home screen, app windows,
   dynamic island, notifications, control center, hardware buttons.
   ===================================================================== */

const Phone = {
    scale: 1,
    state: 'hidden',          // hidden | open | peek
    locked: true,
    profile: null,
    settings: {},
    config: { wallpapers: [], ringtones: [], services: [], places: [] },
    badges: {},
    notifications: [],
    current: null,            // { def, win, root, ctx }
    world: null,
    _listeners: {},
    _peekTimer: null,
    _peekHold: false,

    on(evt, fn) {
        (this._listeners[evt] ||= new Set()).add(fn);
        return () => this._listeners[evt].delete(fn);
    },
    emit(evt, data) {
        (this._listeners[evt] || []).forEach((fn) => { try { fn(data); } catch (e) { console.error(e); } });
    },
};

const Apps = {
    list: [],
    byId: {},
    register(def) { this.list.push(def); this.byId[def.id] = def; },
};

/* ---------------------------------------------------------------------
   installed apps (OPS OS Store)
   System apps are always installed; everything else can be removed and
   reinstalled from the Store. Choices are saved per phone (settings.apps).
   --------------------------------------------------------------------- */

const SYSTEM_APPS = new Set(['phone', 'messages', 'contacts', 'mail', 'camera', 'photos', 'settings', 'services', 'dev', 'store']);
const HOME_ORDER = ['wallet', 'chirp', 'browser', 'maps', 'weather', 'clock', 'photos', 'notes', 'calendar', 'services', 'garage', 'contacts', 'settings', 'store', 'calculator', 'dev'];
const HOME_DOCK = ['phone', 'messages', 'mail', 'camera'];

function isInstalled(id) {
    if (typeof License !== 'undefined' && !License.allowsApp(id)) return false;   // not in this server's OPSHUB license
    if (SYSTEM_APPS.has(id)) return true;
    const a = Phone.settings && Phone.settings.apps;
    if (a && typeof a[id] === 'boolean') return a[id];
    const d = Apps.byId[id];
    return !(d && d.defaultInstalled === false); // new Store apps start uninstalled
}

/** home screen pages built from what is installed (page 1 has the widgets) */
function homeLayout() {
    const known = new Set([...HOME_ORDER, ...HOME_DOCK]);
    const extra = Apps.list.map((a) => a.id).filter((id) => !known.has(id)); // apps added later
    const saved = Array.isArray(Phone.settings && Phone.settings.homeOrder) ? Phone.settings.homeOrder : [];
    const base = [...saved.filter((id) => !HOME_DOCK.includes(id)), ...HOME_ORDER, ...extra];
    const ids = [...new Set(base)].filter((id) => Apps.byId[id] && isInstalled(id));
    // the Batteries widget (js/batteries.js) takes the place of four icons on page 1
    const batt = typeof Batteries !== 'undefined' && Batteries.visible();
    const first = batt ? 12 : 16;
    const pages = [batt ? ['@widgets', '@batteries', ...ids.slice(0, first)] : ['@widgets', ...ids.slice(0, first)]];
    for (let i = first; i < ids.length; i += 24) pages.push(ids.slice(i, i + 24));
    return { pages, dock: HOME_DOCK };
}
let HOME_LAYOUT = { pages: [['@widgets']], dock: HOME_DOCK };

Phone.isInstalled = isInstalled;

function setInstalled(id, on) {
    if (SYSTEM_APPS.has(id)) return;
    const apps = { ...(Phone.settings.apps || {}), [id]: !!on };
    Phone.settings.apps = apps;
    rpc('saveSettings', { apps });
    if (!on) Phone.quitApp(id);
    if (!on) Phone.setBadge(id, 0);
    renderHome();
    Phone.emit('appsChanged', { id, installed: !!on });
}
Phone.installApp = (id) => setInstalled(id, true);
Phone.uninstallApp = (id) => setInstalled(id, false);

const screenEl = () => $('#screen');
const wrapEl = () => $('#phone-wrap');

/* ---------------------------------------------------------------------
   layout / visibility
   --------------------------------------------------------------------- */

const PHONE_H = 886;

function layoutPhone() {
    const zoom = Phone.settings.zoom || 1;
    const s = Math.min(1, (window.innerHeight * 0.84) / PHONE_H) * zoom;
    Phone.scale = s;
    let ty;
    if (Phone.state === 'open') ty = -Math.round(window.innerHeight * 0.035);
    else if (Phone.state === 'peek') ty = PHONE_H * s - 250 * s;
    else ty = PHONE_H * s + 80;
    wrapEl().style.transform = `translateY(${ty}px) scale(${s})`;
    wrapEl().classList.toggle('hidden', Phone.state === 'hidden');
}
window.addEventListener('resize', layoutPhone);

function setState(state) {
    clearTimeout(Phone._peekTimer);
    Phone.state = state;
    if (state === 'hidden') {
        // stay visible during the slide-down
        wrapEl().classList.remove('hidden');
        const s = Phone.scale;
        wrapEl().style.transform = `translateY(${PHONE_H * s + 80}px) scale(${s})`;
        setTimeout(() => { if (Phone.state === 'hidden') wrapEl().classList.add('hidden'); }, 500);
        return;
    }
    layoutPhone();
}

Phone.peek = (ms = 4500) => {
    if (Phone.state === 'open' || battery <= 0) return;
    setState('peek');
    Phone._peekHold = ms === 0;
    if (ms > 0) Phone._peekTimer = setTimeout(() => { if (Phone.state === 'peek') setState('hidden'); }, ms);
};
Phone.unpeek = () => { Phone._peekHold = false; if (Phone.state === 'peek') setState('hidden'); };

Phone.close = () => nui('close');

/* ---------------------------------------------------------------------
   settings / theme
   --------------------------------------------------------------------- */

function wallpaperCss(w) {
    if (!w) w = 'ios18';
    if (/^https?:\/\//i.test(w)) return `url('${cssUrl(w)}') center/cover`;
    const found = (Phone.config.wallpapers || []).find((x) => x.id === w);
    return found ? found.css : (Phone.config.wallpapers?.[0]?.css || '#111');
}

function applySettings() {
    const s = Phone.settings;
    const scr = screenEl();
    scr.dataset.theme = s.darkMode ? 'dark' : 'light';
    scr.classList.toggle('airplane', !!s.airplane);
    if (typeof CarrierState !== 'undefined') CarrierState.apply();
    scr.classList.toggle('reduce-transparency', !!s.reduceTransparency);
    scr.classList.toggle('reduce-motion', !!s.reduceMotion);
    $('#wallpaper').style.background = wallpaperCss(s.wallpaper);
    $('#brightness-dim').style.opacity = String((1 - (s.brightness ?? 1)) * 0.7);
    Sound.setVolume(s.volume ?? 0.7);
    Sound.setSilent(!!s.silent);
    updateChrome();
    layoutPhone();
}

Phone.saveSetting = (key, value) => {
    Phone.settings[key] = value;
    applySettings();
    rpc('saveSettings', { [key]: value });
    Phone.emit('settings', { key, value });
};

/** status bar + home indicator colour */
function updateChrome() {
    const scr = screenEl();
    const cur = Phone.current;
    const overlay = $('#control-center').classList.contains('open') || $('#notif-center').classList.contains('open');
    const inCall = $('#call-screen').classList.contains('show');
    let dark = false;
    if (!Phone.locked && cur && !overlay && !inCall) {
        const appDark = cur.def.dark || (cur.ctx && cur.ctx.darkUI);
        dark = !appDark && scr.dataset.theme === 'light';
    }
    scr.classList.toggle('status-dark', dark);
    scr.classList.toggle('indicator-dark', dark);
}
Phone.updateChrome = updateChrome;

/* ---------------------------------------------------------------------
   clock tick
   --------------------------------------------------------------------- */

let lastMinute = '';
function tick(force) {
    const now = new Date();
    // alarms/timers still run while the phone is away; the DOM only updates when it's visible
    Phone.emit('tick', now);
    if (Phone.state === 'hidden' && force !== true) return;
    const hm = clockHM(now);
    if (hm === lastMinute && force !== true) return;
    lastMinute = hm;
    $('#sb-time').textContent = hm;
    $('#ls-time').textContent = hm;
    $('#ls-date').textContent = now.toLocaleDateString(Phone.locale, { weekday: 'long', month: 'long', day: 'numeric' });
    const nct = $('.nc-time'); if (nct) nct.textContent = hm;
    $$('[data-dyn-icon]').forEach((n) => { const d = Apps.byId[n.dataset.dynIcon]; if (d && d.icon.html) n.innerHTML = d.icon.html(); });
}

/* battery slowly drains while the phone is used, recharges when closed */
/* battery: the real level comes from the game (client/battery.lua) — drains with use, charges on a charger */
let battery = 100;
Phone.battery = { level: 100, charging: null };
function batteryTick() {
    const b = $('#sb-battery');
    if (!b) return;
    b.style.width = Math.max(3, battery) + '%';
    b.classList.toggle('low', battery <= 20 && !Phone.battery.charging);
    const wrap = b.parentElement;
    wrap.classList.toggle('charging', !!Phone.battery.charging);
    wrap.title = battery + '%';
}

/* ---------------------------------------------------------------------
   dynamic island
   --------------------------------------------------------------------- */

// Dynamic Island lives in js/island.js

/* ---------------------------------------------------------------------
   lock screen / passcode / Face Unlock
   --------------------------------------------------------------------- */

const FACE_ID_SVG = `<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round">
    <path d="M6 20V12a6 6 0 0 1 6-6h8M44 6h8a6 6 0 0 1 6 6v8M58 44v8a6 6 0 0 1-6 6h-8M20 58h-8a6 6 0 0 1-6-6v-8"/>
    <path d="M22 24v5M42 24v5M32 24v12h-3M24 44c4.5 4 11.5 4 16 0"/></svg>`;

// Every lock bumps this, so an unlock that was started earlier (Face Unlock scan,
// passcode delay) is discarded if the phone was locked/put away meanwhile.
let lockSeq = 0;
let lockTimer = null;

function lockPhone() {
    clearTimeout(lockTimer);
    lockTimer = null;
    lockSeq++;
    Phone._unlocking = false;
    Phone._afterUnlock = null;
    Phone.faceVerified = false;
    const face = $('.faceid');
    if (face) face.classList.remove('scan', 'ok');
    hidePasscode();
    // don't leave a hidden text field holding the keyboard
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    if (Phone.locked) return;
    Phone.locked = true;
    screenEl().classList.add('locked');
    $('#ls-lock-icon').className = 'fa-solid fa-lock';
    closeOverlays();
    updateChrome();
    Phone.emit('locked');
}

function unlockPhone(seq = lockSeq) {
    if (seq !== lockSeq || !Phone.locked) return;
    Phone._unlocking = false;
    Phone.locked = false;
    $('#ls-lock-icon').className = 'fa-solid fa-lock-open';
    screenEl().classList.remove('locked');
    hidePasscode();
    Sound.play('unlock');
    updateChrome();
    Phone.emit('unlocked');
    if (Phone._afterUnlock) { const f = Phone._afterUnlock; Phone._afterUnlock = null; f(); }
}

async function tryUnlock(after) {
    if (!Phone.locked) { after && after(); return; }
    if (Phone.state !== 'open') return;
    if (after) Phone._afterUnlock = after;
    if (Phone._unlocking || $('#passcode').classList.contains('show')) return;
    const code = Phone.settings.passcode;
    if (code && Phone.settings.faceId === false) return showPasscode();
    // already recognised while the phone was raised
    if (Phone.faceVerified) return unlockPhone(lockSeq);

    // Face Unlock scan
    Phone._unlocking = true;
    const seq = lockSeq;
    const face = $('.faceid', $('#lockscreen'));
    face.classList.remove('ok');
    face.classList.add('scan');
    await sleep(code ? 700 : 260);
    if (seq !== lockSeq) return;
    face.classList.add('ok');
    await sleep(code ? 250 : 80);
    face.classList.remove('scan', 'ok');
    unlockPhone(seq);
}

/** Auto-Lock delay in seconds: 0 = immediately, -1 = never (legacy booleans supported). */
function autoLockDelay() {
    const v = Phone.settings.autoLock;
    if (v === false) return -1;
    if (typeof v === 'number') return v;
    return 0;
}

/** called when the phone is put away */
function scheduleAutoLock() {
    clearTimeout(lockTimer);
    lockTimer = null;
    if (Phone.locked || Phone.inCall) return;
    const delay = autoLockDelay();
    if (delay < 0) return;
    // wait for the slide-down to finish, then lock off-screen without animation
    lockTimer = setTimeout(() => { if (Phone.state !== 'open') lockQuietly(); }, delay === 0 ? 560 : delay * 1000);
}

function lockQuietly() {
    const scr = screenEl();
    scr.classList.add('no-anim');
    lockPhone();
    void scr.offsetHeight;
    requestAnimationFrame(() => scr.classList.remove('no-anim'));
}

/** Face Unlock on raise: recognises you while the phone comes up, so a swipe opens it instantly */
async function autoFaceScan() {
    if (!Phone.locked || Phone.settings.faceId === false || Phone.faceVerified || Phone.needsSetup) return;
    const seq = lockSeq;
    const face = $('.faceid', $('#lockscreen'));
    face.classList.remove('ok');
    face.classList.add('scan');
    await sleep(520);
    if (seq !== lockSeq || !Phone.locked) return;
    face.classList.add('ok');
    await sleep(160);
    face.classList.remove('scan', 'ok');
    if (seq !== lockSeq || !Phone.locked) return;
    Phone.faceVerified = true;
    $('#ls-lock-icon').className = 'fa-solid fa-lock-open';
}

let pcEntry = '';
function showPasscode() {
    const code = Phone.settings.passcode || '';
    const len = code.length || 4;
    pcEntry = '';
    const keys = [['1', ''], ['2', 'ABC'], ['3', 'DEF'], ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'], ['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ']];
    const pc = $('#passcode');
    pc.innerHTML = `
        <i class="fa-solid fa-lock" style="font-size:18px;margin-bottom:14px"></i>
        <div class="pc-title">Enter Passcode</div>
        <div class="pc-dots">${'<i></i>'.repeat(len)}</div>
        <div class="pc-grid">
            ${keys.map(([n, l]) => `<button class="pc-key" data-k="${n}">${n}<small>${l || '&nbsp;'}</small></button>`).join('')}
            <button class="pc-key zero" data-k="0">0</button>
        </div>
        <div class="pc-actions"><button data-pc="emergency">Emergency</button><button data-pc="cancel">Cancel</button></div>`;
    pc.classList.add('show');
}
function hidePasscode() { $('#passcode').classList.remove('show'); }

/** Emergency dialer shown over the lock screen — never unlocks the phone */
function showEmergency() {
    const pc = $('#passcode');
    pc.innerHTML = `
        <div class="pc-title" style="margin-bottom:26px">Emergency</div>
        <div class="em-list">${(Phone.config.services || []).map((s) => `
            <button class="em-btn" data-emergency="${esc(s.number)}">
                <span class="em-icon" style="background:${esc(s.color)}"><i class="fa-solid ${esc(s.icon)}"></i></span>
                <span class="em-label">${esc(s.label)}<small>${esc(s.number)}</small></span>
                <i class="fa-solid fa-phone"></i>
            </button>`).join('')}
        </div>
        <div class="pc-actions"><span></span><button data-pc="back">Cancel</button></div>`;
    pc.classList.add('show');
}

function passcodeKey(k) {
    const code = Phone.settings.passcode || '';
    const pc = $('#passcode');
    pcEntry += k;
    Sound.play('key', k);
    $$('.pc-dots i', pc).forEach((d, i) => d.classList.toggle('on', i < pcEntry.length));
    $('[data-pc=cancel]', pc).textContent = 'Delete';
    if (pcEntry.length >= code.length) {
        if (pcEntry === code) {
            const seq = lockSeq;
            setTimeout(() => unlockPhone(seq), 120);
        } else {
            const dots = $('.pc-dots', pc);
            dots.classList.add('shake');
            // keys typed during the shake already count towards the next try
            setTimeout(() => { dots.classList.remove('shake'); $$('i', dots).forEach((d, i) => d.classList.toggle('on', i < pcEntry.length)); }, 450);
            pcEntry = '';
            $('[data-pc=cancel]', pc).textContent = 'Cancel';
        }
    }
}

function setupLockscreen() {
    const ls = $('#lockscreen');
    ls.insertAdjacentHTML('afterbegin', `<div class="faceid">${FACE_ID_SVG}</div>`);

    drag(ls, {
        onStart: (e) => !e.target.closest('.ls-btn, .notif, .passcode'),
        onMove: (dx, dy) => {
            if (dy > 0 || Math.abs(dx) > Math.abs(dy)) return; // sideways is the camera swipe (js/gestures.js)
            ls.classList.add('dragging');
            ls.style.transform = `translateY(${dy * 0.6}px)`;
            ls.style.opacity = String(1 + dy / 900);
        },
        onEnd: (dx, dy, vy, _vx, _e, moved) => {
            ls.classList.remove('dragging');
            ls.style.transform = '';
            ls.style.opacity = '';
            if (moved && Math.abs(dy) >= Math.abs(dx) && (dy < -110 || vy < -0.6)) tryUnlock();
        },
    });

    ls.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-ls]');
        if (btn) {
            if (btn.dataset.ls === 'flashlight') {
                const on = !btn.classList.contains('on');
                btn.classList.toggle('on', on);
                setFlashlight(on);
            } else if (btn.dataset.ls === 'camera') {
                Phone.openApp('camera', { fromLock: Phone.locked });
            }
            return;
        }
        const k = e.target.closest('.pc-key');
        if (k) return passcodeKey(k.dataset.k);
        const act = e.target.closest('[data-pc]');
        if (act) {
            if (act.dataset.pc === 'cancel') {
                if (pcEntry.length) {
                    pcEntry = pcEntry.slice(0, -1);
                    $$('.pc-dots i').forEach((d, i) => d.classList.toggle('on', i < pcEntry.length));
                    if (!pcEntry.length) act.textContent = 'Cancel';
                } else { hidePasscode(); Phone._afterUnlock = null; }
            } else if (act.dataset.pc === 'emergency') {
                showEmergency();
            } else if (act.dataset.pc === 'back') {
                showPasscode();
            }
            return;
        }
        const em = e.target.closest('[data-emergency]');
        if (em) {
            // calls work from the lock screen; the phone itself stays locked
            Call.start(em.dataset.emergency);
            return;
        }
        if (e.target.closest('.ls-hint')) return tryUnlock();
        const n = e.target.closest('.notif');
        if (n) openNotification(Phone.notifications.find((x) => x.id === n.dataset.id));
    });
}

function setFlashlight(on) {
    Phone.flashlight = on;
    nui('flashlight', { on });
    $$('[data-ls=flashlight]').forEach((b) => b.classList.toggle('on', on));
    $$('[data-cc=flashlight]').forEach((b) => b.classList.toggle('on', on));
}

/* ---------------------------------------------------------------------
   home screen
   --------------------------------------------------------------------- */

function iconHtml(def, size) {
    const ic = def.icon;
    const inner = ic.html ? ic.html() : `<i class="${ic.glyph}" style="${ic.glyphStyle || ''}"></i>`;
    return `<div class="icon" style="background:${ic.bg};color:${ic.color || '#fff'};font-size:${ic.size || 30}px;${size ? `width:${size}px;height:${size}px;border-radius:${size * 0.225}px;` : ''}" ${ic.html ? `data-dyn-icon="${def.id}"` : ''}>${inner}</div>`;
}

/**
 * An app icon at any size: the 64px design is drawn once and scaled as a
 * whole, so glyphs and custom artwork keep their proportions.
 */
function iconScaled(def, size, extraClass = '') {
    const k = size / 64;
    return `<div class="icon-scaled ${extraClass}" style="width:${size}px;height:${size}px;border-radius:${size * 0.225}px">` +
        `<div style="width:64px;height:64px;transform:scale(${k});transform-origin:0 0">${iconHtml(def)}</div></div>`;
}

function appIconHtml(id) {
    const def = Apps.byId[id];
    if (!def || !isInstalled(id) || (def.visible && !def.visible())) return '';
    const badge = Phone.badges[id] ? `<span class="badge">${Phone.badges[id] > 99 ? '99+' : Phone.badges[id]}</span>` : '';
    const remove = SYSTEM_APPS.has(id) ? '' : `<button class="rm-badge" data-remove="${id}" title="Remove App"><i class="fa-solid fa-minus"></i></button>`;
    return `<div class="app-icon" data-app="${id}">${badge}${remove}${iconHtml(def)}<div class="label">${esc(def.label || def.name)}</div></div>`;
}

function widgetsHtml() {
    const now = new Date();
    const first = (new Date(now.getFullYear(), now.getMonth(), 1).getDay() - (typeof weekOffset === 'function' ? weekOffset() : 0) + 7) % 7;
    const days = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    const cells = (typeof weekLetters === 'function' ? weekLetters() : ['S', 'M', 'T', 'W', 'T', 'F', 'S']).map((d) => `<span class="h">${d}</span>`);
    for (let i = 0; i < first; i++) cells.push('<span class="m">.</span>');
    for (let d = 1; d <= days; d++) cells.push(`<span class="${d === now.getDate() ? 't' : ''}">${d}</span>`);
    const w = Phone.world || {};
    const wx = typeof WeatherModel !== 'undefined' ? WeatherModel.current(w) : { temp: 72, label: 'Sunny', icon: 'fa-sun', hi: 78, lo: 63, cls: '' };
    return `
        <div class="widget-wrap" data-widget="weather">
            <div class="widget w-weather ${wx.cls}">
                <div class="ww-city">${esc(w.zone || 'Los Santos')} <i class="fa-solid fa-location-arrow"></i></div>
                <div class="ww-temp">${wx.temp}°</div>
                <div class="ww-icon"><i class="fa-solid ${wx.icon}"></i></div>
                <div class="ww-cond" data-no-i18n>${esc(typeof I18N !== 'undefined' ? I18N.weather(wx.label) : wx.label)}</div>
                <div class="ww-hl">H:${wx.hi}° L:${wx.lo}°</div>
            </div>
            <div class="wl">Weather</div>
        </div>
        <div class="widget-wrap" data-widget="calendar">
            <div class="widget w-calendar ${Phone.settings.darkMode ? 'dark' : ''}">
                <div class="wc-day">${now.toLocaleDateString(Phone.locale, { month: 'long' })}</div>
                <div class="wc-month">${cells.join('')}</div>
            </div>
            <div class="wl">Calendar</div>
        </div>`;
}

/** refresh just the weather widget (instead of rebuilding the whole home screen) */
function updateWeatherWidget() {
    const old = $('[data-widget="weather"]');
    if (!old) return;
    const tmp = document.createElement('div');
    tmp.innerHTML = widgetsHtml();
    old.replaceWith(tmp.firstElementChild);
}

function renderHome() {
    HOME_LAYOUT = homeLayout();
    const pages = $('#home-pages');
    const scroll = pages.scrollLeft;
    pages.innerHTML = HOME_LAYOUT.pages.map((p) => `<div class="home-page">${p.map((id) => (id === '@widgets' ? widgetsHtml() : id === '@batteries' ? Batteries.html() : appIconHtml(id))).join('')}</div>`).join('');
    pages.scrollLeft = scroll;
    $('#home-dots').innerHTML = HOME_LAYOUT.pages.map((_, i) => `<i data-page="${i}"></i>`).join('');
    $('#dock').innerHTML = HOME_LAYOUT.dock.map(appIconHtml).join('');
    updateDots();
}
Phone.renderHome = renderHome;

function updateDots() {
    const pages = $('#home-pages');
    const i = Math.round(pages.scrollLeft / 393);
    $$('#home-dots i').forEach((d, j) => d.classList.toggle('on', i === j));
}

Phone.setBadge = (app, n) => {
    Phone.badges[app] = Math.max(0, n | 0);
    $$(`.app-icon[data-app="${app}"]`).forEach((ic) => {
        let b = $('.badge', ic);
        if (!Phone.badges[app]) { b && b.remove(); return; }
        if (!b) { b = el('<span class="badge"></span>'); ic.prepend(b); }
        b.textContent = Phone.badges[app] > 99 ? '99+' : Phone.badges[app];
    });
};

function setupHome() {
    const home = $('#home');
    const pages = $('#home-pages');
    let swallowClick = false; // the release after a long press is not a tap

    home.addEventListener('click', async (e) => {
        const rm = e.target.closest('[data-remove]');
        if (rm && home.classList.contains('jiggle')) {
            e.stopPropagation();
            const def = Apps.byId[rm.dataset.remove];
            const ok = await UI.alert({
                title: `${I18N.t('Remove')} “${def.label || def.name}”?`,
                message: I18N.t('You can reinstall it any time from the OPS OS Store.'),
                buttons: [{ label: I18N.t('Cancel'), value: false, style: 'cancel' }, { label: I18N.t('Remove App'), value: true, style: 'destructive' }],
            });
            if (ok) Phone.uninstallApp(def.id);
            return;
        }
        if (swallowClick || Phone._swallowHomeClick) { swallowClick = false; Phone._swallowHomeClick = false; return; }
        if (home.classList.contains('jiggle')) { if (!e.target.closest('.app-icon')) Phone.exitJiggle(); return; }
        const icon = e.target.closest('.app-icon[data-app]');
        if (icon) return Phone.openApp(icon.dataset.app, {}, $('.icon', icon));
        const w = e.target.closest('[data-widget]');
        if (w) return Phone.openApp(w.dataset.widget, {}, $('.widget', w));
        const dot = e.target.closest('[data-page]');
        if (dot) pages.scrollTo({ left: +dot.dataset.page * 393 });
    });

    // long-press (quick actions / jiggle) handled in js/gestures.js

    pages.addEventListener('scroll', updateDots, { passive: true });
    let startScroll = 0;
    drag(pages, {
        onStart: () => { startScroll = pages.scrollLeft; return true; },
        onMove: (dx, dy) => { if (Math.abs(dy) > Math.abs(dx) * 1.2 && Math.abs(dx) < 20) return; pages.classList.add('dragging'); pages.scrollLeft = startScroll - dx; },
        onEnd: (dx, _dy, _vy, vx, _e, moved) => {
            pages.classList.remove('dragging');
            if (!moved) return;
            let page = Math.round(startScroll / 393);
            if (dx < -60 || vx < -0.4) page++;
            else if (dx > 60 || vx > 0.4) page--;
            page = Math.max(0, Math.min(HOME_LAYOUT.pages.length - 1, page));
            pages.scrollTo({ left: page * 393 });
            // swallow the click that follows a drag
            const stop = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
            window.addEventListener('click', stop, { capture: true, once: true });
            setTimeout(() => window.removeEventListener('click', stop, { capture: true }), 50);
        },
    });
}

/* ---------------------------------------------------------------------
   app windows
   --------------------------------------------------------------------- */

function rectInScreen(node) {
    if (!node) return null;
    const r = node.getBoundingClientRect();
    const s = screenEl().getBoundingClientRect();
    if (!r.width) return null;
    const k = Phone.scale || 1;
    const x = (r.left - s.left) / k, y = (r.top - s.top) / k, w = r.width / k, h = r.height / k;
    if (x < -10 || x > 393 || y < -10 || y > 852) return null;
    return { x, y, w, h };
}

function iconNodeFor(id) {
    const pages = $('#home-pages');
    const page = Math.round(pages.scrollLeft / 393);
    const dock = $(`#dock .app-icon[data-app="${id}"] .icon`);
    if (dock) return dock;
    const pageEl = pages.children[page];
    return pageEl && ($(`.app-icon[data-app="${id}"] .icon`, pageEl) || $(`[data-widget="${id}"] .widget`, pageEl));
}

function zoomTransform(r) {
    const sx = r.w / 393, sy = r.h / 852;
    return { transform: `translate(${r.x}px, ${r.y}px) scale(${sx}, ${sy})`, radius: `${15 / sx}px / ${15 / sy}px` };
}

Phone.openApp = (id, params = {}, fromNode) => {
    const def = Apps.byId[id];
    if (!def) return;
    if (!isInstalled(id)) return Phone.openApp('store', { app: id });
    // the camera opens over the lock screen without unlocking, like a real phone
    if (Phone.locked && !(id === 'camera' && params.fromLock)) return tryUnlock(() => Phone.openApp(id, params));
    closeOverlays();
    $('#home').classList.remove('jiggle');

    if (Phone.current && Phone.current.def.id === id) {
        if (def.onParams && Object.keys(params).length) def.onParams(params, Phone.current.ctx);
        return;
    }
    if (Phone.current) closeApp(true);
    touchRecent(id);

    // reopened while its close animation is still running: take it back
    const closing = Phone.closing.get(id);
    if (closing) {
        clearTimeout(closing.timer);
        clearTimeout(closing.fade);
        Phone.closing.delete(id);
        resumeWindow(closing.app, fromNode);
        if (def.onParams && Object.keys(params).length) def.onParams(params, closing.app.ctx);
        return;
    }
    // resume a suspended app exactly where it was left
    const sus = Phone.suspended.get(id);
    if (sus) {
        Phone.suspended.delete(id);
        resumeWindow(sus, fromNode);
        if (def.onParams && Object.keys(params).length) def.onParams(params, sus.ctx);
        return;
    }

    const win = el(`
        <div class="app-window app-${id}">
            <div class="app-splash" style="background:${def.splash || 'var(--bg)'}"></div>
            <div class="app-root" style="position:absolute;inset:0"></div>
        </div>`);
    const root = $('.app-root', win);
    $('#app-layer').appendChild(win);

    const unsubs = [];
    const ctx = {
        def, win, root, params,
        darkUI: false,
        on: (evt, fn) => { unsubs.push(Phone.on(evt, fn)); },
        close: () => closeApp(),
        _unsubs: unsubs,
    };
    Phone.current = { def, win, root, ctx };

    const from = rectInScreen(fromNode || iconNodeFor(id));
    if (from) {
        const z = zoomTransform(from);
        win.style.transition = 'none';
        win.style.transform = z.transform;
        win.getBoundingClientRect();
        win.style.transition = '';
        requestAnimationFrame(() => {
            win.classList.add('animating');
            win.style.transform = '';
            setTimeout(() => win.classList.remove('animating'), 520);
        });
    }
    screenEl().classList.add('app-open');

    try { def.open(root, params, ctx); } catch (e) { console.error(e); }
    setTimeout(() => win.classList.add('ready'), 60);
    updateChrome();
};

/* ---------------------------------------------------------------------
   multitasking: apps are suspended (kept with their state) when you leave
   them, and resumed exactly where they were. Apps with live loops
   (camera, maps, clock...) set resumable:false and restart fresh.
   --------------------------------------------------------------------- */

Phone.suspended = new Map();   // id -> { def, win, root, ctx }
Phone.recents = [];            // most recent first
const MAX_SUSPENDED = 5;

function touchRecent(id) {
    Phone.recents = [id, ...Phone.recents.filter((x) => x !== id && Apps.byId[x] && isInstalled(x))].slice(0, 8);
}

function destroyApp(app) {
    if (!app) return;
    app.ctx._unsubs.forEach((u) => u());
    try { app.def.onClose && app.def.onClose(app.ctx); } catch (e) { console.error(e); }
    app.win.remove();
}

/** fully quit an app (switcher swipe-up, uninstall, character switch) */
Phone.quitApp = (id) => {
    if (Phone.current && Phone.current.def.id === id) closeApp(true, true);
    // still animating closed: it would be suspended right after this
    const c = Phone.closing.get(id);
    if (c) { clearTimeout(c.timer); clearTimeout(c.fade); Phone.closing.delete(id); destroyApp(c.app); }
    const s = Phone.suspended.get(id);
    if (s) { Phone.suspended.delete(id); destroyApp(s); }
    Phone.recents = Phone.recents.filter((x) => x !== id);
};

function suspendApp(app) {
    app.win.remove();
    app.win.style.cssText = '';
    app.win.classList.remove('animating');
    Phone.suspended.set(app.def.id, app);
    // keep memory bounded: drop the least recent ones
    while (Phone.suspended.size > MAX_SUSPENDED) {
        const oldest = [...Phone.suspended.keys()].sort((a, b) => Phone.recents.indexOf(b) - Phone.recents.indexOf(a))[0];
        destroyApp(Phone.suspended.get(oldest));
        Phone.suspended.delete(oldest);
    }
}

/** reload whatever page is visible in the current app (fresh data after resume) */
function refreshVisiblePages() {
    const cur = Phone.current;
    if (!cur) return;
    $$('.page', cur.win)
        .filter((p) => !p.classList.contains('behind') && !p.classList.contains('leaving') && !p.closest('.tab-host.hidden'))
        .forEach((p) => { const c = p._ctx; if (c && c.opts.onResume) c.opts.onResume(c); });
}

function resumeWindow(app, fromNode, fromRect) {
    const win = app.win;
    win.style.cssText = '';
    win.classList.add('ready');
    $('#app-layer').appendChild(win);
    Phone.current = app;
    const from = fromRect || rectInScreen(fromNode || iconNodeFor(app.def.id));
    if (from) {
        const z = zoomTransform(from);
        win.style.transition = 'none';
        win.style.transform = z.transform;
        win.getBoundingClientRect();
        win.style.transition = '';
        requestAnimationFrame(() => { win.classList.add('animating'); win.style.transform = ''; setTimeout(() => win.classList.remove('animating'), 520); });
    }
    screenEl().classList.add('app-open');
    updateChrome();
    refreshVisiblePages();
    Phone.emit('appResumed', app.def.id);
}
Phone.resumeWindow = resumeWindow;

function closeApp(instant = false, destroy = false) {
    const cur = Phone.current;
    if (!cur) return;
    Phone.current = null;
    const keep = !destroy && cur.def.resumable !== false && isInstalled(cur.def.id);
    if (!keep) {
        cur.ctx._unsubs.forEach((u) => u());
        try { cur.def.onClose && cur.def.onClose(cur.ctx); } catch (e) { console.error(e); }
    }
    screenEl().classList.remove('app-open');
    const win = cur.win;
    const finish = () => (keep ? suspendApp(cur) : win.remove());
    if (instant) { finish(); updateChrome(); return; }

    const to = rectInScreen(iconNodeFor(cur.def.id));
    win.classList.add('animating');
    win.style.pointerEvents = 'none';
    let fade = null;
    if (to) {
        const z = zoomTransform(to);
        win.classList.remove('ready');
        win.style.transform = z.transform;
        fade = setTimeout(() => { win.style.opacity = '0'; }, 280);
    } else {
        win.style.transform = 'translate(98px, 213px) scale(.5)';
        win.style.opacity = '0';
    }
    const t = setTimeout(() => { Phone.closing.delete(cur.def.id); if (Phone.current !== cur) finish(); }, 480);
    if (keep) Phone.closing.set(cur.def.id, { app: cur, timer: t, fade });
    updateChrome();
}
Phone.closing = new Map();
Phone.closeApp = closeApp;

// setupHomeIndicator() lives in js/gestures.js

function goHome() {
    if (Phone.needsSetup) return;
    if (closeOverlays()) return;
    // swipe up in the app switcher / Search goes back to the home screen
    if (Phone.Switcher && Phone.Switcher.el) return Phone.Switcher.close();
    if (Phone.Spotlight && Phone.Spotlight.el) return Phone.Spotlight.close();
    if (typeof Call !== 'undefined' && Call.minimize()) return;
    if ($('.sheet.show, .alert.show, .action-sheet.show')) {
        $$('.backdrop').forEach((b) => b.click());
        return;
    }
    if (Phone.locked && Phone.current) return closeApp(); // lock screen camera -> back to the lock screen
    if (Phone.locked) return tryUnlock();
    if (Phone.current) return closeApp();
    $('#home').classList.remove('jiggle');
    $('#home-pages').scrollTo({ left: 0 });
}
Phone.goHome = goHome;

/* ---------------------------------------------------------------------
   notifications
   --------------------------------------------------------------------- */

const APP_ICON_FALLBACK = { bg: 'linear-gradient(180deg,#8e8e93,#636366)', glyph: 'fa-solid fa-bell' };

function notifIcon(n) {
    const def = Apps.byId[n.app];
    if (def) return iconScaled(def, 38, 'n-icon');
    return `<div class="n-icon" style="background:${APP_ICON_FALLBACK.bg}"><i class="${n.icon ? 'fa-solid ' + esc(n.icon) : APP_ICON_FALLBACK.glyph}"></i></div>`;
}

function notifHtml(n) {
    return `
        <div class="notif" data-id="${n.id}">
            ${notifIcon(n)}
            <div class="n-body">
                <div class="n-top"><div class="n-title">${esc(n.title || '')}</div><div class="n-time">${esc(shortAgo(n.time))}</div></div>
                <div class="n-text">${esc(n.body || '')}</div>
            </div>
        </div>`;
}

function renderNotifLists() {
    const recent = Phone.notifications.slice(0, 6);
    $('#ls-notifs').innerHTML = recent.map(notifHtml).join('');
    const nc = $('.nc-list');
    if (nc) nc.innerHTML = Phone.notifications.length
        ? `<div class="nc-head"><span>Notification Centre</span><button class="nc-clear"><i class="fa-solid fa-xmark"></i></button></div>${Phone.notifications.map(notifHtml).join('')}`
        : '<div class="nc-empty">No Older Notifications</div>';
}

let notifSeq = 0;
Phone.notify = (n) => {
    if (Apps.byId[n.app] && !isInstalled(n.app)) return; // removed apps stay quiet
    n = { ...n, id: 'n' + (++notifSeq), time: Date.now() };
    const cur = Phone.current;
    const visible = Phone.state === 'open' && !Phone.locked;

    // apps can swallow notifications for the screen the user is already on
    if (visible && cur && cur.def.id === n.app && cur.def.suppress && cur.def.suppress(n, cur.ctx)) {
        Sound.play('sent');
        return;
    }

    Phone.notifications.unshift(n);
    Phone.notifications = Phone.notifications.slice(0, 50);
    renderNotifLists();

    if (Phone.settings.dnd) return;
    Sound.play(n.app === 'messages' ? 'message' : 'notify');
    if (Sound.silent) vibrate();

    if (Phone.state === 'hidden' || (Phone.state === 'peek' && !Phone._peekHold)) Phone.peek();
    if (Phone.locked && Phone.state === 'open') return; // lock screen list shows it
    if (bannersBlocked()) return; // call screen / Notification or Control Centre open: it waits in the list

    const b = el(notifHtml(n));
    b.classList.add('banner-in');
    $('#banners').prepend(b);
    const remove = () => { b.classList.add('banner-out'); setTimeout(() => b.remove(), 400); };
    const t = setTimeout(remove, 4500);
    b.addEventListener('click', () => { clearTimeout(t); remove(); openNotification(n); });
    drag(b, { onEnd: (_dx, dy, _vy, _vx, _e, moved) => { if (moved && dy < -20) { clearTimeout(t); remove(); } } });
    $$('#banners .notif').slice(3).forEach((x) => x.remove());
};

/** full-screen layers that banners would cover (the caller's name, the list itself) */
function bannersBlocked() {
    return $('#call-screen').classList.contains('show') || $('#notif-center').classList.contains('open') || $('#control-center').classList.contains('open');
}

/** slide away any banners on screen (a call screen or a Centre is opening over them) */
function clearBanners() {
    $$('#banners .notif').forEach((b) => { b.classList.add('banner-out'); setTimeout(() => b.remove(), 400); });
}
Phone.clearBanners = clearBanners;

function openNotification(n) {
    if (!n) return;
    Phone.notifications = Phone.notifications.filter((x) => x !== n);
    renderNotifLists();
    if (Phone.state !== 'open') return;
    const data = n.data || {};
    if (data.type === 'gps') nui('setWaypoint', { x: data.x, y: data.y });
    if (data.type === 'contact') {
        return tryUnlock(() => Phone.openApp('contacts', { newContact: { name: data.name, number: data.number } }));
    }
    if (Apps.byId[n.app]) tryUnlock(() => Phone.openApp(n.app, data));
}

function vibrate() {
    const w = wrapEl();
    w.classList.remove('vibrate');
    void w.offsetWidth;
    w.classList.add('vibrate');
    setTimeout(() => w.classList.remove('vibrate'), 800);
}
Phone.vibrate = vibrate;

/* ---------------------------------------------------------------------
   control center + notification center
   --------------------------------------------------------------------- */

function closeOverlays() {
    let closed = false;
    ['#control-center', '#notif-center'].forEach((s) => {
        const n = $(s);
        if (n.classList.contains('open')) { n.classList.remove('open'); closed = true; }
    });
    if (closed) updateChrome();
    return closed;
}

const BT_SVG = '<svg viewBox="0 0 24 24"><path d="M7 7l10 10-5 5V2l5 5L7 17" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const CELL_SVG = '<svg viewBox="0 0 24 24"><path d="M12 9v12M12 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM7.5 3.5a7 7 0 0 0 0 7M16.5 3.5a7 7 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round"/></svg>';

function renderControlCenter() {
    const s = Phone.settings;
    const cc = $('#control-center');
    cc.innerHTML = `
        <div class="cc-carrier" id="cc-carrier"></div>
        <div class="cc-grid">
            <div class="cc-tile cc-conn">
                <button class="cc-tile round ${s.airplane ? 'on orange' : ''}" data-cc="airplane"><i class="fa-solid fa-plane"></i></button>
                <button class="cc-tile round ${!s.airplane && !(typeof Network !== 'undefined' && Network.noSignal()) ? 'on green' : ''}" data-cc="cellular">${CELL_SVG}</button>
                <button class="cc-tile round ${!s.airplane && (typeof Network === 'undefined' || !Network.active || Network.wifi) ? 'on blue' : ''}" data-cc="wifi"><i class="fa-solid fa-wifi"></i></button>
                <button class="cc-tile round ${s.bluetooth !== false ? 'on blue' : ''}" data-cc="bluetooth">${BT_SVG}</button>
            </div>
            ${(() => {
                const t = typeof Music !== 'undefined' && Music.track;
                return `<div class="cc-tile cc-media ${t ? 'has-track' : ''}" data-cc="media">
                    <div class="m-head">${t ? `<span class="m-art" style="background:${artBg(t)}"></span>` : ''}<div class="grow"><div class="m-title">${esc(t ? t.title || 'Untitled' : I18N.t('Not Playing'))}</div><div class="m-sub">${esc(t ? t.artist || musicAppName(Music.app) : I18N.t('Music'))}</div></div></div>
                    <div class="m-ctrl"><button data-cc="mprev"><i class="fa-solid fa-backward"></i></button><button data-cc="mtoggle"><i class="fa-solid ${t && Music.playing ? 'fa-pause' : 'fa-play'}"></i></button><button data-cc="mnext"><i class="fa-solid fa-forward"></i></button></div>
                </div>`;
            })()}
            <button class="cc-tile ${s.silent ? 'on' : ''}" data-cc="silent"><i class="fa-solid ${s.silent ? 'fa-bell-slash' : 'fa-bell'}"></i></button>
            <button class="cc-tile ${s.rotationLock ? 'on' : ''}" data-cc="rotation"><i class="fa-solid fa-arrows-rotate"></i></button>
            <div class="cc-slider" data-slider="brightness"><div class="fill" style="height:${(s.brightness ?? 1) * 100}%"></div><i class="fa-solid fa-sun"></i></div>
            <div class="cc-slider" data-slider="volume"><div class="fill" style="height:${(s.volume ?? 0.7) * 100}%"></div><i class="fa-solid ${typeof Buds !== 'undefined' && Buds.connected ? 'fa-headphones' : 'fa-volume-high'}"></i></div>
            <button class="cc-tile cc-wide ${s.dnd ? 'on' : ''}" data-cc="dnd"><i class="fa-solid fa-moon"></i>${s.dnd ? 'Do Not Disturb' : 'Focus'}</button>
            <button class="cc-tile ${Phone.flashlight ? 'on' : ''}" data-cc="flashlight"><svg viewBox="0 0 24 24"><path d="M8 2h8a1 1 0 0 1 1 1v3.2a3 3 0 0 1-.6 1.8L15 10v11a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1V10L7.6 8A3 3 0 0 1 7 6.2V3a1 1 0 0 1 1-1zm0 2.5h8M12 13v2.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
            <button class="cc-tile" data-cc="timer"><i class="fa-solid fa-stopwatch"></i></button>
            <button class="cc-tile" data-cc="calculator"><i class="fa-solid fa-calculator"></i></button>
            <button class="cc-tile" data-cc="camera"><i class="fa-solid fa-camera"></i></button>
            ${typeof Buds !== 'undefined' ? Buds.ccTile() : ''}
        </div>`;
    if (typeof CarrierState !== 'undefined') CarrierState.apply();
}

function toggleControlCenter(force) {
    const cc = $('#control-center');
    const open = force ?? !cc.classList.contains('open');
    if (open) { $('#notif-center').classList.remove('open'); renderControlCenter(); clearBanners(); }
    cc.classList.toggle('open', open);
    updateChrome();
}

function toggleNotifCenter(force) {
    const nc = $('#notif-center');
    const open = force ?? !nc.classList.contains('open');
    if (open) {
        $('#control-center').classList.remove('open');
        clearBanners();
        nc.innerHTML = `<div class="nc-time"></div><div class="nc-date">${new Date().toLocaleDateString(Phone.locale, { weekday: 'long', month: 'long', day: 'numeric' })}</div><div class="nc-list scroll"></div>`;
        renderNotifLists();
        tick(true);
    }
    nc.classList.toggle('open', open);
    updateChrome();
}

function setupOverlays() {
    // status bar: swipe down / tap handled in js/gestures.js

    const cc = $('#control-center');
    cc.addEventListener('click', (e) => {
        const t = e.target.closest('[data-cc]');
        if (!t) { if (!e.target.closest('.cc-tile, .cc-slider')) toggleControlCenter(false); return; }
        const s = Phone.settings;
        switch (t.dataset.cc) {
            case 'airplane': Phone.saveSetting('airplane', !s.airplane); break;
            case 'cellular': case 'wifi': Phone.saveSetting('airplane', !s.airplane); break;
            case 'bluetooth': Phone.saveSetting('bluetooth', s.bluetooth === false); nui('budsSet', { bluetooth: Phone.settings.bluetooth }); break;
            case 'budsmode': if (typeof Buds !== 'undefined') Buds.cycleMode(); break;
            case 'silent': toggleSilent(); break;
            case 'rotation': Phone.settings.rotationLock = !s.rotationLock; break;
            case 'dnd': Phone.saveSetting('dnd', !s.dnd); break;
            case 'flashlight': setFlashlight(!Phone.flashlight); break;
            case 'timer': toggleControlCenter(false); Phone.openApp('clock', { tab: 'timer' }); return;
            case 'calculator': toggleControlCenter(false); Phone.openApp('calculator'); return;
            case 'camera': toggleControlCenter(false); Phone.openApp('camera', { fromLock: Phone.locked }); return;
            case 'mprev': if (Music.track) Music.prev(); break;
            case 'mnext': if (Music.track) Music.next(); break;
            case 'mtoggle': if (Music.track) Music.toggle(); break;
            case 'media': if (Music.track && Music.app) { toggleControlCenter(false); Phone.openApp(Music.app, { nowPlaying: true }); } return;
        }
        renderControlCenter();
    });
    drag(cc, {
        onStart: (e) => {
            const sl = e.target.closest('[data-slider]');
            cc._slider = sl;
            if (sl) setSlider(sl, e.clientY);
            return true;
        },
        onMove: (_dx, _dy, e) => { if (cc._slider) setSlider(cc._slider, e.clientY); },
        onEnd: (_dx, dy, _vy, _vx, _e, moved) => {
            if (cc._slider) {
                const key = cc._slider.dataset.slider;
                Phone.saveSetting(key, Phone.settings[key]);
                cc._slider = null;
            } else if (moved && dy < -60) toggleControlCenter(false);
        },
    });

    const nc = $('#notif-center');
    nc.addEventListener('click', (e) => {
        if (e.target.closest('.nc-clear')) { Phone.notifications = []; renderNotifLists(); return; }
        const n = e.target.closest('.notif');
        if (n) { toggleNotifCenter(false); openNotification(Phone.notifications.find((x) => x.id === n.dataset.id)); return; }
        if (!e.target.closest('.nc-list')) toggleNotifCenter(false);
    });
    drag(nc, { onEnd: (_dx, dy, _vy, _vx, _e, moved) => { if (moved && dy < -60) toggleNotifCenter(false); } });
}

function setSlider(sl, clientY) {
    const r = sl.getBoundingClientRect();
    const v = Math.max(0.05, Math.min(1, 1 - (clientY - r.top) / r.height));
    $('.fill', sl).style.height = v * 100 + '%';
    const key = sl.dataset.slider;
    Phone.settings[key] = Math.round(v * 100) / 100;
    if (key === 'brightness') $('#brightness-dim').style.opacity = String((1 - v) * 0.7);
    if (key === 'volume') Sound.setVolume(v);
}

/* ---------------------------------------------------------------------
   hardware buttons
   --------------------------------------------------------------------- */

function toggleSilent() {
    const on = !Phone.settings.silent;
    Phone.saveSetting('silent', on);
    Island.flash(`
        <div class="isl-left"><i class="fa-solid ${on ? 'fa-bell-slash isl-orange' : 'fa-bell'}"></i></div>
        <div class="isl-right ${on ? 'isl-orange' : ''}">${on ? 'Silent' : 'Ring'}</div>`);
    if (on) vibrate();
}

let volTimer;
function changeVolume(delta) {
    const v = Math.max(0, Math.min(1, Math.round(((Phone.settings.volume ?? 0.7) + delta) * 10) / 10));
    Phone.settings.volume = v;
    Sound.setVolume(v);
    if (typeof Music !== 'undefined') Music.setVolume(v);
    const hud = $('#volume-hud');
    $('.volume-fill', hud).style.height = v * 100 + '%';
    $('i', hud).className = 'fa-solid ' + (typeof Buds !== 'undefined' && Buds.connected ? 'fa-headphones' : v === 0 ? 'fa-volume-xmark' : v < 0.5 ? 'fa-volume-low' : 'fa-volume-high');
    hud.classList.add('show');
    clearTimeout(volTimer);
    volTimer = setTimeout(() => { hud.classList.remove('show'); Phone.saveSetting('volume', v); }, 1200);
}

function setupHardware() {
    $('#phone').addEventListener('click', (e) => {
        const hw = e.target.closest('[data-hw]');
        if (!hw) return;
        if (Phone.needsSetup && hw.dataset.hw === 'camera') return;
        // in the camera the volume buttons and Camera Control take the picture
        if (Phone.cameraShutter && Phone.current && Phone.current.def.id === 'camera' && ['volup', 'voldown', 'camera'].includes(hw.dataset.hw)) {
            Phone.cameraShutter();
            return;
        }
        switch (hw.dataset.hw) {
            case 'action': toggleSilent(); break;
            case 'volup': changeVolume(0.1); break;
            case 'voldown': changeVolume(-0.1); break;
            case 'power':
                Sound.play('lock');
                $('#screen-off').classList.add('on');
                setTimeout(() => { lockPhone(); Phone.close(); }, 250);
                break;
            case 'camera': Phone.openApp('camera', { fromLock: Phone.locked }); break;
        }
    });
}

/* ---------------------------------------------------------------------
   NUI messages
   --------------------------------------------------------------------- */

async function init(data) {
    if (!data) return;
    Phone.profile = data;
    Phone.settings = data.settings || {};
    Phone.config = data.config || Phone.config;
    // a setup finished in this session is never shown again for the same phone,
    // even if stale profile data arrives afterwards
    Phone.needsSetup = data.setupDone === false && !(typeof Setup !== 'undefined' && Setup.completedFor === data.email);
    document.documentElement.style.setProperty('--frame', data.frameColor || '#3c3d3a');
    Object.assign(Phone.badges, data.badges || {});
    I18N.set(Phone.settings.language || 'en');
    applySettings();
    renderHome();
    tick(true);
    if (Phone.needsSetup) Setup.show();
    Phone.emit('init', data);
    nui('getWorld').then((w) => { if (w) { Phone.world = w; updateWeatherWidget(); } });
    // warm the data cache so apps open instantly
    setTimeout(() => prefetch([
        ['getContacts'], ['getConversations'], ['getRecents'], ['getMail', { box: 'inbox' }],
        ['getNotes'], ['getBank'], ['chirpFeed', {}], ['getPhotos'], ['getLiveShares'],
    ]), 400);
}

const handlers = {
    init,
    async reload() {
        const data = await rpc('init');
        if (data) init(data);
    },
    open() {
        clearTimeout(lockTimer);
        lockTimer = null;
        $('#screen-off').classList.remove('on');
        if (Phone.needsSetup) Setup.show();
        else if (Phone.locked && !Phone.faceVerified) { $('#ls-lock-icon').className = 'fa-solid fa-lock'; }
        setState('open');
        tick(true);
        if (!Phone.needsSetup) setTimeout(autoFaceScan, 180);
        nui('getWorld').then((w) => {
            if (!w) return;
            const changed = !Phone.world || w.weather !== Phone.world.weather || w.zone !== Phone.world.zone || w.hour !== Phone.world.hour;
            Phone.world = w;
            if (changed) updateWeatherWidget();
        });
        Phone.emit('open');
    },
    close() {
        closeOverlays();
        scheduleAutoLock();
        if (Phone._peekHold) setState('peek'); else setState('hidden');
        Phone.emit('close');
    },
    reset() {
        RpcCache.clear();
        Phone.needsSetup = false;
        closeApp(true, true);
        Phone.closing.forEach((c) => { clearTimeout(c.timer); clearTimeout(c.fade); destroyApp(c.app); });
        Phone.closing.clear();
        Phone.suspended.forEach((a) => destroyApp(a));
        Phone.suspended.clear();
        Phone.recents = [];
        lockPhone();
        Phone.notifications = [];
        Phone.profile = null;
        renderNotifLists();
        setState('hidden');
        Phone.emit('reset');
    },
    notify(n) { Phone.notify(n); },
    battery(d) {
        if (!d) return;
        battery = Math.max(0, Math.min(100, d.level | 0));
        Phone.battery = { level: battery, charging: d.charging || null };
        batteryTick();
    },
    placesUpdated(list) { Phone.config.places = list || []; },
    wallpapersUpdated(list) { Phone.config.wallpapers = list || []; applySettings(); },
    cameraFlash() {
        const f = $('#camera-flash');
        f.classList.remove('on'); void f.offsetWidth; f.classList.add('on');
        Sound.play('shutter');
    },
};

// a call kept the phone unlocked; once it ends with the phone put away, apply Auto-Lock
Phone.on('callFinished', () => { if (Phone.state !== 'open') scheduleAutoLock(); });

// server pushes that change data the apps show
const DIRTY_ON = new Set(['message', 'mail', 'callEnded', 'incomingCall', 'chirpRefresh', 'serviceRequest', 'reload', 'notify']);

// when cached data turned out to be stale, reload whatever page is visible
Phone.on('dataChanged', debounce(() => {
    const cur = Phone.current;
    if (!cur) return;
    $$('.page', cur.win)
        .filter((p) => !p.classList.contains('behind') && !p.classList.contains('leaving') && !p.closest('.tab-host.hidden'))
        .forEach((p) => { const c = p._ctx; if (c && c.opts.onResume) c.opts.onResume(c); });
}, 60));

window.addEventListener('message', (e) => {
    const msg = e.data;
    if (!msg || !msg.action) return;
    if (DIRTY_ON.has(msg.action)) RpcCache.markDirty();
    if (handlers[msg.action]) handlers[msg.action](msg.data);
    Phone.emit(msg.action, msg.data);
});

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        // first Escape leaves the text field (keeps what was typed), the next one puts the phone away
        const f = document.activeElement;
        if (f && f.matches('input, textarea, [contenteditable]')) { f.blur(); return; }
        if (Phone.state === 'open') Phone.close();
    }
});

let focusTimer;
document.addEventListener('focusin', (e) => {
    if (e.target.matches('input, textarea, [contenteditable]')) { clearTimeout(focusTimer); nui('inputFocus', { focused: true }); }
});
document.addEventListener('focusout', (e) => {
    if (e.target.matches('input, textarea, [contenteditable]')) {
        focusTimer = setTimeout(() => nui('inputFocus', { focused: false }), 80);
    }
});

function bootPhone() {
    setupLockscreen();
    setupHome();
    setupHomeIndicator();
    setupOverlays();
    setupHardware();
    screenEl().classList.add('locked');
    renderHome();
    tick();
    batteryTick();
    setInterval(tick, 1000);
    $('.wallpaper').style.background = wallpaperCss();
    layoutPhone();
}
