/* Engineer console — renders the context menus sent by client/console.lua */
(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-towers';
  const post = (name, data) => fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}) }).then((r) => r.json()).catch(() => null);
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const safeColor = (c) => (/^#[0-9a-f]{3,8}$|^[a-z]+$|^rgba?\([\d\s.,%]+\)$/i.test(c || '') ? c : '');
  const safeIcon = (i) => (/^[a-z0-9 -]+$/i.test(i || '') ? i : 'fa-solid fa-circle');

  document.body.insertAdjacentHTML('beforeend', `
    <div id="console">
      <div class="shade" data-a="close"></div>
      <div class="win">
        <aside>
          <div class="brand"><div class="mark"><i class="fa-solid fa-tower-broadcast"></i></div><div><b class="b-title">Engineer console</b><span>Network · power · field tools</span></div></div>
          <nav></nav>
          <div class="foot"><span><kbd>Esc</kbd> back</span><span><kbd>/</kbd> search</span><span><kbd>↑↓</kbd><kbd>Enter</kbd> pick</span></div>
        </aside>
        <main>
          <header>
            <button class="back" data-a="back" hidden><i class="fa-solid fa-arrow-left"></i></button>
            <div class="titles"><div class="crumbs"></div><h1></h1></div>
            <div class="search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="Search tools and actions…" spellcheck="false"></div>
            <button class="close" data-a="close"><i class="fa-solid fa-xmark"></i></button>
          </header>
          <div class="body"></div>
        </main>
      </div>
    </div>`);
  const root = document.getElementById('console');
  const $ = (s) => root.querySelector(s);
  const input = $('.search input');
  let menu = null, sel = -1, results = null, sectionK = null;

  const cardHtml = (o, i, extra = '') => {
    const c = safeColor(o.color);
    const meta = (o.meta || []).map((m) => `<span>${m.label != null ? esc(m.label) + ': ' : ''}${esc(m.value ?? '')}</span>`).join('');
    const prog = typeof o.progress === 'number' ? `<div class="bar"><span style="width:${Math.max(0, Math.min(100, o.progress))}%"></span></div>` : '';
    return `<button class="card ${o.disabled ? 'dis' : ''}" data-i="${i}" style="${c ? `--c:${c}` : ''}">
      <span class="ic"><i class="${esc(safeIcon(o.icon || 'fa-solid fa-circle-dot'))}"></i></span>
      <span class="tx"><div class="t">${esc(o.title)}</div>${o.description ? `<div class="d">${esc(o.description)}</div>` : ''}${prog}${meta ? `<div class="meta">${meta}</div>` : ''}
        ${extra}${o.arrow ? '<div class="go">Open <i class="fa-solid fa-chevron-right"></i></div>' : ''}</span>
    </button>`;
  };
  const infoHtml = (o) => {
    const c = safeColor(o.color);
    return `<div class="it" style="${c ? `--c:${c}` : ''}"><i class="${esc(safeIcon(o.icon || 'fa-solid fa-circle-info'))}"></i><div><b>${esc(o.title)}</b>${o.description ? `<span>${esc(o.description)}</span>` : ''}</div></div>`;
  };

  const render = () => {
    const body = $('.body');
    sel = -1;
    if (results) {
      body.innerHTML = results.length
        ? `<div class="group-h">${results.length} result${results.length === 1 ? '' : 's'}</div><div class="grid">${results.map((o, i) => cardHtml(o, i, `<div class="from">in ${esc(o.menuTitle)}</div>`)).join('')}</div>`
        : '<div class="empty"><i class="fa-solid fa-magnifying-glass"></i>Nothing found — open a section first to search inside it.</div>';
      return;
    }
    const opts = menu.options || [];
    const info = opts.filter((o) => o.readOnly);
    const act = opts.filter((o) => !o.readOnly);
    body.innerHTML = (info.length ? `<div class="info">${info.map(infoHtml).join('')}</div>` : '')
      + (act.length ? `<div class="grid">${act.map((o) => cardHtml(o, opts.indexOf(o))).join('')}</div>` : (info.length ? '' : '<div class="empty"><i class="fa-regular fa-folder-open"></i>Nothing here yet.</div>'));
  };

  const show = (m) => {
    if (!m.show) { root.classList.remove('show'); return; }
    menu = m.menu;
    results = null;
    input.value = '';
    if (m.brand) $('.b-title').textContent = m.brand;
    $('h1').textContent = menu.title || 'Engineer console';
    $('.back').hidden = !menu.canBack;
    const crumbs = (m.crumbs || []).slice(0, -1);
    $('.crumbs').innerHTML = crumbs.map((c) => `<a data-crumb="${esc(c.id)}">${esc(c.title)}</a><span class="sep">›</span>`).join('');
    if (m.sections) {
      if (m.root) sectionK = null;
      const here = ((m.crumbs || [])[1] || {}).title || '';
      $('nav').innerHTML = '<div class="lbl">Sections</div>' + m.sections.map((s) => `<button data-sec="${esc(String(s.k))}" class="${String(s.k) === String(sectionK) || (here && here.toLowerCase().includes(String(s.title).toLowerCase())) ? 'on' : ''}" style="${safeColor(s.color) ? `--c:${safeColor(s.color)}` : ''}"><i class="${esc(safeIcon(s.icon || 'fa-solid fa-circle'))}"></i>${esc(s.title)}</button>`).join('');
    }
    render();
    root.classList.add('show');
  };

  window.addEventListener('message', (e) => { const m = e.data; if (m && m.action === 'console') show(m); });

  const pick = (i) => {
    if (results) { const o = results[i]; if (o && !o.disabled) post('consoleSelect', { menu: o.menu, k: o.k }); return; }
    const o = menu && menu.options[i];
    if (!o || o.disabled || o.readOnly) return;
    post('consoleSelect', { menu: menu.id, k: o.k });
  };

  root.addEventListener('click', (e) => {
    const a = e.target.closest('[data-a]');
    if (a) return post(a.dataset.a === 'back' ? 'consoleBack' : 'consoleClose');
    const c = e.target.closest('.card[data-i]');
    if (c) return pick(+c.dataset.i);
    const s = e.target.closest('[data-sec]');
    if (s) { sectionK = s.dataset.sec; return post('consoleSection', { k: s.dataset.sec }); }
    const cr = e.target.closest('[data-crumb]');
    if (cr) return post('consoleCrumb', { id: cr.dataset.crumb });
  });

  let t = 0;
  input.addEventListener('input', () => {
    clearTimeout(t);
    const q = input.value.trim();
    if (q.length < 2) { results = null; return render(); }
    t = setTimeout(async () => {
      // this menu first (instant), then everything opened this session
      const here = (menu.options || []).filter((o) => !o.readOnly && (`${o.title} ${o.description || ''}`).toLowerCase().includes(q.toLowerCase()))
        .map((o) => ({ ...o, menu: menu.id, menuTitle: menu.title }));
      const all = (await post('consoleSearch', { q })) || [];
      const seen = new Set(here.map((o) => `${o.menu}|${o.k}`));
      results = [...here, ...all.filter((o) => !seen.has(`${o.menu}|${o.k}`))];
      render();
    }, 120);
  });

  const cards = () => [...root.querySelectorAll('.card[data-i]')];
  document.addEventListener('keydown', (e) => {
    if (!root.classList.contains('show')) return;
    const inSearch = document.activeElement === input;
    if (e.key === 'Escape') {
      e.preventDefault();
      if (inSearch && input.value) { input.value = ''; results = null; render(); return; }
      if (inSearch) { input.blur(); return; }
      return post(menu && menu.canBack ? 'consoleBack' : 'consoleClose');
    }
    if (e.key === '/' && !inSearch) { e.preventDefault(); input.focus(); return; }
    const list = cards();
    if (!list.length) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowRight' || (e.key === 'Tab' && !e.shiftKey)) { e.preventDefault(); sel = (sel + 1) % list.length; }
    else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft' || (e.key === 'Tab' && e.shiftKey)) { e.preventDefault(); sel = (sel - 1 + list.length) % list.length; }
    else if (e.key === 'Enter') { e.preventDefault(); const c = list[Math.max(0, sel)]; if (c) pick(+c.dataset.i); return; }
    else return;
    list.forEach((c, i) => c.classList.toggle('sel', i === sel));
    list[sel].scrollIntoView({ block: 'nearest' });
  });
})();
