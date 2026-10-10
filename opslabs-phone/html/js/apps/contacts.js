'use strict';

/* Contacts: shared list/detail/editor used by Contacts, Phone and Messages */

const Contacts = {
    cache: [],
    async load() {
        this.cache = (await rpc('getContacts')) || [];
        return this.cache;
    },
    nameFor(number) {
        const c = this.cache.find((x) => x.number === number);
        return c ? c.name : null;
    },
    find(number) { return this.cache.find((x) => x.number === number); },
};

/** Alphabetical contacts list with search and "My Card". */
function ContactsList(content, ctx, { onSelect, showMyCard = true } = {}) {
    content.innerHTML = `
        <div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div>
        ${showMyCard ? `<div class="plain my-card"><div class="row tap" data-me style="padding:10px 16px 14px">
            ${avatar(Phone.profile?.name, null, 'lg')}
            <div class="grow"><div class="title" style="font-size:20px;font-weight:600">${esc(Phone.profile?.name || '')}</div><div class="sub">My Card</div></div>
        </div></div>` : ''}
        <div class="c-list"><div class="spinner"></div></div>`;
    const list = $('.c-list', content);
    let query = '';

    const draw = () => {
        const items = Contacts.cache.filter((c) => !c.blocked || query).filter((c) => (c.name + ' ' + c.number).toLowerCase().includes(query.toLowerCase()));
        if (!items.length) {
            list.innerHTML = UI.empty('fa-solid fa-address-book', query ? 'No Results' : 'No Contacts', query ? '' : 'Tap + to add someone.');
            return;
        }
        const groups = {};
        items.forEach((c) => {
            const k = /[a-z]/i.test(c.name[0]) ? c.name[0].toUpperCase() : '#';
            (groups[k] ||= []).push(c);
        });
        list.innerHTML = Object.keys(groups).sort().map((k) => `
            <div class="section-letter">${k}</div>
            <div class="plain">${groups[k].map((c) => `
                <div class="row tap" data-id="${c.id}"><div class="grow title">${esc(c.name)}${c.blocked ? ' <i class="fa-solid fa-ban muted" style="font-size:12px"></i>' : ''}</div></div>`).join('')}
            </div>`).join('') + `<div class="muted" style="text-align:center;font-size:15px;padding:16px">${items.length} Contacts</div>`;
    };

    const refresh = async () => { await Contacts.load(); draw(); };
    if (ctx && ctx.opts && !ctx.opts.onResume) ctx.opts.onResume = refresh;
    $('input', content).addEventListener('input', (e) => { query = e.target.value; draw(); });
    content.addEventListener('click', (e) => {
        const r = e.target.closest('[data-id]');
        if (r) return onSelect(Contacts.cache.find((c) => c.id === +r.dataset.id), refresh);
        if (e.target.closest('[data-me]')) MyCard(ctx.nav);
    });
    refresh();
    return { refresh };
}

function MyCard(nav) {
    const p = Phone.profile || {};
    nav.push({
        title: '',
        grouped: true,
        render(content) {
            content.innerHTML = `
                <div style="display:flex;flex-direction:column;align-items:center;padding:0 0 22px">
                    ${avatar(p.name, null, 'xl')}
                    <div style="font-size:28px;font-weight:600;margin-top:12px">${esc(p.name)}</div>
                    ${p.job ? `<div class="muted">${esc(p.job)}</div>` : ''}
                </div>
                <div class="group">
                    <div class="row"><div class="grow"><div style="font-size:14px">mobile</div><div class="tint">${esc(p.number)}</div></div></div>
                    <div class="row"><div class="grow"><div style="font-size:14px">email</div><div class="tint">${esc(p.email || '')}</div></div></div>
                </div>`;
        },
    });
}

