'use strict';

/* =====================================================================
   System gestures (OPS OS)
   - home bar: swipe up = home, swipe up & hold = app switcher,
     swipe sideways = previous / next app
   - app switcher: live cards, tap to open, swipe a card up to quit
   - status bar: swipe down left = Notification Centre, right = Control
     Centre, tap = scroll to top
   - home screen: swipe down = Search, long-press = quick actions,
     keep holding / "Edit Home Screen" = jiggle, drag icons to rearrange
   - lock screen: swipe left = Camera
   - lists: swipe a row left to reveal Delete (swipeRows helper)
   ===================================================================== */

/* ---------------------------------------------------------------------
   home bar
   --------------------------------------------------------------------- */

function setupHomeIndicator() {
    const ind = $('#home-indicator');
    let win = null, holdTimer = null, switcherArmed = false, lastMoveAt = 0, horizontal = false;

    drag(ind, {
        threshold: 3,
        onStart: () => {
            if (Phone.locked || Phone.needsSetup) return true;
            win = Phone.current ? Phone.current.win : null;
            switcherArmed = false; horizontal = false;
            return true;
        },
        onMove: (dx, dy) => {
            if (Phone.locked || Phone.needsSetup) return;
            if (!horizontal && Math.abs(dx) > 24 && Math.abs(dx) > Math.abs(dy) * 1.4 && dy > -30) horizontal = true;
            if (horizontal) {
                if (win) { win.style.transition = 'none'; win.style.transform = `translateX(${dx * 0.9}px)`; }
                return;
            }
            if (dy > 0) return;
            lastMoveAt = performance.now();
            const k = Math.max(0.5, 1 + dy / 700);
            if (win) {
                win.style.transition = 'none';
                win.style.transform = `translate(${dx * 0.5}px, ${dy * 0.45}px) scale(${k})`;
                win.style.transformOrigin = '50% 100%';
                win.style.borderRadius = '48px';
            }
            // pausing mid-swipe arms the app switcher (like a real phone)
            clearTimeout(holdTimer);
            if (dy < -90) {
                holdTimer = setTimeout(() => {
                    if (performance.now() - lastMoveAt >= 180 && !switcherArmed) { switcherArmed = true; Phone.vibrate && Sound.play('key', 1); }
                }, 200);
            }
        },
        onEnd: (dx, dy, vy, vx, _e, moved) => {
            clearTimeout(holdTimer);
            if (Phone.locked || Phone.needsSetup) { if (!moved || dy < -40) goHome(); return; }
            if (horizontal) {
                if (win) { win.style.transition = ''; win.style.transform = ''; }
                if (Math.abs(dx) > 70 || Math.abs(vx) > 0.5) quickSwitch(dx > 0 ? 1 : -1);
                return;
            }
            if (switcherArmed) return Switcher.open();
            if (win) {
                win.style.transition = '';
                win.style.transformOrigin = '';
                if (moved && dy > -80 && vy > -0.5) { win.style.transform = ''; win.style.borderRadius = ''; return; }
            }
            goHome();
        },
    });
}

/** swipe sideways on the home bar: jump to the previous/next recent app */
function quickSwitch(dir) {
    const list = Phone.recents.filter((id) => Apps.byId[id] && Phone.isInstalled(id));
    if (!list.length) return;
    const cur = Phone.current && Phone.current.def.id;
    let target;
    if (!cur) target = list[0];
    else {
        const i = list.indexOf(cur);
        target = dir > 0 ? list[i + 1] : list[(i - 1 + list.length) % list.length];
    }
    if (!target || target === cur) return;
    const prev = Phone.current;
    if (prev) {
        // slide the current app out, the next one in
        const w = prev.win;
        w.style.transition = 'transform .35s var(--ease-spring)';
        w.style.transform = `translateX(${dir > 0 ? 393 : -393}px)`;
    }
    setTimeout(() => {
        const keepRecents = Phone.recents.slice();
        Phone.openApp(target, {}, null);
        Phone.recents = [target, ...keepRecents.filter((x) => x !== target)]; // keep order stable for repeated swipes
        const nw = Phone.current && Phone.current.win;
        if (nw) {
            nw.style.transition = 'none';
            nw.style.transform = `translateX(${dir > 0 ? -393 : 393}px)`;
            nw.getBoundingClientRect();
            nw.style.transition = 'transform .38s var(--ease-spring)';
            nw.style.transform = '';
            setTimeout(() => { nw.style.transition = ''; }, 400);
        }
    }, 120);
}

