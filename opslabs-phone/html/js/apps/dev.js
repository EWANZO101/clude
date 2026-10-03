'use strict';

/*
 * Developer app (admins only — the server checks every action).
 * Map locations + GTA blips, live coordinates, teleport, global wallpapers,
 * phone numbers, broadcast notifications and an FPS meter.
 */

const DEV_ICONS = [
    'fa-location-dot', 'fa-house', 'fa-building', 'fa-store', 'fa-cart-shopping', 'fa-utensils', 'fa-mug-hot', 'fa-martini-glass',
    'fa-gas-pump', 'fa-car', 'fa-screwdriver-wrench', 'fa-warehouse', 'fa-hospital', 'fa-building-shield', 'fa-fire-extinguisher', 'fa-gavel',
    'fa-building-columns', 'fa-shirt', 'fa-scissors', 'fa-dumbbell', 'fa-tree', 'fa-umbrella-beach', 'fa-plane', 'fa-ship',
    'fa-train', 'fa-music', 'fa-dice', 'fa-gun', 'fa-briefcase', 'fa-graduation-cap', 'fa-church', 'fa-star',
];
const DEV_CATEGORIES = ['General', 'Business', 'Food & Drink', 'Government', 'Emergency', 'Vehicles', 'Leisure', 'Transport', 'Housing'];
const BLIP_SPRITES = [[1, 'Standard'], [40, 'House'], [50, 'Garage'], [52, 'Store'], [60, 'Police'], [61, 'Hospital'], [68, 'Tow'], [71, 'Barber'],
    [73, 'Clothes'], [75, 'Tattoo'], [93, 'Bar'], [106, 'Bank'], [110, 'Ammu-Nation'], [225, 'Car'], [280, 'Person'], [361, 'Gas'], [446, 'Wrench'], [475, 'Building'], [500, 'Money']];
const BLIP_COLORS = [[0, 'White', '#ffffff'], [1, 'Red', '#e03232'], [2, 'Green', '#71cb71'], [3, 'Blue', '#5db6e5'], [5, 'Yellow', '#eec64e'],
    [17, 'Orange', '#eb8c3c'], [27, 'Purple', '#a55ad2'], [8, 'Pink', '#f19ed2'], [38, 'Dark Blue', '#2c6db8'], [40, 'Grey', '#4c4c4c']];

function copyText(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
    ta.remove();
    UI.toast(ok ? 'Copied' : text, ok ? 'fa-solid fa-copy' : 'fa-solid fa-circle-info');
}

/** rpc wrapper: if the server says the session is gone, return to the login screen */
async function devRpc(name, data) {
    const res = await rpc(name, data);
    if (res && res.loggedOut) {
        UI.alert({ title: 'Signed Out', message: 'Your Developer session has ended. Please sign in again.' });
        if (DevApp.root) DevApp.showLogin();
        return null;
    }
    return res;
}

const fmtN = (n) => (n == null || isNaN(n) ? '—' : Number(n).toFixed(2));

/* ---------------- FPS meter ---------------- */
const FpsMeter = {
    el: null, raf: null,
    toggle(on) {
        if (!on) { cancelAnimationFrame(this.raf); this.el && this.el.remove(); this.el = null; return; }
        if (this.el) return;
        this.el = el('<div class="fps-meter">-- fps</div>');
        $('#screen').appendChild(this.el);
        let frames = 0, last = performance.now(), worst = 0, prev = last;
        const loop = (t) => {
            frames++;
            worst = Math.max(worst, t - prev);
            prev = t;
            if (t - last >= 1000) {
                const fps = Math.round((frames * 1000) / (t - last));
                this.el.textContent = `${fps} fps · ${Math.round(worst)}ms`;
                this.el.classList.toggle('bad', fps < 40);
                frames = 0; worst = 0; last = t;
            }
            this.raf = requestAnimationFrame(loop);
        };
        this.raf = requestAnimationFrame(loop);
    },
};

