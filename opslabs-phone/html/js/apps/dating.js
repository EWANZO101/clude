'use strict';

/*
 * Sparks — dating. Discover: a deck of people who fit what you're looking for (drag right to like, left to pass,
 * tap the photo for the next one). A mutual like is a match; chat with your matches, unmatch or report anyone.
 * Profile: name, age (18+), gender, who you're looking for, photos from your library, bio, job, area, interests.
 * Server: server/dating.lua.
 */

const SPARKS_PINK = '#ff2d6f';
const SPARKS_INTERESTS = ['Cars', 'Music', 'Gym', 'Coffee', 'Nightlife', 'Beach', 'Hiking', 'Gaming', 'Cooking', 'Movies', 'Art', 'Travel', 'Dogs', 'Cats', 'Fishing', 'Golf', 'Dancing', 'Racing'];
const sparksGender = { man: 'Man', woman: 'Woman', nonbinary: 'Non-binary' };
const sparksSeeking = { men: 'Men', women: 'Women', everyone: 'Everyone' };

function sparksPhoto(p, i = 0) {
    const u = (p.photos || [])[i];
    return u ? `background-image:url('${cssUrl(u)}')` : `background:linear-gradient(160deg,${SPARKS_PINK},#7a2cff)`;
}

function sparksCardHtml(p) {
    const n = (p.photos || []).length;
    return `<div class="sp-card" data-id="${p.id}" data-photo="0" style="${sparksPhoto(p)}">
        ${n > 1 ? `<div class="sp-dots">${p.photos.map((_, i) => `<i class="${i === 0 ? 'on' : ''}"></i>`).join('')}</div>` : ''}
        ${n === 0 ? `<div class="sp-noimg">${esc((p.name || '?')[0])}</div>` : ''}
        <div class="sp-stamp like">LIKE</div><div class="sp-stamp nope">NOPE</div>
        <div class="sp-info">
            <div class="sp-name">${esc(p.name)} <span>${esc(String(p.age))}</span></div>
            ${p.job || p.area ? `<div class="sp-sub">${p.job ? `<i class="fa-solid fa-briefcase"></i>${esc(p.job)}` : ''}${p.area ? `<i class="fa-solid fa-location-dot"></i>${esc(p.area)}` : ''}</div>` : ''}
            ${p.bio ? `<div class="sp-bio">${esc(p.bio)}</div>` : ''}
            ${(p.interests || []).length ? `<div class="sp-tags">${p.interests.map((t) => `<span>${esc(t)}</span>`).join('')}</div>` : ''}
        </div>
    </div>`;
}

