'use strict';

/* =====================================================================
   OPS OS Store — browse, install and remove apps.
   Today (featured), Apps (by category), Search, and an app page with
   GET → download ring → OPEN. System apps can't be removed.
   ===================================================================== */

const STORE_INFO = {
    phone:      { category: 'Utilities',      subtitle: 'Calls, voicemail and contacts',     about: 'Call anyone in Los Santos. Favourites, recents, a full keypad and live call controls in the Dynamic Island.' },
    messages:   { category: 'Social',         subtitle: 'Text, photos and live location',     about: 'Chat with friends, send photos and share your live location so they can follow you on the map.' },
    contacts:   { category: 'Utilities',      subtitle: 'Everyone you know, in one place',    about: 'Save numbers and emails, mark favourites, block callers and OpsDrop a card to someone nearby.' },
    mail:       { category: 'Productivity',   subtitle: 'Your OPS ID inbox',                  about: 'Send and receive email from your OPS ID address.' },
    camera:     { category: 'Photo & Video',  subtitle: 'Photos and selfies',                 about: 'Take photos and selfies with the phone camera and save them to Photos.' },
    photos:     { category: 'Photo & Video',  subtitle: 'Your photo library',                 about: 'Browse your photos, mark favourites, share them or set one as your wallpaper.' },
    settings:   { category: 'Utilities',      subtitle: 'Make the phone yours',               about: 'Wallpaper, sounds, language, units, Face Unlock, performance and more.' },
    services:   { category: 'Lifestyle',      subtitle: 'Police, EMS, mechanic and taxi',     about: 'Request help with your GPS location attached. Responders see requests in their dispatch list.' },
    dev:        { category: 'Developer Tools', subtitle: 'Server tools for staff',            about: 'Add map locations and blips, manage wallpapers, phone numbers and the email domain. Requires a developer login.' },
    store:      { category: 'Utilities',      subtitle: 'Get more apps',                      about: 'Discover, install and remove apps.' },
    wallet:     { category: 'Finance',        subtitle: 'Bank, cash and bills',               about: 'Check your balance, send money to any phone number and pay your bills.' },
    chirp:      { category: 'Social',         subtitle: 'What’s happening in Los Santos',     about: 'Post updates, like and reply to what the city is talking about.' },
    maps:       { category: 'Navigation',     subtitle: 'Places, directions and friends',     about: 'Find places across San Andreas, set GPS directions and see friends who share their location.' },
    weather:    { category: 'Weather',        subtitle: 'Live conditions and forecast',       about: 'Current conditions straight from the city, an hourly outlook and a 10-day forecast.' },
    clock:      { category: 'Utilities',      subtitle: 'Alarms, timers and world clock',     about: 'World clock, alarms, stopwatch and timers that keep running when the phone is away.' },
    notes:      { category: 'Productivity',   subtitle: 'Jot it down',                        about: 'Quick notes that save as you type. Send a note to a contact in one tap.' },
    calendar:   { category: 'Productivity',   subtitle: 'Your month at a glance',             about: 'A clean month view with today highlighted.' },
    calculator: { category: 'Utilities',      subtitle: 'Quick sums',                         about: 'A simple, fast calculator.' },
    soundwave:  { category: 'Music',          subtitle: 'Music, radio and your library',      about: 'Stream internet radio, play songs from any link or YouTube, build playlists and keep your liked songs. Plays in the background with controls on the lock screen, Control Center and Dynamic Island.' },
    tide:       { category: 'Music',          subtitle: 'Hi-fi radio and your music',         about: 'A clean, black and white music player: live radio stations, songs from links or YouTube, playlists and liked songs, with controls everywhere on the phone.' },
    opsmobile:  { category: 'Utilities',      subtitle: 'Your plan, usage and eSIM',          about: 'See your texts, minutes and data at a glance, buy or switch plans and extras paid from your bank, renew, install your eSIM and chat with support. Using the app never counts against your data.' },
    garage:     { category: 'Lifestyle',      subtitle: 'Your vehicles',                      about: 'See every vehicle you own, where it is parked and its fuel, engine and body condition.' },
    opsnet:     { category: 'Productivity',   subtitle: 'Jobs, faults and the network',       about: 'The network engineer\'s app: take fault and planned-work jobs and get paid, read fault diagnosis and fix steps, look up customers, cabinets, links, towers and poles, and run a Wi-Fi range test on site. Requires an Ops-Networks account.' },
};

