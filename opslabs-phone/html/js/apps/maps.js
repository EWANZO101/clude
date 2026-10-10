'use strict';

/* =====================================================================
   Maps
   A vector map of San Andreas drawn in real game coordinates (metres):
   coastline, lakes, hills, desert, towns, airports and highways.
   - smooth pan with momentum, wheel / double-click / button zoom
   - follow-me mode with heading, live friends, tappable pins + place card
   - bottom sheet with three heights, search, places and people
   ===================================================================== */

/* ---------------------------------------------------------------------
   world data (GTA V world coordinates, approximate)
   --------------------------------------------------------------------- */

const SA = {
    land: [
        [-1950, -3650], [-1350, -3780], [-700, -3700], [150, -3560], [820, -3420], [1330, -3360], [1560, -2960],
        [1520, -2520], [1900, -2240], [2520, -1900], [2860, -1420], [2980, -820], [3120, -260], [3350, 420],
        [3620, 1250], [3840, 2150], [3930, 3080], [3970, 3960], [3880, 4700], [3640, 5340], [3260, 5860],
        [2780, 6260], [2150, 6480], [1500, 6620], [880, 6880], [380, 7180], [-120, 7020], [-380, 6680],
        [-780, 6380], [-1180, 5960], [-1560, 5460], [-1960, 4930], [-2380, 4380], [-2680, 3780], [-2840, 3180],
        [-2780, 2640], [-3060, 2180], [-3240, 1620], [-3280, 1020], [-3120, 460], [-2760, 80], [-2280, -220],
        [-1980, -560], [-1760, -940], [-1560, -1320], [-1520, -1700], [-1800, -2100], [-2050, -2550], [-2120, -3150],
    ],
    water: [
        // Alamo Sea
        [[240, 3980], [520, 3720], [960, 3600], [1420, 3660], [1860, 3760], [2240, 3900], [2520, 4180], [2460, 4500],
            [2140, 4680], [1660, 4760], [1140, 4720], [700, 4560], [380, 4320]],
        // Land Act Reservoir
        [[1660, 140], [1860, -40], [2120, 30], [2220, 260], [2080, 470], [1820, 470], [1680, 330]],
        // Mirror Park lake
        [[1040, -660], [1120, -720], [1200, -660], [1150, -590], [1060, -600]],
        // Lago Zancudo
        [[-2600, 2560], [-2280, 2480], [-1960, 2580], [-1820, 2760], [-2060, 2860], [-2420, 2820]],
    ],
    desert: [[[880, 2460], [1600, 2300], [2500, 2420], [2980, 2800], [2900, 3400], [2380, 3560], [1500, 3420], [880, 3200]]],
    hills: [
        [500, 5600, 950], [2900, 5550, 620], [2450, -380, 720], [0, 1150, 880], [-500, 2550, 900],
        [-900, 5350, 780], [-300, 4300, 600], [2800, 3100, 520], [-2050, 1050, 650], [1150, 1700, 620],
    ],
    towns: [
        // Los Santos
        [[-1820, -1180], [-1160, -560], [-420, -260], [420, -260], [1080, -460], [1380, -760], [1420, -1500],
            [1260, -2160], [880, -2620], [120, -2820], [-560, -2620], [-1080, -2260], [-1540, -1760]],
        [[1560, 3540], [2120, 3540], [2140, 3860], [1600, 3880]],                   // Sandy Shores
        [[-460, 5980], [260, 6020], [300, 6620], [-380, 6560]],                     // Paleto Bay
        [[1600, 4640], [2580, 4620], [2620, 5160], [1640, 5180]],                   // Grapeseed
        [[-3220, 760], [-2980, 760], [-2980, 1260], [-3200, 1260]],                 // Chumash
        [[150, 2560], [600, 2560], [620, 2780], [160, 2800]],                       // Harmony
    ],
    airports: [
        { rect: [-1960, -3520, -840, -2300], runways: [[[-1800, -3300], [-1000, -2500]], [[-1700, -2600], [-1100, -3200]]] },   // LSIA
        { rect: [-2780, 2900, -1840, 3520], runways: [[[-2700, 3100], [-1920, 3300]]] },                                         // Fort Zancudo
        { rect: [1060, 3020, 1820, 3320], runways: [[[1100, 3100], [1780, 3240]]] },                                             // Sandy airfield
    ],
    highways: [
        // Great Ocean Highway (west + north coast)
        [[-1620, -560], [-2280, -120], [-2900, 420], [-3120, 1100], [-2960, 1900], [-2640, 2600], [-2440, 3360],
            [-2120, 4220], [-1480, 5000], [-760, 5880], [-120, 6380], [700, 6480], [1600, 6380], [2440, 6060], [2700, 5400]],
        // Senora Freeway (east)
        [[1340, -880], [1900, -300], [2420, 600], [2560, 1700], [2400, 2700], [2160, 3400], [2380, 4300],
            [2700, 4900], [2700, 5400]],
        // Route 68
        [[-2620, 2620], [-1500, 2700], [-600, 2900], [300, 2700], [1100, 2680], [1700, 3000], [1960, 3500]],
        // Los Santos freeways
        [[-1620, -560], [-700, -720], [300, -900], [1340, -880]],
        [[-1000, -1300], [-200, -1560], [600, -1500], [1300, -1300]],
        [[600, -1500], [560, -2400], [420, -3200]],
        [[-700, -720], [-860, -1600], [-1050, -2300]],
        [[300, -900], [800, 0], [1500, 700], [2300, 1300], [2560, 1700]],
    ],
    roads: [
        [[-200, -900], [200, 300], [400, 1300]],
        [[-1100, -600], [-1500, 200], [-2200, 600]],
        [[1960, 3500], [2400, 3500], [3200, 3700]],
        [[1700, 3000], [1200, 2200], [800, 1500], [300, 900]],
        [[-120, 6380], [-300, 5400], [-200, 4300], [100, 3200], [300, 2700]],
        [[2160, 3400], [1600, 4100], [1700, 4900]],
    ],
    labels: [
        ['Los Santos', -200, -1500, 'city'], ['Sandy Shores', 1850, 3700, 'town'], ['Paleto Bay', -100, 6300, 'town'],
        ['Grapeseed', 2100, 4900, 'town'], ['Alamo Sea', 1400, 4180, 'water'], ['Mount Chiliad', 500, 5600, 'hill'],
        ['Mount Gordo', 2900, 5550, 'hill'], ['Vinewood Hills', 0, 1150, 'hill'], ['Grand Senora Desert', 1900, 2900, 'area'],
        ['Fort Zancudo', -2300, 3200, 'area'], ['LSIA', -1400, -2900, 'area'], ['Chumash', -3100, 1000, 'town'],
        ['Pacific Ocean', -3600, -1200, 'water'], ['Harmony', 380, 2680, 'town'], ['Tataviam Mtns', 2450, -380, 'hill'],
    ],
};

