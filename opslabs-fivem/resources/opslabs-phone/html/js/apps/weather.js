'use strict';

/*
 * Weather: the current condition comes from the game (GetPrevWeatherTypeHashName).
 * Temperatures and the forecast are generated deterministically per day so
 * every player sees the same numbers.
 */
const WeatherModel = {
    TYPES: {
        sunny:    { label: 'Sunny',          icon: 'fa-sun',              base: 82, bg: ['#2f80d1', '#69b3ef'] },
        clear:    { label: 'Clear',          icon: 'fa-sun',              base: 76, bg: ['#3a8dde', '#79bdf2'] },
        clearing: { label: 'Partly Cloudy',  icon: 'fa-cloud-sun',        base: 72, bg: ['#4b88c9', '#8cb9e3'] },
        cloudy:   { label: 'Cloudy',         icon: 'fa-cloud',            base: 68, bg: ['#5d7896', '#93a8bf'] },
        overcast: { label: 'Overcast',       icon: 'fa-cloud',            base: 64, bg: ['#58687a', '#8a98a8'] },
        rain:     { label: 'Rain',           icon: 'fa-cloud-showers-heavy', base: 60, bg: ['#3e4b5a', '#6d7d8e'] },
        thunder:  { label: 'Thunderstorms',  icon: 'fa-cloud-bolt',       base: 62, bg: ['#262f3d', '#505d70'] },
        smog:     { label: 'Haze',           icon: 'fa-smog',             base: 74, bg: ['#7f7a6c', '#b2ab97'] },
        fog:      { label: 'Fog',            icon: 'fa-smog',             base: 58, bg: ['#6f7a85', '#a3adb6'] },
        snow:     { label: 'Snow',           icon: 'fa-snowflake',        base: 30, bg: ['#7d93ad', '#b8c7d9'] },
        blizzard: { label: 'Blizzard',       icon: 'fa-snowflake',        base: 22, bg: ['#6a7f97', '#a9b9cb'] },
        halloween:{ label: 'Spooky',         icon: 'fa-ghost',            base: 55, bg: ['#2a1a3d', '#5b3f75'] },
    },
    seedFor(dayOffset = 0) {
        const d = new Date(); d.setDate(d.getDate() + dayOffset);
        return d.getFullYear() * 1000 + d.getMonth() * 40 + d.getDate();
    },
    isNight(world) {
        const h = world && typeof world.hour === 'number' ? world.hour : new Date().getHours();
        return h < 6 || h >= 20;
    },
    current(world = {}) {
        const type = this.TYPES[world.weather] ? world.weather : 'clear';
        const t = this.TYPES[type];
        const r = seeded(this.seedFor());
        const hi = Math.round(t.base + r() * 8);
        const lo = hi - 10 - Math.round(r() * 6);
        const hour = typeof world.hour === 'number' ? world.hour : new Date().getHours();
        const curve = Math.sin(((hour - 8) / 24) * Math.PI * 2) * 0.5 + 0.5;
        const night = this.isNight(world);
        return {
            type, ...t, hi: tempFromF(hi), lo: tempFromF(lo), loF: lo,
            temp: tempFromF(lo + (hi - lo) * curve),
            icon: night && (type === 'clear' || type === 'sunny') ? 'fa-moon' : night && type === 'clearing' ? 'fa-cloud-moon' : t.icon,
            cls: night ? 'night' : ['rain', 'thunder', 'overcast', 'fog'].includes(type) ? 'rain' : '',
            night,
        };
    },
    hourly(world = {}) {
        const cur = this.current(world);
        const h0 = typeof world.hour === 'number' ? world.hour : new Date().getHours();
        return Array.from({ length: 24 }, (_, i) => {
            const h = (h0 + i) % 24;
            const curve = Math.sin(((h - 8) / 24) * Math.PI * 2) * 0.5 + 0.5;
            const night = h < 6 || h >= 20;
            let icon = cur.icon;
            if (['clear', 'sunny'].includes(cur.type)) icon = night ? 'fa-moon' : 'fa-sun';
            const d = new Date(); d.setHours(h, 0, 0, 0);
            const label = i === 0 ? 'Now' : d.toLocaleTimeString(Phone.locale, { hour: 'numeric' });
            return { label, temp: Math.round(cur.lo + (cur.hi - cur.lo) * curve), icon };
        });
    },
    daily() {
        const keys = ['sunny', 'clear', 'clearing', 'cloudy', 'clear', 'rain', 'sunny', 'clearing', 'overcast', 'clear'];
        return Array.from({ length: 10 }, (_, i) => {
            const r = seeded(this.seedFor(i));
            const type = i === 0 ? this.current(Phone.world || {}).type : keys[Math.floor(r() * keys.length)];
            const t = this.TYPES[type];
            const hi = Math.round(t.base + r() * 8), lo = hi - 10 - Math.round(r() * 6);
            const d = new Date(); d.setDate(d.getDate() + i);
            return { label: i === 0 ? 'Today' : d.toLocaleDateString(Phone.locale, { weekday: 'short' }), icon: t.icon, hi: tempFromF(hi), lo: tempFromF(lo), rain: ['rain', 'thunder'].includes(type) ? 40 + Math.round(r() * 50) : 0 };
        });
    },
};

