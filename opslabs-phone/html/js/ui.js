'use strict';

/* =====================================================================
   Navigation stack (navigation controller)
   ===================================================================== */

class Nav {
    constructor(host) {
        this.host = host;
        this.stack = [];
        host.classList.add('nav-root');
        this._edgeSwipe();
    }

    get top() { return this.stack[this.stack.length - 1]; }

    /**
     * opts: {
     *   title, large, grouped, tabbar, noNav, solidBar, backLabel, noBack,
     *   left, right (html strings),
     *   render(content, ctx), onResume(ctx), onLeave(ctx)
     * }
     */
    push(opts, animate = true) {
        const prev = this.top;
        const cls = [
            'page',
            opts.grouped && 'grouped',
            opts.large && 'has-large',
            opts.tabbar && 'has-tabbar',
            opts.noNav && 'no-nav',
            opts.className,
        ].filter(Boolean).join(' ');

        const page = el(`
            <div class="${cls}">
                ${opts.noNav ? '' : `<div class="navbar ${opts.solidBar ? 'solid' : ''}">
                    <div class="nav-left"></div>
                    <div class="nav-title">${esc(opts.title || '')}</div>
                    <div class="nav-right"></div>
                </div>`}
                <div class="page-body scroll">
                    ${opts.large ? `<h1 class="large-title">${esc(opts.title || '')}</h1>` : ''}
                    <div class="page-content"></div>
                </div>
            </div>`);

        const body = $('.page-body', page);
        const content = $('.page-content', page);
        const ctx = {
            nav: this,
            page,
            body,
            content,
            pop: () => this.pop(),
            setTitle: (t) => {
                const nt = $('.nav-title', page); if (nt) nt.textContent = t;
                const lt = $('.large-title', page); if (lt) lt.textContent = t;
            },
            setRight: (html) => { const r = $('.nav-right', page); if (r) r.innerHTML = html; return r; },
            setLeft: (html) => { const l = $('.nav-left', page); if (l) l.innerHTML = html; return l; },
            opts,
        };

        if (!opts.noNav) {
            const left = $('.nav-left', page);
            if (prev && !opts.noBack) {
                const label = opts.backLabel ?? prev.opts.backTitle ?? prev.opts.title ?? 'Back';
                left.innerHTML = `<button class="nav-btn nav-back"><i class="fa-solid fa-chevron-left"></i>${esc(label.length > 12 ? 'Back' : label)}</button>`;
                $('.nav-back', left).onclick = () => this.pop();
            }
            if (opts.left) left.insertAdjacentHTML('beforeend', opts.left);
            if (opts.right) $('.nav-right', page).innerHTML = opts.right;
            const threshold = opts.large ? 36 : 2;
            body.addEventListener('scroll', () => page.classList.toggle('scrolled', body.scrollTop > threshold), { passive: true });
        }

        page._ctx = ctx;
        this.stack.push({ page, opts, ctx });

        if (prev && animate) {
            page.classList.add('from-right', 'shadow');
            this.host.appendChild(page);
            page.getBoundingClientRect();
            requestAnimationFrame(() => {
                page.classList.remove('from-right');
                prev.page.classList.add('behind');
                setTimeout(() => page.classList.remove('shadow'), 500);
            });
        } else {
            if (prev) prev.page.classList.add('behind');
            this.host.appendChild(page);
        }

        opts.render && opts.render(content, ctx);
        return ctx;
    }

    pop(animate = true) {
        if (this.stack.length <= 1) return false;
        const top = this.stack.pop();
        const prev = this.top;
        top.opts.onLeave && top.opts.onLeave(top.ctx);
        if (animate) {
            top.page.classList.add('leaving');
            prev.page.classList.remove('behind');
            setTimeout(() => top.page.remove(), 480);
        } else {
            top.page.remove();
            prev.page.classList.remove('behind');
        }
        prev.opts.onResume && prev.opts.onResume(prev.ctx);
        return true;
    }

    popToRoot() {
        while (this.stack.length > 1) this.pop(false);
    }

    /** interactive swipe-from-left-edge to go back */
    _edgeSwipe() {
        let startOk = false;
        drag(this.host, {
            onStart: (e) => {
                const r = this.host.getBoundingClientRect();
                startOk = this.stack.length > 1 && (e.clientX - r.left) / (Phone.scale || 1) < 22;
                return startOk;
            },
            onMove: (dx) => {
                const top = this.top, prev = this.stack[this.stack.length - 2];
                const x = Math.max(0, dx);
                top.page.style.transition = prev.page.style.transition = 'none';
                top.page.style.transform = `translateX(${x}px)`;
                prev.page.style.transform = `translateX(${-28 + (x / 393) * 28}%)`;
            },
            onEnd: (dx, _dy, _vy, vx) => {
                const top = this.top, prev = this.stack[this.stack.length - 2];
                if (!top || !prev) return;
                top.page.style.transition = prev.page.style.transition = '';
                top.page.style.transform = prev.page.style.transform = '';
                if (dx > 120 || vx > 0.5) this.pop();
            },
        });
    }
}

/* =====================================================================
   Tab bar controller
   ===================================================================== */

