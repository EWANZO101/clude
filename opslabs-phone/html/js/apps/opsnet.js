'use strict';

/* =====================================================================
   Ops-Networks — the network engineer's app
   Own sign-in (per phone session), permission-gated screens: jobs and
   planned work, faults, customers, network kit, poles, Wi-Fi range test,
   earnings and an admin panel. The server checks every permission again.
   OpsNetEditors (fault engine / pay / render distance) are shared with the
   Developer app.
   ===================================================================== */

const ON_SEV = { low: ['Low', '#30d158'], medium: ['Medium', '#ffcc00'], high: ['High', '#ff9500'], critical: ['Critical', '#ff3b30'] };
const ON_FAULT_STATUS = { open: ['Open', '#ff3b30'], acknowledged: ['Acknowledged', '#ff9500'], in_progress: ['In progress', '#0a84ff'], fixed: ['Fixed', '#34c759'], closed: ['Closed', '#8e8e93'] };
const ON_JOB_STATUS = { open: ['Available', '#0a84ff'], assigned: ['Assigned', '#ff9500'], completed: ['Completed', '#34c759'], cancelled: ['Cancelled', '#8e8e93'] };
const ON_POLE_STATUS = { live: ['Live', '#34c759'], building: ['Building', '#ff9500'], planned: ['Planned', '#8e8e93'], maintenance: ['Maintenance', '#ff3b30'] };
const ON_COMPASS = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];

const onPill = (map, key) => {
    const [label, color] = map[key] || [key || '—', '#8e8e93'];
    return `<span class="on-pill" style="--c:${color}">${esc(label)}</span>`;
};
const onWhen = (unix) => (unix ? relTime(Number(unix) * 1000) : '—');
const onAgo = (unix) => (unix ? shortAgo(Number(unix) * 1000) : '');
const onNum = (v, d = 1) => (v == null || isNaN(v) ? '—' : Number(v).toFixed(d));
const onKv = (label, value, raw = false) => `<div class="row"><div class="grow muted">${esc(label)}</div><div class="on-kv" data-no-i18n>${raw ? value : esc(value ?? '—')}</div></div>`;
const onHas = (p) => !!(OpsNet.me && OpsNet.me.perms && OpsNet.me.perms.includes(p));
const onAny = (...ps) => ps.some(onHas);
const onSpin = '<div class="spinner" style="margin:40px auto"></div>';
const onCompass = (deg) => ON_COMPASS[Math.round(((deg % 360) + 360) % 360 / 22.5) % 16];
const onWaypoint = (x, y) => { if (x != null && y != null) nui('setWaypoint', { x, y }); };

/** Lua sends empty tables as {} or []: turn empty objects into [] so lists always work */
function onFix(v) {
    if (Array.isArray(v)) return v.map(onFix);
    if (v && typeof v === 'object') {
        const keys = Object.keys(v);
        if (!keys.length) return [];
        keys.forEach((k) => { v[k] = onFix(v[k]); });
    }
    return v;
}

async function onRpc(name, data) {
    const res = onFix(await rpc(name, data));
    if (res && res.loggedOut) {
        UI.alert({ title: 'Signed Out', message: 'Your Ops-Networks session has ended. Please sign in again.' });
        if (OpsNet.root) OpsNet.showLogin();
        return null;
    }
    if (res && res.denied) {
        UI.alert({ title: 'Not Allowed', message: res.error || "You don't have permission to do that." });
        return null;
    }
    return res;
}

function onError(c, res, fallback) {
    c.innerHTML = UI.empty(res && res.offline ? 'fa-solid fa-plug-circle-xmark' : 'fa-solid fa-circle-exclamation',
        res && res.offline ? 'Network Offline' : 'Unavailable', (res && res.error) || fallback || 'Please try again in a moment.');
}

/* ---------------- shared editors (Ops-Networks admin + Developer app) ---------------- */