Apps.register({
    id: 'weather',
    name: 'Weather',
    dark: true,
    icon: {
        bg: 'linear-gradient(180deg,#1b74e4,#5cb0f7)',
        html: () => `<i class="fa-solid fa-sun" style="position:absolute;left:12px;top:12px;font-size:24px;color:#ffd60a"></i><i class="fa-solid fa-cloud" style="position:absolute;left:20px;top:24px;font-size:28px;color:#fff"></i>`,
    },
    async open(root) {
        const world = (await nui('getWorld')) || Phone.world || {};
        Phone.world = world;
        const cur = WeatherModel.current(world);
        const hourly = WeatherModel.hourly(world);
        const daily = WeatherModel.daily();
        const minAll = Math.min(...daily.map((d) => d.lo)), maxAll = Math.max(...daily.map((d) => d.hi));
        const bg = cur.night ? ['#0b1430', '#2b3c6b'] : cur.bg;
        root.innerHTML = `
            <div class="weather scroll" style="background:linear-gradient(180deg,${bg[0]},${bg[1]})">
                ${cur.type === 'rain' || cur.type === 'thunder' ? '<div class="wx-rain"></div>' : ''}
                <div class="wx-head">
                    <div class="wx-loc">My Location</div>
                    <div class="wx-city">${esc(world.zone || 'Los Santos')}</div>
                    <div class="wx-temp">${cur.temp}°</div>
                    <div class="wx-cond" data-no-i18n>${esc(I18N.weather(cur.label))}</div>
                    <div class="wx-hl">H:${cur.hi}°  L:${cur.lo}°</div>
                </div>
                <div class="wx-card">
                    <div class="wx-card-desc" data-no-i18n>${esc(I18N.weather(cur.label))} conditions expected around ${new Date(Date.now() + 7200000).toLocaleTimeString(Phone.locale, { hour: 'numeric' })}. Wind gusts are up to ${fmtSpeed(seeded(WeatherModel.seedFor())() * 15 + 5)}.</div>
                    <div class="wx-hours">${hourly.map((h) => `<div><span>${h.label}</span><i class="fa-solid ${h.icon}"></i><b>${h.temp}°</b></div>`).join('')}</div>
                </div>
                <div class="wx-card">
                    <div class="wx-card-title"><i class="fa-regular fa-calendar"></i> 10-DAY FORECAST</div>
                    ${daily.map((d) => {
                        const l = ((d.lo - minAll) / (maxAll - minAll || 1)) * 100;
                        const w = ((d.hi - d.lo) / (maxAll - minAll || 1)) * 100;
                        return `<div class="wx-day">
                            <span class="wd-label">${d.label}</span>
                            <span class="wd-icon"><i class="fa-solid ${d.icon}"></i>${d.rain ? `<small>${d.rain}%</small>` : ''}</span>
                            <span class="wd-lo">${d.lo}°</span>
                            <span class="wd-bar"><i style="left:${l}%;width:${w}%"></i></span>
                            <span class="wd-hi">${d.hi}°</span>
                        </div>`;
                    }).join('')}
                </div>
                <div class="wx-grid">
                    <div class="wx-card"><div class="wx-card-title"><i class="fa-solid fa-sun"></i> UV INDEX</div><div class="wx-big">${cur.night ? 0 : Math.round(cur.temp / 12)}</div><div>${cur.night ? 'Low' : cur.temp > 80 ? 'High' : 'Moderate'}</div></div>
                    <div class="wx-card"><div class="wx-card-title"><i class="fa-solid fa-droplet"></i> HUMIDITY</div><div class="wx-big">${['rain', 'thunder', 'fog'].includes(cur.type) ? 88 : 46}%</div><div>The dew point is ${tempFromF(WeatherModel.current(world).loF - 6)}° right now.</div></div>
                    <div class="wx-card"><div class="wx-card-title"><i class="fa-solid fa-wind"></i> WIND</div><div class="wx-big">${speedNum(seeded(WeatherModel.seedFor() + 3)() * 14 + 3)}</div><div>${speedSym()} · W</div></div>
                    <div class="wx-card"><div class="wx-card-title"><i class="fa-solid fa-eye"></i> VISIBILITY</div><div class="wx-big">${esc(fmtDist(cur.type === 'fog' ? 1609.34 : 16093.4))}</div><div>${cur.type === 'fog' ? 'Fog is reducing visibility.' : 'Perfectly clear view.'}</div></div>
                </div>
                <div class="wx-foot"><i class="fa-solid fa-map"></i><span>Weather for ${esc(world.zone || 'Los Santos')}</span><i class="fa-solid fa-list-ul"></i></div>
            </div>`;
    },
});
