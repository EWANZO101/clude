'use strict';
(() => {
const IN_GAME = typeof GetParentResourceName === 'function';
const RES = IN_GAME ? GetParentResourceName() : 'opslabs-mdt';
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function nui(endpoint, data = {}) {
    if (!IN_GAME) return null;
    try {
        const res = await fetch(`https://${RES}/${endpoint}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
        return await res.json().catch(() => null);
    } catch (e) { return null; }
}
/** every server action goes through this one NUI callback (client/main.lua: RegisterNUICallback('call', ...)) */
const call = (name, data) => nui('call', { name, data });

function toast(text, color = 'ok') {
    const t = document.createElement('div');
    t.className = 'toast'; t.style.setProperty('--c', `var(--${color})`); t.textContent = text;
    $('#toasts').appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; t.style.transition = 'opacity .4s'; setTimeout(() => t.remove(), 400); }, 3600);
}
function failToast(r, fallback) { if (r && r.error) { toast(r.error, 'bad'); return true; } if (!r) { toast(fallback || 'No response', 'bad'); return true; } return false; }

/** read a value out of a CAD object whose exact shape we can't be 100% sure of, trying a few common keys */
const pick = (obj, ...keys) => { for (const k of keys) { const v = k.split('.').reduce((o, p) => (o == null ? o : o[p]), obj); if (v != null && v !== '') return v; } return null; };
const citizenName = (c) => [pick(c, 'name'), pick(c, 'surname')].filter(Boolean).join(' ') || pick(c, 'fullName') || 'Unknown';
const vehicleModel = (v) => pick(v, 'model.value.value', 'model.value', 'model') || 'Unknown model';
const fmtDate = (v) => { if (!v) return ''; try { return new Date(v).toLocaleDateString(); } catch (e) { return String(v); } };
const fmtDateTime = (v) => { if (!v) return ''; try { return new Date(v).toLocaleString(); } catch (e) { return String(v); } };

/* ====================================================================== state */
const S = { screen: 'dashboard', status: null, selectedCitizen: null, penalCodes: null, citationViolations: [], dashcamActive: false };

/* ====================================================================== boot / link screen */
function renderBoot() {
    const root = $('#app');
    if (S.status && S.status.denied) {
        root.innerHTML = `<div id="frame"><div id="screen"><div class="boot"><div class="boot-box">
            <div class="brand">OPS MDT</div><h1>Access denied</h1>
            <p class="denied">You are not issued a Mobile Data Terminal.</p>
        </div></div></div></div>`;
        return;
    }
    if (!S.status || !S.status.linked) {
        root.innerHTML = `<div id="frame"><div id="screen"><div class="boot"><div class="boot-box">
            <div class="brand">OPS MDT</div><h1>Link your SnailyCAD account</h1>
            <p>Paste your personal CAD <b>User API Token</b> (CAD &rsaquo; Account Settings &rsaquo; API Tokens). Every search, BOLO, citation and warrant you make will show up as you.</p>
            <label class="field"><span>User API Token</span><input id="link-token" type="password" autocomplete="off" placeholder="••••••••••••••••••••••"></label>
            <button class="btn go" id="link-go" style="width:100%">Link account</button>
        </div></div></div></div>`;
        $('#link-go').addEventListener('click', async () => {
            toast('Link button clicked...', 'info');   // debug: confirms the click itself is registering
            const token = $('#link-token').value.trim();
            if (!token) return toast('Paste your token first.', 'bad');
            toast('Sending to server...', 'info');
            const r = await call('link', { token });
            toast(`Server replied: ${JSON.stringify(r)}`, 'info');
            if (failToast(r)) return;
            toast(`Linked as ${r.username || 'officer'}`, 'ok');
            await boot();
        });
        return;
    }
    renderShell();
}

/* ====================================================================== shell */
const NAV = [
    ['dashboard', 'Dashboard'], ['person', 'Query Person'], ['vehicle', 'Query Plate'], ['weapon', 'Query Weapon'],
    ['bolos', 'BOLOs'], ['citation', 'Write Citation'], ['warrants', 'Warrants'], ['incident', 'Incident Report'],
    ['units', 'Units'], ['calls', 'Calls'],
];

function renderShell() {
    const root = $('#app');
    root.innerHTML = `<div id="frame"><div id="screen">
        <div id="shell" class="show">
            <div id="topbar">
                <div class="title">OPS MDT</div>
                <div class="who">
                    <span class="dot ${S.status.onDuty ? 'on' : ''}"></span>
                    ${S.status.onDuty ? 'On duty' : 'Off duty in CAD'} · ${esc(S.status.username || 'Linked officer')}
                    <button class="link-btn dashcam-btn ${S.dashcamActive ? 'live' : ''}" id="dashcam">${S.dashcamActive ? '● Dashcam live' : 'Go live (dashcam)'}</button>
                    <button class="link-btn" id="unlink">Unlink</button>
                    <button class="link-btn" id="close">Close</button>
                </div>
            </div>
            <div id="nav"></div>
            <div id="view"></div>
        </div>
    </div></div>`;
    const nav = $('#nav');
    nav.innerHTML = NAV.map(([id, label]) => `<button data-nav="${id}" class="${S.screen === id ? 'on' : ''}">${esc(label)}</button>`).join('');
    nav.addEventListener('click', (e) => {
        const b = e.target.closest('[data-nav]');
        if (!b) return;
        S.screen = b.dataset.nav;
        $$('#nav button').forEach((x) => x.classList.toggle('on', x === b));
        renderView();
    });
    $('#close').addEventListener('click', () => nui('close'));
    $('#unlink').addEventListener('click', async () => {
        await call('unlink', {});
        S.status = null;
        renderBoot();
    });
    $('#dashcam').addEventListener('click', async () => {
        const btn = $('#dashcam');
        btn.disabled = true;
        const r = await nui('dashcamToggle');
        btn.disabled = false;
        if (!r || !r.ok) { toast((r && r.error) || 'Could not reach the dashcam', 'bad'); return; }
        S.dashcamActive = r.active;
        btn.textContent = S.dashcamActive ? '● Dashcam live' : 'Go live (dashcam)';
        btn.classList.toggle('live', S.dashcamActive);
        toast(S.dashcamActive ? 'Dashcam is now live on Xon Sight' : 'Dashcam stopped', S.dashcamActive ? 'bad' : 'ok');
    });
    nui('dashcamStatus').then((r) => {
        if (!r || !r.ok) return;
        S.dashcamActive = r.active;
        const btn = $('#dashcam');
        if (!btn) return;
        btn.textContent = S.dashcamActive ? '● Dashcam live' : 'Go live (dashcam)';
        btn.classList.toggle('live', S.dashcamActive);
    });
    renderView();
}

const VIEWS = {};
function renderView() {
    const v = $('#view');
    v.innerHTML = '<div class="empty">Loading…</div>';
    (VIEWS[S.screen] || (() => { v.innerHTML = '<div class="empty">Not built yet.</div>'; }))(v);
}

/* ====================================================================== dashboard */
VIEWS.dashboard = async (v) => {
    const [units, calls] = await Promise.all([call('activeOfficers', {}), call('calls', {})]);
    v.innerHTML = `<h2>Dashboard</h2><div class="grid2">
        <div class="card"><h3>Active units</h3><div id="d-units" class="list"></div></div>
        <div class="card"><h3>Active calls</h3><div id="d-calls" class="list"></div></div>
    </div>`;
    renderUnits($('#d-units'), units);
    renderCalls($('#d-calls'), calls);
};

function renderUnits(el, r) {
    if (failToast(r, 'Could not load units')) { el.innerHTML = '<div class="empty">Could not load.</div>'; return; }
    const list = Array.isArray(r.data) ? r.data : (r.data && r.data.officers) || [];
    if (!list.length) { el.innerHTML = '<div class="empty">No one on duty.</div>'; return; }
    el.innerHTML = list.map((u) => {
        const name = pick(u, 'callsign2', 'callsign') ? `${pick(u, 'callsign2', 'callsign')} · ${citizenName(pick(u, 'citizen') || u)}` : citizenName(pick(u, 'citizen') || u);
        const status = pick(u, 'status.value.value', 'status.value', 'status') || '—';
        const dept = pick(u, 'department.value.value', 'department.value') || '';
        return `<div class="item"><div class="hd"><b>${esc(name)}</b><span class="pill info">${esc(status)}</span></div><div class="d">${esc(dept)}</div></div>`;
    }).join('');
}

function renderCalls(el, r) {
    if (failToast(r, 'Could not load calls')) { el.innerHTML = '<div class="empty">Could not load.</div>'; return; }
    const list = Array.isArray(r.data) ? r.data : (r.data && r.data.calls) || [];
    if (!list.length) { el.innerHTML = '<div class="empty">No active calls.</div>'; return; }
    el.innerHTML = list.map((c) => `<div class="item"><div class="hd"><b>${esc(pick(c, 'name') || 'Call')}</b></div>
        <div class="d">${esc(pick(c, 'location') || '')} · ${esc(pick(c, 'description') || '')}</div></div>`).join('');
}

/* ====================================================================== person search */
VIEWS.person = (v) => {
    v.innerHTML = `<h2>Query Person</h2>
        <div class="row" style="margin-bottom:14px">
            <input id="p-name" placeholder="Last name, First name or DOB" style="max-width:320px">
            <button class="btn go" id="p-go">Search</button>
        </div>
        <div id="p-results" class="list"></div>`;
    const run = async () => {
        const name = $('#p-name').value.trim();
        if (!name) return;
        $('#p-results').innerHTML = '<div class="empty">Searching…</div>';
        const r = await call('searchName', { name });
        if (failToast(r, 'Search failed')) { $('#p-results').innerHTML = ''; return; }
        const list = Array.isArray(r.data) ? r.data : [r.data].filter(Boolean);
        if (!list.length) { $('#p-results').innerHTML = '<div class="empty">No matches.</div>'; return; }
        $('#p-results').innerHTML = list.map((c, i) => personCard(c, i)).join('');
        $('#p-results').querySelectorAll('[data-pick]').forEach((b) => b.addEventListener('click', () => {
            const c = list[+b.dataset.pick];
            S.selectedCitizen = { id: pick(c, 'id'), name: citizenName(c) };
            toast(`Selected ${citizenName(c)} for citations/warrants`, 'ok');
        }));
        $('#p-results').querySelectorAll('[data-records]').forEach((b) => b.addEventListener('click', async () => {
            const c = list[+b.dataset.records];
            const rr = await call('citizenRecords', { citizenId: pick(c, 'id') });
            if (failToast(rr, 'Could not load records')) return;
            const recs = Array.isArray(rr.data) ? rr.data : [];
            const box = b.closest('.item').querySelector('.records-box');
            box.hidden = !box.hidden;
            if (!box.hidden) box.innerHTML = recs.length ? recs.map(recordLine).join('') : '<div class="empty">No records.</div>';
        }));
    };
    $('#p-go').addEventListener('click', run);
    $('#p-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
};

function personCard(c, i) {
    const wanted = pick(c, 'hasWarrants') === true || (Array.isArray(pick(c, 'warrants')) && pick(c, 'warrants').length);
    return `<div class="item">
        <div class="hd"><b>${esc(citizenName(c))}</b>${wanted ? '<span class="pill bad">WANTED</span>' : ''}</div>
        <div class="kv" style="margin-top:8px">
            <b>DOB</b><span>${esc(fmtDate(pick(c, 'dateOfBirth')))}</span>
            <b>Address</b><span>${esc(pick(c, 'address') || '—')}</span>
            <b>Driver's lic.</b><span>${esc(pick(c, 'driversLicense.value', 'driversLicense') || '—')}</span>
            <b>Weapon lic.</b><span>${esc(pick(c, 'weaponLicense.value', 'weaponLicense') || '—')}</span>
        </div>
        <div class="row" style="margin-top:10px">
            <button class="btn go" data-pick="${i}">Select for citation/warrant</button>
            <button class="btn" data-records="${i}">Records</button>
        </div>
        <div class="records-box" hidden></div>
    </div>`;
}

/* ====================================================================== vehicle search */
VIEWS.vehicle = (v) => {
    v.innerHTML = `<h2>Query Plate</h2>
        <div class="row" style="margin-bottom:14px">
            <input id="v-plate" placeholder="Plate or VIN" style="max-width:220px">
            <button class="btn go" id="v-go">Search</button>
        </div>
        <div id="v-results" class="list"></div>`;
    const run = async () => {
        const plate = $('#v-plate').value.trim();
        if (!plate) return;
        $('#v-results').innerHTML = '<div class="empty">Searching…</div>';
        const r = await call('searchPlate', { plate });
        if (failToast(r, 'Search failed')) { $('#v-results').innerHTML = ''; return; }
        const list = Array.isArray(r.data) ? r.data : [r.data].filter(Boolean);
        if (!list.length) { $('#v-results').innerHTML = '<div class="empty">No matches.</div>'; return; }
        $('#v-results').innerHTML = list.map(vehicleCard).join('');
    };
    $('#v-go').addEventListener('click', run);
    $('#v-plate').addEventListener('keydown', (e) => { if (e.key === 'Enter') run(); });
};

function vehicleCard(veh) {
    const stolen = pick(veh, 'reportedStolen') === true;
    const bolo = pick(veh, 'bolo');
    return `<div class="item">
        <div class="hd"><b>${esc(vehicleModel(veh))}</b> <span class="d">${esc(pick(veh, 'plate') || '')}</span>
            ${stolen ? '<span class="pill bad">STOLEN</span>' : ''}${bolo ? '<span class="pill warn">BOLO</span>' : ''}</div>
        <div class="kv" style="margin-top:8px">
            <b>Colour</b><span>${esc(pick(veh, 'color') || '—')}</span>
            <b>Owner</b><span>${esc(citizenName(pick(veh, 'citizen') || {}) || '—')}</span>
            <b>Registration</b><span>${esc(pick(veh, 'registrationStatus.value.value', 'registrationStatus.value') || '—')}</span>
            <b>Insurance</b><span>${esc(pick(veh, 'insuranceStatus.value.value', 'insuranceStatus.value') || '—')}</span>
        </div>
    </div>`;
}

/* ====================================================================== weapon search */
VIEWS.weapon = (v) => {
    v.innerHTML = `<h2>Query Weapon</h2>
        <div class="row" style="margin-bottom:14px">
            <input id="w-serial" placeholder="Serial number" style="max-width:220px">
            <button class="btn go" id="w-go">Search</button>
        </div>
        <div id="w-results" class="list"></div>`;
    $('#w-go').addEventListener('click', async () => {
        const serial = $('#w-serial').value.trim();
        if (!serial) return;
        const r = await call('searchWeapon', { serial });
        if (failToast(r, 'Search failed')) { $('#w-results').innerHTML = ''; return; }
        const w = r.data;
        if (!w) { $('#w-results').innerHTML = '<div class="empty">No match.</div>'; return; }
        $('#w-results').innerHTML = `<div class="item"><div class="hd"><b>${esc(pick(w, 'model.value.value', 'model') || 'Weapon')}</b></div>
            <div class="kv" style="margin-top:8px">
                <b>Serial</b><span>${esc(pick(w, 'serialNumber') || '')}</span>
                <b>Registered to</b><span>${esc(citizenName(pick(w, 'citizen') || {}) || '—')}</span>
                <b>Status</b><span>${esc(pick(w, 'status') || '—')}</span>
            </div></div>`;
    });
};

/* ====================================================================== BOLOs */
VIEWS.bolos = async (v) => {
    v.innerHTML = `<h2>BOLOs</h2><div class="grid2">
        <div class="card"><h3>Active BOLOs</h3><div id="b-list" class="list"></div></div>
        <div class="card"><h3>Create BOLO</h3>
            <label class="field"><span>Type</span><select id="b-type"><option value="VEHICLE">Vehicle</option><option value="PERSON">Person</option><option value="OTHER">Other</option></select></label>
            <div id="b-fields"></div>
            <label class="field"><span>Description</span><textarea id="b-desc"></textarea></label>
            <button class="btn go" id="b-go" style="width:100%">Post BOLO</button>
        </div>
    </div>`;
    const fields = () => {
        const t = $('#b-type').value;
        $('#b-fields').innerHTML = t === 'PERSON'
            ? '<label class="field"><span>Name</span><input id="b-name"></label>'
            : t === 'VEHICLE'
                ? '<label class="field"><span>Plate</span><input id="b-plate"></label><label class="field"><span>Model</span><input id="b-model"></label><label class="field"><span>Colour</span><input id="b-color"></label>'
                : '';
    };
    $('#b-type').addEventListener('change', fields);
    fields();
    $('#b-go').addEventListener('click', async () => {
        const desc = $('#b-desc').value.trim();
        if (!desc) return toast('Description is required.', 'bad');
        const body = { type: $('#b-type').value, description: desc, name: $('#b-name') && $('#b-name').value, plate: $('#b-plate') && $('#b-plate').value, model: $('#b-model') && $('#b-model').value, color: $('#b-color') && $('#b-color').value };
        const r = await call('createBolo', body);
        if (failToast(r, 'Could not post BOLO')) return;
        toast('BOLO posted.', 'ok');
        loadBolos();
    });
    async function loadBolos() {
        const r = await call('bolos', {});
        if (failToast(r, 'Could not load BOLOs')) { $('#b-list').innerHTML = ''; return; }
        const list = Array.isArray(r.data) ? r.data : (r.data && r.data.bolos) || [];
        $('#b-list').innerHTML = list.length ? list.map((b) => `<div class="item">
            <div class="hd"><b>${esc(b.type || '')}</b> <span class="pill warn">${esc(b.plate || b.name || '')}</span></div>
            <div class="d">${esc(b.description || '')}${b.color || b.model ? ` · ${esc([b.color, b.model].filter(Boolean).join(' '))}` : ''}</div>
        </div>`).join('') : '<div class="empty">No active BOLOs.</div>';
    }
    loadBolos();
};

/* ====================================================================== citation */
VIEWS.citation = (v) => {
    S.citationViolations = [];
    v.innerHTML = `<h2>Write Citation</h2>
        <div class="card" style="max-width:640px">
            ${S.selectedCitizen ? `<div class="d" style="margin-bottom:10px">For: <b>${esc(S.selectedCitizen.name)}</b></div>` : ''}
            <label class="field"><span>Citizen ID ${S.selectedCitizen ? '(from Query Person)' : '(search a person first, or paste one)'}</span><input id="c-citizen" value="${esc(S.selectedCitizen ? S.selectedCitizen.id : '')}"></label>
            <label class="field"><span>Type</span><select id="c-type"><option value="TICKET">Ticket</option><option value="WRITTEN_WARNING">Written warning</option><option value="ARREST_REPORT">Arrest report</option></select></label>
            <label class="field"><span>Postal</span><input id="c-postal" placeholder="0"></label>
            <label class="field"><span>Plate (optional)</span><input id="c-plate"></label>
            <h3 style="margin-top:14px">Violations</h3>
            <div id="c-violations"></div>
            <button class="btn ghost" id="c-addv" style="margin-bottom:12px">+ Add violation</button>
            <label class="field"><span>Notes</span><textarea id="c-notes"></textarea></label>
            <button class="btn go" id="c-go" style="width:100%">File citation</button>
        </div>`;
    const row = () => {
        const i = S.citationViolations.length;
        S.citationViolations.push({ penalCodeId: '', fine: '', jailTime: '', bail: '' });
        renderViolations();
    };
    function renderViolations() {
        $('#c-violations').innerHTML = S.citationViolations.map((_, i) => `<div class="violation-row">
            <input data-vi="${i}" data-f="penalCodeId" placeholder="Penal code ID (see CAD)">
            <input data-vi="${i}" data-f="fine" placeholder="Fine" type="number">
            <input data-vi="${i}" data-f="jailTime" placeholder="Jail (mo)" type="number">
            <input data-vi="${i}" data-f="bail" placeholder="Bail" type="number">
            <button data-rm="${i}">&times;</button>
        </div>`).join('') || '<div class="empty">No violations added.</div>';
        $$('#c-violations input').forEach((inp) => inp.addEventListener('input', () => { S.citationViolations[+inp.dataset.vi][inp.dataset.f] = inp.value; }));
        $$('#c-violations [data-rm]').forEach((b) => b.addEventListener('click', () => { S.citationViolations.splice(+b.dataset.rm, 1); renderViolations(); }));
    }
    $('#c-addv').addEventListener('click', row);
    row();
    $('#c-go').addEventListener('click', async () => {
        const citizenId = $('#c-citizen').value.trim();
        if (!citizenId) return toast('Citizen ID is required.', 'bad');
        if (!S.citationViolations.length) return toast('Add at least one violation.', 'bad');
        const r = await call('createCitation', {
            citizenId, type: $('#c-type').value, postal: $('#c-postal').value || '0',
            plate: $('#c-plate').value || undefined, notes: $('#c-notes').value || undefined,
            violations: S.citationViolations,
        });
        if (failToast(r, 'Could not file citation')) return;
        toast('Citation filed.', 'ok');
    });
};

/* ====================================================================== warrants */
VIEWS.warrants = async (v) => {
    v.innerHTML = `<h2>Warrants</h2><div class="grid2">
        <div class="card"><h3>Active warrants</h3><div id="wa-list" class="list"></div></div>
        <div class="card"><h3>Issue warrant</h3>
            <label class="field"><span>Citizen ID ${S.selectedCitizen ? '(' + esc(S.selectedCitizen.name) + ')' : ''}</span><input id="wa-citizen" value="${esc(S.selectedCitizen ? S.selectedCitizen.id : '')}"></label>
            <label class="field"><span>Description</span><textarea id="wa-desc"></textarea></label>
            <button class="btn go" id="wa-go" style="width:100%">Issue warrant</button>
        </div>
    </div>`;
    async function load() {
        const r = await call('activeWarrants', {});
        if (failToast(r, 'Could not load warrants')) { $('#wa-list').innerHTML = ''; return; }
        const list = Array.isArray(r.data) ? r.data : (r.data && r.data.warrants) || [];
        $('#wa-list').innerHTML = list.length ? list.map((w) => `<div class="item" data-id="${esc(pick(w, 'id'))}">
            <div class="hd"><b>${esc(citizenName(pick(w, 'citizen') || {}))}</b><span class="pill bad">ACTIVE</span></div>
            <div class="d">${esc(pick(w, 'description') || '')}</div>
            <div class="row" style="margin-top:8px"><button class="btn" data-serve="${esc(pick(w, 'id'))}">Serve</button></div>
        </div>`).join('') : '<div class="empty">No active warrants.</div>';
        $$('[data-serve]').forEach((b) => b.addEventListener('click', async () => {
            const r2 = await call('serveWarrant', { id: b.dataset.serve });
            if (failToast(r2, 'Could not serve warrant')) return;
            toast('Warrant served.', 'ok');
            load();
        }));
    }
    $('#wa-go').addEventListener('click', async () => {
        const citizenId = $('#wa-citizen').value.trim();
        const description = $('#wa-desc').value.trim();
        if (!citizenId || !description) return toast('Citizen ID and description are required.', 'bad');
        const r = await call('createWarrant', { citizenId, description });
        if (failToast(r, 'Could not issue warrant')) return;
        toast('Warrant issued.', 'ok');
        load();
    });
    load();
};

/* ====================================================================== incident report */
VIEWS.incident = (v) => {
    v.innerHTML = `<h2>Incident Report</h2><div class="card" style="max-width:600px">
        <label class="field"><span>Postal</span><input id="i-postal"></label>
        <label class="field"><span>Description</span><textarea id="i-desc"></textarea></label>
        <div class="check"><input type="checkbox" id="i-fire"><label for="i-fire">Firearms involved</label></div>
        <div class="check"><input type="checkbox" id="i-inj"><label for="i-inj">Injuries or fatalities</label></div>
        <div class="check"><input type="checkbox" id="i-arrest"><label for="i-arrest">Arrests made</label></div>
        <button class="btn go" id="i-go" style="width:100%">File report</button>
    </div>`;
    $('#i-go').addEventListener('click', async () => {
        const description = $('#i-desc').value.trim();
        if (!description) return toast('Description is required.', 'bad');
        const r = await call('createIncident', {
            description, postal: $('#i-postal').value || undefined,
            firearmsInvolved: $('#i-fire').checked, injuriesOrFatalities: $('#i-inj').checked, arrestsMade: $('#i-arrest').checked,
        });
        if (failToast(r, 'Could not file report')) return;
        toast('Incident report filed.', 'ok');
    });
};

/* ====================================================================== units / calls (standalone screens, dashboard already shows a summary) */
VIEWS.units = async (v) => { v.innerHTML = '<h2>Units</h2><div id="u-list" class="list"></div>'; renderUnits($('#u-list'), await call('activeOfficers', {})); };
VIEWS.calls = async (v) => { v.innerHTML = '<h2>Calls</h2><div id="c2-list" class="list"></div>'; renderCalls($('#c2-list'), await call('calls', {})); };

function recordLine(r) {
    return `<div class="d" style="margin-top:4px">${esc(fmtDateTime(pick(r, 'createdAt')))} · ${esc(pick(r, 'type') || '')} · ${esc(pick(r, 'notes') || '')}</div>`;
}

/* ====================================================================== boot sequence */
async function boot() {
    S.status = await call('status', {});
    renderBoot();
}

window.addEventListener('message', (e) => {
    const m = e.data || {};
    if (m.action === 'open') {
        $('#app').hidden = false; $('#app').classList.add('show');
        if (m.status) { S.status = m.status; renderBoot(); } else boot();
    } else if (m.action === 'close') { $('#app').classList.remove('show'); $('#app').hidden = true; }
});
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('#app').classList.contains('show')) nui('close'); });

if (!IN_GAME) { $('#app').hidden = false; $('#app').classList.add('show'); S.status = { linked: false }; renderBoot(); }
})();
