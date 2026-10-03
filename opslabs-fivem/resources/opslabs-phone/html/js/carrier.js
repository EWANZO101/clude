'use strict';

/* =====================================================================
   Mobile carrier (eSIM plan)
   - status bar shows SOS / signal, Control Center + lock screen show the
     carrier name
   - actions the plan doesn't cover come back as { __carrier } from the
     server: explain why and offer to fix it (buy / install / top up)
   - Settings > Mobile Service: plan, usage, eSIM install
   - internet radio counts as data
   ===================================================================== */

/* signal from opslabs-towers (absent = full coverage, like before) */
const Network = {
    active: false, cell: 4, net: null, wifi: null, nearby: [], tower: null,
    set(c) {
        if (!c) return;
        this.active = c.enforce !== false;
        this.cell = c.cell ?? 4;
        this.net = c.net || null;
        this.wifi = c.wifi || null;
        this.nearby = c.nearby || [];
        this.tower = c.tower || null;
        CarrierState.apply();
        Phone.emit('networkChanged', this);
    },
    noSignal() { return this.active && this.cell <= 0; },
};
Phone.on('coverage', (c) => Network.set(c));

const CarrierState = {
    view: null,
    set(v) {
        if (!v) return;
        this.view = v;
        Phone.carrier = v;
        this.apply();
        Phone.emit('carrierChanged', v);
    },
    enabled() { return !!(this.view && this.view.enabled); },
    line() { return this.view && this.view.line; },
    service() { return !this.enabled() || !!(this.line() && this.line().service); },
    /** has data left (for things the phone streams itself, like radio) */
    hasData() {
        if (Network.wifi) return true;
        if (Network.noSignal()) return false;
        if (!this.service()) return false;
        const l = this.line();
        if (!l || !this.enabled()) return true;
        const d = l.usage.data_mb;
        return d.limit < 0 || d.used < d.limit;
    },
    name() { return (this.view && this.view.name) || 'OPS Mobile'; },
    storeUrl(path = '') { return ((this.view && this.view.storeUrl) || '').replace(/\/+$/, '') + path; },

    apply() {
        const scr = screenEl();
        const noService = ((this.enabled() && !this.service()) || Network.noSignal()) && !Phone.settings.airplane;
        scr.classList.toggle('no-service', noService);
        // signal bars, 5G/LTE, Wi-Fi arcs
        const sig = $('.sb-signal');
        if (sig) sig.dataset.bars = Network.active ? Network.cell : 4;
        const net = $('.sb-net');
        if (net) net.textContent = Network.active && !Network.wifi && !noService ? (Network.net || '') : '';
        const wifi = $('.sb-wifi');
        if (wifi) wifi.dataset.bars = Network.active ? (Network.wifi ? Network.wifi.bars : 0) : 3;
        scr.classList.toggle('no-wifi', Network.active && !Network.wifi);
        const label = $('#cc-carrier');
        if (label) label.textContent = Phone.settings.airplane ? I18N.t('Airplane Mode') : Network.noSignal() ? 'SOS' : noService ? I18N.t('No Service') : this.name() + (Network.wifi ? ' · ' + Network.wifi.ssid : '');
        const ls = $('#ls-carrier');
        if (ls) ls.textContent = noService ? 'SOS' : this.name();
    },
};
Phone.on('init', (d) => CarrierState.set(d && d.carrier));
Phone.on('carrier', (v) => CarrierState.set(v));
Phone.on('settingsChanged', () => CarrierState.apply());

const CARRIER_MSG = {
    airplane: ['Airplane Mode', 'Turn off Airplane Mode to use mobile service.'],
    no_signal: ['No Service', "You're out of range of a cell tower. Move somewhere with signal. Emergency calls still work."],
    no_internet: ['No Internet Connection', "There's no mobile signal and you're not on Wi-Fi. Find signal or a Wi-Fi network to use apps."],
    no_plan: ['No Service', "You don't have a mobile plan. Get one from %s and install the eSIM."],
    expired: ['Plan Ended', 'Your mobile plan has ended. Renew it or pick a new plan.'],
    cancelled: ['No Service', 'Your line was cancelled. Get a new plan to reconnect.'],
    suspended: ['Service Suspended', 'Your mobile service has been suspended. Contact %s.'],
    not_installed: ['Install Your eSIM', 'Your plan is ready. Install the eSIM in Settings to start using it.'],
    limit_sms: ['Out of Texts', "You've used all the texts in your plan. Add more or upgrade."],
    limit_call: ['Out of Minutes', "You've used all the call minutes in your plan. Add more or upgrade."],
    limit_data: ['Out of Data', "You've used all your mobile data. Add a data boost or upgrade."],
};