/* ---------------------------------------------------------------------
   app switcher
   --------------------------------------------------------------------- */

const Switcher = {
    el: null,
    open() {
        if (this.el) return;
        // the current app joins the suspended set while the switcher is up
        const curId = Phone.current && Phone.current.def.id;
        if (Phone.current) closeApp(true);
        const ids = Phone.recents.filter((id) => Apps.byId[id] && Phone.isInstalled(id));
        const sw = el(`<div class="switcher"><div class="sw-strip"></div><div class="sw-empty ${ids.length ? 'hidden' : ''}">${esc(I18N.t('No Recent Apps'))}</div></div>`);
        this.el = sw;
        $('#screen').appendChild(sw);
        screenEl().classList.add('switcher-open');
        const strip = $('.sw-strip', sw);
        ids.forEach((id) => {
            const def = Apps.byId[id];
            const card = el(`
                <div class="sw-card" data-id="${id}">
                    <div class="sw-label">${iconScaled(def, 30)}<span>${esc(def.label || def.name)}</span></div>
                    <div class="sw-shot"><div class="sw-live"></div></div>
                </div>`);
            const live = $('.sw-live', card);
            const sus = Phone.suspended.get(id);
            if (sus) live.appendChild(sus.win);
            else live.innerHTML = `<div class="sw-splash" style="background:${def.splash || 'var(--bg)'}">${iconScaled(def, 90)}</div>`;
            strip.appendChild(card);
            this.bindCard(card);
        });
        // scroll so the app you came from is centred
        requestAnimationFrame(() => {
            sw.classList.add('show');
            const c = curId && $(`.sw-card[data-id="${curId}"]`, strip);
            if (c) strip.scrollLeft = c.offsetLeft - (393 - c.offsetWidth) / 2;
        });
        sw.addEventListener('click', (e) => { if (!e.target.closest('.sw-card')) this.close(); });
        updateChrome();
    },

    bindCard(card) {
        const shot = $('.sw-shot', card);
        let startScroll = 0;
        const strip = () => $('.sw-strip', this.el);
        drag(card, {
            threshold: 5,
            onStart: () => { startScroll = strip().scrollLeft; return true; },
            onMove: (dx, dy) => {
                if (Math.abs(dy) > Math.abs(dx) && dy < 0) {
                    shot.style.transition = 'none';
                    shot.style.transform = `translateY(${dy}px)`;
                    shot.style.opacity = String(1 + dy / 500);
                } else {
                    strip().scrollLeft = startScroll - dx;
                }
            },
            onEnd: (dx, dy, vy, _vx, _e, moved) => {
                shot.style.transition = '';
                if (!moved) return this.launch(card);
                if (dy < -140 || (vy < -0.8 && dy < -40)) return this.quit(card);
                shot.style.transform = ''; shot.style.opacity = '';
            },
        });
    },

    quit(card) {
        const id = card.dataset.id;
        const shot = $('.sw-shot', card);
        shot.style.transform = 'translateY(-900px)';
        shot.style.opacity = '0';
        setTimeout(() => {
            const sus = Phone.suspended.get(id);
            if (sus) $('#app-layer').appendChild(sus.win); // hand the window back before destroying it
            Phone.quitApp(id);
            card.classList.add('gone');
            setTimeout(() => {
                card.remove();
                if (!$('.sw-card', this.el)) $('.sw-empty', this.el).classList.remove('hidden');
            }, 260);
        }, 220);
    },

    launch(card) {
        const id = card.dataset.id;
        const rect = rectInScreen($('.sw-shot', card));
        const sus = Phone.suspended.get(id);
        this.teardown(id);
        if (sus) {
            Phone.suspended.delete(id);
            touchRecent(id);
            resumeWindow(sus, null, rect);
        } else {
            Phone.openApp(id, {}, $('.sw-shot', card));
        }
    },

    /** put every borrowed window back (suspended, detached) and remove the switcher */
    teardown(exceptId) {
        if (!this.el) return;
        $$('.sw-live > .app-window', this.el).forEach((w) => { if (!exceptId || !w.classList.contains('app-' + exceptId)) w.remove(); });
        const n = this.el;
        this.el = null;
        screenEl().classList.remove('switcher-open');
        n.classList.remove('show');
        setTimeout(() => n.remove(), 300);
        updateChrome();
    },
    close() { this.teardown(); },
};
Phone.Switcher = Switcher;

