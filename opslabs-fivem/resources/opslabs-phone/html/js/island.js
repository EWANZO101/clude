'use strict';

/* =====================================================================
   Dynamic Island — Live Activities
   - several activities at once: the highest priority one is shown
     compact (left + right of the camera), the next one as a small
     bubble beside it (split mode)
   - tap opens the activity's app, long-press expands it with controls
   - alerts (incoming call) take over the island
   - flash(): short system animations (silent mode, etc.)
   ===================================================================== */

const Island = {
    acts: new Map(),       // id -> spec
    expandedId: null,
    _flash: null,
    _flashTimer: null,
    _collapseTimer: null,
    _last: '',

    /**
     * spec: {
     *   priority: number,
     *   compact():  { left, right }  html for the two sides
     *   minimal():  html for the split bubble
     *   expanded(): html for the long-press view (buttons use data-isl-act)
     *   alert:      true -> takes over the island with expanded() (incoming call)
     *   onTap(), onAction(act, el)
     * }
     */
    start(id, spec) { this.acts.set(id, { id, priority: 0, ...spec }); this.render(); },
    update(id, patch) { const a = this.acts.get(id); if (!a) return; if (patch) Object.assign(a, patch); this.render(); },
    end(id) {
        if (!this.acts.has(id)) return;
        this.acts.delete(id);
        if (this.expandedId === id) this.expandedId = null;
        this.render();
    },
    has(id) { return this.acts.has(id); },

    /** short system animation, then back to the activities */
    flash(html, ms = 1700, mode = 'medium') {
        clearTimeout(this._flashTimer);
        this._flash = { html, mode };
        this.render(true);
        this._flashTimer = setTimeout(() => { this._flash = null; this.render(true); }, ms);
    },

    expand(id) {
        if (!this.acts.has(id) || !this.acts.get(id).expanded) return;
        this.expandedId = id;
        this.render(true);
        Phone.vibrate && Sound.play('unlock');
        this._armCollapse();
    },
    collapse() {
        if (!this.expandedId) return;
        this.expandedId = null;
        clearTimeout(this._collapseTimer);
        this.render(true);
    },
    _armCollapse() {
        clearTimeout(this._collapseTimer);
        this._collapseTimer = setTimeout(() => this.collapse(), 6000);
    },

    ordered() { return [...this.acts.values()].sort((a, b) => b.priority - a.priority); },

    // compat with the old single-owner API
    set(owner, _mode, html, onClick) { this.start(owner, { priority: 100, compact: () => ({ left: html, right: '' }), onTap: onClick }); },
    clear(owner) { if (owner) this.end(owner); else { this.acts.clear(); this.render(); } },

    render(force) {
        const isl = $('#island'), content = $('#island-content'), bubble = $('#island2');
        if (!isl) return;
        let mode = '', html = '', bubbleHtml = '', primary = null;
        const list = this.ordered();

        if (this._flash) {
            mode = this._flash.mode; html = this._flash.html;
        } else if (list.length) {
            const alert = list.find((a) => a.alert);
            const exp = this.expandedId && this.acts.get(this.expandedId);
            primary = alert || exp || list[0];
            if (alert) { mode = 'expanded'; html = alert.expanded(); }
            else if (exp) { mode = 'large'; html = `<div class="isl-exp">${exp.expanded()}</div>`; }
            else {
                mode = 'compact';
                const c = primary.compact();
                html = `<div class="isl-left">${c.left || ''}</div><div class="isl-right">${c.right || ''}</div>`;
                const second = list.find((a) => a !== primary && a.minimal);
                if (second) bubbleHtml = second.minimal();
                this._second = second || null;
            }
        }
        this._primary = primary;
        const key = mode + '|' + html + '|' + bubbleHtml;
        if (!force && key === this._last) return;
        const modeChanged = !this._last || this._last.split('|')[0] !== mode;
        this._last = key;

        isl.className = 'island' + (mode ? ' ' + mode : '');
        if (content.innerHTML !== html) content.innerHTML = html;
        if (modeChanged && mode) { isl.classList.add('bump'); setTimeout(() => isl.classList.remove('bump'), 500); }

        bubble.classList.toggle('show', !!bubbleHtml);
        if (bubbleHtml && bubble.innerHTML !== bubbleHtml) bubble.innerHTML = bubbleHtml;
        screenEl().classList.toggle('island-split', !!bubbleHtml);
    },

    setup() {
        const isl = $('#island'), bubble = $('#island2');
        let press = null, longFired = false;
        const startPress = (getAct) => (e) => {
            longFired = false;
            clearTimeout(press);
            press = setTimeout(() => {
                const a = getAct();
                if (a && a.expanded && !a.alert) { longFired = true; this.expand(a.id); }
            }, 420);
        };
        const cancel = () => clearTimeout(press);
        isl.addEventListener('pointerdown', startPress(() => this._primary));
        bubble.addEventListener('pointerdown', startPress(() => this._second));
        window.addEventListener('pointerup', cancel);

        isl.addEventListener('click', (e) => {
            if (longFired) { longFired = false; return; }
            const act = e.target.closest('[data-isl-act]');
            const a = this._primary;
            if (act && a && a.onAction) { e.stopPropagation(); this._armCollapse(); return a.onAction(act.dataset.islAct, act); }
            if (this.expandedId) { const t = this.acts.get(this.expandedId); this.collapse(); if (t && t.onTap && !act) t.onTap(); return; }
            if (a && a.onTap) a.onTap();
        });
        bubble.addEventListener('click', () => {
            if (longFired) { longFired = false; return; }
            const a = this._second;
            if (a && a.onTap) a.onTap();
        });
        // tap anywhere else collapses the expanded view
        $('#screen').addEventListener('pointerdown', (e) => {
            if (this.expandedId && !e.target.closest('#island, #island2')) this.collapse();
        }, true);
        // activities with live text (timers, progress) refresh every second
        Phone.on('tick', () => { if (this.acts.size) this.render(); });
    },
};