let carrierAlertAt = 0;
/** an action was refused by the network */
async function carrierBlocked(gate, reason) {
    if (Date.now() - carrierAlertAt < 3500) return;
    carrierAlertAt = Date.now();
    const key = reason === 'limit' ? 'limit_' + gate : reason;
    const [title, msg] = CARRIER_MSG[key] || CARRIER_MSG.no_plan;
    const buttons = [{ label: I18N.t('OK'), value: null, style: 'cancel' }];
    if (reason === 'airplane') buttons.push({ label: I18N.t('Settings'), value: 'settings', style: 'bold' });
    else if (reason === 'not_installed') buttons.push({ label: I18N.t('Install eSIM'), value: 'settings', style: 'bold' });
    else if (reason === 'limit') buttons.push({ label: I18N.t('Add More'), value: 'store', style: 'bold' });
    else if (reason === 'no_internet') buttons.push({ label: I18N.t('Wi-Fi Settings'), value: 'wifi', style: 'bold' });
    else if (reason !== 'suspended' && reason !== 'no_signal') buttons.push({ label: I18N.t('Get a Plan'), value: 'store', style: 'bold' });
    const v = await UI.alert({ title: I18N.t(title), message: I18N.t(msg).replace('%s', CarrierState.name()), buttons });
    if (v === 'settings') Phone.openApp('settings', { page: reason === 'airplane' ? null : 'cellular' });
    if (v === 'wifi') Phone.openApp('settings', { page: 'wifi' });
    if (v === 'store') openExternal(CarrierState.storeUrl(reason === 'limit' ? '/account' : '/'));
}

/* ---------------------------------------------------------------------
   internet radio uses data (the phone streams it itself)
   --------------------------------------------------------------------- */

let radioSince = 0;
setInterval(async () => {
    const t = typeof Music !== 'undefined' && Music.track;
    const onRadio = t && t.kind === 'radio' && Music.playing && !Music.remote;
    if (!onRadio) { radioSince = 0; return; }
    if (!CarrierState.hasData()) {
        Music.pause();
        const l = CarrierState.line();
        return carrierBlocked('data', Phone.settings.airplane ? 'airplane' : Network.noSignal() ? 'no_internet' : !CarrierState.service() ? (l ? (l.installed ? l.status : 'not_installed') : 'no_plan') : 'limit');
    }
    if (!radioSince) { radioSince = Date.now(); return; }
    if (Date.now() - radioSince >= 60000) {
        radioSince = Date.now();
        const ok = await rpc('carrierRadioMinute');
        if (ok === null && Music.playing && Music.track && Music.track.kind === 'radio') Music.pause();
    }
}, 5000);

/* ---------------------------------------------------------------------
   Settings > Mobile Service
   --------------------------------------------------------------------- */

const fmtMB = (mb) => (mb >= 1024 ? `${(mb / 1024).toFixed(mb >= 10240 ? 0 : 1)} GB` : `${Math.round(mb)} MB`);
function usageRow(icon, label, u, fmt = (x) => String(x)) {
    const unlimited = u.limit < 0;
    const pct = unlimited ? 0 : Math.min(100, (u.used / Math.max(1, u.limit)) * 100);
    const color = pct >= 100 ? '#ff3b30' : pct >= 80 ? '#ff9500' : '#34c759';
    return `<div class="row ms-usage">
        <div class="grow">
            <div class="ms-u-top"><span><i class="fa-solid ${icon}"></i> ${esc(I18N.t(label))}</span>
                <b>${unlimited ? `${esc(fmt(u.used))} · ${esc(I18N.t('Unlimited'))}` : `${esc(fmt(u.used))} ${esc(I18N.t('of'))} ${esc(fmt(u.limit))}`}</b></div>
            ${unlimited ? '' : `<div class="ms-bar"><span style="width:${pct}%;background:${color}"></span></div>`}
        </div></div>`;
}

const STATUS_LABEL = { active: 'Active', pending: 'Ready to Install', suspended: 'Suspended', expired: 'Expired', cancelled: 'Cancelled' };

