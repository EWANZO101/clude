'use strict';

/* Global clock state survives closing the app (like a real phone) */
const ClockState = {
    stopwatch: { running: false, start: 0, elapsed: 0, laps: [] },
    timer: { running: false, end: 0, remaining: 0, total: 0, paused: false },
};

const CITIES = [
    ['Los Angeles', 'America/Los_Angeles'], ['New York', 'America/New_York'], ['London', 'Europe/London'],
    ['Paris', 'Europe/Paris'], ['Berlin', 'Europe/Berlin'], ['Dubai', 'Asia/Dubai'], ['Tokyo', 'Asia/Tokyo'],
    ['Sydney', 'Australia/Sydney'], ['Chicago', 'America/Chicago'], ['Honolulu', 'Pacific/Honolulu'],
    ['São Paulo', 'America/Sao_Paulo'], ['Moscow', 'Europe/Moscow'], ['Mumbai', 'Asia/Kolkata'],
    ['Singapore', 'Asia/Singapore'], ['Amsterdam', 'Europe/Amsterdam'], ['Mexico City', 'America/Mexico_City'],
];

function tzOffsetHours(tz) {
    const now = new Date();
    const local = new Date(now.toLocaleString(Phone.locale));
    const there = new Date(now.toLocaleString(Phone.locale, { timeZone: tz }));
    return Math.round((there - local) / 3600000);
}

function analogClock(size, date = new Date(), dark = false) {
    const h = date.getHours() % 12, m = date.getMinutes(), s = date.getSeconds();
    const ha = (h + m / 60) * 30, ma = m * 6;
    const fg = dark ? '#fff' : '#000';
    const ticks = Array.from({ length: 12 }, (_, i) => `<line x1="32" y1="5" x2="32" y2="${i % 3 ? 8 : 10}" stroke="${fg}" stroke-width="${i % 3 ? 1.4 : 2.2}" transform="rotate(${i * 30} 32 32)"/>`).join('');
    const nums = Array.from({ length: 12 }, (_, i) => {
        const a = ((i + 1) * 30 - 90) * Math.PI / 180;
        return `<text x="${32 + Math.cos(a) * 20.5}" y="${32 + Math.sin(a) * 20.5 + 3}" font-size="8" font-weight="500" text-anchor="middle" fill="${fg}" font-family="Inter,sans-serif">${i + 1}</text>`;
    }).join('');
    return `<svg viewBox="0 0 64 64" width="${size}" height="${size}">
        <circle cx="32" cy="32" r="30" fill="${dark ? '#1c1c1e' : '#fff'}"/>${size > 60 ? ticks : ''}${nums}
        <line x1="32" y1="32" x2="32" y2="17" stroke="${fg}" stroke-width="3" stroke-linecap="round" transform="rotate(${ha} 32 32)"/>
        <line x1="32" y1="32" x2="32" y2="9" stroke="${fg}" stroke-width="2.2" stroke-linecap="round" transform="rotate(${ma} 32 32)"/>
        <g class="clock-sec" style="animation-delay:-${s}s"><line x1="32" y1="38" x2="32" y2="8" stroke="#ff9500" stroke-width="1.1" stroke-linecap="round"/></g>
        <circle cx="32" cy="32" r="2" fill="#ff9500"/></svg>`;
}

