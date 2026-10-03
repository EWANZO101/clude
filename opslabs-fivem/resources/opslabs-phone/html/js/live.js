'use strict';

/* =====================================================================
   Live location sharing (live tracking style)
   - incoming: people sharing their location with us (updated every ~2s)
   - outgoing: people we share our location with
   Rendered as live map cards in Messages, people on the Maps app, and
   (Lua side) moving blips + optional auto-updating GPS route.
   ===================================================================== */

const Live = {
    incoming: {},
    outgoing: {},
    following: null,
    serverOffset: 0,
    myPos: null,

    now() { return Date.now() / 1000 + this.serverOffset; },

    async refresh() {
        const r = await rpc('getLiveShares');
        if (!r) return;
        this.serverOffset = r.now - Date.now() / 1000;
        this.incoming = {};
        this.outgoing = {};
        (r.incoming || []).forEach((s) => { this.incoming[s.id] = s; });
        (r.outgoing || []).forEach((s) => { this.outgoing[s.id] = s; });
        this.changed();
    },

    changed() {
        screenEl().classList.toggle('sharing-location', Object.keys(this.outgoing).length > 0);
        Phone.emit('liveChanged');
    },

    /** asks for a duration, then starts sharing with `number` */
    async share(number, name) {
        const who = name || Contacts.nameFor(number) || number;
        const i = await UI.actionSheet(`Share your live location with ${who}`, [
            { label: 'Share for 15 Minutes' },
            { label: 'Share for One Hour' },
            { label: 'Share Until I Stop' },
        ]);
        if (i === null) return false;
        const res = await rpc('startLiveLocation', { number, minutes: [15, 60, 0][i] });
        if (!res || res.error) {
            UI.alert({ title: "Couldn't Share Location", message: (res && res.error) || 'Try again later.' });
            return false;
        }
        this.outgoing[res.id] = { id: res.id, number: res.number, expires: res.expires };
        this.changed();
        UI.toast(`Sharing with ${who}`, 'fa-solid fa-location-arrow');
        return true;
    },

    async stop(id) {
        if (!(await UI.confirm('Stop Sharing Location', 'They will no longer see where you are.', 'Stop Sharing', true))) return;
        await rpc('stopLiveLocation', { id: +id });
        delete this.outgoing[id];
        this.changed();
    },

    async follow(id) {
        const on = id && this.following !== +id;
        await nui('liveFollow', { id: on ? +id : null });
        this.following = on ? +id : null;
        this.changed();
    },

    directions(id) {
        const s = this.incoming[id];
        if (!s || s.x == null) return;
        nui('setWaypoint', { x: s.x, y: s.y });
        nui('liveFlash', { id: +id });
    },

    remaining(s) {
        if (!s.expires) return 'until you stop';
        const m = Math.max(0, Math.ceil((s.expires - this.now()) / 60));
        return m >= 60 ? `${Math.floor(m / 60)} hr left` : `${m} min left`;
    },

    ago(s) {
        const sec = Math.max(0, Math.round(this.now() - (s.updated || 0)));
        if (sec < 10) return 'Now';
        if (sec < 60) return `${sec}s ago`;
        return `${Math.floor(sec / 60)} min ago`;
    },

    distText(s) { return fmtDist(s.dist); },
};

Phone.on('liveLocation', (d) => {
    Live.incoming[d.id] = { ...(Live.incoming[d.id] || {}), ...d };
    Live.changed();
});
Phone.on('liveLocationEnded', (d) => {
    delete Live.incoming[d.id];
    delete Live.outgoing[d.id];
    if (Live.following === d.id) Live.following = null;
    Live.changed();
});
Phone.on('liveReporting', (d) => {
    if (d && !d.on && Object.keys(Live.outgoing).length) { Live.outgoing = {}; Live.changed(); }
});
Phone.on('init', () => Live.refresh());
Phone.on('reset', () => { Live.incoming = {}; Live.outgoing = {}; Live.following = null; Live.changed(); });
Phone.on('open', () => { if (Object.keys(Live.incoming).length || Object.keys(Live.outgoing).length) Live.refresh(); });