/** iOS-style "Activating eSIM" flow */
function installEsim(code) {
    return new Promise((resolve) => {
        let done = false;
        const sheet = UI.sheet({
            title: '',
            left: I18N.t('Cancel'),
            medium: true,
            onClose: () => resolve(done),
            render(body) {
                body.innerHTML = `<div class="ms-install">
                    <div class="ms-sim"><i class="fa-solid fa-sim-card"></i></div>
                    <h3>${esc(I18N.t('Activating eSIM'))}</h3>
                    <p>${esc(CarrierState.name())}</p>
                    <div class="spinner" style="margin:18px auto"></div></div>`;
                (async () => {
                    const [r] = await Promise.all([rpc('carrierInstall', { code: code || '' }), sleep(1600)]);
                    if (!body.isConnected) return;
                    if (!r || r.error) {
                        body.innerHTML = `<div class="ms-install"><div class="ms-sim err"><i class="fa-solid fa-xmark"></i></div>
                            <h3>${esc(I18N.t('Activation Failed'))}</h3><p>${esc(I18N.t(r && r.error === 'wrong_code' ? 'That activation code is not valid for this phone.' : r && r.error === 'no_line' ? "There's no eSIM for this phone yet. Buy a plan first." : 'Try again in a moment.'))}</p></div>`;
                        return;
                    }
                    done = true;
                    CarrierState.set(r);
                    Sound.play('unlock');
                    body.innerHTML = `<div class="ms-install"><div class="ms-sim ok"><i class="fa-solid fa-check"></i></div>
                        <h3>${esc(I18N.t('Mobile Service Activated'))}</h3>
                        <p>${esc(CarrierState.name())} · ${esc((r.line && r.line.plan && r.line.plan.name) || '')}</p>
                        <button class="btn" data-act="done" style="margin-top:18px">${esc(I18N.t('Done'))}</button></div>`;
                    body.querySelector('[data-act=done]').onclick = () => sheet.close();
                })();
            },
        });
    });
}

