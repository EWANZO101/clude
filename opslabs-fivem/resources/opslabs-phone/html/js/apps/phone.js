'use strict';

/* =====================================================================
   Calls (global) — call screen, island live activity, ringtone
   ===================================================================== */

const Call = {
    cur: null,      // { id, number, name, dir: 'in'|'out', status: 'ringing'|'active'|'ended', startedAt }
    timer: null,
    dtmf: '',

    screen: () => $('#call-screen'),
    visible() { return this.screen().classList.contains('show'); },

    displayName(c = this.cur) { return (c && (c.name || Contacts.nameFor(c.number))) || (c && c.number) || ''; },

    async start(number, name) {
        number = String(number || '').trim();
        if (!number) return;
        if (this.cur) return UI.toast('Already in a call', 'fa-solid fa-phone');
        if (Phone.settings.airplane) {
            return UI.alert({ title: 'Turn Off Airplane Mode to Make a Call' });
        }
        this.cur = { id: null, number, name, dir: 'out', status: 'ringing' };
        Phone.inCall = true;
        this.show();
        Sound.ringback();
        nui('callState', { active: true });

        const res = await rpc('startCall', { number });
        if (!res || res.error) {
            Sound.stopRing();
            if (res && res.error === 'service') {
                this.cur.status = 'ended';
                this.render('Request sent to ' + res.label);
                Phone.notify({ app: 'services', title: res.label, body: 'Your request was sent with your location.' });
            } else {
                this.cur.status = 'ended';
                this.render(res && res.error === 'busy' ? 'Busy' : 'Call Failed');
            }
            setTimeout(() => this.finish(), 1600);
            return;
        }
        this.cur.id = res.id;
        if (res.contact && res.contact.name) this.cur.name = res.contact.name;
        this.render();
    },

    incoming(data) {
        if (this.cur) return;
        this.cur = { id: data.id, number: data.number, name: data.name, dir: 'in', status: 'ringing' };
        Phone.inCall = true;
        if (!Sound.ring(Phone.settings.ringtone || 'reflection')) {
            this.vibrateLoop = setInterval(() => Phone.vibrate(), 1600);
            Phone.vibrate();
        }
        this.show();
        // expanded island only while the phone peeks up from the bottom
        if (Phone.state !== 'open') { Phone.peek(0); this.island(); }
    },

    async answer() {
        if (!this.cur || this.cur.dir !== 'in' || this.cur.status !== 'ringing') return;
        this.stopAlerts();
        await rpc('answerCall', { id: this.cur.id });
    },

    async hangup() {
        if (!this.cur) return;
        this.stopAlerts();
        if (this.cur.id) await rpc('endCall', { id: this.cur.id });
        else this.finish();
    },

    accepted() {
        if (!this.cur) return;
        this.cur.status = 'active';
        this.cur.startedAt = Date.now();
        Sound.stopRing();
        this.stopAlerts();
        clearInterval(this.timer);
        this.timer = setInterval(() => this.updateTimer(), 1000);
        this.render();
        this.island();
    },

    ended(data) {
        if (!this.cur || (data && this.cur.id && data.id !== this.cur.id)) return;
        this.stopAlerts();
        Sound.stopRing();
        Sound.play('end');
        this.cur.status = 'ended';
        this.render('Call Ended');
        setTimeout(() => this.finish(), 1200);
    },

    finish() {
        clearInterval(this.timer);
        this.stopAlerts();
        Sound.stopRing();
        this.cur = null;
        Phone.inCall = false;
        this.screen().classList.remove('show', 'keypad');
        Island.clear('call');
        Phone.unpeek();
        nui('callState', { active: false });
        Phone.updateChrome();
        Phone.emit('callFinished');
    },

    stopAlerts() {
        clearInterval(this.vibrateLoop);
        this.vibrateLoop = null;
        if (this.cur && this.cur.dir === 'in') Sound.stopRing();
    },

    show() {
        this.dtmf = '';
        this.render();
        this.screen().classList.add('show');
        Island.clear('call');
        Phone.updateChrome();
    },

    /** hide the call screen but keep the call alive in the island */
    minimize() {
        if (!this.visible() || !this.cur || this.cur.status === 'ended') return false;
        if (this.cur.dir === 'in' && this.cur.status === 'ringing') return false;
        this.screen().classList.remove('show', 'keypad');
        this.island();
        Phone.updateChrome();
        return true;
    },

    island() {
        const c = this.cur;
        if (!c) return;
        const name = () => this.displayName();
        const timer = () => (this.cur && this.cur.status === 'active' ? fmtDuration((Date.now() - this.cur.startedAt) / 1000) : '');
        if (c.dir === 'in' && c.status === 'ringing') {
            Island.start('call', {
                priority: 100,
                alert: true,
                expanded: () => `
                    <div class="isl-call">
                        ${avatar(name(), null)}
                        <div class="isl-info"><div class="isl-sub">mobile</div><div class="isl-name">${esc(name())}</div></div>
                        <button class="round decline" data-isl-act="decline"><i class="fa-solid fa-phone"></i></button>
                        <button class="round accept" data-isl-act="accept"><i class="fa-solid fa-phone"></i></button>
                    </div>`,
                compact: () => ({ left: '<i class="fa-solid fa-phone isl-green"></i>', right: '' }),
                onTap: () => this.show(),
                onAction: (act) => (act === 'accept' ? this.answer() : this.hangup()),
            });
            return;
        }
        if (this.visible()) { Island.end('call'); return; }
        Island.start('call', {
            priority: 100,
            compact: () => ({ left: `<i class="fa-solid fa-phone isl-green"></i><span class="isl-green isl-num">${timer()}</span>`, right: '<span class="isl-wave"><i></i><i></i><i></i><i></i></span>' }),
            minimal: () => '<i class="fa-solid fa-phone isl-green"></i>',
            expanded: () => `
                <div class="isl-row">
                    ${avatar(name(), null)}
                    <div class="grow"><div class="isl-cap">${esc(I18N.t('mobile'))}</div><div class="isl-title">${esc(name())}</div><div class="isl-cap isl-green">${timer()}</div></div>
                    <button class="isl-btn" data-isl-act="open"><i class="fa-solid fa-grip"></i></button>
                    <button class="isl-btn red" data-isl-act="end"><i class="fa-solid fa-phone" style="transform:rotate(135deg)"></i></button>
                </div>`,
            onTap: () => this.show(),
            onAction: (act) => { if (act === 'end') this.hangup(); if (act === 'open') { Island.collapse(); this.show(); } },
        });
    },

    updateTimer() {
        if (!this.cur || this.cur.status !== 'active') return;
        const t = fmtDuration((Date.now() - this.cur.startedAt) / 1000);
        const st = $('.cs-status', this.screen());
        if (st && !this.screen().classList.contains('keypad')) st.textContent = t;
        const it = $('.isl-timer'); if (it) it.textContent = t;
    },

    render(statusOverride) {
        const c = this.cur;
        if (!c) return;
        const scr = this.screen();
        const name = this.displayName();
        let status = statusOverride;
        if (!status) {
            if (c.status === 'active') status = fmtDuration((Date.now() - c.startedAt) / 1000);
            else if (c.dir === 'out') status = 'calling…';
            else status = 'mobile';
        }
        const incoming = c.dir === 'in' && c.status === 'ringing';
        const btn = (k, icon, label, disabled) => `<button class="cs-btn ${disabled ? 'disabled' : ''}" data-cs="${k}"><span class="c"><i class="fa-solid ${icon}"></i></span>${label}</button>`;
        scr.innerHTML = `
            ${avatar(name, Contacts.find(c.number)?.avatar, 'cs-avatar')}
            <div class="cs-name">${esc(name)}</div>
            <div class="cs-status">${esc(status)}</div>
            <div class="cs-dtmf">${esc(this.dtmf)}</div>
            ${incoming ? `
                <div class="cs-quick">
                    ${btn('remind', 'fa-clock', 'Remind Me')}
                    ${btn('msg', 'fa-message', 'Message')}
                </div>
                <div class="cs-incoming">
                    <button class="cs-btn cs-end" data-cs="end"><span class="c"><i class="fa-solid fa-phone"></i></span>Decline</button>
                    <button class="cs-btn cs-accept" data-cs="accept"><span class="c"><i class="fa-solid fa-phone"></i></span>Accept</button>
                </div>` : `
                <div class="cs-grid">
                    ${btn('mute', 'fa-microphone-slash', 'mute', true)}
                    ${btn('keypad', 'fa-grip', 'keypad', c.status !== 'active')}
                    ${btn('audio', 'fa-volume-high', 'audio', true)}
                    ${btn('add', 'fa-plus', 'add call', true)}
                    ${btn('msg', 'fa-message', 'message')}
                    ${btn('contacts', 'fa-address-book', 'contacts')}
                </div>
                <div class="cs-keypad">
                    ${['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'].map((k) => `<button class="pc-key" data-key="${k}">${k}</button>`).join('')}
                </div>
                <button class="cs-btn cs-end" data-cs="end" ${c.status === 'ended' ? 'style="opacity:.4"' : ''}><span class="c"><i class="fa-solid fa-phone"></i></span></button>
                <button class="nav-btn hidden" data-cs="hidekeypad" style="color:#fff;position:absolute;right:46px;bottom:84px">Hide</button>`}`;
    },

    setup() {
        const scr = this.screen();
        scr.addEventListener('click', (e) => {
            const key = e.target.closest('[data-key]');
            if (key) {
                this.dtmf += key.dataset.key;
                Sound.play('key', key.dataset.key);
                $('.cs-dtmf', scr).textContent = this.dtmf;
                return;
            }
            const b = e.target.closest('[data-cs]');
            if (!b) return;
            switch (b.dataset.cs) {
                case 'accept': this.answer(); break;
                case 'end': this.hangup(); break;
                case 'keypad':
                    scr.classList.add('keypad');
                    $('[data-cs=hidekeypad]', scr).classList.remove('hidden');
                    break;
                case 'hidekeypad':
                    scr.classList.remove('keypad');
                    b.classList.add('hidden');
                    break;
                case 'msg': {
                    const n = this.cur && this.cur.number;
                    if (this.cur && this.cur.status === 'ringing' && this.cur.dir === 'in') this.hangup();
                    else this.minimize();
                    if (n) Phone.openApp('messages', { number: n });
                    break;
                }
                case 'remind':
                    Phone.notify({ app: 'phone', title: 'Call back', body: this.displayName() });
                    this.hangup();
                    break;
                case 'contacts':
                    this.minimize();
                    Phone.openApp('contacts');
                    break;
            }
        });
        Phone.on('incomingCall', (d) => this.incoming(d));
        Phone.on('callAccepted', () => this.accepted());
        Phone.on('callEnded', (d) => this.ended(d));
        Phone.on('open', () => {
            if (this.cur && this.cur.status === 'ringing' && this.cur.dir === 'in') this.show();
        });
        Phone.on('reset', () => this.cur && this.finish());
        Phone.on('init', () => Contacts.load());
    },
};

