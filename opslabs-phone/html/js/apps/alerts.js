'use strict';

/* =====================================================================
   OPS Emergency Alerts (server/emergency.lua, client/emergency.lua)
   - every phone: the full-screen alert with the alert tone when one
     arrives, and the app with the alerts of the last day
   - companies with the premium (OPS Hub → Companies → Emergency
     Alerts) and the alerts.send permission: send to the whole city,
     to an area around you or to the company's staff; cancel them
   Settings in the app: severe / warning / information alerts can be
   switched off (extreme alerts always sound, like the real thing).
   ===================================================================== */

const EA_SEV = {
    extreme: { name: 'Extreme Alert', short: 'Extreme', icon: 'triangle-exclamation', color: '#ff3b30', hint: 'Danger to life — always sounds' },
    severe: { name: 'Severe Alert', short: 'Severe', icon: 'circle-exclamation', color: '#ff9500', hint: 'Serious threat to people or property' },
    warning: { name: 'Warning', short: 'Warning', icon: 'bell', color: '#ffcc00', hint: 'Disruption: closures, outages, weather' },
    info: { name: 'Information', short: 'Info', icon: 'circle-info', color: '#0a84ff', hint: 'Public notice, no siren' },
};
const EA_SETTING = { severe: 'alertsSevere', warning: 'alertsWarning', info: 'alertsInfo' };
const EA_AUD = { all: 'Whole city', area: 'Area', staff: 'Staff only' };
const eaSev = (s) => EA_SEV[s] || EA_SEV.warning;
const eaWhen = (t) => (typeof shortAgo === 'function' ? shortAgo(t * 1000) : new Date(t * 1000).toLocaleTimeString());
const eaWants = (sev) => sev === 'extreme' || !EA_SETTING[sev] || (Phone.settings || {})[EA_SETTING[sev]] !== false;
const eaWhere = (a) => (a.audience === 'area' ? `Within ${a.radius >= 1000 ? (a.radius / 1000) + ' km' : a.radius + ' m'}${a.area ? ' of ' + a.area : ''}` : EA_AUD[a.audience] || '');

/* ------------------------------------------------------------------ the alert tone (WebAudio, like the WEA tone) */
const EATone = (() => {
    let ctx = null;
    let nodes = [];
    function stop() { nodes.forEach((n) => { try { n.stop(); } catch (_) { /* already stopped */ } }); nodes = []; }
    // 853 Hz + 960 Hz together: on 2 s, then 3 × (0.5 s off, 0.5 s on) — twice for extreme alerts
    function play(sev) {
        stop();
        if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
        if (ctx.state === 'suspended') ctx.resume();
        const loud = sev === 'extreme' || sev === 'severe';
        const gain = ctx.createGain();
        gain.gain.value = loud ? 0.32 : 0.22 * (typeof Sound !== 'undefined' && Sound.volume != null ? Sound.volume : 0.7);
        gain.connect(ctx.destination);
        const steps = [[0, 2]];
        for (let i = 0; i < 3; i++) steps.push([2.5 + i, 0.5]);
        const reps = sev === 'extreme' ? 2 : 1;
        const t0 = ctx.currentTime + 0.05;
        for (let r = 0; r < reps; r++) {
            steps.forEach(([at, len]) => [853, 960].forEach((f) => {
                const o = ctx.createOscillator();
                const g = ctx.createGain();
                const t = t0 + r * 5.5 + at;
                o.type = 'sine';
                o.frequency.value = f;
                g.gain.setValueAtTime(0, t);
                g.gain.linearRampToValueAtTime(0.5, t + 0.02);
                g.gain.setValueAtTime(0.5, t + len - 0.03);
                g.gain.linearRampToValueAtTime(0, t + len);
                o.connect(g).connect(gain);
                o.start(t);
                o.stop(t + len + 0.02);
                nodes.push(o);
            }));
        }
    }
    return { play, stop };
})();

