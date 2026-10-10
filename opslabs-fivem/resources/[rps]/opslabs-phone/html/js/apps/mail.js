'use strict';

function MailCompose(to = '', subject = '', onSent) {
    UI.sheet({
        title: 'New Message',
        right: 'Send',
        render(body, api) {
            body.innerHTML = `
                <div class="group" style="margin:0;border-radius:0;background:transparent">
                    <div class="row" style="background:transparent"><span class="muted">To:</span><input class="field" data-f="to" value="${esc(to)}"></div>
                    <div class="row" style="background:transparent"><span class="muted">Cc/Bcc, From:</span><span class="muted mail-from" style="font-size:15px">${esc(Phone.profile?.email || '')}</span></div>
                    <div class="row" style="background:transparent"><span class="muted">Subject:</span><input class="field" data-f="subject" value="${esc(subject)}"></div>
                </div>
                <textarea class="mail-body" data-f="body" placeholder=""></textarea>`;
            // your own domains' mailboxes (OPS Web) can be picked as the sender
            rpc('mailFrom').then((list) => {
                if (!Array.isArray(list) || list.length < 2) return;
                $('.mail-from', body).innerHTML = `<select class="field" data-f="from" style="font-size:15px">${list.map((a) => `<option>${esc(a)}</option>`).join('')}</select>`;
            });
            const check = () => api.setRightEnabled(/@/.test($('[data-f=to]', body).value));
            body.addEventListener('input', check);
            check();
            setTimeout(() => $(to ? '[data-f=subject]' : '[data-f=to]', body).focus(), 350);
        },
        async onRight(api) {
            const b = api.body;
            api.setRightEnabled(false);
            const ok = await rpc('sendMail', {
                to: $('[data-f=to]', b).value.trim(),
                from: $('[data-f=from]', b) ? $('[data-f=from]', b).value : undefined,
                subject: $('[data-f=subject]', b).value.trim() || '(No Subject)',
                body: $('[data-f=body]', b).value,
            });
            if (!ok) { api.setRightEnabled(true); return UI.alert({ title: 'Cannot Send Mail', message: 'Check the recipient address.' }); }
            Sound.play('sent');
            api.close();
            onSent && onSent();
        },
    });
}

function MailRead(nav, m, box, reload) {
    if (!m.is_read && box === 'inbox') { rpc('readMail', { id: m.id }); m.is_read = 1; }
    nav.push({
        title: '',
        solidBar: false,
        render(content, ctx) {
            const d = toDate(m.created_at);
            content.innerHTML = `
                <div class="mail-view">
                    <div class="mv-head">
                        ${avatar(m.sender_name || m.sender)}
                        <div class="grow">
                            <div class="mv-from"><b>${esc(m.sender_name || m.sender)}</b><span class="muted">${esc(relTime(d))}</span></div>
                            <div class="muted" style="font-size:14px">To: ${esc(box === 'sent' ? m.receiver : 'You')}</div>
                        </div>
                    </div>
                    <div class="mv-subject">${esc(m.subject)}</div>
                    <div class="mv-body">${esc(m.body).replace(/\n/g, '<br>')}</div>
                </div>
                <div class="toolbar">
                    <button class="nav-btn" data-act="delete"><i class="fa-regular fa-trash-can"></i></button>
                    <button class="nav-btn" data-act="reply"><i class="fa-solid fa-reply"></i></button>
                    <button class="nav-btn" data-act="new"><i class="fa-regular fa-pen-to-square"></i></button>
                </div>`;
            ctx.page.appendChild($('.toolbar', content));
            ctx.page.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a) return;
                if (a.dataset.act === 'delete' && box === 'inbox') {
                    await rpc('deleteMail', { id: m.id });
                    reload(); ctx.pop();
                }
                if (a.dataset.act === 'reply') MailCompose(box === 'sent' ? m.receiver : m.sender, 'Re: ' + m.subject.replace(/^Re:\s*/i, ''));
                if (a.dataset.act === 'new') MailCompose();
            });
        },
    });
}