// keep "x mi away" fresh while the phone is open
setInterval(async () => {
    if (Phone.state !== 'open' || !Object.keys(Live.incoming).length) return;
    const d = await nui('liveDistances');
    if (!d) return;
    Object.entries(d).forEach(([id, dist]) => { if (Live.incoming[id]) Live.incoming[id].dist = dist; });
    Phone.emit('liveChanged');
}, 5000);

/* ---------------------------------------------------------------------
   mini map + live card (Messages)
   --------------------------------------------------------------------- */

// miniMap(canvas, x, y, zoom) is provided by apps/maps.js

function liveCardHtml(a, mine, ownerName) {
    return `
        <div class="live-card ${mine ? 'mine' : ''}" data-live="${a.shareId}" data-mine="${mine ? 1 : 0}">
            <div class="lc-map">
                <canvas width="460" height="250"></canvas>
                <span class="lc-pin">${mine ? avatar(Phone.profile?.name, null, 'sm') : avatar(ownerName, null, 'sm')}<i class="lc-pulse"></i></span>
                <span class="lc-badge"><i class="fa-solid fa-location-arrow"></i> LIVE</span>
            </div>
            <div class="lc-info"><b>${mine ? 'Sharing My Location' : 'Live Location'}</b><span class="lc-sub">Locating…</span></div>
            <div class="lc-actions"></div>
        </div>`;
}

function updateLiveCard(card) {
    const id = +card.dataset.live;
    const mine = card.dataset.mine === '1';
    const sub = $('.lc-sub', card);
    const actions = $('.lc-actions', card);
    const canvas = $('canvas', card);

    if (mine) {
        const s = Live.outgoing[id];
        card.classList.toggle('ended', !s);
        sub.textContent = s ? `Live · ${Live.remaining(s)}` : 'You stopped sharing';
        const html = s ? `<button data-live-act="stop" data-id="${id}" class="danger">Stop Sharing</button>` : '';
        if (actions.innerHTML !== html) actions.innerHTML = html;
        const pos = Live.myPos;
        if (pos && canvas.dataset.drawn !== `${Math.round(pos.x)},${Math.round(pos.y)}`) {
            miniMap(canvas, pos.x, pos.y);
            canvas.dataset.drawn = `${Math.round(pos.x)},${Math.round(pos.y)}`;
        }
        return;
    }

    const s = Live.incoming[id];
    const active = !!s;
    card.classList.toggle('ended', !active);
    if (!active) {
        sub.textContent = 'Live location ended';
        if (actions.innerHTML) actions.innerHTML = '';
        if (!canvas.dataset.drawn && Live.myPos) { miniMap(canvas, Live.myPos.x, Live.myPos.y, 3); canvas.dataset.drawn = 'ended'; }
        return;
    }
    if (s.x == null) { sub.textContent = 'Locating…'; return; }

    const dist = Live.distText(s);
    sub.textContent = `Updated ${Live.ago(s)}${dist ? ` · ${dist} away` : ''} · ${Live.remaining(s).replace('until you stop', 'live')}`;
    const following = Live.following === id;
    const html = `
        <button data-live-act="directions" data-id="${id}"><i class="fa-solid fa-diamond-turn-right"></i> Directions</button>
        <button data-live-act="follow" data-id="${id}" class="${following ? 'on' : ''}"><i class="fa-solid fa-route"></i> ${following ? 'Following' : 'Follow'}</button>`;
    if (actions.dataset.state !== String(following)) { actions.innerHTML = html; actions.dataset.state = String(following); }

    const key = `${Math.round(s.x)},${Math.round(s.y)}`;
    if (canvas.dataset.drawn !== key) {
        miniMap(canvas, s.x, s.y);
        canvas.dataset.drawn = key;
    }
}

function updateLiveCards(root = document) {
    $$('.live-card', root).forEach(updateLiveCard);
}

Phone.on('liveChanged', () => updateLiveCards());
Phone.on('tick', () => {
    // refresh the "updated Xs ago" labels without redrawing maps
    if (Phone.state === 'open' && $('.live-card')) updateLiveCards();
});

document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-live-act]');
    if (!b) return;
    e.stopPropagation();
    const id = +b.dataset.id;
    switch (b.dataset.liveAct) {
        case 'stop': Live.stop(id); break;
        case 'follow': Live.follow(id); break;
        case 'directions':
            Live.directions(id);
            UI.toast('GPS set', 'fa-solid fa-diamond-turn-right');
            break;
    }
}, true);
