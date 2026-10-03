'use strict';

/** Full-screen photo viewer. photo = url string or { id, url, favorite } */
function PhotoViewer(photo, { onChange, list } = {}) {
    let p = typeof photo === 'string' ? { url: photo } : photo;
    const v = el(`
        <div class="photo-viewer">
            <div class="pv-top">
                <button class="nav-btn" data-act="close"><i class="fa-solid fa-chevron-left"></i></button>
                <div class="pv-date">${p.created_at ? `<b>${esc(relTime(p.created_at))}</b><span>${esc(fmtTime(p.created_at))}</span>` : ''}</div>
                <span style="width:40px"></span>
            </div>
            ${pvMedia(p.url)}
            ${p.id ? `<div class="pv-bar">
                <button class="nav-btn" data-act="share"><i class="fa-solid fa-arrow-up-from-bracket"></i></button>
                <button class="nav-btn" data-act="fav"><i class="fa-${p.favorite ? 'solid' : 'regular'} fa-heart"></i></button>
                ${isVideoUrl(p.url) ? '' : '<button class="nav-btn" data-act="wallpaper"><i class="fa-solid fa-mobile-screen"></i></button>'}
                <button class="nav-btn" data-act="delete"><i class="fa-regular fa-trash-can"></i></button>
            </div>` : ''}
        </div>`);
    $('#overlay-layer').appendChild(v);
    requestAnimationFrame(() => v.classList.add('show'));
    const close = () => { v.classList.remove('show'); setTimeout(() => v.remove(), 300); };
    v.addEventListener('click', async (e) => {
        const a = e.target.closest('[data-act]');
        if (!a) return;
        switch (a.dataset.act) {
            case 'close': close(); break;
            case 'fav':
                await rpc('favoritePhoto', { id: p.id });
                p.favorite = p.favorite ? 0 : 1;
                $('i', a).className = `fa-${p.favorite ? 'solid' : 'regular'} fa-heart`;
                onChange && onChange();
                break;
            case 'wallpaper':
                Phone.saveSetting('wallpaper', p.url);
                UI.toast('Wallpaper set', 'fa-solid fa-image');
                break;
            case 'share': {
                const c = await pickContact('Send to');
                if (c) {
                    // messages show images inline; a video is sent as its link
                    if (isVideoUrl(p.url)) await rpc('sendMessage', { number: c.number, message: p.url });
                    else await rpc('sendMessage', { number: c.number, message: '', attachment: { type: 'image', url: p.url } });
                    UI.toast('Sent to ' + c.name);
                }
                break;
            }
            case 'delete':
                if (await UI.confirm(isVideoUrl(p.url) ? 'Delete Video' : 'Delete Photo', 'This will be deleted from your library.', isVideoUrl(p.url) ? 'Delete Video' : 'Delete Photo', true)) {
                    await rpc('deletePhoto', { id: p.id });
                    close();
                    onChange && onChange();
                }
                break;
        }
    });
    let img = $('.pv-media', v);
    const show = (np) => {
        p = np;
        const next = el(pvMedia(p.url));
        img.replaceWith(next);
        img = next;
        const fav = $('[data-act=fav] i', v);
        if (fav) fav.className = `fa-${p.favorite ? 'solid' : 'regular'} fa-heart`;
        const date = $('.pv-date', v);
        if (date && p.created_at) date.innerHTML = `<b>${esc(relTime(p.created_at))}</b><span>${esc(fmtTime(p.created_at))}</span>`;
    };
    drag(v, {
        onStart: (e) => !e.target.closest('.pv-bar, .pv-top'),
        onMove: (dx, dy) => {
            if (list && Math.abs(dx) > Math.abs(dy)) { img.style.transition = 'none'; img.style.transform = `translateX(${dx}px)`; }
            else if (dy > 0) { img.style.transition = 'none'; img.style.transform = `translateY(${dy}px) scale(${Math.max(0.75, 1 - dy / 900)})`; }
        },
        onEnd: (dx, dy, vy, vx, _e, moved) => {
            img.style.transition = '';
            img.style.transform = '';
            if (!moved) return;
            if (list && Math.abs(dx) > Math.abs(dy) && (Math.abs(dx) > 80 || Math.abs(vx) > 0.5)) {
                const i = list.findIndex((x) => x.id === p.id);
                const next = list[i + (dx < 0 ? 1 : -1)];
                if (next) show(next);
                return;
            }
            if (dy > 100 || vy > 0.6) close();
        },
    });
}