function WorldClockTab(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: 'World Clock',
        large: true,
        tabbar: true,
        left: '<button class="nav-btn" data-act="edit" style="padding-left:8px">Edit</button>',
        right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
        render(content, ctx) {
            let editing = false;
            const list = () => Phone.settings.worldClocks || ['America/Los_Angeles', 'America/New_York', 'Europe/London', 'Asia/Tokyo'];
            const draw = () => {
                content.innerHTML = `<div class="plain">${list().map((tz) => {
                    const city = (CITIES.find((c) => c[1] === tz) || [tz.split('/').pop().replace('_', ' ')])[0];
                    const off = tzOffsetHours(tz);
                    const d = new Date(new Date().toLocaleString(Phone.locale, { timeZone: tz }));
                    const today = new Date();
                    const day = d.getDate() === today.getDate() ? 'Today' : d > today ? 'Tomorrow' : 'Yesterday';
                    return `<div class="row wc-row">
                        ${editing ? `<button data-del="${tz}" style="color:var(--red);font-size:22px"><i class="fa-solid fa-circle-minus"></i></button>` : ''}
                        <div class="grow"><div class="muted" style="font-size:14px">${day}, ${off >= 0 ? '+' : ''}${off}HRS</div><div style="font-size:24px">${esc(city)}</div></div>
                        <div class="wc-time">${d.toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP]M)/, '<small>$1</small>')}</div>
                    </div>`;
                }).join('')}</div>`;
            };
            draw();
            ctx.nav.host.addEventListener('click', async (e) => {
                const del = e.target.closest('[data-del]');
                if (del) { Phone.saveSetting('worldClocks', list().filter((t) => t !== del.dataset.del)); return draw(); }
                const a = e.target.closest('[data-act]');
                if (!a) return;
                if (a.dataset.act === 'edit') { editing = !editing; a.textContent = editing ? 'Done' : 'Edit'; draw(); }
                if (a.dataset.act === 'add') {
                    const opts = CITIES.filter((c) => !list().includes(c[1]));
                    UI.sheet({
                        title: 'Choose a City',
                        render(body, api) {
                            body.innerHTML = `<div class="plain">${opts.map((c) => `<div class="row tap" data-tz="${c[1]}">${esc(c[0])}</div>`).join('')}</div>`;
                            body.addEventListener('click', (ev) => {
                                const r = ev.target.closest('[data-tz]');
                                if (!r) return;
                                Phone.saveSetting('worldClocks', [...list(), r.dataset.tz]);
                                api.close(); draw();
                            });
                        },
                    });
                }
            });
            const iv = setInterval(() => { if (!document.body.contains(content)) return clearInterval(iv); if (!editing) draw(); }, 10000);
        },
    });
}

function AlarmsTab(host) {
    const nav = new Nav(host);
    host._nav = nav;
    nav.push({
        title: 'Alarms',
        large: true,
        tabbar: true,
        right: '<button class="nav-btn" data-act="add"><i class="fa-solid fa-plus"></i></button>',
        render(content, ctx) {
            const alarms = () => Phone.settings.alarms || [];
            const draw = () => {
                const list = alarms().slice().sort((a, b) => a.h * 60 + a.m - (b.h * 60 + b.m));
                content.innerHTML = `
                    <div class="group-header big" style="margin-top:6px"><i class="fa-solid fa-bed"></i> Sleep | Wake Up</div>
                    <div class="plain"><div class="row muted" style="font-size:15px">No Alarm <span style="flex:1"></span><button class="btn small gray">SET UP</button></div></div>
                    <div class="group-header big" style="margin-top:18px">Other</div>
                    <div class="plain">${list.map((a) => {
                        const d = new Date(); d.setHours(a.h, a.m);
                        const [t, ap] = d.toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' }).split(' ');
                        return `<div class="row alarm-row ${a.enabled ? '' : 'off'}" data-id="${a.id}">
                            <div class="grow tap" data-edit="${a.id}"><div class="al-time">${t}<small>${ap}</small></div><div style="font-size:15px">${esc(a.label || 'Alarm')}</div></div>
                            ${UI.switchHtml(a.enabled, `data-toggle="${a.id}"`)}
                        </div>`;
                    }).join('') || '<div class="row muted">No alarms</div>'}</div>`;
            };
            const save = (list) => { Phone.saveSetting('alarms', list); draw(); };
            const edit = (alarm) => {
                const isNew = !alarm;
                alarm = alarm || { id: Date.now(), h: new Date().getHours(), m: new Date().getMinutes(), label: 'Alarm', enabled: true };
                UI.sheet({
                    title: isNew ? 'Add Alarm' : 'Edit Alarm',
                    right: 'Save',
                    render(body) {
                        body.innerHTML = `
                            <div style="display:flex;justify-content:center;padding:20px 0 30px">
                                <input type="time" class="time-input" value="${String(alarm.h).padStart(2, '0')}:${String(alarm.m).padStart(2, '0')}">
                            </div>
                            <div class="group">
                                <div class="row"><span class="lbl">Label</span><input class="field" data-f="label" value="${esc(alarm.label)}" style="text-align:right"></div>
                                <div class="row"><span class="lbl">Sound</span><span class="grow"></span><span class="value">Radar</span><i class="fa-solid fa-chevron-right chev"></i></div>
                            </div>
                            ${isNew ? '' : '<div class="group"><div class="row tap destructive" data-act="del">Delete Alarm</div></div>'}`;
                        body.addEventListener('click', (e) => {
                            if (e.target.closest('[data-act=del]')) {
                                save(alarms().filter((a) => a.id !== alarm.id));
                                $$('.sheet .nav-btn')[0].click();
                            }
                        });
                    },
                    onRight(api) {
                        const [h, m] = $('.time-input', api.body).value.split(':').map(Number);
                        const next = { ...alarm, h, m, label: $('[data-f=label]', api.body).value || 'Alarm', enabled: true };
                        save([...alarms().filter((a) => a.id !== alarm.id), next]);
                        api.close();
                    },
                });
            };
            draw();
            content.addEventListener('change', (e) => {
                const t = e.target.closest('[data-toggle]');
                if (t) save(alarms().map((a) => (a.id === +t.dataset.toggle ? { ...a, enabled: t.checked } : a)));
            });
            content.addEventListener('click', (e) => {
                const r = e.target.closest('[data-edit]');
                if (r) edit(alarms().find((a) => a.id === +r.dataset.edit));
            });
            $('[data-act=add]', ctx.page).onclick = () => edit(null);
        },
    });
}