/**
 * tabs: [{ id, label, icon, render(host) }]
 * Each tab is rendered lazily into its own host and kept alive.
 */
function TabBar(root, tabs, initial) {
    root.innerHTML = '';
    const hosts = {};
    const bar = el(`<div class="tabbar">${tabs.map((t) => `
        <button data-tab="${t.id}"><i class="${t.icon}"></i><span>${esc(t.label)}</span></button>`).join('')}</div>`);
    root.appendChild(bar);

    const api = {
        current: null,
        select(id) {
            const tab = tabs.find((t) => t.id === id) || tabs[0];
            api.current = tab.id;
            $$('button', bar).forEach((b) => b.classList.toggle('on', b.dataset.tab === tab.id));
            Object.entries(hosts).forEach(([k, h]) => h.classList.toggle('hidden', k !== tab.id));
            if (!hosts[tab.id]) {
                const h = el('<div class="tab-host"></div>');
                root.insertBefore(h, bar);
                hosts[tab.id] = h;
                tab.render(h, api);
            } else if (tab.onShow) {
                tab.onShow(hosts[tab.id], api);
            }
            return hosts[tab.id];
        },
        badge(id, n) {
            const b = $(`button[data-tab="${id}"]`, bar);
            if (!b) return;
            let badge = $('.tb-badge', b);
            if (!n) { badge && badge.remove(); return; }
            if (!badge) { badge = el('<span class="tb-badge"></span>'); b.appendChild(badge); }
            badge.textContent = n;
        },
        host: (id) => hosts[id],
    };

    bar.addEventListener('click', (e) => {
        const b = e.target.closest('button[data-tab]');
        if (!b) return;
        if (api.current === b.dataset.tab) {
            const h = hosts[b.dataset.tab];
            // re-tap: pop to root like a real phone
            if (h && h._nav) h._nav.popToRoot();
            return;
        }
        api.select(b.dataset.tab);
    });

    api.select(initial || tabs[0].id);
    return api;
}

/* =====================================================================
   Modals
   ===================================================================== */

