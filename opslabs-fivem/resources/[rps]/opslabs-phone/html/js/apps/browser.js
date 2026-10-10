'use strict';

/* =====================================================================
   Browser — the in-game internet (server/web.lua)
   Every site is data (OPS Web builder blocks) rendered here with escaping —
   no player HTML ever reaches the page. Built-in sites:
     ops.sa            OPS Search
     opsdomains.sa     OPS Domains: register, DNS, WHOIS, transfers, SSL
     opsweb.sa         OPS Web: hosting, site builder, business email
     opsnetwork.sa …   each OPS company's own site
   Uses mobile data on the phone, the Ethernet port on a laptop.
   ===================================================================== */

const BR_HOME = 'https://ops.sa';
const BR_COLORS = ['#0a84ff', '#30d158', '#ff9f0a', '#ff375f', '#bf5af2', '#5e5ce6', '#64d2ff', '#ffd60a', '#e5383b', '#1c1c1e'];
const BR_BLOCKS = {
    hero: ['star', 'Big header', { title: 'Your headline', text: 'A line or two about you.', button: 'Contact us', href: '/contact', align: 'center' }],
    text: ['align-left', 'Text', { heading: 'Heading', body: 'Write something here.' }],
    image: ['image', 'Image', { url: '', caption: '' }],
    features: ['table-cells-large', 'Features', { heading: 'Why us', items: [{ icon: 'star', title: 'Great', text: 'Say why.' }] }],
    list: ['list', 'Menu / price list', { heading: 'Prices', items: [{ name: 'Item', price: '$10', text: '' }] }],
    gallery: ['images', 'Gallery', { heading: '', items: [] }],
    contact: ['envelope', 'Contact & form', { heading: 'Contact us', text: '', form: true }],
    hours: ['clock', 'Opening hours', { heading: 'Opening hours', items: [{ day: 'Mon – Fri', time: '9am – 6pm' }] }],
    links: ['link', 'Links / buttons', { heading: '', items: [{ label: 'Our socials', href: 'https://ops.sa' }] }],
    quote: ['quote-left', 'Quote / review', { text: 'Best in Los Santos!', by: 'A happy customer' }],
    cta: ['bullhorn', 'Call to action', { title: 'Ready?', text: '', button: 'Get started', href: '/contact' }],
    divider: ['minus', 'Divider', {}],
};
const BR_FIELDS = {
    hero: [['title', 'Headline'], ['text', 'Text', 'area'], ['button', 'Button label'], ['href', 'Button link (/page or https://…)'], ['image', 'Background image (https://…)'], ['align', 'Align', ['center', 'left']]],
    text: [['heading', 'Heading'], ['body', 'Text', 'area']],
    image: [['url', 'Image address (https://…)'], ['caption', 'Caption']],
    features: [['heading', 'Heading']], list: [['heading', 'Heading']], gallery: [['heading', 'Heading']], hours: [['heading', 'Heading']], links: [['heading', 'Heading']],
    contact: [['heading', 'Heading'], ['text', 'Text', 'area'], ['form', 'Show a message form', 'bool']],
    quote: [['text', 'Quote', 'area'], ['by', 'Who said it']],
    cta: [['title', 'Title'], ['text', 'Text'], ['button', 'Button label'], ['href', 'Button link']],
    divider: [],
};
const BR_ITEMS = {
    features: { max: 6, add: { icon: 'star', title: '', text: '' }, f: [['icon', 'Icon (e.g. star, car, burger)'], ['title', 'Title'], ['text', 'Text']] },
    list: { max: 24, add: { name: '', price: '', text: '' }, f: [['name', 'Name'], ['price', 'Price'], ['text', 'Description']] },
    gallery: { max: 9, add: { url: '', caption: '' }, f: [['url', 'Image (https://…)'], ['caption', 'Caption']] },
    hours: { max: 7, add: { day: '', time: '' }, f: [['day', 'Day(s)'], ['time', 'Hours']] },
    links: { max: 10, add: { label: '', href: '' }, f: [['label', 'Label'], ['href', 'Link']] },
};

/** click handlers that charge money: ignore further clicks until the current one (confirm + request) is done */
function brOneAtATime(fn) {
    let busy = false;
    return async (e) => {
        if (busy) return;
        busy = true;
        try { await fn(e); } finally { busy = false; }
    };
}