function StopwatchTab(host) {
    const sw = ClockState.stopwatch;
    host.innerHTML = `
        <div class="sw">
            <div class="sw-time">00:00,00</div>
            <div class="sw-buttons">
                <button class="round-btn gray" data-act="lap">Lap</button>
                <span class="sw-dots"><i class="on"></i><i></i></span>
                <button class="round-btn green" data-act="start">Start</button>
            </div>
            <div class="sw-laps plain scroll"></div>
        </div>`;
    const fmtSw = (ms) => {
        const m = Math.floor(ms / 60000), s = Math.floor((ms % 60000) / 1000), cs = Math.floor((ms % 1000) / 10);
        return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')},${String(cs).padStart(2, '0')}`;
    };
    const total = () => sw.elapsed + (sw.running ? Date.now() - sw.start : 0);
    const draw = () => {
        $('.sw-time', host).textContent = fmtSw(total());
        const lapBtn = $('[data-act=lap]', host), st = $('[data-act=start]', host);
        st.textContent = sw.running ? 'Stop' : 'Start';
        st.className = 'round-btn ' + (sw.running ? 'red' : 'green');
        lapBtn.textContent = sw.running || !total() ? 'Lap' : 'Reset';
        lapBtn.classList.toggle('dim', !sw.running && !total());
        const laps = sw.laps;
        const cur = total() - laps.reduce((a, b) => a + b, 0);
        const all = [...laps, cur];
        const done = laps.length > 1 ? laps : [];
        const min = done.length ? Math.min(...done) : -1, max = done.length ? Math.max(...done) : -1;
        $('.sw-laps', host).innerHTML = total() ? all.map((l, i) => i).reverse().map((i) => `
            <div class="row" style="${i < laps.length && all[i] === min ? 'color:#30d158' : i < laps.length && all[i] === max ? 'color:#ff453a' : ''}">
                <span class="grow">Lap ${i + 1}</span><span style="font-feature-settings:'tnum'">${fmtSw(all[i])}</span></div>`).join('') : '';
    };
    host.addEventListener('click', (e) => {
        const a = e.target.closest('[data-act]');
        if (!a) return;
        if (a.dataset.act === 'start') {
            if (sw.running) { sw.elapsed += Date.now() - sw.start; sw.running = false; }
            else { sw.start = Date.now(); sw.running = true; }
        } else if (a.dataset.act === 'lap') {
            if (sw.running) sw.laps.push(total() - sw.laps.reduce((x, y) => x + y, 0));
            else { sw.elapsed = 0; sw.laps = []; }
        }
        draw();
    });
    const loop = () => { if (!document.body.contains(host)) return; if (sw.running) draw(); requestAnimationFrame(loop); };
    draw();
    loop();
}

