'use strict';

/* =====================================================================
   OPS Mobile — the carrier's own app (App Store)
   Overview: line, usage rings, quick actions · Shop: plans and extras,
   paid from the bank · Activity: payments and daily usage · Support:
   texts the carrier number.
   ===================================================================== */

const OM_STATUS = { active: 'Active', pending: 'Ready to install', suspended: 'Suspended', expired: 'Plan ended', cancelled: 'Cancelled' };
const omLimit = (v, mb) => (v < 0 ? I18N.t('Unlimited') : mb ? fmtMB(v) : String(v));

function omRing(u, label, color, fmt = (x) => String(x)) {
    const unlimited = u.limit < 0;
    const pct = unlimited ? 1 : Math.min(1, u.used / Math.max(1, u.limit));
    const left = unlimited ? null : Math.max(0, u.limit - u.used);
    const c = 2 * Math.PI * 30;
    const stroke = !unlimited && pct >= 1 ? '#ff453a' : !unlimited && pct >= 0.8 ? '#ff9f0a' : color;
    return `<div class="om-ring">
        <svg viewBox="0 0 72 72"><circle cx="36" cy="36" r="30" class="track"/>
            <circle cx="36" cy="36" r="30" class="fill" style="stroke:${stroke};stroke-dasharray:${c};stroke-dashoffset:${unlimited ? 0 : c * (1 - pct)}${unlimited ? ';opacity:.35' : ''}"/></svg>
        <div class="om-ring-in"><b>${unlimited ? '∞' : esc(fmt(left))}</b><span>${esc(I18N.t(unlimited ? 'Unlimited' : 'left'))}</span></div>
        <div class="om-ring-label">${esc(I18N.t(label))}</div>
    </div>`;
}

