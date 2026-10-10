'use strict';

function chirpPostHtml(p, detail = false) {
    return `
        <div class="chirp-post ${detail ? 'detail' : ''}" data-post="${p.id}">
            <span class="cp-av" data-user="${esc(p.handle)}">${avatar(p.display_name, p.avatar)}</span>
            <div class="cp-main">
                <div class="cp-head"><b data-user="${esc(p.handle)}">${esc(p.display_name)}</b><span>@${esc(p.handle)} · ${esc(shortAgo(p.created_at))}</span>
                    ${p.mine ? `<button class="cp-more" data-del="${p.id}"><i class="fa-solid fa-ellipsis"></i></button>` : ''}</div>
                <div class="cp-text">${esc(p.content).replace(/(^|\s)([#@]\w+)/g, '$1<span class="cp-tag">$2</span>')}</div>
                ${p.image ? `<img class="cp-img" src="${escUrl(p.image)}" data-img="${escUrl(p.image)}">` : ''}
                <div class="cp-actions">
                    <button data-reply="${p.id}"><i class="fa-regular fa-comment"></i>${p.replies || ''}</button>
                    <button data-like="${p.id}" class="${p.liked ? 'liked' : ''}"><i class="fa-${p.liked ? 'solid' : 'regular'} fa-heart"></i><span>${p.likes || ''}</span></button>
                    <button data-share="${p.id}"><i class="fa-solid fa-arrow-up-from-bracket"></i></button>
                </div>
            </div>
        </div>`;
}

