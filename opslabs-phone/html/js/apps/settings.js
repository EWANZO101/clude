'use strict';

const AUTO_LOCK_OPTIONS = [[0, 'Immediately'], [30, 'After 30 Seconds'], [60, 'After 1 Minute'], [300, 'After 5 Minutes'], [-1, 'Never']];
const autoLockLabel = (v) => (AUTO_LOCK_OPTIONS.find((o) => o[0] === v) || AUTO_LOCK_OPTIONS[0])[1];

const SETTINGS_ICONS = {
    airplane: ['#ff9500', 'fa-plane'],
    wifi: ['#007aff', 'fa-wifi'],
    bluetooth: ['#007aff', 'fa-bluetooth-b fa-brands'],
    cellular: ['#34c759', 'fa-tower-cell'],
    notifications: ['#ff3b30', 'fa-bell'],
    sounds: ['#ff2d55', 'fa-volume-high'],
    focus: ['#5856d6', 'fa-moon'],
    general: ['#8e8e93', 'fa-gear'],
    accessibility: ['#007aff', 'fa-universal-access'],
    performance: ['#ff9500', 'fa-gauge-high'],
    language: ['#007aff', 'fa-globe'],
    units: ['#34c759', 'fa-ruler-combined'],
    display: ['#007aff', 'fa-sun'],
    wallpaper: ['#32ade6', 'fa-image'],
    faceid: ['#34c759', 'fa-face-smile'],
    battery: ['#34c759', 'fa-battery-three-quarters'],
    privacy: ['#007aff', 'fa-hand'],
};

function sIcon(key) {
    const [bg, icon] = SETTINGS_ICONS[key];
    const cls = icon.includes('fa-brands') ? icon : 'fa-solid ' + icon;
    return `<span class="ri" style="background:${bg}"><i class="${cls}"></i></span>`;
}

function sRow(key, label, { value = '', chevron = true, toggle = null, act = key } = {}) {
    return `<div class="row ${toggle === null ? 'tap' : ''} has-icon" data-s="${act}">
        ${sIcon(key)}<div class="grow">${esc(label)}</div>
        ${toggle !== null ? UI.switchHtml(toggle, `data-toggle="${act}"`) : `<span class="value">${esc(value)}</span>${chevron ? '<i class="fa-solid fa-chevron-right chev"></i>' : ''}`}
    </div>`;
}