const UI = {
    layer: () => $('#overlay-layer'),

    _backdrop(light) {
        const b = el(`<div class="backdrop ${light ? 'light' : ''}"></div>`);
        UI.layer().appendChild(b);
        requestAnimationFrame(() => b.classList.add('show'));
        return b;
    },

    _dismiss(nodes, delay = 450) {
        nodes.forEach((n) => n && n.classList.remove('show'));
        setTimeout(() => nodes.forEach((n) => n && n.remove()), delay);
    },

    /** OPS OS alert. buttons: [{ label, value, style: 'cancel'|'destructive'|'default' }] */
    alert({ title, message = '', buttons = [{ label: 'OK', value: true, style: 'bold' }], input = null }) {
        return new Promise((resolve) => {
            const back = UI._backdrop(true);
            const stack = buttons.length > 2;
            const a = el(`
                <div class="alert">
                    <div class="a-body">
                        <div class="a-title">${esc(title)}</div>
                        ${message ? `<div class="a-msg">${esc(message)}</div>` : ''}
                        ${input ? `<input class="a-input" type="${input.type || 'text'}" placeholder="${esc(input.placeholder || '')}" value="${esc(input.value || '')}">` : ''}
                    </div>
                    <div class="a-buttons ${stack ? 'stack' : ''}">
                        ${buttons.map((b, i) => `<button data-i="${i}" class="${b.style === 'cancel' ? '' : (b.style || '')} ${b.style === 'bold' || (!stack && i === buttons.length - 1 && b.style !== 'destructive' && buttons.length > 1) ? 'bold' : ''}">${esc(b.label)}</button>`).join('')}
                    </div>
                </div>`);
            UI.layer().appendChild(a);
            requestAnimationFrame(() => a.classList.add('show'));
            const inp = $('.a-input', a);
            if (inp) setTimeout(() => inp.focus(), 50);
            const done = (i) => {
                const b = buttons[i];
                UI._dismiss([a, back], 300);
                if (!b) return resolve(null);
                resolve(input ? (b.style === 'cancel' ? null : inp.value) : b.value);
            };
            a.addEventListener('click', (e) => {
                const btn = e.target.closest('button[data-i]');
                if (btn) done(+btn.dataset.i);
            });
            if (inp) inp.addEventListener('keydown', (e) => { if (e.key === 'Enter') done(buttons.length - 1); });
        });
    },

    confirm(title, message, okLabel = 'OK', destructive = false) {
        return UI.alert({
            title, message,
            buttons: [{ label: 'Cancel', value: false, style: 'cancel' }, { label: okLabel, value: true, style: destructive ? 'destructive' : 'bold' }],
        });
    },

    prompt(title, message, { placeholder = '', value = '', ok = 'OK', type = 'text' } = {}) {
        return UI.alert({
            title, message,
            input: { placeholder, value, type },
            buttons: [{ label: 'Cancel', style: 'cancel' }, { label: ok, style: 'bold' }],
        });
    },

    /** options: [{ label, destructive }]; resolves with index or null */
    actionSheet(title, options) {
        return new Promise((resolve) => {
            const back = UI._backdrop();
            const s = el(`
                <div class="action-sheet">
                    <div class="as-group">
                        ${title ? `<div class="as-title">${esc(title)}</div>` : ''}
                        ${options.map((o, i) => `<button data-i="${i}" class="${o.destructive ? 'destructive' : ''}">${esc(o.label)}</button>`).join('')}
                    </div>
                    <button class="as-cancel" data-i="-1">Cancel</button>
                </div>`);
            UI.layer().appendChild(s);
            requestAnimationFrame(() => s.classList.add('show'));
            const done = (i) => { UI._dismiss([s, back]); resolve(i < 0 ? null : i); };
            s.addEventListener('click', (e) => { const b = e.target.closest('button[data-i]'); if (b) done(+b.dataset.i); });
            back.addEventListener('click', () => done(-1));
        });
    },

    /** action sheet that resolves with the chosen option's value (or its index when it has none), null if cancelled */
    async pick(title, options) {
        const i = await UI.actionSheet(title, options);
        return i === null ? null : (options[i].value ?? i);
    },

    /**
     * Card sheet. opts: { title, left = 'Cancel', right, rightBold, medium, render(body, api), onRight(api) }
     * api: { close(), body, el, setRightEnabled(bool) }
     */
    sheet(opts) {
        const back = UI._backdrop();
        const win = $('.app-window:last-child', $('#app-layer'));
        if (win && !opts.medium) win.classList.add('sheet-behind');
        const s = el(`
            <div class="sheet ${opts.medium ? 'medium' : ''}">
                <div class="grabber"></div>
                <div class="sheet-bar">
                    <button class="nav-btn" data-act="left">${esc(opts.left ?? 'Cancel')}</button>
                    <div class="sheet-title">${esc(opts.title || '')}</div>
                    ${opts.right ? `<button class="nav-btn bold" data-act="right">${esc(opts.right)}</button>` : '<span></span>'}
                </div>
                <div class="sheet-body scroll"></div>
            </div>`);
        UI.layer().appendChild(s);
        requestAnimationFrame(() => s.classList.add('show'));
        const api = {
            el: s,
            body: $('.sheet-body', s),
            close() {
                if (win) win.classList.remove('sheet-behind');
                UI._dismiss([s, back]);
                opts.onClose && opts.onClose();
            },
            setRightEnabled(on) { const b = $('[data-act=right]', s); if (b) b.disabled = !on; },
        };
        $('[data-act=left]', s).onclick = () => (opts.onLeft ? opts.onLeft(api) : api.close());
        const r = $('[data-act=right]', s);
        if (r) r.onclick = () => opts.onRight && opts.onRight(api);
        back.onclick = () => api.close();
        drag($('.sheet-bar', s), {
            onStart: (e) => !e.target.closest('button'),
            onMove: (_dx, dy) => { if (dy > 0) { s.style.transition = 'none'; s.style.transform = `translateY(${dy}px)`; } },
            onEnd: (_dx, dy, vy) => {
                s.style.transition = '';
                s.style.transform = '';
                if (dy > 110 || vy > 0.7) api.close();
            },
        });
        opts.render && opts.render(api.body, api);
        return api;
    },

    toast(text, icon = 'fa-solid fa-circle-check') {
        const t = el(`<div class="toast"><i class="${icon}"></i>${esc(text)}</div>`);
        UI.layer().appendChild(t);
        requestAnimationFrame(() => t.classList.add('show'));
        setTimeout(() => UI._dismiss([t], 400), 1800);
    },

    switchHtml(checked, attrs = '') {
        return `<label class="switch"><input type="checkbox" ${checked ? 'checked' : ''} ${attrs}><span></span></label>`;
    },

    empty(icon, title, text) {
        return `<div class="empty"><i class="${icon}"></i><b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}</div>`;
    },
};

/** Contact picker sheet: resolves with { name, number } or null */
function pickContact(title = 'Contacts') {
    return new Promise(async (resolve) => {
        let picked = null;
        const contacts = (await rpc('getContacts')) || [];
        UI.sheet({
            title,
            onClose: () => resolve(picked),
            render(body, api) {
                body.innerHTML = `
                    <div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div>
                    <div class="group list"></div>`;
                const list = $('.list', body);
                const draw = (q = '') => {
                    const f = contacts.filter((c) => !c.blocked && (c.name + c.number).toLowerCase().includes(q.toLowerCase()));
                    list.innerHTML = f.length ? f.map((c, i) => `
                        <div class="row tap has-icon" data-i="${contacts.indexOf(c)}" style="--sep-left:68px">
                            ${avatar(c.name, c.avatar)}
                            <div class="grow"><div class="title">${esc(c.name)}</div><div class="sub">${esc(c.number)}</div></div>
                        </div>`).join('') : `<div class="row muted">No Contacts</div>`;
                };
                draw();
                $('input', body).addEventListener('input', (e) => draw(e.target.value));
                list.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-i]');
                    if (!r) return;
                    picked = contacts[+r.dataset.i];
                    api.close();
                });
            },
        });
    });
}