function SparksEditor(onSaved) {
    rpc('datingProfile').then((d) => {
        if (!d) return;
        const p = d.profile || { name: d.suggestedName || '', age: d.minAge, gender: 'man', photos: [], interests: [] };
        const st = { photos: [...(p.photos || [])], interests: new Set(p.interests || []) };
        UI.sheet({
            title: d.profile ? 'Edit Profile' : 'Create Your Profile',
            right: 'Save',
            render(body) {
                const photos = () => {
                    $('.sp-ed-photos', body).innerHTML = st.photos.map((u, i) => `<div class="sp-ed-ph" style="background-image:url('${cssUrl(u)}')"><button data-rm="${i}"><i class="fa-solid fa-xmark"></i></button></div>`).join('')
                        + (st.photos.length < (d.maxPhotos || 4) ? '<button class="sp-ed-add" data-act="add"><i class="fa-solid fa-plus"></i></button>' : '');
                };
                body.innerHTML = `
                    <div class="sp-ed-photos"></div>
                    <div class="group-footer" style="margin-top:-8px">Add up to ${d.maxPhotos || 4} photos from your library. The first one is your main photo.</div>
                    <div class="group">
                        <div class="row"><span class="lbl">Name</span><input class="field" data-f="name" maxlength="40" value="${esc(p.name || '')}"></div>
                        <div class="row"><span class="lbl">Age</span><input class="field" data-f="age" type="number" min="${d.minAge}" max="99" value="${esc(String(p.age || d.minAge))}"></div>
                        <div class="row"><span class="lbl">I am a</span><select class="field" data-f="gender">${Object.entries(sparksGender).map(([k, v]) => `<option value="${k}" ${p.gender === k ? 'selected' : ''}>${v}</option>`).join('')}</select></div>
                        <div class="row"><span class="lbl">Show me</span><select class="field" data-f="seeking">${Object.entries(sparksSeeking).map(([k, v]) => `<option value="${k}" ${(d.seeking || 'everyone') === k ? 'selected' : ''}>${v}</option>`).join('')}</select></div>
                    </div>
                    <div class="group">
                        <div class="row"><textarea class="field" data-f="bio" maxlength="500" placeholder="About me">${esc(p.bio || '')}</textarea></div>
                        <div class="row"><span class="lbl">Job</span><input class="field" data-f="job" maxlength="60" value="${esc(p.job || '')}" placeholder="Optional"></div>
                        <div class="row"><span class="lbl">Area</span><input class="field" data-f="area" maxlength="60" value="${esc(p.area || '')}" placeholder="Vinewood, Sandy Shores…"></div>
                    </div>
                    <div class="group-header">Interests (up to 8)</div>
                    <div class="sp-ed-tags">${SPARKS_INTERESTS.map((t) => `<button data-tag="${esc(t)}" class="${st.interests.has(t) ? 'on' : ''}">${esc(t)}</button>`).join('')}</div>
                    ${d.profile ? `<div class="group" style="margin-top:20px"><div class="row"><div class="grow">Show me on Sparks</div>${UI.switchHtml(d.active !== false, 'data-f="active"')}</div></div>
                        <div class="group-footer">Turn off to take a break — you keep your matches and chats.</div>` : ''}
                    <div class="group-footer">Sparks is for ages ${d.minAge}+. Be kind; report anyone who isn’t.</div>`;
                photos();
                body.addEventListener('click', async (e) => {
                    const rm = e.target.closest('[data-rm]');
                    if (rm) { st.photos.splice(+rm.dataset.rm, 1); return photos(); }
                    if (e.target.closest('[data-act=add]')) { const u = await pickPhoto(); if (u) { st.photos.push(u); photos(); } return; }
                    const t = e.target.closest('[data-tag]');
                    if (t) {
                        const v = t.dataset.tag;
                        if (st.interests.has(v)) st.interests.delete(v); else if (st.interests.size < 8) st.interests.add(v);
                        t.classList.toggle('on', st.interests.has(v));
                    }
                });
            },
            async onRight(api) {
                const v = (f) => { const x = $(`[data-f=${f}]`, api.body); return x ? (x.type === 'checkbox' ? x.checked : x.value.trim()) : undefined; };
                const res = await rpc('datingSave', { name: v('name'), age: +v('age'), gender: v('gender'), seeking: v('seeking'), bio: v('bio'), job: v('job'), area: v('area'),
                    photos: st.photos, interests: [...st.interests], active: v('active') === undefined ? true : v('active') });
                if (!res || res.error) return UI.alert({ title: (res && res.error) || 'Could not save' });
                api.close();
                UI.toast('Profile saved', 'fa-solid fa-heart');
                onSaved && onSaved();
            },
        });
    });
}

function SparksMatchCelebration(host, match, onChat) {
    const o = el(`<div class="sp-match">
        <div class="sp-match-title">It’s a match!</div>
        <div class="sp-match-sub">You and ${esc(match.profile.name)} like each other</div>
        <div class="sp-match-pics"><span style="${sparksPhoto(match.profile)}"></span><i class="fa-solid fa-heart"></i></div>
        <button class="sp-btn primary" data-a="chat">Send a message</button>
        <button class="sp-btn" data-a="keep">Keep swiping</button>
    </div>`);
    host.appendChild(o);
    Sound.play('notify');
    o.addEventListener('click', (e) => {
        const a = e.target.closest('[data-a]');
        if (!a) return;
        o.remove();
        if (a.dataset.a === 'chat') onChat(match);
    });
}