function ChirpCompose(replyTo, onDone) {
    let image = null;
    UI.sheet({
        title: '',
        right: replyTo ? 'Reply' : 'Post',
        render(body, api) {
            body.innerHTML = `
                <div class="chirp-compose">
                    ${avatar(Phone.profile?.name)}
                    <div style="flex:1">
                        ${replyTo ? `<div class="muted" style="font-size:14px;margin-bottom:6px">Replying to <span class="tint">@${esc(replyTo.handle)}</span></div>` : ''}
                        <textarea maxlength="280" placeholder="${replyTo ? 'Post your reply' : "What's happening?"}"></textarea>
                        <div class="cc-img"></div>
                    </div>
                </div>
                <div class="chirp-compose-bar"><button class="tint" data-act="img"><i class="fa-regular fa-image"></i></button><button class="tint" data-act="photos"><i class="fa-solid fa-photo-film"></i></button><span class="cc-count">280</span></div>`;
            const ta = $('textarea', body);
            const check = () => { $('.cc-count', body).textContent = 280 - ta.value.length; api.setRightEnabled(ta.value.trim().length > 0); };
            ta.addEventListener('input', check);
            check();
            setTimeout(() => ta.focus(), 350);
            body.addEventListener('click', async (e) => {
                const a = e.target.closest('[data-act]');
                if (!a) return;
                const url = a.dataset.act === 'photos' ? await pickPhoto() : await UI.prompt('Add Image', 'Paste an image URL', { placeholder: 'https://' });
                if (url && /^https?:\/\//.test(url)) { image = url; $('.cc-img', body).innerHTML = `<img src="${escUrl(url)}">`; }
            });
        },
        async onRight(api) {
            const content = $('textarea', api.body).value.trim();
            api.setRightEnabled(false);
            const id = await rpc('chirpPost', { content, image, replyTo: replyTo && replyTo.id });
            if (!id) { api.setRightEnabled(true); return UI.alert({ title: "Couldn't post" }); }
            Sound.play('sent');
            api.close();
            onDone && onDone();
        },
    });
}

function ChirpProfile(onSaved) {
    rpc('chirpProfile').then((p) => {
        if (!p) return;
        UI.sheet({
            title: 'Edit Profile',
            right: 'Save',
            render(body) {
                body.innerHTML = `
                    <div style="display:flex;justify-content:center;padding:10px 0 20px">${avatar(p.display_name, p.avatar, 'xl')}</div>
                    <div class="group">
                        <div class="row"><span class="lbl">Name</span><input class="field" data-f="display_name" value="${esc(p.display_name)}"></div>
                        <div class="row"><span class="lbl">Handle</span><input class="field" data-f="handle" value="${esc(p.handle)}"></div>
                        <div class="row"><span class="lbl">Bio</span><input class="field" data-f="bio" value="${esc(p.bio || '')}" placeholder="Add a bio"></div>
                        <div class="row"><span class="lbl">Avatar</span><input class="field" data-f="avatar" value="${esc(p.avatar || '')}" placeholder="https://"></div>
                    </div>`;
            },
            async onRight(api) {
                const v = (f) => $(`[data-f=${f}]`, api.body).value.trim();
                const res = await rpc('chirpUpdateProfile', { display_name: v('display_name'), handle: v('handle'), bio: v('bio'), avatar: v('avatar') });
                if (!res || res.error) return UI.alert({ title: (res && res.error) || 'Could not save' });
                api.close();
                onSaved && onSaved();
            },
        });
    });
}

Apps.register({
    id: 'chirp',
    name: 'Chirp',
    icon: { bg: 'linear-gradient(180deg,#3cb2ff,#1d8cf0)', glyph: 'fa-solid fa-feather-pointed', size: 30 },
    open(root, _p, app) {
        const nav = new Nav(root);
        root.insertAdjacentHTML('beforeend', '<button class="chirp-fab" data-act="compose"><i class="fa-solid fa-plus"></i></button>');
        let posts = [];

        const handleClick = async (e, reload) => {
            const user = e.target.closest('[data-user]');
            if (user) { openUser(user.dataset.user); return true; }
            const like = e.target.closest('[data-like]');
            if (like) {
                const liked = await rpc('chirpLike', { id: +like.dataset.like });
                like.classList.toggle('liked', liked);
                $('i', like).className = `fa-${liked ? 'solid' : 'regular'} fa-heart`;
                const n = $('span', like);
                n.textContent = Math.max(0, (+n.textContent || 0) + (liked ? 1 : -1)) || '';
                return true;
            }
            const del = e.target.closest('[data-del]');
            if (del) {
                const i = await UI.actionSheet(null, [{ label: 'Delete Post', destructive: true }]);
                if (i === 0 && (await rpc('chirpDelete', { id: +del.dataset.del }))) reload();
                return true;
            }
            const rep = e.target.closest('[data-reply]');
            if (rep) { const p = posts.find((x) => x.id === +rep.dataset.reply) || {}; ChirpCompose(p, reload); return true; }
            const share = e.target.closest('[data-share]');
            if (share) {
                const p = posts.find((x) => x.id === +share.dataset.share);
                const c = await pickContact('Share Post');
                if (c && p) { await rpc('sendMessage', { number: c.number, message: `@${p.handle}: ${p.content}` }); UI.toast('Shared'); }
                return true;
            }
            const img = e.target.closest('[data-img]');
            if (img) { PhotoViewer(img.dataset.img); return true; }
            return false;
        };

        const openPost = (post) => {
            nav.push({
                title: 'Post',
                solidBar: true,
                render(content) {
                    const load = async () => {
                        const replies = (await rpc('chirpFeed', { replyTo: post.id })) || [];
                        posts = [post, ...replies, ...posts.filter((p) => p.id !== post.id)];
                        content.innerHTML = chirpPostHtml(post, true) + `<div class="chirp-replies">${replies.map((r) => chirpPostHtml(r)).join('') || '<div class="muted" style="padding:30px;text-align:center">No replies yet</div>'}</div>`;
                    };
                    content.addEventListener('click', (e) => handleClick(e, load));
                    load();
                },
            });
        };

        // someone's profile: bio, counts, follow button and their posts
        const openUser = (handle) => {
            nav.push({
                title: '@' + handle,
                solidBar: true,
                render(content) {
                    const load = async () => {
                        const [u, list] = await Promise.all([rpc('chirpUser', { handle }), rpc('chirpFeed', { handle })]);
                        if (!u) { content.innerHTML = UI.empty('fa-solid fa-user-slash', 'Account not found', ''); return; }
                        posts = [...(list || []), ...posts];
                        content.innerHTML = `
                            <div class="chirp-user">
                                <div class="cu-top">${avatar(u.display_name, u.avatar, 'xl')}
                                    ${u.mine ? '<button class="cu-btn" data-act="editprofile">Edit Profile</button>'
                                        : `<button class="cu-btn ${u.followed ? '' : 'primary'}" data-act="follow">${u.followed ? 'Following' : 'Follow'}</button>`}</div>
                                <div class="cu-name">${esc(u.display_name)}</div>
                                <div class="cu-handle">@${esc(u.handle)}</div>
                                ${u.bio ? `<div class="cu-bio" data-no-i18n>${esc(u.bio)}</div>` : ''}
                                <div class="cu-counts"><span><b>${u.following || 0}</b> Following</span><span><b>${u.followers || 0}</b> Followers</span></div>
                            </div>
                            <div class="chirp-feed">${(list || []).map((p) => chirpPostHtml(p)).join('') || '<div class="muted" style="padding:30px;text-align:center">No posts yet</div>'}</div>`;
                    };
                    let busy = false;
                    content.addEventListener('click', async (e) => {
                        const a = e.target.closest('[data-act]');
                        if (a && a.dataset.act === 'editprofile') return ChirpProfile(load);
                        if (a && a.dataset.act === 'follow') {
                            if (busy) return;
                            busy = true;
                            const r = await rpc('chirpFollow', { handle });
                            busy = false;
                            if (!r || r.error) return UI.alert({ title: (r && r.error) || "Couldn't follow" });
                            return load();
                        }
                        const u = e.target.closest('[data-user]');
                        if (u && u.dataset.user === handle) return; // already here
                        if (await handleClick(e, load)) return;
                        const p = e.target.closest('[data-post]');
                        if (p) openPost(posts.find((x) => x.id === +p.dataset.post));
                    });
                    load();
                },
            });
        };

        nav.push({
            title: 'Chirp',
            solidBar: true,
            noBack: true,
            left: '<button class="nav-btn" data-act="profile" style="padding-left:8px">' + avatar(Phone.profile?.name, null, 'sm') + '</button>',
            right: '<button class="nav-btn" data-act="refresh"><i class="fa-solid fa-rotate-right"></i></button>',
            render(content, ctx) {
                $('.nav-title', ctx.page).innerHTML = '<i class="fa-solid fa-feather-pointed" style="color:#1d9bf0;font-size:22px"></i>';
                content.innerHTML = `<div class="segmented chirp-tabs"><button class="on" data-tab="all">For You</button><button data-tab="following">Following</button></div><div class="chirp-feed"><div class="spinner"></div></div>`;
                const feed = $('.chirp-feed', content);
                let tab = 'all', seq = 0;
                const load = async () => {
                    const mySeq = ++seq, following = tab === 'following';
                    const list = (await rpc('chirpFeed', following ? { following: true } : {})) || [];
                    if (mySeq !== seq) return; // switched tab while loading
                    posts = list;
                    feed.innerHTML = posts.length ? posts.map((p) => chirpPostHtml(p)).join('')
                        : following ? UI.empty('fa-solid fa-user-plus', 'Nobody here yet', 'Tap someone’s name to see their profile and follow them.')
                        : UI.empty('fa-solid fa-feather-pointed', 'Welcome to Chirp', 'Be the first to post something.');
                };
                content.addEventListener('click', async (e) => {
                    const t = e.target.closest('[data-tab]');
                    if (t) {
                        if (t.dataset.tab === tab) return;
                        tab = t.dataset.tab;
                        $$('[data-tab]', content).forEach((b) => b.classList.toggle('on', b === t));
                        feed.innerHTML = '<div class="spinner"></div>';
                        return load();
                    }
                    if (await handleClick(e, load)) return;
                    const p = e.target.closest('[data-post]');
                    if (p) openPost(posts.find((x) => x.id === +p.dataset.post));
                });
                ctx.page.addEventListener('click', (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'refresh') load();
                    if (a.dataset.act === 'profile') ChirpProfile(load);
                });
                ctx.opts.onResume = load;
                app.reload = load;
                load();
            },
        });
        $('.chirp-fab', root).onclick = () => ChirpCompose(null, () => app.reload && app.reload());
        app.on('chirpRefresh', () => app.reload && nav.stack.length === 1 && app.reload());
    },
});