const MAP_STYLES = {
    standard: { sea: '#a9d3ec', land: '#f2efe8', hill: 'rgba(160,205,140,.55)', desert: '#efe2c4', town: '#e6e2da', airport: '#dcd8d0',
        runway: '#bdb8b0', hwy: '#ffcd4a', hwyCase: '#e8a63a', road: '#ffffff', roadCase: '#d8d4cc', grid: 'rgba(255,255,255,.9)',
        label: '#4a4a52', water: '#4f86b0', halo: 'rgba(255,255,255,.85)' },
    dark: { sea: '#17283a', land: '#2a2c30', hill: 'rgba(60,92,64,.6)', desert: '#3a3426', town: '#34363b', airport: '#3a3c41',
        runway: '#55575d', hwy: '#b98a2e', hwyCase: '#6e5420', road: '#4c4f55', roadCase: '#2f3135', grid: 'rgba(90,94,102,.9)',
        label: '#c7c7cc', water: '#7fa7cc', halo: 'rgba(0,0,0,.6)' },
};

/* world paths are built once and reused for every frame */
const MapPaths = (() => {
    const poly = (pts) => { const p = new Path2D(); pts.forEach(([x, y], i) => (i ? p.lineTo(x, y) : p.moveTo(x, y))); p.closePath(); return p; };
    const line = (pts) => { const p = new Path2D(); pts.forEach(([x, y], i) => (i ? p.lineTo(x, y) : p.moveTo(x, y))); return p; };
    const land = poly(SA.land);
    const water = new Path2D(); SA.water.forEach((w) => water.addPath(poly(w)));
    const desert = new Path2D(); SA.desert.forEach((d) => desert.addPath(poly(d)));
    const towns = new Path2D(); SA.towns.forEach((t) => towns.addPath(poly(t)));
    const hills = new Path2D(); SA.hills.forEach(([x, y, r]) => { const h = new Path2D(); h.ellipse(x, y, r, r * 0.8, 0, 0, Math.PI * 2); hills.addPath(h); });
    const airports = new Path2D(); const runways = new Path2D();
    SA.airports.forEach((a) => {
        const [x1, y1, x2, y2] = a.rect;
        const r = new Path2D(); r.rect(x1, y1, x2 - x1, y2 - y1); airports.addPath(r);
        a.runways.forEach((rw) => runways.addPath(line(rw)));
    });
    const hwy = new Path2D(); SA.highways.forEach((h) => hwy.addPath(line(h)));
    const roads = new Path2D(); SA.roads.forEach((r) => roads.addPath(line(r)));
    // Los Santos street grid (clipped to the city at draw time)
    const grid = new Path2D();
    for (let x = -1800; x <= 1400; x += 120) { grid.moveTo(x, -2800); grid.lineTo(x + 140, -200); }
    for (let y = -2800; y <= -200; y += 120) { grid.moveTo(-1900, y); grid.lineTo(1500, y - 60); }
    const city = poly(SA.towns[0]);
    return { land, water, desert, towns, hills, airports, runways, hwy, roads, grid, city };
})();