/** Contact card with quick actions. */
function ContactDetail(nav, contact, onChange) {
    nav.push({
        title: '',
        grouped: true,
        right: '<button class="nav-btn" data-act="edit">Edit</button>',
        render(content, ctx) {
            const draw = () => {
                const c = contact;
                content.innerHTML = `
                    <div style="display:flex;flex-direction:column;align-items:center;padding:0 16px 18px">
                        ${avatar(c.name, c.avatar, 'xl')}
                        <div style="font-size:28px;font-weight:600;margin-top:12px;text-align:center">${esc(c.name)}</div>
                        <div style="display:flex;gap:8px;margin-top:16px;width:100%">
                            ${[['message', 'fa-message', 'message'], ['call', 'fa-phone', 'call'], ['mail', 'fa-envelope', 'mail'], ['share', 'fa-share-from-square', 'share']].map(([k, i, l]) => `
                                <button data-act="${k}" style="flex:1;background:var(--cell);border-radius:10px;padding:9px 0 7px;color:var(--tint);display:flex;flex-direction:column;align-items:center;gap:4px;font-size:11px${k === 'mail' && !c.email ? ';opacity:.4" disabled' : '"'}>
                                    <i class="fa-solid ${i}" style="font-size:18px"></i>${l}</button>`).join('')}
                        </div>
                    </div>
                    <div class="group">
                        <div class="row tap" data-act="call"><div class="grow"><div style="font-size:14px">mobile</div><div class="tint">${esc(c.number)}</div></div></div>
                        ${c.email ? `<div class="row tap" data-act="mail"><div class="grow"><div style="font-size:14px">email</div><div class="tint">${esc(c.email)}</div></div></div>` : ''}
                    </div>
                    <div class="group">
                        <div class="row tap" data-act="message"><span class="tint">Send Message</span></div>
                        <div class="row tap" data-act="favorite"><span class="tint">${c.favorite ? 'Remove from Favourites' : 'Add to Favourites'}</span></div>
                        <div class="row tap" data-act="location"><span class="tint">Share My Live Location</span></div>
                    </div>
                    <div class="group">
                        <div class="row tap" data-act="block"><span class="danger">${c.blocked ? 'Unblock this Caller' : 'Block this Caller'}</span></div>
                    </div>`;
            };
            draw();
            ctx.page.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a) return;
                const c = contact;
                switch (a.dataset.act) {
                    case 'call': Call.start(c.number, c.name); break;
                    case 'message': Phone.openApp('messages', { number: c.number }); break;
                    case 'mail': if (c.email) Phone.openApp('mail', { compose: c.email }); break;
                    case 'location':
                        Live.share(c.number, c.name);
                        break;
                    case 'share': OpsDrop({ name: c.name, number: c.number }); break;
                    case 'favorite':
                        await rpc('toggleFavorite', { id: c.id });
                        c.favorite = c.favorite ? 0 : 1; draw(); onChange && onChange();
                        break;
                    case 'block':
                        if (!c.blocked && !(await UI.confirm('Block Contact', "You will not receive calls or messages from people on the block list.", 'Block Contact', true))) return;
                        await rpc('toggleBlock', { number: c.number });
                        c.blocked = c.blocked ? 0 : 1; draw(); onChange && onChange();
                        break;
                    case 'edit':
                        ContactEditor(c, (saved) => {
                            if (saved === 'deleted') { onChange && onChange(); ctx.pop(); return; }
                            Object.assign(contact, saved); draw(); onChange && onChange();
                        });
                        break;
                }
            });
        },
    });
}