const brStore = {
    get(k, d) { try { const v = JSON.parse(localStorage.getItem('opsbr.' + k)); return v ?? d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('opsbr.' + k, JSON.stringify(v)); } catch (e) { /* storage off */ } },
};
const brMoney = (v) => '$' + Number(v || 0).toLocaleString('en-US', { maximumFractionDigits: 2 });
const brDate = (t) => (t ? new Date(t * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '—');
const brPara = (s) => esc(s || '').split(/\n{2,}/).map((p) => `<p>${p.replace(/\n/g, '<br>')}</p>`).join('');
const brChip = (txt, c) => `<span class="br-chip" style="--c:${c}">${esc(txt)}</span>`;
const BR_STATUS = { active: '#30d158', expired: '#ff9f0a', suspended: '#ff3b30', cancelled: '#8e8e93', valid: '#30d158', revoked: '#ff3b30' };

/** what the user typed → a url (or a search) */
function brNormalize(input) {
    const s = String(input || '').trim();
    if (!s) return null;
    if (/^https?:\/\//i.test(s)) return s;
    if (!/\s/.test(s) && /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(\/\S*)?$/i.test(s)) return s;
    return BR_HOME + '/search?q=' + encodeURIComponent(s);
}
function brSplit(url) {
    const m = String(url || '').match(/^(?:(https?):\/\/)?([^/?#]+)([^?#]*)(?:\?([^#]*))?/i);
    if (!m) return {};
    const q = {};
    (m[4] || '').split('&').forEach((kv) => { if (!kv) return; const [k, v = ''] = kv.split('='); try { q[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' ')); } catch (e) { /* bad escape */ } });
    return { scheme: m[1], host: m[2].toLowerCase(), path: (m[3] || '/').replace(/\/+$/, '') || '/', query: q };
}

const Browser = {
    root: null, page: null, bar: null,
    stack: [], idx: -1, cur: null, loading: 0,

    open(root, params) {
        this.root = root;
        root.innerHTML = `
            <div class="br">
                <div class="br-top">
                    <div class="br-url"><button class="br-lock" data-act="info"><i class="fa-solid fa-magnifying-glass"></i></button>
                        <input class="br-input" spellcheck="false" autocomplete="off" autocapitalize="off" placeholder="Search or enter website">
                        <button class="br-reload" data-act="reload"><i class="fa-solid fa-rotate-right"></i></button></div>
                    <div class="br-progress"><i></i></div>
                </div>
                <div class="br-page scroll"></div>
                <div class="br-bottom">
                    <button data-act="back"><i class="fa-solid fa-chevron-left"></i></button>
                    <button data-act="fwd"><i class="fa-solid fa-chevron-right"></i></button>
                    <button data-act="home"><i class="fa-solid fa-house"></i></button>
                    <button data-act="star"><i class="fa-regular fa-star"></i></button>
                    <button data-act="books"><i class="fa-solid fa-book-open"></i></button>
                </div>
            </div>`;
        this.page = $('.br-page', root);
        this.input = $('.br-input', root);
        this.input.addEventListener('keydown', (e) => {
            if (e.key !== 'Enter') return;
            const u = brNormalize(this.input.value);
            this.input.blur();
            if (u) this.go(u);
        });
        this.input.addEventListener('focus', () => { this.input.value = this.cur ? this.cur.shown : ''; setTimeout(() => this.input.select(), 0); });
        this.input.addEventListener('blur', () => this.showUrl());
        root.addEventListener('click', (e) => this.onClick(e));
        this.stack = []; this.idx = -1;
        this.go((params && params.url) || brStore.get('last', BR_HOME));
    },

    showUrl() {
        if (!this.cur || document.activeElement === this.input) return;
        const r = this.cur.r || {};
        const host = this.cur.host || '';
        this.input.value = host.replace(/^www\./, '') || this.cur.shown;
        const lock = $('.br-lock', this.root);
        lock.className = 'br-lock ' + (r.secure ? 'ok' : r.kind === 'error' || !r.kind ? '' : r.warning || r.kind === 'interstitial' ? 'bad' : 'warn');
        lock.innerHTML = r.secure ? '<i class="fa-solid fa-lock"></i>' : r.kind === 'error' || !r.kind ? '<i class="fa-solid fa-magnifying-glass"></i>'
            : `<i class="fa-solid fa-${r.warning || r.kind === 'interstitial' ? 'triangle-exclamation' : 'circle-info'}"></i><span>Not secure</span>`;
        const bms = brStore.get('bookmarks', []);
        $('[data-act=star] i', this.root).className = bms.some((b) => b.url === this.cur.shown) ? 'fa-solid fa-star' : 'fa-regular fa-star';
        $('[data-act=back]', this.root).disabled = this.idx <= 0;
        $('[data-act=fwd]', this.root).disabled = this.idx >= this.stack.length - 1;
    },

    /** navigate; push = new history entry */
    go(url, { push = true, proceed = false } = {}) {
        if (push) { this.stack = this.stack.slice(0, this.idx + 1); this.stack.push(url); this.idx = this.stack.length - 1; }
        return this.load(url, proceed);
    },
    /** same host, new path (built-in sites' own navigation) */
    nav(path, query) {
        const h = this.cur ? this.cur.host : 'ops.sa';
        const qs = query ? '?' + Object.entries(query).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&') : '';
        return this.go(`https://${h}${path === '/' ? '' : path}${qs}`);
    },

    async load(url, proceed) {
        const my = ++this.loading;
        const parts = brSplit(url);
        this.cur = { url, shown: url.replace(/^https?:\/\//, ''), host: parts.host, path: parts.path, query: parts.query, r: null };
        this.root.classList.add('br-busy');
        this.showUrl();
        const r = await rpc('webBrowse', { url, proceed });
        if (my !== this.loading) return;
        this.root.classList.remove('br-busy');
        if (!r) { this.renderOffline(); return; }
        this.cur.r = r;
        if (r.url) {
            const p2 = brSplit(r.url);
            this.cur.shown = r.url.replace(/^https?:\/\//, '') + (url.includes('?') ? url.slice(url.indexOf('?')) : '');
            this.cur.host = p2.host;
            this.stack[this.idx] = (r.url + (url.includes('?') ? url.slice(url.indexOf('?')) : ''));
        }
        brStore.set('last', this.stack[this.idx]);
        if (r.kind !== 'error') {
            const hist = brStore.get('history', []).filter((h) => h.url !== this.stack[this.idx]);
            hist.unshift({ url: this.stack[this.idx], title: (r.site && r.site.title) || r.host || this.cur.shown, at: Date.now() });
            brStore.set('history', hist.slice(0, 60));
        }
        this.page.scrollTop = 0;
        this.showUrl();
        try { await this.render(r); } catch (e) { console.error(e); this.page.innerHTML = UI.empty('fa-solid fa-bug', 'This page broke', String(e.message || e)); }
    },

    renderOffline() {
        this.page.innerHTML = `<div class="br-err"><i class="fa-solid fa-wifi"></i><h2>You’re not connected to the internet</h2>
            <p>${Laptop && Laptop.active ? 'Plug the laptop into a router with internet.' : 'You need mobile data (a plan and signal) or Wi-Fi.'}</p><small>ERR_INTERNET_DISCONNECTED</small></div>`;
    },

    async render(r) {
        const pg = this.page;
        if (r.kind === 'error') {
            pg.innerHTML = `<div class="br-err"><i class="fa-solid fa-file-circle-xmark"></i><h2>${esc(r.title)}</h2><p>${esc(r.text)}</p>${r.hint ? `<p class="hint">${esc(r.hint)}</p>` : ''}
                <small>${esc(r.code)}</small>${r.code !== 'ERR_INVALID_URL' ? `<button class="br-btn" data-act="reload">Reload</button>` : ''}
                ${r.code === 'DNS_PROBE_FINISHED_NXDOMAIN' ? `<button class="br-link" data-go="${esc(BR_HOME + '/search?q=' + encodeURIComponent(r.host || ''))}">Search for ${esc(r.host)}</button>
                <button class="br-link" data-go="https://opsdomains.sa/?q=${esc(encodeURIComponent(r.host || ''))}">Is it available? Check on OPS Domains</button>` : ''}</div>`;
            return;
        }
        if (r.kind === 'interstitial') {
            pg.innerHTML = `<div class="br-err br-warnpage"><i class="fa-solid fa-triangle-exclamation"></i><h2>Your connection is not private</h2>
                <p>Attackers might be trying to steal your information from <b>${esc(r.host)}</b> (for example, passwords, messages or card details).</p>
                <small>${esc(r.code)}</small>
                <button class="br-btn" data-act="back">Back to safety</button>
                <button class="br-link" data-act="adv">Advanced</button>
                <div class="br-adv hidden"><p>${r.cert ? `The certificate for ${esc(r.cert.subject)} ${r.cert.status === 'revoked' ? 'was revoked by its issuer' : `expired on ${brDate(r.cert.expires)}`}.` : `This server could not prove that it is ${esc(r.host)}; its certificate is missing or isn’t for this name.`}</p>
                <button class="br-link danger" data-act="proceed">Proceed to ${esc(r.host)} (unsafe)</button></div></div>`;
            return;
        }
        if (r.kind === 'parked') return this.renderParked(r);
        if (r.kind === 'site') { pg.innerHTML = brSiteHtml(r); return; }
        if (r.kind === 'internal') {
            const app = BrInternal[r.data.app] || BrInternal.search;
            return app(pg, r.data, this.cur.query || {}, this);
        }
        pg.innerHTML = UI.empty('fa-solid fa-circle-question', 'Unknown page', '');
    },

    renderParked(r) {
        const P = {
            parked: ['globe', '#0a84ff', esc(r.domain || r.host), 'This domain is registered with OPS Domains and has no website yet.', 'Is it yours? Build a site in minutes on <a data-go="https://opsweb.sa">opsweb.sa</a>.'],
            expired: ['hourglass-end', '#ff9f0a', esc(r.domain || r.host), 'This domain has expired.', 'If you own it, renew it on <a data-go="https://opsdomains.sa/my">opsdomains.sa</a> before it is released.'],
            suspended: ['ban', '#ff3b30', esc(r.domain || r.host), 'This domain has been suspended by OPS Domains.', 'Contact OPS Domains if you think this is a mistake.'],
            hosting: ['pause', '#ff9f0a', 'Account suspended', 'This website’s OPS Web hosting is suspended.', 'The owner can pay the bill on <a data-go="https://opsweb.sa/panel">opsweb.sa</a>.'],
            takedown: ['gavel', '#ff3b30', 'This site was taken down', esc(r.note || 'It broke the OPS Web acceptable use policy.'), ''],
            coming_soon: ['rocket', '#bf5af2', esc(r.title || r.host), 'Coming soon.', 'This site is being built — check back later.'],
            default_server: ['server', '#30d158', 'It works!', `This is the default web page for this server (${esc(r.ip || '')}).`, 'The web server is running, but no site has been added to it yet. Owner: create a site on opsweb.sa and host it on this IP.'],
        }[r.reason] || ['globe', '#8e8e93', esc(r.host), '', ''];
        this.page.innerHTML = `<div class="br-park"><span class="br-park-ic" style="--c:${P[1]}"><i class="fa-solid fa-${P[0]}"></i></span><h1>${P[2]}</h1><p>${P[3]}</p><p class="muted">${P[4]}</p>
            ${r.reason === 'parked' || r.reason === 'expired' ? '<div class="br-park-foot">Parked free by <b>OPS Domains</b></div>' : ''}</div>`;
    },

    onClick(e) {
        const go = e.target.closest('[data-go]');
        if (go) { e.preventDefault(); return this.go(go.dataset.go); }
        const href = e.target.closest('[data-href]');
        if (href) { e.preventDefault(); return this.follow(href.dataset.href); }
        const nav = e.target.closest('[data-nav]');
        if (nav) { e.preventDefault(); return this.nav(nav.dataset.nav); }
        const a = e.target.closest('[data-act]');
        if (!a || !this.root.contains(a)) return;
        const act = a.dataset.act;
        if (act === 'back' && this.idx > 0) { this.idx--; this.load(this.stack[this.idx]); }
        else if (act === 'fwd' && this.idx < this.stack.length - 1) { this.idx++; this.load(this.stack[this.idx]); }
        else if (act === 'reload') this.load(this.stack[this.idx]);
        else if (act === 'home') this.go(BR_HOME);
        else if (act === 'adv') $('.br-adv', this.page).classList.remove('hidden');
        else if (act === 'proceed') this.load(this.stack[this.idx], true);
        else if (act === 'info') this.info();
        else if (act === 'star') this.toggleStar();
        else if (act === 'books') this.books();
        else if (act === 'send-form') this.sendForm(a);
    },

    follow(href) {
        if (!href || href === '#') return;
        if (href.startsWith('mailto:')) return MailCompose(href.slice(7));
        if (href.startsWith('tel:')) return UI.alert({ title: href.slice(4), message: 'Call this number from the Phone app.' });
        if (href.startsWith('/')) {
            const r = this.cur.r || {};
            return this.go(`${r.secure ? 'https' : 'http'}://${this.cur.host}${href === '/' ? '' : href}`);
        }
        return this.go(href);
    },

    info() {
        const r = (this.cur && this.cur.r) || {};
        const c = r.cert;
        UI.sheet({
            title: this.cur.host || 'Page info',
            render(body, api) {
                body.innerHTML = `<div class="group">
                    <div class="row has-icon"><span class="ri" style="background:${r.secure ? '#30d158' : '#ff9f0a'}"><i class="fa-solid fa-${r.secure ? 'lock' : 'lock-open'}"></i></span><div class="grow"><div>${r.secure ? 'Connection is secure' : 'Connection is not secure'}</div>
                        <div class="sub muted">${r.secure ? 'Your information is private when it is sent to this site.' : 'Don’t enter passwords or card details on this site.'}</div></div></div>
                    ${c ? `<div class="row"><div class="grow muted">Issued to</div><div>${esc(c.wildcard ? '*.' + c.subject.replace(/^\*\./, '') : c.subject)}</div></div>
                        ${c.org ? `<div class="row"><div class="grow muted">Organisation</div><div>${esc(c.org)}</div></div>` : ''}
                        <div class="row"><div class="grow muted">Issued by</div><div>${esc(c.issuer)}</div></div>
                        <div class="row"><div class="grow muted">Type</div><div>${esc(String(c.kind || '').toUpperCase())}</div></div>
                        ${c.expires ? `<div class="row"><div class="grow muted">Valid until</div><div>${brDate(c.expires)}</div></div>` : ''}` : ''}
                    ${r.hosted ? `<div class="row"><div class="grow muted">Hosted by</div><div>${esc(r.hosted)}</div></div>` : ''}
                    ${r.ip ? `<div class="row"><div class="grow muted">Server</div><div style="font-family:ui-monospace,monospace">${esc(r.ip)}</div></div>` : ''}
                    </div>
                    <div class="group"><div class="row tap" data-whois><div class="grow" style="color:var(--tint)">WHOIS for this domain</div></div></div>`;
                body.addEventListener('click', (e) => { if (e.target.closest('[data-whois]')) { api.close(); Browser.go('https://opsdomains.sa/whois?q=' + encodeURIComponent(Browser.cur.host)); } });
            },
        });
    },

    toggleStar() {
        if (!this.cur) return;
        const url = this.stack[this.idx];
        let bms = brStore.get('bookmarks', []);
        if (bms.some((b) => b.url === url)) bms = bms.filter((b) => b.url !== url);
        else bms.unshift({ url, title: (this.cur.r && this.cur.r.site && this.cur.r.site.title) || this.cur.host });
        brStore.set('bookmarks', bms.slice(0, 50));
        UI.toast(bms.some((b) => b.url === url) ? 'Bookmarked' : 'Removed', 'fa-solid fa-star');
        this.showUrl();
    },

    books() {
        UI.sheet({
            title: 'Bookmarks & history',
            render(body, api) {
                const bms = brStore.get('bookmarks', []);
                const hist = brStore.get('history', []);
                const row = (b) => `<div class="row tap has-icon" data-url="${esc(b.url)}"><span class="ri" style="background:${brColorOf(b.url)}">${esc(brLetter(b.url))}</span><div class="grow"><div>${esc(b.title || b.url)}</div><div class="sub muted">${esc(b.url.replace(/^https?:\/\//, ''))}</div></div></div>`;
                body.innerHTML = `<div class="group-header">Bookmarks</div><div class="group">${bms.map(row).join('') || '<div class="row"><div class="grow muted">Tap ☆ to bookmark a page</div></div>'}</div>
                    <div class="group-header">History</div><div class="group">${hist.slice(0, 25).map(row).join('') || '<div class="row"><div class="grow muted">Nothing yet</div></div>'}</div>
                    ${hist.length ? '<div style="padding:0 16px 20px"><button class="btn block secondary" data-clear>Clear history</button></div>' : ''}`;
                body.addEventListener('click', (e) => {
                    const u = e.target.closest('[data-url]');
                    if (u) { api.close(); Browser.go(u.dataset.url); }
                    if (e.target.closest('[data-clear]')) { brStore.set('history', []); api.close(); }
                });
            },
        });
    },

    async sendForm(btn) {
        const f = btn.closest('.bs-form');
        const val = (n) => ($(`[name=${n}]`, f).value || '').trim();
        if (!val('message')) return UI.toast('Write a message first', 'fa-solid fa-circle-exclamation');
        btn.disabled = true;
        const r = await rpc('webForm', { url: this.stack[this.idx], name: val('name') || (Phone.profile && Phone.profile.name) || '', email: val('email') || (Phone.profile && Phone.profile.email) || '', message: val('message') });
        btn.disabled = false;
        if (r && r.ok) { f.innerHTML = '<div class="bs-sent"><i class="fa-solid fa-circle-check"></i> Message sent — thank you!</div>'; return; }
        UI.alert({ title: 'Couldn’t send', message: (r && r.error) || 'Try again later' });
    },
};

function brLetter(url) { const h = brSplit(url).host || '?'; return h.replace(/^www\./, '')[0].toUpperCase(); }
function brColorOf(url) { const h = brSplit(url).host || ''; let n = 0; for (const ch of h) n = (n * 31 + ch.charCodeAt(0)) >>> 0; return BR_COLORS[n % (BR_COLORS.length - 1)]; }

/* ---------------------------------------------------------------------
   player websites (OPS Web builder) — data in, escaped HTML out
   --------------------------------------------------------------------- */
const BR_FONTS = { sans: 'Inter, "Segoe UI", Arial, sans-serif', serif: 'Georgia, "Times New Roman", serif', mono: 'ui-monospace, Menlo, Consolas, monospace', rounded: '"Nunito", "Arial Rounded MT Bold", Inter, sans-serif' };

function brBlock(b) {
    const link = (label, href, cls = 'bs-btn') => (label ? `<a class="${cls}" ${href ? `data-href="${esc(href)}"` : ''}>${esc(label)}</a>` : '');
    const items = b.items || [];
    switch (b.t) {
        case 'hero':
            return `<section class="bs-hero ${b.align === 'left' ? 'left' : ''}" ${b.image ? `style="background-image:linear-gradient(rgba(0,0,0,.45),rgba(0,0,0,.45)),url('${esc(b.image)}')"` : ''}>
                <h1>${esc(b.title || '')}</h1>${b.text ? `<p>${esc(b.text)}</p>` : ''}${link(b.button, b.href)}</section>`;
        case 'text': return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-text">${brPara(b.body)}</div></section>`;
        case 'image': return b.url ? `<figure class="bs-sec bs-img"><img src="${esc(b.url)}" loading="lazy" referrerpolicy="no-referrer" alt="">${b.caption ? `<figcaption>${esc(b.caption)}</figcaption>` : ''}</figure>` : '';
        case 'features':
            return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-feats">${items.map((it) => `<div class="bs-feat"><i class="fa-solid fa-${esc(it.icon || 'star')}"></i><b>${esc(it.title || '')}</b><span>${esc(it.text || '')}</span></div>`).join('')}</div></section>`;
        case 'list':
            return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-list">${items.map((it) => `<div><div class="bs-li-top"><b>${esc(it.name || '')}</b><i></i><span>${esc(it.price || '')}</span></div>${it.text ? `<small>${esc(it.text)}</small>` : ''}</div>`).join('')}</div></section>`;
        case 'gallery':
            return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-gal">${items.filter((it) => it.url).map((it) => `<figure><img src="${esc(it.url)}" loading="lazy" referrerpolicy="no-referrer" alt="">${it.caption ? `<figcaption>${esc(it.caption)}</figcaption>` : ''}</figure>`).join('')}</div></section>`;
        case 'hours': return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-hours">${items.map((it) => `<div><span>${esc(it.day || '')}</span><b>${esc(it.time || '')}</b></div>`).join('')}</div></section>`;
        case 'links': return `<section class="bs-sec">${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}<div class="bs-links">${items.map((it) => link(it.label, it.href, 'bs-btn ghost')).join('')}</div></section>`;
        case 'quote': return `<section class="bs-sec"><blockquote class="bs-quote">“${esc(b.text || '')}”${b.by ? `<cite>— ${esc(b.by)}</cite>` : ''}</blockquote></section>`;
        case 'cta': return `<section class="bs-cta"><h2>${esc(b.title || '')}</h2>${b.text ? `<p>${esc(b.text)}</p>` : ''}${link(b.button, b.href, 'bs-btn inv')}</section>`;
        case 'divider': return '<hr class="bs-hr">';
        case 'contact': return `<section class="bs-sec" data-contact>${b.heading ? `<h2>${esc(b.heading)}</h2>` : ''}${b.text ? `<div class="bs-text">${brPara(b.text)}</div>` : ''}%CONTACT%${b.form ? `<div class="bs-form">
                <input name="name" placeholder="Your name"><input name="email" placeholder="Your email"><textarea name="message" rows="4" placeholder="Message"></textarea>
                <button class="bs-btn" data-act="send-form">Send message</button></div>` : ''}</section>`;
        default: return '';
    }
}

function brSiteHtml(r) {
    const s = r.site || {};
    const th = s.theme || {};
    const c = s.contact || {};
    const contact = [c.email && `<a data-href="mailto:${esc(c.email)}"><i class="fa-solid fa-envelope"></i>${esc(c.email)}</a>`, c.phone && `<span><i class="fa-solid fa-phone"></i>${esc(c.phone)}</span>`,
        c.address && `<span><i class="fa-solid fa-location-dot"></i>${esc(c.address)}</span>`].filter(Boolean).join('');
    const body = r.notFound
        ? `<section class="bs-sec bs-404"><h1>404</h1><p>This page doesn’t exist.</p><a class="bs-btn" data-href="/">Go to the home page</a></section>`
        : (r.page.blocks || []).map(brBlock).join('').replace(/%CONTACT%/g, contact ? `<div class="bs-contact">${contact}</div>` : '') || '<section class="bs-sec bs-404"><p>This page is empty.</p></section>';
    const nav = (s.nav || []).length > 1 ? `<nav>${s.nav.map((p) => `<a data-href="/${esc(p.slug)}" class="${r.page && r.page.slug === p.slug ? 'on' : ''}">${esc(p.title)}</a>`).join('')}</nav>` : '';
    return `<div class="bs ${th.mode === 'dark' ? 'dark' : ''}" style="--sc:${esc(th.color || '#0a84ff')};--sf:${BR_FONTS[th.font] || BR_FONTS.sans}">
        ${r.warning ? '<div class="bs-unsafe"><i class="fa-solid fa-triangle-exclamation"></i> Not secure — the certificate isn’t valid</div>' : ''}
        <header class="bs-head"><a data-href="/" class="bs-logo">${esc(s.title || '')}</a>${nav}</header>
        ${body}
        <footer class="bs-foot">${contact ? `<div class="bs-contact">${contact}</div>` : ''}<div>© ${new Date().getFullYear()} ${esc(s.title || '')} · ${esc(r.hosted || '')}</div></footer></div>`;
}

/* ---------------------------------------------------------------------
   built-in sites
   --------------------------------------------------------------------- */
const brWebBar = (brand, color, icon, links, path) => `<header class="bi-head" style="--bc:${color}"><a data-nav="/" class="bi-brand"><i class="fa-solid fa-${icon}"></i>${brand}</a>
    <nav>${links.map(([p, l]) => `<a data-nav="${p}" class="${path === p || (p !== '/' && path.startsWith(p)) ? 'on' : ''}">${l}</a>`).join('')}</nav></header>`;
const brSpin = '<div class="spinner" style="margin:60px auto"></div>';
const brFail = (r) => UI.alert({ title: 'Couldn’t do that', message: (r && r.error) || 'Try again in a moment.' });

const BrInternal = {
    /* ----------------------------- OPS Search */
    async search(pg, data, q) {
        const box = (v = '') => `<form class="bi-search" data-search><i class="fa-solid fa-magnifying-glass"></i><input name="q" value="${esc(v)}" placeholder="Search the web" autocomplete="off"></form>`;
        const wire = () => { const f = $('[data-search]', pg); if (f) f.addEventListener('submit', (e) => { e.preventDefault(); const v = f.q.value.trim(); if (v) Browser.nav('/search', { q: v }); }); };
        if (data.path === '/search' && q.q) {
            pg.innerHTML = `<div class="bi-sr"><div class="bi-sr-top"><a data-nav="/" class="bi-logo sm">OPS <b>Search</b></a>${box(q.q)}</div><div class="bi-res">${brSpin}</div></div>`;
            wire();
            const r = await rpc('webSearch', { q: q.q });
            const list = (r && r.results) || [];
            const asUrl = brNormalize(q.q);
            const looksLikeSite = asUrl && !asUrl.startsWith(BR_HOME + '/search');
            $('.bi-res', pg).innerHTML = (looksLikeSite ? `<a class="bi-goto" data-go="${esc(asUrl)}"><i class="fa-solid fa-arrow-right"></i> Go to <b>${esc(q.q)}</b></a>` : '')
                + `<div class="muted bi-count">${r ? `About ${r.total || 0} result${r.total === 1 ? '' : 's'}` : 'Search isn’t available right now'}</div>`
                + (list.map((x) => `<div class="bi-hit"><div class="bi-hit-url"><span class="bi-fav" style="background:${x.color || brColorOf(x.url)}">${esc(brLetter(x.url))}</span><span>${esc(x.url.replace(/^https?:\/\//, ''))}</span>${x.secure ? '' : '<em>Not secure</em>'}</div>
                    <a data-go="${esc(x.url)}">${esc(x.title)}</a><p>${esc(x.snippet || '')}</p></div>`).join('')
                || `<div class="bi-none">No results for <b>${esc(q.q)}</b>. ${looksLikeSite ? '' : 'Try fewer words.'}</div>`);
            return;
        }
        pg.innerHTML = `<div class="bi-home"><div class="bi-logo">OPS <b>Search</b></div>${box()}
            <div class="bi-tiles">${[['ops-domains', 'opsdomains.sa', 'globe', '#ffd60a'], ['ops-web', 'opsweb.sa', 'code', '#ff9f0a'], ['network', 'opsnetwork.sa', 'network-wired', '#0a84ff'], ['secure', 'opssecure.sa', 'video', '#ff375f']]
                .map(([, h, i, c]) => `<a class="bi-tile" data-go="https://${h}"><span style="--c:${c}"><i class="fa-solid fa-${i}"></i></span>${h.replace('.sa', '')}</a>`).join('')}</div>
            ${(data.popular || []).length ? `<div class="bi-pop"><h3>Popular in Los Santos</h3>${data.popular.map((p) => { const u = 'https://' + (p.host === '@' ? '' : p.host + '.') + p.domain; return `<a data-go="${esc(u)}"><span class="bi-fav" style="background:${brColorOf(u)}">${esc(brLetter(u))}</span><div><b>${esc(p.title)}</b><small>${esc(p.description || u.replace('https://', ''))}</small></div></a>`; }).join('')}</div>` : ''}
            <div class="bi-foot">Get your own site: <a data-go="https://opsdomains.sa">a domain</a> + <a data-go="https://opsweb.sa">OPS Web</a></div></div>`;
        wire();
        setTimeout(() => { const i = $('[data-search] input', pg); if (i && !Laptop.active) i.blur(); }, 0);
    },

    /* ----------------------------- OPS Domains */
    async domains(pg, data, q) {
        const path = data.path || '/';
        const head = brWebBar('OPS <b>Domains</b>', '#ffd60a', 'globe', [['/', 'Find'], ['/my', 'My domains'], ['/whois', 'WHOIS'], ['/transfer', 'Transfer']], path);
        const out = (html) => { pg.innerHTML = `<div class="bi bi-dom">${head}<div class="bi-body">${html}</div></div>`; return $('.bi-body', pg); };

        if (path === '/' || path === '') {
            const body = out(`<div class="bi-hero"><h1>Find your name online</h1><p>.ls · .sa · .biz · .shop · .club — from ${brMoney(Math.min(...(data.tlds || [{ price: 20 }]).filter((t) => t.price > 0).map((t) => t.price)))} a period</p>
                <form class="bi-search" data-find><i class="fa-solid fa-magnifying-glass"></i><input name="q" value="${esc(q.q || '')}" placeholder="yourname" autocomplete="off"><button>Search</button></form></div>
                <div class="bi-results"></div>
                <div class="bi-cards">${(data.tlds || []).map((t) => `<div class="bi-card"><b>.${esc(t.tld)}</b><span>${esc(t.desc || '')}</span><em>${t.price ? brMoney(t.price) : 'restricted'}</em></div>`).join('')}</div>
                <p class="bi-note">Every domain includes free DNS hosting, WHOIS privacy and parking. Renews automatically every billing period from your bank.</p>`);
            const res = $('.bi-results', body);
            const find = async (v) => {
                res.innerHTML = brSpin;
                const r = await rpc('webDomains', { action: 'check', name: v });
                if (!r || r.error) { res.innerHTML = `<div class="bi-none">${esc((r && r.error) || 'Search failed')}</div>`; return; }
                res.innerHTML = `<div class="bi-list">${r.list.map((x) => `<div class="bi-li ${x.available ? '' : 'off'}"><div><b>${esc(x.name)}</b><small>${x.available ? esc(x.desc || '') : x.restricted ? 'Government & emergency services only' : 'Taken'}</small></div>
                    ${x.available ? `<b>${brMoney(x.price)}</b><button class="bi-btn" data-reg="${esc(x.name)}" data-price="${x.price}">Register</button>` : x.taken ? `<button class="bi-btn ghost" data-whois="${esc(x.name)}">WHOIS</button>` : ''}</div>`).join('')}</div>`;
            };
            $('[data-find]', body).addEventListener('submit', (e) => { e.preventDefault(); const v = e.target.q.value.trim(); if (v) find(v); });
            body.addEventListener('click', async (e) => {
                const w = e.target.closest('[data-whois]');
                if (w) return Browser.nav('/whois', { q: w.dataset.whois });
                const b = e.target.closest('[data-reg]');
                if (!b) return;
                if (!await UI.confirm(`Register ${b.dataset.reg}?`, `${brMoney(b.dataset.price)} from your bank for one billing period. It renews automatically — turn that off any time.`, 'Register')) return;
                b.disabled = true;
                const r = await rpc('webDomains', { action: 'register', name: b.dataset.reg });
                if (!r || !r.ok) { b.disabled = false; return brFail(r); }
                UI.toast(`${r.name} is yours!`, 'fa-solid fa-globe');
                Browser.nav('/domain/' + r.id);
            });
            if (q.q) find(q.q.replace(/\..*$/, ''));
            return;
        }

        if (path === '/whois') {
            const body = out(`<h2>WHOIS lookup</h2><p class="muted">Who owns a domain, and when it expires.</p>
                <form class="bi-search" data-w><i class="fa-solid fa-magnifying-glass"></i><input name="q" value="${esc(q.q || '')}" placeholder="example.ls"><button>Look up</button></form><div class="bi-whois"></div>`);
            const show = async (v) => {
                const box = $('.bi-whois', body);
                box.innerHTML = brSpin;
                const r = await rpc('webDomains', { action: 'whois', name: v });
                if (!r) { box.innerHTML = ''; return; }
                box.innerHTML = r.registered ? `<pre class="bi-pre">Domain Name: ${esc(r.name.toUpperCase())}
Registrar: ${esc(r.registrar)}
Registrant: ${esc(r.registrant || '')}
Status: ${esc(r.status)}${r.locked ? ' · clientTransferProhibited' : ''}
${r.created ? `Created: ${brDate(r.created)}\n` : ''}${r.expires ? `Expires: ${brDate(r.expires)}\n` : ''}Name Servers: ${esc((r.nameservers || []).join(', '))}</pre>`
                    : `<div class="bi-none"><b>${esc(r.name)}</b> isn’t registered. <a data-nav="/?q=${esc(r.name)}">Register it</a></div>`;
                $('[data-nav]', box) && $('[data-nav]', box).addEventListener('click', (e) => { e.stopPropagation(); Browser.nav('/', { q: r.name }); });
            };
            $('[data-w]', body).addEventListener('submit', (e) => { e.preventDefault(); const v = e.target.q.value.trim(); if (v) show(v); });
            if (q.q) show(q.q);
            return;
        }

        if (path === '/transfer') {
            const body = out(`<h2>Receive a domain</h2><p class="muted">The owner unlocks the domain on <b>My domains</b> and gives you its transfer code.</p>
                <div class="bi-form"><input data-f="name" placeholder="domain (e.g. bestcars.ls)"><input data-f="code" placeholder="transfer code" style="text-transform:uppercase"><button class="bi-btn" data-go-t>Transfer to me</button></div>`);
            $('[data-go-t]', body).addEventListener('click', async () => {
                const r = await rpc('webDomains', { action: 'accept', name: $('[data-f=name]', body).value.trim(), code: $('[data-f=code]', body).value.trim() });
                if (!r || !r.ok) return brFail(r);
                UI.toast('Transferred to you', 'fa-solid fa-globe');
                Browser.nav('/my');
            });
            return;
        }

        if (path === '/my') {
            const body = out(brSpin);
            const r = await rpc('webDomains', { action: 'mine' });
            if (!r) { body.innerHTML = '<div class="bi-none">Can’t reach OPS Domains.</div>'; return; }
            const row = (d) => `<a class="bi-li" data-nav="/domain/${d.id}"><div><b>${esc(d.name)}</b><small>${d.status === 'active' ? 'Renews' : 'Expired'} ${brDate(d.expires)}${d.auto ? ' · auto-renew' : ''}</small></div>${brChip(d.status, BR_STATUS[d.status] || '#8e8e93')}<i class="fa-solid fa-chevron-right muted"></i></a>`;
            body.innerHTML = `<h2>My domains</h2><div class="bi-list">${r.domains.map(row).join('') || '<div class="bi-none">No domains yet. <a data-nav="/">Find one</a></div>'}</div>
                ${(r.work || []).map((w) => `<h3 class="bi-h3"><i class="fa-solid fa-briefcase"></i> ${esc(w.ref)} · ${esc(w.customer || '')}</h3><div class="bi-list">${w.domains.map(row).join('') || '<div class="bi-none">This customer has no domains.</div>'}</div>`).join('')}`;
            return;
        }

        const m = path.match(/^\/domain\/(\d+)$/);
        if (m) {
            const body = out(brSpin);
            const draw = async () => {
                const r = await rpc('webDomains', { action: 'get', id: +m[1] });
                if (!r || !r.domain) { body.innerHTML = `<div class="bi-none">${esc((r && r.error) || 'Not found')}</div>`; return; }
                const d = r.domain;
                const sw = (f, on, label, sub) => `<div class="bi-set"><div><b>${label}</b><small>${sub}</small></div>${UI.switchHtml(on, `data-set="${f}"`)}</div>`;
                body.innerHTML = `<div class="bi-domhead"><div><h2>${esc(d.name)}</h2><small>${d.status === 'active' ? 'Renews' : 'Expired'} ${brDate(d.expires)} · ${brMoney(d.price)} a period</small></div>${brChip(d.status, BR_STATUS[d.status] || '#8e8e93')}</div>
                    <div class="bi-actions"><button class="bi-btn" data-a="renew">Renew</button><button class="bi-btn ghost" data-go="https://${esc(d.name)}">Visit</button><button class="bi-btn ghost" data-go="https://opsweb.sa/panel">Build a site</button></div>
                    <div class="bi-box">${sw('auto', d.auto, 'Auto-renew', 'Charged to your bank when it’s due')}${sw('privacy', d.privacy, 'WHOIS privacy', 'Hide your name in WHOIS')}${sw('locked', d.locked, 'Transfer lock', d.locked ? 'Locked — can’t be transferred' : 'Unlocked')}
                        ${d.locked ? '' : `<div class="bi-set"><div><b>Transfer code</b><small>${d.transferCode ? `Give <b class="mono">${esc(d.transferCode)}</b> to the new owner` : 'Generate a code for the new owner'}</small></div><button class="bi-btn ghost" data-a="code">${d.transferCode ? 'New code' : 'Get code'}</button></div>`}</div>
                    <h3 class="bi-h3">DNS records <button class="bi-btn sm" data-a="add">+ Add</button></h3>
                    <div class="bi-dns">${(d.records || []).map((x) => `<div class="bi-rec" data-rid="${x.id}"><span class="t">${esc(x.type)}</span><span class="h">${esc(x.host)}</span><span class="v">${x.type === 'MX' ? x.prio + ' ' : ''}${esc(x.value)}</span><i class="fa-solid fa-pen muted"></i></div>`).join('') || '<div class="bi-none">No records — the domain doesn’t point anywhere.</div>'}</div>
                    <p class="bi-note">Nameservers: ns1.opsdomains.sa, ns2.opsdomains.sa · OPS Web hosting is <span class="mono">198.18.10.80</span>, mail is <span class="mono">mx.opsweb.sa</span>.</p>
                    <h3 class="bi-h3">Security certificate</h3>
                    <div class="bi-box"><div class="bi-set"><div><b>${d.cert ? `<i class="fa-solid fa-lock" style="color:#30d158"></i> ${esc(d.cert.subject)}` : 'No certificate'}</b><small>${d.cert ? `${esc(d.cert.kind.toUpperCase())} · valid until ${brDate(d.cert.expires)} · ${esc(d.cert.issuer)}` : 'Visitors see “Not secure”'}</small></div><button class="bi-btn ghost" data-a="ssl">${d.cert ? 'Reissue' : 'Get one'}</button></div></div>`;
                body._d = d;
            };
            await draw();
            body.addEventListener('change', async (e) => {
                const s = e.target.closest('[data-set]');
                if (!s) return;
                const r = await rpc('webDomains', { action: 'set', id: +m[1], field: s.dataset.set, value: s.checked });
                if (!r || !r.ok) brFail(r);
                draw();
            });
            body.addEventListener('click', brOneAtATime(async (e) => {
                const d = body._d;
                const rec = e.target.closest('[data-rid]');
                const a = e.target.closest('[data-a]');
                if (rec) return brDnsSheet(d, d.records.find((x) => x.id === +rec.dataset.rid), draw);
                if (!a) return;
                if (a.dataset.a === 'add') return brDnsSheet(d, null, draw);
                if (a.dataset.a === 'renew') {
                    if (!await UI.confirm(`Renew ${d.name}?`, `${brMoney(d.price)} for one more period.`, 'Renew')) return;
                    const r = await rpc('webDomains', { action: 'renew', id: d.id });
                    if (!r || !r.ok) return brFail(r);
                    UI.toast('Renewed'); draw();
                }
                if (a.dataset.a === 'code') { const r = await rpc('webDomains', { action: 'transfer_code', id: d.id }); if (!r || !r.ok) return brFail(r); draw(); }
                if (a.dataset.a === 'ssl') brSslSheet(d, draw);
            }));
            return;
        }
        out('<div class="bi-none">Page not found. <a data-nav="/">OPS Domains home</a></div>');
    },

    /* ----------------------------- OPS Web */
    async web(pg, data, q) {
        const path = data.path || '/';
        const head = brWebBar('OPS <b>Web</b>', '#ff9f0a', 'code', [['/', 'Plans'], ['/panel', 'Control panel']], path);
        const out = (html) => { pg.innerHTML = `<div class="bi bi-web">${head}<div class="bi-body">${html}</div></div>`; return $('.bi-body', pg); };

        if (path === '/' || path === '') {
            const body = out(`<div class="bi-hero"><h1>Your website, live today</h1><p>Drag-and-drop builder, free SSL, business email on your domain.</p></div>
                <div class="bi-plans">${(data.plans || []).map((p, i) => `<div class="bi-plan ${i === 1 ? 'hot' : ''}">${i === 1 ? '<em>Most popular</em>' : ''}<h3>${esc(p.name)}</h3><div class="bi-price">${brMoney(p.price)}<small>/period</small></div>
                    <ul><li>${p.sites} website${p.sites === 1 ? '' : 's'}</li><li>${p.mailboxes} mailboxes</li><li>Free ${esc(String(p.ssl).toUpperCase())} SSL</li><li>Unlimited pages & visitors</li></ul>
                    <button class="bi-btn" data-buy="${esc(p.code)}" data-price="${p.price}" data-name="${esc(p.name)}">Choose ${esc(p.name)}</button></div>`).join('')}</div>
                <h3 class="bi-h3">Rather we did it?</h3>
                <div class="bi-cards">${(data.services || []).map((s) => `<div class="bi-card"><b>${esc({ web_build: 'Website build', web_ssl: 'SSL set-up', web_mail: 'Email set-up' }[s.code] || s.code)}</b><span>${esc(s.desc)}</span><em>${brMoney(s.price)}</em></div>`).join('')}</div>
                <p class="bi-note">Already have a server? Point your domain at your own OPS Network static IP and build the site here with the self-hosted option — forward ports 80/443 on your router.</p>`);
            body.addEventListener('click', brOneAtATime(async (e) => {
                const b = e.target.closest('[data-buy]');
                if (!b) return;
                if (!await UI.confirm(`OPS Web ${b.dataset.name}`, `${brMoney(b.dataset.price)} now, then every billing period.`, 'Buy')) return;
                const r = await rpc('webHost', { action: 'buy', plan: b.dataset.buy });
                if (!r || !r.ok) return brFail(r);
                UI.toast('Welcome to OPS Web', 'fa-solid fa-code');
                Browser.nav('/panel');
            }));
            return;
        }

        if (path === '/panel') {
            const body = out(brSpin);
            const r = await rpc('webHost', { action: 'mine' });
            if (!r) { body.innerHTML = '<div class="bi-none">Can’t reach OPS Web.</div>'; return; }
            const siteRow = (s) => `<a class="bi-li" data-nav="/site/${s.id}"><div><b>${esc(s.title)}</b><small>${s.host ? esc(s.host) : 'No address yet'}${s.selfIp ? ' · self-hosted ' + esc(s.selfIp) : ''}${s.host && !s.live ? ' · <span style="color:#ff9f0a">DNS not pointing here</span>' : ''}</small></div>
                ${s.status === 'taken_down' ? brChip('taken down', '#ff3b30') : brChip(s.published ? 'live' : 'draft', s.published ? '#30d158' : '#8e8e93')}<i class="fa-solid fa-chevron-right muted"></i></a>`;
            body.innerHTML = `<h2>Control panel</h2>
                ${r.hosting.length ? '' : `<div class="bi-callout">You don’t have hosting yet. <a data-nav="/">Pick a plan</a> — or host a site yourself on a static IP.</div>`}
                ${r.hosting.map((h) => `<div class="bi-box"><div class="bi-set"><div><b>${esc(h.name || h.plan)} hosting</b><small>${h.sites}/${h.maxSites} sites · ${brMoney(h.price)} · next bill ${brDate(h.next)}${h.overdue ? ' · <span style="color:#ff3b30">payment overdue</span>' : ''}</small></div>${brChip(h.status, BR_STATUS[h.status] || '#8e8e93')}</div>
                    <div class="bi-actions">${h.overdue || h.status === 'suspended' ? `<button class="bi-btn" data-h="pay" data-id="${h.id}">Pay ${brMoney(h.price)}</button>` : ''}<button class="bi-btn ghost" data-h="plan" data-id="${h.id}">Change plan</button><button class="bi-btn ghost" data-h="cancel" data-id="${h.id}">Cancel</button></div></div>`).join('')}
                <h3 class="bi-h3">Websites <button class="bi-btn sm" data-new>+ New site</button></h3>
                <div class="bi-list">${r.sites.map(siteRow).join('') || '<div class="bi-none">No sites yet.</div>'}</div>
                <h3 class="bi-h3">Email <button class="bi-btn sm" data-mail>+ Mailbox</button></h3>
                <div class="bi-list">${r.mailboxes.map((m) => `<div class="bi-li"><div><b>${esc(m.address)}</b><small>Arrives on ${esc(m.deliver_to)}${+m.catch_all ? ' · catch-all' : ''}</small></div><button class="bi-btn ghost sm" data-delbox="${m.id}">Remove</button></div>`).join('')
                    || `<div class="bi-none">${r.limits.mailboxes ? 'No mailboxes yet — create info@yourdomain.' : 'Email comes with any hosting plan.'}</div>`}</div>
                <p class="bi-note">${r.limits.mailboxes} mailbox${r.limits.mailboxes === 1 ? '' : 'es'} on your plans · mail arrives in the phone’s Mail app (the MX record is set for you).</p>
                <h3 class="bi-h3">Have us do it</h3>
                <div class="bi-actions">${r.services.map((s) => `<button class="bi-btn ghost" data-order="${esc(s.code)}">${esc({ web_build: 'Build my site', web_ssl: 'Set up SSL', web_mail: 'Set up email' }[s.code] || s.code)} · ${brMoney(s.price)}</button>`).join('')}</div>
                ${(r.work || []).map((w) => `<h3 class="bi-h3"><i class="fa-solid fa-briefcase"></i> ${esc(w.ref)} · ${esc(w.customer || '')}</h3><div class="bi-list">${w.sites.map(siteRow).join('') || '<div class="bi-none">The customer has no sites yet — they need to create one.</div>'}</div>`).join('')}`;
            body.addEventListener('click', brOneAtATime(async (e) => {
                const h = e.target.closest('[data-h]');
                if (h) {
                    const id = +h.dataset.id;
                    if (h.dataset.h === 'pay') { const x = await rpc('webHost', { action: 'hosting_pay', id }); if (!x || !x.ok) return brFail(x); UI.toast('Paid'); return Browser.load(Browser.stack[Browser.idx]); }
                    if (h.dataset.h === 'cancel') { if (!await UI.confirm('Cancel hosting?', 'Its websites go offline.', 'Cancel hosting', true)) return; const x = await rpc('webHost', { action: 'hosting_cancel', id }); if (!x || !x.ok) return brFail(x); return Browser.load(Browser.stack[Browser.idx]); }
                    if (h.dataset.h === 'plan') {
                        const p = await UI.pick('Change plan', r.plans.map((x) => ({ label: `${x.name} · ${brMoney(x.price)}`, value: x.code })));
                        if (!p) return;
                        const x = await rpc('webHost', { action: 'hosting_plan', id, plan: p }); if (!x || !x.ok) return brFail(x);
                        return Browser.load(Browser.stack[Browser.idx]);
                    }
                }
                if (e.target.closest('[data-new]')) return brNewSite(r);
                if (e.target.closest('[data-mail]')) return brMailboxSheet(r);
                const del = e.target.closest('[data-delbox]');
                if (del) { if (!await UI.confirm('Remove mailbox?', 'Mail to it will bounce.', 'Remove', true)) return; const x = await rpc('webHost', { action: 'mailbox_del', id: +del.dataset.delbox }); if (!x || !x.ok) return brFail(x); return Browser.load(Browser.stack[Browser.idx]); }
                const o = e.target.closest('[data-order]');
                if (o) return brOrderSheet(r, o.dataset.order);
            }));
            return;
        }

        const sm = path.match(/^\/site\/(\d+)(?:\/page\/(\d+))?$/);
        if (sm) return brEditor(out, +sm[1], sm[2] !== undefined ? +sm[2] : null);
        out('<div class="bi-none">Page not found.</div>');
    },

    /* ----------------------------- OPS Cloud */
    async cloud(pg, data) {
        const path = data.path || '/';
        const head = brWebBar('OPS <b>Cloud</b>', '#40c8e0', 'cloud', [['/', 'Pricing'], ['/console', 'Console']], path);
        const out = (html) => { pg.innerHTML = `<div class="bi bi-cloud">${head}<div class="bi-body">${html}</div></div>`; return $('.bi-body', pg); };
        const ST = { running: ['Running', '#30d158'], provisioning: ['Starting', '#0a84ff'], stopped: ['Stopped', '#8e8e93'], host_down: ['Host down', '#ff3b30'], no_capacity: ['Waiting for capacity', '#ff9f0a'], suspended: ['Suspended', '#ff3b30'] };
        const chipOf = (s) => brChip((ST[s] || [s])[0], (ST[s] || [0, '#8e8e93'])[1]);
        const capLine = (cap) => Object.entries(cap || {}).map(([r, c]) => `${esc(r)}: ${c.hosts} host${c.hosts === 1 ? '' : 's'} · ${Math.max(0, c.ram - c.usedRam)} GB free${c.waiting ? ' · <b style="color:#ff9f0a">full</b>' : ''}`).join(' &nbsp;·&nbsp; ') || 'No regions online yet';
        if (path === '/' || path === '') {
            const body = out(`<div class="bi-hero"><h1>Servers in seconds</h1><p>Virtual servers in OPS Data’s Los Santos data halls. Host your OPS Web site on your own server, or run anything you like.</p></div>
                <div class="bi-plans">${(data.plans || []).map((p, i) => `<div class="bi-plan ${i === 2 ? 'hot' : ''}">${i === 2 ? '<em>Popular</em>' : ''}<h3>${esc(p.name)}</h3><div class="bi-price">${brMoney(p.price)}<small>/period</small></div>
                    <ul><li>${p.vcpu} vCPU</li><li>${p.ram} GB RAM</li><li>${p.disk} GB SSD</li><li>Public IP + firewall</li></ul><button class="bi-btn" data-nav="/console">Deploy</button></div>`).join('')}</div>
                <p class="bi-note">Regions: ${capLine(data.capacity)}. Servers restart automatically on another host if theirs fails.</p>`);
            return body;
        }
        if (path === '/console') {
            const body = out(brSpin);
            const r = await rpc('webCloud', { action: 'mine' });
            if (!r) { body.innerHTML = '<div class="bi-none">Can’t reach OPS Cloud.</div>'; return; }
            const row = (v) => `<a class="bi-li" data-nav="/vm/${v.id}"><span class="bi-fav" style="background:#40c8e0"><i class="fa-solid fa-server" style="font-size:11px"></i></span><div><b>${esc(v.name)}</b><small class="mono">${esc(v.ip || '—')} · ${v.vcpu} vCPU · ${v.ram} GB · ${esc(v.imageName)} · ${esc(v.region)}</small></div>${chipOf(v.status === 'suspended' ? 'suspended' : v.state)}<i class="fa-solid fa-chevron-right muted"></i></a>`;
            body.innerHTML = `<h2>Your servers <button class="bi-btn sm" data-new style="float:right">+ Create server</button></h2>
                <div class="bi-list" style="margin-top:12px">${r.vms.map(row).join('') || '<div class="bi-none">No servers yet.</div>'}</div>
                <p class="bi-note">Capacity: ${capLine(r.capacity)}</p>
                <h3 class="bi-h3">Have us do it</h3>
                <div class="bi-actions"><button class="bi-btn ghost" data-order="web_cloud_setup">Set up my server & site · $150</button><button class="bi-btn ghost" data-order="web_cloud_migrate">Migrate my website here · $250</button></div>
                ${(r.work || []).map((w) => `<h3 class="bi-h3"><i class="fa-solid fa-briefcase"></i> ${esc(w.ref)} · ${esc(w.customer || '')}</h3><div class="bi-list">${w.vms.map(row).join('') || '<div class="bi-none">The customer has no servers yet.</div>'}</div>`).join('')}`;
            body.addEventListener('click', async (e) => {
                if (e.target.closest('[data-new]')) return brCloudNew(r);
                const o = e.target.closest('[data-order]');
                if (o) {
                    const doms = await rpc('webDomains', { action: 'mine' });
                    const list = (doms && doms.domains) || [];
                    if (!list.length) return UI.alert({ title: 'You need a domain', message: 'Register one on opsdomains.sa first.' });
                    brFormSheet(o.dataset.order === 'web_cloud_setup' ? 'Set up my server' : 'Migrate my website', [
                        { k: 'domain', label: 'Domain', options: list.map((d) => ({ label: d.name, value: d.id })) }, { k: 'note', label: 'Brief', ph: 'Anything we should know?' }],
                    async (v) => {
                        const x = await rpc('webCloud', { action: 'order', code: o.dataset.order, domain: +v.domain, note: v.note });
                        if (!x || !x.ok) { brFail(x); return false; }
                        UI.alert({ title: 'Booked', message: `Job ${x.ref} — an OPS Cloud engineer will pick it up. You pay ${brMoney(x.price)} when it’s done.` });
                    }, '<div class="group-footer">Create the server first (OPS Web server image) — we do the rest.</div>');
                }
            });
            return;
        }
        const m = path.match(/^\/vm\/(\d+)$/);
        if (!m) { out('<div class="bi-none">Page not found.</div>'); return; }
        const body = out(brSpin);
        const draw = async () => {
            const r = await rpc('webCloud', { action: 'get', id: +m[1] });
            if (!r || !r.vm) { body.innerHTML = `<div class="bi-none">${esc((r && r.error) || 'Not found')}</div>`; return; }
            const v = r.vm;
            const running = v.state === 'running';
            body.innerHTML = `<div class="be-bar"><a data-nav="/console"><i class="fa-solid fa-chevron-left"></i> Console</a></div>
                <div class="bi-domhead"><div><h2>${esc(v.name)}</h2><small class="mono">${esc(v.ip || '')} · ${esc(v.region)}${v.host ? ' · ' + esc(v.host) : ''}</small></div>${chipOf(v.status === 'suspended' ? 'suspended' : v.state)}</div>
                ${v.overdue || v.status === 'suspended' ? `<div class="bi-callout bad">Payment overdue. <button class="bi-btn sm" data-a="pay">Pay ${brMoney(v.price)}</button></div>` : ''}
                ${v.state === 'host_down' ? '<div class="bi-callout bad"><i class="fa-solid fa-triangle-exclamation"></i> Its physical host failed and there’s no free capacity to restart it — OPS Data engineers have been called.</div>' : ''}
                ${v.state === 'no_capacity' ? '<div class="bi-callout"><i class="fa-solid fa-hourglass-half"></i> Queued: the region is full. It starts as soon as OPS Data adds servers.</div>' : ''}
                <div class="bi-actions">${v.desired === 'running' ? `<button class="bi-btn ghost" data-a="stop">Shut down</button>${running ? '<button class="bi-btn ghost" data-a="reboot">Reboot</button>' : ''}` : '<button class="bi-btn" data-a="start">Start</button>'}
                    <button class="bi-btn ghost" data-a="resize">Resize</button><button class="bi-btn ghost" data-a="rename">Rename</button></div>
                <div class="bi-box">${[['Size', `${v.vcpu} vCPU · ${v.ram} GB RAM · ${v.disk} GB SSD (${esc(v.plan)})`], ['Image', esc(v.imageName)], ['Price', `${brMoney(v.price)} / period · next ${brDate(v.next)}`],
                    ['Up since', v.booted && running ? brDate(v.booted) : '—']].map(([k, val]) => `<div class="bi-set"><div><b>${k}</b><small>${val}</small></div></div>`).join('')}</div>
                <h3 class="bi-h3">Firewall · open ports <button class="bi-btn sm" data-a="fw">Edit</button></h3>
                <div class="bi-box"><div class="bi-set"><div><b class="mono">${(v.firewall || []).join(', ') || 'nothing open'}</b><small>80 / 443 must be open to host a website · 22 = SSH</small></div></div></div>
                <h3 class="bi-h3">Websites on this server</h3>
                <div class="bi-list">${(v.sites || []).map((s) => `<a class="bi-li" data-go="https://opsweb.sa/site/${s.id}"><div><b>${esc(s.title)}</b><small>${s.domain ? esc((s.host === '@' ? '' : s.host + '.') + s.domain) : 'no address'}</small></div>${brChip(+s.published ? 'live' : 'draft', +s.published ? '#30d158' : '#8e8e93')}</a>`).join('')
                    || `<div class="bi-none">None — on <a data-go="https://opsweb.sa/panel">opsweb.sa</a> create a site and host it on ${esc(v.ip || '')}, or move an existing one here.</div>`}</div>
                <h3 class="bi-h3">Snapshots <button class="bi-btn sm" data-a="snap">+ Snapshot</button></h3>
                <div class="bi-list">${(v.snapshots || []).map((s) => `<div class="bi-li"><div><b>${esc(s.name)}</b><small>${s.size_gb} GB · ${brDate(s.created_at)}</small></div><button class="bi-btn ghost sm" data-restore="${s.id}">Restore</button><button class="bi-btn ghost sm danger" data-sdel="${s.id}">Delete</button></div>`).join('') || '<div class="bi-none">No snapshots.</div>'}</div>
                <h3 class="bi-h3">Console</h3>
                <pre class="bi-pre" style="max-height:220px;overflow:auto">${esc((v.log || []).join('\n')) || '—'}</pre>
                <div style="padding:14px 0"><button class="bi-btn ghost danger" data-a="delete">Delete server</button></div>`;
            body._v = v;
        };
        await draw();
        body.addEventListener('click', async (e) => {
            const v = body._v; if (!v) return;
            const call = async (x) => { const r = await rpc('webCloud', Object.assign({ id: v.id }, x)); if (!r || !r.ok) { brFail(r); return false; } await draw(); return true; };
            const rs = e.target.closest('[data-restore]'); if (rs) { if (await UI.confirm('Restore this snapshot?', 'The server restarts from it — later changes are lost.', 'Restore', true)) call({ action: 'restore', snap: +rs.dataset.restore }); return; }
            const sd = e.target.closest('[data-sdel]'); if (sd) { call({ action: 'snap_del', snap: +sd.dataset.sdel }); return; }
            const a = e.target.closest('[data-a]'); if (!a) return;
            const act = a.dataset.a;
            if (['start', 'stop', 'reboot', 'pay'].includes(act)) return call({ action: act });
            if (act === 'snap') { const n = await UI.prompt('Snapshot', 'Name it (optional)', { placeholder: 'before-update' }); if (n === null) return; return call({ action: 'snapshot', name: n }); }
            if (act === 'rename') { const n = await UI.prompt('Rename', '', { value: v.name }); if (n) call({ action: 'rename', name: n }); return; }
            if (act === 'fw') { const n = await UI.prompt('Open ports', 'Comma separated, e.g. 22, 80, 443', { value: (v.firewall || []).join(', ') }); if (n === null) return; return call({ action: 'firewall', ports: n.split(/[ ,]+/).filter(Boolean).map(Number) }); }
            if (act === 'resize') { const p = await UI.pick('Resize to', (data.plans || []).map((p) => ({ label: `${p.name} · ${p.vcpu} vCPU · ${p.ram} GB · ${brMoney(p.price)}`, value: p.code }))); if (p) call({ action: 'resize', plan: p }); return; }
            if (act === 'delete') { if (!await UI.confirm('Delete ' + v.name + '?', 'The server, its disk and snapshots are destroyed and its IP is released. Sites hosted on it go offline.', 'Delete', true)) return; const r = await rpc('webCloud', { action: 'delete', id: v.id }); if (!r || !r.ok) return brFail(r); Browser.nav('/console'); }
        });
    },

    /* ----------------------------- OPS company sites */
    company(pg, data) {
        const c = data.company;
        if (!c) { pg.innerHTML = UI.empty('fa-solid fa-building', 'Unavailable', ''); return; }
        pg.innerHTML = `<div class="bi bi-co" style="--bc:${esc(c.color)}">
            <header class="bi-head"><span class="bi-brand"><i class="fa-solid fa-${esc(c.icon)}"></i>${esc(c.name)}</span></header>
            <div class="bi-co-hero"><span class="bi-co-ic"><i class="fa-solid fa-${esc(c.icon)}"></i></span><h1>${esc(c.name)}</h1><p>${esc(c.tagline || '')}</p>
                <div class="bi-co-stats"><div><b>${c.completed}</b><span>jobs completed</span></div><div><b>${c.staff}</b><span>people</span></div><div><b>24/7</b><span>support</span></div></div>
                <button class="bi-btn inv" data-ow>Book us on OPS Work</button></div>
            <div class="bi-body">
                ${(c.outages || []).length ? `<h3 class="bi-h3">Service status</h3><div class="bi-list">${c.outages.map((o) => `<div class="bi-li"><div><b>${esc(o.title)}</b><small>${esc(o.ref)} · ${esc(o.area || '')}</small></div>${brChip(+o.planned ? 'planned' : o.status, +o.planned ? '#ff9f0a' : '#ff3b30')}</div>`).join('')}</div>` : (c.code === 'network' ? '<div class="bi-callout ok"><i class="fa-solid fa-circle-check"></i> All OPS Network services are running normally.</div>' : '')}
                ${c.code === 'data' ? `<h3 class="bi-h3">Data halls</h3>${(c.halls || []).length ? `<div class="bi-list">${c.halls.map((h) => `<div class="bi-li"><div><b>${esc(h.region || 'Hall')} · ${h.racks} rack${h.racks === 1 ? '' : 's'}</b>
                    <small>${h.temp} °C · ${h.load} kW load / ${h.cooling} kW cooling · ${h.servers - h.down}/${h.servers} servers up · ${h.power === 'battery' ? `on UPS battery ${h.charge}%` : h.power === 'ups' ? 'UPS on mains' : 'mains'}</small></div>
                    ${brChip(h.down ? 'degraded' : h.power === 'battery' ? 'on battery' : 'operational', h.down || h.power === 'battery' ? '#ff9f0a' : '#30d158')}</div>`).join('')}</div>` : '<div class="bi-none">No data halls built yet.</div>'}
                    ${Object.keys(c.platform || {}).length ? `<div class="bi-cards">${Object.entries(c.platform).filter(([, r]) => r.total).map(([k, r]) => `<div class="bi-card"><b>${esc({ opsweb: 'OPS Web hosting', dns: 'OPS DNS', mail: 'OPS Web mail' }[k] || k)}</b><span>${r.up}/${r.total} servers up</span><em style="color:${r.up ? '#30d158' : '#ff3b30'}">${r.up ? 'Operational' : 'Down'}</em></div>`).join('')}</div>` : ''}` : ''}
                ${(c.packages || []).length ? `<h3 class="bi-h3">Broadband</h3><div class="bi-cards">${c.packages.map((p) => `<div class="bi-card"><b>${esc(p.name)}</b><span>${p.down_mbps}/${p.up_mbps} Mbps · ${esc(p.segment)}</span><em>${brMoney(p.price)}</em></div>`).join('')}</div><p class="bi-note">Order on your phone: OPS Work → My broadband.</p>` : ''}
                <h3 class="bi-h3">What we do</h3>
                <div class="bi-list">${c.services.map((s) => `<div class="bi-li"><div><b>${esc(s.title)}</b><small>${esc(s.desc || '')}</small></div>${s.price ? `<b>from ${brMoney(s.price)}</b>` : brChip('included', '#30d158')}</div>`).join('')}</div>
                <div class="bi-callout"><b>Work with us.</b> Sign up on OPS Work on your phone and apply to join ${esc(c.name)} — engineers get paid for every job they complete.</div>
            </div>
            <footer class="bi-cofoot">© ${new Date().getFullYear()} ${esc(c.name)} · part of OPS Group</footer></div>`;
        $('[data-ow]', pg).addEventListener('click', () => Phone.openApp && Phone.openApp('opswork'));
    },
    /* ----------------------------- OPS Academy (opsacademy.sa) — the same courses as the app and OPS Hub → Classroom */
    async academy(pg, data) {
        const path = data.path || '/';
        const head = brWebBar('OPS <b>Academy</b>', '#bf5af2', 'graduation-cap', [['/', 'Courses'], ['/systems', 'Systems'], ['/slides', 'Slideshows']], path);
        const out = (html) => { pg.innerHTML = `<div class="bi bi-ac">${head}<div class="bi-body">${html}</div></div>`; return $('.bi-body', pg); };
        const openApp = () => (typeof Laptop !== 'undefined' && Laptop.active ? Laptop.openApp('academy') : Phone.openApp('academy'));
        const appCall = (what) => `<div class="bi-callout"><b>${what}</b> in the <a data-acapp>OPS Academy app</a> (phone or laptop) or on OPS Hub → Classroom — sign in to OPS Work so your result counts.</div>`;
        const wire = () => $$('[data-acapp]', pg).forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openApp(); }));
        const seg = path.split('/').filter(Boolean);
        out(brSpin);

        if (seg[0] === 'lesson' && seg[1]) {
            const r = await rpc('opsLesson', { family: seg[1] });
            const f = r && r.family;
            if (!f) return out('<div class="bi-none">Lesson not found.</div>');
            out(`<h2>${esc(f.name)}</h2><p class="bi-note">${esc(f.summary || '')}</p>
                <h3 class="bi-h3">Overview</h3><div class="bi-box"><p style="padding:10px 0;line-height:1.5">${esc(f.overview)}</p></div>
                <h3 class="bi-h3">The equipment — what it does</h3><div class="bi-list">${(f.equipment || []).map((x) => `<div class="bi-li"><div><b>${esc(x.name)}</b><small>${esc(x.what)}</small><small><i class="fa-solid fa-hand-pointer"></i> ${esc(x.how)}</small></div></div>`).join('')}</div>
                <h3 class="bi-h3">Tools &amp; PPE</h3><div class="bi-cards">${f.tools.concat(f.ppe).map((x) => `<div class="bi-card"><b style="font-size:15px">${esc(x.name)}</b><span>${esc(x.what || '')}</span></div>`).join('')}</div>
                <h3 class="bi-h3">Step by step</h3><div class="bi-list">${(f.steps || []).map((x, i) => `<div class="bi-li"><div><b>${i + 1}. ${esc(x.title)}</b><small>${esc(x.detail)}</small>${x.where ? `<small><i class="fa-solid fa-location-dot"></i> ${esc(x.where)}</small>` : ''}</div></div>`).join('')}</div>
                <h3 class="bi-h3">Health &amp; safety</h3><div class="bi-list">${(f.safety || []).map((x) => `<div class="bi-li"><div><b style="color:#ff9f0a">${esc(x.hazard)}</b><small>${esc(x.risk)}</small><small><i class="fa-solid fa-shield"></i> ${esc(x.control)}</small></div></div>`).join('')}</div>
                <h3 class="bi-h3">What goes wrong</h3><div class="bi-list">${(f.mistakes || []).map((x) => `<div class="bi-li"><div><b style="color:#ff453a">${esc(x.mistake)}</b><small>${esc(x.consequence)}</small></div></div>`).join('')}</div>
                ${appCall('Take the health &amp; safety module and the exam')}`);
            return wire();
        }

        const r = await rpc('opsAcademy');
        if (!r || !r.courses) return out('<div class="bi-none">OPS Academy is unavailable right now.</div>');
        if (r.training === false) return out('<div class="bi-none">Training is switched off on this server.</div>');

        if (seg[0] === 'course' && seg[1]) {
            const c = r.courses.find((x) => x.code === seg[1]);
            if (!c) return out('<div class="bi-none">Course not found.</div>');
            out(`<h2>${esc(c.name)}</h2><p class="bi-note">${esc(c.company || '')} · ${c.families.length} module${c.families.length === 1 ? '' : 's'} · ${c.questions}-question exam (pass ${r.passMark}%)${c.needPractical ? ' · practical at an OPS Academy training centre' : ''}</p>
                ${c.cert && c.cert.valid ? '<div class="bi-callout ok"><i class="fa-solid fa-award"></i> You hold this certificate.</div>' : ''}
                <div class="bi-list">${c.families.map((f) => `<a class="bi-li" data-nav="/lesson/${esc(f.code)}"><div><b>${esc(f.name)}</b><small>${esc(f.summary || '')}</small><small>${f.jobs} job type${f.jobs === 1 ? '' : 's'}${f.required ? ' · certificate required' : ''}${f.lesson && f.lesson.state === 'done' ? ' · lesson read ✓' : ''}${f.safety && f.safety.state === 'done' ? ' · safety passed ✓' : ''}</small></div><i class="fa-solid fa-chevron-right" style="color:var(--label3)"></i></a>`).join('')}</div>
                ${appCall('Take the safety modules and the exam')}`);
            return wire();
        }

        if (seg[0] === 'systems' && seg[1]) {
            const s = await rpc('opsSystem', { code: seg[1] });
            if (!s || !s.system) return out('<div class="bi-none">Not found.</div>');
            out(`<h2>${esc(s.system.name)}</h2>${s.system.sections.map((x) => `<h3 class="bi-h3">${esc(x.title)}</h3><div class="bi-box"><p style="padding:10px 0;line-height:1.5">${esc(x.body)}</p></div>`).join('')}
                ${s.families.length ? `<h3 class="bi-h3">Lessons for the jobs on this system</h3><div class="bi-list">${s.families.map((f) => `<a class="bi-li" data-nav="/lesson/${esc(f.code)}"><div><b>${esc(f.name)}</b></div><i class="fa-solid fa-chevron-right" style="color:var(--label3)"></i></a>`).join('')}</div>` : ''}`);
            return;
        }
        if (seg[0] === 'systems') {
            out(`<h2>How the systems work</h2><p class="bi-note">What feeds what — and what breaks for everyone when something is done wrong.</p>
                <div class="bi-list">${r.systems.map((s) => `<a class="bi-li" data-nav="/systems/${esc(s.code)}"><i class="fa-solid fa-${esc(s.icon || 'book')}" style="color:#0a84ff;width:22px;text-align:center"></i><div><b>${esc(s.name)}</b><small>${esc(s.intro || '')}</small></div></a>`).join('')}</div>`);
            return;
        }

        if (seg[0] === 'slides' && seg[1]) {
            const s = await rpc('opsSlides', { code: seg[1] });
            const show = s && s.show;
            if (!show) return out('<div class="bi-none">Not found.</div>');
            let i = 0;
            const draw = () => {
                const sl = show.slides[i];
                const body = out(`<h2>${esc(show.name)}</h2><div class="bi-box" style="padding:18px;min-height:260px"><div style="display:flex;align-items:center;gap:10px;margin-bottom:12px"><span style="width:40px;height:40px;border-radius:11px;display:grid;place-items:center;background:linear-gradient(140deg,#5e5ce6,#0a84ff);color:#fff"><i class="fa-solid fa-${esc(sl.icon || 'circle-info')}"></i></span><b style="font-size:19px">${esc(sl.title)}</b></div>
                    <ul style="padding-left:18px;display:grid;gap:9px;line-height:1.5">${(Array.isArray(sl.body) ? sl.body : [sl.body]).map((b) => `<li>${esc(b)}</li>`).join('')}</ul></div>
                    <div class="bi-actions" style="justify-content:space-between;align-items:center"><button class="bi-btn ghost" data-p ${i ? '' : 'disabled'}>Back</button><span class="bi-note">${i + 1} / ${show.slides.length}</span><button class="bi-btn" data-n>${i === show.slides.length - 1 ? 'Finish' : 'Next'}</button></div>`);
                $('[data-p]', body).addEventListener('click', () => { if (i) { i -= 1; draw(); } });
                $('[data-n]', body).addEventListener('click', () => { if (i === show.slides.length - 1) Browser.nav('/slides'); else { i += 1; draw(); } });
            };
            return draw();
        }
        if (seg[0] === 'slides') {
            out(`<h2>Slideshow courses</h2><div class="bi-list">${r.slideshows.map((s) => `<a class="bi-li" data-nav="/slides/${esc(s.code)}"><i class="fa-solid fa-${esc(s.icon || 'person-chalkboard')}" style="color:#ff9f0a;width:22px;text-align:center"></i><div><b>${esc(s.name)}</b><small>${esc(s.desc || '')} · ${s.count} slides</small></div></a>`).join('')}</div>`);
            return;
        }

        const card = (c) => `<a class="bi-li" data-nav="/course/${esc(c.code)}"><i class="fa-solid fa-${esc(c.icon || 'graduation-cap')}" style="color:${esc(c.color || '#bf5af2')};width:22px;text-align:center"></i><div><b>${esc(c.name)}</b><small>${esc(c.company || '')} · ${c.families.map((f) => esc(f.name)).join(', ')}</small></div>${c.cert && c.cert.valid ? brChip('certified', '#30d158') : ''}</a>`;
        out(`<div class="bi-hero"><h1>Learn every OPS job</h1><p>Free lessons on every job — the kit, each step, health &amp; safety and what goes wrong — plus how each whole system works.</p></div>
            ${r.signedIn ? `<div class="bi-callout ok">Signed in as <b>${esc(r.name || '')}</b> — your progress is saved.</div>` : appCall('Record your progress, take the safety modules and exams')}
            <h3 class="bi-h3">Courses</h3><div class="bi-list">${r.courses.map(card).join('')}</div>
            <div class="bi-cards"><a class="bi-card" data-nav="/systems"><b style="font-size:15px"><i class="fa-solid fa-diagram-project"></i> Systems</b><span>${r.systems.length} explainers</span></a><a class="bi-card" data-nav="/slides"><b style="font-size:15px"><i class="fa-solid fa-person-chalkboard"></i> Slideshows</b><span>${r.slideshows.length} courses</span></a></div>`);
        wire();
    },
};

/* ---------------------------------------------------------------------
   sheets: DNS records, SSL, new site, mailbox, service order
   --------------------------------------------------------------------- */
function brFormSheet(title, fields, onSave, extra, onExtra) {
    UI.sheet({
        title, right: 'Save',
        render(body, api) {
            body.innerHTML = `<div class="group" style="margin-top:12px">${fields.map((f) => `<div class="row"><span class="muted" style="min-width:96px">${esc(f.label)}</span>
                ${f.options ? `<select class="field" data-k="${f.k}">${f.options.map((o) => `<option value="${esc(o.value ?? o)}" ${(o.value ?? o) == f.value ? 'selected' : ''}>${esc(o.label ?? o)}</option>`).join('')}</select>`
                : f.bool ? UI.switchHtml(!!f.value, `data-k="${f.k}"`)
                    : `<input class="field" data-k="${f.k}" value="${esc(f.value ?? '')}" placeholder="${esc(f.ph || '')}" ${f.type ? `type="${f.type}"` : ''}>`}</div>`).join('')}</div>
                ${extra || ''}`;
            if (onExtra) onExtra(body, api);
        },
        async onRight(api) {
            const v = {};
            $$('[data-k]', api.body).forEach((el) => { v[el.dataset.k] = el.type === 'checkbox' ? el.checked : el.value.trim(); });
            if (await onSave(v, api) !== false) api.close();
        },
    });
}

function brDnsSheet(d, rec, done) {
    brFormSheet(rec ? 'Edit record' : 'Add record', [
        { k: 'type', label: 'Type', options: ['A', 'CNAME', 'MX', 'TXT', 'AAAA'], value: rec ? rec.type : 'A' },
        { k: 'host', label: 'Name', value: rec ? rec.host : '@', ph: '@ or www' },
        { k: 'value', label: 'Points to', value: rec ? rec.value : '', ph: 'IP address / hostname / text' },
        { k: 'prio', label: 'Priority (MX)', value: rec ? rec.prio : 10, type: 'number' },
        { k: 'ttl', label: 'TTL (seconds)', value: rec ? rec.ttl : 3600, type: 'number' },
    ], async (v) => {
        const r = await rpc('webDomains', { action: rec ? 'dns_edit' : 'dns_add', id: d.id, rid: rec && rec.id, record: v });
        if (!r || !r.ok) { brFail(r); return false; }
        done();
    }, rec ? '<div style="padding:0 16px 20px"><button class="btn block secondary" style="color:#ff3b30" data-del-rec>Delete record</button></div>' : '', (body, api) => {
        const b = $('[data-del-rec]', body);
        if (b) b.addEventListener('click', async () => { await rpc('webDomains', { action: 'dns_del', id: d.id, rid: rec.id }); api.close(); done(); UI.toast('Deleted'); });
    });
}

async function brSslSheet(d, done) {
    const kinds = [{ label: 'Domain validated (DV) · free with OPS Web hosting, else $15', value: 'dv' }, { label: 'Organisation validated (OV) · $60', value: 'ov' },
        { label: 'Extended validation (EV) · $150', value: 'ev' }, { label: 'Wildcard *.' + d.name + ' · $70', value: 'wild' }];
    const kind = await UI.pick('Certificate for ' + d.name, kinds);
    if (!kind) return;
    let host = '@';
    if (kind !== 'wild') {
        const h = await UI.prompt('Which name?', `@ for ${d.name}, or a subdomain like shop`, { value: '@' });
        if (h === null) return;
        host = h.trim() || '@';
    }
    const r = await rpc('webHost', { action: 'ssl', domain: d.id, kind, host });
    if (!r || !r.ok) return brFail(r);
    UI.alert({ title: 'Certificate issued', message: `${r.name} is now secure${r.free ? ' (free with your hosting, renews automatically)' : ` — ${brMoney(r.price)}`}.` });
    done();
}

async function brNewSite(r) {
    const opts = r.hosting.filter((h) => h.status === 'active').map((h) => ({ label: `OPS Web ${h.name || h.plan} (${h.sites}/${h.maxSites} used)`, value: 'h' + h.id }))
        .concat(r.ips.map((ip) => ({ label: `Self-host on ${ip.ip} (${ip.ref})`, value: 'ip' + ip.ip })));
    if (!opts.length) return UI.alert({ title: 'Nowhere to host it', message: 'Buy an OPS Web plan, or get a business broadband line with a static IP from OPS Network to host it yourself.' });
    const where = await UI.pick('Where will it live?', opts);
    if (!where) return;
    const title = await UI.prompt('Site name', 'Shown at the top of every page', { placeholder: 'Bean Machine Coffee' });
    if (!title) return;
    const x = await rpc('webHost', where.startsWith('h') ? { action: 'site_new', title, hosting: +where.slice(1) } : { action: 'site_new', title, self_ip: where.slice(2) });
    if (!x || !x.ok) return brFail(x);
    Browser.nav('/site/' + x.id);
}

function brCloudNew(r) {
    const regions = Object.keys(r.capacity || {});
    brFormSheet('Create server', [
        { k: 'name', label: 'Name', ph: 'web-1' },
        { k: 'plan', label: 'Size', options: (r.plans || []).map((p) => ({ label: `${p.name} · ${p.vcpu} vCPU · ${p.ram} GB · ${brMoney(p.price)}`, value: p.code })), value: 'small' },
        { k: 'image', label: 'Image', options: (r.images || []).map((i) => ({ label: i.name + (i.extra ? ` (+${brMoney(i.extra)})` : ''), value: i.code })), value: 'opsweb' },
        { k: 'region', label: 'Region', options: regions.length ? regions : ['LS-1'] },
    ], async (v) => {
        const x = await rpc('webCloud', Object.assign({ action: 'create' }, v));
        if (!x || !x.ok) { brFail(x); return false; }
        UI.toast(x.waiting ? 'Queued — waiting for capacity' : 'Deploying ' + x.ip, 'fa-solid fa-cloud');
        Browser.nav('/vm/' + x.id);
    }, '<div class="group-footer">The first period is paid now from your bank. It boots on an OPS Data host in the region you pick.</div>');
}

function brMailboxSheet(r) {
    if (!r.domains.length) return UI.alert({ title: 'You need a domain', message: 'Register one on opsdomains.sa first.' });
    brFormSheet('New mailbox', [
        { k: 'local', label: 'Address', ph: 'info' },
        { k: 'domain', label: 'Domain', options: r.domains.filter((d) => d.status === 'active').map((d) => ({ label: '@' + d.name, value: d.id })) },
        { k: 'deliver', label: 'Deliver to phone', value: r.number },
        { k: 'catch_all', label: 'Catch-all', bool: true },
    ], async (v) => {
        const x = await rpc('webHost', { action: 'mailbox_add', domain: +v.domain, local: v.local, deliver: v.deliver, catch_all: v.catch_all });
        if (!x || !x.ok) { brFail(x); return false; }
        UI.toast(x.address + ' created', 'fa-solid fa-envelope');
        Browser.load(Browser.stack[Browser.idx]);
    });
}

function brOrderSheet(r, code) {
    if (!r.domains.length) return UI.alert({ title: 'You need a domain', message: 'Register one on opsdomains.sa first.' });
    const svc = r.services.find((s) => s.code === code) || {};
    brFormSheet({ web_build: 'Build my site', web_ssl: 'Set up SSL', web_mail: 'Set up email' }[code] || 'Order', [
        { k: 'domain', label: 'For', options: r.domains.map((d) => ({ label: d.name, value: d.id })) },
        { k: 'note', label: 'Brief', ph: code === 'web_build' ? 'What should the site say?' : 'Anything we should know?' },
    ], async (v) => {
        const x = await rpc('webHost', { action: 'order', code, domain: +v.domain, note: v.note });
        if (!x || !x.ok) { brFail(x); return false; }
        UI.alert({ title: 'Booked', message: `Job ${x.ref}: an OPS Web specialist will pick it up. You pay ${brMoney(svc.price)} when it’s done.` });
    }, `<div class="group-footer">${esc(svc.desc || '')} · ${brMoney(svc.price)}, paid when the work is done. ${code === 'web_build' ? 'Create the (empty) site in your panel first so they can build it.' : ''}</div>`);
}

/* ---------------------------------------------------------------------
   the site builder (opsweb.sa/site/ID, /site/ID/page/N)
   --------------------------------------------------------------------- */
const BrEdit = { id: null, site: null, dirty: false };

async function brEditor(out, id, pageIdx) {
    if (BrEdit.id !== id || !BrEdit.site) {
        const body = out(brSpin);
        const r = await rpc('webHost', { action: 'site_get', id });
        if (!r || !r.site) { body.innerHTML = `<div class="bi-none">${esc((r && r.error) || 'Site not found')}</div>`; return; }
        BrEdit.id = id; BrEdit.site = r.site; BrEdit.dirty = false;
    }
    const s = BrEdit.site;
    const save = async () => {
        const r = await rpc('webHost', { action: 'site_save', id, title: s.title, description: s.description, keywords: s.keywords, noindex: s.noindex, data: s.data });
        if (!r || !r.ok) { brFail(r); return false; }
        BrEdit.dirty = false;
        UI.toast('Saved');
        return true;
    };
    const bar = `<div class="be-bar"><a data-nav="${pageIdx === null ? '/panel' : '/site/' + id}"><i class="fa-solid fa-chevron-left"></i> ${pageIdx === null ? 'Panel' : 'Site'}</a><span class="grow"></span>
        ${s.url ? `<button class="bi-btn ghost sm" data-e="view">View</button>` : ''}<button class="bi-btn sm" data-e="save">Save${BrEdit.dirty ? ' •' : ''}</button></div>`;

    if (pageIdx === null) {
        const d = s.data;
        const body = out(`${bar}
            <div class="bi-domhead"><div><h2>${esc(s.title)}</h2><small>${s.host ? esc(s.host) : 'No address'}${s.selfIp ? ' · self-hosted on ' + esc(s.selfIp) : ' · OPS Web'} · ${s.views || 0} views</small></div>
                ${s.status === 'taken_down' ? brChip('taken down', '#ff3b30') : `<label class="be-pub">${s.published ? 'Live' : 'Draft'} ${UI.switchHtml(s.published, 'data-e-pub')}</label>`}</div>
            ${s.status === 'taken_down' ? `<div class="bi-callout bad">Taken down by OPS Web: ${esc(s.reason || '')}</div>` : ''}
            ${s.dnsHint ? `<div class="bi-callout"><i class="fa-solid fa-triangle-exclamation"></i> ${esc(s.dnsHint)}. Connect the domain below (we fix the DNS).</div>` : ''}
            <h3 class="bi-h3">Address</h3>
            <div class="bi-form row2"><select data-f="domain"><option value="">— no domain —</option>${(s.domains || []).map((x) => `<option value="${x.id}" ${x.id === s.domainId ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select>
                <input data-f="sub" value="${esc(s.sub && s.sub !== '@' ? s.sub : '')}" placeholder="subdomain (optional)"><button class="bi-btn" data-e="connect">Connect</button></div>
            <div class="bi-box">${s.cert ? `<div class="bi-set"><div><b><i class="fa-solid fa-lock" style="color:#30d158"></i> HTTPS on</b><small>${esc(s.cert.kind.toUpperCase())} · until ${brDate(s.cert.expires)}</small></div></div>`
                : `<div class="bi-set"><div><b>No SSL certificate</b><small>Visitors see “Not secure”</small></div>${s.domainId ? `<button class="bi-btn ghost sm" data-e="ssl">Get SSL</button>` : ''}</div>`}</div>
            <div class="bi-actions"><button class="bi-btn ghost sm" data-e="move">Move to another server…</button></div>
            <h3 class="bi-h3">Pages <button class="bi-btn sm" data-e="addpage">+ Page</button></h3>
            <div class="bi-list">${d.pages.map((p, i) => `<a class="bi-li" data-nav="/site/${id}/page/${i}"><div><b>${esc(p.title)}</b><small>/${esc(p.slug)} · ${p.blocks.length} block${p.blocks.length === 1 ? '' : 's'}</small></div><i class="fa-solid fa-chevron-right muted"></i></a>`).join('')}</div>
            <h3 class="bi-h3">Look</h3>
            <div class="be-colors">${BR_COLORS.map((c) => `<button data-color="${c}" style="background:${c}" class="${d.theme.color === c ? 'on' : ''}"></button>`).join('')}</div>
            <div class="bi-form row2"><select data-f="mode"><option value="light">Light</option><option value="dark" ${d.theme.mode === 'dark' ? 'selected' : ''}>Dark</option></select>
                <select data-f="font">${Object.keys(BR_FONTS).map((f) => `<option ${d.theme.font === f ? 'selected' : ''}>${f}</option>`).join('')}</select></div>
            <h3 class="bi-h3">Contact details</h3>
            <div class="bi-form"><input data-f="email" value="${esc(d.contact.email || '')}" placeholder="Email (form messages go here)"><input data-f="phone" value="${esc(d.contact.phone || '')}" placeholder="Phone"><input data-f="address" value="${esc(d.contact.address || '')}" placeholder="Address"></div>
            <h3 class="bi-h3">Search (OPS Search)</h3>
            <div class="bi-form"><input data-f="title" value="${esc(s.title)}" placeholder="Site name"><input data-f="description" value="${esc(s.description || '')}" placeholder="Description shown in search results"><input data-f="keywords" value="${esc(s.keywords || '')}" placeholder="Keywords: coffee, cafe, vinewood">
                <label class="be-check"><input type="checkbox" data-f="noindex" ${s.noindex ? 'checked' : ''}> Hide from search results</label></div>
            ${s.status !== 'taken_down' ? '<div style="padding:18px 0"><button class="bi-btn ghost danger" data-e="delete">Delete site</button></div>' : ''}`);
        body.addEventListener('input', (e) => {
            const f = e.target.dataset.f;
            if (!f) return;
            const v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
            if (['email', 'phone', 'address'].includes(f)) d.contact[f] = v;
            else if (f === 'mode' || f === 'font') d.theme[f] = v;
            else if (['title', 'description', 'keywords', 'noindex'].includes(f)) s[f] = v;
            else return;
            BrEdit.dirty = true;
        });
        body.addEventListener('change', async (e) => {
            if (e.target.matches('[data-e-pub]')) {
                if (BrEdit.dirty && !(await save())) return;
                const r = await rpc('webHost', { action: 'site_publish', id, on: e.target.checked });
                if (!r || !r.ok) return brFail(r);
                s.published = e.target.checked;
                UI.toast(s.published ? 'Your site is live' : 'Unpublished');
                BrEdit.site = null; Browser.load(Browser.stack[Browser.idx]);
            }
        });
        body.addEventListener('click', async (e) => {
            const col = e.target.closest('[data-color]');
            if (col) { d.theme.color = col.dataset.color; BrEdit.dirty = true; $$('[data-color]', body).forEach((b) => b.classList.toggle('on', b === col)); return; }
            const a = e.target.closest('[data-e]');
            if (!a) return;
            const act = a.dataset.e;
            if (act === 'save') { if (await save()) { BrEdit.site = null; Browser.load(Browser.stack[Browser.idx]); } }
            if (act === 'view') { if (BrEdit.dirty) await save(); Browser.go(s.url); }
            if (act === 'connect') {
                const dom = $('[data-f=domain]', body).value;
                const r = await rpc('webHost', { action: 'site_domain', id, domain: dom ? +dom : null, host: $('[data-f=sub]', body).value.trim() || '@' });
                if (!r || !r.ok) return brFail(r);
                UI.toast(r.url ? 'Connected — DNS updated' : 'Disconnected');
                BrEdit.site = null; Browser.load(Browser.stack[Browser.idx]);
            }
            if (act === 'ssl') { brSslSheet({ id: s.domainId, name: s.host.replace(/^[^.]+\.(?=[^.]+\.[^.]+$)/, '') }, () => { BrEdit.site = null; Browser.load(Browser.stack[Browser.idx]); }); }
            if (act === 'move') {
                const mine = await rpc('webHost', { action: 'mine' });
                if (!mine) return;
                const opts = [{ label: 'OPS Web shared hosting', value: 'h' }].concat((mine.ips || []).filter((ip) => ip.ip !== s.selfIp).map((ip) => ({ label: `${ip.pool === 'cloud' ? 'Cloud server' : 'Own line'} · ${ip.ip} (${ip.ref})`, value: ip.ip })));
                const to = await UI.pick('Move this site to…', opts);
                if (!to) return;
                if (!await UI.confirm('Move the site?', 'The DNS for its address is updated to the new server straight away.', 'Move')) return;
                const r = await rpc('webHost', to === 'h' ? { action: 'site_move', id } : { action: 'site_move', id, self_ip: to });
                if (!r || !r.ok) return brFail(r);
                UI.toast('Moved'); BrEdit.site = null; Browser.load(Browser.stack[Browser.idx]);
            }
            if (act === 'addpage') {
                if (d.pages.length >= 8) return UI.toast('Up to 8 pages');
                const t = await UI.prompt('New page', 'Page title', { placeholder: 'Menu' });
                if (!t) return;
                const slug = t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 24) || 'page' + (d.pages.length + 1);
                d.pages.push({ slug, title: t.slice(0, 40), blocks: [{ t: 'text', heading: t, body: '' }] });
                BrEdit.dirty = true;
                Browser.nav(`/site/${id}/page/${d.pages.length - 1}`);
            }
            if (act === 'delete') {
                if (!await UI.confirm('Delete this site?', 'It goes offline straight away. This can’t be undone.', 'Delete', true)) return;
                const r = await rpc('webHost', { action: 'site_delete', id });
                if (!r || !r.ok) return brFail(r);
                BrEdit.site = null; Browser.nav('/panel');
            }
        });
        return;
    }

    // one page: its blocks
    const p = s.data.pages[pageIdx];
    if (!p) { out(`${bar}<div class="bi-none">No such page.</div>`); return; }
    const sum = (b) => esc(b.title || b.heading || b.text || b.body || b.caption || (b.items && b.items.length ? `${b.items.length} item${b.items.length === 1 ? '' : 's'}` : '') || '').slice(0, 60);
    const body = out(`${bar}
        <div class="bi-form row2"><input data-pf="title" value="${esc(p.title)}" placeholder="Page title">${pageIdx ? `<input data-pf="slug" value="${esc(p.slug)}" placeholder="address: /menu">` : '<input disabled value="Home page ( / )">'}</div>
        <div class="be-blocks">${p.blocks.map((b, i) => `<div class="be-block" data-bi="${i}"><span class="be-ic"><i class="fa-solid fa-${(BR_BLOCKS[b.t] || ['square'])[0]}"></i></span>
            <div class="grow"><b>${esc((BR_BLOCKS[b.t] || [0, b.t])[1])}</b><small>${sum(b)}</small></div>
            <button data-mv="-1" ${i === 0 ? 'disabled' : ''}><i class="fa-solid fa-arrow-up"></i></button><button data-mv="1" ${i === p.blocks.length - 1 ? 'disabled' : ''}><i class="fa-solid fa-arrow-down"></i></button></div>`).join('') || '<div class="bi-none">No blocks yet.</div>'}</div>
        <button class="bi-btn block" data-e="addblock">+ Add a block</button>
        <div class="be-preview"><div class="be-pv-label">Preview</div>${brSiteHtml({ site: { title: s.title, theme: s.data.theme, contact: s.data.contact, nav: s.data.pages.map((x) => ({ slug: x.slug, title: x.title })) }, page: p, hosted: 'Preview' })}</div>
        ${pageIdx ? '<div style="padding:16px 0"><button class="bi-btn ghost danger" data-e="delpage">Delete this page</button></div>' : ''}`);
    const redraw = () => brEditor(out, id, pageIdx);
    body.addEventListener('input', (e) => {
        const f = e.target.dataset.pf;
        if (f === 'title') p.title = e.target.value.slice(0, 40);
        if (f === 'slug') p.slug = e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '').slice(0, 24);
        if (f) BrEdit.dirty = true;
    });
    body.addEventListener('click', async (e) => {
        if (e.target.closest('.be-preview')) { e.stopPropagation(); return; }
        const mv = e.target.closest('[data-mv]');
        const blk = e.target.closest('[data-bi]');
        if (mv && blk) {
            const i = +blk.dataset.bi, j = i + +mv.dataset.mv;
            [p.blocks[i], p.blocks[j]] = [p.blocks[j], p.blocks[i]];
            BrEdit.dirty = true; return redraw();
        }
        if (blk) return brBlockSheet(p, +blk.dataset.bi, redraw);
        const a = e.target.closest('[data-e]');
        if (!a) return;
        if (a.dataset.e === 'save') { if (await save()) redraw(); }
        if (a.dataset.e === 'view') { if (BrEdit.dirty) await save(); Browser.go(s.url + (p.slug ? '/' + p.slug : '')); }
        if (a.dataset.e === 'addblock') {
            if (p.blocks.length >= 25) return UI.toast('Up to 25 blocks a page');
            const t = await UI.pick('Add a block', Object.entries(BR_BLOCKS).map(([k, v]) => ({ label: v[1], value: k })));
            if (!t) return;
            p.blocks.push(JSON.parse(JSON.stringify(Object.assign({ t }, BR_BLOCKS[t][2]))));
            BrEdit.dirty = true;
            redraw();
            if (t !== 'divider') brBlockSheet(p, p.blocks.length - 1, redraw);
        }
        if (a.dataset.e === 'delpage') {
            if (!await UI.confirm('Delete this page?', '', 'Delete', true)) return;
            s.data.pages.splice(pageIdx, 1);
            BrEdit.dirty = true;
            Browser.nav('/site/' + id);
        }
    });
}

function brBlockSheet(p, i, done) {
    const b = p.blocks[i];
    const fields = BR_FIELDS[b.t] || [];
    const items = BR_ITEMS[b.t];
    UI.sheet({
        title: (BR_BLOCKS[b.t] || [0, 'Block'])[1], right: 'Done',
        render(body, api) {
            const draw = () => {
                body.innerHTML = `<div class="be-sheet">${fields.map(([k, label, kind]) => `<label>${esc(label)}${
                    kind === 'area' ? `<textarea data-k="${k}" rows="4">${esc(b[k] || '')}</textarea>`
                        : kind === 'bool' ? UI.switchHtml(!!b[k], `data-k="${k}"`)
                            : Array.isArray(kind) ? `<select data-k="${k}">${kind.map((o) => `<option ${b[k] === o ? 'selected' : ''}>${o}</option>`).join('')}</select>`
                                : `<input data-k="${k}" value="${esc(b[k] || '')}">`}</label>`).join('')}
                    ${items ? `<div class="be-items">${(b.items || []).map((it, n) => `<div class="be-item"><div class="be-item-h">#${n + 1}<button data-rm="${n}"><i class="fa-solid fa-trash"></i></button></div>
                        ${items.f.map(([k, label]) => `<input data-ik="${n}.${k}" value="${esc(it[k] || '')}" placeholder="${esc(label)}">`).join('')}</div>`).join('')}
                        ${(b.items || []).length < items.max ? '<button class="bi-btn ghost block" data-additem>+ Add item</button>' : ''}</div>` : ''}
                    <button class="bi-btn ghost danger block" data-delblock style="margin-top:18px">Remove this block</button></div>`;
            };
            draw();
            body.addEventListener('input', (e) => {
                const k = e.target.dataset.k, ik = e.target.dataset.ik;
                if (k) b[k] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
                if (ik) { const [n, f] = ik.split('.'); b.items[+n][f] = e.target.value; }
                BrEdit.dirty = true;
            });
            body.addEventListener('change', (e) => { if (e.target.dataset.k && e.target.type === 'checkbox') { b[e.target.dataset.k] = e.target.checked; BrEdit.dirty = true; } });
            body.addEventListener('click', (e) => {
                if (e.target.closest('[data-additem]')) { b.items = b.items || []; b.items.push(Object.assign({}, items.add)); BrEdit.dirty = true; draw(); }
                const rm = e.target.closest('[data-rm]');
                if (rm) { b.items.splice(+rm.dataset.rm, 1); BrEdit.dirty = true; draw(); }
                if (e.target.closest('[data-delblock]')) { p.blocks.splice(i, 1); BrEdit.dirty = true; api.close(); done(); }
            });
        },
        onRight(api) { api.close(); done(); },
    });
}

Apps.register({
    id: 'browser', name: 'Browser', resumable: true,
    splash: 'linear-gradient(160deg,#0a84ff,#5e5ce6)',
    icon: { bg: 'linear-gradient(150deg,#5ac8fa,#0a84ff 55%,#5e5ce6)', html: () => '<i class="fa-solid fa-compass" style="font-size:30px;color:#fff"></i>' },
    open(root, params) { return Browser.open(root, params); },
    onClose() { Browser.loading++; },
});