/* ------------------------------------------------------------------ the full-screen alert */
const EmergencyAlerts = {
    shown: new Map(),       // id → alert on screen

    layer() {
        let l = $('#ea-layer');
        if (!l) {
            l = el('<div class="ea-layer" id="ea-layer" style="display:none"></div>');
            screenEl().appendChild(l);
            l.addEventListener('click', (e) => {
                const card = e.target.closest('.ea-card');
                if (!card) return;
                const id = +card.dataset.id;
                if (e.target.closest('[data-ea=map]')) { const a = this.shown.get(id); if (a) nui('emergencyWaypoint', { x: a.x, y: a.y }); UI.toast('Waypoint set', 'fa-solid fa-location-dot'); }
                if (e.target.closest('[data-ea=ok]') || e.target.closest('[data-ea=map]')) this.dismiss(id);
            });
        }
        return l;
    },

    cardHtml(a) {
        const s = eaSev(a.severity);
        return `<div class="ea-card sev-${esc(a.severity)}" data-id="${a.id}">
            <div class="ea-head"><span class="ea-ico"><i class="fa-solid fa-${s.icon}"></i></span>
                <div><div class="ea-kind">${esc(a.severity === 'extreme' ? 'Emergency Alert' : s.name)}</div><div class="ea-from">${esc(a.company || 'OPS')} · ${esc(eaWhen(a.at))}</div></div></div>
            <div class="ea-body"><div class="ea-title">${esc(a.title)}</div><div class="ea-text">${esc(a.body)}</div>
                <div class="ea-meta">${esc(eaWhere(a))}</div></div>
            <div class="ea-actions">${a.audience === 'area' && a.x != null ? '<button data-ea="map">Show on map</button>' : ''}<button data-ea="ok">OK</button></div></div>`;
    },

    render() {
        const l = this.layer();
        const list = [...this.shown.values()].sort((x, y) => y.at - x.at);
        l.innerHTML = list.map((a) => this.cardHtml(a)).join('');
        l.style.display = list.length ? '' : 'none';
    },

    receive(a) {
        if (!a || !a.id) return;
        // always in the Notification Centre, and in the app's list
        Phone.notifications.unshift({ app: 'alerts', title: `${eaSev(a.severity).name}: ${a.title}`, body: a.body, id: 'ea' + a.id, time: Date.now() });
        Phone.notifications = Phone.notifications.slice(0, 50);
        if (typeof renderNotifLists === 'function') renderNotifLists();
        Phone.emit('emergencyChanged');
        if (!eaWants(a.severity)) return;                       // switched off in the app: quietly listed only
        if (a.severity === 'info') {
            if (!Phone.settings.dnd && typeof Sound !== 'undefined') Sound.play('notify');
        } else if (a.severity === 'extreme' || a.severity === 'severe' || !(typeof Sound !== 'undefined' && Sound.silent)) {
            EATone.play(a.severity);                            // severe / extreme sound in Silent mode and Do Not Disturb too
        }
        if (typeof vibrate === 'function') vibrate();
        this.shown.set(a.id, a);
        this.render();
        if (Phone.state !== 'open') Phone.peek(a.severity === 'info' ? 6000 : 12000);
    },

    dismiss(id) {
        this.shown.delete(id);
        if (!this.shown.size) EATone.stop();
        this.render();
    },

    end(d) {
        const a = d && this.shown.get(d.id);
        if (a && d.status === 'cancelled') this.dismiss(d.id);
        else if (a) { a.status = d.status; const c = $(`.ea-card[data-id="${d.id}"]`); if (c) c.classList.add('ended'); }
        Phone.emit('emergencyChanged');
    },
};

Phone.on('emergencyAlert', (a) => EmergencyAlerts.receive(a));
Phone.on('emergencyEnd', (d) => EmergencyAlerts.end(d));
Phone.on('emergencyChanged', () => { if (EAApp.root && EAApp.reload) EAApp.reload(); });
Phone.on('reset', () => { EmergencyAlerts.shown.clear(); EATone.stop(); EmergencyAlerts.render(); });