const STORE_FEATURED = [
    { id: 'opsmobile', eyebrow: 'ESSENTIALS', title: 'Your Plan in Your Pocket', bg: 'linear-gradient(150deg,#0a84ff,#5e5ce6 55%,#ff375f)' },
    { id: 'soundwave', eyebrow: 'NEW', title: 'Music for Every Drive', bg: 'linear-gradient(160deg,#1ed760,#0b3d1d)' },
    { id: 'chirp', eyebrow: 'APP OF THE DAY', title: 'Join the Conversation', bg: 'linear-gradient(160deg,#1d9bf0,#0b5fa5)' },
    { id: 'maps', eyebrow: 'GET STARTED', title: 'Find Your Way Around San Andreas', bg: 'linear-gradient(160deg,#34c759,#1e7c39)' },
    { id: 'wallet', eyebrow: 'ESSENTIALS', title: 'Your Money, Sorted', bg: 'linear-gradient(160deg,#2c2c2e,#000)' },
];

const storeInfo = (id) => STORE_INFO[id] || { category: 'Utilities', subtitle: '', about: '' };
const isSystemApp = (id) => SYSTEM_APPS.has(id);

/** GET / OPEN button html */
function storeBtn(id) {
    return Phone.isInstalled(id)
        ? `<button class="st-get open" data-open="${id}">${esc(I18N.t('Open'))}</button>`
        : `<button class="st-get" data-get="${id}">${esc(I18N.t('Get'))}</button>`;
}

function storeRow(def) {
    const info = storeInfo(def.id);
    return `
        <div class="row tap st-row" data-detail="${def.id}">
            ${iconScaled(def, 58)}
            <div class="grow"><div class="title">${esc(def.name)}</div><div class="sub">${esc(info.subtitle)}</div></div>
            ${storeBtn(def.id)}
        </div>`;
}

/** animate GET → spinner → progress ring → OPEN, then install */
function storeInstall(id, btn) {
    if (!btn || btn.classList.contains('loading')) return;
    btn.classList.add('loading');
    btn.innerHTML = '<svg viewBox="0 0 36 36" class="st-ring"><circle cx="18" cy="18" r="15" class="bg"/><circle cx="18" cy="18" r="15" class="fg"/><rect x="13.5" y="13.5" width="9" height="9" rx="1.5"/></svg>';
    const fg = $('.fg', btn);
    const t0 = performance.now(), dur = 1100;
    const step = (t) => {
        const p = Math.min(1, (t - t0) / dur);
        fg.style.strokeDashoffset = String(94.25 * (1 - p));
        if (p < 1) return requestAnimationFrame(step);
        Phone.installApp(id);
        Sound.play('pay');
        UI.toast(`${(Apps.byId[id] || {}).name || ''} ${I18N.t('installed')}`, 'fa-solid fa-circle-check');
    };
    requestAnimationFrame(step);
}

/** keep every GET/OPEN button on screen in sync with install state */
function storeRefreshButtons(root) {
    $$('[data-get], [data-open]', root).forEach((b) => {
        const id = b.dataset.get || b.dataset.open;
        if (b.classList.contains('loading') && !Phone.isInstalled(id)) return;
        b.outerHTML = storeBtn(id);
    });
    $$('[data-remove-app]', root).forEach((b) => b.classList.toggle('hidden', !Phone.isInstalled(b.dataset.removeApp)));
}