/* ---------------------------------------------------------------------
   status bar: swipe down for Notification / Control Centre, tap = top
   --------------------------------------------------------------------- */

function setupStatusGestures() {
    const bar = $('#statusbar');
    const scrollTop = () => {
        const cur = Phone.current;
        if (!cur) return;
        $$('.page-body, .scroll', cur.win).forEach((s) => {
            if (s.scrollTop > 0 && s.offsetParent !== null) s.scrollTo({ top: 0, behavior: 'smooth' });
        });
    };
    $$('[data-sb]', bar).forEach((zone) => {
        drag(zone, {
            threshold: 4,
            onStart: () => !Phone.needsSetup,
            onMove: () => {},
            onEnd: (_dx, dy, vy, _vx, _e, moved) => {
                if (!moved) return scrollTop();
                if (dy > 40 || vy > 0.5) {
                    if (zone.dataset.sb === 'right') toggleControlCenter(true);
                    else if (!Phone.locked) toggleNotifCenter(true);
                }
            },
        });
    });
}

/* ---------------------------------------------------------------------
   home screen: search, quick actions, jiggle + rearrange
   --------------------------------------------------------------------- */

const Spotlight = {
    el: null,
    open() {
        if (this.el || Phone.locked) return;
        const sp = el(`
            <div class="spotlight">
                <div class="spl-bar"><div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="${esc(I18N.t('Search'))}"></div><button class="nav-btn" data-act="cancel">${esc(I18N.t('Cancel'))}</button></div>
                <div class="spl-results scroll"></div>
            </div>`);
        this.el = sp;
        $('#screen').appendChild(sp);
        requestAnimationFrame(() => sp.classList.add('show'));
        const input = $('input', sp), out = $('.spl-results', sp);
        const draw = () => {
            const q = input.value.trim().toLowerCase();
            const apps = Apps.list.filter((a) => Phone.isInstalled(a.id) && (!q || (a.name + ' ' + (a.label || '')).toLowerCase().includes(q)));
            const people = q ? Contacts.cache.filter((c) => (c.name + c.number).toLowerCase().includes(q)).slice(0, 6) : [];
            out.innerHTML = `
                ${apps.length ? `<div class="spl-h">${esc(q ? I18N.t('Apps') : I18N.t('Siri Suggestions').replace('Siri ', ''))}</div>
                <div class="spl-apps">${apps.slice(0, q ? 8 : 8).map((a) => `<button class="spl-app" data-app="${a.id}">${iconScaled(a, 56)}<span>${esc(a.label || a.name)}</span></button>`).join('')}</div>` : ''}
                ${people.length ? `<div class="spl-h">${esc(I18N.t('Contacts'))}</div><div class="group">${people.map((c) => `
                    <div class="row tap" data-contact="${c.id}" style="--sep-left:64px">${avatar(c.name, c.avatar, 'sm')}<div class="grow"><div class="title">${esc(c.name)}</div><div class="sub">${esc(c.number)}</div></div>
                        <button class="spl-call" data-call="${esc(c.number)}"><i class="fa-solid fa-phone"></i></button></div>`).join('')}</div>` : ''}
                ${q && !apps.length && !people.length ? UI.empty('fa-solid fa-magnifying-glass', I18N.t('No Results'), '') : ''}`;
        };
        input.addEventListener('input', draw);
        sp.addEventListener('click', (e) => {
            const a = e.target.closest('[data-app]');
            if (a) { this.close(); return Phone.openApp(a.dataset.app); }
            const call = e.target.closest('[data-call]');
            if (call) { e.stopPropagation(); this.close(); return Call.start(call.dataset.call); }
            const c = e.target.closest('[data-contact]');
            if (c) { const ct = Contacts.cache.find((x) => x.id === +c.dataset.contact); this.close(); return ct && Phone.openApp('messages', { number: ct.number }); }
            if (e.target.closest('[data-act=cancel]') || e.target === sp) this.close();
        });
        drag(sp, { onStart: (e) => !e.target.closest('input, .spl-results'), onEnd: (_dx, dy, _vy, _vx, _e, moved) => { if (moved && dy < -50) this.close(); } });
        draw();
        setTimeout(() => input.focus(), 250);
    },
    close() {
        if (!this.el) return;
        const n = this.el;
        this.el = null;
        $('input', n).blur();
        n.classList.remove('show');
        setTimeout(() => n.remove(), 300);
    },
};
Phone.Spotlight = Spotlight;

