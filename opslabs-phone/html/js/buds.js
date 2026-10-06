'use strict';

/* =====================================================================
   OPS Buds — wireless earbuds (client/buds.lua does the game side)
   - "Connect" card the first time the case is opened, battery card after
   - Dynamic Island: connected (battery ring), Noise Control changes
   - Settings → Bluetooth → OPS Buds: batteries, Noise Control,
     Conversation Awareness, Automatic Ear Detection, rename, forget
   - Control Center: Noise Control tile, headphones on the volume slider
   - audio: ear detection / losing the connection pauses music, talking
     lowers it (Conversation Awareness), the press control plays / pauses,
     answers and hangs up calls
   ===================================================================== */

const BUDS_ICON = `<svg class="buds-ico" viewBox="0 0 32 32" fill="currentColor"><path d="M9.5 5.5a5 5 0 0 1 5 5c0 1.6-.8 2.9-1.9 3.8v11.2a1.6 1.6 0 0 1-3.2 0V15.4a5 5 0 0 1 .1-9.9z"/><path d="M22.5 5.5a5 5 0 0 0-5 5c0 1.6.8 2.9 1.9 3.8v11.2a1.6 1.6 0 0 0 3.2 0V15.4a5 5 0 0 0-.1-9.9z"/></svg>`;

const BUDS_MODES = {
    anc: { label: 'Noise Cancellation', icon: 'fa-solid fa-circle-half-stroke', desc: 'Blocks out the world around you.' },
    adaptive: { label: 'Adaptive', icon: 'fa-solid fa-wand-magic-sparkles', desc: 'Cancels noise, but lets loud sounds like gunfire and explosions through.' },
    transparency: { label: 'Transparency', icon: 'fa-solid fa-ear-listen', desc: 'Hear everything around you.' },
    off: { label: 'Off', icon: 'fa-solid fa-circle', desc: 'Noise Control is off.' },
};

