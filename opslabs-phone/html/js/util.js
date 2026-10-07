'use strict';

const IN_GAME = typeof GetParentResourceName === 'function';
const RES = IN_GAME ? GetParentResourceName() : 'opslabs-phone';

/** POST to a client NUI callback. Outside the game, routes to the mock backend. */
async function nui(endpoint, data = {}) {
    if (!IN_GAME) return window.Mock ? Mock.nui(endpoint, data) : null;
    const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = ctrl && setTimeout(() => ctrl.abort(), 15000);
    try {
        const res = await fetch(`https://${RES}/${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data),
            signal: ctrl ? ctrl.signal : undefined,
        });
        const text = await res.text();
        const value = text ? JSON.parse(text) : null;
        // the mobile network refused it (no plan, out of texts/minutes/data, ...)
        if (value && typeof value === 'object' && value.__carrier) {
            if (typeof carrierBlocked === 'function') carrierBlocked(value.__carrier, value.reason);
            nui.lastFailure = 'carrier';
            return null;
        }
        // not part of this server's OPSHUB license (html/js/license.js)
        if (value && typeof value === 'object' && value.__license) {
            if (typeof License !== 'undefined') License.blocked(value.__license);
            nui.lastFailure = 'license';
            return null;
        }
        if (value && typeof value === 'object' && value.__failed) {
            console.warn('[opslabs-phone] request failed:', endpoint, data && data.name, value.__failed);
            nui.lastFailure = value.__failed;
            return null;
        }
        return value;
    } catch (e) {
        console.error('[opslabs-phone] nui error', endpoint, e);
        return null;
    } finally {
        if (timer) clearTimeout(timer);
    }
}

/* ---------------------------------------------------------------------
   rpc + cache
   Reads are served instantly from memory (stale-while-revalidate): the app
   renders the last known data in the same frame, a background refresh runs,
   and if anything changed the visible page reloads itself. Any write, and
   any server push (new message, mail...), marks the cache dirty so the next
   read waits for fresh data instead.
   --------------------------------------------------------------------- */

const READ_RPCS = new Set([
    'getContacts', 'getConversations', 'getMessages', 'getRecents', 'getNotes', 'getPhotos', 'getMail',
    'chirpFeed', 'chirpProfile', 'getBank', 'getVehicles', 'getServiceRequests', 'getLiveShares', 'devStats', 'musicLibrary',
]);

const RpcCache = {
    map: new Map(),
    markDirty() { this.map.forEach((e) => { e.dirty = true; }); },
    clear() { this.map.clear(); },
};

const cloneData = (v) => (v == null ? v : JSON.parse(JSON.stringify(v)));

function rpcFetch(key, name, data) {
    const entry = RpcCache.map.get(key) || {};
    const p = nui('rpc', { name, data }).then((value) => {
        if (value != null) {
            const changed = entry.json !== undefined && entry.json !== JSON.stringify(value);
            RpcCache.map.set(key, { value, json: JSON.stringify(value), at: Date.now(), dirty: false });
            if (changed && window.Phone) Phone.emit('dataChanged', name);
        }
        return value;
    });
    entry.pending = p;
    RpcCache.map.set(key, entry);
    return p;
}

/** Calls a server callback registered with Register() in server/*.lua */
const NEUTRAL_RPCS = new Set(['spotifyApi', 'tidalApi', 'oauthStatus', 'oauthStart']);

function rpc(name, data = {}) {
    if (NEUTRAL_RPCS.has(name)) return nui('rpc', { name, data });
    if (!READ_RPCS.has(name)) {
        RpcCache.markDirty();
        return nui('rpc', { name, data });
    }
    const key = name + '|' + JSON.stringify(data);
    const hit = RpcCache.map.get(key);
    if (hit && hit.json !== undefined && !hit.dirty) {
        if (Date.now() - hit.at > 1500 && !hit.revalidating) {
            hit.revalidating = true;
            rpcFetch(key, name, data).finally(() => { const e = RpcCache.map.get(key); if (e) e.revalidating = false; });
        }
        return Promise.resolve(cloneData(hit.value));
    }
    if (hit && hit.pending && !hit.dirty) return hit.pending.then(cloneData);
    return rpcFetch(key, name, data).then(cloneData);
}

/** warm the cache in the background (called after init) */
function prefetch(list) {
    let i = 0;
    const next = () => {
        if (i >= list.length) return;
        const [name, data] = list[i++];
        rpc(name, data || {}).finally(() => setTimeout(next, 30));
    };
    next();
}

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const ESC_MAP = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC_MAP[c]);
/** a URL that is safe inside url('…') within an html style="" attribute */
const cssUrl = (u) => String(u).replace(/['"()\\\s<>]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0'));
const escUrl = (u) => (/^https?:\/\//i.test(u || '') ? esc(u) : '');

function el(html) {
    const t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function debounce(fn, ms) {
    let t;
    return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
}

function initials(name) {
    const parts = String(name || '').trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return '';
    if (/^[\d\-+ ]+$/.test(name)) return '';
    return ((parts[0][0] || '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase();
}

/** OPS OS style contact avatar */
function avatar(name, url, cls = '') {
    if (url && /^https?:\/\//i.test(url)) {
        return `<div class="avatar ${cls}" style="background-image:url('${esc(url)}')"></div>`;
    }
    const ini = initials(name);
    return `<div class="avatar ${cls}">${ini ? esc(ini) : '<i class="fa-solid fa-user" style="font-size:.85em;opacity:.95;transform:translateY(12%)"></i>'}</div>`;
}

/** oxmysql returns timestamps as epoch ms; strings are handled too. */
function toDate(v) {
    if (v instanceof Date) return v;
    if (typeof v === 'number') return new Date(v);
    if (typeof v === 'string') return new Date(v.includes('T') ? v : v.replace(' ', 'T'));
    return new Date();
}

function fmtTime(d) {
    d = toDate(d);
    return d.toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' });
}

function isSameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** "9:41 AM", "Yesterday", "Tuesday", "3/14/26" — like Messages/Phone lists */
function relTime(v) {
    const d = toDate(v);
    const now = new Date();
    if (isSameDay(d, now)) return fmtTime(d);
    const y = new Date(now); y.setDate(now.getDate() - 1);
    if (isSameDay(d, y)) return 'Yesterday';
    if (now - d < 6 * 86400000) return d.toLocaleDateString(Phone.locale, { weekday: 'long' });
    return fmtDate(d);
}

function shortAgo(v) {
    const s = Math.max(0, (Date.now() - toDate(v).getTime()) / 1000);
    if (s < 60) return 'now';
    if (s < 3600) return Math.floor(s / 60) + 'm';
    if (s < 86400) return Math.floor(s / 3600) + 'h';
    if (s < 604800) return Math.floor(s / 86400) + 'd';
    return toDate(v).toLocaleDateString(Phone.locale, { month: 'short', day: 'numeric' });
}

function fmtMoney(n, cents = false) {
    return '$' + Number(n || 0).toLocaleString(Phone.locale, { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: cents ? 2 : 0 });
}

function fmtDuration(sec) {
    sec = Math.max(0, Math.floor(sec));
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    const mm = h ? String(m).padStart(2, '0') : String(m);
    return (h ? h + ':' : '') + mm + ':' + String(s).padStart(2, '0');
}

/**
 * Mouse/pointer drag helper.
 * opts: { onStart(e) -> bool, onMove(dx, dy, e), onEnd(dx, dy, velocityY, velocityX, e), threshold }
 */
function drag(target, opts) {
    target.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        if (opts.onStart && opts.onStart(e) === false) return;
        const sx = e.clientX, sy = e.clientY;
        let lx = sx, ly = sy, lt = performance.now(), vx = 0, vy = 0, moved = false;
        const scale = Phone.scale || 1;
        const move = (ev) => {
            const now = performance.now();
            const dt = Math.max(1, now - lt);
            vx = (ev.clientX - lx) / dt / scale;
            vy = (ev.clientY - ly) / dt / scale;
            lx = ev.clientX; ly = ev.clientY; lt = now;
            const dx = (ev.clientX - sx) / scale, dy = (ev.clientY - sy) / scale;
            if (!moved && Math.hypot(dx, dy) < (opts.threshold ?? 6)) return;
            moved = true;
            opts.onMove && opts.onMove(dx, dy, ev);
        };
        const up = (ev) => {
            window.removeEventListener('pointermove', move);
            window.removeEventListener('pointerup', up);
            const dx = (ev.clientX - sx) / scale, dy = (ev.clientY - sy) / scale;
            opts.onEnd && opts.onEnd(dx, dy, vy, vx, ev, moved);
        };
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', up);
    });
}

/** Seeded pseudo-random for stable fake data (weather forecast, etc.) */
function seeded(seed) {
    let s = seed >>> 0;
    return () => {
        s = (s + 0x6d2b79f5) >>> 0;
        let t = s;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
