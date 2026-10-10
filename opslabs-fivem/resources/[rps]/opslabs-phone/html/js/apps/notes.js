'use strict';

function NoteEditor(nav, note, onChange) {
    note = note || { title: '', body: '' };
    nav.push({
        title: '',
        backLabel: 'Notes',
        className: 'notes-page',
        right: '<button class="nav-btn" data-act="share"><i class="fa-solid fa-arrow-up-from-bracket"></i></button><button class="nav-btn bold" data-act="done">Done</button>',
        onLeave: () => save(true),
        render(content, ctx) {
            const d = note.updated_at ? toDate(note.updated_at) : new Date();
            content.innerHTML = `
                <div class="note-date">${esc(d.toLocaleDateString(Phone.locale, { day: 'numeric', month: 'long', year: 'numeric' }))} at ${esc(fmtTime(d))}</div>
                <textarea class="note-text" placeholder="Start typing…">${esc((note.title ? note.title + '\n' : '') + (note.body || ''))}</textarea>`;
            const ta = $('textarea', content);
            const autosize = () => { ta.style.height = 'auto'; ta.style.height = Math.max(500, ta.scrollHeight) + 'px'; };
            ta.addEventListener('input', () => { autosize(); debounced(); });
            autosize();
            if (!note.id) setTimeout(() => ta.focus(), 400);
            ctx.page.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a) return;
                if (a.dataset.act === 'done') { ta.blur(); save(); }
                if (a.dataset.act === 'share') {
                    const c = await pickContact('Send Note');
                    if (c && ta.value.trim()) {
                        await rpc('sendMessage', { number: c.number, message: ta.value.trim().slice(0, 1000) });
                        UI.toast('Sent to ' + c.name);
                    }
                }
            });
            ctx.textarea = ta;
        },
    });
    const ctx = nav.top.ctx;
    let saving = null;
    async function save(leaving) {
        // one save at a time, so a new note gets its id before the next save (no duplicates)
        while (saving) await saving;
        const text = ctx.textarea.value;
        const [first, ...rest] = text.split('\n');
        if (!text.trim()) {
            if (note.id && leaving) { await rpc('deleteNote', { id: note.id }); onChange(); }
            return;
        }
        if (first === note.title && rest.join('\n') === note.body) return;
        note.title = first.slice(0, 120);
        note.body = rest.join('\n');
        saving = rpc('saveNote', { id: note.id, title: note.title, body: note.body });
        const id = await saving;
        saving = null;
        if (id) note.id = id;
        onChange();
    }
    const debounced = debounce(() => save(), 800);
}

Apps.register({
    id: 'notes',
    name: 'Notes',
    icon: {
        bg: '#fff',
        html: () => `<div style="position:absolute;inset:0;background:linear-gradient(180deg,#ffd426 0 25%,#fff 25%)"></div>
            <div style="position:absolute;left:0;right:0;top:25%;height:1px;background:rgba(0,0,0,.12)"></div>
            <div style="position:absolute;left:8px;right:8px;top:44%;bottom:10px;background:repeating-linear-gradient(180deg,transparent 0 8px,#d8d8dc 8px 9.5px)"></div>
            <div style="position:absolute;left:8px;top:8%;display:flex;gap:4px">${'<i style="width:3px;height:3px;border-radius:50%;background:rgba(0,0,0,.25);display:block"></i>'.repeat(8)}</div>`,
    },
    open(root) {
        const nav = new Nav(root);
        nav.push({
            title: 'Notes',
            large: true,
            backTitle: 'Notes',
            className: 'notes-list-page',
            render(content, ctx) {
                content.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div><div class="n-list"><div class="spinner"></div></div>
                    <div class="toolbar"><span style="width:30px"></span><span class="n-count"></span><button class="nav-btn" data-act="new" style="color:#e4a900"><i class="fa-regular fa-pen-to-square"></i></button></div>`;
                ctx.page.appendChild($('.toolbar', content));
                const list = $('.n-list', content);
                let notes = [], q = '';
                const draw = () => {
                    const items = notes.filter((n) => (n.title + n.body).toLowerCase().includes(q.toLowerCase()));
                    $('.n-count', ctx.page).textContent = notes.length === 1 ? '1 Note' : `${notes.length} Notes`;
                    list.innerHTML = items.length ? `<div class="group">${items.map((n) => `
                        <div class="row tap" data-id="${n.id}" style="display:block">
                            <div class="title" style="font-weight:600">${esc(n.title || 'New Note')}</div>
                            <div class="sub"><span style="color:var(--label)">${esc(relTime(n.updated_at))}</span>&nbsp;&nbsp;${esc((n.body || '').split('\n').find((l) => l.trim()) || 'No additional text')}</div>
                        </div>`).join('')}</div>` : UI.empty('fa-regular fa-note-sticky', 'No Notes', '');
                };
                const load = async () => { notes = (await rpc('getNotes')) || []; draw(); };
                $('input', content).addEventListener('input', (e) => { q = e.target.value; draw(); });
                swipeRows(list, '.row[data-id]', { onDelete: async (row) => { await rpc('deleteNote', { id: +row.dataset.id }); load(); } });
                list.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-id]');
                    if (r) NoteEditor(nav, notes.find((n) => n.id === +r.dataset.id), load);
                });
                $('[data-act=new]', ctx.page).onclick = () => NoteEditor(nav, null, load);
                ctx.opts.onResume = load;
                load();
            },
        });
    },
});