const OpsNetEditors = {
    /** opts: { call(name, data), load, save, trigger, close, backLabel } */
    faults(nav, opts) {
        nav.push({
            title: 'Network Faults',
            grouped: true,
            backLabel: opts.backLabel,
            right: '<button class="nav-btn bold" data-act="save">Save</button>',
            render(c, ctx) {
                let data = null;
                const draw = async () => {
                    c.innerHTML = onSpin;
                    data = onFix(await opts.call(opts.load));
                    if (!data || data.error) return onError(c, data, 'Fault settings are unavailable.');
                    const s = data.settings || {};
                    const types = s.types || [];
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px">
                            <div class="row"><div class="grow">Fault engine<div class="sub">Faults develop on live assets at random</div></div>${UI.switchHtml(s.enabled !== false, 'data-f="enabled"')}</div>
                            <div class="row"><div class="grow">Max open faults<div class="sub">No new faults while this many are open</div></div><input class="field on-num" type="number" min="0" max="500" step="1" data-f="maxOpen" value="${esc(s.maxOpen ?? 0)}"></div>
                        </div>
                        ${types.map((t) => `
                            <div class="group-header on-th"><span data-no-i18n>${esc(t.label || t.id)}</span> ${onPill(ON_SEV, t.severity)}</div>
                            <div class="group" data-type="${esc(t.id)}">
                                <div class="row"><div class="grow">Enabled${t.description ? `<div class="sub on-wrap" data-no-i18n>${esc(t.description)}</div>` : ''}</div>${UI.switchHtml(t.enabled !== false, 'data-t="enabled"')}</div>
                                <div class="row"><div class="grow">About N per week<div class="sub">Across the whole network</div></div><input class="field on-num" type="number" min="0" step="0.1" data-t="perWeek" value="${esc(t.perWeek ?? 0)}"></div>
                                <div class="row"><div class="grow">Only after live for N hours<div class="sub">Asset age before it can fail</div></div><input class="field on-num" type="number" min="0" step="1" data-t="minLiveHours" value="${esc(t.minLiveHours ?? 0)}"></div>
                            </div>`).join('')}
                        <div class="group-header">Testing</div>
                        <div class="group">
                            <div class="row tap has-icon" data-act="trigger"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-bolt"></i></span><div class="grow">Trigger Test Fault…</div></div>
                        </div>
                        <div class="group-footer">Forces a fault of the chosen type now on a random eligible asset.</div>
                        <div class="group-header">Active Faults (${(data.faults || []).length})</div>
                        <div class="group">${(data.faults || []).map((f) => `
                            <div class="row tap" data-fault="${f.id}">
                                <div class="grow"><div class="title" data-no-i18n>#${f.id} · ${esc(f.label || f.type)}</div><div class="sub">${esc((f.asset && f.asset.label) || '')}${f.pole_id ? ' · Pole #' + f.pole_id : ''} · ${onAgo(f.created_at)}</div></div>
                                ${onPill(ON_FAULT_STATUS, f.status)}
                            </div>`).join('') || '<div class="row muted">No active faults</div>'}</div>`;
                };
                draw();
                c.addEventListener('click', async (e) => {
                    if (e.target.closest('[data-act=trigger]')) {
                        const types = (data && data.settings && data.settings.types) || [];
                        if (!types.length) return;
                        const i = await UI.actionSheet('Trigger Test Fault', types.map((t) => ({ label: t.label || t.id })));
                        if (i == null) return;
                        const res = await opts.call(opts.trigger, { type: types[i].id });
                        if (!res || res.error) return UI.alert({ title: "Couldn't trigger", message: (res && res.error) || '' });
                        UI.toast(`Fault #${res.fault && res.fault.id} opened`, 'fa-solid fa-bolt');
                        return draw();
                    }
                    const r = e.target.closest('[data-fault]');
                    if (!r) return;
                    const f = (data.faults || []).find((x) => x.id === +r.dataset.fault);
                    if (!f) return;
                    const i = await UI.actionSheet(`#${f.id} · ${f.label || f.type}`, [{ label: 'Set GPS' }, { label: 'Close Fault', destructive: true }]);
                    if (i === 0) onWaypoint(f.x, f.y);
                    if (i === 1) {
                        const note = await UI.prompt('Close Fault', 'Optional note (no engineer is paid for faults closed here).', { ok: 'Close' });
                        if (note == null) return;
                        const res = await opts.call(opts.close, { id: f.id, note });
                        if (!res || res.error) return UI.alert({ title: "Couldn't close", message: (res && res.error) || '' });
                        UI.toast('Fault closed');
                        draw();
                    }
                });
                $('[data-act=save]', ctx.page).onclick = async () => {
                    if (!data || data.error) return;
                    const out = { enabled: $('[data-f=enabled]', c).checked, maxOpen: +$('[data-f=maxOpen]', c).value, types: {} };
                    $$('[data-type]', c).forEach((g) => {
                        out.types[g.dataset.type] = {
                            enabled: $('[data-t=enabled]', g).checked,
                            perWeek: parseFloat($('[data-t=perWeek]', g).value) || 0,
                            minLiveHours: parseFloat($('[data-t=minLiveHours]', g).value) || 0,
                        };
                    });
                    const res = await opts.call(opts.save, out);
                    if (!res || res.error) return UI.alert({ title: "Couldn't save", message: (res && res.error) || '' });
                    UI.toast('Fault settings saved', 'fa-solid fa-triangle-exclamation');
                };
            },
        });
    },

    /** opts: { call, load, save, backLabel } */
    pay(nav, opts) {
        nav.push({
            title: 'Engineer Pay',
            grouped: true,
            backLabel: opts.backLabel,
            right: '<button class="nav-btn bold" data-act="save">Save</button>',
            render(c, ctx) {
                let data = null;
                const money = (f, v, sub) => `<div class="row"><div class="grow">${esc(f[1])}${sub ? `<div class="sub">${esc(sub)}</div>` : ''}</div><span class="muted">$</span><input class="field on-num" type="number" min="0" step="50" data-p="${f[0]}" value="${esc(v ?? 0)}"></div>`;
                (async () => {
                    c.innerHTML = onSpin;
                    data = onFix(await opts.call(opts.load));
                    if (!data || data.error) return onError(c, data);
                    const s = data.settings, d = data.defaults || {};
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px">
                            ${money(['Default', 'Default fault rate'], s.Default, 'Fault types or severities without a rate')}
                            ${money(['Planned', 'Planned work'], s.Planned, 'Suggested pay for new planned jobs')}
                        </div>
                        <div class="group-header">By Severity</div>
                        <div class="group">${['low', 'medium', 'high', 'critical'].map((k) => money(['sev.' + k, ON_SEV[k][0]], s.BySeverity[k], `Config default $${(d.BySeverity || {})[k] ?? '—'}`)).join('')}</div>
                        <div class="group-header">By Fault Type</div>
                        <div class="group">${(data.types || []).map((t) => money(['type.' + t.id, t.label || t.id], (s.ByType || {})[t.id] || 0)).join('')}</div>
                        <div class="group-footer">A fault type rate above $0 replaces the severity rate for that type.</div>
                        <div class="group-header">Quick-Fix Bonus</div>
                        <div class="group">
                            <div class="row"><div class="grow">Bonus enabled</div>${UI.switchHtml(s.Bonus.Enabled, 'data-p="bonus.on"')}</div>
                            <div class="row"><div class="grow">Fixed within (hours)</div><input class="field on-num" type="number" min="0.25" step="0.25" data-p="bonus.hours" value="${esc(s.Bonus.Hours)}"></div>
                            ${money(['bonus.amount', 'Bonus amount'], s.Bonus.Amount)}
                        </div>
                        <div class="group-footer">Paid into the engineer's ${esc(data.account || 'bank')} account when the fault is fixed in game. Changes apply immediately.</div>`;
                })();
                $('[data-act=save]', ctx.page).onclick = async () => {
                    if (!data || data.error) return;
                    const v = (k) => { const n = $(`[data-p="${k}"]`, c); return n ? Number(n.value) || 0 : 0; };
                    const out = { Default: v('Default'), Planned: v('Planned'), BySeverity: {}, ByType: {}, Bonus: { Enabled: $('[data-p="bonus.on"]', c).checked, Hours: v('bonus.hours'), Amount: v('bonus.amount') } };
                    ['low', 'medium', 'high', 'critical'].forEach((k) => { out.BySeverity[k] = v('sev.' + k); });
                    (data.types || []).forEach((t) => { out.ByType[t.id] = v('type.' + t.id); });
                    const res = await opts.call(opts.save, out);
                    if (!res || res.error) return UI.alert({ title: "Couldn't save", message: (res && res.error) || '' });
                    UI.toast('Pay rates saved', 'fa-solid fa-sack-dollar');
                    ctx.pop();
                };
            },
        });
    },

    /** opts: { call, load, save, backLabel } */
    render(nav, opts) {
        const FIELDS = [
            ['Distance', 'Render distance', 'm', 'How far kit streams in front of the camera', 10],
            ['Behind', 'Nearby radius', 'm', 'Kit within this radius stays loaded whichever way you face', 5],
            ['ViewAngle', 'View angle', '°', 'Width of the forward cone', 5],
            ['Margin', 'Margin', 'm', 'Hysteresis so kit at the edge does not flicker', 1],
        ];
        nav.push({
            title: 'Render Distance',
            grouped: true,
            backLabel: opts.backLabel,
            right: '<button class="nav-btn bold" data-act="save">Save</button>',
            render(c, ctx) {
                let data = null;
                (async () => {
                    c.innerHTML = onSpin;
                    data = onFix(await opts.call(opts.load));
                    if (!data || data.error) return onError(c, data, 'Render settings are unavailable.');
                    const s = data.settings || {}, lim = data.limits || {};
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px">${FIELDS.map(([k, label, unit, help, step]) => {
                            const [lo, hi] = lim[k] || [0, 9999];
                            return `<div class="row"><div class="grow">${esc(label)}<div class="sub on-wrap">${esc(help)} (${lo}–${hi} ${unit})</div></div>
                                <div class="on-stepper"><button data-step="-${step}" data-k="${k}">−</button><input class="field on-num" type="number" min="${lo}" max="${hi}" step="${step}" data-r="${k}" value="${esc(Math.round(s[k] ?? lo))}"><button data-step="${step}" data-k="${k}">+</button></div></div>`;
                        }).join('')}</div>
                        <div class="group-footer">Network and power kit (poles, cabinets, cables) only renders within this range in front of each player. Changes apply live to everyone.</div>`;
                })();
                c.addEventListener('click', (e) => {
                    const b = e.target.closest('[data-step]');
                    if (!b || !data) return;
                    const inp = $(`[data-r="${b.dataset.k}"]`, c);
                    const v = (Number(inp.value) || 0) + Number(b.dataset.step);
                    inp.value = Math.max(Number(inp.min), Math.min(Number(inp.max), v));
                });
                $('[data-act=save]', ctx.page).onclick = async () => {
                    if (!data || data.error) return;
                    const out = {};
                    FIELDS.forEach(([k]) => { const n = Number($(`[data-r="${k}"]`, c).value); if (!isNaN(n)) out[k] = n; });
                    const res = await opts.call(opts.save, out);
                    if (!res || res.error) return UI.alert({ title: "Couldn't save", message: (res && res.error) || '' });
                    UI.toast('Render distance saved', 'fa-solid fa-eye');
                    ctx.pop();
                };
            },
        });
    },
};

/* ---------------- pages ---------------- */

function onJobRow(j) {
    const sev = ON_SEV[j.priority] || ON_SEV.medium;
    return `<div class="row tap has-icon" data-job="${j.id}">
        <span class="ri" style="background:${sev[1]}"><i class="fa-solid ${j.kind === 'fault' ? 'fa-triangle-exclamation' : 'fa-helmet-safety'}"></i></span>
        <div class="grow"><div class="title" data-no-i18n>${esc(j.title)}</div>
            <div class="sub">${esc(j.location || (j.kind === 'planned' ? 'Planned work' : 'Fault'))}${j.status === 'assigned' && j.assignedName ? ' · ' + esc(j.assignedName) : ''}${j.status === 'completed' && j.completedName ? ' · ' + esc(j.completedName) : ''} · ${onAgo(j.completedAt || j.createdAt)}</div></div>
        <span class="value">${fmtMoney(j.status === 'completed' && j.paid ? j.paidAmount : j.pay)}</span>
    </div>`;
}

const OnPages = {
    jobs(nav, initial) {
        nav.push({
            title: 'Jobs',
            grouped: true,
            backLabel: 'Ops-Networks',
            right: onHas('jobs.manage') ? '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>' : '',
            render(c, ctx) {
                let filter = initial || 'available';
                c.innerHTML = `<div class="segmented" style="margin-top:12px"><button data-f="available">Available</button><button data-f="mine">Mine</button><button data-f="completed">Completed</button></div><div class="on-list"></div>`;
                const list = $('.on-list', c);
                const load = async () => {
                    $$('[data-f]', c).forEach((b) => b.classList.toggle('on', b.dataset.f === filter));
                    const res = await onRpc('opsnetJobs', { filter });
                    if (!res) return;
                    if (res.error) return onError(list, res);
                    $('[data-f=available]', c).textContent = `Available${res.counts.available ? ' (' + res.counts.available + ')' : ''}`;
                    $('[data-f=mine]', c).textContent = `Mine${res.counts.mine ? ' (' + res.counts.mine + ')' : ''}`;
                    list.innerHTML = res.jobs.length ? `<div class="group">${res.jobs.map(onJobRow).join('')}</div>`
                        : UI.empty('fa-solid fa-clipboard-check', filter === 'mine' ? 'No Jobs Assigned' : filter === 'completed' ? 'Nothing Completed Yet' : 'All Clear', filter === 'available' ? 'New faults and planned work appear here.' : '');
                };
                list.innerHTML = onSpin;
                load();
                ctx.opts.onResume = load;
                ctx.opts.onLeave = Phone.on('opsnetJobsChanged', load);
                c.addEventListener('click', (e) => {
                    const f = e.target.closest('[data-f]');
                    if (f) { filter = f.dataset.f; list.innerHTML = onSpin; return load(); }
                    const j = e.target.closest('[data-job]');
                    if (j) OnPages.job(nav, +j.dataset.job);
                });
                const add = $('[data-act=add]', ctx.page);
                if (add) add.onclick = () => OnPages.createJob(load);
            },
        });
    },

    planned(nav) {
        nav.push({
            title: 'Planned Work',
            grouped: true,
            backLabel: 'Ops-Networks',
            right: onHas('jobs.manage') ? '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>' : '',
            render(c, ctx) {
                const load = async () => {
                    const res = await onRpc('opsnetJobs', { filter: 'planned' });
                    if (!res) return;
                    if (res.error) return onError(c, res);
                    c.innerHTML = res.jobs.length ? `<div class="group" style="margin-top:12px">${res.jobs.map(onJobRow).join('')}</div>
                        <div class="group-footer">Complete planned work on site: you must be within range of the job location.</div>`
                        : UI.empty('fa-solid fa-calendar-check', 'No Planned Work', onHas('jobs.manage') ? 'Tap + to plan a job at your position or at a pole.' : '');
                };
                c.innerHTML = onSpin;
                load();
                ctx.opts.onResume = load;
                ctx.opts.onLeave = Phone.on('opsnetJobsChanged', load);
                c.addEventListener('click', (e) => { const j = e.target.closest('[data-job]'); if (j) OnPages.job(nav, +j.dataset.job); });
                const add = $('[data-act=add]', ctx.page);
                if (add) add.onclick = () => OnPages.createJob(load);
            },
        });
    },

    createJob(onDone) {
        let where = 'here';
        UI.sheet({
            title: 'Plan Work',
            right: 'Create',
            render(body, api) {
                body.innerHTML = `
                    <div class="group">
                        <div class="row"><input class="field" data-f="title" maxlength="120" placeholder="Title (e.g. Install CBT on pole 12)"></div>
                        <div class="row"><textarea class="field" data-f="description" maxlength="1000" placeholder="What needs doing"></textarea></div>
                    </div>
                    <div class="group-header">Location</div>
                    <div class="group">
                        <div class="row tap" data-where="here"><div class="grow">My current position</div><i class="fa-solid fa-check check"></i></div>
                        <div class="row tap" data-where="pole"><div class="grow">At a pole</div><i class="fa-solid fa-check check hidden"></i></div>
                        <div class="row hidden" data-pole-row><span class="lbl">Pole ID</span><input class="field" data-f="poleId" type="number" min="1" placeholder="e.g. 12"></div>
                        <div class="row"><span class="lbl">Label</span><input class="field" data-f="location" maxlength="160" placeholder="Optional (street, cabinet…)"></div>
                    </div>
                    <div class="group-header">Priority &amp; Pay</div>
                    <div class="group">
                        <div class="row"><span class="lbl">Priority</span><select class="field" data-f="priority">${Object.entries(ON_SEV).map(([k, v]) => `<option value="${k}" ${k === 'medium' ? 'selected' : ''}>${v[0]}</option>`).join('')}</select></div>
                        <div class="row"><span class="lbl">Pay ($)</span><input class="field" data-f="pay" type="number" min="0" step="50" placeholder="Default rate"></div>
                    </div>`;
                const check = () => api.setRightEnabled($('[data-f=title]', body).value.trim().length > 0);
                body.addEventListener('input', check);
                check();
                body.addEventListener('click', (e) => {
                    const w = e.target.closest('[data-where]');
                    if (!w) return;
                    where = w.dataset.where;
                    $$('[data-where]', body).forEach((r) => $('.check', r).classList.toggle('hidden', r.dataset.where !== where));
                    $('[data-pole-row]', body).classList.toggle('hidden', where !== 'pole');
                });
            },
            async onRight(api) {
                const b = api.body;
                const pay = $('[data-f=pay]', b).value;
                const res = await onRpc('opsnetCreateJob', {
                    title: $('[data-f=title]', b).value.trim(), description: $('[data-f=description]', b).value.trim(),
                    location: $('[data-f=location]', b).value.trim(), priority: $('[data-f=priority]', b).value,
                    pay: pay === '' ? null : Number(pay), where, poleId: Number($('[data-f=poleId]', b).value) || null,
                });
                if (!res) return;
                if (res.error) return UI.alert({ title: "Couldn't create job", message: res.error });
                api.close();
                UI.toast('Planned work created', 'fa-solid fa-helmet-safety');
                onDone && onDone();
            },
        });
    },

    job(nav, id) {
        nav.push({
            title: 'Job',
            grouped: true,
            render(c, ctx) {
                let j = null;
                const load = async () => {
                    j = await onRpc('opsnetJob', { id });
                    if (!j) return;
                    if (j.error) return onError(c, j);
                    const f = j.fault;
                    const canTake = onHas('jobs.take'), canManage = onHas('jobs.manage');
                    const actions = [];
                    actions.push('<div class="row tap has-icon" data-act="gps"><span class="ri" style="background:#007aff"><i class="fa-solid fa-location-arrow"></i></span><div class="grow tint">Set Waypoint</div></div>');
                    if (canTake && j.status === 'open') actions.push('<div class="row tap has-icon" data-act="accept"><span class="ri" style="background:#34c759"><i class="fa-solid fa-hand"></i></span><div class="grow tint">Accept Job</div></div>');
                    if (canTake && j.kind === 'planned' && (j.status === 'open' || j.mine)) actions.push('<div class="row tap has-icon" data-act="complete"><span class="ri" style="background:#30b0c7"><i class="fa-solid fa-flag-checkered"></i></span><div class="grow tint">Complete On Site</div></div>');
                    if (j.status === 'assigned' && (j.mine || canManage)) actions.push('<div class="row tap has-icon" data-act="release"><span class="ri" style="background:#8e8e93"><i class="fa-solid fa-rotate-left"></i></span><div class="grow tint">Release Job</div></div>');
                    if (canManage && (j.status === 'open' || j.status === 'assigned')) actions.push('<div class="row tap has-icon" data-act="assign"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-user-gear"></i></span><div class="grow tint">Assign To…</div></div>');
                    if (canManage && j.kind === 'planned' && (j.status === 'open' || j.status === 'assigned')) actions.push('<div class="row tap" data-act="cancel"><div class="grow danger">Cancel Job</div></div>');
                    c.innerHTML = `
                        <div class="on-hero">
                            <div class="on-hero-ico" style="background:${(ON_SEV[j.priority] || ON_SEV.medium)[1]}"><i class="fa-solid ${j.kind === 'fault' ? 'fa-triangle-exclamation' : 'fa-helmet-safety'}"></i></div>
                            <b data-no-i18n>${esc(j.title)}</b>
                            <div class="on-pills">${onPill(ON_SEV, j.priority)} ${onPill(ON_JOB_STATUS, j.status)} ${j.faultStatus && j.kind === 'fault' ? onPill(ON_FAULT_STATUS, j.faultStatus) : ''}</div>
                        </div>
                        <div class="group">${actions.join('')}</div>
                        <div class="group">
                            ${onKv('Type', j.kind === 'fault' ? `Fault #${j.faultId}` : 'Planned work')}
                            ${onKv('Location', j.location || '—')}
                            ${j.poleId ? onKv('Pole', '#' + j.poleId) : ''}
                            ${onKv('Pay', fmtMoney(j.paid ? j.paidAmount : j.pay) + (j.paid ? ' (paid)' : ''))}
                            ${j.kind === 'fault' && j.bonus && !j.paid ? onKv('Quick-fix bonus', `${fmtMoney(j.bonus.amount)} within ${j.bonus.hours} h`) : ''}
                            ${onKv('Assigned', j.assignedName || 'Nobody')}
                            ${onKv('Created', `${onWhen(j.createdAt)}${j.createdBy ? ' · ' + j.createdBy : ''}`)}
                            ${j.completedAt ? onKv(j.status === 'cancelled' ? 'Cancelled' : 'Completed', `${onWhen(j.completedAt)}${j.completedName ? ' · ' + j.completedName : ''}`) : ''}
                        </div>
                        ${j.description ? `<div class="group-header">Description</div><div class="group"><div class="row on-text" data-no-i18n>${esc(j.description)}</div></div>` : ''}
                        ${f ? OnPages.faultBody(f, true) : ''}
                        ${j.kind === 'fault' && j.status !== 'completed' ? '<div class="group-footer" style="margin-top:-20px">Fault jobs complete when the repair is done in the field; the engineer who fixes it is paid.</div>' : ''}
                        ${j.kind === 'planned' && j.status !== 'completed' ? `<div class="group-footer" style="margin-top:-20px">Be within ${Math.round(j.radius || 30)} m of the job to complete it.</div>` : ''}`;
                };
                c.innerHTML = onSpin;
                load();
                ctx.opts.onLeave = Phone.on('opsnetJobsChanged', load);
                c.addEventListener('click', async (e) => {
                    const fl = e.target.closest('[data-open-fault]');
                    if (fl) return OnPages.fault(nav, +fl.dataset.openFault);
                    const a = e.target.closest('[data-act]');
                    if (!a || !j) return;
                    const act = a.dataset.act;
                    let res;
                    if (act === 'gps') return onWaypoint(j.x, j.y);
                    if (act === 'accept') { res = await onRpc('opsnetAcceptJob', { id }); if (res && !res.error) { UI.toast('Job accepted'); onWaypoint(j.x, j.y); } }
                    if (act === 'release') res = await onRpc('opsnetReleaseJob', { id });
                    if (act === 'complete') { res = await onRpc('opsnetCompleteJob', { id }); if (res && !res.error) UI.toast(`Completed · ${fmtMoney(res.paid)} paid`, 'fa-solid fa-sack-dollar'); }
                    if (act === 'cancel') {
                        if (!(await UI.confirm('Cancel Job', 'This planned work will be removed from the list.', 'Cancel Job', true))) return;
                        res = await onRpc('opsnetCancelJob', { id });
                    }
                    if (act === 'assign') {
                        const list = await onRpc('opsnetEngineers');
                        if (!list || list.error) return;
                        if (!list.length) return UI.alert({ title: 'No Engineers', message: 'Nobody has the jobs.take permission yet.' });
                        const i = await UI.actionSheet('Assign To', list.map((u) => ({ label: `${u.name} (${u.username})` })));
                        if (i == null) return;
                        res = await onRpc('opsnetAssignJob', { id, userId: list[i].id });
                        if (res && !res.error) UI.toast('Assigned to ' + list[i].name);
                    }
                    if (res && res.error) return UI.alert({ title: "Couldn't do that", message: res.error });
                    load();
                });
            },
        });
    },

    faultBody(f, linked) {
        const list = (arr, numbered) => (arr && arr.length ? `<div class="group">${arr.map((s, i) => `<div class="row on-text" data-no-i18n>${numbered ? `<b class="on-step">${i + 1}</b>` : ''}<span>${esc(s)}</span></div>`).join('')}</div>` : '');
        const aff = f.affected || [];
        return `
            ${linked ? `<div class="group-header">Fault</div><div class="group"><div class="row tap" data-open-fault="${f.id}"><div class="grow tint">Open Fault #${f.id}</div>${onPill(ON_FAULT_STATUS, f.status)}<i class="fa-solid fa-chevron-right chev"></i></div></div>` : ''}
            ${f.symptoms && f.symptoms.length ? '<div class="group-header">Symptoms</div>' + list(f.symptoms) : ''}
            ${f.diagnosis ? `<div class="group-header">Diagnosis</div><div class="group"><div class="row on-text" data-no-i18n>${esc(f.diagnosis)}</div></div>` : ''}
            ${f.fix_steps && f.fix_steps.length ? '<div class="group-header">Fix Steps</div>' + list(f.fix_steps, true) : ''}
            ${f.tools && f.tools.length ? `<div class="group-header">Tools</div><div class="group"><div class="row on-chips">${f.tools.map((t) => `<span data-no-i18n>${esc(t)}</span>`).join('')}${f.at_height ? '<span class="warn"><i class="fa-solid fa-person-falling"></i> Work at height: harness on</span>' : ''}</div></div>` : ''}
            ${!linked ? `<div class="group-header">Affected Customers (${f.affected_count || 0})</div>
                <div class="group">${aff.map((a) => `<div class="row"><div class="grow"><div class="title" data-no-i18n>${esc(a.customer || 'Unassigned ONT')}</div><div class="sub" data-no-i18n>${esc([a.username, a.provider, a.ip, 'ONT #' + a.ont_id].filter(Boolean).join(' · '))}</div></div></div>`).join('')
                    || `<div class="row muted">${f.affected_count ? (onHas('customers.view') ? 'Details unavailable' : 'Requires customers.view') : 'None'}</div>`}</div>` : ''}`;
    },

    faults(nav) {
        nav.push({
            title: 'Faults',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c, ctx) {
                let status = 'active';
                c.innerHTML = `<div class="on-tiles" data-stats></div><div class="segmented"><button data-s="active" class="on">Active</button><button data-s="all">Last 14 Days</button></div><div class="on-list"></div>`;
                const list = $('.on-list', c);
                const load = async () => {
                    $$('[data-s]', c).forEach((b) => b.classList.toggle('on', b.dataset.s === status));
                    const res = await onRpc('opsnetFaults', { status });
                    if (!res) return;
                    if (res.error) return onError(list, res);
                    const st = res.stats || {};
                    $('[data-stats]', c).innerHTML = [['Open', st.open], ['Critical', st.critical], ['Customers hit', st.affected]].map(([l, v]) => `<div><b>${Number(v || 0)}</b><span>${l}</span></div>`).join('');
                    list.innerHTML = res.faults.length ? `<div class="group">${res.faults.map((f) => `
                        <div class="row tap has-icon" data-fault="${f.id}">
                            <span class="ri" style="background:${(ON_SEV[f.severity] || ON_SEV.medium)[1]}"><i class="fa-solid fa-triangle-exclamation"></i></span>
                            <div class="grow"><div class="title" data-no-i18n>#${f.id} · ${esc(f.label || f.type)}</div><div class="sub">${esc((f.asset && f.asset.label) || f.category || '')}${f.affected_count ? ` · ${f.affected_count} customers` : ''} · ${onAgo(f.created_at)}</div></div>
                            ${onPill(ON_FAULT_STATUS, f.status)}
                        </div>`).join('')}</div>` : UI.empty('fa-solid fa-circle-check', 'No Faults', 'The network is healthy.');
                };
                list.innerHTML = onSpin;
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => {
                    const s = e.target.closest('[data-s]');
                    if (s) { status = s.dataset.s; list.innerHTML = onSpin; return load(); }
                    const f = e.target.closest('[data-fault]');
                    if (f) OnPages.fault(nav, +f.dataset.fault);
                });
            },
        });
    },

    fault(nav, id) {
        nav.push({
            title: 'Fault #' + id,
            grouped: true,
            render(c) {
                let f = null;
                const load = async () => {
                    f = await onRpc('opsnetFault', { id });
                    if (!f) return;
                    if (f.error) return onError(c, f);
                    const manage = onHas('faults.manage');
                    const active = ['open', 'acknowledged', 'in_progress'].includes(f.status);
                    c.innerHTML = `
                        <div class="on-hero">
                            <div class="on-hero-ico" style="background:${(ON_SEV[f.severity] || ON_SEV.medium)[1]}"><i class="fa-solid fa-triangle-exclamation"></i></div>
                            <b data-no-i18n>${esc(f.label || f.type)}</b>
                            <div class="on-pills">${onPill(ON_SEV, f.severity)} ${onPill(ON_FAULT_STATUS, f.status)}</div>
                        </div>
                        <div class="group">
                            <div class="row tap has-icon" data-act="gps"><span class="ri" style="background:#007aff"><i class="fa-solid fa-location-arrow"></i></span><div class="grow tint">Set Waypoint</div></div>
                            ${f.job ? `<div class="row tap has-icon" data-act="job"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-clipboard-list"></i></span><div class="grow tint">Open Job</div><span class="value">${esc((ON_JOB_STATUS[f.job.status] || [f.job.status])[0])}</span></div>` : ''}
                            ${manage && f.status === 'open' ? '<div class="row tap has-icon" data-act="ack"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-eye"></i></span><div class="grow tint">Acknowledge</div></div>' : ''}
                            ${manage ? '<div class="row tap has-icon" data-act="note"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-note-sticky"></i></span><div class="grow tint">Add Note</div></div>' : ''}
                            ${manage && active ? '<div class="row tap" data-act="close"><div class="grow danger">Close Fault</div></div>' : ''}
                        </div>
                        <div class="group">
                            ${onKv('Asset', f.asset ? `${f.asset.label || f.asset.kind} #${f.asset.id}` : '—')}
                            ${f.pole_id ? onKv('Pole', '#' + f.pole_id) : ''}
                            ${onKv('Category', f.category || '—')}
                            ${onKv('At height', f.at_height ? 'Yes: climb + harness' : 'No')}
                            ${onKv('Opened', onWhen(f.created_at))}
                            ${f.ack_at ? onKv('Acknowledged', `${onWhen(f.ack_at)}${f.ack_by ? ' · ' + f.ack_by : ''}`) : ''}
                            ${f.fixed_at ? onKv('Fixed', `${onWhen(f.fixed_at)}${f.fixed_by ? ' · ' + f.fixed_by : ''}`) : ''}
                            ${f.cause && (f.status === 'in_progress' || f.status === 'fixed' || f.status === 'closed') ? onKv('Cause', f.cause) : ''}
                        </div>
                        ${OnPages.faultBody(f, false)}
                        <div class="group-header">Notes</div>
                        <div class="group">${(f.notes || []).map((n) => `<div class="row on-text"><div class="grow"><div data-no-i18n>${esc(n.text)}</div><div class="sub">${esc(n.by || '')} · ${onWhen(n.at)}</div></div></div>`).join('') || '<div class="row muted">No notes</div>'}</div>`;
                };
                c.innerHTML = onSpin;
                load();
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a || !f) return;
                    let res;
                    if (a.dataset.act === 'gps') return onWaypoint(f.x, f.y);
                    if (a.dataset.act === 'job') return OnPages.job(nav, f.job.id);
                    if (a.dataset.act === 'ack') res = await onRpc('opsnetFaultAction', { id, action: 'ack' });
                    if (a.dataset.act === 'note') {
                        const text = await UI.prompt('Add Note', '', { placeholder: 'e.g. OTDR shows break at 212 m' });
                        if (!text) return;
                        res = await onRpc('opsnetFaultAction', { id, action: 'note', text });
                    }
                    if (a.dataset.act === 'close') {
                        const text = await UI.prompt('Close Fault', 'Closing from the app does not pay anyone. Add a note:', { ok: 'Close' });
                        if (text == null) return;
                        res = await onRpc('opsnetFaultAction', { id, action: 'close', text });
                    }
                    if (res && res.error) return UI.alert({ title: "Couldn't do that", message: res.error });
                    if (res) UI.toast('Done');
                    load();
                });
            },
        });
    },

    customers(nav) {
        nav.push({
            title: 'Customers',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c) {
                let data = null;
                c.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Customer, username, serial${onHas('customers.ip') ? ', IP' : ''}"></div><div class="on-tiles" data-stats></div><div class="on-list">${onSpin}</div>`;
                const list = $('.on-list', c);
                const draw = (q = '') => {
                    q = q.trim().toLowerCase();
                    const rows = data.onts.filter((o) => !q || [o.customer, o.username, o.serial, o.provider, o.ip, o.mac, '#' + o.id].join(' ').toLowerCase().includes(q));
                    list.innerHTML = rows.length ? `<div class="group">${rows.slice(0, 150).map((o) => `
                        <div class="row tap" data-ont="${o.id}">
                            <span class="on-dot" style="background:${o.los || o.hardware === 'failed' ? '#ff3b30' : o.service === 'active' ? '#34c759' : o.service === 'suspended' ? '#ff9500' : '#8e8e93'}"></span>
                            <div class="grow"><div class="title" data-no-i18n>${esc(o.customer || 'No customer')}${o.fault ? ' <i class="fa-solid fa-triangle-exclamation" style="color:#ff9500;font-size:12px"></i>' : ''}</div>
                                <div class="sub" data-no-i18n>${esc([o.username, o.provider, o.plan].filter(Boolean).join(' · ') || 'ONT #' + o.id)}</div></div>
                            <i class="fa-solid fa-chevron-right chev"></i>
                        </div>`).join('')}</div>` : UI.empty('fa-solid fa-users', 'No Customers', q ? 'Nothing matches your search.' : '');
                };
                (async () => {
                    data = await onRpc('opsnetCustomers');
                    if (!data) return;
                    if (data.error) return onError(list, data);
                    const st = data.stats || {};
                    $('[data-stats]', c).innerHTML = [['ONTs', st.total], ['Live', st.live], ['No service', st.no_service], ['LOS', st.los]].map(([l, v]) => `<div><b>${Number(v || 0)}</b><span>${l}</span></div>`).join('');
                    draw();
                })();
                $('input', c).addEventListener('input', debounce((e) => data && !data.error && draw(e.target.value), 150));
                list.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-ont]');
                    if (r) OnPages.customer(nav, data.onts.find((o) => o.id === +r.dataset.ont), data.ip);
                });
            },
        });
    },

    customer(nav, o, ip) {
        if (!o) return;
        nav.push({
            title: o.customer || 'ONT #' + o.id,
            grouped: true,
            render(c) {
                const rxColor = o.rx == null ? '' : o.rx < -27 ? '#ff3b30' : o.rx < -24 ? '#ff9500' : '#34c759';
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        <div class="row tap has-icon" data-act="gps"><span class="ri" style="background:#007aff"><i class="fa-solid fa-location-arrow"></i></span><div class="grow tint">Set Waypoint</div></div>
                        ${o.fault && onHas('faults.view') ? `<div class="row tap has-icon" data-fault="${o.fault}"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-triangle-exclamation"></i></span><div class="grow tint">Open Fault #${o.fault}</div></div>` : ''}
                    </div>
                    <div class="group-header">Service</div>
                    <div class="group">
                        ${onKv('Customer', o.customer || '—')}
                        ${onKv('Username', o.username || '—')}
                        ${onKv('Provider', o.provider || '—')}
                        ${onKv('Plan', o.plan ? `${o.plan}${o.down ? ` (${o.down}/${o.up} Mb)` : ''}` : '—')}
                        ${onKv('Status', o.service || 'none')}
                        ${o.uptime ? onKv('Uptime', fmtDuration(o.uptime)) : ''}
                    </div>
                    <div class="group-header">ONT</div>
                    <div class="group">
                        ${onKv('ONT', '#' + o.id)}
                        ${onKv('Serial', o.serial || '—')}
                        ${onKv('Rx light', o.rx != null ? `<span style="color:${rxColor}">${onNum(o.rx)} dBm</span>` : '—', true)}
                        ${onKv('Fibre distance', o.distance != null ? o.distance + ' m' : '—')}
                        ${onKv('Joints', o.joints ?? '—')}
                        ${onKv('PON', o.los ? 'LOS (no light)' : o.pon || '—')}
                        ${o.hardware === 'failed' ? onKv('Hardware', '<span class="danger">Failed</span>', true) : ''}
                        ${o.lowLight ? onKv('Light level', '<span style="color:#ff9500">Low</span>', true) : ''}
                        ${o.lanName ? onKv('LAN', o.lanName) : ''}
                    </div>
                    ${ip ? `<div class="group-header">Addressing</div><div class="group">
                        ${onKv('Public IP', o.ip || '—')}${onKv('Gateway', o.gateway || '—')}${onKv('MAC', o.mac || '—')}${onKv('LAN subnet', o.lan_subnet || '—')}</div>` : ''}`;
                c.addEventListener('click', (e) => {
                    if (e.target.closest('[data-act=gps]')) onWaypoint(o.x, o.y);
                    const f = e.target.closest('[data-fault]');
                    if (f) OnPages.fault(nav, +f.dataset.fault);
                });
            },
        });
    },

    network(nav) {
        nav.push({
            title: 'Network',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c) {
                let data = null, tab = 'kit';
                c.innerHTML = `<div class="on-tiles" data-stats></div><div class="segmented"><button data-t="kit" class="on">Equipment</button><button data-t="links">Links</button><button data-t="towers">Towers</button></div><div class="on-list">${onSpin}</div>`;
                const list = $('.on-list', c);
                const lit = (on) => `<span class="on-dot" style="background:${on ? '#34c759' : '#8e8e93'}" title="${on ? 'Lit' : 'Dark'}"></span>`;
                const draw = () => {
                    $$('[data-t]', c).forEach((b) => b.classList.toggle('on', b.dataset.t === tab));
                    if (tab === 'kit') {
                        list.innerHTML = data.kit.length ? `<div class="group">${data.kit.map((k) => `
                            <div class="row tap" data-gps="${k.x},${k.y}">${lit(k.lit)}<div class="grow"><div class="title" data-no-i18n>${esc(k.label)} #${k.id}</div><div class="sub">${k.headend ? 'Head-end' : 'Passive'} · ${k.lit ? 'Lit' : 'Dark'}</div></div><i class="fa-solid fa-location-arrow tint"></i></div>`).join('')}</div>
                            <div class="group-footer">Cabinets, OLTs, joints, CBTs and CSPs. Tap to set a waypoint.</div>` : UI.empty('fa-solid fa-server', 'No Equipment', '');
                    } else if (tab === 'links') {
                        list.innerHTML = data.links.length ? `<div class="group">${data.links.slice(0, 200).map((l) => `
                            <div class="row">${lit(l.lit)}<div class="grow"><div class="title">${l.kind === 'fibre' ? 'Fibre' : esc(l.kind || 'Cable')} #${l.id}</div><div class="sub">${l.lit ? 'Lit' : 'Dark'}</div></div><span class="value">${Number(l.length || 0)} m</span></div>`).join('')}</div>` : UI.empty('fa-solid fa-route', 'No Links', '');
                    } else {
                        list.innerHTML = data.towers.length ? `<div class="group">${data.towers.map((t) => `
                            <div class="row tap has-icon" data-gps="${t.x},${t.y}"><span class="ri" style="background:${t.type === 'wifi' ? '#32ade6' : '#5856d6'}"><i class="fa-solid ${t.type === 'wifi' ? 'fa-wifi' : 'fa-tower-cell'}"></i></span>
                                <div class="grow"><div class="title" data-no-i18n>${esc(t.name || (t.type === 'wifi' ? 'Access point' : 'Cell tower'))}</div><div class="sub" data-no-i18n>${esc([t.type === 'wifi' ? (t.ssid || 'Wi-Fi') : 'Cell', t.range ? t.range + ' m' : null, t.active ? 'Active' : 'Off'].filter(Boolean).join(' · '))}</div></div>
                                <i class="fa-solid fa-location-arrow tint"></i></div>`).join('')}</div>` : UI.empty('fa-solid fa-tower-cell', 'No Towers', '');
                    }
                };
                (async () => {
                    data = await onRpc('opsnetNetwork');
                    if (!data) return;
                    if (data.error) return onError(list, data);
                    const t = data.totals || {};
                    $('[data-stats]', c).innerHTML = [['Fibre', `${(t.fibre / 1000).toFixed(1)} km`], ['Links lit', `${t.lit}/${t.links}`], ['Poles', t.poles], ['Open faults', (data.faults && data.faults.open) || 0]]
                        .map(([l, v]) => `<div><b data-no-i18n>${esc(v)}</b><span>${l}</span></div>`).join('');
                    draw();
                })();
                c.addEventListener('click', (e) => {
                    const t = e.target.closest('[data-t]');
                    if (t && data && !data.error) { tab = t.dataset.t; return draw(); }
                    const g = e.target.closest('[data-gps]');
                    if (g) { const [x, y] = g.dataset.gps.split(',').map(Number); onWaypoint(x, y); }
                });
            },
        });
    },

    poles(nav) {
        nav.push({
            title: 'Poles',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c) {
                let data = null;
                c.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Pole number, type or status"></div><div class="on-list">${onSpin}</div>`;
                const list = $('.on-list', c);
                const draw = (q = '') => {
                    q = q.trim().toLowerCase().replace(/^#/, '');
                    const rows = data.poles.filter((p) => !q || String(p.id) === q || [p.label, p.status, 'pole ' + p.id].join(' ').toLowerCase().includes(q));
                    list.innerHTML = rows.length ? `<div class="group">${rows.slice(0, 200).map((p) => `
                        <div class="row tap" data-pole="${p.id}">
                            <div class="grow"><div class="title" data-no-i18n>Pole #${p.id} · ${esc(p.label || '')}</div><div class="sub">${onNum(p.height, 0)} m · ${(p.equipment || []).length} kit · ${p.fibres || 0} fibres</div></div>
                            ${p.faults && p.faults.length ? `<span class="on-pill" style="--c:#ff3b30">${p.faults.length} fault${p.faults.length > 1 ? 's' : ''}</span>` : ''}
                            ${onPill(ON_POLE_STATUS, p.status)}
                        </div>`).join('')}</div>` : UI.empty('fa-solid fa-tower-observation', 'No Poles', q ? 'Nothing matches your search.' : '');
                };
                (async () => {
                    data = await onRpc('opsnetPoles');
                    if (!data) return;
                    if (data.error) return onError(list, data);
                    draw();
                })();
                $('input', c).addEventListener('input', debounce((e) => data && !data.error && draw(e.target.value), 150));
                list.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-pole]');
                    if (r) OnPages.pole(nav, data.poles.find((p) => p.id === +r.dataset.pole));
                });
            },
        });
    },

    pole(nav, p) {
        if (!p) return;
        nav.push({
            title: 'Pole #' + p.id,
            grouped: true,
            render(c) {
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        <div class="row tap has-icon" data-act="gps"><span class="ri" style="background:#007aff"><i class="fa-solid fa-location-arrow"></i></span><div class="grow tint">Set Waypoint</div></div>
                    </div>
                    <div class="group">
                        ${onKv('Type', p.label || p.model)}
                        ${onKv('Status', (ON_POLE_STATUS[p.status] || [p.status])[0])}
                        ${onKv('Height', onNum(p.height, 1) + ' m')}
                        ${onKv('Lit', p.lit ? 'Yes' : 'No')}
                        ${onKv('Fibres', p.fibres || 0)}
                        ${onKv('Cables', p.cables || 0)}
                    </div>
                    <div class="group-header">Equipment</div>
                    <div class="group">${(p.equipment || []).map((k) => `<div class="row"><span class="on-dot" style="background:${k.lit ? '#34c759' : '#8e8e93'}"></span><div class="grow"><div class="title" data-no-i18n>${esc(k.label)} #${k.id}</div><div class="sub">${onNum(k.height, 1)} m up · ${k.lit ? 'Lit' : 'Dark'}</div></div></div>`).join('') || '<div class="row muted">Nothing mounted</div>'}</div>
                    <div class="group-header">Faults</div>
                    <div class="group">${(p.faults || []).map((f) => `<div class="row ${onHas('faults.view') ? 'tap' : ''}" data-fault="${f.id}"><div class="grow"><div class="title" data-no-i18n>#${f.id}${f.label ? ' · ' + esc(f.label) : ''}</div></div>${f.status ? onPill(ON_FAULT_STATUS, f.status) : ''}</div>`).join('') || '<div class="row muted">No faults</div>'}</div>`;
                c.addEventListener('click', (e) => {
                    if (e.target.closest('[data-act=gps]')) onWaypoint(p.x, p.y);
                    const f = e.target.closest('[data-fault]');
                    if (f && onHas('faults.view')) OnPages.fault(nav, +f.dataset.fault);
                });
            },
        });
    },

    earnings(nav) {
        nav.push({
            title: 'Earnings',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c) {
                c.innerHTML = onSpin;
                (async () => {
                    const d = await onRpc('opsnetEarnings');
                    if (!d) return;
                    if (d.error) return onError(c, d);
                    c.innerHTML = `
                        <div class="on-tiles" style="margin-top:12px"><div><b>${fmtMoney(d.week)}</b><span>Last 7 days</span></div><div><b>${fmtMoney(d.total)}</b><span>All time</span></div><div><b>${d.jobs}</b><span>Jobs paid</span></div></div>
                        <div class="group-header">History</div>
                        <div class="group">${d.payments.map((p) => `
                            <div class="row"><div class="grow"><div class="title" data-no-i18n>${esc(p.label)}</div><div class="sub">${onWhen(p.created_at)}${p.bonus ? ` · incl. ${fmtMoney(p.bonus)} bonus` : ''}</div></div><span class="value" style="color:#34c759">+${fmtMoney(p.amount + p.bonus)}</span></div>`).join('') || '<div class="row muted">No payments yet</div>'}</div>
                        <div class="group-header">Current Rates</div>
                        <div class="group">${['low', 'medium', 'high', 'critical'].map((k) => onKv(ON_SEV[k][0] + ' fault', fmtMoney(d.rates.BySeverity[k]))).join('')}
                            ${onKv('Planned work (default)', fmtMoney(d.rates.Planned))}
                            ${d.rates.Bonus.Enabled ? onKv('Quick-fix bonus', `${fmtMoney(d.rates.Bonus.Amount)} within ${d.rates.Bonus.Hours} h`) : ''}</div>`;
                })();
            },
        });
    },

    rangetest(nav) {
        nav.push({
            title: 'Range Test',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c, ctx) {
                let models = [], sel = 0, busy = false;
                ctx.opts.onLeave = () => nui('opsnetRangeClear');
                c.innerHTML = onSpin;
                const chart = (r) => {
                    const S = 230, C = S / 2, R = C - 14, k = R / Math.max(1, r.range);
                    const pt = (a, d) => [C + Math.sin((a * Math.PI) / 180) * d * k, C - Math.cos((a * Math.PI) / 180) * d * k];
                    const poly = r.rays.map((x) => pt(x.angle, x.distance).map((n) => n.toFixed(1)).join(',')).join(' ');
                    return `<svg class="on-radar" viewBox="0 0 ${S} ${S}">
                        ${[0.25, 0.5, 0.75, 1].map((f) => `<circle cx="${C}" cy="${C}" r="${(R * f).toFixed(1)}" class="g"/>`).join('')}
                        <line x1="${C}" y1="${C - R}" x2="${C}" y2="${C + R}" class="g"/><line x1="${C - R}" y1="${C}" x2="${C + R}" y2="${C}" class="g"/>
                        <polygon points="${poly}" class="cov"/>
                        ${r.rays.map((x) => { const [px, py] = pt(x.angle, x.distance); return `<circle cx="${px.toFixed(1)}" cy="${py.toFixed(1)}" r="2.6" class="${x.walls ? 'hit' : 'free'}"/>`; }).join('')}
                        <circle cx="${C}" cy="${C}" r="4" class="ap"/>
                        <text x="${C}" y="10" class="t">N</text><text x="${C + R + 8}" y="${C + 4}" class="t">E</text><text x="${C}" y="${S - 2}" class="t">S</text><text x="${C - R - 8}" y="${C + 4}" class="t">W</text>
                        <text x="${C + 4}" y="${C - R + 12}" class="s">${Math.round(r.range)} m</text>
                    </svg>`;
                };
                const draw = (result) => {
                    const m = models[sel];
                    c.innerHTML = `
                        <div class="group-header" style="margin-top:12px">Access Point Model</div>
                        <div class="group">${models.map((x, i) => `<div class="row tap" data-m="${i}"><div class="grow"><div class="title" data-no-i18n>${esc(x.label)}</div><div class="sub">Nominal range ${Math.round(x.range)} m</div></div>${i === sel ? '<i class="fa-solid fa-check check"></i>' : ''}</div>`).join('')}</div>
                        <div style="margin:0 16px 26px"><button class="btn block" data-act="run" ${busy ? 'disabled' : ''}>${busy ? '<span class="btn-spin"></span>Testing…' : '<i class="fa-solid fa-satellite-dish"></i> Run Test Here'}</button></div>
                        ${result ? `
                            <div class="on-tiles"><div><b>${onNum(result.min, 0)} m</b><span>Min</span></div><div><b>${onNum(result.avg, 0)} m</b><span>Average</span></div><div><b>${onNum(result.max, 0)} m</b><span>Max</span></div></div>
                            <div class="group" style="padding:12px;display:grid;place-items:center">${chart(result)}</div>
                            <div class="group-footer">${esc(m ? m.label : '')}: estimated coverage from where you stand, walls and objects cut the signal. The ring is shown in the world for ${result.seconds} s.</div>
                            <div class="group-header">By Direction</div>
                            <div class="group">${result.rays.map((x) => `<div class="row"><div class="grow" data-no-i18n>${onCompass(x.angle)} <span class="muted">${Math.round(x.angle)}°</span></div><span class="muted on-walls">${x.walls ? x.walls + (x.walls > 1 ? ' obstacles' : ' obstacle') : 'clear'}</span><span class="value" data-no-i18n>${onNum(x.distance, 0)} m</span></div>`).join('')}</div>` : '<div class="group-footer" style="margin-top:-14px">Stand where the access point would go, then run the test. Rays are cast at mounting height in every direction.</div>'}`;
                };
                (async () => {
                    const res = await onRpc('opsnetWifiModels');
                    if (!res) return;
                    if (res.error) return onError(c, res);
                    models = res.models || [];
                    draw(null);
                })();
                c.addEventListener('click', async (e) => {
                    const m = e.target.closest('[data-m]');
                    if (m && !busy) { sel = +m.dataset.m; return draw(null); }
                    if (!e.target.closest('[data-act=run]') || busy || !models[sel]) return;
                    busy = true;
                    draw(null);
                    const auth = await onRpc('opsnetWifiModels');
                    if (!auth || auth.error) { busy = false; return draw(null); }
                    const result = await nui('opsnetRangeTest', { range: models[sel].range, rays: 20 });
                    busy = false;
                    if (!result || !result.rays) { draw(null); return UI.alert({ title: 'Range test failed', message: 'Try again in a moment.' }); }
                    draw(result);
                });
            },
        });
    },

    admin(nav) {
        nav.push({
            title: 'Admin',
            grouped: true,
            backLabel: 'Ops-Networks',
            render(c, ctx) {
                const draw = async () => {
                    const me = OpsNet.me;
                    let pending = 0;
                    if (onAny('admin.users', 'admin.permissions')) {
                        const u = await onRpc('opsnetAdminUsers');
                        if (u && u.users) pending = u.users.filter((x) => x.pending && !x.disabled).length;
                    }
                    c.innerHTML = `
                        ${me.adminDefaultPassword ? `<div class="on-banner"><i class="fa-solid fa-shield-halved"></i><div><b>Default administrator password</b>
                            <p>${me.defaultPassword ? 'Your account still uses the default password from the server config. Change it now so nobody else can sign in as administrator.' : 'An administrator account still uses the default password. Ask its owner to change it, or reset it in Users.'}</p>
                            ${me.defaultPassword ? '<button class="btn small" data-act="pw">Change Password</button>' : ''}</div></div>` : ''}
                        <div class="group" style="margin-top:12px">
                            ${onAny('admin.users', 'admin.permissions') ? `<div class="row tap has-icon" data-p="users"><span class="ri" style="background:#007aff"><i class="fa-solid fa-users"></i></span><div class="grow">Users &amp; Permissions</div>${pending ? `<span class="on-badge">${pending}</span>` : ''}<i class="fa-solid fa-chevron-right chev"></i></div>` : ''}
                            ${onHas('admin.payments') ? '<div class="row tap has-icon" data-p="pay"><span class="ri" style="background:#34c759"><i class="fa-solid fa-sack-dollar"></i></span><div class="grow">Engineer Pay</div><i class="fa-solid fa-chevron-right chev"></i></div>' : ''}
                            ${onHas('admin.faults') ? '<div class="row tap has-icon" data-p="faults"><span class="ri" style="background:#ff3b30"><i class="fa-solid fa-triangle-exclamation"></i></span><div class="grow">Fault Engine</div><i class="fa-solid fa-chevron-right chev"></i></div>' : ''}
                            ${onAny('admin.render', 'admin.faults') ? '<div class="row tap has-icon" data-p="render"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-eye"></i></span><div class="grow">Render Distance</div><i class="fa-solid fa-chevron-right chev"></i></div>' : ''}
                        </div>`;
                };
                draw();
                ctx.opts.onResume = draw;
                const call = (name, data) => onRpc(name, data);
                c.addEventListener('click', (e) => {
                    if (e.target.closest('[data-act=pw]')) return OpsNet.changePassword();
                    const p = e.target.closest('[data-p]');
                    if (!p) return;
                    const k = p.dataset.p;
                    if (k === 'users') OnPages.users(nav);
                    if (k === 'pay') OpsNetEditors.pay(nav, { call, load: 'opsnetAdminPay', save: 'opsnetAdminSavePay', backLabel: 'Admin' });
                    if (k === 'faults') OpsNetEditors.faults(nav, { call, load: 'opsnetAdminFaults', save: 'opsnetAdminSaveFaults', trigger: 'opsnetAdminTriggerFault', close: 'opsnetAdminCloseFault', backLabel: 'Admin' });
                    if (k === 'render') OpsNetEditors.render(nav, { call, load: 'opsnetAdminRender', save: 'opsnetAdminSaveRender', backLabel: 'Admin' });
                });
            },
        });
    },

    users(nav) {
        nav.push({
            title: 'Users',
            grouped: true,
            backLabel: 'Admin',
            right: onHas('admin.users') ? '<button class="nav-btn" data-act="add"><i class="fa-solid fa-user-plus"></i></button>' : '',
            render(c, ctx) {
                let data = null;
                const row = (u) => `
                    <div class="row tap" data-user="${u.id}" style="--sep-left:68px">
                        ${avatar(u.name)}
                        <div class="grow"><div class="title" data-no-i18n>${esc(u.name)} <span class="muted" style="font-size:13px">@${esc(u.username)}</span>${u.online ? ' <span class="dev-online">online</span>' : ''}</div>
                            <div class="sub" data-no-i18n>${esc(u.role === 'custom' ? `${u.perms.length} permissions` : ((data.presets.find((p) => p.id === u.role) || {}).label || u.role))}${u.character ? ' · ' + esc(u.character) : ''}${u.defaultPassword ? ' · default password' : ''}</div></div>
                        <i class="fa-solid fa-chevron-right chev"></i>
                    </div>`;
                const draw = async () => {
                    data = await onRpc('opsnetAdminUsers');
                    if (!data) return;
                    if (data.error) return onError(c, data);
                    const pending = data.users.filter((u) => u.pending && !u.disabled);
                    const active = data.users.filter((u) => !u.pending && !u.disabled);
                    const disabled = data.users.filter((u) => u.disabled);
                    c.innerHTML = `
                        ${pending.length ? `<div class="group-header" style="margin-top:12px">Waiting For Access</div><div class="group">${pending.map(row).join('')}</div>` : ''}
                        <div class="group-header" style="${pending.length ? '' : 'margin-top:12px'}">Active</div><div class="group">${active.map(row).join('') || '<div class="row muted">Nobody yet</div>'}</div>
                        ${disabled.length ? `<div class="group-header">Disabled</div><div class="group">${disabled.map(row).join('')}</div>` : ''}`;
                };
                c.innerHTML = onSpin;
                draw();
                ctx.opts.onResume = draw;
                c.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-user]');
                    if (r && data) OnPages.user(nav, data, data.users.find((u) => u.id === +r.dataset.user));
                });
                const add = $('[data-act=add]', ctx.page);
                if (add) add.onclick = () => data && OnPages.createUser(data, draw);
            },
        });
    },

    permsHtml(data, role, perms, editable) {
        const groups = {};
        data.perms.forEach((p) => (groups[p.group] ||= []).push(p));
        const all = role === 'admin';
        return `
            <div class="group-header">Role Preset</div>
            <div class="group"><div class="row on-chips on-presets">${data.presets.map((p) => `<button data-preset="${p.id}" class="${role === p.id ? 'on' : ''}" ${editable ? '' : 'disabled'}>${esc(p.label)}</button>`).join('')}<button data-preset="custom" class="${role === 'custom' ? 'on' : ''}" ${editable ? '' : 'disabled'}>Custom</button></div></div>
            <div class="group-footer">Apply a preset, then fine-tune. Administrators always have every permission.</div>
            ${Object.entries(groups).map(([g, list]) => `<div class="group-header">${esc(g)}</div><div class="group">${list.map((p) => `
                <div class="row"><div class="grow">${esc(p.label)}<div class="sub" data-no-i18n>${esc(p.id)}</div></div>${UI.switchHtml(all || perms.includes(p.id), `data-perm="${p.id}" ${editable && !all ? '' : 'disabled'}`)}</div>`).join('')}</div>`).join('')}`;
    },

    bindPerms(root, data, state, editable) {
        root.addEventListener('click', (e) => {
            const b = e.target.closest('[data-preset]');
            if (!b || !editable) return;
            state.role = b.dataset.preset;
            const p = data.presets.find((x) => x.id === state.role);
            if (p && !p.all) state.perms = [...p.perms];
            $$('[data-preset]', root).forEach((x) => x.classList.toggle('on', x === b));
            $$('[data-perm]', root).forEach((x) => { x.checked = state.role === 'admin' || state.perms.includes(x.dataset.perm); x.disabled = state.role === 'admin'; });
        });
        root.addEventListener('change', (e) => {
            const t = e.target.closest('[data-perm]');
            if (!t || !editable) return;
            state.perms = $$('[data-perm]', root).filter((x) => x.checked).map((x) => x.dataset.perm);
            state.role = 'custom';
            $$('[data-preset]', root).forEach((x) => x.classList.toggle('on', x.dataset.preset === 'custom'));
        });
    },

    createUser(data, onDone) {
        const state = { role: 'engineer', perms: [...(data.presets.find((p) => p.id === 'engineer') || { perms: [] }).perms] };
        const editable = onHas('admin.permissions');
        UI.sheet({
            title: 'New User',
            right: 'Create',
            render(body, api) {
                body.innerHTML = `
                    <div class="group">
                        <div class="row"><span class="lbl">Username</span><input class="field" data-f="username" maxlength="24" autocomplete="off" spellcheck="false" placeholder="jsmith"></div>
                        <div class="row"><span class="lbl">Name</span><input class="field" data-f="name" maxlength="60" placeholder="John Smith"></div>
                        <div class="row"><span class="lbl">Password</span><input class="field" data-f="password" type="password" autocomplete="off" placeholder="At least 6 characters"></div>
                    </div>
                    <div class="group-footer">The account links to the first character that signs in with it.</div>
                    ${editable ? OnPages.permsHtml(data, state.role, state.perms, true) : ''}`;
                if (editable) OnPages.bindPerms(body, data, state, true);
                const check = () => api.setRightEnabled($('[data-f=username]', body).value.trim().length >= 3 && $('[data-f=password]', body).value.length >= 6);
                body.addEventListener('input', check);
                check();
            },
            async onRight(api) {
                const b = api.body;
                const res = await onRpc('opsnetAdminSaveUser', { username: $('[data-f=username]', b).value.trim(), name: $('[data-f=name]', b).value.trim(), password: $('[data-f=password]', b).value, role: state.role, perms: state.perms });
                if (!res) return;
                if (res.error) return UI.alert({ title: "Couldn't create user", message: res.error });
                api.close();
                UI.toast('User created', 'fa-solid fa-user-plus');
                onDone && onDone();
            },
        });
    },

    user(nav, data, u) {
        if (!u) return;
        const state = { role: u.role, perms: [...u.perms] };
        const canUsers = onHas('admin.users'), canPerms = onHas('admin.permissions');
        const self = OpsNet.me && OpsNet.me.id === u.id;
        nav.push({
            title: u.name,
            grouped: true,
            backLabel: 'Users',
            right: '<button class="nav-btn bold" data-act="save">Save</button>',
            render(c, ctx) {
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        ${onKv('Username', '@' + u.username)}
                        ${onKv('Character', u.character || (u.linked ? 'Linked' : 'Not linked yet'))}
                        ${onKv('Last sign-in', u.lastLogin ? onWhen(u.lastLogin) : 'Never')}
                        <div class="row"><span class="lbl">Name</span><input class="field" data-f="name" maxlength="60" value="${esc(u.name)}" ${canUsers ? '' : 'disabled'}></div>
                        <div class="row"><div class="grow">Account enabled</div>${UI.switchHtml(!u.disabled, `data-f="enabled" ${canUsers && !self ? '' : 'disabled'}`)}</div>
                    </div>
                    ${u.pending && !u.disabled ? '<div class="group-footer">Waiting for access: grant a preset or permissions below and save.</div>' : ''}
                    ${OnPages.permsHtml(data, state.role, state.perms, canPerms)}
                    ${canUsers ? `<div class="group">
                        <div class="row tap" data-act="reset"><div class="grow tint">Reset Password…</div></div>
                        ${self ? '' : '<div class="row tap" data-act="delete"><div class="grow danger">Delete User</div></div>'}
                    </div>` : ''}`;
                OnPages.bindPerms(c, data, state, canPerms);
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'reset') {
                        const pw = await UI.prompt('Reset Password', `New password for @${u.username} (at least 6 characters).`, { type: 'password' });
                        if (!pw) return;
                        const res = await onRpc('opsnetAdminResetPassword', { id: u.id, password: pw });
                        if (res && res.error) return UI.alert({ title: "Couldn't reset", message: res.error });
                        if (res) UI.toast('Password reset', 'fa-solid fa-key');
                    }
                    if (a.dataset.act === 'delete') {
                        if (!(await UI.confirm('Delete User', `@${u.username} will be removed. Their jobs go back to the available list; payment history is kept.`, 'Delete', true))) return;
                        const res = await onRpc('opsnetAdminDeleteUser', { id: u.id });
                        if (res && res.error) return UI.alert({ title: "Couldn't delete", message: res.error });
                        if (res) { UI.toast('User deleted', 'fa-solid fa-trash'); ctx.pop(); }
                    }
                });
                $('[data-act=save]', ctx.page).onclick = async () => {
                    const out = { id: u.id };
                    if (canUsers) { out.name = $('[data-f=name]', c).value.trim(); out.disabled = !$('[data-f=enabled]', c).checked; }
                    if (canPerms) { out.role = state.role; out.perms = state.perms; }
                    const res = await onRpc('opsnetAdminSaveUser', out);
                    if (!res) return;
                    if (res.error) return UI.alert({ title: "Couldn't save", message: res.error });
                    UI.toast('User saved', 'fa-solid fa-user-check');
                    if (self) OpsNet.refreshMe();
                    ctx.pop();
                };
            },
        });
    },
};

