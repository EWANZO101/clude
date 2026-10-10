'use strict';

function SendMoney(onDone, preset = {}) {
    UI.sheet({
        title: 'Send Money',
        right: 'Send',
        render(body, api) {
            body.innerHTML = `
                <div class="pay-amount"><span>$</span><input data-f="amount" type="number" min="1" placeholder="0" value="${esc(preset.amount || '')}"></div>
                <div class="group">
                    <div class="row"><span class="lbl">To</span><input class="field" data-f="number" placeholder="Phone number" value="${esc(preset.number || '')}">
                        <button class="tint" data-act="pick" style="font-size:20px"><i class="fa-solid fa-address-book"></i></button></div>
                    <div class="row"><span class="lbl">Note</span><input class="field" data-f="note" placeholder="What's it for?"></div>
                </div>
                <div class="group-footer" style="margin-top:-24px">Money is sent instantly from your bank account.</div>`;
            const check = () => api.setRightEnabled(+$('[data-f=amount]', body).value > 0 && $('[data-f=number]', body).value.trim());
            body.addEventListener('input', check);
            check();
            body.addEventListener('click', async (e) => {
                if (!e.target.closest('[data-act=pick]')) return;
                const c = await pickContact('Send to');
                if (c) { $('[data-f=number]', body).value = c.number; check(); }
            });
            setTimeout(() => $('[data-f=amount]', body).focus(), 350);
        },
        async onRight(api) {
            const b = api.body;
            const amount = +$('[data-f=amount]', b).value;
            const number = $('[data-f=number]', b).value.trim();
            const name = Contacts.nameFor(number) || number;
            api.setRightEnabled(false);
            if (!(await UI.confirm(`Send ${fmtMoney(amount)}?`, `To ${name}`, 'Send'))) return api.setRightEnabled(true);
            const res = await rpc('transfer', { amount, number, note: $('[data-f=note]', b).value });
            if (!res || res.error) { api.setRightEnabled(true); return UI.alert({ title: 'Payment Failed', message: (res && res.error) || 'Try again later.' }); }
            Sound.play('pay');
            api.close();
            UI.toast(`Sent ${fmtMoney(amount)}`, 'fa-solid fa-circle-check');
            onDone && onDone();
        },
    });
}

Apps.register({
    id: 'wallet',
    name: 'Wallet',
    icon: {
        bg: '#000',
        html: () => `<div style="position:absolute;left:9px;right:9px;top:12px;height:40px;border-radius:6px;overflow:hidden;display:flex;flex-direction:column">
            <i style="flex:1;background:#2fa8e0;display:block"></i><i style="flex:1;background:#f7b500;display:block"></i><i style="flex:1;background:#4fbf5b;display:block"></i><i style="flex:1;background:#f05b4a;display:block"></i></div>
            <div style="position:absolute;left:6px;right:6px;bottom:8px;height:24px;border-radius:5px;background:#e9e3d4"></div>`,
    },
    open(root) {
        const nav = new Nav(root);
        nav.push({
            title: 'Wallet',
            large: true,
            right: '<button class="nav-btn" data-act="send"><i class="fa-solid fa-paper-plane"></i></button>',
            render(content, ctx) {
                content.innerHTML = '<div class="spinner"></div>';
                const load = async () => {
                    const d = await rpc('getBank');
                    if (!d) { content.innerHTML = UI.empty('fa-solid fa-building-columns', 'Unavailable', ''); return; }
                    content.innerHTML = `
                        <div class="wallet-cards">
                            <div class="wcard bank">
                                <div class="wc-top"><span class="wc-brand"><i class="fa-solid fa-building-columns"></i> Bank</span><span class="wc-chip"></span></div>
                                <div class="wc-bal-label">Balance</div>
                                <div class="wc-bal">${fmtMoney(d.balance)}</div>
                                <div class="wc-bottom"><span>${esc(d.name)}</span><span>•••• ${esc(String(Phone.profile?.number || '').replace(/\D/g, '').slice(-4))}</span></div>
                            </div>
                            <div class="wcard cash">
                                <div class="wc-top"><span class="wc-brand"><i class="fa-solid fa-money-bill-wave"></i> Cash</span></div>
                                <div class="wc-bal">${fmtMoney(d.cash)}</div>
                            </div>
                        </div>
                        <div class="wallet-actions">
                            <button data-act="send"><span><i class="fa-solid fa-arrow-up"></i></span>Send</button>
                            <button data-act="request"><span><i class="fa-solid fa-arrow-down"></i></span>Request</button>
                            <button data-act="bills"><span><i class="fa-solid fa-file-invoice-dollar"></i></span>Bills${d.bills.length ? ` (${d.bills.length})` : ''}</button>
                        </div>
                        ${d.bills.length ? `<div class="group-header big">Bills Due</div><div class="group">${d.bills.map((b) => `
                            <div class="row has-icon"><span class="ri" style="background:#ff9500"><i class="fa-solid fa-file-invoice-dollar"></i></span>
                                <div class="grow"><div class="title">${esc(b.label)}</div><div class="sub">${esc(String(b.target).replace(/^society_/, '').toUpperCase())}</div></div>
                                <span style="font-weight:600">${fmtMoney(b.amount)}</span>
                                <button class="btn small" data-pay="${b.id}" data-amount="${b.amount}">Pay</button></div>`).join('')}</div>` : ''}
                        <div class="group-header big">Latest Transactions</div>
                        <div class="group">${d.transactions.length ? d.transactions.map((t) => `
                            <div class="row has-icon">
                                <span class="ri" style="background:${t.amount > 0 ? '#34c759' : '#8e8e93'}"><i class="fa-solid ${t.amount > 0 ? 'fa-arrow-down' : 'fa-arrow-up'}"></i></span>
                                <div class="grow"><div class="title">${esc(t.label)}</div><div class="sub">${esc(relTime(t.created_at))}</div></div>
                                <span style="font-weight:600;${t.amount > 0 ? 'color:#34c759' : ''}">${t.amount > 0 ? '+' : '−'}${fmtMoney(Math.abs(t.amount))}</span>
                            </div>`).join('') : '<div class="row muted">No transactions yet</div>'}</div>`;
                };
                ctx.page.addEventListener('click', async (e) => {
                    const pay = e.target.closest('[data-pay]');
                    if (pay) {
                        if (pay.disabled) return;
                        pay.disabled = true;
                        if (!(await UI.confirm('Pay Bill', `Pay ${fmtMoney(+pay.dataset.amount)} from your bank account?`, 'Pay'))) { pay.disabled = false; return; }
                        const res = await rpc('payBill', { id: +pay.dataset.pay });
                        if (!res || res.error) { pay.disabled = false; return UI.alert({ title: 'Payment Failed', message: (res && res.error) || '' }); }
                        Sound.play('pay');
                        UI.toast('Bill paid');
                        return load();
                    }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'send') SendMoney(load);
                    if (a.dataset.act === 'bills') { const g = $('.group-header.big', content); if (g) g.scrollIntoView({ behavior: 'smooth' }); }
                    if (a.dataset.act === 'request') {
                        const c = await pickContact('Request from');
                        if (!c) return;
                        const amt = await UI.prompt('Request Money', `How much from ${c.name}?`, { type: 'number', placeholder: '0' });
                        if (amt && +amt > 0) {
                            await rpc('sendMessage', { number: c.number, message: `💸 Payment request: ${fmtMoney(+amt)} — open Wallet to send it.` });
                            UI.toast('Request sent');
                        }
                    }
                });
                ctx.opts.onResume = load;
                load();
            },
        });
    },
});
