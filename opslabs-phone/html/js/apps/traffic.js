'use strict';

/*
 * OPS Traffic — live incidents across the state: accidents, road closures, fires, gun violence, active police
 * pursuits (10-80), hazards and planned work. Report what you see, confirm or clear what others reported, set GPS,
 * and get alerts for incidents near you. Police start / end 10-80s and close roads. Server: server/traffic.lua.
 */

const TRAFFIC_FILTERS = [
    { id: 'all', label: 'All' },
    { id: 'accident', label: 'Accidents' },
    { id: 'closure', label: 'Closures' },
    { id: 'pursuit', label: '10-80' },
    { id: 'shots', label: 'Shots fired' },
    { id: 'fire', label: 'Fires' },
    { id: 'works', label: 'Planned work' },
    { id: 'hazard', label: 'Hazards' },
];
const TRAFFIC_REPORT = [
    { kind: 'accident', label: 'Accident', icon: 'fa-car-burst', color: '#ff9f0a' },
    { kind: 'hazard', label: 'Hazard on the road', icon: 'fa-triangle-exclamation', color: '#ffd60a' },
    { kind: 'fire', label: 'Fire', icon: 'fa-fire', color: '#ff6b00' },
    { kind: 'shots', label: 'Shots fired', icon: 'fa-gun', color: '#bf5af2' },
    { kind: 'police', label: 'Police activity', icon: 'fa-shield-halved', color: '#0a84ff' },
    { kind: 'closure', label: 'Road closed', icon: 'fa-road-barrier', color: '#ff453a', closer: true },
];
const TRAFFIC_SOURCE = { auto: 'Detected automatically', sensor: 'OPS Sentinel sensors', works: 'Street works site', planned: 'Planned work', crew: 'Crew on site', police: 'Police', player: 'Reported by drivers', system: 'City' };