function StoreDetail(nav, id) {
    const def = Apps.byId[id];
    if (!def) return;
    const info = storeInfo(id);
    nav.push({
        title: '',
        backLabel: I18N.t('Back'),
        render(c) {
            c.innerHTML = `
                <div class="sd-head">
                    ${iconScaled(def, 118)}
                    <div class="sd-meta">
                        <div class="sd-name">${esc(def.name)}</div>
                        <div class="sd-sub">${esc(info.subtitle)}</div>
                        <div class="sd-actions">${storeBtn(id)}</div>
                    </div>
                </div>
                <div class="sd-strip">
                    <div><span>${esc(I18N.t('Category'))}</span><i class="fa-solid fa-shapes"></i><b>${esc(info.category)}</b></div>
                    <div><span>${esc(I18N.t('Developer'))}</span><i class="fa-solid fa-code"></i><b>OPS Labs</b></div>
                    <div><span>${esc(I18N.t('Version'))}</span><i class="fa-solid fa-code-branch"></i><b>1.0</b></div>
                    <div><span>${esc(I18N.t('Requires'))}</span><i class="fa-solid fa-mobile-screen"></i><b>OPS OS 1.0</b></div>
                </div>
                <div class="sd-preview" style="background:${def.icon.bg}">${iconScaled(def, 84)}<b>${esc(def.name)}</b><span>${esc(info.subtitle)}</span></div>
                <div class="sd-about">${esc(info.about)}</div>
                ${isSystemApp(id) ? `<div class="sd-note"><i class="fa-solid fa-lock"></i> ${esc(I18N.t('Built into OPS OS'))}</div>`
                    : `<div class="group" style="margin-top:20px"><div class="row tap destructive ${Phone.isInstalled(id) ? '' : 'hidden'}" data-remove-app="${id}">${esc(I18N.t('Remove App'))}</div></div>`}`;
        },
    });
}

function StoreTodayTab(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: I18N.t('Today'),
        large: true,
        tabbar: true,
        render(c) {
            const now = new Date();
            c.innerHTML = `
                <div class="st-date">${esc(now.toLocaleDateString(Phone.locale, { weekday: 'long', day: 'numeric', month: 'long' }).toUpperCase())}</div>
                ${STORE_FEATURED.filter((f) => Apps.byId[f.id]).map((f) => {
                    const def = Apps.byId[f.id];
                    return `<div class="st-card" data-detail="${f.id}" style="background:${f.bg}">
                        <div class="st-card-eyebrow">${esc(f.eyebrow)}</div>
                        <div class="st-card-title">${esc(f.title)}</div>
                        <div class="st-card-art">${iconScaled(def, 96)}</div>
                        <div class="st-card-foot">${iconScaled(def, 40)}<div class="grow"><b>${esc(def.name)}</b><span>${esc(storeInfo(f.id).subtitle)}</span></div>${storeBtn(f.id)}</div>
                    </div>`;
                }).join('')}
                <div class="group-header big" style="margin-top:8px">${esc(I18N.t('Essentials'))}</div>
                <div class="group plain-bg">${['phone', 'messages', 'services', 'settings'].map((id) => Apps.byId[id] && storeRow(Apps.byId[id])).join('')}</div>`;
        },
    });
}

function StoreAppsTab(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: I18N.t('Apps'),
        large: true,
        tabbar: true,
        render(c) {
            const byCat = {};
            Apps.list.forEach((a) => { (byCat[storeInfo(a.id).category] ||= []).push(a); });
            const order = ['Music', 'Social', 'Navigation', 'Finance', 'Productivity', 'Photo & Video', 'Lifestyle', 'Weather', 'Utilities', 'Developer Tools'];
            const cats = Object.keys(byCat).sort((a, b) => (order.indexOf(a) + 99) % 99 - (order.indexOf(b) + 99) % 99);
            const installed = Apps.list.filter((a) => Phone.isInstalled(a.id)).length;
            c.innerHTML = `
                <div class="st-summary"><b>${installed}</b> ${esc(I18N.t('of'))} <b>${Apps.list.length}</b> ${esc(I18N.t('apps installed'))}</div>
                ${cats.map((cat) => `
                    <div class="group-header big">${esc(cat)}</div>
                    <div class="group plain-bg">${byCat[cat].map(storeRow).join('')}</div>`).join('')}`;
        },
    });
}

