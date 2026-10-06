'use strict';

/* =====================================================================
   OPS POS — the till screen (client/main.lua relays every call to the server)
   Sell · Stock · Manage (bosses) · set-up on a new terminal
   ===================================================================== */

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-pos';
const $ = (s, r = document) => r.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

async function nui(name, data = {}) {
    try {
        const r = await fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
        return await r.json();
    } catch (e) { return { error: 'The till is not responding' }; }
}

const S = { d: null, tab: 'sell', basket: {}, cat: 'All', q: '', customers: [], customer: null, redeem: false, busy: false, report: null, carried: null };
let C = '$';
const fmt = (v) => C + (Number(v) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const store = () => S.d && S.d.store;
const me = () => (store() && store().me) || {};

function toast(msg, kind = '') {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'toast ' + kind;
    clearTimeout(toast._t);
    toast._t = setTimeout(() => t.classList.add('hidden'), 3200);
}
const fail = (r) => { if (r && r.error) { toast(r.error, 'bad'); return true; } return false; };

/* ------------------------------------------------------------------ frame */
function render() {
    const s = store();
    $('#store-name').textContent = s ? '· ' + s.name : '';
    const tabs = s ? [['sell', 'Sell', 'fa-basket-shopping'], ['stock', 'Stock', 'fa-boxes-stacked']] : [];
    if (s && me().boss) tabs.push(['manage', 'Manage', 'fa-chart-line']);
    $('#tabs').innerHTML = tabs.map(([k, l, i]) => `<button data-tab="${k}" class="${S.tab === k ? 'on' : ''}"><i class="fa-solid ${i}"></i> ${l}</button>`).join('');
    $('#clock').innerHTML = s ? (me().clockedIn
        ? `<span style="color:var(--good)">●</span> On shift · <button class="btn small" data-act="clock">Clock out</button>`
        : `<button class="btn small primary" data-act="clock"><i class="fa-solid fa-user-clock"></i> Clock in</button>`) : '';
    const b = $('#banner');
    b.className = 'banner hidden';
    if (s && s.licence !== 'active') {
        b.className = 'banner' + (s.licence === 'overdue' ? ' warn' : '');
        b.innerHTML = s.licence === 'suspended'
            ? `<i class="fa-solid fa-lock"></i> The OPS POS licence is unpaid — sales are blocked. ${me().boss ? '<button class="btn small primary" data-act="paylicence">Pay licence</button>' : 'Ask a boss to pay it.'}`
            : `<i class="fa-solid fa-triangle-exclamation"></i> The OPS POS licence is overdue — the business account will be charged ${fmt(S.d.licence.monthly)}.`;
    }
    const v = $('#view');
    if (!s) return renderSetup(v);
    if (S.tab === 'stock') return renderStock(v);
    if (S.tab === 'manage') return renderManage(v);
    return renderSell(v);
}

/* ------------------------------------------------------------------ set-up */
function renderSetup(v) {
    const st = S.d.setup || {};
    const L = S.d.licence;
    const kit = S.d.kit;
    const kitRow = (k, label) => `<li>${kit[k] ? '✅' : '⬜'} ${label}</li>`;
    v.innerHTML = `<div class="setup">
        <div class="big"><i class="fa-solid fa-cash-register"></i></div>
        <h2>Set up OPS POS</h2>
        ${st.canSetup ? `
            <div class="muted">This till will belong to <b style="color:var(--text)">${esc(st.jobLabel || st.job)}</b>. Set-up ${fmt(L.setup)} + licence ${fmt(L.monthly)} every ${L.days} days, from the business account.</div>
            <input id="setup-name" maxlength="48" placeholder="Store name" value="${esc(st.jobLabel || '')}">
            <button class="btn primary" data-act="setup" style="width:100%;padding:14px"><i class="fa-solid fa-bolt"></i> Set up this till</button>`
        : `<div class="muted">Ask a boss of your business to set up this till.</div>`}
        <ul>
            <li>✅ Terminal</li>
            ${kitRow('reader', 'Card reader — card & contactless (phone) payments')}
            ${kitRow('drawer', 'Cash drawer — cash payments')}
            ${kitRow('scanner', 'Barcode scanner — scan to add')}
            ${kitRow('printer', 'Receipt printer — printed receipts')}
            ${kitRow('display', 'Customer display — customers see their basket')}
        </ul>
        <div class="muted" style="font-size:12px">Kit within a few metres of the terminal joins the till. Card payments: ${S.d.cardFee}% processing fee.</div>
    </div>`;
}

/* ------------------------------------------------------------------ sell */
function basketLines() {
    const P = Object.fromEntries((store().products || []).map((p) => [p.id, p]));
    return Object.entries(S.basket).filter(([id, q]) => q > 0 && P[id]).map(([id, q]) => ({ id: +id, label: P[id].label, qty: q, price: +P[id].price, total: +P[id].price * q }));
}
function totals() {
    const lines = basketLines();
    const sub = lines.reduce((a, l) => a + l.total, 0);
    const c = S.customers.find((x) => x.src === S.customer);
    const L = S.d.loyalty;
    let disc = 0;
    if (S.redeem && c && c.points >= L.MinRedeem) disc = Math.min(sub, c.points * L.PointValue);
    const tax = (sub - disc) * (store().tax || 0) / 100;
    return { lines, sub, disc, tax, total: sub - disc + tax, c };
}

let pushT = null;
function pushDisplay() {
    clearTimeout(pushT);
    pushT = setTimeout(() => {
        const t = totals();
        nui('basket', { lines: t.lines.map((l) => ({ label: l.label, qty: l.qty, total: l.total })), total: t.total, customer: t.c ? t.c.name : null });
    }, 250);
}

function add(id, n = 1) {
    const p = (store().products || []).find((x) => x.id === id);
    if (!p) return;
    const cur = S.basket[id] || 0;
    const next = Math.max(0, Math.min(p.stock, cur + n));
    if (n > 0 && next === cur) return toast(`No more ${p.label} in stock`, 'bad');
    S.basket[id] = next;
    if (n > 0 && S.d.kit.scanner) nui('beep');
    renderSell($('#view'));
    pushDisplay();
}

function renderSell(v) {
    const prods = store().products || [];
    const cats = ['All', ...new Set(prods.map((p) => p.category))];
    const q = S.q.toLowerCase();
    const list = prods.filter((p) => (S.cat === 'All' || p.category === S.cat) && (!q || p.label.toLowerCase().includes(q) || String(p.barcode || '').includes(q)));
    const t = totals();
    const kit = S.d.kit;
    const L = S.d.loyalty;
    v.innerHTML = `<div class="sell">
        <section class="products">
            <div class="filters">
                <input id="search" placeholder="${kit.scanner ? 'Scan a barcode or search…' : 'Search products…'}" value="${esc(S.q)}">
                ${cats.map((c) => `<button class="chip ${S.cat === c ? 'on' : ''}" data-cat="${esc(c)}">${esc(c)}</button>`).join('')}
            </div>
            <div class="grid">
                ${list.length ? list.map((p) => `<button class="tile ${p.stock <= 0 ? 'out' : ''}" data-add="${p.id}">
                    <span class="n">${esc(p.label)}</span><span class="s">${p.stock} in stock</span><span class="p">${fmt(p.price)}</span></button>`).join('')
                : `<div class="muted" style="grid-column:1/-1;padding:30px;text-align:center">${prods.length ? 'Nothing matches.' : 'No products yet. ' + (me().boss ? 'Add some under Stock.' : 'A boss adds them under Stock.')}</div>`}
            </div>
        </section>
        <aside class="basket">
            <h3>Current sale</h3>
            <div class="lines">${t.lines.map((l) => `<div class="line"><span>${esc(l.label)}<br><span class="muted" style="font-size:12px">${fmt(l.price)}</span></span>
                <span class="qty"><button data-dec="${l.id}">−</button>${l.qty}<button data-inc="${l.id}">+</button></span><b>${fmt(l.total)}</b></div>`).join('')
                || '<div class="muted" style="padding:20px 6px">Tap products to add them.</div>'}</div>
            <div class="totals">
                <div><span class="muted">Subtotal</span><span>${fmt(t.sub)}</span></div>
                ${t.disc > 0 ? `<div><span class="muted">Loyalty discount</span><span style="color:var(--good)">−${fmt(t.disc)}</span></div>` : ''}
                <div><span class="muted">Tax ${store().tax || 0}%</span><span>${fmt(t.tax)}</span></div>
                <div class="grand"><span>Total</span><span>${fmt(t.total)}</span></div>
            </div>
            <div class="customer">
                <div class="row"><select id="cust"><option value="">Customer at the counter…</option>
                    ${S.customers.map((c) => `<option value="${c.src}" ${S.customer === c.src ? 'selected' : ''}>${esc(c.name)} · ${c.dist} m${c.points ? ` · ${c.points} pts` : ''}</option>`).join('')}</select>
                    <button class="btn small" data-act="customers" title="Look again"><i class="fa-solid fa-rotate"></i></button></div>
                ${t.c && t.c.points >= L.MinRedeem ? `<label class="row" style="gap:6px"><input type="checkbox" id="redeem" ${S.redeem ? 'checked' : ''}> Use ${t.c.points} loyalty points (worth ${fmt(t.c.points * L.PointValue)})</label>` : t.c ? `<div class="muted" style="font-size:12px">${t.c.points} loyalty points · ${t.c.visits} visits</div>` : ''}
            </div>
            <div class="pay">
                <button class="btn blue" data-pay="card" ${!kit.reader || S.busy ? 'disabled' : ''} title="${kit.reader ? '' : 'No card reader on this till'}"><i class="fa-solid fa-wifi" style="transform:rotate(90deg)"></i> Card</button>
                <button class="btn good" data-pay="cash" ${!kit.drawer || S.busy ? 'disabled' : ''} title="${kit.drawer ? '' : 'No cash drawer on this till'}"><i class="fa-solid fa-money-bill-wave"></i> Cash</button>
                <div class="status ${S.busy ? 'wait' : ''}" id="status">${S.busy ? S.busy : (t.lines.length ? '' : '')}</div>
                ${t.lines.length ? '<button class="btn small" data-act="clear" style="grid-column:span 2">Clear sale</button>' : ''}
            </div>
        </aside>
    </div>`;
    const s = $('#search');
    if (S._focusSearch) { s.focus(); s.setSelectionRange(s.value.length, s.value.length); S._focusSearch = false; }
}

async function loadCustomers() {
    const r = await nui('customers');
    S.customers = (r && r.list) || [];
    if (!S.customers.some((c) => c.src === S.customer)) S.customer = S.customers.length === 1 ? S.customers[0].src : null;
    if (S.tab === 'sell' && store()) renderSell($('#view'));
    pushDisplay();
}

async function pay(method) {
    const t = totals();
    if (!t.lines.length) return toast('The basket is empty', 'bad');
    if (!S.customer) return toast('Pick the customer at the counter', 'bad');
    if (S.d.store.licence === 'suspended') return toast('The licence is unpaid', 'bad');
    if (!me().clockedIn) return toast('Clock in first', 'bad');
    S.busy = method === 'card' ? 'Waiting for the customer to tap their phone…' : 'Waiting for the customer to hand over the cash…';
    renderSell($('#view'));
    const basket = Object.fromEntries(t.lines.map((l) => [l.id, l.qty]));
    const r = await nui('charge', { basket, customer: S.customer, method, redeem: S.redeem });
    S.busy = false;
    if (!fail(r)) {
        toast(`Paid ${fmt(r.total)} by ${method}${r.earned ? ` · +${r.earned} points` : ''}`, 'good');
        S.basket = {};
        S.redeem = false;
        store().products = r.products || store().products;
        loadCustomers();
    }
    renderSell($('#view'));
}

/* ------------------------------------------------------------------ stock */
async function renderStock(v) {
    const prods = store().products || [];
    const boss = me().boss;
    if (!S.carried) { S.carried = []; nui('carried').then((r) => { S.carried = (r && r.items) || []; if (S.tab === 'stock') renderStock($('#view')); }); }
    const carriedOpts = S.carried.map((i) => `<option value="${esc(i.item)}">${esc(i.label)} (×${i.count})</option>`).join('');
    v.innerHTML = `<div class="page">
        <div class="box"><h4><i class="fa-solid fa-truck-ramp-box"></i> ${boss ? 'Add a product or receive stock' : 'Receive stock'} <span class="muted" style="font-weight:400">from what you're carrying</span>
            <button class="btn small" data-act="recarry"><i class="fa-solid fa-rotate"></i></button></h4>
            <div class="form">
                <select id="st-item">${carriedOpts || '<option value="">You are not carrying anything</option>'}</select>
                <input id="st-qty" type="number" min="0" value="1" style="width:90px" title="Quantity">
                ${boss ? `<input id="st-price" type="number" min="0" step="0.01" placeholder="Price" style="width:110px">
                <input id="st-cat" placeholder="Category" style="width:140px" value="General">
                <input id="st-bar" placeholder="Barcode (optional)" style="width:160px">
                <button class="btn primary" data-act="addproduct"><i class="fa-solid fa-plus"></i> Add / receive</button>` :
                '<button class="btn primary" data-act="receive"><i class="fa-solid fa-dolly"></i> Receive</button>'}
            </div>
            <div class="muted" style="font-size:12px;margin-top:8px">The items leave your inventory and go into the till's stock. ${boss ? 'An item already on the till just gets the stock added.' : ''}</div>
        </div>
        <div class="box"><h4><i class="fa-solid fa-boxes-stacked"></i> Products (${prods.length})</h4>
            <table><tr><th>Product</th><th>Category</th><th>Barcode</th><th>Stock</th><th>Price</th>${boss ? '<th></th>' : ''}</tr>
            ${prods.map((p) => `<tr><td>${esc(p.label)}</td><td>${esc(p.category)}</td><td class="muted">${esc(p.barcode || '')}</td>
                <td style="color:${p.stock <= 3 ? 'var(--bad)' : 'inherit'}">${p.stock}</td>
                <td>${boss ? `<input type="number" step="0.01" min="0" value="${(+p.price).toFixed(2)}" data-price="${p.id}" data-cat="${esc(p.category)}">` : fmt(p.price)}</td>
                ${boss ? `<td style="white-space:nowrap"><button class="btn small" data-take="${p.id}" title="Take this many out of stock (the quantity box above)">Take out</button>
                    <button class="btn small danger" data-remove="${p.id}" title="Remove from the till (stock comes back to you)"><i class="fa-solid fa-trash"></i></button></td>` : ''}</tr>`).join('')
            || `<tr><td colspan="6" class="muted">No products yet.</td></tr>`}</table>
        </div>
    </div>`;
}

async function productAction(action, data) {
    const r = await nui('product', { store: store().id, action, data });
    if (fail(r)) return;
    store().products = r.products || store().products;
    S.carried = null;
    toast('Saved', 'good');
    render();
}

/* ------------------------------------------------------------------ manage */
async function renderManage(v) {
    v.innerHTML = '<div class="page"><div class="muted">Loading…</div></div>';
    const r = await nui('report', { store: store().id });
    if (fail(r)) return;
    S.report = r;
    const day = r.today || {}, wk = r.week || {};
    const when = (t) => new Date(t * 1000).toLocaleString(S.d.locale || 'en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    v.innerHTML = `<div class="page">
        <div class="cards">
            <div class="card"><div class="k">Today</div><div class="v acc">${fmt(day.total)}</div><div class="sub">${day.n || 0} sales · card ${fmt(day.card)} · cash ${fmt(day.cash)}</div></div>
            <div class="card"><div class="k">Last 7 days</div><div class="v">${fmt(wk.total)}</div><div class="sub">${wk.n || 0} sales · fees ${fmt(wk.fees)}${+wk.npc ? ` · shop ${fmt(wk.npc)}` : ''}</div></div>
            <div class="card"><div class="k">Cash in drawer</div><div class="v">${fmt(r.drawer)}</div><div class="sub"><button class="btn small primary" data-act="cashup" ${r.drawer > 0 ? '' : 'disabled'}>Cash up to the business</button></div></div>
            <div class="card"><div class="k">Business account</div><div class="v">${fmt(r.society)}</div><div class="sub">Licence ${r.licence} · until ${new Date(r.licenceUntil * 1000).toLocaleDateString()}
                ${r.licence !== 'active' ? '<button class="btn small primary" data-act="paylicence">Pay now</button>' : ''}</div></div>
        </div>
        <div class="two">
            <div class="box"><h4><i class="fa-solid fa-receipt"></i> Recent sales</h4>
                <table><tr><th>#</th><th>When</th><th>Customer</th><th>Staff</th><th>Total</th><th></th></tr>
                ${(r.sales || []).map((s) => `<tr><td class="muted">${s.id}</td><td>${when(s.created_at)}</td><td>${esc(s.customer_name || '—')}</td><td>${esc(s.staff_name || '')}</td>
                    <td>${fmt(s.total)} <span class="tag ${s.refunded ? 'ref' : s.source === 'npc' ? 'npc' : s.method}">${s.refunded ? 'refunded' : s.source === 'npc' ? 'shop ' + s.method : s.method}</span></td>
                    <td>${s.refunded || s.source === 'npc' ? '' : `<button class="btn small danger" data-refund="${s.id}">Refund</button>`}</td></tr>`).join('') || '<tr><td colspan="6" class="muted">No sales yet.</td></tr>'}</table>
            </div>
            <div style="display:flex;flex-direction:column;gap:16px">
                <div class="box"><h4><i class="fa-solid fa-user-clock"></i> Staff hours · 7 days</h4>
                    <table><tr><th>Name</th><th>Hours</th><th></th></tr>${(r.hours || []).map((h) => `<tr><td>${esc(h.name)}</td><td>${h.hours}</td><td>${h.onShift ? '<span class="tag cash">on shift</span>' : ''}</td></tr>`).join('') || '<tr><td colspan="3" class="muted">Nobody has clocked in.</td></tr>'}</table></div>
                <div class="box"><h4><i class="fa-solid fa-ranking-star"></i> Top products · 7 days</h4>
                    <table>${(r.top || []).map((t) => `<tr><td>${esc(t.label)}</td><td>×${t.qty}</td><td>${fmt(t.total)}</td></tr>`).join('') || '<tr><td class="muted">—</td></tr>'}</table></div>
                <div class="box"><h4><i class="fa-solid fa-heart"></i> Loyal customers</h4>
                    <table>${(r.loyalty || []).map((l) => `<tr><td>${esc(l.name)}</td><td>${l.visits} visits</td><td>${fmt(l.spent)}</td><td class="muted">${l.points} pts</td></tr>`).join('') || '<tr><td class="muted">—</td></tr>'}</table></div>
                ${(r.low || []).length ? `<div class="box"><h4 style="color:var(--bad)"><i class="fa-solid fa-triangle-exclamation"></i> Low stock</h4>${r.low.map((l) => `<span class="tag" style="margin:2px">${esc(l.label)} · ${l.stock}</span>`).join('')}</div>` : ''}
                <div class="box"><h4><i class="fa-solid fa-gear"></i> Store settings</h4>
                    <div class="form"><input id="set-name" value="${esc(r.name)}" maxlength="48" style="flex:1">
                        <input id="set-tax" type="number" min="0" max="30" step="0.5" value="${r.tax}" style="width:90px" title="Sales tax %"> %
                        <button class="btn primary" data-act="savesettings">Save</button></div>
                    <div class="muted" style="font-size:12px;margin-top:8px">${r.npcShop ? `Runs the shop <b>${esc(r.npcShop)}</b>: its takings come here.` : 'Set this till up inside a shop and the shop’s takings come here too.'}</div></div>
            </div>
        </div>
    </div>`;
}

/* ------------------------------------------------------------------ events */
document.addEventListener('click', async (e) => {
    const a = e.target.closest('[data-act],[data-tab],[data-add],[data-inc],[data-dec],[data-cat],[data-pay],[data-take],[data-remove],[data-refund]');
    if (!a) return;
    const d = a.dataset;
    if (d.tab) { S.tab = d.tab; S.carried = null; return render(); }
    if (d.add) return add(+d.add, 1);
    if (d.inc) return add(+d.inc, 1);
    if (d.dec) return add(+d.dec, -1);
    if (d.cat) { S.cat = d.cat; return renderSell($('#view')); }
    if (d.pay) return pay(d.pay);
    if (d.take) {
        // how many: the quantity box at the top
        return productAction('take', { id: +d.take, qty: Math.max(1, +$('#st-qty').value || 1) });
    }
    if (d.remove) return productAction('remove', { id: +d.remove });
    if (d.refund) {
        const r = await nui('refund', { store: store().id, sale: +d.refund });
        if (!fail(r)) { toast('Refunded', 'good'); renderManage($('#view')); }
        return;
    }
    switch (d.act) {
        case 'close': return nui('close');
        case 'setup': {
            const r = await nui('setup', { name: $('#setup-name').value });
            if (fail(r)) return;
            toast('Till set up — welcome to OPS POS', 'good');
            return reopen();
        }
        case 'clock': {
            const r = await nui('clock', { store: store().id });
            if (fail(r)) return;
            me().clockedIn = r.clockedIn;
            toast(r.clockedIn ? 'Clocked in' : `Clocked out · ${r.hours} h`, 'good');
            return render();
        }
        case 'customers': return loadCustomers();
        case 'clear': S.basket = {}; S.redeem = false; renderSell($('#view')); return pushDisplay();
        case 'recarry': S.carried = null; return renderStock($('#view'));
        case 'addproduct': return productAction('add', { item: $('#st-item').value, qty: +$('#st-qty').value, price: +$('#st-price').value, category: $('#st-cat').value, barcode: $('#st-bar').value });
        case 'receive': return productAction('receive', { item: $('#st-item').value, qty: +$('#st-qty').value });
        case 'cashup': {
            const r = await nui('cashup', { store: store().id });
            if (!fail(r)) { toast(`${fmt(r.amount)} paid into the business account`, 'good'); renderManage($('#view')); }
            return;
        }
        case 'paylicence': {
            const r = await nui('payLicence', { store: store().id });
            if (!fail(r)) { toast('Licence paid', 'good'); reopen(); }
            return;
        }
        case 'savesettings': {
            const r = await nui('settings', { store: store().id, data: { name: $('#set-name').value, tax: +$('#set-tax').value } });
            if (!fail(r)) { toast('Saved', 'good'); reopen(); }
            return;
        }
    }
});

document.addEventListener('change', (e) => {
    if (e.target.id === 'cust') { S.customer = e.target.value ? +e.target.value : null; S.redeem = false; renderSell($('#view')); pushDisplay(); }
    if (e.target.id === 'redeem') { S.redeem = e.target.checked; renderSell($('#view')); pushDisplay(); }
    if (e.target.dataset.price) productAction('price', { id: +e.target.dataset.price, price: +e.target.value, category: e.target.dataset.cat });
});

document.addEventListener('input', (e) => {
    if (e.target.id !== 'search') return;
    S.q = e.target.value;
    S._focusSearch = true;
    renderSell($('#view'));
});

// a scanned barcode (Enter in the search box): exact match goes straight into the basket
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') return nui('close');
    if (e.key === 'Enter' && e.target.id === 'search' && store()) {
        const code = e.target.value.trim();
        const p = (store().products || []).find((x) => String(x.barcode) === code) || ((store().products || []).filter((x) => x.label.toLowerCase().includes(code.toLowerCase())).length === 1 ? store().products.find((x) => x.label.toLowerCase().includes(code.toLowerCase())) : null);
        if (p) { S.q = ''; S._focusSearch = true; add(p.id, 1); }
    }
});

async function reopen() {
    const r = await nui('reopen');
    if (fail(r)) return;
    open(r);
}

function open(d) {
    S.d = d;
    C = d.currency || '$';
    if (!d.store) S.tab = 'sell';
    $('#pos').classList.remove('hidden');
    render();
    if (d.store) loadCustomers();
}

window.addEventListener('message', (e) => {
    const m = e.data || {};
    if (m.action === 'open') { S.basket = {}; S.redeem = false; S.carried = null; S.tab = 'sell'; open(m.data); }
    if (m.action === 'close') { $('#pos').classList.add('hidden'); S.d = null; }
});