function trafficDist(m) {
    if (m == null) return '';
    const imperial = (Phone.settings.unitDistance || '') === 'mi';
    if (imperial) { const ft = m * 3.281; return ft < 1000 ? `${Math.round(ft / 10) * 10} ft` : `${(m / 1609).toFixed(1)} mi`; }
    return m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1)} km`;
}
const trafficAgo = (t) => (t ? shortAgo(t * 1000) : '');
const trafficPrefs = () => ({ alerts: true, ...(Phone.settings.traffic || {}) });

// alerts for incidents near you — even when the app is closed
Phone.on('trafficAlert', (inc) => {
    if (!inc || !isInstalled('traffic')) return;
    const p = trafficPrefs();
    if (p.alerts === false || p[inc.kind] === false) return;
    Phone.notify({ app: 'traffic', title: inc.label, icon: inc.icon, body: [inc.street, inc.detail, inc.dist != null ? trafficDist(inc.dist) + ' away' : ''].filter(Boolean).join(' · ') });
});

function trafficRow(i) {
    return `<div class="tr-item" data-inc="${esc(String(i.id))}">
        <span class="tr-ic" style="background:${esc(i.color)}"><i class="fa-solid ${esc(i.icon)}"></i></span>
        <div class="grow">
            <div class="tr-top"><b>${esc(i.label)}</b>${i.kind === 'pursuit' ? '<span class="tr-live">LIVE</span>' : ''}<span class="tr-dist">${esc(trafficDist(i.dist))}</span></div>
            <div class="tr-street">${esc(i.street || 'Locating…')}</div>
            ${i.detail ? `<div class="tr-detail">${esc(i.detail)}</div>` : ''}
            <div class="tr-meta">${esc(TRAFFIC_SOURCE[i.source] || '')}${i.confirms > 1 ? ` · ${i.confirms} reports` : ''}${i.created_at ? ' · ' + esc(trafficAgo(i.updated_at || i.created_at)) : ''}</div>
        </div>
    </div>`;
}

function TrafficReport(feed, reload) {
    const opts = TRAFFIC_REPORT.filter((o) => !o.closer || feed.closer);
    UI.actionSheet('What do you see?', opts.map((o) => ({ label: o.label }))).then(async (i) => {
        if (i == null || i < 0 || !opts[i]) return;
        const o = opts[i];
        const here = (await nui('trafficHere')) || {};
        UI.sheet({
            title: o.label,
            right: 'Report',
            render(body) {
                body.innerHTML = `
                    <div class="tr-sheet-head"><span class="tr-ic big" style="background:${o.color}"><i class="fa-solid ${o.icon}"></i></span>
                        <div class="muted">${esc(here.street || 'Your location')}</div></div>
                    <div class="group"><div class="row"><textarea class="field" maxlength="200" placeholder="${o.kind === 'closure' ? 'Why is it closed? Diversion?' : 'Anything drivers should know (optional)'}"></textarea></div></div>
                    ${o.kind === 'closure' ? `<div class="group"><div class="row"><span class="lbl">Closed for</span><select class="field" data-f="minutes">
                        ${[15, 30, 60, 120, 240, 480].map((m) => `<option value="${m}" ${m === 60 ? 'selected' : ''}>${m < 60 ? m + ' minutes' : m / 60 + ' hour' + (m > 60 ? 's' : '')}</option>`).join('')}</select></div></div>` : ''}
                    <div class="group-footer">Your report is placed where you are standing now. Others nearby get an alert.</div>`;
            },
            async onRight(api) {
                const res = await rpc('trafficReport', { kind: o.kind, detail: $('textarea', api.body).value.trim(), street: here.street, minutes: +($('[data-f=minutes]', api.body) || {}).value || undefined });
                if (!res || res.error) return UI.alert({ title: (res && res.error) || 'Could not send the report' });
                api.close();
                Sound.play('sent');
                UI.toast(res.merged ? 'Thanks — added to the existing report' : 'Reported — thanks for keeping the roads safe', 'fa-solid fa-tower-broadcast');
                reload();
            },
        });
    });
}

function TrafficDetail(i, feed, reload) {
    const reported = typeof i.id === 'number';
    UI.sheet({
        title: i.label,
        left: 'Close',
        render(body, api) {
            body.innerHTML = `
                <div class="tr-sheet-head"><span class="tr-ic big" style="background:${esc(i.color)}"><i class="fa-solid ${esc(i.icon)}"></i></span>
                    <b style="font-size:19px">${esc(i.street || '')}</b><div class="muted">${esc(trafficDist(i.dist))} away · ${esc(trafficAgo(i.updated_at || i.created_at))}</div></div>
                ${i.detail ? `<div class="group"><div class="row" style="white-space:normal">${esc(i.detail)}</div></div>` : ''}
                <div class="group">
                    <div class="row"><span class="lbl">Source</span><span class="value">${esc(TRAFFIC_SOURCE[i.source] || i.source || '')}</span></div>
                    ${i.reporter ? `<div class="row"><span class="lbl">Reported by</span><span class="value">${esc(i.reporter)}</span></div>` : ''}
                    ${i.confirms > 1 ? `<div class="row"><span class="lbl">Confirmed</span><span class="value">${i.confirms} times</span></div>` : ''}
                </div>
                <div class="tr-actions">
                    <button class="btn" data-a="gps"><i class="fa-solid fa-location-arrow"></i> ${i.kind === 'closure' || i.kind === 'pursuit' ? 'Show on GPS' : 'GPS'}</button>
                    ${reported && !i.mine && i.kind !== 'pursuit' ? '<button class="btn gray" data-a="still">Still there</button><button class="btn gray" data-a="gone">It\'s gone</button>' : ''}
                    ${reported && (i.mine || feed.police || (i.kind === 'closure' && feed.closer)) && i.kind !== 'pursuit' ? '<button class="btn gray destructive" data-a="clear">Clear it</button>' : ''}
                </div>`;
            body.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-a]');
                if (!a) return;
                if (a.dataset.a === 'gps') { nui('setWaypoint', { x: i.x, y: i.y }); return UI.toast('GPS set', 'fa-solid fa-location-arrow'); }
                const res = a.dataset.a === 'clear' ? await rpc('trafficClear', { id: i.id }) : await rpc('trafficVote', { id: i.id, vote: a.dataset.a });
                if (!res || res.error) return UI.toast((res && res.error) || 'Failed', 'fa-solid fa-circle-xmark');
                UI.toast(a.dataset.a === 'clear' ? 'Cleared' : 'Thanks');
                api.close();
                reload();
            });
        },
    });
}

function TrafficSettings() {
    const p = trafficPrefs();
    UI.sheet({
        title: 'Alerts',
        right: 'Done',
        render(body) {
            body.innerHTML = `
                <div class="group"><div class="row"><div class="grow">Alerts near me</div>${UI.switchHtml(p.alerts !== false, 'data-k="alerts"')}</div></div>
                <div class="group-footer">A notification when something happens close to you — even when the app is closed.</div>
                <div class="group-header">Tell me about</div>
                <div class="group">${TRAFFIC_FILTERS.filter((f) => f.id !== 'all').map((f) => `<div class="row"><div class="grow">${esc(f.label)}</div>${UI.switchHtml(p[f.id] !== false, `data-k="${f.id}"`)}</div>`).join('')}</div>`;
        },
        onRight(api) {
            const out = {};
            $$('[data-k]', api.body).forEach((s) => { const inp = s.matches('input') ? s : $('input', s); out[s.dataset.k] = inp ? inp.checked : s.classList.contains('on'); });
            Phone.saveSetting('traffic', out);
            api.close();
        },
    });
}

Apps.register({
    id: 'traffic',
    name: 'OPS Traffic',
    icon: { bg: 'linear-gradient(160deg,#ff9f0a,#ff453a)', glyph: 'fa-solid fa-car-burst', size: 27 },
    open(root, _p, app) {
        const nav = new Nav(root);
        let feed = { incidents: [] }, filter = 'all', pursuit = false;
        nav.push({
            title: 'Traffic',
            large: true,
            grouped: true,
            right: '<button class="nav-btn" data-act="settings"><i class="fa-solid fa-bell"></i></button>',
            render(content, ctx) {
                content.innerHTML = `
                    <div class="tr-here"><i class="fa-solid fa-location-dot"></i><span class="tr-here-street">Finding you…</span></div>
                    <div class="tr-police"></div>
                    <div class="tr-chips">${TRAFFIC_FILTERS.map((f) => `<button data-f="${f.id}" class="${f.id === filter ? 'on' : ''}">${esc(f.label)}<span></span></button>`).join('')}</div>
                    <div class="tr-list"><div class="spinner"></div></div>
                    <button class="tr-fab" data-act="report"><i class="fa-solid fa-plus"></i> Report</button>`;
                const list = $('.tr-list', content);
                const render = () => {
                    const items = feed.incidents.filter((i) => filter === 'all' || i.kind === filter || (filter === 'hazard' && i.kind === 'police')).sort((a, b) => (a.dist ?? 1e9) - (b.dist ?? 1e9));
                    $$('.tr-chips button', content).forEach((b) => {
                        const n = b.dataset.f === 'all' ? feed.incidents.length : feed.incidents.filter((i) => i.kind === b.dataset.f).length;
                        $('span', b).textContent = n ? ` ${n}` : '';
                        b.classList.toggle('on', b.dataset.f === filter);
                    });
                    list.innerHTML = items.length ? items.map(trafficRow).join('')
                        : UI.empty('fa-solid fa-road', filter === 'all' ? 'All clear' : 'Nothing here', 'No incidents reported right now. Drive safe.');
                };
                const police = () => {
                    $('.tr-police', content).innerHTML = feed.police ? `<button class="tr-1080 ${pursuit ? 'on' : ''}" data-act="pursuit"><i class="fa-solid fa-car-on"></i>${pursuit ? 'End 10-80 · you are the lead unit' : 'Start 10-80 (pursuit)'}</button>` : '';
                };
                const load = async () => {
                    const [d, here] = await Promise.all([rpc('trafficFeed'), nui('trafficHere')]);
                    if (here) { $('.tr-here-street', content).textContent = here.street || 'Unknown road'; pursuit = !!here.pursuit; }
                    if (!d || d.__carrier) { list.innerHTML = UI.empty('fa-solid fa-signal', 'No connection', 'OPS Traffic needs mobile data.'); return; }
                    feed = d;
                    police();
                    render();
                    // street names for the live items that have none
                    const missing = feed.incidents.filter((i) => !i.street);
                    if (missing.length) {
                        const names = await nui('trafficStreets', { points: missing.map((i) => ({ x: i.x, y: i.y, z: i.z })) });
                        if (Array.isArray(names)) { missing.forEach((i, k) => { if (names[k]) i.street = names[k]; }); render(); }
                    }
                };
                content.addEventListener('click', async (e) => {
                    const f = e.target.closest('[data-f]');
                    if (f) { filter = f.dataset.f; return render(); }
                    const it = e.target.closest('[data-inc]');
                    if (it) { const i = feed.incidents.find((x) => String(x.id) === it.dataset.inc); if (i) TrafficDetail(i, feed, load); return; }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'report') return TrafficReport(feed, load);
                    if (a.dataset.act === 'pursuit') {
                        if (!pursuit) {
                            const detail = await UI.prompt('Start 10-80', 'Vehicle and direction (shown to drivers)', { placeholder: 'Black sedan heading north on Route 68', ok: 'Start' });
                            if (detail === null || detail === undefined) return;
                            const here = (await nui('trafficHere')) || {};
                            const r = await rpc('trafficPursuit', { action: 'start', detail: detail || undefined, street: here.street });
                            if (!r || r.error) return UI.toast((r && r.error) || 'Failed', 'fa-solid fa-circle-xmark');
                            pursuit = true;
                            nui('trafficPursuitTrack', { on: true });
                            UI.toast('10-80 live — drivers nearby are alerted', 'fa-solid fa-car-on');
                        } else {
                            await rpc('trafficPursuit', { action: 'end' });
                            pursuit = false;
                            nui('trafficPursuitTrack', { on: false });
                            UI.toast('10-80 ended');
                        }
                        police();
                        return load();
                    }
                });
                ctx.page.addEventListener('click', (e) => { if (e.target.closest('[data-act=settings]')) TrafficSettings(); });
                app.on('trafficChanged', debounce(load, 800));
                app.on('trafficMove', (m) => {
                    const i = m && feed.incidents.find((x) => x.id === m.id);
                    if (!i) return;
                    i.x = m.x; i.y = m.y; if (m.street) i.street = m.street;
                    render();
                });
                ctx.opts.onResume = load;
                app.reload = load;
                load();
            },
        });
    },
});