/** quick-action menu shown on long-press (before jiggle mode) */
function showQuickActions(id, iconEl) {
    const def = Apps.byId[id];
    if (!def) return;
    closeQuickActions();
    const r = rectInScreen($('.icon', iconEl) || iconEl);
    const removable = !SYSTEM_APPS.has(id);
    const extra = (def.quickActions || []);
    const menu = el(`
        <div class="qa-layer">
            <div class="qa-menu" style="${r.y > 420 ? `bottom:${852 - r.y + 12}px` : `top:${r.y + r.h + 12}px`};${r.x > 200 ? `right:${393 - r.x - r.w}px` : `left:${r.x}px`}">
                ${extra.map((q, i) => `<button data-qa="x${i}"><span>${esc(I18N.t(q.label))}</span><i class="fa-solid ${q.icon}"></i></button>`).join('')}
                <button data-qa="edit"><span>${esc(I18N.t('Edit Home Screen'))}</span><i class="fa-solid fa-mobile-screen"></i></button>
                ${removable ? `<button data-qa="remove" class="danger"><span>${esc(I18N.t('Remove App'))}</span><i class="fa-solid fa-circle-minus"></i></button>` : ''}
            </div>
        </div>`);
    // the pressed icon floats above the blur
    const lifted = iconEl.cloneNode(true);
    lifted.classList.add('qa-icon');
    lifted.style.left = r.x + 'px';
    lifted.style.top = r.y + 'px';
    $$('.badge, .rm-badge', lifted).forEach((b) => b.remove());
    menu.appendChild(lifted);
    $('#screen').appendChild(menu);
    requestAnimationFrame(() => menu.classList.add('show'));
    menu.addEventListener('click', async (e) => {
        const b = e.target.closest('[data-qa]');
        closeQuickActions();
        if (!b) return;
        const a = b.dataset.qa;
        if (a === 'edit') return enterJiggle();
        if (a === 'remove') {
            const ok = await UI.alert({
                title: `${I18N.t('Remove')} “${def.label || def.name}”?`,
                message: I18N.t('You can reinstall it any time from the OPS OS Store.'),
                buttons: [{ label: I18N.t('Cancel'), value: false, style: 'cancel' }, { label: I18N.t('Remove App'), value: true, style: 'destructive' }],
            });
            if (ok) Phone.uninstallApp(id);
            return;
        }
        if (a[0] === 'x') { const q = extra[+a.slice(1)]; if (q) q.run(); }
    });
}
function closeQuickActions() {
    $$('.qa-layer').forEach((m) => { m.classList.remove('show'); setTimeout(() => m.remove(), 200); });

}

function enterJiggle() {
    closeQuickActions();
    const home = $('#home');
    if (home.classList.contains('jiggle')) return;
    home.classList.add('jiggle');
    Phone.vibrate && Phone.vibrate();
    if (!$('.jiggle-bar')) {
        const bar = el(`<div class="jiggle-bar"><button data-jb="add"><i class="fa-solid fa-plus"></i></button><button data-jb="done">${esc(I18N.t('Done'))}</button></div>`);
        home.appendChild(bar);
        bar.addEventListener('click', (e) => {
            const b = e.target.closest('[data-jb]');
            if (!b) return;
            e.stopPropagation();
            if (b.dataset.jb === 'done') exitJiggle();
            else { exitJiggle(); Phone.openApp('store'); }
        });
    }
}
function exitJiggle() {
    $('#home').classList.remove('jiggle');
    $$('.jiggle-bar').forEach((b) => b.remove());
}
Phone.enterJiggle = enterJiggle;
Phone.exitJiggle = exitJiggle;

