'use strict';

/* =====================================================================
   OPS Pay — contactless at OPS POS tills (client/pay.lua, opslabs-pos)
   The till asks → a pay sheet slides up: merchant, items, total, the
   bank card → "Pay with Face ID" (or cancel) → the answer goes back.
   ===================================================================== */

const Pay = {
    cur: null,

    show(d) {
        this.cur = d;
        let host = $('#pay-sheet');
        if (!host) {
            host = el('<div class="pay-host" id="pay-sheet"></div>');
            screenEl().appendChild(host);
            host.addEventListener('click', (e) => {
                const a = e.target.closest('[data-pay]');
                if (!a || !this.cur) return;
                if (a.dataset.pay === 'ok') this.approve();
                if (a.dataset.pay === 'cancel') this.respond(false);
            });
        }
        const C = d.currency || '$';
        const money = (v) => C + (Number(v) || 0).toFixed(2);
        const lines = (d.lines || []).slice(0, 5);
        const more = (d.lines || []).length - lines.length;
        const name = (Phone.profile && Phone.profile.name) || '';
        host.innerHTML = `
            <div class="pay-sheet">
                <div class="pay-top"><span class="pay-brand"><i class="fa-solid fa-wifi"></i> OPS Pay</span>
                    <button class="pay-x" data-pay="cancel"><i class="fa-solid fa-xmark"></i></button></div>
                <div class="pay-card"><div class="pay-chip"></div><div class="pay-card-name" data-no-i18n>${esc(name)}</div>
                    <div class="pay-card-bank">${esc(I18N.t('Bank account'))}</div><i class="fa-solid fa-wifi pay-nfc"></i></div>
                <div class="pay-merchant" data-no-i18n>${esc(d.merchant || 'OPS POS')}</div>
                <div class="pay-lines">${lines.map((l) => `<div><span data-no-i18n>${l.qty || 1} × ${esc(l.label || '')}</span><span>${money(l.total)}</span></div>`).join('')}
                    ${more > 0 ? `<div class="muted">+ ${more} ${esc(I18N.t('more'))}</div>` : ''}</div>
                <div class="pay-total"><span>${esc(I18N.t('Total'))}</span><b>${money(d.total)}</b></div>
                <button class="pay-btn" data-pay="ok"><span class="pay-face"><i class="fa-regular fa-face-smile"></i></span> ${esc(I18N.t('Pay with Face ID'))}</button>
                <div class="pay-timer"><i style="animation-duration:${d.timeout || 30}s"></i></div>
            </div>`;
        requestAnimationFrame(() => host.classList.add('show'));
        Sound.play('notify');
        if (Phone.state !== 'open') Phone.peek(4000);
    },

    approve() {
        const host = $('#pay-sheet');
        const btn = $('.pay-btn', host);
        btn.disabled = true;
        btn.classList.add('scanning');
        $('.pay-face', btn).innerHTML = '<i class="fa-solid fa-expand"></i>';
        setTimeout(() => {
            btn.classList.remove('scanning');
            btn.classList.add('done');
            btn.innerHTML = `<i class="fa-solid fa-circle-check"></i> ${esc(I18N.t('Done'))}`;
            Sound.play('pay');
            this.respond(true, 1300);
        }, 900);
    },

    respond(ok, delay = 0) {
        const d = this.cur;
        if (!d) return;
        this.cur = null;
        nui('payRespond', { id: d.id, ok });
        setTimeout(() => this.close(), delay);
    },

    close() {
        const host = $('#pay-sheet');
        if (host) host.classList.remove('show');
    },
};

Phone.on('payRequest', (d) => d && Pay.show(d));
Phone.on('payClose', (d) => { if (Pay.cur && (!d || d.id === Pay.cur.id)) { Pay.cur = null; Pay.close(); } });