/* =====================================================================
   Phone app
   ===================================================================== */

const KEYPAD = [['1', ''], ['2', 'A B C'], ['3', 'D E F'], ['4', 'G H I'], ['5', 'J K L'], ['6', 'M N O'], ['7', 'P Q R S'], ['8', 'T U V'], ['9', 'W X Y Z'], ['*', ''], ['0', '+'], ['#', '']];

function KeypadView(host) {
    let number = '';
    host.innerHTML = `
        <div class="keypad-view">
            <div class="kp-number"></div>
            <button class="kp-add hidden">Add Number</button>
            <div class="kp-grid">
                ${KEYPAD.map(([k, l]) => `<button class="kp-key" data-k="${k}"><span>${k}</span><small>${l}</small></button>`).join('')}
                <span></span>
                <button class="kp-call"><i class="fa-solid fa-phone"></i></button>
                <button class="kp-del hidden"><i class="fa-solid fa-delete-left"></i></button>
            </div>
        </div>`;
    const draw = () => {
        $('.kp-number', host).textContent = number;
        $('.kp-number', host).style.fontSize = number.length > 11 ? '30px' : '38px';
        $('.kp-del', host).classList.toggle('hidden', !number);
        $('.kp-add', host).classList.toggle('hidden', !number || !!Contacts.find(number));
    };
    let hold;
    host.addEventListener('pointerdown', (e) => {
        const k = e.target.closest('[data-k="0"]');
        if (k) hold = setTimeout(() => { hold = 'plus'; number += '+'; draw(); }, 600);
    });
    host.addEventListener('click', (e) => {
        const k = e.target.closest('[data-k]');
        if (k) {
            if (hold === 'plus') { hold = null; return; }
            clearTimeout(hold);
            if (number.length < 16) number += k.dataset.k;
            Sound.play('key', k.dataset.k);
            return draw();
        }
        if (e.target.closest('.kp-del')) { number = number.slice(0, -1); return draw(); }
        if (e.target.closest('.kp-call')) {
            if (!number) {
                // OPS OS: tapping call with empty field recalls the last dialed number
                rpc('getRecents').then((r) => { const o = (r || []).find((x) => x.outgoing); if (o) { number = o.number; draw(); } });
                return;
            }
            Call.start(number);
        }
        if (e.target.closest('.kp-add')) ContactEditor({ number }, () => draw());
    });
    draw();
}