function TimerTab(host) {
    const t = ClockState.timer;
    const sel = (max, val, unit) => `<div class="tp-col"><select data-u="${unit}">${Array.from({ length: max }, (_, i) => `<option ${i === val ? 'selected' : ''}>${i}</option>`).join('')}</select><span>${unit}</span></div>`;
    const draw = () => {
        const active = t.running || t.paused;
        if (!active) {
            host.innerHTML = `
                <div class="timer">
                    <div class="tp">${sel(24, 0, 'hours')}${sel(60, 5, 'min')}${sel(60, 0, 'sec')}</div>
                    <div class="sw-buttons"><button class="round-btn gray dim">Cancel</button><button class="round-btn green" data-act="start">Start</button></div>
                    <div class="group" style="margin-top:30px"><div class="row"><span class="grow">When Timer Ends</span><span class="value">Radar</span><i class="fa-solid fa-chevron-right chev"></i></div></div>
                </div>`;
            return;
        }
        host.innerHTML = `
            <div class="timer">
                <div class="tm-ring"><svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="46" stroke="var(--fill)" stroke-width="3" fill="none"/>
                    <circle class="tm-prog" cx="50" cy="50" r="46" stroke="#ff9f0a" stroke-width="3" fill="none" stroke-linecap="round" stroke-dasharray="289" transform="rotate(-90 50 50)"/></svg>
                    <div class="tm-left"></div><div class="tm-end"><i class="fa-solid fa-bell"></i> ${new Date(t.running ? t.end : Date.now() + t.remaining).toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' })}</div></div>
                <div class="sw-buttons"><button class="round-btn gray" data-act="cancel">Cancel</button>
                    <button class="round-btn ${t.running ? 'orange' : 'green'}" data-act="pause">${t.running ? 'Pause' : 'Resume'}</button></div>
            </div>`;
        tickTimer();
    };
    const tickTimer = () => {
        const left = t.running ? Math.max(0, t.end - Date.now()) : t.remaining;
        const lt = $('.tm-left', host);
        if (!lt) return;
        lt.textContent = fmtDuration(Math.ceil(left / 1000));
        $('.tm-prog', host).style.strokeDashoffset = String(289 * (1 - left / t.total));
        if (t.running && left <= 0) draw();
    };
    host.addEventListener('click', (e) => {
        const a = e.target.closest('[data-act]');
        if (!a) return;
        if (a.dataset.act === 'start') {
            const v = (u) => +$(`[data-u=${u}]`, host).value;
            const ms = (v('hours') * 3600 + v('min') * 60 + v('sec')) * 1000;
            if (!ms) return;
            Object.assign(t, { running: true, paused: false, total: ms, end: Date.now() + ms });
        } else if (a.dataset.act === 'cancel') {
            Object.assign(t, { running: false, paused: false });
        } else if (a.dataset.act === 'pause') {
            if (t.running) Object.assign(t, { running: false, paused: true, remaining: t.end - Date.now() });
            else Object.assign(t, { running: true, paused: false, end: Date.now() + t.remaining });
        }
        draw();
    });
    const iv = setInterval(() => { if (!document.body.contains(host)) return clearInterval(iv); tickTimer(); if (!t.running && !t.paused && $('.tm-left', host)) draw(); }, 250);
    draw();
}

// alarms + timer fire even when the app is closed
let lastAlarmMinute = '';
Phone.on('tick', (now) => {
    const t = ClockState.timer;
    if (t.running && Date.now() >= t.end) {
        t.running = false;
        Sound.play('alarm');
        Phone.vibrate();
        Phone.notify({ app: 'clock', title: 'Timer', body: 'Timer Done' });
    }
    const key = now.getHours() + ':' + now.getMinutes();
    if (key === lastAlarmMinute) return;
    lastAlarmMinute = key;
    (Phone.settings.alarms || []).forEach((a) => {
        if (a.enabled && a.h === now.getHours() && a.m === now.getMinutes()) {
            Sound.play('alarm');
            setTimeout(() => Sound.play('alarm'), 2200);
            Phone.vibrate();
            Phone.notify({ app: 'clock', title: 'Alarm', body: a.label || 'Alarm' });
            if (Phone.state === 'hidden') Phone.peek(8000);
        }
    });
});

Apps.register({
    id: 'clock',
    resumable: false, // live loops: restart fresh instead of resuming
    name: 'Clock',
    icon: {
        bg: '#000',
        html: () => analogClock(56),
    },
    open(root, params) {
        TabBar(root, [
            { id: 'world', label: 'World Clock', icon: 'fa-solid fa-globe', render: (h) => WorldClockTab(h) },
            { id: 'alarms', label: 'Alarms', icon: 'fa-solid fa-clock', render: (h) => AlarmsTab(h) },
            { id: 'stopwatch', label: 'Stopwatch', icon: 'fa-solid fa-stopwatch', render: (h) => StopwatchTab(h) },
            { id: 'timer', label: 'Timers', icon: 'fa-solid fa-hourglass-half', render: (h) => TimerTab(h) },
        ], params.tab || 'world');
    },
});