Apps.register({
    id: 'opsmobile',
    get name() { return (typeof CarrierState !== 'undefined' && CarrierState.name()) || 'OPS Mobile'; },
    defaultInstalled: false,
    splash: 'linear-gradient(160deg,#0a84ff,#5e5ce6 60%,#ff375f)',
    icon: {
        bg: 'linear-gradient(150deg,#0a84ff,#5e5ce6 55%,#ff375f)',
        html: () => `<svg viewBox="0 0 64 64" width="44" height="44" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round"><path d="M32 26v22"/><path d="M22 14a15 15 0 0 0 0 19M42 14a15 15 0 0 1 0 19"/><circle cx="32" cy="23" r="3.6" fill="#fff" stroke="none"/></svg>`,
    },

    open(root) {
        let tab = 'overview', shop = null, activity = null;
        root.innerHTML = `
            <div class="om">
                <div class="om-top">
                    <div class="om-brand"><span class="om-logo"></span><b></b></div>
                    <button class="om-help" data-act="support"><i class="fa-solid fa-comment-dots"></i></button>
                </div>
                <div class="segmented om-tabs"><button data-tab="overview" class="on">${esc(I18N.t('Overview'))}</button><button data-tab="shop">${esc(I18N.t('Shop'))}</button><button data-tab="activity">${esc(I18N.t('Activity'))}</button></div>
                <div class="om-page scroll"></div>
            </div>`;
        const page = $('.om-page', root);
        $('.om-brand b', root).textContent = CarrierState.name();

        const view = () => CarrierState.view || {};
        const line = () => view().line;

        /* ---------------- overview ---------------- */
        const overview = () => {
            const v = view(), l = line();
            if (!v.enabled) {
                page.innerHTML = `<div class="om-hero"><h2>${esc(I18N.t('Unlimited for everyone'))}</h2><p>${esc(I18N.t('Mobile service is free on this server right now. No plan needed.'))}</p></div>`;
                return;
            }
            if (!l) {
                page.innerHTML = (v.credit ? `<div class="om-card om-credit-card"><i class="fa-solid fa-gift"></i><div class="grow"><b>$${esc(v.credit.toLocaleString())} ${esc(I18N.t('credit'))}</b><span>${esc(I18N.t('Ready to spend on your first plan.'))}</span></div></div>` : '') + `<div class="om-hero">
                        <div class="om-sim"><i class="fa-solid fa-sim-card"></i></div>
                        <h2>${esc(I18N.t('Get connected'))}</h2>
                        <p>${esc(I18N.t('Pick a plan to text, call and use online apps. Your eSIM is ready in seconds.'))}</p>
                        <button class="om-btn" data-tab-go="shop">${esc(I18N.t('See Plans'))}</button></div>`;
                return;
            }
            const plan = l.plan || {};
            const until = l.period_end ? new Date(l.period_end * 1000) : null;
            const days = until ? Math.max(0, Math.ceil((until - Date.now()) / 86400000)) : 0;
            const statusKey = l.service ? 'active' : l.status;
            page.innerHTML = `
                <div class="om-card om-line" style="--c:${plan.color || '#5e5ce6'}">
                    <div class="om-line-top">
                        <div><span class="om-eyebrow">${esc(I18N.t('Your plan'))}</span><h2>${esc(plan.name || '—')}</h2></div>
                        <span class="om-pill ${l.service ? 'ok' : statusKey === 'pending' ? 'warn' : 'bad'}">${esc(I18N.t(OM_STATUS[statusKey] || statusKey))}</span>
                    </div>
                    <div class="om-line-meta">
                        <span><i class="fa-solid fa-phone"></i> ${esc((Phone.profile && Phone.profile.number) || '')}</span>
                        ${l.installed && until ? `<span><i class="fa-regular fa-calendar"></i> ${esc(I18N.t(l.service ? (l.auto_renew ? 'Renews' : 'Ends') : 'Ended'))} ${esc(fmtDate(until))}</span>` : ''}
                    </div>
                    ${l.installed && l.service ? `<div class="om-days"><div class="om-days-bar"><span style="width:${Math.min(100, (1 - days / Math.max(1, plan.period_days || 7)) * 100)}%"></span></div><small>${days} ${esc(I18N.t(days === 1 ? 'day left' : 'days left'))}</small></div>` : ''}
                </div>
                ${v.credit ? `<div class="om-card om-credit-card"><i class="fa-solid fa-gift"></i><div class="grow"><b>$${esc(v.credit.toLocaleString())} ${esc(I18N.t('credit'))}</b><span>${esc(I18N.t('Used first for plans, renewals and extras.'))}</span></div></div>` : ''}
                ${!l.installed ? `<button class="om-card om-alert" data-act="install"><i class="fa-solid fa-sim-card"></i><div class="grow"><b>${esc(I18N.t('Install your eSIM'))}</b><span>${esc(I18N.t('Your plan starts when the eSIM is installed.'))}</span></div><i class="fa-solid fa-chevron-right"></i></button>` : ''}
                ${l.installed ? `<div class="om-card om-rings">
                    ${omRing(l.usage.sms, 'Texts', '#0a84ff')}
                    ${omRing(l.usage.minutes, 'Minutes', '#30d158')}
                    ${omRing(l.usage.data_mb, 'Data', '#bf5af2', fmtMB)}
                </div>` : ''}
                <div class="om-actions">
                    ${!l.service && l.installed && plan.price ? `<button data-act="renew"><i class="fa-solid fa-rotate"></i><span>${esc(I18N.t('Renew'))}</span></button>` : ''}
                    <button data-tab-go="shop" data-shop-focus="addon"><i class="fa-solid fa-bolt"></i><span>${esc(I18N.t('Add Extras'))}</span></button>
                    <button data-tab-go="shop"><i class="fa-solid fa-arrow-up-right-dots"></i><span>${esc(I18N.t('Change Plan'))}</span></button>
                    <button data-act="support"><i class="fa-solid fa-headset"></i><span>${esc(I18N.t('Support'))}</span></button>
                </div>
                <div class="group" style="margin:0 0 16px">
                    <div class="row"><div class="grow">${esc(I18N.t('Auto-Renew'))}</div>${UI.switchHtml(!!l.auto_renew, `data-toggle="autorenew" ${plan.price ? '' : 'disabled'}`)}</div>
                    ${plan.price ? `<div class="row"><div class="grow">${esc(I18N.t('Price'))}</div><span class="value">$${esc(String(plan.price))} / ${esc(String(plan.period_days))} ${esc(I18N.t('days'))}</span></div>` : ''}
                    <div class="row tap" data-act="settings"><div class="grow">${esc(I18N.t('Mobile Service Settings'))}</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    <div class="row tap" data-act="web"><div class="grow">${esc(I18N.t('Manage on the website'))}</div><i class="fa-solid fa-arrow-up-right-from-square muted"></i></div>
                </div>
                <p class="om-foot">${esc(I18N.t('Usage resets when your plan renews. Emergency calls and texts to {name} are always free.').replace('{name}', CarrierState.name()))}</p>`;
        };

        /* ---------------- shop ---------------- */
        const planCard = (p, current) => `
            <div class="om-plan ${p.featured ? 'featured' : ''}" style="--c:${p.color}">
                ${p.featured ? `<span class="om-tag">${esc(I18N.t('Most popular'))}</span>` : ''}
                <div class="om-plan-head"><b>${esc(p.name)}</b><span class="om-price">$${esc(p.price.toLocaleString())}<small>/${p.period_days}${esc(I18N.t('d'))}</small></span></div>
                <p>${esc(p.description || '')}</p>
                <div class="om-feats">
                    <span><i class="fa-solid fa-message"></i>${esc(omLimit(p.sms))}</span>
                    <span><i class="fa-solid fa-phone"></i>${esc(omLimit(p.minutes))}${p.minutes >= 0 ? ' min' : ''}</span>
                    <span><i class="fa-solid fa-signal"></i>${esc(omLimit(p.data_mb, true))}</span>
                </div>
                <button class="om-btn ${current ? 'ghost' : ''}" data-buy="${esc(p.code)}">${esc(current ? I18N.t('Renew') : I18N.t('Choose'))}</button>
            </div>`;
        const addonRow = (a) => `
            <div class="om-addon" style="--c:${a.color}">
                <i class="fa-solid ${a.data_mb > 0 ? 'fa-signal' : a.minutes > 0 ? 'fa-phone' : 'fa-message'}"></i>
                <div class="grow"><b>${esc(a.name)}</b><span>${esc(a.description || '')}</span></div>
                <button class="om-btn sm" data-buy="${esc(a.code)}">$${esc(a.price.toLocaleString())}</button>
            </div>`;
        const shopPage = async (focus) => {
            if (!shop) page.innerHTML = '<div class="spinner" style="margin:40px auto"></div>';
            shop = (await rpc('carrierShop')) || shop;
            if (tab !== 'shop') return;
            if (!shop) { page.innerHTML = `<p class="om-foot">${esc(I18N.t("Couldn't reach the server"))}</p>`; return; }
            if (shop.carrier) CarrierState.set(shop.carrier);
            const l = line();
            const cur = l && l.plan && l.plan.code;
            const plansList = shop.plans.filter((p) => p.kind === 'plan'), addons = shop.plans.filter((p) => p.kind === 'addon');
            page.innerHTML = `
                <div class="om-balance">
                    ${shop.credit ? `<div><span>${esc(I18N.t('Credit'))}</span><b class="om-credit">$${esc(shop.credit.toLocaleString())}</b></div>` : ''}
                    <div><span>${esc(I18N.t('Bank balance'))}</span><b>$${esc((shop.balance || 0).toLocaleString())}</b></div>
                </div>
                ${shop.credit ? `<p class="om-sub">${esc(I18N.t('Credit is used first, then your bank.'))}</p>` : ''}
                ${addons.length ? `<h3 class="om-h" id="om-addons">${esc(I18N.t('Extras'))}</h3>
                    <p class="om-sub">${esc(l && l.service ? I18N.t('Added straight away, until your plan renews.') : I18N.t('Extras need an active plan.'))}</p>
                    <div class="om-card om-addons ${l && l.service ? '' : 'dim'}">${addons.map(addonRow).join('')}</div>` : ''}
                <h3 class="om-h">${esc(I18N.t('Plans'))}</h3>
                <p class="om-sub">${esc(I18N.t('Paid from your bank. Switch or cancel any time.'))}</p>
                ${plansList.map((p) => planCard(p, p.code === cur)).join('')}`;
            if (focus === 'addon') $('#om-addons', page)?.scrollIntoView();
            else page.scrollTop = 0;
        };

        const buy = async (code) => {
            const item = shop && shop.plans.find((p) => p.code === code);
            if (!item) return;
            const l = line();
            if (item.kind === 'addon' && !(l && l.service)) return UI.alert({ title: I18N.t('No active plan'), message: I18N.t('Choose a plan first, then add extras.') });
            const credit = shop.credit || 0;
            if ((shop.balance || 0) + credit < item.price) return UI.alert({ title: I18N.t('Not enough money'), message: I18N.t('You need ${amount} more in your bank.').replace('{amount}', (item.price - credit - (shop.balance || 0)).toLocaleString()) });
            const useCredit = Math.min(credit, item.price);
            const switching = item.kind === 'plan' && l && l.plan && l.plan.code !== item.code && l.service;
            const msg = item.kind === 'addon'
                ? I18N.t('{name} will be added to your plan now.').replace('{name}', item.name)
                : (switching ? I18N.t('Your current plan ends and {name} starts now.') : I18N.t('{name} for {days} days, renews automatically.')).replace('{name}', item.name).replace('{days}', item.period_days);
            const payNote = useCredit ? '\n\n' + (useCredit >= item.price ? I18N.t('Paid with ${credit} credit.') : I18N.t('${credit} credit + ${bank} from your bank.'))
                .replace('{credit}', useCredit.toLocaleString()).replace('{bank}', (item.price - useCredit).toLocaleString()) : '';
            const ok = await UI.alert({
                title: `${item.name} · $${item.price.toLocaleString()}`, message: msg + payNote,
                buttons: [{ label: I18N.t('Cancel'), value: false, style: 'cancel' }, { label: useCredit >= item.price ? I18N.t('Pay with Credit') : I18N.t('Pay') + ` $${(item.price - useCredit).toLocaleString()}`, value: true, style: 'bold' }],
            });
            if (!ok) return;
            const r = await rpc('carrierBuy', { code });
            if (!r || r.error) return UI.alert({ title: I18N.t('Payment failed'), message: (r && r.error) || I18N.t("Couldn't reach the server") });
            Sound.play('unlock');
            CarrierState.set(r.carrier);
            shop.balance = r.balance;
            shop.credit = r.credit || 0;
            activity = null;
            const nl = r.carrier && r.carrier.line;
            if (nl && !nl.installed) {
                UI.toast(I18N.t('Plan bought — install your eSIM'), 'fa-solid fa-sim-card');
                await installEsim();
            } else UI.toast(item.kind === 'addon' ? I18N.t('Added to your plan') : I18N.t('You are now on {name}').replace('{name}', item.name), 'fa-solid fa-circle-check');
            go('overview');
        };

        /* ---------------- activity ---------------- */
        const EVENT_LABEL = { subscribe: 'Plan started', renew: 'Renewed', addon: 'Extra added', install: 'eSIM installed', suspended: 'Suspended', expired: 'Plan ended',
            cancelled: 'Cancelled', active: 'Reactivated', pending: 'Waiting for eSIM', reset_usage: 'Usage reset', reissue_esim: 'New eSIM issued', admin_change: 'Line updated', auto_renew: 'Auto-renew changed' };
        const activityPage = async () => {
            if (!activity) page.innerHTML = '<div class="spinner" style="margin:40px auto"></div>';
            activity = (await rpc('carrierActivity')) || activity || { events: [], daily: [] };
            if (tab !== 'activity') return;
            const maxKb = Math.max(1, ...activity.daily.map((d) => d.data_kb));
            page.innerHTML = `
                ${activity.daily.length ? `<div class="om-card"><span class="om-eyebrow">${esc(I18N.t('Data — last 14 days'))}</span>
                    <div class="om-chart">${activity.daily.map((d) => `<div title="${esc(d.day)}"><span style="height:${Math.max(3, (d.data_kb / maxKb) * 100)}%"></span><small>${esc(d.day.slice(8))}</small></div>`).join('')}</div></div>` : ''}
                <h3 class="om-h">${esc(I18N.t('History'))}</h3>
                <div class="group" style="margin:0">${activity.events.length ? activity.events.map((e) => `
                    <div class="row"><div class="grow"><div class="title">${esc(I18N.t(EVENT_LABEL[e.type] || e.type))}</div><div class="sub">${esc([e.detail, fmtDate(new Date(e.at * 1000))].filter(Boolean).join(' · '))}</div></div>
                    ${e.amount ? `<span class="value">−$${esc(e.amount.toLocaleString())}</span>` : ''}</div>`).join('') : `<div class="row muted">${esc(I18N.t('Nothing yet'))}</div>`}</div>`;
        };

        const go = (t, focus) => {
            tab = t;
            $$('[data-tab]', root).forEach((b) => b.classList.toggle('on', b.dataset.tab === t));
            if (t === 'overview') overview();
            if (t === 'shop') shopPage(focus);
            if (t === 'activity') activityPage();
        };

        root.addEventListener('click', async (e) => {
            const t = e.target.closest('[data-tab]');
            if (t) return go(t.dataset.tab);
            const tg = e.target.closest('[data-tab-go]');
            if (tg) return go(tg.dataset.tabGo, tg.dataset.shopFocus);
            const b = e.target.closest('[data-buy]');
            if (b) return buy(b.dataset.buy);
            const a = e.target.closest('[data-act]');
            if (!a) return;
            switch (a.dataset.act) {
                case 'support': Phone.openApp('messages', { number: (view().number) || '6677' }); break;
                case 'install': if (await installEsim()) overview(); break;
                case 'settings': Phone.openApp('settings', { page: 'cellular' }); break;
                case 'web': openExternal(CarrierState.storeUrl('/account')); break;
                case 'renew': {
                    const plan = line() && line().plan;
                    if (!plan) break;
                    const ok = await UI.confirm(`${I18N.t('Renew')} ${plan.name}`, I18N.t('${price} from your bank for {days} more days.').replace('{price}', plan.price.toLocaleString()).replace('{days}', plan.period_days), I18N.t('Renew'));
                    if (!ok) break;
                    const r = await rpc('carrierRenew');
                    if (!r || r.error) UI.alert({ title: I18N.t("Couldn't renew"), message: (r && r.error) || '' });
                    else { CarrierState.set(r.carrier); UI.toast(I18N.t('Renewed'), 'fa-solid fa-circle-check'); activity = null; overview(); }
                    break;
                }
            }
        });
        root.addEventListener('change', async (e) => {
            if (e.target.dataset.toggle !== 'autorenew') return;
            const r = await rpc('carrierAutoRenew', { on: e.target.checked });
            if (r && r.carrier) CarrierState.set(r.carrier);
            UI.toast(I18N.t(e.target.checked ? 'Auto-renew on' : 'Auto-renew off'), 'fa-solid fa-rotate');
        });
        const off = Phone.on('carrierChanged', () => { if (!root.isConnected) return off(); if (tab === 'overview') overview(); $('.om-brand b', root).textContent = CarrierState.name(); });

        overview();
        rpc('carrierStatus').then((v) => { if (v) CarrierState.set(v); });
    },
});