/* ---------------- location editor ---------------- */
function DevPlaceEditor(place, onSaved) {
    const p = place ? { ...place } : { name: '', icon: 'fa-location-dot', category: 'General', blip: false, blipSprite: 1, blipColor: 0 };
    const isNew = !p.id;
    let pos = p.coords ? { ...p.coords } : null;
    UI.sheet({
        title: isNew ? 'New Location' : 'Edit Location',
        right: 'Save',
        render(body, api) {
            body.innerHTML = `
                <div class="group">
                    <div class="row"><input class="field" data-f="name" placeholder="Location name" value="${esc(p.name)}"></div>
                    <div class="row"><span class="lbl">Category</span><select class="field" data-f="category">${DEV_CATEGORIES.map((c) => `<option ${c === p.category ? 'selected' : ''}>${esc(c)}</option>`).join('')}</select></div>
                </div>
                <div class="group-header">Icon</div>
                <div class="group" style="padding:12px"><div class="dev-icons">${DEV_ICONS.map((i) => `<button data-icon="${i}" class="${i === p.icon ? 'on' : ''}"><i class="fa-solid ${i}"></i></button>`).join('')}</div></div>
                <div class="group-header">Position</div>
                <div class="group">
                    <div class="row"><div class="grow dev-pos">${pos ? `${fmtN(pos.x)}, ${fmtN(pos.y)}, ${fmtN(pos.z)}` : 'Getting your position…'}</div></div>
                    <div class="row tap" data-act="here"><span class="tint grow">Use My Current Position</span><i class="fa-solid fa-location-crosshairs tint"></i></div>
                    <div class="row tap" data-act="manual"><span class="tint grow">Enter Coordinates…</span><i class="fa-solid fa-keyboard tint"></i></div>
                </div>
                <div class="group-header">GTA Map Blip</div>
                <div class="group">
                    <div class="row"><div class="grow">Show blip for everyone</div>${UI.switchHtml(p.blip, 'data-f="blip"')}</div>
                    <div class="row"><span class="lbl">Sprite</span><select class="field" data-f="blipSprite">${BLIP_SPRITES.map(([v, l]) => `<option value="${v}" ${v === +p.blipSprite ? 'selected' : ''}>${l} (${v})</option>`).join('')}${BLIP_SPRITES.some(([v]) => v === +p.blipSprite) ? '' : `<option value="${+p.blipSprite}" selected>Custom (${+p.blipSprite})</option>`}</select></div>
                    <div class="row"><span class="lbl">Colour</span><div class="dev-colors">${BLIP_COLORS.map(([v, l, c]) => `<button data-color="${v}" title="${l}" class="${v === +p.blipColor ? 'on' : ''}" style="background:${c}"></button>`).join('')}</div></div>
                </div>
                <div class="group-footer">Locations appear in everyone's Maps app instantly. Blips use GTA blip sprite IDs.</div>`;
            const setPos = (c) => { pos = { x: c.x, y: c.y, z: c.z }; $('.dev-pos', body).textContent = `${fmtN(pos.x)}, ${fmtN(pos.y)}, ${fmtN(pos.z)}`; };
            if (!pos) nui('getLocation').then((c) => c && setPos(c));
            const check = () => api.setRightEnabled($('[data-f=name]', body).value.trim().length > 0);
            body.addEventListener('input', check);
            check();
            body.addEventListener('click', async (e) => {
                const ic = e.target.closest('[data-icon]');
                if (ic) { p.icon = ic.dataset.icon; $$('[data-icon]', body).forEach((b) => b.classList.toggle('on', b === ic)); return; }
                const col = e.target.closest('[data-color]');
                if (col) { p.blipColor = +col.dataset.color; $$('[data-color]', body).forEach((b) => b.classList.toggle('on', b === col)); return; }
                const a = e.target.closest('[data-act]');
                if (!a) return;
                if (a.dataset.act === 'here') { const c = await nui('getLocation'); if (c) setPos(c); }
                if (a.dataset.act === 'manual') {
                    const v = await UI.prompt('Coordinates', 'x, y, z', { value: pos ? `${fmtN(pos.x)}, ${fmtN(pos.y)}, ${fmtN(pos.z)}` : '' });
                    const n = (v || '').replace(/vec[34]?\(|\)/g, '').split(',').map((x) => parseFloat(x));
                    if (n.length >= 3 && n.slice(0, 3).every((x) => !isNaN(x))) setPos({ x: n[0], y: n[1], z: n[2] });
                    else if (v) UI.alert({ title: 'Invalid coordinates', message: 'Use the format: 123.4, -567.8, 30.0' });
                }
            });
            if (isNew) setTimeout(() => $('[data-f=name]', body).focus(), 350);
        },
        async onRight(api) {
            const b = api.body;
            if (!pos) return UI.alert({ title: 'No position yet', message: 'Tap "Use My Current Position".' });
            const res = await devRpc('devSavePlace', {
                id: p.id,
                name: $('[data-f=name]', b).value.trim(),
                category: $('[data-f=category]', b).value,
                icon: p.icon,
                x: pos.x, y: pos.y, z: pos.z,
                blip: $('[data-f=blip]', b).checked,
                blipSprite: +$('[data-f=blipSprite]', b).value,
                blipColor: p.blipColor,
            });
            if (!res || res.error) return UI.alert({ title: "Couldn't save", message: (res && res.error) || '' });
            api.close();
            UI.toast(isNew ? 'Location added' : 'Location saved', 'fa-solid fa-location-dot');
            onSaved && onSaved();
        },
    });
}

