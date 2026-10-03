'use strict';

const Messages = {
    openThread: null,   // number of the thread currently on screen
    updateBadge(convos) {
        const n = convos.reduce((a, c) => a + (c.unread || 0), 0);
        Phone.setBadge('messages', n);
    },
};

function locationCard(a, mine) {
    return `
        <div class="msg-location ${mine ? 'mine' : ''}" data-gps="${a.x},${a.y}">
            <div class="ml-map"><span class="ml-pin"><i class="fa-solid fa-location-dot"></i></span></div>
            <div class="ml-info"><b>Shared Location</b><span>Tap to set GPS</span></div>
        </div>`;
}

function bubbleHtml(m, i, list, otherName) {
    const prev = list[i - 1], next = list[i + 1];
    const t = toDate(m.created_at);
    let header = '';
    if (!prev || t - toDate(prev.created_at) > 3600000) {
        const day = isSameDay(t, new Date()) ? 'Today' : relTime(t);
        header = `<div class="msg-time"><b>${esc(day)}</b> ${esc(fmtTime(t))}</div>`;
    }
    const last = !next || next.mine !== m.mine || toDate(next.created_at) - t > 3600000;
    const a = m.attachment;
    let inner = '';
    if (a && a.type === 'location') inner += locationCard(a, m.mine);
    if (a && a.type === 'live') inner += liveCardHtml(a, m.mine, otherName);
    if (a && a.type === 'image') inner += `<img class="msg-img" src="${escUrl(a.url)}" data-img="${escUrl(a.url)}">`;
    if (m.message) inner += `<div class="bubble ${m.mine ? 'out' : 'in'} ${last ? 'tail' : ''}">${esc(m.message)}</div>`;
    return `${header}<div class="msg-row ${m.mine ? 'out' : 'in'} ${last ? 'last' : ''}" data-mid="${m.id}">${inner}</div>`;
}