SettingsPages.cellular = function (nav) {
    nav.push({
        title: 'Mobile Service', grouped: true, backLabel: 'Settings',
        render(c, ctx) {
            const draw = () => {
                const v = CarrierState.view || {};
                const l = v.line;
                const name = CarrierState.name();
                if (!v.enabled) {
                    c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row"><div class="grow">${esc(name)}</div><span class="value">${esc(I18N.t('Unlimited'))}</span></div></div>
                        <div class="group-footer">${esc(I18N.t('Mobile service is unlimited on this server.'))}</div>`;
                    return;
                }
                let html = `<div class="ms-head"><div class="ms-logo"><i class="fa-solid fa-tower-cell"></i></div>
                    <div class="grow"><b>${esc(name)}</b><span>${esc(l ? I18N.t(STATUS_LABEL[l.service ? 'active' : l.status] || l.status) : I18N.t('No SIM'))}${l && l.plan ? ' · ' + esc(l.plan.name) : ''}</span></div>
                    <span class="ms-dot ${l && l.service ? 'on' : ''}"></span></div>`;
                if (!l) {
                    html += `<div class="group"><div class="row tap" data-ms="store"><div class="grow" style="color:var(--blue)">${esc(I18N.t('Get a Plan'))}</div><i class="fa-solid fa-arrow-up-right-from-square muted"></i></div>
                        <div class="row tap" data-ms="code"><div class="grow" style="color:var(--blue)">${esc(I18N.t('Add eSIM'))}</div></div></div>
                        <div class="group-footer">${esc(I18N.t('Buy a plan on the {name} website, then install the eSIM here to text, call and use online apps. Emergency calls always work.').replace('{name}', name))}</div>`;
                } else {
                    if (!l.installed) {
                        html += `<div class="group"><div class="row ms-ready"><i class="fa-solid fa-sim-card"></i><div class="grow"><b>${esc(I18N.t('eSIM Ready to Install'))}</b>
                            <span>${esc(I18N.t('Your {plan} plan is waiting.').replace('{plan}', (l.plan && l.plan.name) || ''))}</span></div>
                            <button class="mini-btn" data-ms="install">${esc(I18N.t('Install'))}</button></div></div>`;
                    }
                    const until = l.period_end ? fmtDate(new Date(l.period_end * 1000)) : '—';
                    html += `<div class="group">
                        <div class="row"><div class="grow">${esc(I18N.t('Plan'))}</div><span class="value">${esc((l.plan && l.plan.name) || '—')}</span></div>
                        <div class="row"><div class="grow">${esc(I18N.t('Phone Number'))}</div><span class="value">${esc((Phone.profile && Phone.profile.number) || '')}</span></div>
                        <div class="row"><div class="grow">${esc(I18N.t(!l.installed ? 'Starts' : l.service && l.auto_renew ? 'Renews' : l.service ? 'Ends' : 'Ended'))}</div><span class="value">${esc(l.installed ? until : I18N.t('When installed'))}</span></div>
                        ${v.credit ? `<div class="row"><div class="grow">${esc(I18N.t('Account Credit'))}</div><span class="value" style="color:#34c759;font-weight:600">$${esc(v.credit.toLocaleString())}</span></div>` : ''}
                        ${l.plan && l.plan.price ? `<div class="row"><div class="grow">${esc(I18N.t('Price'))}</div><span class="value">$${esc(String(l.plan.price))} / ${esc(String(l.plan.period_days))} ${esc(I18N.t('days'))}</span></div>` : ''}
                    </div>`;
                    if (l.installed) {
                        html += `<div class="group-header">${esc(I18N.t('Current Period'))}</div><div class="group">
                            ${usageRow('fa-message', 'Texts', l.usage.sms)}
                            ${usageRow('fa-phone', 'Minutes', l.usage.minutes)}
                            ${usageRow('fa-signal', 'Mobile Data', l.usage.data_mb, fmtMB)}
                        </div><div class="group-footer">${esc(I18N.t('Usage resets when your plan renews. Emergency calls are always free.'))}</div>`;
                    }
                    html += `<div class="group">
                        <div class="row tap" data-ms="manage"><div class="grow" style="color:var(--blue)">${esc(I18N.t('Manage Plan'))}</div><i class="fa-solid fa-arrow-up-right-from-square muted"></i></div>
                        ${l.installed ? '' : `<div class="row tap" data-ms="code"><div class="grow" style="color:var(--blue)">${esc(I18N.t('Enter Activation Code'))}</div></div>`}
                    </div>
                    <div class="group"><div class="row"><div class="grow">ICCID</div><span class="value" style="font-variant-numeric:tabular-nums">${esc(l.iccid || '')}</span></div></div>`;
                }
                c.innerHTML = html;
            };
            draw();
            rpc('carrierStatus').then((v) => { if (v) CarrierState.set(v); });
            const off = Phone.on('carrierChanged', () => { if (c.isConnected) draw(); else off(); });
            c.addEventListener('click', async (e) => {
                const r = e.target.closest('[data-ms]');
                if (!r) return;
                const act = r.dataset.ms;
                if (act === 'store') openExternal(CarrierState.storeUrl('/'));
                if (act === 'manage') openExternal(CarrierState.storeUrl('/account'));
                if (act === 'install') await installEsim();
                if (act === 'code') {
                    const code = await UI.prompt(I18N.t('Enter Activation Code'), I18N.t('Enter the code from your {name} account.').replace('{name}', CarrierState.name()), { placeholder: 'XXXX-XXXX-XXXX-XXXX', ok: I18N.t('Next') });
                    if (code) await installEsim(code.trim());
                }
                draw();
            });
            ctx.opts.onResume = draw;
        },
    });
};

/* ---------------------------------------------------------------------
   Settings > Wi-Fi (networks come from opslabs-towers)
   --------------------------------------------------------------------- */

function wifiIcon(bars, locked) {
    return `<span class="wf-ico" data-bars="${bars}"><svg viewBox="0 0 18 13"><path class="w1" d="M9 12.2a1.6 1.6 0 1 1 0-3.2 1.6 1.6 0 0 1 0 3.2z"/><path class="w2" d="M4.6 7.6a6.3 6.3 0 0 1 8.8 0l-1.3 1.3a4.5 4.5 0 0 0-6.2 0L4.6 7.6z"/><path class="w3" d="M1.8 4.8a10.3 10.3 0 0 1 14.4 0l-1.3 1.3a8.5 8.5 0 0 0-11.8 0L1.8 4.8z"/></svg></span>${locked ? '<i class="fa-solid fa-lock wf-lock"></i>' : ''}`;
}

SettingsPages.wifi = function (nav) {
    nav.push({
        title: 'Wi-Fi', grouped: true, backLabel: 'Settings',
        render(c) {
            const draw = () => {
                if (!Network.active) {
                    c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row"><div class="grow">Wi-Fi</div><span class="value">LS-Public</span></div></div>
                        <div class="group-footer">${esc(I18N.t('Connected automatically.'))}</div>`;
                    return;
                }
                const cur = Network.wifi;
                const others = Network.nearby.filter((n) => !cur || n.ssid !== cur.ssid);
                c.innerHTML = `
                    <div class="wf-hero"><span class="ri" style="background:#007aff"><i class="fa-solid fa-wifi"></i></span><b>Wi-Fi</b>
                        <p>${esc(I18N.t('Buildings around the city have Wi-Fi. Your phone joins open networks automatically — apps work on Wi-Fi without using mobile data.'))}</p></div>
                    <div class="group">${cur
                        ? `<div class="row tap" data-wf="${cur.id}" data-cur="1"><i class="fa-solid fa-check" style="color:var(--blue);width:18px"></i><div class="grow"><b>${esc(cur.ssid)}</b>${cur.secured ? `<div class="sub">${esc(I18N.t('Secured network'))}</div>` : ''}</div>${wifiIcon(cur.bars, cur.secured)}<i class="fa-solid fa-circle-info wf-info"></i></div>`
                        : `<div class="row"><div class="grow muted">${esc(I18N.t('Not Connected'))}</div></div>`}</div>
                    <div class="group-header">${esc(I18N.t(others.length ? 'Networks' : 'Other Networks'))}</div>
                    <div class="group">${others.length ? others.map((n) => `
                        <div class="row tap ${n.locked ? 'wf-locked' : ''}" data-wf="${n.id}"><div class="grow">${esc(n.ssid)}${n.locked ? `<div class="sub">${esc(I18N.t('Restricted network'))}</div>` : !n.inRange ? `<div class="sub">${esc(I18N.t('Too far away'))}</div>` : n.secured && !n.known ? `<div class="sub">${esc(I18N.t('Password required'))}</div>` : ''}</div>${wifiIcon(n.bars, n.locked || n.secured)}</div>`).join('')
                        : `<div class="row"><div class="grow muted">${esc(I18N.t('No networks nearby'))}</div></div>`}</div>
                    <div class="group-header">${esc(I18N.t('Mobile Signal'))}</div>
                    <div class="group"><div class="row"><div class="grow">${esc(CarrierState.name())}</div><span class="value">${Network.cell > 0 ? `${Network.net || ''} · ${Network.cell}/4` : 'SOS'}</span></div>
                        ${Network.tower && Network.cell > 0 ? `<div class="row"><div class="grow">${esc(I18N.t('Tower'))}</div><span class="value">${esc(Network.tower)}</span></div>` : ''}</div>
                    <div class="group-footer">${esc(I18N.t('With no signal only emergency calls go through.'))}</div>`;
            };
            draw();
            const off = Phone.on('networkChanged', () => { if (c.isConnected) draw(); else off(); });
            c.addEventListener('click', async (e) => {
                const row = e.target.closest('[data-wf]');
                if (!row) return;
                const id = +row.dataset.wf;
                const n = Network.nearby.find((x) => x.id === id) || (Network.wifi && Network.wifi.id === id ? Network.wifi : null);
                if (!n) return;
                if (row.dataset.cur) {
                    const i = await UI.actionSheet(n.ssid, [{ label: I18N.t('Forget This Network'), destructive: true }]);
                    if (i === 0 && (await UI.confirm(I18N.t('Forget Wi-Fi Network "{n}"?').replace('{n}', n.ssid), I18N.t('Your phone will no longer join this Wi-Fi network automatically.'), I18N.t('Forget'), true))) {
                        await rpc('wifiForget', { id });
                        UI.toast(I18N.t('Network forgotten'), 'fa-solid fa-wifi');
                    }
                    return;
                }
                if (n.locked) return UI.alert({ title: n.ssid, message: I18N.t('This network is restricted. Only some jobs can join it.') });
                if (!n.inRange) return UI.alert({ title: n.ssid, message: I18N.t('Move closer to join this network.') });
                let password = '';
                if (n.secured && !n.known) {
                    password = await UI.prompt(I18N.t('Enter the password for "{n}"').replace('{n}', n.ssid), '', { type: 'password', placeholder: I18N.t('Password'), ok: I18N.t('Join') });
                    if (password === null) return;
                }
                const r = await rpc('wifiJoin', { id, password });
                if (!r || r.error) {
                    const msg = { wrong_password: 'Incorrect password', restricted: 'This network is restricted.', not_found: 'This network is no longer available.' }[r && r.error] || "Couldn't join this network";
                    return UI.alert({ title: I18N.t(r && r.error === 'wrong_password' ? 'Unable to join "{n}"' : msg).replace('{n}', n.ssid), message: r && r.error === 'wrong_password' ? I18N.t('Incorrect password') : '' });
                }
                Sound.play('notify');
                UI.toast(I18N.t('Joined {n}').replace('{n}', n.ssid), 'fa-solid fa-wifi');
            });
        },
    });
};