const Buds = {
    s: { owned: false, worn: false, connected: false, paired: false, l: 100, r: 100, c: 100, mode: 'anc', earDetect: true, convAware: true, label: 'OPS Buds' },
    _resumeOnIn: 0,
    _ducked: false,

    get connected() { return !!this.s.connected; },

    /** "Ewan's OPS Buds" unless renamed */
    name() {
        const set = (Phone.settings.buds || {}).name;
        if (set) return set;
        const first = ((Phone.profile && Phone.profile.name) || '').split(' ')[0];
        return first ? `${first}'s ${this.s.label}` : this.s.label;
    },

    settings() { return Object.assign({ paired: false, mode: 'anc', earDetect: true, convAware: true }, Phone.settings.buds || {}); },

    /** save to the phone settings (server) and tell the game */
    save(patch) {
        const next = Object.assign(this.settings(), patch);
        Phone.saveSetting('buds', next);
        Object.assign(this.s, patch);
        nui('budsSet', patch);
        this.refresh();
    },

    ring(pct, size = 34, charging = false) {
        const r = size / 2 - 3, c = 2 * Math.PI * r, v = Math.max(0, Math.min(100, pct | 0));
        const col = v <= 10 ? '#ff453a' : v <= 20 ? '#ff9f0a' : '#32d74b';
        return `<svg class="buds-ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
            <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(120,120,128,.32)" stroke-width="3"/>
            <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${col}" stroke-width="3" stroke-linecap="round"
                stroke-dasharray="${(c * v) / 100} ${c}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
            ${charging ? `<text x="50%" y="56%" text-anchor="middle" dominant-baseline="middle" font-size="${size * 0.36}" fill="${col}">⚡</text>` : ''}
        </svg>`;
    },

    budsPct() { return Math.round(Math.min(this.s.l, this.s.r)); },

    /** the game sent a new state */
    update(d) {
        if (!d) return;
        const was = this.s.connected;
        Object.assign(this.s, d);
        if (d.event === 'connected' && !was) this.onConnected();
        if (d.event === 'disconnected' && was) this.onDisconnected(d);
        if (d.event === 'mode') {
            Phone.saveSetting('buds', Object.assign(this.settings(), { mode: d.mode }));
            this.flashMode();
        }
        // the battery card is up: keep its numbers live
        const card = $('#buds-card');
        if (card && card.classList.contains('show') && !$('[data-bc="connect"]', card) && d.event !== 'connected') {
            $$('.bc-batt b', card).forEach((b, i) => { b.textContent = [this.s.l, this.s.r, this.s.c][i] + '%'; });
        }
        this.refresh();
    },

    onConnected() {
        Sound.play('unlock');
        Island.flash(`
            <div class="isl-left buds-isl">${BUDS_ICON}<span data-no-i18n>${esc(this.s.label)}</span></div>
            <div class="isl-right buds-isl-batt">${this.ring(this.budsPct(), 26)}<span>${this.budsPct()}%</span></div>`, 3200, 'medium');
        if (Phone.state !== 'open') Phone.peek(3400);
        // Automatic Ear Detection: back in the ears within a minute → carry on playing
        if (this._resumeOnIn && Date.now() - this._resumeOnIn < 60000 && typeof Music !== 'undefined' && Music.track && !Music.playing) Music.resume();
        this._resumeOnIn = 0;
    },

    onDisconnected(d) {
        if (typeof Music === 'undefined' || !Music.playing) return;
        if (!d.worn) {
            // taken out of the ears: pause only with Automatic Ear Detection (otherwise it goes to the speaker)
            if (this.settings().earDetect) { Music.pause(); this._resumeOnIn = Date.now(); }
        } else {
            // out of range / flat / Bluetooth off: the audio route went away
            Music.pause();
        }
        this.duck(false);
    },

    flashMode() {
        const m = BUDS_MODES[this.s.mode] || BUDS_MODES.anc;
        Island.flash(`
            <div class="isl-left buds-isl"><i class="${m.icon}"></i></div>
            <div class="isl-right">${esc(I18N.t(m.label))}</div>`, 1800, 'medium');
        if (Phone.state !== 'open') Phone.peek(2000);
    },

    cycleMode() {
        const order = ['anc', 'adaptive', 'transparency'];
        const next = order[(order.indexOf(this.s.mode) + 1) % order.length];
        this.save({ mode: next });
        this.flashMode();
    },

    /** Conversation Awareness: talking lowers the music */
    duck(on) {
        if (this._ducked === on || typeof Music === 'undefined') return;
        this._ducked = on;
        const v = Music.volume() * (on ? 0.25 : 1);
        if (Music.audio) Music.audio.volume = v;
        if (Music.yt && Music.yt.setVolume) Music.yt.setVolume(Math.round(v * 100));
    },

    /** the press control on the buds */
    press(taps) {
        if (!this.s.connected) return;
        if (typeof Call !== 'undefined' && Call.cur) {
            if (Call.cur.dir === 'in' && Call.cur.status === 'ringing') Call.answer();
            else Call.hangup();
            return;
        }
        if (typeof Music === 'undefined' || !Music.track) return;
        if (taps >= 3) Music.prev();
        else if (taps === 2) Music.next();
        else Music.toggle();
    },

    /* ------------------------------------------------------------------ card */
    card(d) {
        let host = $('#buds-card');
        if (d.stage === 'close') { if (host) host.classList.remove('show'); return; }
        if (!host) {
            host = el('<div class="buds-card" id="buds-card"></div>');
            screenEl().appendChild(host);
            host.addEventListener('click', (e) => {
                const a = e.target.closest('[data-bc]');
                if (!a) return;
                if (a.dataset.bc === 'connect') {
                    this.save({ paired: true });
                    nui('budsPair');
                    this.card({ stage: 'battery' });
                    setTimeout(() => this.card({ stage: 'close' }), 4500);
                }
                if (a.dataset.bc === 'close') { host.classList.remove('show'); nui('budsCardClosed'); }
            });
        }
        const pair = d.stage === 'pair';
        const label = d.label || this.s.label;
        host.innerHTML = `
            <div class="bc-sheet">
                <button class="bc-x" data-bc="close"><i class="fa-solid fa-xmark"></i></button>
                <div class="bc-title" data-no-i18n>${esc(pair ? label : this.name())}</div>
                ${pair ? `<div class="bc-sub">${esc(I18N.t('Not Connected'))}</div>` : ''}
                <img class="bc-img" src="img/opsbuds.png" alt="">
                ${pair ? `<button class="bc-btn" data-bc="connect">${esc(I18N.t('Connect'))}</button>` : `
                <div class="bc-batt">
                    <div>${this.ring(d.l ?? this.s.l, 52)}<b>${d.l ?? this.s.l}%</b><span>L</span></div>
                    <div>${this.ring(d.r ?? this.s.r, 52)}<b>${d.r ?? this.s.r}%</b><span>R</span></div>
                    <div>${this.ring(d.c ?? this.s.c, 52, this.s.caseCharging)}<b>${d.c ?? this.s.c}%</b><span>${esc(I18N.t('Case'))}</span></div>
                </div>`}
            </div>`;
        requestAnimationFrame(() => host.classList.add('show'));
        if (!pair) {
            clearTimeout(this._cardTimer);
            this._cardTimer = setTimeout(() => host.classList.remove('show'), 5000);
        }
    },

    /* ------------------------------------------------------------------ UI bits other screens use */
    settingsRow() {
        if (!this.settings().paired) return '';
        return `<div class="group"><div class="row tap has-icon" data-s="buds">
            <span class="ri buds-ri">${BUDS_ICON}</span>
            <div class="grow" data-no-i18n>${esc(this.name())}</div>
            <span class="value">${this.s.connected ? `${this.budsPct()}%` : esc(I18N.t('Not Connected'))}</span><i class="fa-solid fa-chevron-right chev"></i></div></div>`;
    },

    ccTile() {
        if (!this.s.connected) return '';
        const m = BUDS_MODES[this.s.mode] || BUDS_MODES.anc;
        return `<button class="cc-tile ${this.s.mode !== 'off' && this.s.mode !== 'transparency' ? 'on' : ''}" data-cc="budsmode" title="${esc(m.label)}"><i class="${m.icon}"></i></button>`;
    },

    /** redraw whatever shows buds state */
    refresh() {
        if ($('#control-center').classList.contains('open') && typeof renderControlCenter === 'function') renderControlCenter();
        const cur = Phone.current;
        if (cur && cur.def.id === 'settings') Phone.emit('dataChanged');
    },
};

