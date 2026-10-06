'use strict';

/* =====================================================================
   OPS Academy — learn everything about every OPS job, on the phone or a laptop (server/training.lua)
   Same content and records as OPS Hub → Classroom and opsacademy.sa: every course (lessons, health & safety,
   exams, practical), the whole-system explainers and the slideshow courses. Anyone can read; signing in to
   OPS Work records lessons and lets you take the modules and exams. Lesson / quiz / course pages are OPS Work's.
   ===================================================================== */

const AC_COLOR = '#bf5af2';
const acIcon = (icon, color) => `<span class="ri" style="background:${color}"><i class="fa-solid fa-${icon}"></i></span>`;
const acSpin = '<div class="spinner" style="margin:60px auto"></div>';
const acRpc = async (name, data) => { const r = await rpc(name, data); return typeof onFix === 'function' ? onFix(r) : r; };

const Academy = {
    root: null,
    open(root, params) {
        this.root = root;
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: 'OPS Academy', large: true, grouped: true,
            render(c, ctx) {
                let tab = 'courses';
                const draw = () => {
                    const r = c._r;
                    if (!r) return;
                    const done = (x) => x && x.state === 'done';
                    const prog = (x) => (x.cert && x.cert.valid ? `<span class="on-pill" style="--c:#30d158">Certified</span>`
                        : r.signedIn ? `<span class="sub muted">${x.families.filter((f) => done(f.lesson)).length}/${x.families.length} lessons · ${x.families.filter((f) => done(f.safety)).length}/${x.families.length} safety · exam ${done(x.exam) ? '✓' : '—'}</span>`
                        : `<span class="sub muted">${x.families.length} module${x.families.length === 1 ? '' : 's'} · ${x.questions}-question exam</span>`);
                    const course = (x) => `<div class="row tap has-icon" data-cert="${x.code}" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">${acIcon(x.icon || 'graduation-cap', x.color || AC_COLOR)}
                        <div class="grow"><div><b>${esc(x.name)}</b></div><div class="sub muted" style="white-space:normal">${esc(x.company || '')} · ${x.families.map((f) => esc(f.name)).join(', ')}</div><div style="margin-top:5px">${prog(x)}</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`;
                    const mine = r.courses.filter((x) => x.mine), other = r.courses.filter((x) => !x.mine);
                    let body;
                    if (tab === 'courses') {
                        body = `${mine.length ? `<div class="group-header">Your companies’ courses</div><div class="group">${mine.map(course).join('')}</div>` : ''}
                            <div class="group-header">${mine.length ? 'Other courses' : 'Every course'}</div><div class="group">${other.map(course).join('')}</div>
                            <div class="group-footer">Each course: read the lessons, pass each job family’s health &amp; safety module, pass the exam (${r.passMark}%)${r.courses[0] && r.courses[0].needPractical ? ' and do the practical at an OPS Academy training centre' : ''}.</div>`;
                    } else if (tab === 'systems') {
                        body = `<div class="group" style="margin-top:12px">${r.systems.map((s) => `<div class="row tap has-icon" data-sys="${s.code}" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">${acIcon(s.icon || 'book', '#0a84ff')}
                            <div class="grow"><div><b>${esc(s.name)}</b></div><div class="sub muted" style="white-space:normal;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">${esc(s.intro || '')}</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}</div>
                            <div class="group-footer">How each whole system works — what feeds what, and what breaks when something is wrong.</div>`;
                    } else {
                        body = `<div class="group" style="margin-top:12px">${r.slideshows.map((s) => `<div class="row tap has-icon" data-show="${s.code}" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">${acIcon(s.icon || 'person-chalkboard', '#ff9f0a')}
                            <div class="grow"><div><b>${esc(s.name)}</b></div><div class="sub muted" style="white-space:normal">${esc(s.desc || '')}</div><div class="sub muted" style="margin-top:4px">${s.count} slides</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}</div>`;
                    }
                    c.innerHTML = `<div class="group" style="margin-top:8px"><div class="row has-icon" style="align-items:flex-start">${acIcon(r.signedIn ? 'user-graduate' : 'book-open-reader', AC_COLOR)}
                            <div class="grow" style="white-space:normal">${r.signedIn ? `<div><b>${esc(r.name || 'Signed in')}</b></div><div class="sub muted">Your progress is saved — it’s the same on OPS Hub → Classroom and opsacademy.sa.</div>`
                            : `<div><b>Learn anything, free</b></div><div class="sub muted">Sign in to OPS Work to record lessons and take the safety modules and exams.</div>`}</div></div>
                        ${!r.signedIn ? `<div class="row tap has-icon" data-signin>${acIcon('right-to-bracket', '#0a84ff')}<div class="grow">Sign in with OPS Work</div><i class="fa-solid fa-chevron-right chev"></i></div>` : ''}
                        ${r.centres && r.centres[0] ? `<div class="row tap has-icon" data-centre>${acIcon('location-dot', '#30d158')}<div class="grow"><div>${esc(r.centres[0].label || 'OPS Academy training centre')}</div><div class="sub muted">Practicals happen here — set GPS</div></div></div>` : ''}</div>
                        <div class="segmented" style="margin-top:12px"><button data-t="courses">Courses</button><button data-t="systems">Systems</button><button data-t="slides">Slideshows</button></div>${body}`;
                    $$('[data-t]', c).forEach((b) => b.classList.toggle('on', b.dataset.t === tab));
                };
                const load = async () => {
                    if (!c._r) c.innerHTML = acSpin;
                    const r = await acRpc('opsAcademy');
                    if (!r || r.error || !r.courses) { c.innerHTML = UI.empty('fa-solid fa-wifi', 'Can’t reach OPS Academy', (r && r.error) || 'You need signal or Wi-Fi to learn online.'); return; }
                    if (r.training === false) { c.innerHTML = UI.empty('fa-solid fa-graduation-cap', 'Training is off', 'Your server has switched training off.'); return; }
                    c._r = r;
                    draw();
                };
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => {
                    const r = c._r; if (!r) return;
                    const t = e.target.closest('[data-t]');
                    if (t) { tab = t.dataset.t; return draw(); }
                    const ce = e.target.closest('[data-cert]');
                    if (ce) return OwPages.course(nav, r.courses.find((x) => x.code === ce.dataset.cert), r, 'Academy');
                    const sy = e.target.closest('[data-sys]');
                    if (sy) return Academy.system(nav, sy.dataset.sys);
                    const sh = e.target.closest('[data-show]');
                    if (sh) return Academy.slides(nav, sh.dataset.show);
                    if (e.target.closest('[data-centre]')) { nui('opsGps', r.centres[0]); return UI.toast('Waypoint set', 'fa-solid fa-location-dot'); }
                    if (e.target.closest('[data-signin]')) return typeof Laptop !== 'undefined' && Laptop.active ? Laptop.openApp('opswork') : Phone.openApp('opswork');
                });
                if (params && params.show) Academy.slides(nav, params.show);
            },
        });
    },

    system(nav, code) {
        nav.push({
            title: 'System', grouped: true, backLabel: 'Academy',
            async render(c, ctx) {
                c.innerHTML = acSpin;
                const r = await acRpc('opsSystem', { code });
                if (!r || !r.system) { c.innerHTML = UI.empty('fa-solid fa-book', 'Not found', ''); return; }
                const s = r.system;
                ctx.setTitle && ctx.setTitle(s.name);
                c.innerHTML = `${s.sections.map((x) => `<div class="group-header">${esc(x.title)}</div><div class="group"><div class="row"><div class="grow" style="white-space:normal;line-height:1.45">${esc(x.body)}</div></div></div>`).join('')}
                    ${r.families.length ? `<div class="group-header">Jobs on this system — lessons</div><div class="group">${r.families.map((f) => `<div class="row tap has-icon" data-fam="${f.code}">${acIcon('book-open', '#0a84ff')}<div class="grow">${esc(f.name)}</div><i class="fa-solid fa-chevron-right chev"></i></div>`).join('')}</div>` : ''}`;
                c.addEventListener('click', (e) => { const f = e.target.closest('[data-fam]'); if (f) OwPages.lesson(nav, f.dataset.fam); });
            },
        });
    },

    slides(nav, code) {
        nav.push({
            title: 'Slideshow', grouped: true, backLabel: 'Academy',
            async render(c, ctx) {
                c.innerHTML = acSpin;
                const r = await acRpc('opsSlides', { code });
                if (!r || !r.show) { c.innerHTML = UI.empty('fa-solid fa-person-chalkboard', 'Not found', ''); return; }
                const show = r.show;
                ctx.setTitle && ctx.setTitle(show.name);
                let i = 0;
                const draw = () => {
                    const s = show.slides[i], last = i === show.slides.length - 1;
                    c.innerHTML = `<div style="padding:14px 16px 0"><div style="border-radius:18px;padding:20px 18px;background:linear-gradient(160deg,rgba(94,92,230,.22),rgba(10,132,255,.10));border:1px solid rgba(255,255,255,.08);min-height:300px">
                            <div style="width:46px;height:46px;border-radius:13px;display:grid;place-items:center;background:linear-gradient(140deg,#5e5ce6,#0a84ff);color:#fff;font-size:20px;margin-bottom:12px"><i class="fa-solid fa-${esc(s.icon || 'circle-info')}"></i></div>
                            <div style="font-size:20px;font-weight:700;margin-bottom:12px;line-height:1.25">${esc(s.title)}</div>
                            <ul style="margin:0;padding-left:18px;display:grid;gap:9px;line-height:1.45;font-size:14px">${(Array.isArray(s.body) ? s.body : [s.body]).map((b) => `<li>${esc(b)}</li>`).join('')}</ul></div>
                        <div style="display:flex;gap:5px;justify-content:center;margin:12px 0">${show.slides.map((_, k) => `<i data-dot="${k}" style="width:7px;height:7px;border-radius:50%;cursor:pointer;background:${k === i ? '#0a84ff' : 'rgba(128,128,128,.4)'}"></i>`).join('')}</div>
                        <div style="display:flex;gap:10px;padding-bottom:16px"><button class="btn gray" data-prev style="flex:1" ${i === 0 ? 'disabled' : ''}>Back</button><button class="btn" data-next style="flex:1">${last ? 'Finish' : 'Next'}</button></div>
                        <div class="sub muted" style="text-align:center;padding-bottom:16px">${i + 1} / ${show.slides.length}</div></div>`;
                };
                draw();
                c.addEventListener('click', (e) => {
                    const d = e.target.closest('[data-dot]');
                    if (d) { i = +d.dataset.dot; return draw(); }
                    if (e.target.closest('[data-prev]') && i > 0) { i -= 1; return draw(); }
                    if (e.target.closest('[data-next]')) { if (i === show.slides.length - 1) return nav.pop(); i += 1; draw(); }
                });
            },
        });
    },
};

Apps.register({
    id: 'academy', name: 'OPS Academy', resumable: false,
    splash: `linear-gradient(160deg,#1c1c1e,${AC_COLOR} 80%)`,
    icon: { bg: `linear-gradient(150deg,#5e5ce6,${AC_COLOR} 60%,#ff375f 140%)`, html: () => '<i class="fa-solid fa-graduation-cap" style="font-size:28px;color:#fff"></i>' },
    open(root, params) { return Academy.open(root, params); },
    onClose() { Academy.root = null; },
});
