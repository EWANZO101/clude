'use strict';

/* =====================================================================
   OPS SafeMag + Batteries widget (client/safemag.lua does the game side)
   - SafeMag snaps on: the phone peeks up and the Dynamic Island shows
     the pack charging the phone, with both levels
   - Batteries widget (home screen, page 1): phone, SafeMag, OPS Buds
     and their case, like the iPhone one. Shows once you own an
     accessory; Settings → Battery hides it
   ===================================================================== */

const SAFEMAG_ICON = `<svg class="sm-ico" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.2"><rect x="6" y="3.5" width="20" height="25" rx="5"/><circle cx="16" cy="16" r="5.5"/><path d="M16 21.5v7" /></svg>`;
const PHONE_ICON = `<i class="fa-solid fa-mobile-screen-button"></i>`;
const CASE_ICON = `<svg class="sm-ico" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="2.2"><rect x="5" y="8" width="22" height="17" rx="7"/><path d="M5 14.5h22"/></svg>`;

const SafeMag = {
    s: { owned: false, on: false, level: 100, charging: false, label: 'OPS SafeMag' },

    update(d) {
        if (!d) return;
        Object.assign(this.s, d);
        if (d.event === 'on') this.onSnap();
        Batteries.refresh();
    },

    /** snapped onto the phone: the iPhone MagSafe moment */
    onSnap() {
        Sound.play('unlock');
        const phone = (Phone.battery && Phone.battery.level) || 0;
        Island.flash(`
            <div class="isl-left sm-isl" title="${esc(this.s.label)}">${SAFEMAG_ICON}${Batteries.ring(this.s.level, 24, false)}<span>${this.s.level}%</span></div>
            <div class="isl-right sm-isl-phone"><i class="fa-solid fa-bolt"></i><span>${phone}%</span></div>`, 3200, 'medium');
        if (Phone.state !== 'open') Phone.peek(3400);
    },
};

const Batteries = {
    _shown: null,

    visible() {
        if (Phone.config.batteriesWidget === false || Phone.settings.batteriesWidget === false) return false;
        return !!(SafeMag.s.owned || (typeof Buds !== 'undefined' && Buds.s.owned));
    },

    /** one ring per device, the iPhone way (green, orange at 20 %, red at 10 %) */
    ring(pct, size, charging) {
        const r = size / 2 - 3, c = 2 * Math.PI * r, v = Math.max(0, Math.min(100, pct | 0));
        const col = charging ? '#32d74b' : v <= 10 ? '#ff453a' : v <= 20 ? '#ff9f0a' : '#32d74b';
        return `<svg class="bw-ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
            <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(120,120,128,.3)" stroke-width="${size > 40 ? 4.5 : 3}"/>
            <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${col}" stroke-width="${size > 40 ? 4.5 : 3}" stroke-linecap="round"
                stroke-dasharray="${(c * v) / 100} ${c}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
        </svg>`;
    },

    devices() {
        const b = Phone.battery || { level: 100 };
        const list = [{ icon: PHONE_ICON, pct: b.level, charging: !!b.charging && b.charging !== 'full', name: 'Phone' }];
        if (SafeMag.s.owned) list.push({ icon: SAFEMAG_ICON, pct: SafeMag.s.level, charging: SafeMag.s.charging, name: SafeMag.s.label });
        if (typeof Buds !== 'undefined' && Buds.s.owned) {
            // in the case they show with the case; in your ears, on their own (like iOS)
            list.push({ icon: BUDS_ICON, pct: Buds.budsPct(), charging: !Buds.s.worn && Buds.s.c > 0 && Buds.budsPct() < 100, name: Buds.s.label });
            list.push({ icon: CASE_ICON, pct: Math.round(Buds.s.c), charging: Buds.s.caseCharging, name: 'Case' });
        }
        return list.slice(0, 4);
    },

    html() {
        const cells = this.devices().map((d) => `
            <div class="bw-cell" title="${esc(d.name)}">
                <div class="bw-dev">${this.ring(d.pct, 56, d.charging)}<span class="bw-icon">${d.icon}</span>
                    ${d.charging ? '<span class="bw-bolt"><i class="fa-solid fa-bolt"></i></span>' : ''}</div>
                <div class="bw-pct">${d.pct}%</div>
            </div>`);
        while (cells.length < 4) cells.push('<div class="bw-cell empty"><div class="bw-dev">' + this.ring(0, 56, false) + '</div><div class="bw-pct">&nbsp;</div></div>');
        return `
        <div class="widget-wrap" data-widget="settings" id="batteries-widget">
            <div class="widget w-batteries ${Phone.settings.darkMode ? 'dark' : ''}">${cells.join('')}</div>
            <div class="wl">${esc(I18N.t('Batteries'))}</div>
        </div>`;
    },

    /** shown / hidden changes the home layout; otherwise just redraw the widget */
    refresh() {
        const show = this.visible();
        if (this._shown !== null && show !== this._shown && typeof renderHome === 'function') {
            this._shown = show;
            return renderHome();
        }
        this._shown = show;
        const old = $('#batteries-widget');
        if (!old) return;
        const tmp = document.createElement('div');
        tmp.innerHTML = this.html();
        old.replaceWith(tmp.firstElementChild);
    },
};

Phone.on('safemag', (d) => SafeMag.update(d));
['battery', 'buds'].forEach((ev) => Phone.on(ev, () => Batteries.refresh()));
Phone.on('init', () => {
    Batteries._shown = Batteries.visible();
    // the game may have sent these before the page was ready: ask again
    nui('safemagState').then((d) => { if (d && d.label) SafeMag.update(d); });
    nui('budsState').then((d) => { if (d && d.label && typeof Buds !== 'undefined') Buds.update(d); });
});