/* Font Awesome glyphs for canvas pins */
const GlyphCache = {};
function glyphFor(icon) {
    if (GlyphCache[icon] !== undefined) return GlyphCache[icon];
    const i = document.createElement('i');
    i.className = 'fa-solid ' + icon;
    i.style.cssText = 'position:absolute;left:-9999px';
    document.body.appendChild(i);
    const c = getComputedStyle(i, '::before').content;
    i.remove();
    return (GlyphCache[icon] = c && c !== 'none' ? c.replace(/["']/g, '') : '');
}

const CATEGORY_COLOR = {
    General: '#ff3b30', Business: '#af52de', 'Food & Drink': '#ff9500', Government: '#5856d6', Emergency: '#ff2d55',
    Vehicles: '#34c759', Leisure: '#30b0c7', Transport: '#007aff', Housing: '#a2845e',
};

/* ---------------------------------------------------------------------
   renderer (also used by the live-location card in Messages)
   view: { cx, cy, scale }  scale = CSS px per metre
   --------------------------------------------------------------------- */

const MapRender = {
    draw(canvas, view, opts = {}) {
        const ctx = canvas.getContext('2d');
        const k = canvas.width / (canvas.clientWidth || canvas.width / 2);
        const W = canvas.width, H = canvas.height;
        const st = MAP_STYLES[opts.style || 'standard'];
        const s = view.scale * k;
        const tx = W / 2 - view.cx * s, ty = H / 2 + view.cy * s;
        const px = 1 / s; // one device pixel in world units

        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.fillStyle = st.sea;
        ctx.fillRect(0, 0, W, H);

        ctx.setTransform(s, 0, 0, -s, tx, ty);
        ctx.fillStyle = st.land; ctx.fill(MapPaths.land);
        ctx.fillStyle = st.desert; ctx.fill(MapPaths.desert);
        ctx.fillStyle = st.hill; ctx.fill(MapPaths.hills);
        ctx.fillStyle = st.town; ctx.fill(MapPaths.towns);
        ctx.fillStyle = st.airport; ctx.fill(MapPaths.airports);
        ctx.fillStyle = st.sea; ctx.fill(MapPaths.water);

        ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        if (view.scale > 0.09) {
            ctx.save();
            ctx.clip(MapPaths.city);
            ctx.strokeStyle = st.grid; ctx.lineWidth = Math.max(1.2 * k * px, 4);
            ctx.stroke(MapPaths.grid);
            ctx.restore();
        }
        ctx.strokeStyle = st.runway; ctx.lineWidth = Math.max(5 * k * px, 45); ctx.stroke(MapPaths.runways);
        ctx.strokeStyle = st.roadCase; ctx.lineWidth = 4.2 * k * px; ctx.stroke(MapPaths.roads);
        ctx.strokeStyle = st.road; ctx.lineWidth = 2.6 * k * px; ctx.stroke(MapPaths.roads);
        ctx.strokeStyle = st.hwyCase; ctx.lineWidth = 5.4 * k * px; ctx.stroke(MapPaths.hwy);
        ctx.strokeStyle = st.hwy; ctx.lineWidth = 3.6 * k * px; ctx.stroke(MapPaths.hwy);

        // ---- screen-space layer
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        const toScreen = (x, y) => [x * s + tx, -y * s + ty];
        if (opts.labels !== false) this.drawAreaLabels(ctx, view, st, toScreen, k);
        (opts.markers || []).forEach((m) => this.drawMarker(ctx, m, toScreen, k, st));
        if (opts.me) this.drawMe(ctx, opts.me, toScreen, k);
        return toScreen;
    },

    drawAreaLabels(ctx, view, st, toScreen, k) {
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        SA.labels.forEach(([text, x, y, kind]) => {
            const show = kind === 'city' ? view.scale < 0.2 : kind === 'water' || kind === 'area' ? view.scale > 0.025 && view.scale < 0.35 : view.scale > 0.045 && view.scale < 0.5;
            if (!show) return;
            const [sx, sy] = toScreen(x, y);
            const size = (kind === 'city' ? 15 : kind === 'water' ? 12 : 11) * k;
            ctx.font = `${kind === 'water' ? 'italic 500' : kind === 'city' ? '700' : '600'} ${size}px Inter, sans-serif`;
            ctx.lineWidth = 3 * k; ctx.strokeStyle = st.halo;
            ctx.strokeText(text, sx, sy);
            ctx.fillStyle = kind === 'water' ? st.water : st.label;
            ctx.fillText(text, sx, sy);
        });
    },

    /** marker: { x, y, kind: 'place'|'person', color, icon, label, selected, showLabel } */
    drawMarker(ctx, m, toScreen, k, st) {
        const [sx, sy] = toScreen(m.x, m.y);
        m._sx = sx / k; m._sy = sy / k; // CSS px, for hit-testing
        const r = (m.selected ? 17 : 13) * k;
        if (m.kind === 'person') {
            ctx.beginPath(); ctx.arc(sx, sy, r * 1.9, 0, Math.PI * 2); ctx.fillStyle = 'rgba(52,199,89,.22)'; ctx.fill();
            ctx.beginPath(); ctx.arc(sx, sy, r, 0, Math.PI * 2); ctx.fillStyle = '#34c759'; ctx.fill();
            ctx.lineWidth = 3 * k; ctx.strokeStyle = '#fff'; ctx.stroke();
            ctx.fillStyle = '#fff'; ctx.font = `700 ${r * 0.8}px Inter, sans-serif`;
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillText(initials(m.label) || '•', sx, sy + k * 0.5);
        } else {
            ctx.save();
            ctx.shadowColor = 'rgba(0,0,0,.25)'; ctx.shadowBlur = 4 * k; ctx.shadowOffsetY = 1 * k;
            ctx.beginPath(); ctx.arc(sx, sy, r, 0, Math.PI * 2); ctx.fillStyle = m.color || '#ff3b30'; ctx.fill();
            ctx.restore();
            ctx.lineWidth = 2 * k; ctx.strokeStyle = '#fff'; ctx.stroke();
            const g = glyphFor(m.icon || 'fa-location-dot');
            if (g) {
                ctx.fillStyle = '#fff'; ctx.font = `900 ${r * 0.95}px "Font Awesome 6 Free"`;
                ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
                ctx.fillText(g, sx, sy + k * 0.5);
            }
        }
        if (m.showLabel) {
            ctx.font = `600 ${(m.selected ? 13 : 11.5) * k}px Inter, sans-serif`;
            ctx.textAlign = 'center'; ctx.textBaseline = 'top';
            ctx.lineWidth = 3 * k; ctx.strokeStyle = st.halo;
            ctx.strokeText(m.label, sx, sy + r + 3 * k);
            ctx.fillStyle = st.label; ctx.fillText(m.label, sx, sy + r + 3 * k);
        }
    },

    drawMe(ctx, me, toScreen, k) {
        const [sx, sy] = toScreen(me.x, me.y);
        if (typeof me.h === 'number') {
            ctx.save();
            ctx.translate(sx, sy);
            ctx.rotate((-me.h * Math.PI) / 180);
            const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 46 * k);
            g.addColorStop(0, 'rgba(0,122,255,.45)'); g.addColorStop(1, 'rgba(0,122,255,0)');
            ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, 46 * k, -Math.PI / 2 - 0.5, -Math.PI / 2 + 0.5); ctx.closePath();
            ctx.fillStyle = g; ctx.fill();
            ctx.restore();
        }
        ctx.beginPath(); ctx.arc(sx, sy, 22 * k, 0, Math.PI * 2); ctx.fillStyle = 'rgba(0,122,255,.16)'; ctx.fill();
        ctx.beginPath(); ctx.arc(sx, sy, 9 * k, 0, Math.PI * 2); ctx.fillStyle = '#007aff'; ctx.fill();
        ctx.lineWidth = 3 * k; ctx.strokeStyle = '#fff'; ctx.stroke();
    },
};

/** small static map (live-location card in Messages) */
function miniMap(canvas, x, y, zoom = 5) {
    MapRender.draw(canvas, { cx: x, cy: y, scale: 0.05 * zoom }, { style: Phone.settings.darkMode ? 'dark' : 'standard', labels: false });
}

/* ---------------------------------------------------------------------
   app
   --------------------------------------------------------------------- */

const SHEET = { peek: 132, half: 420, full: 740 };

Apps.register({
    id: 'maps',
    resumable: false, // live loops: restart fresh instead of resuming
    name: 'Maps',
    icon: {
        bg: 'linear-gradient(135deg,#7fd36e 0 38%,#f6f1e6 38% 62%,#8fc8f2 62%)',
        html: () => `<div style="position:absolute;left:-10px;right:-10px;top:30px;height:9px;background:#fff;transform:rotate(-38deg);box-shadow:0 0 0 1px rgba(0,0,0,.05)"></div>
            <div style="position:absolute;left:24px;top:8px;width:9px;height:60px;background:#ffcf4a;transform:rotate(22deg)"></div>
            <div style="position:absolute;right:10px;top:10px;width:24px;height:24px;border-radius:50%;background:#007aff;border:3px solid #fff;display:grid;place-items:center"><i class="fa-solid fa-location-arrow" style="font-size:11px;color:#fff"></i></div>`,
    },
    open(root, params, app) {
        root.innerHTML = `
            <div class="maps">
                <canvas class="map-canvas"></canvas>
                <div class="map-ctrls">
                    <button data-act="style" title="Map style"><i class="fa-solid fa-map"></i></button>
                    <button data-act="follow" title="My location"><i class="fa-regular fa-paper-plane"></i></button>
                </div>
                <div class="map-zoom"><button data-act="zin"><i class="fa-solid fa-plus"></i></button><button data-act="zout"><i class="fa-solid fa-minus"></i></button></div>
                <div class="map-sheet">
                    <div class="ms-handle"><div class="grabber"></div></div>
                    <div class="ms-search"><div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search Maps"><button class="ms-clear hidden"><i class="fa-solid fa-circle-xmark"></i></button></div></div>
                    <div class="ms-content scroll"></div>
                </div>
            </div>`;

        const canvas = $('.map-canvas', root);
        const sheet = $('.map-sheet', root);
        const content = $('.ms-content', root);
        const search = $('.ms-search input', root);
        const K = 2;
        canvas.width = 393 * K;
        canvas.height = 852 * K;

        // your homes (housing integration: Config.Integrations.housing) come first, then the city's places
        let homes = [];
        const allPlaces = () => [
            ...homes.map((h) => ({ name: h.label, icon: 'fa-house', color: '#ff9500', home: true, coords: { x: h.x, y: h.y, z: h.z },
                category: h.kind === 'key' ? 'Key holder' : h.kind === 'rented' ? 'Rented' : 'My Home' })),
            ...(Phone.config.places || []),
        ];
        let places = allPlaces();
        let me = Live.myPos || null;
        let style = Phone.settings.mapStyle || (Phone.settings.darkMode ? 'dark' : 'standard');
        let sheetH = SHEET.half;
        let follow = false;
        let selected = null;   // { type: 'place'|'person', id }
        let markers = [];
        let anim = null;
        let dragging = false;
        const view = { cx: 0, cy: 0, scale: 0.12 };
        const MIN_SCALE = 0.02, MAX_SCALE = 1.6;

        /* ---------- view helpers ---------- */
        const visibleCenterY = () => (54 + (852 - sheetH)) / 2;   // CSS px, middle of the uncovered map area
        const centerOffsetPx = () => visibleCenterY() - 852 / 2;

        const peopleList = () => Object.values(Live.incoming).filter((s) => s.x != null);
        const placeColor = (p) => p.color || CATEGORY_COLOR[p.category] || '#ff3b30';
        const isSel = (type, id) => !!selected && selected.type === type && selected.id === id;
        const buildMarkers = () => {
            const showLabels = view.scale > 0.07;
            markers = [
                ...places.map((p, i) => ({ kind: 'place', id: i, x: p.coords.x, y: p.coords.y, color: placeColor(p), icon: p.icon, label: p.name,
                    selected: isSel('place', i), showLabel: showLabels || isSel('place', i) })),
                ...peopleList().map((s) => ({ kind: 'person', id: s.id, x: s.x, y: s.y, label: s.name || Contacts.nameFor(s.number) || s.number,
                    selected: isSel('person', s.id), showLabel: true })),
            ];
            markers.sort((a, b) => (a.selected ? 1 : 0) - (b.selected ? 1 : 0)); // selected on top
        };

        let rafPending = false;
        const redraw = () => {
            if (rafPending) return;
            rafPending = true;
            requestAnimationFrame(() => {
                rafPending = false;
                buildMarkers();
                // shift the camera so (view.cx, view.cy) lands in the middle of the
                // uncovered map area above the sheet, not the middle of the screen
                const off = centerOffsetPx() / view.scale;
                MapRender.draw(canvas, { cx: view.cx, cy: view.cy + off, scale: view.scale }, { style, markers, me });
            });
        };

        const stopAnim = () => { if (anim) cancelAnimationFrame(anim.raf); anim = null; };
        /** smooth fly-to */
        const flyTo = (x, y, scale = view.scale, ms = 420) => {
            stopAnim();
            const from = { ...view }, t0 = performance.now();
            const ease = (t) => 1 - Math.pow(1 - t, 3);
            const step = (t) => {
                const p = Math.min(1, (t - t0) / ms), e = ease(p);
                view.cx = from.cx + (x - from.cx) * e;
                view.cy = from.cy + (y - from.cy) * e;
                view.scale = Math.exp(Math.log(from.scale) + (Math.log(scale) - Math.log(from.scale)) * e);
                redraw();
                anim = p < 1 ? { raf: requestAnimationFrame(step) } : null;
            };
            anim = { raf: requestAnimationFrame(step) };
        };
        const zoomAt = (factor, sx = 196.5, sy = visibleCenterY()) => {
            stopAnim();
            const next = Math.max(MIN_SCALE, Math.min(MAX_SCALE, view.scale * factor));
            // keep the world point under (sx, sy) fixed
            const wx = view.cx + (sx - 196.5) / view.scale;
            const wy = view.cy - (sy - visibleCenterY()) / view.scale;
            view.scale = next;
            view.cx = wx - (sx - 196.5) / view.scale;
            view.cy = wy + (sy - visibleCenterY()) / view.scale;
            redraw();
        };
        const setFollow = (on) => {
            follow = on;
            $('[data-act=follow] i', root).className = on ? 'fa-solid fa-location-arrow' : 'fa-regular fa-paper-plane';
            $('[data-act=follow]', root).classList.toggle('on', on);
            if (on && me) flyTo(me.x, me.y, Math.max(view.scale, 0.35));
        };

        /* ---------- sheet ---------- */
        const setSheet = (h, animate = true) => {
            sheetH = h;
            sheet.style.transition = animate ? '' : 'none';
            sheet.style.height = h + 'px';
            $('.map-zoom', root).style.bottom = (Math.min(h, SHEET.half) + 14) + 'px';
            $('.map-zoom', root).classList.toggle('hidden', h > SHEET.half + 40);
            sheet.classList.toggle('is-peek', h <= SHEET.peek);
            redraw();
        };
        const snapSheet = (h, v) => {
            const order = [SHEET.peek, SHEET.half, SHEET.full];
            let target = order.reduce((a, b) => (Math.abs(b - h) < Math.abs(a - h) ? b : a));
            if (v < -0.5) target = order.find((x) => x > sheetH) || SHEET.full;
            if (v > 0.5) target = [...order].reverse().find((x) => x < sheetH) || SHEET.peek;
            setSheet(target);
        };
        let sheetStart = 0;
        drag($('.ms-handle', sheet), {
            threshold: 2,
            onStart: () => { sheetStart = sheetH; return true; },
            onMove: (_dx, dy) => setSheet(Math.max(SHEET.peek - 20, Math.min(SHEET.full + 20, sheetStart - dy)), false),
            onEnd: (_dx, dy, vy, _vx, _e, moved) => {
                if (!moved) return setSheet(sheetH === SHEET.peek ? SHEET.half : sheetH === SHEET.half ? SHEET.full : SHEET.half);
                snapSheet(sheetStart - dy, vy);
            },
        });

        /* ---------- sheet content ---------- */
        const placeDist = (p) => (me ? Math.hypot(p.coords.x - me.x, p.coords.y - me.y) : null);
        const listView = () => {
            const q = search.value.trim().toLowerCase();
            const ps = places.map((p, i) => ({ p, i, d: placeDist(p) }))
                .filter(({ p }) => !q || (p.name + ' ' + (p.category || '')).toLowerCase().includes(q))
                .sort((a, b) => (a.d ?? 0) - (b.d ?? 0));
            const placeRow = ({ p, i, d }) => `
                    <div class="row tap has-icon" data-place="${i}">
                        <span class="ri" style="background:${placeColor(p)};border-radius:50%"><i class="fa-solid ${esc(p.icon || 'fa-location-dot')}"></i></span>
                        <div class="grow"><div class="title">${esc(p.name)}</div><div class="sub">${esc(p.category || 'Place')}${d != null ? ' · ' + esc(fmtDist(d)) : ''}</div></div>
                        <i class="fa-solid fa-chevron-right chev"></i></div>`;
            const myHomes = q ? [] : ps.filter(({ p }) => p.home);
            const rest = q ? ps : ps.filter(({ p }) => !p.home);
            const people = peopleList().filter((s) => !q || (s.name || s.number || '').toLowerCase().includes(q));
            const out = Object.values(Live.outgoing);
            content.innerHTML = `
                ${!q && me ? `<div class="group ms-here"><div class="row has-icon">
                    <span class="ri" style="background:#007aff;border-radius:50%"><i class="fa-solid fa-location-arrow"></i></span>
                    <div class="grow"><div class="title">${esc(me.street || 'Unknown street')}${me.cross ? ' & ' + esc(me.cross) : ''}</div><div class="sub">${esc(me.zone || '')}</div></div>
                    <button class="btn small gray" data-act="share" title="Share My Live Location"><i class="fa-solid fa-arrow-up-from-bracket"></i></button></div></div>` : ''}
                ${people.length ? `<div class="group-header big ms-h">People</div><div class="group">${people.map((s) => `
                    <div class="row tap has-icon" data-person="${s.id}" style="--sep-left:64px">
                        <span class="live-av">${avatar(s.name || s.number, null, 'sm')}<i></i></span>
                        <div class="grow"><div class="title">${esc(s.name || Contacts.nameFor(s.number) || s.number)}</div><div class="sub">${esc(Live.ago(s))}${s.dist != null ? ' · ' + esc(fmtDist(s.dist)) : ''}</div></div>
                        <i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}</div>` : ''}
                ${out.length && !q ? `<div class="group-header big ms-h">Sharing My Location</div><div class="group">${out.map((s) => `
                    <div class="row has-icon"><span class="ri" style="background:#34c759;border-radius:50%"><i class="fa-solid fa-location-arrow"></i></span>
                        <div class="grow"><div class="title">${esc(Contacts.nameFor(s.number) || s.number)}</div><div class="sub">${esc(Live.remaining(s))}</div></div>
                        <button class="btn small gray" data-live-act="stop" data-id="${s.id}" style="color:var(--red)">Stop</button></div>`).join('')}</div>` : ''}
                ${myHomes.length ? `<div class="group-header big ms-h">My Homes</div><div class="group">${myHomes.map(placeRow).join('')}</div>` : ''}
                <div class="group-header big ms-h">${q ? 'Results' : 'Places'}</div>
                <div class="group">${rest.map(placeRow).join('') || '<div class="row muted">No results</div>'}</div>`;
        };

        const cardView = () => {
            let title, sub, color, icon, actions;
            if (selected.type === 'place') {
                const p = places[selected.id];
                if (!p) { selected = null; return listView(); }
                const d = placeDist(p);
                title = p.name; color = placeColor(p); icon = p.icon || 'fa-location-dot';
                sub = `${p.category || 'Place'}${d != null ? ' · ' + fmtDist(d) : ''}`;
                actions = `
                    <button class="ms-act primary" data-act="go"><i class="fa-solid fa-diamond-turn-right"></i><span>Directions</span></button>
                    <button class="ms-act" data-act="sendplace"><i class="fa-solid fa-arrow-up-from-bracket"></i><span>Share</span></button>`;
            } else {
                const s = Live.incoming[selected.id];
                if (!s) { selected = null; return listView(); }
                title = s.name || Contacts.nameFor(s.number) || s.number; color = '#34c759'; icon = 'fa-user';
                sub = `${Live.ago(s)}${s.dist != null ? ' · ' + fmtDist(s.dist) : ''}`;
                const following = Live.following === s.id;
                actions = `
                    <button class="ms-act primary" data-act="go"><i class="fa-solid fa-diamond-turn-right"></i><span>Directions</span></button>
                    <button class="ms-act ${following ? 'on' : ''}" data-live-act="follow" data-id="${s.id}"><i class="fa-solid fa-route"></i><span>${following ? 'Following' : 'Follow'}</span></button>
                    <button class="ms-act" data-act="msg" data-number="${esc(s.number)}"><i class="fa-solid fa-message"></i><span>Message</span></button>`;
            }
            content.innerHTML = `
                <div class="ms-card">
                    <div class="ms-card-head">
                        <span class="ms-card-icon" style="background:${color}"><i class="fa-solid ${esc(icon)}"></i></span>
                        <div class="grow"><div class="ms-card-title">${esc(title)}</div><div class="ms-card-sub">${esc(sub)}</div></div>
                        <button class="ms-card-close" data-act="close"><i class="fa-solid fa-xmark"></i></button>
                    </div>
                    <div class="ms-actions">${actions}</div>
                </div>`;
        };
        const renderSheet = () => (selected ? cardView() : listView());

        const select = (sel, fly = true) => {
            selected = sel;
            search.blur();
            renderSheet();
            if (sheetH > SHEET.half) setSheet(SHEET.half);
            if (!sel) return redraw();
            const t = sel.type === 'place' ? places[sel.id] && places[sel.id].coords : Live.incoming[sel.id];
            if (!t) return redraw();
            setFollow(false);
            if (fly) flyTo(t.x, t.y, Math.max(view.scale, 0.3)); else redraw();
        };

        /* ---------- map gestures ---------- */
        let start = null, lastTap = 0;
        const hitTest = (sx, sy) => {
            let best = null, bestD = 26;
            markers.forEach((m) => {
                if (m._sx == null) return;
                const d = Math.hypot(m._sx - sx, m._sy - sy);
                if (d < bestD) { bestD = d; best = m; }
            });
            return best;
        };
        const localPoint = (e) => {
            const r = canvas.getBoundingClientRect();
            return [((e.clientX - r.left) / r.width) * 393, ((e.clientY - r.top) / r.height) * 852];
        };
        drag(canvas, {
            threshold: 4,
            onStart: () => { stopAnim(); start = { cx: view.cx, cy: view.cy }; return true; },
            onMove: (dx, dy) => {
                dragging = true;
                if (follow) setFollow(false);
                view.cx = start.cx - dx / view.scale;
                view.cy = start.cy + dy / view.scale;
                redraw();
            },
            onEnd: (_dx, _dy, vy, vx, e, moved) => {
                dragging = false;
                start = null;
                if (!moved) {
                    const [sx, sy] = localPoint(e);
                    const now = Date.now();
                    if (now - lastTap < 300) { lastTap = 0; return zoomAt(2, sx, sy); }   // double tap / click
                    lastTap = now;
                    const hit = hitTest(sx, sy);
                    if (hit) return select({ type: hit.kind, id: hit.id });
                    if (selected) select(null, false);
                    return;
                }
                // momentum
                let vX = vx, vY = vy;
                const t0 = performance.now(); let last = t0;
                const glide = (t) => {
                    const dt = Math.min(48, t - last); last = t;
                    vX *= Math.pow(0.992, dt); vY *= Math.pow(0.992, dt);
                    view.cx -= (vX * dt) / view.scale;
                    view.cy += (vY * dt) / view.scale;
                    redraw();
                    anim = Math.hypot(vX, vY) > 0.02 && t - t0 < 1200 ? { raf: requestAnimationFrame(glide) } : null;
                };
                if (Math.hypot(vx, vy) > 0.15) anim = { raf: requestAnimationFrame(glide) };
            },
        });
        canvas.addEventListener('wheel', (e) => {
            e.preventDefault();
            const [sx, sy] = localPoint(e);
            zoomAt(e.deltaY < 0 ? 1.25 : 0.8, sx, sy);
        }, { passive: false });

        /* ---------- clicks ---------- */
        root.addEventListener('click', async (e) => {
            const pl = e.target.closest('[data-place]');
            if (pl) return select({ type: 'place', id: +pl.dataset.place });
            const pe = e.target.closest('[data-person]');
            if (pe) return select({ type: 'person', id: +pe.dataset.person });
            const a = e.target.closest('[data-act]');
            if (!a) return;
            switch (a.dataset.act) {
                case 'zin': return zoomAt(1.6);
                case 'zout': return zoomAt(1 / 1.6);
                case 'follow': return setFollow(!follow);
                case 'style':
                    style = style === 'dark' ? 'standard' : 'dark';
                    Phone.settings.mapStyle = style;
                    rpc('saveSettings', { mapStyle: style });
                    $('.maps', root).classList.toggle('dark-map', style === 'dark');
                    return redraw();
                case 'close': return select(null, false);
                case 'go': {
                    if (!selected) return;
                    const t = selected.type === 'place' ? places[selected.id].coords : Live.incoming[selected.id];
                    if (!t) return;
                    nui('setWaypoint', { x: t.x, y: t.y });
                    if (selected.type === 'person') nui('liveFlash', { id: selected.id });
                    UI.toast(I18N.t('GPS set'), 'fa-solid fa-diamond-turn-right');
                    return;
                }
                case 'sendplace': {
                    const p = selected && places[selected.id];
                    const c = await pickContact('Share');
                    if (c && p) {
                        await rpc('sendMessage', { number: c.number, message: `📍 ${p.name}` });
                        UI.toast('Sent to ' + c.name);
                    }
                    return;
                }
                case 'msg': return Phone.openApp('messages', { number: a.dataset.number });
                case 'share': {
                    const c = await pickContact('Share Live Location');
                    if (c) Live.share(c.number, c.name);
                    return;
                }
            }
        });
        search.addEventListener('focus', () => {
            if (sheetH < SHEET.full) setSheet(SHEET.full);
            if (selected) { selected = null; redraw(); }
            listView();
        });
        search.addEventListener('input', () => { $('.ms-clear', root).classList.toggle('hidden', !search.value); listView(); });
        $('.ms-clear', root).addEventListener('click', () => { search.value = ''; $('.ms-clear', root).classList.add('hidden'); listView(); search.focus(); });

        /* ---------- live data ---------- */
        const loadHomes = () => rpc('getHomes').then((list) => {
            if (!Array.isArray(list)) return;
            const sel = selected && selected.type === 'place' ? places[selected.id] : null;
            homes = list.filter((h) => h && h.x != null);
            places = allPlaces();
            if (sel) { const i = places.indexOf(sel); selected = i >= 0 ? { type: 'place', id: i } : null; }
            if (document.activeElement !== search) renderSheet();
            redraw();
        });
        loadHomes();
        app.on('placesUpdated', () => {
            places = allPlaces();
            if (selected && selected.type === 'place' && !places[selected.id]) selected = null;
            if (document.activeElement !== search) renderSheet();
            redraw();
        });
        app.on('liveChanged', () => {
            if (selected && selected.type === 'person' && !Live.incoming[selected.id]) selected = null;
            if (document.activeElement !== search) renderSheet();
            // keep a selected friend in view while they move (unless the player is dragging)
            const s = selected && selected.type === 'person' && Live.incoming[selected.id];
            if (s && s.x != null && !dragging && !anim) { view.cx = s.x; view.cy = s.y; }
            redraw();
        });

        let lastListKey = '';
        const updateMe = async () => {
            const p = await nui('getLocation');
            if (!p || !document.body.contains(canvas)) return;
            const first = !me;
            me = p;
            Live.myPos = p;
            if (first) { view.cx = p.x; view.cy = p.y; view.scale = 0.3; }
            else if (follow && !dragging && !anim) { view.cx = p.x; view.cy = p.y; }
            // refresh the list only when the street changes (keeps scrolling smooth)
            const key = `${p.street}|${p.cross}|${Math.round(p.x / 50)}|${Math.round(p.y / 50)}`;
            if (!selected && document.activeElement !== search && key !== lastListKey) { lastListKey = key; listView(); }
            redraw();
        };
        const iv = setInterval(() => {
            if (!document.body.contains(canvas)) return clearInterval(iv);
            if (Phone.state === 'open') updateMe();
        }, 1000);

        /* ---------- start ---------- */
        $('.maps', root).classList.toggle('dark-map', style === 'dark');
        if (me) { view.cx = me.x; view.cy = me.y; view.scale = 0.3; }
        setSheet(SHEET.half, false);
        listView();
        updateMe();
        if (params.live && !params.mine) setTimeout(() => Live.incoming[params.live] && select({ type: 'person', id: +params.live }), 60);
        if (document.fonts) document.fonts.ready.then(redraw);

        app.focusLive = (id) => Live.incoming[id] && select({ type: 'person', id });
    },
    onParams(params, app) {
        if (params.live && !params.mine && app.focusLive) app.focusLive(+params.live);
    },
});