function SparksChat(nav, match, onChange) {
    nav.push({
        title: match.profile.name,
        solidBar: true,
        right: '<button class="nav-btn" data-act="more"><i class="fa-solid fa-ellipsis"></i></button>',
        render(content, ctx) {
            content.classList.add('sp-chat-page');
            content.innerHTML = `<div class="sp-chat-head"><span class="sp-av" style="${sparksPhoto(match.profile)}"></span><div><b>${esc(match.profile.name)}, ${esc(String(match.profile.age))}</b><div class="muted">${esc(match.profile.bio || '')}</div></div></div>
                <div class="sp-msgs"><div class="spinner"></div></div>
                <form class="sp-compose"><input maxlength="1000" placeholder="Message"><button><i class="fa-solid fa-arrow-up"></i></button></form>`;
            const box = $('.sp-msgs', content);
            let msgs = [];
            const draw = () => {
                box.innerHTML = msgs.length ? msgs.map((m) => `<div class="sp-bub ${m.mine ? 'me' : ''}">${esc(m.body)}</div>`).join('')
                    : `<div class="sp-chat-empty"><i class="fa-solid fa-heart"></i>You matched with ${esc(match.profile.name)}. Say hi!</div>`;
                box.scrollTop = box.scrollHeight;
            };
            const load = async () => {
                const r = await rpc('datingChat', { match: match.id });
                if (!r || r.error) { box.innerHTML = UI.empty('fa-solid fa-heart-crack', 'Chat unavailable', (r && r.error) || ''); return; }
                msgs = r.messages || [];
                draw();
                onChange && onChange();
            };
            $('form', content).addEventListener('submit', async (e) => {
                e.preventDefault();
                const inp = $('input', content);
                const body = inp.value.trim();
                if (!body) return;
                inp.value = '';
                msgs.push({ body, mine: true });
                draw();
                const r = await rpc('datingSend', { match: match.id, body });
                if (!r || r.error) UI.toast((r && r.error) || 'Not sent', 'fa-solid fa-circle-xmark');
                else Sound.play('sent');
            });
            ctx.page.addEventListener('click', async (e) => {
                if (!e.target.closest('[data-act=more]')) return;
                const i = await UI.actionSheet(match.profile.name, [{ label: 'Unmatch', destructive: true }, { label: 'Report', destructive: true }]);
                if (i === 0 && (await UI.confirm('Unmatch?', `You won't see ${match.profile.name} again and the chat is closed.`, 'Unmatch', true))) {
                    await rpc('datingUnmatch', { match: match.id });
                    nav.pop(); onChange && onChange();
                } else if (i === 1) {
                    const why = await UI.prompt('Report', 'What happened? Server staff can see reports.', { placeholder: 'Reason', ok: 'Report' });
                    if (why === null) return;
                    await rpc('datingReport', { id: match.profile.id, reason: why });
                    UI.toast('Reported — you won’t see them again');
                    nav.pop(); onChange && onChange();
                }
            });
            SparksChat._live = (m) => { if (m && m.match === match.id && content.isConnected) { msgs.push({ body: m.body, mine: false }); draw(); rpc('datingChat', { match: match.id }); } };
            load();
        },
    });
}