const SettingsPages = {
    general(nav) {
        nav.push({
            title: 'General', grouped: true, backLabel: 'Settings',
            render(c) {
                c.innerHTML = `<div class="group" style="margin-top:12px">
                    <div class="row tap" data-p="about"><div class="grow">About</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    <div class="row tap" data-p="update"><div class="grow">Software Update</div><i class="fa-solid fa-chevron-right chev"></i></div>
                </div>
                <div class="group">
                    <div class="row"><div class="grow">Storage</div><span class="value">128 GB</span></div>
                    <div class="row"><div class="grow">Date & Time</div><span class="value">Automatic</span></div>
                    <div class="row"><div class="grow">Keyboard</div><span class="value">English</span></div>
                </div>
                <div class="group"><div class="row tap" data-p="reset"><div class="grow">Transfer or Reset Phone</div><i class="fa-solid fa-chevron-right chev"></i></div></div>`;
                c.addEventListener('click', async (e) => {
                    const p = e.target.closest('[data-p]');
                    if (!p) return;
                    if (p.dataset.p === 'about') SettingsPages.about(nav);
                    if (p.dataset.p === 'update') SettingsPages.update(nav);
                    if (p.dataset.p === 'reset') {
                        if (await UI.confirm('Reset All Settings', 'This will reset wallpaper, sounds, display and passcode.', 'Reset', true)) {
                            const defaults = { wallpaper: 'ios18', ringtone: 'reflection', darkMode: false, passcode: '', brightness: 1, volume: 0.7, zoom: 1, silent: false, dnd: false, faceId: true };
                            Object.assign(Phone.settings, defaults);
                            rpc('saveSettings', defaults);
                            applySettings();
                            renderHome();
                            UI.toast('Settings reset');
                        }
                    }
                });
            },
        });
    },

    about(nav) {
        const p = Phone.profile || {};
        nav.push({
            title: 'About', grouped: true,
            render(c) {
                const rows = [
                    ['Name', p.name], ['Version', 'OPS OS 1.0'], ['Model Name', 'OPS Phone 16'], ['Model Number', 'OPS-16'],
                    ['Serial Number', 'OPS' + String(p.number || '').replace(/\D/g, '') + 'XQ'],
                ];
                const rows2 = [['Phone Number', p.number], ['Email', p.email], ['Network', 'LS Mobile'], ['Capacity', '128 GB'], ['Available', '97.4 GB']];
                const g = (r) => `<div class="group">${r.map(([k, v]) => `<div class="row"><div class="grow">${esc(k)}</div><span class="value" style="user-select:text">${esc(v || '')}</span></div>`).join('')}</div>`;
                c.innerHTML = `<div style="margin-top:12px"></div>${g(rows)}${g(rows2)}`;
            },
        });
    },

    update(nav) {
        nav.push({
            title: 'Software Update', grouped: true,
            render(c) {
                c.innerHTML = `<div class="empty" style="padding-top:120px"><i class="fa-solid fa-gear" style="color:var(--label2)"></i><b style="font-size:17px">OPS OS 1.0</b><p>OPS OS is up to date</p></div>`;
            },
        });
    },

    sounds(nav) {
        nav.push({
            title: 'Sounds & Haptics', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const s = Phone.settings;
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px"><div class="row"><div class="grow">Silent Mode</div>${UI.switchHtml(s.silent, 'data-toggle="silent"')}</div></div>
                        <div class="group-header">Ringtone and Alert Volume</div>
                        <div class="group"><div class="row" style="gap:14px"><i class="fa-solid fa-volume-off muted"></i>
                            <input type="range" class="slider" min="0" max="100" value="${Math.round((s.volume ?? 0.7) * 100)}" data-range="volume"><i class="fa-solid fa-volume-high muted"></i></div></div>
                        <div class="group-header">Sounds and Haptic Patterns</div>
                        <div class="group">${(Phone.config.ringtones || []).map((r) => `
                            <div class="row tap" data-ring="${r.id}"><div class="grow">${esc(r.label)}</div>${(s.ringtone || 'reflection') === r.id ? '<i class="fa-solid fa-check check"></i>' : ''}</div>`).join('')}
                        </div>`;
                };
                draw();
                c.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-ring]');
                    if (r) { Phone.saveSetting('ringtone', r.dataset.ring); Sound.preview(r.dataset.ring); draw(); }
                });
                c.addEventListener('change', (e) => {
                    if (e.target.dataset.toggle === 'silent') Phone.saveSetting('silent', e.target.checked);
                    if (e.target.dataset.range === 'volume') { Phone.saveSetting('volume', +e.target.value / 100); Sound.play('notify'); }
                });
            },
            onLeave: () => Sound.stopRing(),
        });
    },

    notifications(nav) {
        nav.push({
            title: 'Notifications', grouped: true, backLabel: 'Settings',
            render(c) {
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        <div class="row"><div class="grow">Show Previews</div><span class="value">Always</span><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row"><div class="grow">Do Not Disturb</div>${UI.switchHtml(Phone.settings.dnd, 'data-toggle="dnd"')}</div>
                    </div>
                    <div class="group-header">Notification Style</div>
                    <div class="group">${Apps.list.filter((a) => !['calculator', 'camera', 'clock'].includes(a.id)).map((a) => `
                        <div class="row has-icon">${iconScaled(a, 30, 'ri')}
                            <div class="grow"><div class="title">${esc(a.name)}</div><div class="sub">Banners, Sounds, Badges</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}
                    </div>`;
                c.addEventListener('change', (e) => { if (e.target.dataset.toggle === 'dnd') Phone.saveSetting('dnd', e.target.checked); });
            },
        });
    },

    focus(nav) {
        nav.push({
            title: 'Focus', grouped: true, backLabel: 'Settings',
            render(c) {
                c.innerHTML = `
                    <div class="group" style="margin-top:12px">
                        <div class="row has-icon"><span class="ri" style="background:#5856d6"><i class="fa-solid fa-moon"></i></span><div class="grow">Do Not Disturb</div>${UI.switchHtml(Phone.settings.dnd, 'data-toggle="dnd"')}</div>
                    </div>
                    <div class="group-footer">When Do Not Disturb is on, notifications are silenced and won't show banners. Calls still ring.</div>`;
                c.addEventListener('change', (e) => { if (e.target.dataset.toggle === 'dnd') Phone.saveSetting('dnd', e.target.checked); });
            },
        });
    },

    display(nav) {
        nav.push({
            title: 'Display & Brightness', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const s = Phone.settings;
                    const zoom = s.zoom || 1;
                    c.innerHTML = `
                        <div class="group-header" style="margin-top:12px">Appearance</div>
                        <div class="group"><div class="appearance">
                            ${[['light', 'Light', false], ['dark', 'Dark', true]].map(([k, l, d]) => `
                                <button data-look="${k}" class="${!!s.darkMode === d ? 'on' : ''}">
                                    <span class="ap-phone ${k}" style="background:${wallpaperCss(s.wallpaper)}"><i></i><i></i><i></i></span>
                                    <span>${l}</span>
                                    <span class="ap-check">${!!s.darkMode === d ? '<i class="fa-solid fa-circle-check"></i>' : '<i class="fa-regular fa-circle"></i>'}</span>
                                </button>`).join('')}
                        </div></div>
                        <div class="group-header">Brightness</div>
                        <div class="group"><div class="row" style="gap:14px"><i class="fa-solid fa-sun muted" style="font-size:12px"></i>
                            <input type="range" class="slider" min="10" max="100" value="${Math.round((s.brightness ?? 1) * 100)}" data-range="brightness"><i class="fa-solid fa-sun muted" style="font-size:20px"></i></div></div>
                        <div class="group">
                            <div class="row tap" data-act="autolock"><div class="grow">Auto-Lock</div><span class="value">${esc(autoLockLabel(autoLockDelay()))}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                        </div>
                        <div class="group-header">Display Zoom</div>
                        <div class="group">
                            ${[[0.9, 'Smaller'], [1, 'Default'], [1.12, 'Larger Text']].map(([z, l]) => `<div class="row tap" data-zoom="${z}"><div class="grow">${l}</div>${Math.abs(zoom - z) < 0.01 ? '<i class="fa-solid fa-check check"></i>' : ''}</div>`).join('')}
                        </div>
                        <div class="group-footer">Changes the size of the phone on your screen.</div>`;
                };
                draw();
                c.addEventListener('click', (e) => {
                    const t = e.target.closest('[data-look]');
                    if (t) { Phone.saveSetting('darkMode', t.dataset.look === 'dark'); renderHome(); draw(); }
                    if (e.target.closest('[data-act=autolock]')) { SettingsPages.autolock(nav, draw); return; }
                    const z = e.target.closest('[data-zoom]');
                    if (z) { Phone.saveSetting('zoom', +z.dataset.zoom); draw(); }
                });
                c.addEventListener('input', (e) => {
                    if (e.target.dataset.range === 'brightness') {
                        Phone.settings.brightness = +e.target.value / 100;
                        $('#brightness-dim').style.opacity = String((1 - Phone.settings.brightness) * 0.7);
                    }
                });
                c.addEventListener('change', (e) => {
                    if (e.target.dataset.range === 'brightness') Phone.saveSetting('brightness', +e.target.value / 100);
                });
            },
        });
    },

    language(nav) {
        nav.push({
            title: 'Language & Region', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const s = Phone.settings;
                    const region = regionById(s.region);
                    c.innerHTML = `
                        <div class="group-header" style="margin-top:12px">Language</div>
                        <div class="group">${LANGUAGES.map((l) => `
                            <div class="row tap" data-lang="${l.id}"><div class="grow"><div class="title" data-no-i18n>${esc(l.native)}</div><div class="sub" data-no-i18n>${esc(l.name)}</div></div>${(s.language || 'en') === l.id ? '<i class="fa-solid fa-check check"></i>' : ''}</div>`).join('')}
                        </div>
                        <div class="group">
                            <div class="row tap" data-act="region"><div class="grow">Region</div><span class="value" data-no-i18n>${esc(region.name)}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row tap" data-act="units"><div class="grow">Units & Formats</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        </div>
                        <div class="group-footer">Region decides number formatting only. Every unit is set in Units & Formats.</div>`;
                };
                draw();
                c.addEventListener('click', async (e) => {
                    const l = e.target.closest('[data-lang]');
                    if (l) { Phone.saveSetting('language', l.dataset.lang); I18N.set(l.dataset.lang); renderHome(); tick(true); return draw(); }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'units') return SettingsPages.units(nav);
                    if (a.dataset.act === 'region') {
                        const i = await UI.actionSheet(I18N.t('Region'), REGIONS.map((r) => ({ label: r.name })));
                        if (i === null) return;
                        Phone.saveSetting('region', REGIONS[i].id);
                        tick(true); renderHome(); draw();
                    }
                });
            },
        });
    },

    units(nav) {
        nav.push({
            title: 'Units & Formats', grouped: true, backLabel: 'Back',
            render(c) {
                c.innerHTML = `
                    <div class="st-preview units-preview" style="margin:12px 16px 20px" data-no-i18n>${unitsPreviewHtml()}</div>
                    <div class="units-editor">${unitsEditorHtml()}</div>
                    <div class="group-footer" style="margin-top:6px">Pick each one — they don’t depend on your language.</div>`;
                bindUnitsEditor(c, (all) => {
                    rpc('saveSettings', all);
                    renderHome();
                });
            },
        });
    },

    performance(nav) {
        nav.push({
            title: 'Performance', grouped: true, backLabel: 'Settings',
            render(c) {
                let result = null;
                const draw = () => {
                    const cur = Perf.current();
                    c.innerHTML = `
                        <div class="st-bench perf-result" style="margin:12px 16px 26px">${result ? `
                            <div class="st-bench-res"><b>${result.fps}</b><span>fps</span></div>
                            <div class="st-bench-res"><b>${result.loadMs}</b><span>ms load</span></div>
                            <div class="st-bench-res"><b>${result.p95}</b><span>ms worst</span></div>` : '<span class="muted" style="font-size:14px">Run the test to see how your PC handles the phone.</span>'}
                        </div>
                        <div class="group">${Object.entries(Perf.PRESETS).map(([id, p]) => `
                            <div class="row tap has-icon" data-preset="${id}">
                                <span class="ri" style="background:${id === 'ultra' ? '#af52de' : id === 'balanced' ? '#007aff' : '#ff9500'}"><i class="fa-solid ${p.icon}"></i></span>
                                <div class="grow"><div class="title">${esc(p.label)}${result && result.recommended === id ? ` <span class="st-rec">${esc(I18N.t('Recommended'))}</span>` : ''}</div><div class="sub" style="white-space:normal">${esc(p.desc)}</div></div>
                                ${cur === id ? '<i class="fa-solid fa-check check"></i>' : ''}
                            </div>`).join('')}
                        </div>
                        <div class="group"><div class="row tap" data-act="test"><span class="tint grow">Run Test Again</span><i class="fa-solid fa-gauge tint"></i></div></div>
                        <div class="group-footer">The phone draws at your game's frame rate. Lighter profiles make each frame cheaper, so the phone keeps 60 fps or more on slower PCs.</div>`;
                };
                draw();
                const test = async () => {
                    const prev = Perf.current();
                    Object.assign(Phone.settings, { reduceTransparency: false, reduceMotion: false });
                    applySettings();
                    c.querySelector('.perf-result').innerHTML = '<div class="spinner" style="margin:6px auto"></div>';
                    result = await Perf.benchmark(c, 1500);
                    Perf.apply(prev);
                    draw();
                };
                c.addEventListener('click', (e) => {
                    const p = e.target.closest('[data-preset]');
                    if (p) { Perf.apply(p.dataset.preset); return draw(); }
                    if (e.target.closest('[data-act=test]')) test();
                });
            },
        });
    },

    accessibility(nav) {
        nav.push({
            title: 'Accessibility', grouped: true, backLabel: 'Settings',
            render(c) {
                const s = Phone.settings;
                c.innerHTML = `
                    <div class="group-header" style="margin-top:12px">Vision</div>
                    <div class="group">
                        <div class="row"><div class="grow">Reduce Transparency</div>${UI.switchHtml(s.reduceTransparency, 'data-toggle="reduceTransparency"')}</div>
                    </div>
                    <div class="group-footer">Replaces blurred backgrounds with solid colours. Turn this on if the phone feels slow on your PC.</div>
                    <div class="group-header">Motion</div>
                    <div class="group">
                        <div class="row"><div class="grow">Reduce Motion</div>${UI.switchHtml(s.reduceMotion, 'data-toggle="reduceMotion"')}</div>
                    </div>
                    <div class="group-footer">Uses quick fades instead of zoom and slide animations.</div>`;
                c.addEventListener('change', (e) => {
                    const k = e.target.dataset.toggle;
                    if (k) Phone.saveSetting(k, e.target.checked);
                });
            },
        });
    },

    autolock(nav, onChange) {
        nav.push({
            title: 'Auto-Lock', grouped: true, backLabel: 'Back',
            render(c) {
                const draw = () => {
                    const cur = autoLockDelay();
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px">${AUTO_LOCK_OPTIONS.map(([v]) => `
                            <div class="row tap" data-delay="${v}"><div class="grow">${esc(autoLockLabel(v))}</div>${cur === v ? '<i class="fa-solid fa-check check"></i>' : ''}</div>`).join('')}
                        </div>
                        <div class="group-footer">How long the phone stays unlocked after you put it away. Pressing the side button always locks it immediately.</div>`;
                };
                draw();
                c.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-delay]');
                    if (!r) return;
                    Phone.saveSetting('autoLock', +r.dataset.delay);
                    draw();
                    onChange && onChange();
                });
            },
        });
    },

    wallpaper(nav) {
        nav.push({
            title: 'Wallpaper', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const cur = Phone.settings.wallpaper || 'ios18';
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px;padding:18px 10px">
                            <div class="wp-current">
                                <div class="wp-prev lock" style="background:${wallpaperCss(cur)}"><span class="wp-time">${new Date().toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M/, '')}</span></div>
                                <div class="wp-prev home" style="background:${wallpaperCss(cur)}"><span class="wp-icons">${'<i></i>'.repeat(16)}</span></div>
                            </div>
                        </div>
                        <div class="group-header">Collections</div>
                        <div class="group" style="padding:14px">
                            <div class="wp-grid">${(Phone.config.wallpapers || []).map((w) => `
                                <button class="wp-item ${cur === w.id ? 'on' : ''}" data-wp="${w.id}" style="background:${w.css}"><span>${esc(w.label)}</span></button>`).join('')}
                            </div>
                        </div>
                        <div class="group">
                            <div class="row tap" data-act="photos"><span class="tint grow">Choose from Photos</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row tap" data-act="url"><span class="tint grow">Image URL…</span><i class="fa-solid fa-chevron-right chev"></i></div>
                        </div>`;
                };
                draw();
                c.addEventListener('click', async (e) => {
                    const w = e.target.closest('[data-wp]');
                    if (w) { Phone.saveSetting('wallpaper', w.dataset.wp); return draw(); }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    const url = a.dataset.act === 'photos' ? await pickPhoto() : await UI.prompt('Wallpaper', 'Paste an image URL', { placeholder: 'https://' });
                    if (url && /^https?:\/\//.test(url)) { Phone.saveSetting('wallpaper', url); draw(); }
                });
            },
        });
    },

    faceid(nav) {
        nav.push({
            title: 'Face Unlock & Passcode', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const s = Phone.settings;
                    c.innerHTML = `
                        <div class="group-header" style="margin-top:12px">Use Face Unlock For</div>
                        <div class="group">
                            <div class="row"><div class="grow">Phone Unlock</div>${UI.switchHtml(s.faceId !== false, 'data-toggle="faceId"')}</div>
                        </div>
                        <div class="group-footer">Face Unlock recognises you as you raise the phone, so a swipe opens it. Turn it off to always enter your passcode.</div>
                        <div class="group">
                            <div class="row tap" data-act="code"><span class="tint">${s.passcode ? 'Turn Passcode Off' : 'Turn Passcode On'}</span></div>
                            ${s.passcode ? '<div class="row tap" data-act="change"><span class="tint">Change Passcode</span></div>' : ''}
                        </div>`;
                };
                draw();
                const setNew = async () => {
                    const a = await UI.prompt('Set Passcode', 'Enter a 4 or 6 digit passcode', { type: 'password', placeholder: '••••' });
                    if (a === null) return;
                    if (!/^\d{4}$|^\d{6}$/.test(a)) return UI.alert({ title: 'Passcode must be 4 or 6 digits' });
                    const b = await UI.prompt('Verify Passcode', 'Re-enter your passcode', { type: 'password' });
                    if (b !== a) return UI.alert({ title: "Passcodes didn't match" });
                    Phone.saveSetting('passcode', a);
                    UI.toast('Passcode set', 'fa-solid fa-lock');
                    draw();
                };
                const verify = async () => {
                    const v = await UI.prompt('Enter Passcode', '', { type: 'password' });
                    if (v !== Phone.settings.passcode) { if (v !== null) UI.alert({ title: 'Incorrect Passcode' }); return false; }
                    return true;
                };
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'code') {
                        if (Phone.settings.passcode) { if (await verify()) { Phone.saveSetting('passcode', ''); draw(); } }
                        else setNew();
                    }
                    if (a.dataset.act === 'change' && (await verify())) setNew();
                });
                c.addEventListener('change', (e) => { if (e.target.dataset.toggle === 'faceId') Phone.saveSetting('faceId', e.target.checked); });
            },
        });
    },

    battery(nav) {
        nav.push({
            title: 'Battery', grouped: true, backLabel: 'Settings',
            render(c) {
                const b = Phone.battery || { level: 100 };
                const lvl = b.level;
                const state = b.charging === 'full' ? 'Charged' : b.charging === 'wireless' ? 'Charging wirelessly' : b.charging === 'powerbank' ? 'Charging from a power bank' : b.charging === 'safemag' ? 'Charging from OPS SafeMag' : b.charging ? 'Charging' : 'On battery';
                const sm = typeof SafeMag !== 'undefined' && SafeMag.s.owned ? SafeMag.s : null;
                c.innerHTML = `
                    <div class="group" style="margin-top:12px"><div class="row"><div class="grow">Battery Percentage</div><span class="value">${lvl}%</span></div>
                    <div class="row"><div class="grow">Status</div><span class="value">${esc(I18N.t(state))}</span></div>
                    <div class="row"><div class="grow">Battery Health</div><span class="value">100%</span></div></div>
                    <div class="group-footer">${esc(I18N.t('Charge at a phone charging cable, a wireless pad or a USB socket, or with a power bank. At 0% the phone switches off until it is charged.'))}</div>
                    ${sm ? `<div class="group-header" data-no-i18n>${esc(sm.label)}</div>
                    <div class="group"><div class="row"><div class="grow">Battery Percentage</div><span class="value">${sm.level}%</span></div>
                    <div class="row"><div class="grow">Status</div><span class="value">${esc(I18N.t(sm.charging ? 'Charging' : sm.on ? 'On your phone' : 'Not attached'))}</span></div></div>
                    <div class="group-footer">${esc(I18N.t('Use it from your inventory to snap it onto the back of your phone or take it off. It charges beside a live charger, or with your phone once the phone is full.'))}</div>` : ''}
                    ${Phone.config.batteriesWidget !== false ? `<div class="group"><div class="row"><div class="grow">Batteries Widget</div>${UI.switchHtml(Phone.settings.batteriesWidget !== false, 'data-toggle="batteriesWidget"')}</div></div>
                    <div class="group-footer">${esc(I18N.t('Shows your phone, OPS SafeMag and OPS Buds batteries on the Home Screen.'))}</div>` : ''}
                    <div class="group" style="padding:16px">
                        <div class="muted" style="font-size:13px;margin-bottom:8px">BATTERY LEVEL · LAST 24 HOURS</div>
                        <div class="bat-chart">${Array.from({ length: 24 }, (_, i) => `<i style="height:${30 + ((i * 37) % 60)}%"></i>`).join('')}</div>
                    </div>`;
                c.addEventListener('change', (e) => {
                    if (e.target.dataset.toggle !== 'batteriesWidget') return;
                    Phone.saveSetting('batteriesWidget', e.target.checked);
                    if (typeof Batteries !== 'undefined') Batteries.refresh();
                });
            },
        });
    },

    account(nav) {
        nav.push({
            title: '', grouped: true, backLabel: 'Settings',
            render(c) {
                const draw = () => {
                    const p = Phone.profile || {};
                    c.innerHTML = `
                        <div style="display:flex;flex-direction:column;align-items:center;padding:0 0 22px">
                            ${avatar(p.name, null, 'xl')}
                            <div style="font-size:26px;font-weight:600;margin-top:12px" data-no-i18n>${esc(p.name || '')}</div>
                            <div class="muted" data-no-i18n>${esc(p.email || '')}</div>
                        </div>
                        <div class="group">
                            <div class="row tap" data-act="name"><div class="grow">Name</div><span class="value" data-no-i18n>${esc(p.name || '')}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row tap" data-act="opsid"><div class="grow">OPS ID</div><span class="value" data-no-i18n>${esc(p.email || '')}</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row"><div class="grow">Phone Number</div><span class="value" data-no-i18n>${esc(p.number || '')}</span></div>
                        </div>
                        <div class="group-footer">Your OPS ID is your email address for Mail. Your old address stops receiving mail when you change it.</div>`;
                };
                draw();
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    const p = Phone.profile || {};
                    if (a.dataset.act === 'name') {
                        const v = await UI.prompt(I18N.t('Name'), '', { value: p.name || '' });
                        if (v === null || !v.trim() || v.trim() === p.name) return;
                        const res = await rpc('changeName', { name: v.trim() });
                        if (!res || res.error) return UI.alert({ title: (res && res.error) || "Couldn't save" });
                        p.name = res.name;
                        draw();
                        UI.toast(I18N.t('Saved'));
                    }
                    if (a.dataset.act === 'opsid') {
                        const domain = p.mailDomain || (p.email || '').split('@')[1] || 'opslabs.cloud';
                        const v = await UI.prompt('OPS ID', '@' + domain, { value: (p.email || '').split('@')[0] });
                        if (v === null) return;
                        const user = v.trim().toLowerCase().split('@')[0];
                        if (!user || user + '@' + domain === p.email) return;
                        const res = await rpc('changeOpsId', { emailUser: user });
                        if (!res || res.error) return UI.alert({ title: "Couldn't change OPS ID", message: (res && res.error) || '' });
                        p.email = res.email;
                        draw();
                        UI.toast(res.email, 'fa-solid fa-envelope');
                    }
                });
            },
        });
    },
};

Apps.register({
    id: 'settings',
    name: 'Settings',
    icon: {
        bg: 'linear-gradient(180deg,#d6d6db,#8e8e93)',
        html: () => `<svg viewBox="0 0 64 64" width="52" height="52"><g fill="#4a4a50"><circle cx="32" cy="32" r="21"/>${Array.from({ length: 12 }, (_, i) => `<rect x="29" y="5" width="6" height="12" rx="2" transform="rotate(${i * 30} 32 32)"/>`).join('')}</g>
            <circle cx="32" cy="32" r="15" fill="#c5c5ca"/><circle cx="32" cy="32" r="8" fill="#4a4a50"/>${Array.from({ length: 3 }, (_, i) => `<rect x="31" y="17" width="2" height="9" fill="#4a4a50" transform="rotate(${i * 120} 32 32)"/>`).join('')}</svg>`,
    },
    onParams(params, ctx) {
        if (params.page && SettingsPages[params.page] && ctx.root._nav) SettingsPages[params.page](ctx.root._nav);
    },
    open(root, params = {}) {
        const nav = new Nav(root);
        root._nav = nav;
        if (params.page && SettingsPages[params.page]) setTimeout(() => SettingsPages[params.page](nav), 0);
        nav.push({
            title: 'Settings',
            large: true,
            grouped: true,
            render(c, ctx) {
                const draw = () => {
                    const s = Phone.settings, p = Phone.profile || {};
                    c.innerHTML = `
                        <div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search"></div>
                        <div class="group"><div class="row tap" data-s="account" style="padding:12px 16px">
                            ${avatar(p.name, null, 'lg')}
                            <div class="grow"><div class="title" style="font-size:20px">${esc(p.name || '')}</div><div class="sub" style="font-size:13px">${esc(p.number || '')} · ${esc(p.email || '')}</div></div>
                            <i class="fa-solid fa-chevron-right chev"></i></div></div>
                        ${typeof Buds !== 'undefined' ? Buds.settingsRow() : ''}
                        <div class="group">
                            ${sRow('airplane', 'Airplane Mode', { toggle: !!s.airplane })}
                            ${sRow('wifi', 'Wi-Fi', { value: s.airplane ? 'Off' : (typeof Network !== 'undefined' && Network.active ? (Network.wifi ? Network.wifi.ssid : 'Not Connected') : 'LS-Public') })}
                            ${sRow('bluetooth', 'Bluetooth', { value: s.bluetooth === false ? 'Off' : (typeof Buds !== 'undefined' && Buds.connected ? Buds.name() : 'On') })}
                            ${sRow('cellular', 'Mobile Service', { value: s.airplane ? 'Airplane Mode' : (typeof CarrierState !== 'undefined' && CarrierState.enabled() ? (CarrierState.service() ? CarrierState.name() : 'No Service') : '') })}
                        </div>
                        <div class="group">
                            ${sRow('notifications', 'Notifications')}
                            ${sRow('sounds', 'Sounds & Haptics')}
                            ${sRow('focus', 'Focus', { value: s.dnd ? 'On' : '' })}
                        </div>
                        <div class="group">
                            ${sRow('general', 'General')}
                            ${sRow('language', 'Language & Region', { value: (LANGUAGES.find((l) => l.id === (s.language || 'en')) || LANGUAGES[0]).native })}
                            ${sRow('units', 'Units & Formats', { value: `${tempSym()} · ${unit('distance') === 'km' ? 'km' : 'mi'}` })}
                            ${sRow('performance', 'Performance', { value: I18N.t((Perf.PRESETS[Perf.current()] || Perf.PRESETS.ultra).label) })}
                            ${sRow('accessibility', 'Accessibility')}
                            ${sRow('display', 'Display & Brightness')}
                            ${sRow('wallpaper', 'Wallpaper')}
                            ${sRow('faceid', 'Face Unlock & Passcode')}
                            ${sRow('battery', 'Battery')}
                        </div>`;
                };
                draw();
                c.addEventListener('click', (e) => {
                    const r = e.target.closest('[data-s]');
                    if (!r || e.target.closest('.switch')) return;
                    const page = SettingsPages[r.dataset.s];
                    if (page) page(nav);
                });
                c.addEventListener('change', (e) => {
                    if (e.target.dataset.toggle === 'airplane') {
                        Phone.saveSetting('airplane', e.target.checked);
                        draw();
                    }
                });
                c.addEventListener('input', (e) => {
                    if (!e.target.closest('.search')) return;
                    const q = e.target.value.toLowerCase();
                    $$('.row[data-s]', c).forEach((r) => { r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none'; });
                });
                ctx.opts.onResume = draw;
            },
        });
    },
});