/* ---------------- app shell ---------------- */

const OPSNET_ICON = `<svg viewBox="0 0 64 64" width="44" height="44" fill="none" stroke="#fff" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round">
    <path d="M32 50V24"/><path d="M22 50l10-26 10 26"/><path d="M25 42h14"/>
    <path d="M20 16a17 17 0 0 0 0 20M44 16a17 17 0 0 1 0 20" opacity=".9"/><path d="M14 11a25 25 0 0 0 0 30M50 11a25 25 0 0 1 0 30" opacity=".55"/>
    <circle cx="32" cy="22" r="3.4" fill="#fff" stroke="none"/></svg>`;

Apps.register({
    id: 'opsnet',
    name: 'Ops-Networks',
    resumable: false,
    splash: 'linear-gradient(160deg,#0b3d91,#0a84ff 70%,#30d158)',
    icon: {
        bg: 'linear-gradient(150deg,#0b3d91,#0a84ff 65%,#30b0c7)',
        html: () => OPSNET_ICON,
    },
    async open(root, params) {
        OpsNet.root = root;
        OpsNet.params = params || null;
        root.innerHTML = '<div class="spinner" style="margin-top:300px"></div>';
        const s = onFix(await rpc('opsnetSession'));
        if (OpsNet.root !== root) return;
        OpsNet.signup = !s || s.signup !== false;
        if (s && s.loggedIn) { OpsNet.me = s.me; OpsNet.showHome(); } else OpsNet.showLogin();
    },
    onClose() { OpsNet.root = null; if (OpsNet.unsub) OpsNet.unsub(); OpsNet.unsub = null; },
});