Apps.register({
    id: 'dating',
    name: 'Sparks',
    icon: { bg: `linear-gradient(160deg,#ff6a3d,${SPARKS_PINK} 55%,#c2185b)`, glyph: 'fa-solid fa-fire-flame-curved', size: 30 },
    // a message from the person you're chatting with doesn't need a banner
    suppress: (n) => !!(n.data && n.data.match && SparksChat._open === n.data.match),
    open(root, _p, app) {
        app.on('datingMessage', (m) => SparksChat._live && SparksChat._live(m));
        const tabs = TabBar(root, [
            {
                id: 'discover', label: 'Discover', icon: 'fa-solid fa-fire-flame-curved',
                render(host) {
                    host.innerHTML = `<div class="sp-top"><i class="fa-solid fa-fire-flame-curved"></i>sparks</div><div class="sp-deck"></div>
                        <div class="sp-actions"><button class="sp-round nope" data-act="nope"><i class="fa-solid fa-xmark"></i></button><button class="sp-round like" data-act="like"><i class="fa-solid fa-heart"></i></button></div>`;
                    const deck = $('.sp-deck', host);
                    let cards = [];
                    const drawDeck = () => {
                        if (!cards.length) {
                            deck.innerHTML = UI.empty('fa-solid fa-fire-flame-curved', 'No one new nearby', 'Check back later — new people join every day.');
                            $('.sp-actions', host).style.visibility = 'hidden';
                            return;
                        }
                        $('.sp-actions', host).style.visibility = '';
                        deck.innerHTML = cards.slice(0, 3).reverse().map(sparksCardHtml).join('');
                        const top = deck.lastElementChild;
                        drag(top, {
                            onMove: (dx, dy) => {
                                top.style.transition = 'none';
                                top.style.transform = `translate(${dx}px,${dy * 0.3}px) rotate(${dx / 18}deg)`;
                                $('.sp-stamp.like', top).style.opacity = Math.max(0, Math.min(1, dx / 90));
                                $('.sp-stamp.nope', top).style.opacity = Math.max(0, Math.min(1, -dx / 90));
                            },
                            onEnd: (dx, _dy, _vy, vx, e, moved) => {
                                top.style.transition = '';
                                if (dx > 100 || (vx || 0) > 0.8) return swipe(true);
                                if (dx < -100 || (vx || 0) < -0.8) return swipe(false);
                                top.style.transform = '';
                                $$('.sp-stamp', top).forEach((s) => { s.style.opacity = 0; });
                                if (!moved) nextPhoto(top, e);
                            },
                        });
                    };
                    const nextPhoto = (c, e) => {
                        const p = cards[0];
                        const n = (p.photos || []).length;
                        if (n < 2) return;
                        const r = c.getBoundingClientRect();
                        const x = (e && (e.clientX ?? (e.changedTouches && e.changedTouches[0].clientX))) || r.right;
                        let i = +c.dataset.photo + (x < r.left + r.width / 2 ? -1 : 1);
                        i = (i + n) % n;
                        c.dataset.photo = i;
                        c.style.cssText += ';' + sparksPhoto(p, i);
                        $$('.sp-dots i', c).forEach((d, k) => d.classList.toggle('on', k === i));
                    };
                    const swipe = async (like) => {
                        const p = cards.shift();
                        const top = deck.lastElementChild;
                        if (top) { top.style.transform = `translate(${like ? 500 : -500}px,40px) rotate(${like ? 30 : -30}deg)`; top.style.opacity = '0'; }
                        setTimeout(drawDeck, 220);
                        if (!p) return;
                        const r = await rpc('datingSwipe', { id: p.id, like });
                        if (r && r.match) {
                            SparksMatchCelebration(root, r.match, (m) => { tabs.select('matches'); setTimeout(() => app.openChat && app.openChat(m), 50); });
                            app.reloadMatches && app.reloadMatches();
                        }
                        if (cards.length < 3) load(true);
                    };
                    const load = async (more) => {
                        const d = await rpc('datingDeck');
                        if (!d || d.__carrier) { deck.innerHTML = UI.empty('fa-solid fa-signal', 'No connection', 'Sparks needs mobile data.'); return; }
                        if (d.needProfile) {
                            $('.sp-actions', host).style.visibility = 'hidden';
                            deck.innerHTML = `<div class="sp-welcome"><i class="fa-solid fa-fire-flame-curved"></i><b>Welcome to Sparks</b><p>Make a profile to start meeting people in Los Santos.</p><button class="sp-btn primary" data-act="create">Create profile</button></div>`;
                            return;
                        }
                        const seen = new Set(cards.map((c) => c.id));
                        cards = more ? [...cards, ...(d.cards || []).filter((c) => !seen.has(c.id))] : (d.cards || []);
                        if (!more || deck.children.length < 2) drawDeck();
                        if (d.active === false) UI.toast('You are hidden — turn “Show me on Sparks” on in your profile', 'fa-solid fa-eye-slash');
                    };
                    host.addEventListener('click', (e) => {
                        const a = e.target.closest('[data-act]');
                        if (!a) return;
                        if (a.dataset.act === 'create') return SparksEditor(() => load());
                        if (!cards.length) return;
                        if (a.dataset.act === 'like' || a.dataset.act === 'nope') swipe(a.dataset.act === 'like');
                    });
                    app.reloadDeck = () => load();
                    load();
                },
            },
            {
                id: 'matches', label: 'Matches', icon: 'fa-solid fa-comments',
                render(host) {
                    const nav = new Nav(host);
                    host._nav = nav;
                    nav.push({
                        title: 'Matches',
                        large: true,
                        noBack: true,
                        render(content, ctx) {
                            const load = async () => {
                                const d = await rpc('datingMatches');
                                if (!d || d.__carrier) { content.innerHTML = UI.empty('fa-solid fa-signal', 'No connection', ''); return; }
                                const ms = d.matches || [];
                                const fresh = ms.filter((m) => m.new), talking = ms.filter((m) => !m.new);
                                tabs.badge('matches', ms.reduce((n, m) => n + (m.unread || 0), 0) || (fresh.length || 0));
                                content.innerHTML = !ms.length ? UI.empty('fa-solid fa-heart', 'No matches yet', 'Like people in Discover — when they like you back, they show up here.')
                                    : `${fresh.length ? `<div class="group-header">New matches</div><div class="sp-new">${fresh.map((m) => `<button data-m="${m.id}"><span style="${sparksPhoto(m.profile)}"></span><b>${esc(m.profile.name)}</b></button>`).join('')}</div>` : ''}
                                       ${talking.length ? `<div class="group-header">Messages</div><div class="group">${talking.map((m) => `
                                        <div class="row tap sp-row" data-m="${m.id}"><span class="sp-av" style="${sparksPhoto(m.profile)}"></span>
                                            <div class="grow"><b>${esc(m.profile.name)}</b><div class="muted sp-last">${m.lastMine ? 'You: ' : ''}${esc(m.last || '')}</div></div>
                                            <div class="sp-when">${esc(shortAgo(m.at * 1000))}${m.unread ? `<span class="sp-unread">${m.unread}</span>` : ''}</div></div>`).join('')}</div>` : ''}`;
                                content._ms = ms;
                            };
                            const open = (m) => { SparksChat._open = m.id; SparksChat(nav, m, load); };
                            app.openChat = open;
                            content.addEventListener('click', (e) => {
                                const r = e.target.closest('[data-m]');
                                if (!r) return;
                                const m = (content._ms || []).find((x) => String(x.id) === r.dataset.m);
                                if (m) open(m);
                            });
                            ctx.opts.onResume = () => { SparksChat._open = null; load(); };
                            app.reloadMatches = load;
                            app.on('datingChanged', load);
                            app.on('datingMessage', () => { if (nav.stack.length === 1) load(); });
                            load();
                        },
                    });
                },
            },
            {
                id: 'me', label: 'Profile', icon: 'fa-solid fa-user',
                render(host) {
                    const load = async () => {
                        const d = await rpc('datingProfile');
                        const p = d && d.profile;
                        host.innerHTML = `<div class="sp-me">${p ? `<div class="sp-card static" style="${sparksPhoto(p)}">${(p.photos || []).length ? '' : `<div class="sp-noimg">${esc(p.name[0])}</div>`}
                            <div class="sp-info"><div class="sp-name">${esc(p.name)} <span>${esc(String(p.age))}</span></div>${p.bio ? `<div class="sp-bio">${esc(p.bio)}</div>` : ''}</div></div>
                            ${d.active === false ? '<div class="sp-hidden"><i class="fa-solid fa-eye-slash"></i> Hidden from Discover</div>' : ''}`
                            : '<div class="sp-welcome"><i class="fa-solid fa-user"></i><b>No profile yet</b><p>Create one to appear in Discover.</p></div>'}
                            <button class="sp-btn primary" data-act="edit">${p ? 'Edit profile' : 'Create profile'}</button></div>`;
                    };
                    host.addEventListener('click', (e) => { if (e.target.closest('[data-act=edit]')) SparksEditor(() => { load(); app.reloadDeck && app.reloadDeck(); }); });
                    load();
                },
            },
        ]);
        app.tabs = tabs;
    },
});