/* ------------------------------------------------------------------ the app */
const EAApp = {
    root: null,
    reload: null,

    rowHtml(a, mine) {
        const s = eaSev(a.severity);
        const live = a.status === 'live' || a.status === 'pending';
        return `<div class="row tap has-icon" data-ea-id="${a.id}" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">
            <span class="ri" style="background:${s.color}"><i class="fa-solid fa-${s.icon}" style="color:#000"></i></span>
            <div class="grow"><div><b>${esc(a.title)}</b></div>
                <div class="sub muted">${esc(a.company || '')} · ${esc(eaWhen(a.at))}</div>
                <div style="display:flex;gap:5px;margin-top:5px;flex-wrap:wrap"><span class="ea-sev" style="--c:${s.color}">${esc(s.short)}</span>${live ? '<span class="ea-live">Live</span>' : ''}<span class="sub muted">${esc(eaWhere(a))}</span>${mine ? `<span class="sub muted">· reached ${a.reach || 0} phone${a.reach === 1 ? '' : 's'}${a.sentBy ? ' · by ' + esc(a.sentBy) : ''}${a.source === 'hub' ? ' · OPS Hub' : ''}</span>` : ''}</div></div>
            <i class="fa-solid fa-chevron-right chev"></i></div>`;
    },

    open(root) {
        this.root = root;
        root.innerHTML = '';
        const nav = new Nav(root);
        const self = this;
        nav.push({
            title: 'Emergency Alerts', large: true, grouped: true,
            render(c, ctx) {
                let inbox = [];
                let mine = null;
                const draw = () => {
                    const live = inbox.filter((a) => a.status === 'live');
                    const past = inbox.filter((a) => a.status !== 'live');
                    const s = Phone.settings || {};
                    c.innerHTML = `
                        ${mine && mine.senders && mine.senders.length ? `<div class="group" style="margin-top:12px">
                            <div class="row tap has-icon" data-ea-act="send"><span class="ri" style="background:#ff3b30"><i class="fa-solid fa-tower-broadcast"></i></span><div class="grow"><b>Send an alert</b><div class="sub muted">${esc(mine.senders.map((x) => x.name).join(', '))}</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row tap has-icon" data-ea-act="sent"><span class="ri" style="background:#8e8e93"><i class="fa-solid fa-clock-rotate-left"></i></span><div class="grow">Sent by your companies</div><span class="muted">${(mine.sent || []).filter((a) => a.status === 'live').length || ''}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                        </div>` : ''}
                        <div class="group-header">Live now</div>
                        <div class="group">${live.map((a) => self.rowHtml(a)).join('') || '<div class="row"><div class="grow muted">No alerts right now</div></div>'}</div>
                        ${past.length ? `<div class="group-header">Last 24 hours</div><div class="group">${past.map((a) => self.rowHtml(a)).join('')}</div>` : ''}
                        <div class="group-header">Alerts on this phone</div>
                        <div class="group">
                            <div class="row"><div class="grow">Extreme alerts<div class="sub muted">Danger to life. Always on.</div></div>${UI.switchHtml(true, 'disabled')}</div>
                            <div class="row"><div class="grow">Severe alerts</div>${UI.switchHtml(s.alertsSevere !== false, 'data-ea-set="alertsSevere"')}</div>
                            <div class="row"><div class="grow">Warnings</div>${UI.switchHtml(s.alertsWarning !== false, 'data-ea-set="alertsWarning"')}</div>
                            <div class="row"><div class="grow">Information</div>${UI.switchHtml(s.alertsInfo !== false, 'data-ea-set="alertsInfo"')}</div>
                        </div>
                        <div class="group-footer">Alerts come from the city's services and companies. Extreme and severe alerts sound even in Silent mode. Alerts you switch off still show up here.</div>`;
                };
                const load = async () => {
                    const [r, m] = await Promise.all([rpc('emergencyInbox'), rpc('emergencyMine')]);
                    if (EAApp.root !== root) return;
                    inbox = (r && r.alerts) || [];
                    mine = m;
                    draw();
                };
                c.innerHTML = '<div class="spinner" style="margin:60px auto"></div>';
                load();
                ctx.opts.onResume = load;
                EAApp.reload = load;
                c.addEventListener('change', (e) => { const t = e.target.closest('[data-ea-set]'); if (t) Phone.saveSetting(t.dataset.eaSet, t.checked); });
                c.addEventListener('click', (e) => {
                    const act = e.target.closest('[data-ea-act]');
                    if (act && act.dataset.eaAct === 'send') return EAApp.compose(nav, mine, load);
                    if (act && act.dataset.eaAct === 'sent') return EAApp.sent(nav, load);
                    const row = e.target.closest('[data-ea-id]');
                    if (row) { const a = inbox.find((x) => x.id === +row.dataset.eaId); if (a) EAApp.detail(nav, a, false, load); }
                });
            },
        });
    },

    detail(nav, a, canCancel, after) {
        const s = eaSev(a.severity);
        nav.push({
            title: s.name, grouped: true,
            render(c, ctx) {
                const live = a.status === 'live' || a.status === 'pending';
                c.innerHTML = `
                    <div class="group" style="margin-top:12px"><div class="ea-card sev-${esc(a.severity)}" style="margin:0;box-shadow:none;border-radius:0;animation:none">
                        <div class="ea-head"><span class="ea-ico"><i class="fa-solid fa-${s.icon}"></i></span><div><div class="ea-kind">${esc(s.name)}</div><div class="ea-from">${esc(a.company || '')} · ${esc(new Date(a.at * 1000).toLocaleString())}</div></div></div>
                        <div class="ea-body"><div class="ea-title">${esc(a.title)}</div><div class="ea-text">${esc(a.body)}</div>
                        <div class="ea-meta">${esc(eaWhere(a))} · ${live ? 'live until ' + esc(new Date(a.expires * 1000).toLocaleTimeString()) : esc(a.status)}</div></div></div></div>
                    ${a.audience === 'area' && a.x != null ? '<div class="group"><div class="row tap" data-ea-act="map"><div class="grow" style="color:#0a84ff">Show the area on the map</div></div></div>' : ''}
                    ${canCancel && live ? '<div class="group"><div class="row tap" data-ea-act="cancel"><div class="grow" style="color:#ff3b30">Cancel this alert</div></div></div><div class="group-footer">Cancelling takes it off every phone right away.</div>' : ''}`;
                c.addEventListener('click', async (e) => {
                    const act = e.target.closest('[data-ea-act]');
                    if (!act) return;
                    if (act.dataset.eaAct === 'map') { nui('emergencyWaypoint', { x: a.x, y: a.y }); UI.toast('Waypoint set', 'fa-solid fa-location-dot'); }
                    if (act.dataset.eaAct === 'cancel') {
                        if (!(await UI.confirm('Cancel this alert?', a.title, 'Cancel alert', true))) return;
                        const r = await rpc('emergencyCancel', { id: a.id });
                        if (!r || r.error) return UI.alert({ title: 'Couldn’t cancel', message: (r && r.error) || 'Try again in a moment.' });
                        UI.toast('Alert cancelled', 'fa-solid fa-ban');
                        if (after) after();
                        ctx.pop();
                    }
                });
            },
        });
    },

    sent(nav, after) {
        nav.push({
            title: 'Sent', grouped: true, backLabel: 'Alerts',
            render(c, ctx) {
                let list = [];
                const load = async () => {
                    const m = await rpc('emergencyMine');
                    list = (m && m.sent) || [];
                    c.innerHTML = `<div class="group" style="margin-top:12px">${list.map((a) => EAApp.rowHtml(a, true)).join('') || '<div class="row"><div class="grow muted">Nothing sent yet</div></div>'}</div>
                        <div class="group-footer">Alerts your companies sent from phones and from OPS Hub. Tap a live one to cancel it.</div>`;
                };
                c.innerHTML = '<div class="spinner" style="margin:60px auto"></div>';
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => {
                    const row = e.target.closest('[data-ea-id]');
                    const a = row && list.find((x) => x.id === +row.dataset.eaId);
                    if (a) EAApp.detail(nav, a, true, () => { load(); if (after) after(); });
                });
            },
        });
    },

    compose(nav, mine, after) {
        const f = { company: mine.senders[0].id, severity: 'warning', audience: 'all', radius: (mine.radii || [500])[1] || 500, hours: (mine.hours || [1])[0] };
        nav.push({
            title: 'New Alert', grouped: true, backLabel: 'Alerts',
            right: '<button class="nav-btn bold" data-act="send">Send</button>',
            render(c, ctx) {
                const radius = (r) => (r >= 1000 ? `${r / 1000} km` : `${r} m`);
                c.innerHTML = `
                    ${mine.senders.length > 1 ? `<div class="group" style="margin-top:12px"><div class="row"><span class="lbl">From</span><select class="field" data-f="company">${mine.senders.map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join('')}</select></div></div>` : `<div class="group-header" style="margin-top:12px">From ${esc(mine.senders[0].name)}</div>`}
                    <div class="group-header">How serious</div>
                    <div class="ea-picks">${Object.entries(EA_SEV).map(([k, s]) => `<button data-sev="${k}" style="--c:${s.color}"><i class="fa-solid fa-${s.icon}"></i>${esc(s.name)}<small>${esc(s.hint)}</small></button>`).join('')}</div>
                    <div class="group-header">Who gets it</div>
                    <div class="segmented" style="margin:0 16px 10px">${Object.entries(EA_AUD).map(([k, v]) => `<button data-aud="${k}">${esc(k === 'area' ? 'Around me' : v)}</button>`).join('')}</div>
                    <div class="group ea-area">
                        <div class="row"><span class="lbl">Radius</span><select class="field" data-f="radius">${(mine.radii || []).map((r) => `<option value="${r}" ${r === f.radius ? 'selected' : ''}>${radius(r)}</option>`).join('')}</select></div>
                        <div class="row"><input class="field" data-f="area" placeholder="Place name (e.g. Mirror Park)" maxlength="80"></div>
                    </div>
                    <div class="group">
                        <div class="row"><span class="lbl">Live for</span><select class="field" data-f="hours">${(mine.hours || []).map((h) => `<option value="${h}">${h} hour${h === 1 ? '' : 's'}</option>`).join('')}</select></div>
                        <div class="row"><input class="field" data-f="title" placeholder="Headline (e.g. Gas leak — stay indoors)" maxlength="80"></div>
                        <div class="row"><textarea class="field" data-f="body" placeholder="What is happening and what people should do" maxlength="600" style="min-height:110px"></textarea></div>
                    </div>
                    <div class="group-footer ea-foot"></div>`;
                const sync = () => {
                    $$('[data-sev]', c).forEach((b) => b.classList.toggle('on', b.dataset.sev === f.severity));
                    $$('[data-aud]', c).forEach((b) => b.classList.toggle('on', b.dataset.aud === f.audience));
                    $('.ea-area', c).style.display = f.audience === 'area' ? '' : 'none';
                    $('.ea-foot', c).textContent = f.audience === 'all' ? 'Every phone in the city gets it, and anyone who comes online while it is live.'
                        : f.audience === 'area' ? 'Everyone within the radius of where you are standing now gets it — and anyone who walks into the area while it is live. The area shows on their map.'
                            : 'Only staff of the company get it.';
                };
                sync();
                c.addEventListener('click', (e) => {
                    const s = e.target.closest('[data-sev]');
                    if (s) { f.severity = s.dataset.sev; sync(); }
                    const a = e.target.closest('[data-aud]');
                    if (a) { f.audience = a.dataset.aud; sync(); }
                });
                $('[data-act=send]', ctx.page).onclick = async () => {
                    const val = (k) => { const x = $(`[data-f=${k}]`, c); return x ? x.value.trim() : ''; };
                    const data = { ...f, company: +(val('company') || f.company), radius: +val('radius') || f.radius, hours: +val('hours') || f.hours, area: val('area'), title: val('title'), body: val('body') };
                    if (!data.title || !data.body) return UI.alert({ title: 'Missing details', message: 'Give the alert a headline and a message.' });
                    const who = data.audience === 'area' ? `everyone within ${radius(data.radius)} of you` : data.audience === 'staff' ? 'your staff' : 'every phone in the city';
                    if (!(await UI.confirm(`Send ${eaSev(data.severity).name}?`, `${data.title} — to ${who}.`, 'Send', data.severity === 'extreme'))) return;
                    const r = await rpc('emergencySend', data);
                    if (!r || r.error) return UI.alert({ title: 'Couldn’t send', message: (r && r.error) || 'Try again in a moment.' });
                    UI.toast('Alert sent', 'fa-solid fa-tower-broadcast');
                    if (after) after();
                    ctx.pop();
                };
            },
        });
    },
};

Apps.register({
    id: 'alerts', name: 'Alerts', resumable: false,
    splash: 'linear-gradient(160deg,#1c1c1e,#ff3b30)',
    icon: { bg: 'linear-gradient(150deg,#ff453a,#7a0b05 130%)', html: () => '<i class="fa-solid fa-triangle-exclamation" style="font-size:27px;color:#fff"></i>' },
    open(root) { return EAApp.open(root); },
    onClose() { EAApp.root = null; EAApp.reload = null; },
});