function RecentsView(host, tabs) {
    const nav = new Nav(host);
    host._nav = nav;
    let filter = 'all';
    nav.push({
        title: 'Recents',
        large: true,
        tabbar: true,
        left: '<button class="nav-btn" data-act="clear" style="padding-left:8px">Clear</button>',
        render(content, ctx) {
            content.innerHTML = `<div class="segmented" style="margin:0 16px 10px"><button data-f="all" class="on">All</button><button data-f="missed">Missed</button></div><div class="r-list"><div class="spinner"></div></div>`;
            const list = $('.r-list', content);
            let rows = [];
            const draw = () => {
                const items = rows.filter((r) => filter === 'all' || (r.status === 'missed' && !r.outgoing));
                list.innerHTML = items.length ? `<div class="plain">${items.map((r) => {
                    const missed = r.status === 'missed' && !r.outgoing;
                    const name = r.name || Contacts.nameFor(r.number) || r.number;
                    return `<div class="row tap recent" data-n="${esc(r.number)}" style="--sep-left:40px">
                        <span style="width:16px;color:var(--label2);font-size:12px">${r.outgoing ? '<i class="fa-solid fa-phone" style="font-size:10px"></i>' : ''}</span>
                        <div class="grow"><div class="title" style="font-weight:600;${missed ? 'color:var(--red)' : ''}">${esc(name)}</div>
                        <div class="sub">${r.status === 'answered' ? 'mobile · ' + fmtDuration(r.duration) : r.status === 'declined' ? 'declined' : 'mobile'}</div></div>
                        <span class="value" style="font-size:15px">${esc(relTime(r.time))}</span>
                        <button class="tint" data-info="${esc(r.number)}" style="font-size:20px;padding-left:6px"><i class="fa-solid fa-circle-info"></i></button>
                    </div>`;
                }).join('')}</div>` : UI.empty('fa-solid fa-clock-rotate-left', 'No Recents', '');
            };
            const load = async () => { rows = (await rpc('getRecents')) || []; draw(); };
            content.addEventListener('click', (e) => {
                const seg = e.target.closest('[data-f]');
                if (seg) {
                    filter = seg.dataset.f;
                    $$('[data-f]', content).forEach((b) => b.classList.toggle('on', b === seg));
                    return draw();
                }
                const info = e.target.closest('[data-info]');
                if (info) {
                    const c = Contacts.find(info.dataset.info);
                    if (c) return ContactDetail(nav, c, load);
                    return ContactEditor({ number: info.dataset.info }, load);
                }
                const r = e.target.closest('[data-n]');
                if (r) Call.start(r.dataset.n);
            });
            $('[data-act=clear]', ctx.page).onclick = async () => {
                if (await UI.confirm('Clear All Recents', '', 'Clear All Recents', true)) { await rpc('clearRecents'); load(); }
            };
            ctx.opts.onResume = load;
            load();
            Phone.setBadge('phone', 0);
            tabs.badge('recents', 0);
        },
    });
}