/* ---------------------------------------------------------------------- Settings → Bluetooth / OPS Buds */
SETTINGS_ICONS.buds = ['#8e8e93', 'fa-headphones'];

Object.assign(SettingsPages, {
    bluetooth(nav) {
        nav.push({
            title: 'Bluetooth', grouped: true, backLabel: 'Settings',
            render(c, ctx) {
                const draw = () => {
                    const on = Phone.settings.bluetooth !== false;
                    const st = Buds.settings();
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px"><div class="row"><div class="grow">Bluetooth</div>${UI.switchHtml(on, 'data-toggle="bt"')}</div></div>
                        <div class="group-footer">${esc(I18N.t('This phone is discoverable as "OPS Phone" while Bluetooth settings is open.'))}</div>
                        ${on ? `
                        <div class="group-header">${esc(I18N.t('My Devices'))}</div>
                        <div class="group">
                            ${st.paired ? `<div class="row tap" data-p="buds"><div class="grow" data-no-i18n>${esc(Buds.name())}</div>
                                <span class="value">${esc(I18N.t(Buds.s.connected ? 'Connected' : 'Not Connected'))}</span><i class="fa-solid fa-circle-info buds-info"></i></div>`
                                : `<div class="row"><div class="grow muted">${esc(I18N.t('No devices'))}</div></div>`}
                        </div>
                        ${!st.paired ? `<div class="group-footer">${esc(I18N.t('To connect OPS Buds, open the case next to your phone (use the item).'))}</div>` : ''}` : ''}`;
                };
                draw();
                c.addEventListener('change', (e) => {
                    if (e.target.dataset.toggle !== 'bt') return;
                    Phone.saveSetting('bluetooth', e.target.checked);
                    nui('budsSet', { bluetooth: e.target.checked });
                    draw();
                });
                c.addEventListener('click', (e) => { if (e.target.closest('[data-p="buds"]')) SettingsPages.buds(nav); });
                ctx.opts.onResume = draw;
            },
        });
    },

    buds(nav) {
        nav.push({
            title: '', grouped: true, backLabel: 'Back',
            render(c, ctx) {
                const draw = () => {
                    const s = Buds.s, st = Buds.settings();
                    if (!st.paired) { c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row"><div class="grow muted">${esc(I18N.t('Not Connected'))}</div></div></div>`; return; }
                    c.innerHTML = `
                        <div class="buds-hero">
                            <img src="img/opsbuds.png" alt="">
                            <div class="bh-name" data-no-i18n>${esc(Buds.name())}</div>
                            <div class="bh-state">${esc(I18N.t(s.connected ? 'Connected' : s.worn ? 'Not Connected' : 'In Case'))}</div>
                            <div class="bc-batt">
                                <div>${Buds.ring(s.l, 44)}<b>${s.l}%</b><span>L</span></div>
                                <div>${Buds.ring(s.r, 44)}<b>${s.r}%</b><span>R</span></div>
                                <div>${Buds.ring(s.c, 44, s.caseCharging)}<b>${s.c}%</b><span>${esc(I18N.t('Case'))}</span></div>
                            </div>
                        </div>
                        <div class="group-header">${esc(I18N.t('Noise Control'))}</div>
                        <div class="group buds-modes">
                            ${['anc', 'adaptive', 'transparency', 'off'].map((k) => `<div class="row tap" data-mode="${k}">
                                <i class="${BUDS_MODES[k].icon} bm-ico"></i><div class="grow">${esc(I18N.t(BUDS_MODES[k].label))}</div>
                                ${st.mode === k ? '<i class="fa-solid fa-check" style="color:var(--blue)"></i>' : ''}</div>`).join('')}
                        </div>
                        <div class="group-footer">${esc(I18N.t((BUDS_MODES[st.mode] || BUDS_MODES.anc).desc))} ${esc(I18N.t('Press and hold the buds control to switch.'))}</div>
                        <div class="group">
                            <div class="row"><div class="grow">${esc(I18N.t('Conversation Awareness'))}</div>${UI.switchHtml(st.convAware, 'data-toggle="convAware"')}</div>
                        </div>
                        <div class="group-footer">${esc(I18N.t('Lowers your music and lets the world in while you talk.'))}</div>
                        <div class="group-header">${esc(I18N.t('Press Control'))}</div>
                        <div class="group">
                            <div class="row"><div class="grow">${esc(I18N.t('Press'))}</div><span class="value">${esc(I18N.t('Play / Pause · Answer'))}</span></div>
                            <div class="row"><div class="grow">${esc(I18N.t('Press twice'))}</div><span class="value">${esc(I18N.t('Next Track'))}</span></div>
                            <div class="row"><div class="grow">${esc(I18N.t('Press three times'))}</div><span class="value">${esc(I18N.t('Previous Track'))}</span></div>
                            <div class="row"><div class="grow">${esc(I18N.t('Press and hold'))}</div><span class="value">${esc(I18N.t('Noise Control'))}</span></div>
                        </div>
                        <div class="group-footer">${esc(I18N.t('Change the key in Settings → Key Bindings → FiveM → "OPS Buds".'))}</div>
                        <div class="group">
                            <div class="row"><div class="grow">${esc(I18N.t('Automatic Ear Detection'))}</div>${UI.switchHtml(st.earDetect, 'data-toggle="earDetect"')}</div>
                        </div>
                        <div class="group-footer">${esc(I18N.t('Taking your buds out pauses what is playing; putting them back in carries on.'))}</div>
                        <div class="group">
                            <div class="row tap" data-act="rename"><div class="grow">${esc(I18N.t('Name'))}</div><span class="value" data-no-i18n>${esc(Buds.name())}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row"><div class="grow">${esc(I18N.t('Model Name'))}</div><span class="value" data-no-i18n>${esc(s.label)}</span></div>
                        </div>
                        <div class="group"><div class="row tap" data-act="forget"><div class="grow" style="color:var(--red)">${esc(I18N.t('Forget This Device'))}</div></div></div>`;
                };
                draw();
                c.addEventListener('click', async (e) => {
                    const m = e.target.closest('[data-mode]');
                    if (m) { Buds.save({ mode: m.dataset.mode }); if (Buds.s.connected) Buds.flashMode(); draw(); return; }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'rename') {
                        const v = await UI.prompt(I18N.t('Name'), '', { value: Buds.name() });
                        if (v === null) return;
                        Buds.save({ name: v.trim().slice(0, 32) || null });
                        draw();
                    }
                    if (a.dataset.act === 'forget') {
                        if (!(await UI.confirm(I18N.t('Forget This Device'), I18N.t('Your OPS Buds will disconnect. Open the case next to your phone to connect them again.'), I18N.t('Forget Device'), true))) return;
                        Buds.save({ paired: false, name: null });
                        nav.pop && nav.pop();
                    }
                });
                c.addEventListener('change', (e) => {
                    const k = e.target.dataset.toggle;
                    if (k === 'convAware' || k === 'earDetect') Buds.save({ [k]: e.target.checked });
                });
                ctx.opts.onResume = draw;
            },
        });
    },
});

/* ---------------------------------------------------------------------- wiring */
Phone.on('buds', (d) => Buds.update(d));
Phone.on('budsCard', (d) => Buds.card(d || {}));
Phone.on('budsPress', (d) => Buds.press((d && d.taps) || 1));
Phone.on('budsDuck', (d) => Buds.duck(!!(d && d.on)));
Phone.on('init', () => { Buds.s.mode = Buds.settings().mode; });
let budsPlaying = null;
Phone.on('music', () => {
    const p = typeof Music !== 'undefined' && Music.playing;
    if (p !== budsPlaying) { budsPlaying = p; nui('budsAudio', { playing: p }); }
});