/** New / edit contact sheet. onSaved(contact | 'deleted') */
function ContactEditor(contact = {}, onSaved) {
    const isNew = !contact.id;
    UI.sheet({
        title: isNew ? 'New Contact' : '',
        right: 'Done',
        render(body, api) {
            body.innerHTML = `
                <div style="display:flex;flex-direction:column;align-items:center;padding:6px 0 22px">
                    ${avatar(contact.name, contact.avatar, 'xl')}
                    <button class="btn small gray" style="margin-top:12px" data-act="photo">${contact.avatar ? 'Edit' : 'Add Photo'}</button>
                </div>
                <div class="group">
                    <div class="row"><input class="field" data-f="name" placeholder="Name" value="${esc(contact.name || '')}"></div>
                </div>
                <div class="group">
                    <div class="row"><span class="lbl tint" style="width:70px">mobile</span><input class="field" data-f="number" placeholder="Phone" value="${esc(contact.number || '')}"></div>
                </div>
                <div class="group">
                    <div class="row"><span class="lbl tint" style="width:70px">email</span><input class="field" data-f="email" placeholder="Email" value="${esc(contact.email || '')}"></div>
                </div>
                ${isNew ? '' : '<div class="group"><div class="row tap destructive" data-act="delete">Delete Contact</div></div>'}`;
            const val = (f) => $(`[data-f=${f}]`, body).value.trim();
            const check = () => api.setRightEnabled(val('name') && val('number'));
            body.addEventListener('input', check);
            check();
            setTimeout(() => $('[data-f=name]', body).focus(), 300);

            body.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a) return;
                if (a.dataset.act === 'photo') {
                    const url = await UI.prompt('Contact Photo', 'Paste an image URL', { value: contact.avatar || '', placeholder: 'https://' });
                    if (url !== null) { contact.avatar = url; $('.avatar', body).outerHTML = avatar(val('name'), url, 'xl'); }
                }
                if (a.dataset.act === 'delete') {
                    if (await UI.confirm('Delete Contact', '', 'Delete Contact', true)) {
                        await rpc('deleteContact', { id: contact.id });
                        await Contacts.load();
                        api.close();
                        onSaved && onSaved('deleted');
                    }
                }
            });
        },
        async onRight(api) {
            const b = api.body;
            const data = {
                id: contact.id,
                name: $('[data-f=name]', b).value.trim(),
                number: $('[data-f=number]', b).value.trim(),
                email: $('[data-f=email]', b).value.trim(),
                avatar: contact.avatar || null,
            };
            api.setRightEnabled(false);
            const id = await rpc('saveContact', data);
            if (!id) { api.setRightEnabled(true); return UI.alert({ title: 'Could not save contact' }); }
            await Contacts.load();
            api.close();
            onSaved && onSaved({ ...data, id, favorite: contact.favorite || 0, blocked: contact.blocked || 0 });
        },
    });
}

/** OpsDrop a contact card to a nearby player */
async function OpsDrop(card) {
    const nearby = (await rpc('nearbyPlayers')) || [];
    UI.sheet({
        title: 'OpsDrop',
        left: 'Done',
        medium: true,
        render(body, api) {
            body.innerHTML = nearby.length ? `
                <div style="display:flex;flex-wrap:wrap;gap:22px;padding:20px 24px">
                    ${nearby.map((p) => `<button data-id="${p.id}" style="display:flex;flex-direction:column;align-items:center;gap:6px;width:72px;font-size:12px">
                        ${avatar(p.name, null, 'lg')}<span>${esc(p.name)}</span></button>`).join('')}
                </div>` : UI.empty('fa-solid fa-tower-broadcast', 'No People Found', 'Stand close to someone to OpsDrop.');
            body.addEventListener('click', async (e) => {
                const b = e.target.closest('[data-id]');
                if (!b) return;
                await rpc('shareContact', { target: +b.dataset.id, name: card.name, number: card.number });
                api.close();
                UI.toast('Sent', 'fa-solid fa-circle-check');
            });
        },
    });
}

Apps.register({
    id: 'contacts',
    name: 'Contacts',
    icon: {
        bg: 'linear-gradient(180deg,#f5f5f7,#d9d9de)',
        html: () => `<div style="width:42px;height:42px;border-radius:50%;background:linear-gradient(180deg,#b8bcc6,#8d929d);display:grid;place-items:center;overflow:hidden"><i class="fa-solid fa-user" style="font-size:30px;color:#f0f0f3;transform:translateY(6px)"></i></div>
            <div style="position:absolute;right:6px;top:10px;display:flex;flex-direction:column;gap:3px">${['#ff9500', '#34c759', '#007aff', '#8e8e93'].map((c) => `<i style="display:block;width:4px;height:7px;border-radius:2px;background:${c}"></i>`).join('')}</div>`,
    },
    open(root, params) {
        const nav = new Nav(root);
        nav.push({
            title: 'Contacts',
            large: true,
            right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
            render(content, ctx) {
                const list = ContactsList(content, ctx, { onSelect: (c, refresh) => ContactDetail(nav, c, refresh) });
                $('[data-act=add]', ctx.page).onclick = () => ContactEditor({}, () => list.refresh());
                if (params.newContact) ContactEditor(params.newContact, () => list.refresh());
            },
        });
    },
});