document.addEventListener('DOMContentLoaded', () => Island.setup());

/* ---------------------------------------------------------------------
   built-in activities: timer, stopwatch, live location, GPS follow
   --------------------------------------------------------------------- */

const islandTimerText = () => {
    const t = ClockState.timer;
    const left = t.running ? Math.max(0, t.end - Date.now()) : t.remaining;
    return fmtDuration(Math.ceil(left / 1000));
};

function syncClockActivities() {
    if (typeof ClockState === 'undefined') return;
    const t = ClockState.timer;
    if (t.running || t.paused) {
        if (!Island.has('timer')) {
            Island.start('timer', {
                priority: 60,
                compact: () => ({ left: '<i class="fa-solid fa-hourglass-half isl-orange"></i>', right: `<span class="isl-orange isl-num">${islandTimerText()}</span>` }),
                minimal: () => '<i class="fa-solid fa-hourglass-half isl-orange"></i>',
                expanded: () => `
                    <div class="isl-row"><i class="fa-solid fa-hourglass-half isl-orange isl-big-icon"></i>
                        <div class="grow"><div class="isl-cap">${esc(I18N.t('Timer'))}</div><div class="isl-huge isl-orange">${islandTimerText()}</div></div>
                        <button class="isl-btn" data-isl-act="pause"><i class="fa-solid ${ClockState.timer.running ? 'fa-pause' : 'fa-play'}"></i></button>
                        <button class="isl-btn red" data-isl-act="cancel"><i class="fa-solid fa-xmark"></i></button></div>`,
                onTap: () => Phone.openApp('clock', { tab: 'timer' }),
                onAction: (act) => {
                    const tt = ClockState.timer;
                    if (act === 'cancel') Object.assign(tt, { running: false, paused: false });
                    if (act === 'pause') {
                        if (tt.running) Object.assign(tt, { running: false, paused: true, remaining: tt.end - Date.now() });
                        else Object.assign(tt, { running: true, paused: false, end: Date.now() + tt.remaining });
                    }
                    syncClockActivities();
                    Island.render(true);
                },
            });
        }
    } else Island.end('timer');

    const sw = ClockState.stopwatch;
    if (sw.running) {
        if (!Island.has('stopwatch')) {
            const text = () => {
                const ms = sw.elapsed + (sw.running ? Date.now() - sw.start : 0);
                return fmtDuration(Math.floor(ms / 1000));
            };
            Island.start('stopwatch', {
                priority: 40,
                compact: () => ({ left: '<i class="fa-solid fa-stopwatch isl-orange"></i>', right: `<span class="isl-orange isl-num">${text()}</span>` }),
                minimal: () => '<i class="fa-solid fa-stopwatch isl-orange"></i>',
                expanded: () => `<div class="isl-row"><i class="fa-solid fa-stopwatch isl-orange isl-big-icon"></i>
                    <div class="grow"><div class="isl-cap">${esc(I18N.t('Stopwatch'))}</div><div class="isl-huge isl-orange">${text()}</div></div>
                    <button class="isl-btn" data-isl-act="stop"><i class="fa-solid fa-pause"></i></button></div>`,
                onTap: () => Phone.openApp('clock', { tab: 'stopwatch' }),
                onAction: (act) => { if (act === 'stop') { sw.elapsed += Date.now() - sw.start; sw.running = false; syncClockActivities(); } },
            });
        }
    } else Island.end('stopwatch');
}
Phone.on('tick', syncClockActivities);

function syncLiveActivities() {
    const out = Object.values(Live.outgoing);
    if (out.length) {
        Island.start('sharing', {
            priority: 20,
            compact: () => ({ left: '<i class="fa-solid fa-location-arrow isl-green"></i>', right: `<span class="isl-green isl-small">${out.length > 1 ? out.length + ' ' : ''}${esc(I18N.t('Sharing'))}</span>` }),
            minimal: () => '<i class="fa-solid fa-location-arrow isl-green"></i>',
            expanded: () => `<div class="isl-row"><i class="fa-solid fa-location-arrow isl-green isl-big-icon"></i>
                <div class="grow"><div class="isl-cap">${esc(I18N.t('Sharing My Location'))}</div><div class="isl-title">${esc(out.map((s) => Contacts.nameFor(s.number) || s.number).join(', '))}</div></div></div>`,
            onTap: () => Phone.openApp('maps'),
        });
    } else Island.end('sharing');

    const f = Live.following && Live.incoming[Live.following];
    if (f) {
        const name = f.name || Contacts.nameFor(f.number) || f.number;
        Island.start('navigation', {
            priority: 30,
            compact: () => ({ left: '<i class="fa-solid fa-route isl-blue"></i>', right: `<span class="isl-blue isl-small">${esc(fmtDist(Live.incoming[Live.following] ? Live.incoming[Live.following].dist : null) || name)}</span>` }),
            minimal: () => '<i class="fa-solid fa-route isl-blue"></i>',
            expanded: () => `<div class="isl-row"><i class="fa-solid fa-route isl-blue isl-big-icon"></i>
                <div class="grow"><div class="isl-cap">${esc(I18N.t('Following'))}</div><div class="isl-title">${esc(name)}</div></div>
                <button class="isl-btn red" data-isl-act="stop"><i class="fa-solid fa-xmark"></i></button></div>`,
            onTap: () => Phone.openApp('maps', { live: f.id }),
            onAction: (act) => { if (act === 'stop') Live.follow(null); },
        });
    } else Island.end('navigation');
}
Phone.on('liveChanged', syncLiveActivities);