const OpsNet = {
    root: null, me: null, params: null, signup: true, unsub: null,

    async refreshMe() {
        const s = onFix(await rpc('opsnetSession'));
        if (!this.root) return;
        if (!s || !s.loggedIn) return this.showLogin();
        const wasPending = this.me && this.me.pending;
        this.me = s.me;
        if (wasPending !== this.me.pending) this.showHome();
    },

    showLogin(mode = 'login') {
        const root = this.root;
        if (!root) return;
        this.me = null;
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: '',
            grouped: true,
            noNav: true,
            render(c) {
                const signup = mode === 'signup';
                c.innerHTML = `
                    <div class="dev-login on-login">
                        <div class="dl-icon on-icon">${OPSNET_ICON}</div>
                        <h1>Ops-Networks</h1>
                        <p>${signup ? 'Request an engineer account. An administrator has to grant you access before you can start.' : 'Sign in with your engineer account to see jobs, faults and the network.'}</p>
                        <div class="group dl-fields">
                            <div class="row"><input class="field" data-f="username" placeholder="Username" autocomplete="off" spellcheck="false" maxlength="24"></div>
                            <div class="row"><input class="field" data-f="password" type="password" placeholder="Password" autocomplete="off"></div>
                            ${signup ? '<div class="row"><input class="field" data-f="confirm" type="password" placeholder="Confirm password" autocomplete="off"></div>' : ''}
                        </div>
                        <div class="dl-error"></div>
                        <button class="btn block" data-act="go">${signup ? 'Request Account' : 'Sign In'}</button>
                        ${OpsNet.signup ? `<button class="on-link" data-act="mode">${signup ? 'Already have an account? Sign in' : 'New engineer? Request an account'}</button>` : ''}
                    </div>`;
                const user = $('[data-f=username]', c), pass = $('[data-f=password]', c), conf = $('[data-f=confirm]', c), btn = $('[data-act=go]', c), err = $('.dl-error', c);
                const check = () => { btn.disabled = !(user.value.trim() && pass.value && (!conf || conf.value)); };
                c.addEventListener('input', () => { err.textContent = ''; check(); });
                check();
                const submit = async () => {
                    if (btn.disabled) return;
                    if (conf && conf.value !== pass.value) { err.textContent = 'Passwords do not match.'; return; }
                    btn.disabled = true;
                    btn.textContent = signup ? 'Requesting…' : 'Signing In…';
                    const res = await rpc(signup ? 'opsnetSignup' : 'opsnetLogin', { username: user.value.trim(), password: pass.value });
                    btn.textContent = signup ? 'Request Account' : 'Sign In';
                    if (res && res.ok) {
                        pass.blur(); user.blur();
                        Sound.play('unlock');
                        OpsNet.me = onFix(res.me);
                        return OpsNet.showHome();
                    }
                    err.textContent = (res && res.error) || 'Something went wrong.';
                    pass.value = '';
                    if (conf) conf.value = '';
                    const box = $('.dl-fields', c);
                    box.classList.remove('shake'); void box.offsetWidth; box.classList.add('shake');
                    check();
                };
                btn.onclick = submit;
                const m = $('[data-act=mode]', c);
                if (m) m.onclick = () => OpsNet.showLogin(signup ? 'login' : 'signup');
                c.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
                setTimeout(() => user.focus(), 450);
            },
        });
    },

    async logout() {
        if (!(await UI.confirm('Log Out', 'You will need to sign in again to use Ops-Networks.', 'Log Out', true))) return;
        await rpc('opsnetLogout');
        nui('opsnetRangeClear');
        this.showLogin();
    },

    changePassword() {
        UI.sheet({
            title: 'Change Password',
            right: 'Save',
            render(body, api) {
                body.innerHTML = `
                    <div class="group">
                        <div class="row"><input class="field" data-f="current" type="password" placeholder="Current password" autocomplete="off"></div>
                        <div class="row"><input class="field" data-f="password" type="password" placeholder="New password (6+ characters)" autocomplete="off"></div>
                        <div class="row"><input class="field" data-f="confirm" type="password" placeholder="Confirm new password" autocomplete="off"></div>
                    </div>`;
                const check = () => api.setRightEnabled($('[data-f=current]', body).value && $('[data-f=password]', body).value.length >= 6 && $('[data-f=confirm]', body).value);
                body.addEventListener('input', check);
                check();
            },
            async onRight(api) {
                const b = api.body;
                if ($('[data-f=password]', b).value !== $('[data-f=confirm]', b).value) return UI.alert({ title: 'Passwords do not match' });
                const res = await onRpc('opsnetChangePassword', { current: $('[data-f=current]', b).value, password: $('[data-f=password]', b).value });
                if (!res) return;
                if (res.error) return UI.alert({ title: "Couldn't change password", message: res.error });
                api.close();
                UI.toast('Password changed', 'fa-solid fa-key');
                await OpsNet.refreshMe();
                OpsNet.showHome();
            },
        });
    },

    showPending(nav) {
        nav.push({
            title: 'Ops-Networks',
            large: true,
            grouped: true,
            left: '<button class="nav-btn" data-act="logout" style="padding-left:8px">Log Out</button>',
            render(c, ctx) {
                $('[data-act=logout]', ctx.page).onclick = () => OpsNet.logout();
                c.innerHTML = `
                    ${UI.empty('fa-solid fa-hourglass-half', 'Waiting for Access', `Hi ${OpsNet.me.name}. Your account @${OpsNet.me.username} has been created. An administrator needs to grant you access before you can see jobs and the network.`)}
                    <div style="margin:0 16px"><button class="btn block gray" data-act="refresh"><i class="fa-solid fa-rotate"></i> Check Again</button></div>`;
                $('[data-act=refresh]', c).onclick = async () => {
                    await OpsNet.refreshMe();
                    if (OpsNet.me && OpsNet.me.pending) UI.toast('Still waiting for an administrator', 'fa-solid fa-hourglass-half');
                };
            },
        });
    },

    showHome() {
        const root = this.root;
        if (!root || !this.me) return;
        root.innerHTML = '';
        const nav = new Nav(root);
        if (this.unsub) this.unsub();
        this.unsub = Phone.on('opsnetMeChanged', () => this.refreshMe());
        if (this.me.pending) return this.showPending(nav);
        nav.push({
            title: 'Ops-Networks',
            large: true,
            grouped: true,
            left: '<button class="nav-btn" data-act="logout" style="padding-left:8px">Log Out</button>',
            render(c, ctx) {
                $('[data-act=logout]', ctx.page).onclick = () => OpsNet.logout();
                const me = OpsNet.me;
                const item = (p, page, color, icon, label, extra = '') => (onAny(...[].concat(p)) ? `<div class="row tap has-icon" data-p="${page}"><span class="ri" style="background:${color}"><i class="fa-solid ${icon}"></i></span><div class="grow">${label}</div>${extra}<i class="fa-solid fa-chevron-right chev"></i></div>` : '');
                const group = (title, rows) => (rows.join('') ? `<div class="group-header">${title}</div><div class="group">${rows.join('')}</div>` : '');
                const isAdmin = me.perms.some((p) => p.startsWith('admin.'));
                c.innerHTML = `
                    <div class="on-me">
                        ${avatar(me.name)}
                        <div class="grow"><b data-no-i18n>${esc(me.name)}</b><span data-no-i18n>@${esc(me.username)} · ${esc(me.role === 'custom' ? 'Custom access' : ({ trainee: 'Trainee', engineer: 'Engineer', senior: 'Senior engineer', noc: 'NOC', admin: 'Administrator' })[me.role] || me.role)}</span></div>
                    </div>
                    ${me.adminDefaultPassword ? '<div class="on-banner small" data-p="admin"><i class="fa-solid fa-shield-halved"></i><div><b>Default admin password in use</b><p>Open Admin to change it.</p></div></div>' : ''}
                    ${group('Work', [
                        item('jobs.view', 'jobs', '#ff9500', 'fa-clipboard-list', 'Jobs', '<span class="value" data-count="available"></span>'),
                        item(['planned.view', 'jobs.view'], 'planned', '#5856d6', 'fa-calendar-days', 'Planned Work'),
                        item('payments.view', 'earnings', '#34c759', 'fa-sack-dollar', 'Earnings'),
                    ])}
                    ${group('Network', [
                        item('faults.view', 'faults', '#ff3b30', 'fa-triangle-exclamation', 'Faults', '<span class="value" data-count="faults"></span>'),
                        item('customers.view', 'customers', '#007aff', 'fa-users', 'Customers'),
                        item('network.view', 'network', '#30b0c7', 'fa-network-wired', 'Network &amp; Equipment'),
                        item('poles.view', 'poles', '#a2845e', 'fa-tower-observation', 'Poles'),
                    ])}
                    ${group('Tools', [item('rangetest.use', 'rangetest', '#32ade6', 'fa-wifi', 'Wi-Fi Range Test')])}
                    ${isAdmin ? group('Administration', [`<div class="row tap has-icon" data-p="admin"><span class="ri" style="background:#8e8e93"><i class="fa-solid fa-user-shield"></i></span><div class="grow">Admin</div><i class="fa-solid fa-chevron-right chev"></i></div>`]) : ''}
                    <div class="group-header">Account</div>
                    <div class="group"><div class="row tap has-icon" data-act="pw"><span class="ri" style="background:#636366"><i class="fa-solid fa-key"></i></span><div class="grow">Change Password</div></div></div>`;
                const counts = async () => {
                    if (onHas('jobs.view')) {
                        const r = await onRpc('opsnetJobs', { filter: 'available' });
                        const n = $('[data-count=available]', c);
                        if (n && r && r.counts) n.textContent = r.counts.available ? `${r.counts.available} open` : '';
                    }
                    if (onHas('faults.view')) {
                        const r = await rpc('opsnetFaults', { status: 'active' });
                        const n = $('[data-count=faults]', c);
                        if (n && r && r.stats) n.textContent = r.stats.open ? `${r.stats.open} open` : '';
                    }
                };
                counts();
                ctx.opts.onResume = () => { counts(); OpsNet.refreshMe(); };
                c.addEventListener('click', (e) => {
                    if (e.target.closest('[data-act=pw]')) return OpsNet.changePassword();
                    const p = e.target.closest('[data-p]');
                    if (p && OnPages[p.dataset.p]) OnPages[p.dataset.p](nav);
                });
                // opened from a notification
                const want = OpsNet.params && OpsNet.params.page;
                OpsNet.params = null;
                if (want === 'earnings' && onHas('payments.view')) OnPages.earnings(nav);
                if (want === 'jobs' && onHas('jobs.view')) OnPages.jobs(nav);
            },
        });
    },
};