function StoreSearchTab(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: I18N.t('Search'),
        large: true,
        tabbar: true,
        render(c) {
            c.innerHTML = `<div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="${esc(I18N.t('Apps, categories and more'))}"></div><div class="st-results"></div>`;
            const out = $('.st-results', c);
            const draw = (q) => {
                q = q.trim().toLowerCase();
                const list = Apps.list.filter((a) => {
                    const i = storeInfo(a.id);
                    return !q || (a.name + ' ' + i.subtitle + ' ' + i.category + ' ' + i.about).toLowerCase().includes(q);
                });
                out.innerHTML = q && !list.length
                    ? UI.empty('fa-solid fa-magnifying-glass', I18N.t('No Results'), '')
                    : `${q ? '' : `<div class="group-header big">${esc(I18N.t('Discover'))}</div>`}<div class="group plain-bg">${list.map(storeRow).join('')}</div>`;
            };
            $('input', c).addEventListener('input', (e) => draw(e.target.value));
            draw('');
        },
    });
}

Apps.register({
    id: 'store',
    name: 'OPS OS Store',
    label: 'OPS Store',
    icon: {
        bg: 'linear-gradient(180deg,#1ec8ff,#0a6cff)',
        html: () => `<svg viewBox="0 0 64 64" width="44" height="44" fill="none" stroke="#fff" stroke-width="5.2" stroke-linecap="round">
            <path d="M23 47 37 18"/><path d="M41 47 34 33"/><path d="M15 39h34"/></svg>`,
    },
    open(root, params, app) {
        const tabs = TabBar(root, [
            { id: 'today', label: 'Today', icon: 'fa-solid fa-newspaper', render: (h) => StoreTodayTab(h) },
            { id: 'apps', label: 'Apps', icon: 'fa-solid fa-layer-group', render: (h) => StoreAppsTab(h) },
            { id: 'search', label: 'Search', icon: 'fa-solid fa-magnifying-glass', render: (h) => StoreSearchTab(h) },
        ], 'today');
        app.tabs = tabs;

        root.addEventListener('click', (e) => {
            const get = e.target.closest('[data-get]');
            if (get) { e.stopPropagation(); return storeInstall(get.dataset.get, get); }
            const open = e.target.closest('[data-open]');
            if (open) { e.stopPropagation(); return open.dataset.open === 'store' ? null : Phone.openApp(open.dataset.open); }
            const rm = e.target.closest('[data-remove-app]');
            if (rm) {
                const def = Apps.byId[rm.dataset.removeApp];
                UI.alert({
                    title: `${I18N.t('Remove')} “${def.name}”?`,
                    message: I18N.t('You can reinstall it any time from the OPS OS Store.'),
                    buttons: [{ label: I18N.t('Cancel'), value: false, style: 'cancel' }, { label: I18N.t('Remove App'), value: true, style: 'destructive' }],
                }).then((ok) => { if (ok) Phone.uninstallApp(def.id); });
                return;
            }
            const d = e.target.closest('[data-detail]');
            if (d) {
                const host = tabs.host(tabs.current);
                if (host && host._nav) StoreDetail(host._nav, d.dataset.detail);
            }
        });
        app.on('appsChanged', () => {
            storeRefreshButtons(root);
            const sum = $('.st-summary', root);
            if (sum) sum.innerHTML = `<b>${Apps.list.filter((a) => Phone.isInstalled(a.id)).length}</b> ${esc(I18N.t('of'))} <b>${Apps.list.length}</b> ${esc(I18N.t('apps installed'))}`;
        });
        // opened by tapping a removed app (e.g. from a notification or shortcut)
        if (params.app) setTimeout(() => { const h = tabs.host(tabs.current); if (h && h._nav) StoreDetail(h._nav, params.app); }, 50);
    },
    onParams(params, app) {
        const h = app.tabs && app.tabs.host(app.tabs.current);
        if (params.app && h && h._nav) StoreDetail(h._nav, params.app);
    },
});