/** drag icons around in jiggle mode; order is saved per phone */
function setupIconDrag() {
    const home = $('#home');
    let dragging = null; // { id, ghost, from }
    let edgeTimer = null;

    const pageIcons = () => $$('#home-pages .app-icon[data-app]');
    const currentOrder = () => HOME_LAYOUT.pages.flat().filter((x) => x[0] !== '@');   // widgets aren't apps

    home.addEventListener('pointerdown', (e) => {
        if (!home.classList.contains('jiggle')) return;
        const icon = e.target.closest('#home-pages .app-icon[data-app]');
        if (!icon || e.target.closest('.rm-badge')) return;
        e.stopPropagation();
        const sx = e.clientX, sy = e.clientY;
        let started = false;
        const move = (ev) => {
            const k = Phone.scale || 1;
            if (!started) {
                if (Math.hypot(ev.clientX - sx, ev.clientY - sy) / k < 6) return;
                started = true;
                const r = icon.getBoundingClientRect(), s = $('#screen').getBoundingClientRect();
                const ghost = icon.cloneNode(true);
                ghost.classList.add('icon-ghost');
                ghost.style.left = (r.left - s.left) / k + 'px';
                ghost.style.top = (r.top - s.top) / k + 'px';
                $('#screen').appendChild(ghost);
                icon.classList.add('icon-placeholder');
                dragging = { id: icon.dataset.app, ghost, ox: (sx - r.left) / k, oy: (sy - r.top) / k };
            }
            const s = $('#screen').getBoundingClientRect();
            const x = (ev.clientX - s.left) / k, y = (ev.clientY - s.top) / k;
            dragging.ghost.style.left = x - dragging.ox + 'px';
            dragging.ghost.style.top = y - dragging.oy + 'px';
            // hovering over another icon swaps them
            const over = pageIcons().find((i) => {
                if (i.dataset.app === dragging.id) return false;
                const r = i.getBoundingClientRect();
                return ev.clientX > r.left && ev.clientX < r.right && ev.clientY > r.top && ev.clientY < r.bottom;
            });
            if (over) {
                const order = currentOrder();
                const from = order.indexOf(dragging.id), to = order.indexOf(over.dataset.app);
                if (from >= 0 && to >= 0) {
                    order.splice(from, 1);
                    order.splice(to, 0, dragging.id);
                    Phone.settings.homeOrder = order;
                    renderHome();
                    $(`#home-pages .app-icon[data-app="${dragging.id}"]`).classList.add('icon-placeholder');
                }
            }
            // hold at the screen edge to move to the next / previous page
            clearTimeout(edgeTimer);
            if (x < 18 || x > 375) {
                edgeTimer = setTimeout(() => {
                    const pages = $('#home-pages');
                    const page = Math.round(pages.scrollLeft / 393) + (x > 375 ? 1 : -1);
                    if (page < 0 || page >= HOME_LAYOUT.pages.length) return;
                    pages.scrollTo({ left: page * 393 });
                }, 550);
            }
        };
        const up = () => {
            window.removeEventListener('pointermove', move);
            window.removeEventListener('pointerup', up);
            clearTimeout(edgeTimer);
            if (!started || !dragging) return;
            dragging.ghost.remove();
            dragging = null;
            rpc('saveSettings', { homeOrder: Phone.settings.homeOrder || currentOrder() });
            renderHome();
        };
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', up);
    }, true);
}

/** long-press on icons + swipe down for Search (replaces the old long-press) */
function setupHomeGestures() {
    const home = $('#home');
    const pages = $('#home-pages');
    let press = null, pressIcon = null, menuShown = false, px = 0, py = 0;
    home.addEventListener('pointerdown', (e) => {
        const icon = e.target.closest('.app-icon[data-app]');
        if (!icon || home.classList.contains('jiggle') || e.target.closest('.rm-badge')) return;
        pressIcon = icon; menuShown = false; px = e.clientX; py = e.clientY;
        clearTimeout(press);
        press = setTimeout(() => {
            menuShown = true;
            Phone.vibrate && Sound.play('key', 5);
            showQuickActions(icon.dataset.app, icon);
            // keep holding without moving -> jiggle mode
            press = setTimeout(() => { if (menuShown) { enterJiggle(); Phone._swallowHomeClick = true; } }, 900);
        }, 480);
    }, true);
    window.addEventListener('pointermove', (e) => {
        if (!pressIcon) return;
        const moved = Math.hypot(e.clientX - px, e.clientY - py) / (Phone.scale || 1);
        if (moved > 8) {
            clearTimeout(press);
            // moving while the menu is up starts editing (like a real phone)
            if (menuShown && moved > 14) { enterJiggle(); menuShown = false; }
        }
    });
    window.addEventListener('pointerup', () => {
        clearTimeout(press);
        if (menuShown) {
            Phone._swallowHomeClick = true; // releasing after the menu appears isn't a tap
            // ...but only that release: if it lands on the menu instead of the home screen, don't eat the next tap
            setTimeout(() => { Phone._swallowHomeClick = false; }, 0);
        }
        pressIcon = null;
    });

    // swipe down on the home screen opens Search
    drag(pages, {
        threshold: 10,
        onStart: (e) => !home.classList.contains('jiggle') && !e.target.closest('.widget-wrap'),
        onEnd: (dx, dy, vy, _vx, _e, moved) => { if (moved && dy > 70 && Math.abs(dx) < 50) Spotlight.open(); },
    });
}

