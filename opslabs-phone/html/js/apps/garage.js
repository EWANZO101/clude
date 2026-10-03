'use strict';

function statBar(label, value, max, color) {
    const pct = value == null ? null : Math.max(0, Math.min(100, (value / max) * 100));
    return `<div class="gv-stat"><span>${label}</span><div class="gv-bar"><i style="width:${pct ?? 0}%;background:${color}"></i></div><b>${pct == null ? '—' : Math.round(pct) + '%'}</b></div>`;
}

Apps.register({
    id: 'garage',
    name: 'Garage',
    icon: { bg: 'linear-gradient(180deg,#3d4b63,#1b2333)', glyph: 'fa-solid fa-car-side', size: 28 },
    open(root) {
        const nav = new Nav(root);
        nav.push({
            title: 'My Vehicles',
            large: true,
            grouped: true,
            render(content) {
                content.innerHTML = '<div class="spinner"></div>';
                (async () => {
                    const vehicles = (await rpc('getVehicles')) || [];
                    const models = [...new Set(vehicles.map((v) => v.model).filter((m) => m != null).map((m) => Math.trunc(m)))];
                    const labels = models.length ? (await nui('vehicleLabels', { models })) || {} : {};
                    if (!vehicles.length) { content.innerHTML = UI.empty('fa-solid fa-car', 'No Vehicles', 'Vehicles you own will show up here.'); return; }
                    content.innerHTML = vehicles.map((v) => {
                        const l = labels[String(Math.trunc(v.model))] || {};
                        const name = v.name || l.name || 'Vehicle';
                        const status = v.pound ? ['Impounded', '#ff3b30', 'fa-triangle-exclamation'] : v.stored ? ['In Garage', '#34c759', 'fa-warehouse'] : ['Out', '#ff9500', 'fa-road'];
                        const icon = v.type === 'boat' ? 'fa-ship' : v.type === 'aircraft' || v.type === 'heli' ? 'fa-helicopter' : 'fa-car-side';
                        return `<div class="group garage-card">
                            <div class="gv-head">
                                <div class="gv-icon"><i class="fa-solid ${icon}"></i></div>
                                <div class="grow"><div class="gv-name">${esc(name)}</div><div class="muted" style="font-size:14px">${esc(l.make || '')} ${l.make ? '·' : ''} <span class="gv-plate">${esc(v.plate)}</span></div></div>
                                <span class="gv-status" style="color:${status[1]}"><i class="fa-solid ${status[2]}"></i> ${status[0]}</span>
                            </div>
                            ${v.parking || v.pound ? `<div class="gv-loc"><i class="fa-solid fa-location-dot"></i> ${esc(v.pound || v.parking)}</div>` : ''}
                            ${statBar('Fuel', v.fuel, 100, '#34c759')}
                            ${statBar('Engine', v.engine, 1000, '#007aff')}
                            ${statBar('Body', v.body, 1000, '#5856d6')}
                            ${v.mileage ? `<div class="gv-loc" style="margin-top:6px"><i class="fa-solid fa-gauge"></i> ${Number(unit('distance') === 'km' ? v.mileage * 1.609 : v.mileage).toLocaleString(Phone.locale, { maximumFractionDigits: 1 })} ${unit('distance') === 'km' ? 'km' : 'mi'}</div>` : ''}
                        </div>`;
                    }).join('');
                })();
            },
        });
    },
});
