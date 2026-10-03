'use strict';
/* OPS Mobile network map: San Andreas vector map, merged coverage, dead zones, live towers + players (opslabs-towers). */
(() => {
  const root = document.getElementById('tm');
  const canvas = document.getElementById('tm-canvas');
  const ctx = canvas.getContext('2d');
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const store = { get(k, d) { try { return localStorage.getItem(k) ?? d; } catch { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } } };

  const state = { towers: [], players: [], stats: {}, enforce: true, selected: null, draft: null, hover: null, adding: null,
    props: { cell: [], wifi: [] },
    tab: 'towers', q: '', updated: 0, coverage: null, coverSig: '', selecting: false, picked: new Set(),
    layers: { cell: true, wifi: true, players: true, ranges: true, dead: true } };
  const view = { cx: 300, cy: 1500, scale: 0.08 };
  let W = 0, H = 0, dpr = 1;
  let mapStyle = store.get('tm-style', matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');

  const PAL = {
    light: { sea: '#d4e4f7', seaDeep: '#c4d8f0', land: '#f3f4ef', edge: '#cfd6c8', water: '#c4dcf5', desert: '#f2ead6', hill: 'rgba(96,120,80,.10)', town: '#e6e7ec',
      road: '#ffffff', roadEdge: '#dfe2e8', hwy: '#fbd38d', hwyEdge: '#e9b45e', label: '#5d6075', labelCity: '#1f2235', dead: 'rgba(229,56,59,.28)', grid: 'rgba(30,40,80,.04)',
      cell: '#5b3df5', wifi: '#16a34a', off: '#e5383b', chip: 'rgba(255,255,255,.94)', chipText: '#0b0b1a' },
    dark: { sea: '#0a1020', seaDeep: '#080d1a', land: '#161c29', edge: '#252e40', water: '#0d182b', desert: '#1f1d1a', hill: 'rgba(255,255,255,.05)', town: '#1d2433',
      road: '#2a3346', roadEdge: '#1f2738', hwy: '#4b5675', hwyEdge: '#39425b', label: '#8b93ad', labelCity: '#e4e8f5', dead: 'rgba(255,90,95,.30)', grid: 'rgba(255,255,255,.035)',
      cell: '#8b74ff', wifi: '#34d399', off: '#ff5a5f', chip: 'rgba(20,22,36,.92)', chipText: '#f2f3fa' },
  };
  const P = () => PAL[mapStyle];

  const sx = (x) => W / 2 + (x - view.cx) * view.scale;
  const sy = (y) => H / 2 - (y - view.cy) * view.scale;
  const wx = (px) => view.cx + (px - W / 2) / view.scale;
  const wy = (py) => view.cy - (py - H / 2) / view.scale;

  // offscreen layers for merged coverage (no darker overlaps) and dead zones
  const off = { cov: document.createElement('canvas'), wifi: document.createElement('canvas'), dead: document.createElement('canvas') };
  const offCtx = Object.fromEntries(Object.entries(off).map(([k, c]) => [k, c.getContext('2d')]));

  function resize() {
    const r = canvas.parentElement.getBoundingClientRect();
    dpr = window.devicePixelRatio || 1;
    W = r.width; H = r.height;
    for (const c of [canvas, ...Object.values(off)]) { c.width = W * dpr; c.height = H * dpr; }
    canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    Object.values(offCtx).forEach((c) => c.setTransform(dpr, 0, 0, dpr, 0, 0));
    draw();
  }
  function fit() { view.cx = 300; view.cy = 1500; view.scale = Math.min(W / 8000, H / 11200); draw(); }

  /* ---------------- geometry helpers ---------------- */
  function path(c, pts, close = true) {
    c.beginPath();
    pts.forEach(([x, y], i) => (i ? c.lineTo(sx(x), sy(y)) : c.moveTo(sx(x), sy(y))));
    if (close) c.closePath();
  }
  function fillPoly(c, pts, color) { path(c, pts); c.fillStyle = color; c.fill(); }
  function stroke(c, pts, color, w) { path(c, pts, false); c.strokeStyle = color; c.lineWidth = w; c.lineJoin = c.lineCap = 'round'; c.stroke(); }
  function inPoly(x, y, poly) {
    let inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [xi, yi] = poly[i], [xj, yj] = poly[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  }
  const onLand = (x, y) => inPoly(x, y, SA.land) && !SA.water.some((w) => inPoly(x, y, w));

  /* share of land inside an online cell tower's range (sampled grid, cached per tower set) */
  function landCoverage() {
    const cells = state.towers.filter((t) => t.type === 'cell' && t.active);
    const sig = cells.map((t) => `${t.id}:${t.x}:${t.y}:${t.range}`).join('|');
    if (sig === state.coverSig && state.coverage !== null) return state.coverage;
    let land = 0, covered = 0;
    for (let x = -3400; x <= 4000; x += 70) {
      for (let y = -3800; y <= 7200; y += 70) {
        if (!onLand(x, y)) continue;
        land++;
        if (cells.some((t) => (x - t.x) ** 2 + (y - t.y) ** 2 <= t.range * t.range)) covered++;
      }
    }
    state.coverSig = sig;
    state.coverage = land ? covered / land : 0;
    return state.coverage;
  }

  /* ---------------- drawing ---------------- */
  let hatch = null, hatchStyle = '';
  function hatchPattern(color) {
    if (hatch && hatchStyle === color) return hatch;
    const p = document.createElement('canvas'); p.width = p.height = 9;
    const c = p.getContext('2d'); c.strokeStyle = color; c.lineWidth = 1.4;
    c.beginPath(); c.moveTo(0, 9); c.lineTo(9, 0); c.stroke();
    hatch = ctx.createPattern(p, 'repeat'); hatchStyle = color;
    return hatch;
  }

  function drawBase(c) {
    const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, c.sea); g.addColorStop(1, c.seaDeep);
    ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    const step = view.scale > 0.25 ? 250 : view.scale > 0.1 ? 500 : 1000;
    ctx.strokeStyle = c.grid; ctx.lineWidth = 1;
    for (let x = Math.floor(wx(0) / step) * step; x < wx(W); x += step) { ctx.beginPath(); ctx.moveTo(sx(x), 0); ctx.lineTo(sx(x), H); ctx.stroke(); }
    for (let y = Math.floor(wy(H) / step) * step; y < wy(0); y += step) { ctx.beginPath(); ctx.moveTo(0, sy(y)); ctx.lineTo(W, sy(y)); ctx.stroke(); }
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.12)'; ctx.shadowBlur = 18; fillPoly(ctx, SA.land, c.land); ctx.restore();
    path(ctx, SA.land); ctx.strokeStyle = c.edge; ctx.lineWidth = 1.5; ctx.stroke();
    SA.desert.forEach((p) => fillPoly(ctx, p, c.desert));
    SA.hills.forEach(([x, y, r]) => {
      const rg = ctx.createRadialGradient(sx(x), sy(y), 0, sx(x), sy(y), r * view.scale);
      rg.addColorStop(0, c.hill); rg.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = rg; ctx.beginPath(); ctx.arc(sx(x), sy(y), r * view.scale, 0, Math.PI * 2); ctx.fill();
    });
    SA.towns.forEach((p) => fillPoly(ctx, p, c.town));
    SA.water.forEach((p) => fillPoly(ctx, p, c.water));
    SA.airports.forEach((a) => {
      const [x1, y1, x2, y2] = a.rect; fillPoly(ctx, [[x1, y1], [x2, y1], [x2, y2], [x1, y2]], c.town);
      a.runways.forEach((r) => stroke(ctx, r, c.road, Math.max(2, 45 * view.scale)));
    });
    const rw = Math.max(1.2, 16 * view.scale), hw = Math.max(2, 28 * view.scale);
    SA.roads.forEach((r) => { stroke(ctx, r, c.roadEdge, rw + 1.5); stroke(ctx, r, c.road, rw); });
    SA.highways.forEach((r) => { stroke(ctx, r, c.hwyEdge, hw + 1.5); stroke(ctx, r, c.hwy, hw); });
  }

  function towerList() {
    const d = state.draft;
    const list = state.towers.filter((t) => !d || t.id !== d.id);
    if (d) list.push({ ...d, _draft: true });
    return list;
  }

  function drawCoverage(c) {
    const list = towerList();
    const cells = list.filter((t) => t.type === 'cell' && t.active && state.layers.cell);
    // merged cell coverage mask
    const cc = offCtx.cov; cc.clearRect(0, 0, W, H); cc.fillStyle = '#000';
    for (const t of cells) { cc.beginPath(); cc.arc(sx(t.x), sy(t.y), t.range * view.scale, 0, Math.PI * 2); cc.fill(); }
    // dead zones = land not covered
    if (state.layers.dead && state.enforce) {
      const dc = offCtx.dead; dc.clearRect(0, 0, W, H);
      path(dc, SA.land); dc.fillStyle = hatchPattern(c.dead); dc.fill();
      SA.water.forEach((w) => { dc.save(); dc.globalCompositeOperation = 'destination-out'; path(dc, w); dc.fill(); dc.restore(); });
      dc.save(); dc.globalCompositeOperation = 'destination-out'; dc.setTransform(1, 0, 0, 1, 0, 0); dc.drawImage(off.cov, 0, 0); dc.restore();
      ctx.drawImage(off.dead, 0, 0, W, H);
    }
    if (state.layers.ranges) {
      // tint the merged area once (overlaps don't get darker)
      const tc = offCtx.wifi; tc.clearRect(0, 0, W, H);
      tc.save(); tc.setTransform(1, 0, 0, 1, 0, 0); tc.drawImage(off.cov, 0, 0); tc.restore();
      tc.save(); tc.globalCompositeOperation = 'source-in'; tc.fillStyle = c.cell; tc.fillRect(0, 0, W, H); tc.restore();
      ctx.save(); ctx.globalAlpha = mapStyle === 'dark' ? 0.16 : 0.11; ctx.drawImage(off.wifi, 0, 0, W, H); ctx.restore();
      // outlines
      for (const t of list.filter((t) => t.type === 'cell' && state.layers.cell)) {
        const sel = state.selected === t.id || t._draft;
        ctx.beginPath(); ctx.arc(sx(t.x), sy(t.y), t.range * view.scale, 0, Math.PI * 2);
        ctx.setLineDash(t.active ? [] : [7, 6]);
        ctx.strokeStyle = t.active ? c.cell : c.off;
        ctx.globalAlpha = sel ? 1 : t.active ? 0.35 : 0.8;
        ctx.lineWidth = sel ? 2.2 : 1;
        ctx.stroke(); ctx.globalAlpha = 1; ctx.setLineDash([]);
        if (sel) { ctx.fillStyle = (t.active ? c.cell : c.off) + '1f'; ctx.fill(); }
      }
      // Wi-Fi bubbles
      if (state.layers.wifi) {
        for (const t of list.filter((t) => t.type === 'wifi')) {
          const r = t.range * view.scale;
          if (r < 1.5) continue;
          ctx.beginPath(); ctx.arc(sx(t.x), sy(t.y), r, 0, Math.PI * 2);
          ctx.fillStyle = (t.active ? c.wifi : c.off) + '30'; ctx.fill();
          ctx.setLineDash(t.active ? [] : [5, 4]); ctx.strokeStyle = t.active ? c.wifi : c.off; ctx.lineWidth = 1.2; ctx.stroke(); ctx.setLineDash([]);
        }
      }
    }
  }

  function drawLabels(c) {
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    for (const [name, x, y, kind] of SA.labels) {
      if (kind === 'area' && view.scale < 0.07) continue;
      const city = kind === 'city';
      ctx.font = `${city ? 800 : kind === 'water' ? '500 italic' : 600} ${city ? 13 : 10.5}px Inter, sans-serif`;
      ctx.fillStyle = city ? c.labelCity : c.label;
      const txt = city || kind === 'town' ? name.toUpperCase() : name;
      if ('letterSpacing' in ctx) ctx.letterSpacing = city || kind === 'town' ? '1.5px' : '0px';
      ctx.fillText(txt, sx(x), sy(y));
    }
    if ('letterSpacing' in ctx) ctx.letterSpacing = '0px';
    ctx.textBaseline = 'alphabetic';
  }

  function glyph(t, x, y, size, color) {
    ctx.save(); ctx.translate(x, y); ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineCap = 'round'; ctx.lineWidth = 1.6;
    if (t.type === 'wifi') {
      ctx.beginPath(); ctx.arc(0, size * 0.35, 1.4, 0, Math.PI * 2); ctx.fill();
      for (const r of [size * 0.38, size * 0.66]) { ctx.beginPath(); ctx.arc(0, size * 0.35, r, -Math.PI * 0.78, -Math.PI * 0.22); ctx.stroke(); }
    } else {
      const s = size * 0.42;
      ctx.beginPath(); ctx.moveTo(0, -s * 0.2); ctx.lineTo(0, s); ctx.stroke();
      ctx.beginPath(); ctx.arc(0, -s * 0.2, 1.5, 0, Math.PI * 2); ctx.fill();
      for (const r of [s * 0.55, s * 0.95]) {
        ctx.beginPath(); ctx.arc(0, -s * 0.2, r, -Math.PI * 0.3, Math.PI * 0.3); ctx.stroke();
        ctx.beginPath(); ctx.arc(0, -s * 0.2, r, Math.PI * 0.7, Math.PI * 1.3); ctx.stroke();
      }
    }
    ctx.restore();
  }

  function drawTowers(c) {
    for (const t of towerList()) {
      if (!state.layers[t.type]) continue;
      if (t.type === 'wifi' && view.scale < 0.045 && state.selected !== t.id) continue;
      const x = sx(t.x), y = sy(t.y), sel = state.selected === t.id || t._draft || state.picked.has(t.id), hov = state.hover === t;
      const col = !t.active ? c.off : t.type === 'wifi' ? c.wifi : c.cell;
      const r = t.type === 'wifi' ? (sel ? 11 : 8.5) : (sel ? 14 : 11);
      ctx.save();
      ctx.shadowColor = 'rgba(0,0,0,.28)'; ctx.shadowBlur = 8; ctx.shadowOffsetY = 2;
      ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fillStyle = col; ctx.fill();
      ctx.restore();
      ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.lineWidth = sel || hov ? 3 : 2; ctx.strokeStyle = '#fff'; ctx.stroke();
      glyph(t, x, y, r * 1.5, '#fff');
      if (sel) { ctx.beginPath(); ctx.arc(x, y, r + 6, 0, Math.PI * 2); ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.globalAlpha = 0.45; ctx.stroke(); ctx.globalAlpha = 1; }
      if (sel || hov || (t.type === 'cell' && view.scale > 0.11) || view.scale > 0.5) {
        const label = t.name + (t.active ? '' : ' · offline');
        ctx.font = '650 12px Inter, sans-serif'; ctx.textAlign = 'left';
        const w = ctx.measureText(label).width;
        const lx = x + r + 6, ly = y - 11;
        ctx.save(); ctx.shadowColor = 'rgba(0,0,0,.15)'; ctx.shadowBlur = 6;
        roundRect(lx, ly, w + 14, 22, 7); ctx.fillStyle = c.chip; ctx.fill(); ctx.restore();
        ctx.fillStyle = t.active ? c.chipText : c.off; ctx.fillText(label, lx + 7, ly + 15);
      }
    }
  }
  function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

  const playerColor = (p) => (p.cell >= 3 ? '#22b357' : p.cell >= 1 ? '#f59f0a' : p.wifi ? '#22b357' : '#e5383b');
  function drawPlayers(c) {
    if (!state.layers.players) return;
    for (const p of state.players) {
      const x = sx(p.x), y = sy(p.y), col = playerColor(p);
      const a = (-(p.heading || 0)) * Math.PI / 180;
      ctx.save(); ctx.translate(x, y); ctx.rotate(a);
      ctx.shadowColor = 'rgba(0,0,0,.35)'; ctx.shadowBlur = 6;
      ctx.beginPath(); ctx.moveTo(0, -11); ctx.lineTo(7.5, 7); ctx.lineTo(0, 3.5); ctx.lineTo(-7.5, 7); ctx.closePath();
      ctx.fillStyle = col; ctx.fill(); ctx.shadowBlur = 0; ctx.lineWidth = 2; ctx.strokeStyle = '#fff'; ctx.stroke();
      ctx.restore();
      if (p.wifi) { ctx.beginPath(); ctx.arc(x + 9, y - 9, 4.5, 0, Math.PI * 2); ctx.fillStyle = c.wifi; ctx.fill(); ctx.lineWidth = 1.5; ctx.strokeStyle = '#fff'; ctx.stroke(); }
      if (state.hover === p || view.scale > 0.22) {
        ctx.font = '700 11.5px Inter, sans-serif'; ctx.textAlign = 'center';
        const w = ctx.measureText(p.name).width;
        roundRect(x - w / 2 - 6, y + 12, w + 12, 19, 6); ctx.fillStyle = c.chip; ctx.fill();
        ctx.fillStyle = c.chipText; ctx.fillText(p.name, x, y + 25);
      }
    }
  }

  function drawScale(c) {
    const metres = view.scale > 0.4 ? 250 : view.scale > 0.15 ? 500 : view.scale > 0.05 ? 1000 : 2000;
    const px = metres * view.scale, x = W - px - 18, y = H - 20;
    ctx.fillStyle = c.chip; roundRect(x - 8, y - 22, px + 16, 30, 8); ctx.fill();
    ctx.fillStyle = c.chipText; ctx.fillRect(x, y, px, 2.5); ctx.fillRect(x, y - 5, 1.5, 7.5); ctx.fillRect(x + px - 1.5, y - 5, 1.5, 7.5);
    ctx.font = '650 11px Inter, sans-serif'; ctx.textAlign = 'center';
    ctx.fillText(metres >= 1000 ? metres / 1000 + ' km' : metres + ' m', x + px / 2, y - 7);
  }

  let raf = 0;
  function draw() {
    if (raf) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      const c = P();
      drawBase(c);
      drawCoverage(c);
      drawLabels(c);
      drawTowers(c);
      drawPlayers(c);
      drawScale(c);
    });
  }

  /* ---------------- interaction ---------------- */
  let drag = null;
  canvas.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    // grab the tower being edited to move it
    let d = state.draft;
    let grab = d && !form.hidden && Math.hypot(sx(d.x) - mx, sy(d.y) - my) < 16;
    // press on any tower and drag: it opens and moves in one go
    if (!grab && !state.adding && !state.selecting) {
      const hit = pick(mx, my);
      if (hit && hit.type) { openEditor(hit); d = state.draft; grab = true; }
    }
    drag = { x: e.clientX, y: e.clientY, cx: view.cx, cy: view.cy, moved: false, tower: grab };
    canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener('pointermove', (e) => {
    const r = canvas.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    $('#tm-coords').textContent = `X ${wx(mx).toFixed(1)} · Y ${wy(my).toFixed(1)}`;
    if (drag && drag.tower && state.draft) {
      drag.moved = true;
      state.draft.x = Math.round(wx(mx) * 10) / 10; state.draft.y = Math.round(wy(my) * 10) / 10;
      form.elements.x.value = state.draft.x; form.elements.y.value = state.draft.y;
      canvas.style.cursor = 'grabbing'; $('#tm-tip').hidden = true;
      $('#tm-moved').hidden = false;
      draw();
      return;
    }
    if (drag) {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (Math.hypot(dx, dy) > 4) drag.moved = true;
      view.cx = drag.cx - dx / view.scale; view.cy = drag.cy + dy / view.scale;
      $('#tm-tip').hidden = true; draw();
      return;
    }
    const hit = pick(mx, my);
    if (hit !== state.hover) { state.hover = hit; draw(); }
    const onDraft = state.draft && !form.hidden && Math.hypot(sx(state.draft.x) - mx, sy(state.draft.y) - my) < 16;
    canvas.style.cursor = state.adding ? 'crosshair' : (onDraft || (hit && hit.type && !state.selecting)) ? 'move' : hit ? 'pointer' : 'grab';
    const tip = $('#tm-tip');
    if (hit) {
      tip.hidden = false;
      tip.style.left = Math.min(mx + 16, W - 260) + 'px'; tip.style.top = my + 16 + 'px';
      tip.innerHTML = hit.type
        ? `<b>${esc(hit.name)}</b><span>${hit.type === 'wifi' ? 'Wi-Fi · ' + esc(hit.ssid || '') : 'Cell tower'} · ${hit.range} m · ${connected(hit)} connected${hit.active ? '' : ' · <em>offline</em>'}</span>`
        : `<b>${esc(hit.name)}</b><span>${hit.number ? esc(hit.number) + ' · ' : ''}${hit.cell > 0 ? `${hit.net} ${hit.cell}/4 · ${esc(hit.tower || '')}` : '<em>No signal</em>'}${hit.wifi ? ' · Wi-Fi ' + esc(hit.wifi) : ''}</span>`;
    } else tip.hidden = true;
  });
  canvas.addEventListener('pointerleave', () => { $('#tm-tip').hidden = true; state.hover = null; draw(); });
  canvas.addEventListener('pointerup', (e) => {
    const d = drag; drag = null;
    if (!d || d.moved) return;
    const r = canvas.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    if (state.adding) {
      const wifi = state.adding === 'wifi';
      openEditor({ type: state.adding, name: wifi ? 'New Wi-Fi' : 'New tower', x: Math.round(wx(mx) * 10) / 10, y: Math.round(wy(my) * 10) / 10, z: 30, range: wifi ? 40 : 1500, active: true });
      setAdding(null);
      return;
    }
    const hit = pick(mx, my);
    if (hit && hit.type && state.selecting) { state.picked.has(hit.id) ? state.picked.delete(hit.id) : state.picked.add(hit.id); syncBulk(); renderList(); draw(); return; }
    if (hit && hit.type) openEditor(hit);
    else if (hit) { state.tab = 'players'; setTab('players'); }
  });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect();
    zoomAt(e.clientX - r.left, e.clientY - r.top, Math.exp(-e.deltaY * 0.0015));
  }, { passive: false });
  function zoomAt(mx, my, k) {
    const bx = wx(mx), by = wy(my);
    view.scale = Math.max(0.02, Math.min(3, view.scale * k));
    view.cx = bx - (mx - W / 2) / view.scale; view.cy = by + (my - H / 2) / view.scale;
    draw();
  }
  function pick(mx, my) {
    if (state.layers.players) for (const p of state.players) if (Math.hypot(sx(p.x) - mx, sy(p.y) - my) < 11) return p;
    let best = null, bd = 15;
    for (const t of state.towers) {
      if (!state.layers[t.type]) continue;
      const d = Math.hypot(sx(t.x) - mx, sy(t.y) - my);
      if (d < bd) { bd = d; best = t; }
    }
    return best;
  }
  function focus(x, y, scale) {
    const from = { cx: view.cx, cy: view.cy, s: view.scale }, to = { cx: x, cy: y, s: scale ? Math.max(view.scale, scale) : view.scale };
    const t0 = performance.now();
    const step = (now) => {
      const k = Math.min(1, (now - t0) / 380), e = 1 - Math.pow(1 - k, 3);
      view.cx = from.cx + (to.cx - from.cx) * e; view.cy = from.cy + (to.cy - from.cy) * e; view.scale = from.s + (to.s - from.s) * e;
      draw();
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  root.addEventListener('click', (e) => {
    const z = e.target.closest('[data-zoom]'); if (z) return zoomAt(W / 2, H / 2, +z.dataset.zoom > 0 ? 1.6 : 1 / 1.6);
    if (e.target.closest('[data-fit]')) return fit();
    const st = e.target.closest('[data-style]');
    if (st) { mapStyle = st.dataset.style; store.set('tm-style', mapStyle); $$('[data-style]').forEach((b) => b.classList.toggle('on', b === st)); hatch = null; return draw(); }
    const a = e.target.closest('[data-add]'); if (a) return setAdding(state.adding === a.dataset.add ? null : a.dataset.add);
    const tb = e.target.closest('[data-tab]'); if (tb) return setTab(tb.dataset.tab);
    const ba = e.target.closest('[data-bulk-all]');
    if (ba) return bulkAll(ba.dataset.bulkAll);
    const bb = e.target.closest('[data-bulk]');
    if (bb) return bulkSelected(bb.dataset.bulk);
    const item = e.target.closest('[data-tower]');
    if (item && state.selecting) {
      const id = +item.dataset.tower;
      state.picked.has(id) ? state.picked.delete(id) : state.picked.add(id);
      syncBulk(); renderList(); draw();
      return;
    }
    if (item) { const t = state.towers.find((x) => x.id === +item.dataset.tower); if (t) { openEditor(t); focus(t.x, t.y, t.type === 'wifi' ? 0.7 : 0.12); } return; }
    const pl = e.target.closest('[data-player]');
    if (pl) { const p = state.players.find((x) => x.id === +pl.dataset.player); if (p) focus(p.x, p.y, 0.3); return; }
    if (e.target.closest('[data-focus]') && state.draft) focus(state.draft.x, state.draft.y, state.draft.type === 'wifi' ? 0.7 : 0.12);
  });
  $$('[data-layer]').forEach((cb) => cb.addEventListener('change', () => { state.layers[cb.dataset.layer] = cb.checked; draw(); }));
  $$('[data-style]').forEach((b) => b.classList.toggle('on', b.dataset.style === mapStyle));
  $('#tm-q').addEventListener('input', (e) => { state.q = e.target.value.toLowerCase(); renderList(); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && !e.target.closest('input')) { setAdding(null); closeEditor(); } });

  function setTab(tab) {
    state.tab = tab;
    $$('#tm-tabs [data-tab]').forEach((b) => b.classList.toggle('on', b.dataset.tab === tab));
    closeEditor();
  }
  function setAdding(kind) {
    state.adding = kind;
    $$('[data-add]').forEach((b) => b.classList.toggle('active', b.dataset.add === kind));
    const hint = $('#tm-hint');
    hint.hidden = !kind;
    hint.innerHTML = kind ? `Click anywhere on the map to place a <b>${kind === 'wifi' ? 'Wi-Fi access point' : 'cell tower'}</b> <kbd>Esc</kbd> to cancel` : '';
    canvas.style.cursor = kind ? 'crosshair' : 'grab';
  }

  /* ---------------- side panel ---------------- */
  const connected = (t) => state.players.filter((p) => (t.type === 'wifi' ? p.wifi === t.ssid : p.tower === t.name)).length;
  const towerIco = (t) => `<span class="ti ${t.type} ${t.active ? '' : 'off'}">${t.type === 'wifi'
    ? '<svg viewBox="0 0 24 24"><path d="M5 12.6a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 20h.01"/></svg>'
    : '<svg viewBox="0 0 24 24"><path d="M12 9v11M7.2 4.6a7 7 0 0 0 0 8.8M16.8 4.6a7 7 0 0 1 0 8.8"/><circle cx="12" cy="9" r="1.6"/></svg>'}</span>`;
  const bars = (n) => `<span class="sig" data-bars="${n}"><i></i><i></i><i></i><i></i></span>`;

  function renderList() {
    const el = $('#tm-list'), q = state.q;
    $('#c-towers').textContent = state.towers.length;
    $('#c-players').textContent = state.players.length;
    const outages = state.towers.filter((t) => !t.active);
    $('#c-outages').textContent = outages.length;
    $('#c-outages').classList.toggle('alert', outages.length > 0);
    if (state.tab === 'players') {
      const list = state.players.filter((p) => !q || `${p.name} ${p.number || ''} ${p.wifi || ''}`.toLowerCase().includes(q))
        .sort((a, b) => a.cell - b.cell);
      el.innerHTML = list.length ? list.map((p) => `
        <button class="li" data-player="${p.id}">
          <span class="pdot" style="--c:${playerColor(p)}"></span>
          <div class="li-main"><b>${esc(p.name)}</b><span>${p.number ? esc(p.number) + ' · ' : ''}${p.cell > 0 ? esc(p.tower || '') : 'No signal'}${p.wifi ? ' · ' + esc(p.wifi) : ''}</span></div>
          <div class="li-side">${bars(p.cell)}<small>${p.cell > 0 ? esc(p.net || '') : 'SOS'}</small></div>
        </button>`).join('') : empty('No players in the city right now.');
      return;
    }
    let list = state.tab === 'outages' ? outages : state.towers;
    list = list.filter((t) => !q || `${t.name} ${t.ssid || ''} ${t.jobs || ''}`.toLowerCase().includes(q));
    const group = (title, items) => items.length ? `<div class="li-group">${title}<span>${items.length}</span></div>` + items.map((t) => `
      <button class="li ${state.selected === t.id ? 'on' : ''} ${state.picked.has(t.id) ? 'picked' : ''}" data-tower="${t.id}">
        ${state.selecting ? `<span class="li-check ${state.picked.has(t.id) ? 'on' : ''}"></span>` : ''}
        ${towerIco(t)}
        <div class="li-main"><b>${esc(t.name)}${t.password ? ' <i class="lock-badge" title="Password protected">🔒</i>' : ''}</b><span>${t.type === 'wifi' ? esc(t.ssid || '') + (t.jobs ? ' · ' + esc(t.jobs) : '') : 'Cell tower'} · ${t.range >= 1000 ? (t.range / 1000).toFixed(1) + ' km' : t.range + ' m'}</span></div>
        <div class="li-side">${t.active ? `<b class="cnt">${connected(t)}</b><small>connected</small>` : '<em class="off-pill">Offline</em>'}</div>
      </button>`).join('') : '';
    const byName = (a, b) => a.name.localeCompare(b.name);
    const html = group('Cell towers', list.filter((t) => t.type === 'cell').sort(byName)) + group('Wi-Fi access points', list.filter((t) => t.type === 'wifi').sort(byName));
    el.innerHTML = html || empty(state.tab === 'outages' ? 'No outages — every tower is online.' : q ? 'Nothing matches your search.' : 'No towers yet. Use “Add cell tower” and click the map.');
  }
  const empty = (msg) => `<div class="li-empty">${esc(msg)}</div>`;

  /* ---------------- bulk ---------------- */
  const visibleTowers = () => (state.tab === 'outages' ? state.towers.filter((t) => !t.active) : state.towers)
    .filter((t) => !state.q || `${t.name} ${t.ssid || ''} ${t.jobs || ''}`.toLowerCase().includes(state.q));
  function setSelecting(on) {
    state.selecting = on;
    if (!on) state.picked.clear();
    $('#tm-select').classList.toggle('on', on);
    $('#tm-select').textContent = on ? 'Done' : 'Select';
    $('#tm-bulk-all').hidden = !on;
    syncBulk(); renderList(); draw();
  }
  function syncBulk() {
    const n = state.picked.size;
    $('#tm-bulkbar').hidden = !state.selecting;
    $('#tm-sel-count').textContent = `${n} selected`;
    $$('[data-bulk]').forEach((b) => (b.disabled = n === 0));
    const vis = visibleTowers();
    $('#tm-check-all').checked = vis.length > 0 && vis.every((t) => state.picked.has(t.id));
  }
  $('#tm-select').addEventListener('click', () => { if (state.tab === 'players') setTab('towers'); setSelecting(!state.selecting); });
  $('#tm-check-all').addEventListener('change', (e) => {
    for (const t of visibleTowers()) e.target.checked ? state.picked.add(t.id) : state.picked.delete(t.id);
    syncBulk(); renderList(); draw();
  });
  async function runBulk(body, label) {
    try {
      const r = await send(`${root.dataset.api}/bulk`, 'POST', body);
      toast(`${label} ${r.count} tower${r.count === 1 ? '' : 's'}`);
      state.picked.clear(); syncBulk();
      await refresh(); renderList();
    } catch (err) { toast(err.message, true); }
  }
  function bulkSelected(action) {
    const ids = [...state.picked];
    if (!ids.length) return;
    if (action === 'delete' && !confirm(`Delete ${ids.length} tower${ids.length === 1 ? '' : 's'}? Phones in those areas lose this signal.`)) return;
    runBulk({ action, ids }, action === 'delete' ? 'Deleted' : action === 'offline' ? 'Took offline' : 'Brought online');
  }
  function bulkAll(kind) {
    const label = { offline: 'all offline towers', wifi: 'all Wi-Fi access points', cell: 'all cell towers', all: 'EVERY tower and Wi-Fi access point' }[kind];
    const n = state.towers.filter((t) => kind === 'all' || (kind === 'offline' ? !t.active : t.type === kind)).length;
    if (!n) return toast('Nothing to delete');
    if (kind === 'all') {
      if (prompt(`This deletes ${n} towers and leaves the whole map with no signal. Type DELETE to confirm.`) !== 'DELETE') return;
    } else if (!confirm(`Delete ${label} (${n})?`)) return;
    runBulk({ action: 'delete', all: true, ...(kind === 'offline' ? { offline: true } : kind === 'all' ? {} : { type: kind }) }, 'Deleted');
  }

  /* ---------------- detail / editor ---------------- */
  const form = $('#tm-editor');
  const slider = $('#ed-range');
  function openEditor(t) {
    if (state.selecting) setSelecting(false);
    state.selected = t.id || null;
    state.draft = { ...t };
    form.hidden = false; $('#tm-list').hidden = true; $('.nm-search').hidden = true;
    form.querySelector(`[name=type][value=${t.type}]`).checked = true;
    for (const k of ['name', 'x', 'y', 'z', 'range', 'ssid', 'jobs', 'notes', 'password']) form.elements[k].value = t[k] ?? '';
    form.elements.password.type = 'password'; form.querySelector('[data-eye]').textContent = 'Show';
    form.elements.active.checked = t.active !== false;
    fillModels(t.type, t.prop ? (t.model || '') : '');
    form.querySelector('[data-delete]').hidden = !t.id;
    $('#tm-moved').hidden = true;
    $('#ed-meta').textContent = t.id ? `#${t.id}${t.created_by ? ' · placed by ' + t.created_by : ''}` : 'New — click Save to add it to the network.';
    syncHeader(); syncType();
    renderList(); draw();
  }
  function closeEditor() {
    form.hidden = true; $('#tm-list').hidden = false; $('.nm-search').hidden = false;
    state.selected = null; state.draft = null; renderList(); draw();
  }
  /** prop choices for this type (same list the game uses) */
  function fillModels(type, current) {
    const sel = form.elements.model;
    const list = state.props[type] || [];
    const known = list.some((p) => p.model === current);
    sel.innerHTML = `<option value="">No prop${type === 'cell' ? ' (invisible tower)' : ''}</option>`
      + list.map((p) => `<option value="${esc(p.model)}">${esc(p.label)}</option>`).join('')
      + (current && !known ? `<option value="${esc(current)}">${esc(current)}</option>` : '');
    sel.value = current || '';
  }
  function syncType() {
    const wifi = form.querySelector('[name=type]:checked').value === 'wifi';
    if (state.draft && state.draft.type !== (wifi ? 'wifi' : 'cell')) fillModels(wifi ? 'wifi' : 'cell', '');
    form.querySelector('.wifi-only').hidden = !wifi;
    slider.min = wifi ? 8 : 100; slider.max = wifi ? 250 : 6000;
    slider.value = form.elements.range.value;
  }
  function syncHeader() {
    const d = state.draft; if (!d) return;
    $('#ed-ico').innerHTML = towerIco({ ...d, active: form.elements.active.checked });
    $('#ed-title').textContent = form.elements.name.value || 'Untitled';
    $('#ed-sub').textContent = `${d.type === 'wifi' ? 'Wi-Fi access point' : 'Cell tower'} · ${form.elements.active.checked ? 'Online' : 'Offline'}`;
    $('#ed-conn').textContent = d.id ? connected(d) : '—';
    const r = +form.elements.range.value;
    $('#ed-range-s').textContent = r >= 1000 ? (r / 1000).toFixed(1) + ' km' : r + ' m';
  }
  form.addEventListener('input', (e) => {
    if (e.target === slider) form.elements.range.value = slider.value;
    if (e.target.name === 'range') slider.value = e.target.value;
    if (e.target.name === 'type') syncType();
    const d = state.draft;
    if (d) { d.x = +form.elements.x.value; d.y = +form.elements.y.value; d.range = +form.elements.range.value || d.range; d.type = form.querySelector('[name=type]:checked').value; d.active = form.elements.active.checked; }
    syncHeader(); draw();
  });
  // the online switch saves straight away for existing towers
  form.elements.active.addEventListener('change', async () => {
    if (!state.selected) return;
    try { await send(`${root.dataset.api}/${state.selected}`, 'PATCH', { active: form.elements.active.checked }); toast(form.elements.active.checked ? 'Tower back online' : 'Tower taken offline — phones nearby lose this signal'); refresh(); }
    catch (err) { toast(err.message, true); }
  });
  form.querySelector('[data-close]').addEventListener('click', closeEditor);
  form.querySelector('[data-eye]').addEventListener('click', (e) => {
    const pw = form.elements.password; pw.type = pw.type === 'password' ? 'text' : 'password';
    e.target.textContent = pw.type === 'password' ? 'Show' : 'Hide';
  });
  async function send(url, method, body) {
    const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': root.dataset.csrf }, body: body ? JSON.stringify(body) : undefined });
    const d = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(d.error || 'Request failed');
    return d;
  }
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = form.elements;
    const body = { type: form.querySelector('[name=type]:checked').value, name: f.name.value, x: f.x.value, y: f.y.value, z: f.z.value, range: f.range.value,
      ssid: f.ssid.value, jobs: f.jobs.value, active: f.active.checked, model: f.model.value, notes: f.notes.value, password: f.password.value };
    const btn = form.querySelector('[type=submit]'); btn.disabled = true;
    try {
      const saved = state.selected ? await send(`${root.dataset.api}/${state.selected}`, 'PATCH', body) : await send(root.dataset.api, 'POST', body);
      toast(`${saved.name} saved · phones update within seconds`);
      await refresh();
      openEditor(state.towers.find((t) => t.id === saved.id) || saved);
    } catch (err) { toast(err.message, true); }
    btn.disabled = false;
  });
  form.querySelector('[data-delete]').addEventListener('click', async () => {
    const t = state.towers.find((x) => x.id === state.selected);
    if (!t || !confirm(`Delete ${t.name}? Phones around it lose this signal.`)) return;
    try { await send(`${root.dataset.api}/${t.id}`, 'DELETE'); toast(`${t.name} deleted`); closeEditor(); refresh(); } catch (err) { toast(err.message, true); }
  });

  function toast(msg, bad) {
    const el = document.createElement('div');
    el.className = 'nm-toast' + (bad ? ' bad' : '');
    el.textContent = msg; $('.nm-map').appendChild(el);
    setTimeout(() => el.classList.add('out'), 2800);
    setTimeout(() => el.remove(), 3200);
  }

  /* ---------------- live data ---------------- */
  async function refresh() {
    try {
      const r = await fetch(root.dataset.live, { cache: 'no-store' });
      const d = await r.json();
      if (!r.ok) throw new Error(d.error || 'Live data unavailable');
      state.towers = d.towers || []; state.players = d.players || []; state.stats = d.stats || {}; state.enforce = d.enforce !== false;
      if (d.props) state.props = { cell: d.props.cell || [], wifi: d.props.wifi || [] };
      state.updated = Date.now();
      $('#tm-live').classList.remove('down');
      const err = $('#tm-error');
      err.hidden = state.enforce;
      if (!state.enforce) err.textContent = 'Coverage isn’t enforced (Config.Enforce = false) — every phone currently has full service.';
      const online = state.towers.filter((t) => t.active).length, s = state.stats;
      $('#st-towers').innerHTML = `${online}<small>/${state.towers.length}</small>`;
      $('#st-cover').textContent = Math.round(landCoverage() * 100) + '%';
      $('#st-players').textContent = s.players ?? 0;
      $('#st-signal').textContent = s.players ? Math.round((s.with_signal / s.players) * 100) + '%' : '—';
      $('#st-wifi').textContent = s.on_wifi ?? 0;
      if (form.hidden) renderList(); else syncHeader();
      draw();
    } catch (e) {
      $('#tm-live').classList.add('down');
      $('#tm-updated').textContent = 'Offline';
      const err = $('#tm-error'); err.hidden = false; err.textContent = e.message;
    }
  }
  setInterval(() => {
    if (!state.updated) return;
    const s = Math.round((Date.now() - state.updated) / 1000);
    $('#tm-updated').textContent = s < 2 ? 'Live · just now' : `Live · ${s}s ago`;
  }, 1000);

  addEventListener('resize', resize);
  if (window.ResizeObserver) new ResizeObserver(() => resize()).observe(canvas.parentElement);
  resize(); fit(); refresh();
  setInterval(refresh, 3000);
})();