/* ---------------------------------------------------------------------
   lock screen: swipe left opens the camera without unlocking
   --------------------------------------------------------------------- */

function setupLockGestures() {
    const ls = $('#lockscreen');
    drag(ls, {
        threshold: 8,
        onStart: (e) => !e.target.closest('.ls-btn, .notif, .passcode, .ls-music'),
        onMove: (dx, dy) => {
            if (Math.abs(dx) < Math.abs(dy) || dx > 0) return;
            ls.classList.add('dragging');
            ls.style.transform = `translateX(${dx * 0.8}px)`;
        },
        onEnd: (dx, dy, _vy, vx) => {
            if (Math.abs(dx) < Math.abs(dy)) return;
            ls.classList.remove('dragging');
            ls.style.transform = '';
            if (dx < -110 || vx < -0.6) openLockCamera();
        },
    });
}
function openLockCamera() {
    Phone.openApp('camera', { fromLock: true });
}

/* ---------------------------------------------------------------------
   swipe a list row left to reveal Delete
   swipeRows(container, '.row[data-id]', { label, onDelete(row) })
   --------------------------------------------------------------------- */

function swipeRows(container, selector, { label = 'Delete', icon = 'fa-trash', onDelete }) {
    let open = null;
    const closeOpen = () => { if (open) { open.classList.remove('swiped'); $('.sw-row-inner', open).style.transform = ''; open = null; } };
    container.addEventListener('pointerdown', (e) => {
        const row = e.target.closest(selector);
        if (open && open !== row && !e.target.closest('.sw-del')) closeOpen();
        if (!row || e.target.closest('.sw-del')) return;
        if (!row.querySelector('.sw-row-inner')) {
            const inner = document.createElement('div');
            inner.className = 'sw-row-inner';
            while (row.firstChild) inner.appendChild(row.firstChild);
            row.appendChild(inner);
            row.insertAdjacentHTML('beforeend', `<button class="sw-del"><i class="fa-solid ${icon}"></i><span>${esc(I18N.t(label))}</span></button>`);
            row.classList.add('sw-row');
        }
        const inner = $('.sw-row-inner', row);
        const sx = e.clientX, sy = e.clientY, base = row.classList.contains('swiped') ? -88 : 0;
        let horiz = null;
        const move = (ev) => {
            const k = Phone.scale || 1;
            const dx = (ev.clientX - sx) / k, dy = (ev.clientY - sy) / k;
            if (horiz === null && Math.hypot(dx, dy) > 6) horiz = Math.abs(dx) > Math.abs(dy);
            if (!horiz) return;
            ev.preventDefault();
            inner.style.transition = 'none';
            inner.style.transform = `translateX(${Math.min(0, base + dx)}px)`;
        };
        const up = (ev) => {
            window.removeEventListener('pointermove', move);
            window.removeEventListener('pointerup', up);
            inner.style.transition = '';
            if (!horiz) return;
            const dx = (ev.clientX - sx) / (Phone.scale || 1) + base;
            // swallow the click that follows a swipe
            const stop = (c) => { c.stopPropagation(); c.preventDefault(); };
            window.addEventListener('click', stop, { capture: true, once: true });
            setTimeout(() => window.removeEventListener('click', stop, { capture: true }), 60);
            if (dx < -260) { inner.style.transform = 'translateX(-100%)'; return setTimeout(() => onDelete(row), 180); }   // full swipe
            if (dx < -50) { inner.style.transform = 'translateX(-88px)'; row.classList.add('swiped'); open = row; }
            else { inner.style.transform = ''; row.classList.remove('swiped'); if (open === row) open = null; }
        };
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', up);
    });
    container.addEventListener('click', (e) => {
        const del = e.target.closest('.sw-del');
        if (!del) return;
        e.stopPropagation();
        const row = del.closest(selector);
        open = null;
        onDelete(row);
    }, true);
}

/* ---------------------------------------------------------------------
   boot
   --------------------------------------------------------------------- */

// locking puts away everything that sits above the lock screen
Phone.on('locked', () => {
    Switcher.close();
    Spotlight.close();
    closeQuickActions();
    exitJiggle();
});

document.addEventListener('DOMContentLoaded', () => {
    setupStatusGestures();
    setupHomeGestures();
    setupIconDrag();
    setupLockGestures();
});