function MailBox(nav, box) {
    nav.push({
        title: box === 'sent' ? 'Sent' : 'Inbox',
        large: true,
        className: 'mailbox-page',
        backLabel: 'Mailboxes',
        // the inbox can be edited: select mails to mark as read or delete (sent mail is kept)
        right: box === 'inbox' ? '<button class="nav-btn" data-act="edit">Edit</button>' : '',
        render(content, ctx) {
            content.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div><div class="m-list"><div class="spinner"></div></div>
                <div class="toolbar"><span></span><span class="m-updated" style="font-size:11px">Updated Just Now</span><button class="nav-btn" data-act="new"><i class="fa-regular fa-pen-to-square"></i></button></div>`;
            ctx.page.appendChild($('.toolbar', content));
            const list = $('.m-list', content);
            const toolbar = $('.toolbar', ctx.page), toolbarHtml = toolbar.innerHTML;
            let mails = [], q = '', editing = false;
            const selected = new Set();
            const drawToolbar = () => {
                if (!editing) { toolbar.innerHTML = toolbarHtml; $('[data-act=new]', toolbar).onclick = () => MailCompose('', '', load); return; }
                const n = selected.size;
                toolbar.innerHTML = `<button class="nav-btn" data-act="markread" ${n ? '' : 'disabled'}>Mark Read</button>
                    <span style="font-size:13px;font-weight:600">${n ? `${n} Selected` : 'Select Messages'}</span>
                    <button class="nav-btn" data-act="trash" style="color:var(--red)" ${n ? '' : 'disabled'}>Delete</button>`;
            };
            const draw = () => {
                const items = mails.filter((m) => (m.subject + m.body + (m.sender_name || '') + m.sender).toLowerCase().includes(q.toLowerCase()));
                list.innerHTML = items.length ? `<div class="plain">${items.map((m) => `
                    <div class="row tap ${editing ? 'mail-sel' : 'mail-row'}" data-id="${m.id}" style="--sep-left:32px">
                        ${editing ? `<span class="mail-check ${selected.has(m.id) ? 'on' : ''}"><i class="fa-solid fa-check"></i></span>` : `<span class="unread-dot ${!m.is_read ? 'on' : ''}"></span>`}
                        <div class="grow">
                            <div class="cv-top"><span class="title" style="font-weight:600">${esc(box === 'sent' ? m.receiver : (m.sender_name || m.sender))}</span><span class="cv-time">${esc(relTime(m.created_at))} <i class="fa-solid fa-chevron-right"></i></span></div>
                            <div style="font-size:15px">${esc(m.subject)}</div>
                            <div class="cv-prev">${esc(m.body)}</div>
                        </div>
                    </div>`).join('')}</div>` : UI.empty('fa-solid fa-envelope-open', 'No Mail', '');
            };
            const load = async () => {
                mails = (await rpc('getMail', { box })) || [];
                if (box === 'inbox') Phone.setBadge('mail', mails.filter((m) => !m.is_read).length);
                [...selected].forEach((id) => { if (!mails.some((m) => m.id === id)) selected.delete(id); });
                draw();
                drawToolbar();
            };
            $('input', content).addEventListener('input', (e) => { q = e.target.value; draw(); });
            if (box === 'inbox') swipeRows(list, '.mail-row', { onDelete: async (row) => { await rpc('deleteMail', { id: +row.dataset.id }); load(); } });
            list.addEventListener('click', (e) => {
                const r = e.target.closest('[data-id]');
                if (!r) return;
                const id = +r.dataset.id;
                if (editing) {
                    if (!selected.delete(id)) selected.add(id);
                    $('.mail-check', r).classList.toggle('on', selected.has(id));
                    return drawToolbar();
                }
                const m = mails.find((x) => x.id === id);
                if (m) MailRead(nav, m, box, load);
            });
            const setEditing = (on) => {
                editing = on;
                selected.clear();
                const b = $('[data-act=edit]', ctx.page);
                if (b) b.textContent = I18N.t(on ? 'Done' : 'Edit');
                draw();
                drawToolbar();
            };
            let busy = false;
            ctx.page.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a || a.disabled) return;
                if (a.dataset.act === 'edit') return setEditing(!editing);
                if (busy || !selected.size || !['markread', 'trash'].includes(a.dataset.act)) return;
                const ids = [...selected];
                if (a.dataset.act === 'trash' && !await UI.confirm(`Delete ${ids.length} message${ids.length === 1 ? '' : 's'}?`, '', 'Delete', true)) return;
                busy = true;
                await Promise.all(ids.map((id) => rpc(a.dataset.act === 'trash' ? 'deleteMail' : 'readMail', { id })));
                busy = false;
                setEditing(false);
                load();
            });
            drawToolbar();
            ctx.opts.onResume = load;
            ctx.reload = load;
            load();
        },
    });
}

Apps.register({
    id: 'mail',
    name: 'Mail',
    icon: {
        bg: 'linear-gradient(180deg,#1fb5ff,#1a6dfb)',
        html: () => `<svg viewBox="0 0 64 64" width="44" height="44"><rect x="6" y="14" width="52" height="36" rx="5" fill="#fff"/><path d="M8 17l24 19 24-19" fill="none" stroke="#1a8cfb" stroke-width="3" stroke-linejoin="round"/></svg>`,
    },
    open(root, params, app) {
        const nav = new Nav(root);
        nav.push({
            title: 'Mailboxes',
            large: true,
            grouped: true,
            render(content) {
                content.innerHTML = `
                    <div class="group">
                        <div class="row tap has-icon" data-box="inbox"><i class="fa-solid fa-inbox tint" style="width:30px;font-size:20px"></i><div class="grow">Inbox</div><span class="value" data-count></span><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-box="sent"><i class="fa-regular fa-paper-plane tint" style="width:30px;font-size:20px"></i><div class="grow">Sent</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    </div>
                    <div class="group-header">${esc(Phone.profile?.email || 'OPS ID')}</div>`;
                const c = $('[data-count]', content);
                if (Phone.badges.mail) c.textContent = Phone.badges.mail;
                content.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-box]');
                    if (r) MailBox(nav, r.dataset.box);
                });
            },
        });
        MailBox(nav, 'inbox');
        if (params.compose) MailCompose(params.compose);
        app.on('mail', () => { const top = nav.top; if (top && top.ctx.reload) top.ctx.reload(); });
    },
    onParams(params) { if (params.compose) MailCompose(params.compose); },
});

Phone.on('mail', () => {
    if (!(Phone.current && Phone.current.def.id === 'mail')) Phone.setBadge('mail', (Phone.badges.mail || 0) + 1);
});