/* ---------------- pages ---------------- */
const DevPages = {
    locations(nav) {
        nav.push({
            title: 'Map Locations',
            grouped: true,
            backLabel: 'Developer',
            right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
            render(c, ctx) {
                const draw = () => {
                    const all = Phone.config.places || [];
                    const mine = all.filter((p) => p.source === 'db');
                    const cfg = all.filter((p) => p.source !== 'db');
                    const cats = {};
                    mine.forEach((p) => (cats[p.category || 'General'] ||= []).push(p));
                    const row = (p, editable) => `
                        <div class="row ${editable ? 'tap' : ''} has-icon" ${editable ? `data-place="${p.id}"` : ''}>
                            <span class="ri" style="background:#ff3b30;border-radius:50%"><i class="fa-solid ${esc(p.icon || 'fa-location-dot')}"></i></span>
                            <div class="grow"><div class="title">${esc(p.name)}${p.blip ? ' <i class="fa-solid fa-map-pin muted" style="font-size:11px" title="Has blip"></i>' : ''}</div>
                                <div class="sub">${fmtN(p.coords.x)}, ${fmtN(p.coords.y)}, ${fmtN(p.coords.z)}</div></div>
                            ${editable ? '<i class="fa-solid fa-ellipsis muted"></i>' : ''}
                        </div>`;
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px"><div class="row tap" data-act="addhere"><span class="ri" style="background:#34c759"><i class="fa-solid fa-plus"></i></span><span class="tint grow">Add Location Here</span></div></div>
                        ${Object.keys(cats).sort().map((k) => `<div class="group-header">${esc(k)}</div><div class="group">${cats[k].map((p) => row(p, true)).join('')}</div>`).join('') ||
                            '<div class="group-footer" style="margin-top:-20px">No locations added in-game yet.</div>'}
                        <div class="group-header">From config.lua</div>
                        <div class="group">${cfg.map((p) => row(p, false)).join('') || '<div class="row muted">None</div>'}</div>
                        <div class="group-footer">Config locations are edited in config.lua (Config.Places).</div>`;
                };
                draw();
                const unsub = Phone.on('placesUpdated', draw);
                ctx.opts.onLeave = unsub;
                ctx.page.addEventListener('click', async (e) => {
                    if (e.target.closest('[data-act=add], [data-act=addhere]')) return DevPlaceEditor(null);
                    const r = e.target.closest('[data-place]');
                    if (!r) return;
                    const p = (Phone.config.places || []).find((x) => x.id === +r.dataset.place && x.source === 'db');
                    if (!p) return;
                    const i = await UI.actionSheet(p.name, [{ label: 'Edit' }, { label: 'Set GPS' }, { label: 'Teleport' }, { label: 'Copy Coordinates' }, { label: 'Delete', destructive: true }]);
                    if (i === 0) DevPlaceEditor(p);
                    if (i === 1) { nui('setWaypoint', { x: p.coords.x, y: p.coords.y }); }
                    if (i === 2) devRpc('devTeleport', p.coords);
                    if (i === 3) copyText(`vec3(${fmtN(p.coords.x)}, ${fmtN(p.coords.y)}, ${fmtN(p.coords.z)})`);
                    if (i === 4 && (await UI.confirm('Delete Location', `"${p.name}" will be removed from everyone's Maps.`, 'Delete', true))) {
                        await devRpc('devDeletePlace', { id: p.id });
                        UI.toast('Deleted', 'fa-solid fa-trash');
                    }
                });
            },
        });
    },

    coords(nav) {
        nav.push({
            title: 'Coordinates',
            grouped: true,
            backLabel: 'Developer',
            render(c) {
                c.innerHTML = `
                    <div class="dev-coords">
                        <div><span>X</span><b data-c="x">—</b></div><div><span>Y</span><b data-c="y">—</b></div>
                        <div><span>Z</span><b data-c="z">—</b></div><div><span>Heading</span><b data-c="h">—</b></div>
                    </div>
                    <div class="group"><div class="row"><div class="grow"><div class="title" data-c="street">—</div><div class="sub" data-c="zone"></div></div></div></div>
                    <div class="group">
                        <div class="row tap" data-copy="vec3"><span class="tint grow">Copy as vec3</span><i class="fa-regular fa-copy tint"></i></div>
                        <div class="row tap" data-copy="vec4"><span class="tint grow">Copy as vec4 (with heading)</span><i class="fa-regular fa-copy tint"></i></div>
                        <div class="row tap" data-copy="json"><span class="tint grow">Copy as JSON</span><i class="fa-regular fa-copy tint"></i></div>
                    </div>
                    <div class="group"><div class="row tap" data-act="save"><span class="tint grow">Save as Map Location</span><i class="fa-solid fa-location-dot tint"></i></div></div>`;
                let cur = null;
                const update = async () => {
                    if (!document.body.contains(c)) return clearInterval(iv);
                    if (Phone.state !== 'open') return;
                    const p = await nui('getLocation');
                    if (!p) return;
                    cur = p;
                    $('[data-c=x]', c).textContent = fmtN(p.x);
                    $('[data-c=y]', c).textContent = fmtN(p.y);
                    $('[data-c=z]', c).textContent = fmtN(p.z);
                    $('[data-c=h]', c).textContent = fmtN(p.h || 0);
                    $('[data-c=street]', c).textContent = (p.street || '') + (p.cross ? ' & ' + p.cross : '');
                    $('[data-c=zone]', c).textContent = p.zone || '';
                };
                const iv = setInterval(update, 500);
                update();
                c.addEventListener('click', (e) => {
                    if (!cur) return;
                    const cp = e.target.closest('[data-copy]');
                    if (cp) {
                        const t = { vec3: `vec3(${fmtN(cur.x)}, ${fmtN(cur.y)}, ${fmtN(cur.z)})`, vec4: `vec4(${fmtN(cur.x)}, ${fmtN(cur.y)}, ${fmtN(cur.z)}, ${fmtN(cur.h || 0)})`, json: JSON.stringify({ x: +fmtN(cur.x), y: +fmtN(cur.y), z: +fmtN(cur.z), h: +fmtN(cur.h || 0) }) }[cp.dataset.copy];
                        copyText(t);
                    }
                    if (e.target.closest('[data-act=save]')) DevPlaceEditor({ name: cur.street || '', icon: 'fa-location-dot', category: 'General', coords: { x: cur.x, y: cur.y, z: cur.z }, blip: false, blipSprite: 1, blipColor: 0 });
                });
            },
        });
    },

    wallpapers(nav) {
        nav.push({
            title: 'Wallpapers',
            grouped: true,
            backLabel: 'Developer',
            right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
            render(c, ctx) {
                const draw = () => {
                    const all = Phone.config.wallpapers || [];
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px;padding:14px"><div class="wp-grid">${all.map((w) => `
                            <div class="wp-item ${w.dbId ? 'custom' : ''}" style="background:${w.css}"><span>${esc(w.label)}</span>
                                ${w.dbId ? `<button class="wp-del" data-del="${w.dbId}"><i class="fa-solid fa-xmark"></i></button>` : ''}</div>`).join('')}</div></div>
                        <div class="group-footer" style="margin-top:-20px">Wallpapers you add here appear for everyone in Settings → Wallpaper. Built-in ones are in config.lua.</div>`;
                };
                draw();
                const unsub = Phone.on('wallpapersUpdated', draw);
                ctx.opts.onLeave = unsub;
                ctx.page.addEventListener('click', async (e) => {
                    const d = e.target.closest('[data-del]');
                    if (d) {
                        if (await UI.confirm('Remove Wallpaper', 'Players using it will fall back to the default.', 'Remove', true)) await devRpc('devDeleteWallpaper', { id: +d.dataset.del });
                        return;
                    }
                    if (!e.target.closest('[data-act=add]')) return;
                    const url = await UI.prompt('Add Wallpaper', 'Image URL (portrait works best)', { placeholder: 'https://' });
                    if (!url) return;
                    const label = await UI.prompt('Name', '', { value: 'Custom' });
                    const res = await devRpc('devAddWallpaper', { url, label: label || 'Custom' });
                    if (!res || res.error) UI.alert({ title: "Couldn't add", message: (res && res.error) || '' });
                    else UI.toast('Wallpaper added', 'fa-solid fa-image');
                });
            },
        });
    },

    numbers(nav) {
        nav.push({
            title: 'Phone Numbers',
            grouped: true,
            backLabel: 'Developer',
            render(c) {
                c.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Name, number or email"></div><div class="dev-users"></div>`;
                const list = $('.dev-users', c);
                let rows = [];
                const search = debounce(async (q) => {
                    if (q.trim().length < 2) { list.innerHTML = '<div class="group-footer" style="margin-top:0">Type at least 2 characters.</div>'; return; }
                    rows = (await devRpc('devFindUsers', { query: q })) || [];
                    list.innerHTML = rows.length ? `<div class="group">${rows.map((r, i) => `
                        <div class="row tap" data-i="${i}" style="--sep-left:68px">
                            ${avatar(r.name || r.number)}
                            <div class="grow"><div class="title">${esc(r.name || 'Unknown')} ${r.online ? '<span class="dev-online">online</span>' : ''}</div><div class="sub">${esc(r.number)} · ${esc(r.email || '')}</div></div>
                            <i class="fa-solid fa-pen muted"></i>
                        </div>`).join('')}</div>` : '<div class="group-footer" style="margin-top:0">No phones found.</div>';
                }, 300);
                $('input', c).addEventListener('input', (e) => search(e.target.value));
                search('');
                list.addEventListener('click', async (e) => {
                    const r = e.target.closest('[data-i]');
                    if (!r) return;
                    const u = rows[+r.dataset.i];
                    const n = await UI.prompt('Change Number', `${u.name || u.number} — current: ${u.number}. Messages, calls and contacts move with it.`, { value: u.number });
                    if (!n || n === u.number) return;
                    const res = await devRpc('devSetNumber', { number: u.number, newNumber: n });
                    if (!res || res.error) return UI.alert({ title: "Couldn't change number", message: (res && res.error) || '' });
                    UI.toast('Number changed to ' + res.number);
                    search($('input', c).value);
                });
            },
        });
    },

    maildomain(nav) {
        nav.push({
            title: 'Email Domain',
            grouped: true,
            backLabel: 'Developer',
            right: '<button class="nav-btn bold" data-act="save">Save</button>',
            render(c, ctx) {
                c.innerHTML = '<div class="spinner"></div>';
                devRpc('devMailDomain').then((d) => {
                    if (!d) return;
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px">
                            <div class="row"><span class="muted" style="font-size:20px">@</span><input class="field" data-f="domain" value="${esc(d.domain)}" spellcheck="false" placeholder="opslabs.cloud"></div>
                        </div>
                        <div class="group-footer">New OPS ID addresses look like <b data-no-i18n>example@<span class="dm-prev">${esc(d.domain)}</span></b>. The default comes from Config.MailDomain (<span data-no-i18n>${esc(d.default)}</span>).</div>
                        <div class="group">
                            <div class="row"><div class="grow">Move existing addresses<div class="sub" style="white-space:normal">Every phone and its mail history switches to the new domain</div></div>${UI.switchHtml(false, 'data-f="migrate"')}</div>
                        </div>`;
                    $('[data-f=domain]', c).addEventListener('input', (e) => { $('.dm-prev', c).textContent = e.target.value.trim(); });
                });
                $('[data-act=save]', ctx.page).onclick = async () => {
                    const domain = ($('[data-f=domain]', c) || {}).value;
                    if (!domain) return;
                    const migrate = $('[data-f=migrate]', c).checked;
                    if (migrate && !(await UI.confirm('Move all addresses?', `Every email address will change to @${domain.trim()}.`, 'Move', true))) return;
                    const res = await devRpc('devSetMailDomain', { domain: domain.trim(), migrate });
                    if (!res) return;
                    if (res.error) return UI.alert({ title: "Couldn't change domain", message: res.error });
                    if (Phone.profile) Phone.profile.mailDomain = res.domain;
                    UI.toast('Email domain: ' + res.domain, 'fa-solid fa-at');
                    ctx.pop();
                };
            },
        });
    },

    // Ops-Networks / opslabs-towers settings (editors live in apps/opsnet.js)
    netfaults(nav) {
        if (typeof OpsNetEditors === 'undefined') return UI.alert({ title: 'Unavailable', message: 'The Ops-Networks app is not loaded.' });
        OpsNetEditors.faults(nav, { call: devRpc, load: 'devOpsFaults', save: 'devOpsSaveFaults', trigger: 'devOpsTriggerFault', close: 'devOpsCloseFault', backLabel: 'Developer' });
    },

    engpay(nav) {
        if (typeof OpsNetEditors === 'undefined') return UI.alert({ title: 'Unavailable', message: 'The Ops-Networks app is not loaded.' });
        OpsNetEditors.pay(nav, { call: devRpc, load: 'devOpsPay', save: 'devOpsSavePay', backLabel: 'Developer' });
    },

    render(nav) {
        if (typeof OpsNetEditors === 'undefined') return UI.alert({ title: 'Unavailable', message: 'The Ops-Networks app is not loaded.' });
        OpsNetEditors.render(nav, { call: devRpc, load: 'devOpsRender', save: 'devOpsSaveRender', backLabel: 'Developer' });
    },

    broadcast(nav) {
        nav.push({
            title: 'Broadcast',
            grouped: true,
            backLabel: 'Developer',
            right: '<button class="nav-btn bold" data-act="send">Send</button>',
            render(c, ctx) {
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        <div class="row"><input class="field" data-f="title" placeholder="Title (e.g. Server)" maxlength="80"></div>
                        <div class="row"><textarea class="field" data-f="body" placeholder="Message to every phone" maxlength="300"></textarea></div>
                    </div>
                    <div class="group-footer">Sent as a notification to every player with the phone loaded.</div>`;
                $('[data-act=send]', ctx.page).onclick = async () => {
                    const body = $('[data-f=body]', c).value.trim();
                    if (!body) return;
                    if (!(await UI.confirm('Send to everyone?', body, 'Send'))) return;
                    const res = await devRpc('devBroadcast', { title: $('[data-f=title]', c).value.trim(), body });
                    if (!res || res.error) return UI.alert({ title: "Couldn't send", message: (res && res.error) || '' });
                    UI.toast(`Delivered to ${res.delivered} phones`, 'fa-solid fa-bullhorn');
                    ctx.pop();
                };
            },
        });
    },
};

Apps.register({
    id: 'dev',
    resumable: false, // live loops: restart fresh instead of resuming
    name: 'Developer',
    icon: {
        bg: 'linear-gradient(180deg,#5b5b60,#2c2c2e)',
        html: () => `<i class="fa-solid fa-hammer" style="font-size:28px;transform:rotate(-20deg);color:#e5e5ea"></i>`,
    },
    async open(root) {
        DevApp.root = root;
        root.innerHTML = '<div class="spinner" style="margin-top:300px"></div>';
        const s = await rpc('devSession');
        if (DevApp.root !== root) return;
        if (s && s.loggedIn) DevApp.showMain(); else DevApp.showLogin();
    },
    onClose() { DevApp.root = null; },
});

const DevApp = {
    root: null,

    showLogin() {
        const root = this.root;
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: '',
            grouped: true,
            noNav: true,
            render(c) {
                c.innerHTML = `
                    <div class="dev-login">
                        <div class="dl-icon"><i class="fa-solid fa-hammer"></i></div>
                        <h1>Developer</h1>
                        <p>Sign in to manage map locations, wallpapers, phone numbers and more.</p>
                        <div class="group dl-fields">
                            <div class="row"><input class="field" data-f="email" type="email" placeholder="Email" autocomplete="off" spellcheck="false"></div>
                            <div class="row"><input class="field" data-f="password" type="password" placeholder="Password" autocomplete="off"></div>
                        </div>
                        <div class="dl-error"></div>
                        <button class="btn block" data-act="login">Sign In</button>
                    </div>`;
                const email = $('[data-f=email]', c), pass = $('[data-f=password]', c), btn = $('[data-act=login]', c), err = $('.dl-error', c);
                const check = () => { btn.disabled = !(email.value.trim() && pass.value); };
                c.addEventListener('input', () => { err.textContent = ''; check(); });
                check();
                const submit = async () => {
                    if (btn.disabled) return;
                    btn.disabled = true;
                    btn.textContent = 'Signing In…';
                    const res = await rpc('devLogin', { email: email.value.trim(), password: pass.value });
                    btn.textContent = 'Sign In';
                    if (res && res.ok) {
                        pass.blur(); email.blur();
                        Sound.play('unlock');
                        return DevApp.showMain();
                    }
                    err.textContent = (res && res.error) || 'Sign in failed.';
                    pass.value = '';
                    const box = $('.dl-fields', c);
                    box.classList.remove('shake'); void box.offsetWidth; box.classList.add('shake');
                    check();
                };
                btn.onclick = submit;
                c.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
                setTimeout(() => email.focus(), 450);
            },
        });
    },

    showMain() {
        const root = this.root;
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: 'Developer',
            large: true,
            grouped: true,
            left: '<button class="nav-btn" data-act="logout" style="padding-left:8px">Log Out</button>',
            render(c, ctx) {
                $('[data-act=logout]', ctx.page).onclick = async () => {
                    if (!(await UI.confirm('Log Out', 'You will need to sign in again to use the Developer app.', 'Log Out', true))) return;
                    await rpc('devLogout');
                    FpsMeter.toggle(false);
                    DevApp.showLogin();
                };
                c.innerHTML = `
                    <div class="dev-stats"><div class="spinner" style="margin:10px auto"></div></div>
                    <div class="group-header">World</div>
                    <div class="group">
                        <div class="row tap has-icon" data-p="locations"><span class="ri" style="background:#ff3b30"><i class="fa-solid fa-map-location-dot"></i></span><div class="grow">Map Locations</div><span class="value" data-count="places"></span><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="coords"><span class="ri" style="background:#007aff"><i class="fa-solid fa-crosshairs"></i></span><div class="grow">Coordinates</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-act="tpwaypoint"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-person-walking-arrow-right"></i></span><div class="grow">Teleport to Waypoint</div></div>
                    </div>
                    <div class="group-header">Phone</div>
                    <div class="group">
                        <div class="row tap has-icon" data-p="wallpapers"><span class="ri" style="background:#32ade6"><i class="fa-solid fa-image"></i></span><div class="grow">Wallpapers</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="numbers"><span class="ri" style="background:#34c759"><i class="fa-solid fa-hashtag"></i></span><div class="grow">Phone Numbers</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="maildomain"><span class="ri" style="background:#1a8cfb"><i class="fa-solid fa-at"></i></span><div class="grow">Email Domain</div><span class="value" data-no-i18n>${esc(Phone.profile?.mailDomain || '')}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="broadcast"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-bullhorn"></i></span><div class="grow">Broadcast Notification</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    </div>
                    <div class="group-header">Network</div>
                    <div class="group">
                        <div class="row tap has-icon" data-p="netfaults"><span class="ri" style="background:#ff3b30"><i class="fa-solid fa-triangle-exclamation"></i></span><div class="grow">Network Faults</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="engpay"><span class="ri" style="background:#34c759"><i class="fa-solid fa-sack-dollar"></i></span><div class="grow">Engineer Pay</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="render"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-eye"></i></span><div class="grow">Render Distance</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    </div>
                    <div class="group-header">Debug</div>
                    <div class="group">
                        <div class="row has-icon"><span class="ri" style="background:#8e8e93"><i class="fa-solid fa-gauge-high"></i></span><div class="grow">Show FPS Meter</div>${UI.switchHtml(!!FpsMeter.el, 'data-toggle="fps"')}</div>
                        <div class="row tap has-icon" data-act="reload"><span class="ri" style="background:#8e8e93"><i class="fa-solid fa-rotate"></i></span><div class="grow">Reload Phone Data</div></div>
                    </div>`;
                const loadStats = async () => {
                    const s = await devRpc('devStats');
                    const box = $('.dev-stats', c);
                    if (!s || s.error) { box.innerHTML = `<div class="group-footer" style="margin:0 16px 20px">${esc((s && s.error) || 'Unavailable')}</div>`; return; }
                    box.innerHTML = [['Online', s.online], ['Phones', s.users], ['Messages', s.messages], ['Places', s.places]]
                        .map(([l, v]) => `<div><b>${Number(v || 0).toLocaleString(Phone.locale)}</b><span>${l}</span></div>`).join('');
                    const pc = $('[data-count=places]', c); if (pc) pc.textContent = s.places;
                };
                loadStats();
                ctx.opts.onResume = loadStats;
                c.addEventListener('click', async (e) => {
                    const p = e.target.closest('[data-p]');
                    if (p) return DevPages[p.dataset.p](nav);
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'tpwaypoint') { await devRpc('devTeleport', { waypoint: true }); }
                    if (a.dataset.act === 'reload') { await handlers.reload(); UI.toast('Reloaded'); }
                });
                c.addEventListener('change', (e) => { if (e.target.dataset.toggle === 'fps') FpsMeter.toggle(e.target.checked); });
            },
        });
    },
};