function FavoritesView(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: 'Favourites',
        large: true,
        tabbar: true,
        right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
        render(content, ctx) {
            const draw = () => {
                const favs = Contacts.cache.filter((c) => c.favorite);
                content.innerHTML = favs.length ? `<div class="plain">${favs.map((c) => `
                    <div class="row tap" data-id="${c.id}" style="--sep-left:68px">
                        ${avatar(c.name, c.avatar)}
                        <div class="grow"><div class="title" style="font-weight:600">${esc(c.name)}</div><div class="sub"><i class="fa-solid fa-phone" style="font-size:11px"></i> mobile</div></div>
                        <button class="tint" data-info="${c.id}" style="font-size:20px"><i class="fa-solid fa-circle-info"></i></button>
                    </div>`).join('')}</div>` : UI.empty('fa-solid fa-star', 'No Favourites', 'Add people you call often.');
            };
            const load = async () => { await Contacts.load(); draw(); };
            content.addEventListener('click', (e) => {
                const info = e.target.closest('[data-info]');
                if (info) return ContactDetail(nav, Contacts.cache.find((c) => c.id === +info.dataset.info), load);
                const r = e.target.closest('[data-id]');
                if (r) { const c = Contacts.cache.find((x) => x.id === +r.dataset.id); Call.start(c.number, c.name); }
            });
            $('[data-act=add]', ctx.page).onclick = async () => {
                const c = await pickContact('Add Favourite');
                if (c && !c.favorite) { await rpc('toggleFavorite', { id: c.id }); load(); }
            };
            ctx.opts.onResume = load;
            load();
        },
    });
}