function pvMedia(url) {
    return isVideoUrl(url)
        ? `<video class="pv-media" src="${escUrl(url)}" controls autoplay loop playsinline></video>`
        : `<img class="pv-media" src="${escUrl(url)}">`;
}

function photoCount(items) {
    const v = items.filter((p) => isVideoUrl(p.url)).length, ph = items.length - v;
    return [ph ? `${ph} ${I18N.t(ph === 1 ? 'Photo' : 'Photos')}` : '', v ? `${v} ${I18N.t(v === 1 ? 'Video' : 'Videos')}` : ''].filter(Boolean).join(', ');
}

/** grid cell for a photo or video */
function photoCell(p, attrs) {
    if (isVideoUrl(p.url)) {
        return `<div class="pg-item is-video" ${attrs}><video src="${escUrl(p.url)}#t=0.1" muted preload="metadata"></video><span class="pg-dur"><i class="fa-solid fa-video"></i></span>${p.favorite ? '<i class="fa-solid fa-heart"></i>' : ''}</div>`;
    }
    return `<div class="pg-item" ${attrs} style="background-image:url('${escUrl(p.url)}')">${p.favorite ? '<i class="fa-solid fa-heart"></i>' : ''}</div>`;
}

/** Sheet to pick a photo from the library. Resolves with url or null. */
function pickPhoto() {
    return new Promise(async (resolve) => {
        let picked = null;
        const photos = (await rpc('getPhotos')) || [];
        UI.sheet({
            title: 'Photos',
            onClose: () => resolve(picked),
            render(body, api) {
                body.innerHTML = photos.length
                    ? `<div class="photo-grid">${photos.filter((p) => !isVideoUrl(p.url)).map((p) => photoCell({ url: p.url }, `data-url="${escUrl(p.url)}"`)).join('')}</div>`
                    : UI.empty('fa-regular fa-images', 'No Photos', '');
                body.addEventListener('click', (e) => {
                    const it = e.target.closest('[data-url]');
                    if (it) { picked = it.dataset.url; api.close(); }
                });
            },
        });
    });
}

Apps.register({
    id: 'photos',
    name: 'Photos',
    icon: {
        bg: '#fff',
        html: () => `<svg viewBox="0 0 64 64" width="54" height="54">${['#f9c80e', '#f86624', '#ea3546', '#b0479b', '#662e9b', '#2b6fdc', '#43bccd', '#7ac74f'].map((c, i) =>
            `<ellipse cx="32" cy="18" rx="7.5" ry="13" fill="${c}" opacity=".88" transform="rotate(${i * 45} 32 32)" style="mix-blend-mode:multiply"/>`).join('')}</svg>`,
    },
    open(root) {
        const nav = new Nav(root);
        let photos = [];
        let filter = 'all';
        nav.push({
            title: 'Library',
            large: true,
            right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
            render(content, ctx) {
                content.innerHTML = `<div class="segmented" style="margin:0 16px 12px"><button data-f="all" class="on">All Photos</button><button data-f="fav">Favourites</button></div><div class="p-host"><div class="spinner"></div></div>`;
                const host = $('.p-host', content);
                const draw = () => {
                    const items = photos.filter((p) => filter === 'all' || p.favorite);
                    host.innerHTML = items.length
                        ? `<div class="photo-grid">${items.map((p) => photoCell(p, `data-id="${p.id}"`)).join('')}</div>
                           <div class="muted" style="text-align:center;padding:14px;font-size:15px">${photoCount(items)}</div>`
                        : UI.empty('fa-regular fa-images', 'No Photos', 'Take photos with the Camera or add one from a URL.');
                };
                const load = async () => { photos = (await rpc('getPhotos')) || []; draw(); };
                content.addEventListener('click', (e) => {
                    const seg = e.target.closest('[data-f]');
                    if (seg) {
                        filter = seg.dataset.f;
                        $$('[data-f]', content).forEach((b) => b.classList.toggle('on', b === seg));
                        return draw();
                    }
                    const it = e.target.closest('[data-id]');
                    if (it) PhotoViewer(photos.find((p) => p.id === +it.dataset.id), { onChange: load, list: photos.filter((p) => filter === 'all' || p.favorite) });
                });
                $('[data-act=add]', ctx.page).onclick = async () => {
                    const url = await UI.prompt('Add Photo', 'Paste an image URL', { placeholder: 'https://' });
                    if (url && (await rpc('savePhoto', { url }))) load();
                };
                ctx.opts.onResume = load;
                load();
            },
        });
    },
});