function ThreadView(nav, number, name) {
    Messages.openThread = number;
    const display = name || Contacts.nameFor(number) || number;
    nav.push({
        title: '',
        backLabel: '',
        className: 'thread-page',
        solidBar: true,
        right: '<button class="nav-btn" data-act="call"><i class="fa-solid fa-phone" style="font-size:18px"></i></button>',
        onLeave: () => { Messages.openThread = null; },
        render(content, ctx) {
            const c = Contacts.find(number);
            $('.nav-title', ctx.page).innerHTML = `
                <div class="thread-head">${avatar(display, c && c.avatar, 'sm')}<span>${esc(display)} <i class="fa-solid fa-chevron-right"></i></span></div>`;
            $('.nav-title', ctx.page).style.pointerEvents = 'all';
            ctx.page.insertAdjacentHTML('beforeend', `
                <div class="composer">
                    <button class="cmp-plus" data-act="plus"><i class="fa-solid fa-plus"></i></button>
                    <div class="cmp-field"><textarea rows="1" placeholder="Message"></textarea>
                        <button class="cmp-send hidden" data-act="send"><i class="fa-solid fa-arrow-up"></i></button></div>
                </div>`);
            content.innerHTML = '<div class="msg-list"><div class="spinner"></div></div>';
            const list = $('.msg-list', content);
            const ta = $('.composer textarea', ctx.page);
            let msgs = [];

            const draw = () => {
                list.innerHTML = msgs.map((m, i, l) => bubbleHtml(m, i, l, display)).join('') +
                    (msgs.length && msgs[msgs.length - 1].mine ? '<div class="msg-delivered">Delivered</div>' : '');
                updateLiveCards(list);
                ctx.body.scrollTop = ctx.body.scrollHeight;
                if ($('.live-card', list)) {
                    nui('getLocation').then((p) => { if (p) { Live.myPos = p; updateLiveCards(list); } });
                }
            };
            const load = async () => {
                msgs = (await rpc('getMessages', { number })) || [];
                draw();
                Phone.emit('messagesRead', number);
            };

            const send = async (text, attachment) => {
                text = (text || '').trim();
                if (!text && !attachment) return;
                const tmp = { id: 'tmp' + Date.now(), mine: true, message: text, attachment: attachment && attachment.type === 'image' ? attachment : null, created_at: Date.now() };
                if (!attachment || attachment.type === 'image') { msgs.push(tmp); draw(); }
                Sound.play('sent');
                const ok = await rpc('sendMessage', { number, message: text, attachment });
                if (!ok) { UI.toast('Not Delivered', 'fa-solid fa-circle-exclamation'); }
                load();
            };

            ta.addEventListener('input', () => {
                ta.style.height = 'auto';
                ta.style.height = Math.min(110, ta.scrollHeight) + 'px';
                $('.cmp-send', ctx.page).classList.toggle('hidden', !ta.value.trim());
            });
            ta.addEventListener('keydown', (e) => {
                if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    const v = ta.value; ta.value = ''; ta.dispatchEvent(new Event('input'));
                    send(v);
                }
            });

            ctx.page.addEventListener('click', async (e) => {
                const act = e.target.closest('[data-act]');
                if (act) {
                    if (act.dataset.act === 'send') {
                        const v = ta.value; ta.value = ''; ta.dispatchEvent(new Event('input'));
                        send(v);
                    } else if (act.dataset.act === 'call') {
                        Call.start(number, display);
                    } else if (act.dataset.act === 'plus') {
                        const i = await UI.actionSheet(null, [{ label: 'Share Live Location' }, { label: 'Send Current Location' }, { label: 'Photos' }, { label: 'Image from URL' }]);
                        if (i === 0) { if (await Live.share(number, display)) load(); }
                        if (i === 1) send('', { type: 'location' });
                        if (i === 2) {
                            const url = await pickPhoto();
                            if (url) send('', { type: 'image', url });
                        }
                        if (i === 3) {
                            const url = await UI.prompt('Send Image', 'Paste an image URL', { placeholder: 'https://' });
                            if (url) send('', { type: 'image', url });
                        }
                    }
                    return;
                }
                const live = e.target.closest('.live-card');
                if (live) return Phone.openApp('maps', { live: +live.dataset.live, mine: live.dataset.mine === '1' });
                const gps = e.target.closest('[data-gps]');
                if (gps) {
                    const [x, y] = gps.dataset.gps.split(',').map(Number);
                    nui('setWaypoint', { x, y });
                    UI.toast('GPS set', 'fa-solid fa-location-arrow');
                    return;
                }
                const img = e.target.closest('[data-img]');
                if (img) return PhotoViewer(img.dataset.img);
                if (e.target.closest('.thread-head')) {
                    const ct = Contacts.find(number);
                    if (ct) ContactDetail(nav, ct, () => Contacts.load());
                    else ContactEditor({ number }, () => {});
                }
            });

            ctx.thread = { reload: load };
            ctx.opts.onResume = load;
            Messages.currentThread = ctx.thread;
            ctx.opts.onLeave = () => { Messages.openThread = null; Messages.currentThread = null; };
            load();
            setTimeout(() => ta.focus(), 400);
        },
    });
}

function NewMessage(nav) {
    UI.sheet({
        title: 'New Message',
        render(body, api) {
            body.innerHTML = `
                <div class="group" style="margin-top:4px">
                    <div class="row"><span class="muted">To:</span><input class="field" data-f="to" placeholder="Name or number">
                        <button class="tint" data-act="pick" style="font-size:22px"><i class="fa-solid fa-circle-plus"></i></button></div>
                </div>
                <div class="group suggestions plain" style="background:transparent"></div>`;
            const input = $('[data-f=to]', body);
            const sug = $('.suggestions', body);
            const go = (number, name) => { api.close(); ThreadView(nav, number, name); };
            input.addEventListener('input', () => {
                const q = input.value.toLowerCase();
                const f = q ? Contacts.cache.filter((c) => (c.name + c.number).toLowerCase().includes(q)).slice(0, 8) : [];
                sug.innerHTML = f.map((c) => `<div class="row tap" data-n="${esc(c.number)}" data-name="${esc(c.name)}" style="--sep-left:68px">${avatar(c.name, c.avatar)}<div class="grow"><div class="title">${esc(c.name)}</div><div class="sub">${esc(c.number)}</div></div></div>`).join('');
            });
            input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && input.value.trim()) go(input.value.trim()); });
            body.addEventListener('click', async (e) => {
                const r = e.target.closest('[data-n]');
                if (r) return go(r.dataset.n, r.dataset.name);
                if (e.target.closest('[data-act=pick]')) {
                    api.close();
                    const c = await pickContact();
                    if (c) ThreadView(nav, c.number, c.name);
                }
            });
            setTimeout(() => input.focus(), 350);
        },
    });
}