Apps.register({
    id: 'phone',
    name: 'Phone',
    icon: { bg: 'linear-gradient(180deg,#65f27e,#0dbd2e)', glyph: 'fa-solid fa-phone', size: 31 },
    open(root, params) {
        const tabs = TabBar(root, [
            { id: 'favorites', label: 'Favourites', icon: 'fa-solid fa-star', render: (h) => FavoritesView(h) },
            { id: 'recents', label: 'Recents', icon: 'fa-solid fa-clock', render: (h, t) => RecentsView(h, t) },
            {
                id: 'contacts', label: 'Contacts', icon: 'fa-solid fa-circle-user', render: (h) => {
                    const nav = new Nav(h); h._nav = nav;
                    nav.push({
                        title: 'Contacts', large: true, tabbar: true,
                        right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
                        render(content, ctx) {
                            const list = ContactsList(content, ctx, { onSelect: (c, refresh) => ContactDetail(nav, c, refresh) });
                            $('[data-act=add]', ctx.page).onclick = () => ContactEditor({}, () => list.refresh());
                        },
                    });
                },
            },
            { id: 'keypad', label: 'Keypad', icon: 'fa-solid fa-grip', render: (h) => KeypadView(h) },
            {
                id: 'voicemail', label: 'Voicemail', icon: 'fa-solid fa-voicemail', render: (h) => {
                    const nav = new Nav(h); h._nav = nav;
                    nav.push({ title: 'Voicemail', large: true, tabbar: true, render: (c) => { c.innerHTML = UI.empty('fa-solid fa-voicemail', 'No Voicemail', ''); } });
                },
            },
        ], params.tab || (Phone.badges.phone ? 'recents' : 'keypad'));
        if (Phone.badges.phone) tabs.badge('recents', Phone.badges.phone);
        if (params.number) Call.start(params.number);
    },
    onParams(params) { if (params.number) Call.start(params.number); },
});

Phone.on('callEnded', (d) => {
    if (d && d.status === 'missed') Phone.setBadge('phone', (Phone.badges.phone || 0) + (Call.cur && Call.cur.dir === 'in' ? 1 : 0));
});

document.addEventListener('DOMContentLoaded', () => Call.setup());