Apps.register({
    id: 'messages',
    name: 'Messages',
    icon: { bg: 'linear-gradient(180deg,#65f27e,#0dbd2e)', glyph: 'fa-solid fa-comment', size: 34, glyphStyle: 'transform:scaleX(1.08)' },
    open(root, params, app) {
        const nav = new Nav(root);
        app.nav = nav;
        let convos = [];
        nav.push({
            title: 'Messages',
            large: true,
            left: '<button class="nav-btn" data-act="edit" style="padding-left:8px">Edit</button>',
            right: '<button class="nav-btn" data-act="new"><i class="fa-regular fa-pen-to-square"></i></button>',
            render(content, ctx) {
                content.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div><div class="cv-list"><div class="spinner"></div></div>`;
                const list = $('.cv-list', content);
                let q = '', editing = false;
                const draw = () => {
                    const items = convos.filter((c) => ((c.name || '') + c.number + (c.last || '')).toLowerCase().includes(q.toLowerCase()));
                    list.innerHTML = items.length ? `<div class="plain">${items.map((c) => {
                        const name = c.name || Contacts.nameFor(c.number) || c.number;
                        return `<div class="row tap convo" data-n="${esc(c.number)}" style="--sep-left:84px">
                            <span class="unread-dot ${c.unread ? 'on' : ''}"></span>
                            ${avatar(name, c.avatar, 'convo-av')}
                            <div class="grow">
                                <div class="cv-top"><span class="title">${esc(name)}</span><span class="cv-time">${esc(relTime(c.time))} <i class="fa-solid fa-chevron-right"></i></span></div>
                                <div class="cv-prev">${c.attachment && !c.last ? ({ live: '<i class="fa-solid fa-location-arrow"></i> Live Location', location: '<i class="fa-solid fa-location-dot"></i> Location', image: '<i class="fa-solid fa-image"></i> Photo' }[c.attachment] || 'Attachment') : esc(c.last)}</div>
                            </div>
                            ${editing ? `<button class="cv-del" data-del="${esc(c.number)}"><i class="fa-solid fa-trash"></i></button>` : ''}
                        </div>`;
                    }).join('')}</div>` : UI.empty('fa-solid fa-comments', q ? 'No Results' : 'No Messages', q ? '' : 'Tap the compose button to start a conversation.');
                };
                const load = async () => {
                    await Contacts.load();
                    convos = (await rpc('getConversations')) || [];
                    Messages.updateBadge(convos);
                    draw();
                };
                $('input', content).addEventListener('input', (e) => { q = e.target.value; draw(); });
                swipeRows(list, '.convo', {
                    onDelete: async (row) => {
                        if (!(await UI.confirm(I18N.t('Delete Conversation'), '', I18N.t('Delete'), true))) return draw();
                        await rpc('deleteConversation', { number: row.dataset.n });
                        load();
                    },
                });
                content.addEventListener('click', async (e) => {
                    const d = e.target.closest('[data-del]');
                    if (d) {
                        e.stopPropagation();
                        if (await UI.confirm('Delete Conversation', 'This conversation will be deleted from this phone.', 'Delete', true)) {
                            await rpc('deleteConversation', { number: d.dataset.del });
                            load();
                        }
                        return;
                    }
                    const r = e.target.closest('[data-n]');
                    if (r) ThreadView(nav, r.dataset.n);
                });
                $('[data-act=new]', ctx.page).onclick = () => NewMessage(nav);
                $('[data-act=edit]', ctx.page).onclick = (e) => { editing = !editing; e.target.textContent = editing ? 'Done' : 'Edit'; draw(); };
                ctx.opts.onResume = load;
                app.reloadList = load;
                load();
            },
        });

        app.on('message', (m) => {
            if (Messages.openThread === m.number && Messages.currentThread) Messages.currentThread.reload();
            else if (nav.stack.length === 1) app.reloadList();
        });
        if (params.number) ThreadView(nav, params.number);
    },
    onParams(params, app) {
        if (params.number) {
            app.nav.popToRoot();
            ThreadView(app.nav, params.number);
        }
    },
    suppress(n) {
        return n.data && n.data.number && Messages.openThread === n.data.number;
    },
    onClose() { Messages.openThread = null; Messages.currentThread = null; },
});

// unread badge while the app is closed
Phone.on('message', () => {
    if (!(Phone.current && Phone.current.def.id === 'messages' && Messages.openThread)) {
        Phone.setBadge('messages', (Phone.badges.messages || 0) + 1);
    }
});
