'use strict';

/* =====================================================================
   OPS Work — the OPS group's staff + customer app (server/platform.lua)
   · Customers (no account needed): ask any OPS company for a service, follow it, see invoices
   · Staff (Ops-Networks account): companies you work for, job boards, your jobs with live checks of the
     real work, earnings, company news, employees / applications, finance, dispatch
   One app per company too (OPS Network, OPS Secure, OPS Fibre…): the same app opened on that company.
   ===================================================================== */

const OW_STATUS = { open: ['Available', '#0a84ff'], assigned: ['Assigned', '#ff9f0a'], in_progress: ['In progress', '#bf5af2'], completed: ['Completed', '#30d158'], cancelled: ['Cancelled', '#8e8e93'] };
const owPill = (k) => { const [l, c] = OW_STATUS[k] || [k, '#8e8e93']; return `<span class="on-pill" style="--c:${c}">${esc(l)}</span>`; };
const owMoney = (v) => '$' + Number(v || 0).toLocaleString(undefined, { maximumFractionDigits: 2 });
const owSpin = '<div class="spinner" style="margin:40px auto"></div>';
const owFix = (v) => (typeof onFix === 'function' ? onFix(v) : v);
async function owRpc(name, data) {
    const res = owFix(await rpc(name, data));
    if (res && res.loggedOut) { OpsWork.me = null; UI.toast('Signed out', 'fa-solid fa-right-from-bracket'); OpsWork.home(); return null; }
    if (res && res.denied) { UI.alert({ title: 'Not Allowed', message: res.error || "You don't have permission for that." }); return null; }
    return res;
}
const owIcon = (icon, color) => `<span class="ri" style="background:${color}"><i class="fa-solid fa-${icon}"></i></span>`;
const owWhen = (t) => (t ? (typeof shortAgo === 'function' ? shortAgo(t * 1000) : new Date(t * 1000).toLocaleString()) : '');

/* real addresses: the game works out street / crossing / district for each job location */
const OW_ADDR = new Map();
async function owAddresses(jobs) {
    const want = jobs.filter((j) => j.x != null);
    if (!want.length) return;
    const res = await nui('opsAddresses', { points: want.map((j) => ({ x: j.x, y: j.y, z: j.z })) });
    (res || []).forEach((a, i) => { if (a) OW_ADDR.set(want[i].id, a); });
}
const owDist = (m) => (m >= 1000 ? (m / 1000).toFixed(1) + ' km' : m + ' m');
/** the address lines for a job: [headline, detail] */
function owAddr(j) {
    const a = OW_ADDR.get(j.id) || {};
    const street = a.street ? a.street + (a.cross ? ' / ' + a.cross : '') : '';
    let head = j.customerAddress && j.customerAddress !== j.customer ? j.customerAddress : (j.customer || j.location || 'Job location');
    let detail = [street, a.zone].filter(Boolean).join(' · ');
    if (j.customerKind === 'residential' && j.customerAddress) head = j.customerAddress;
    else if (j.customer && street) { head = j.customer; detail = [street, a.zone].filter(Boolean).join(' · '); }
    return [head, detail, a.dist != null ? `${owDist(a.dist)} ${a.dir || ''}`.trim() : ''];
}
const OW_KIND = { residential: ['Home', 'house', '#30d158'], business: ['Business', 'store', '#0a84ff'], police: ['Police', 'shield-halved', '#5e5ce6'], government: ['Government', 'landmark', '#ff9f0a'] };

/** SLA: "due in 3 h" / "overdue 20 min" */
function owDue(j) {
    if (!j.due || j.status === 'completed' || j.status === 'cancelled') return '';
    const s = j.due - Math.floor(Date.now() / 1000);
    const f = (x) => (x >= 3600 ? Math.round(x / 3600) + ' h' : Math.max(1, Math.round(x / 60)) + ' min');
    return s < 0 ? `<span style="color:#ff453a;font-weight:700">SLA overdue ${f(-s)}</span>` : `<span style="color:${s < 3600 ? '#ff9f0a' : 'inherit'}">Due in ${f(s)}</span>`;
}
function owJobRow(j) {
    const [head, detail, dist] = owAddr(j);
    const k = OW_KIND[j.customerKind] || ['', 'location-dot', '#8e8e93'];
    return `<div class="row tap ow-job" data-job="${j.id}" style="align-items:flex-start;padding-top:12px;padding-bottom:12px">
        <span class="ri" style="background:${j.emergency ? '#ff3b30' : (j.color || '#0a84ff')};margin-top:2px"><i class="fa-solid fa-${j.emergency ? 'triangle-exclamation' : (j.icon || 'briefcase')}"></i></span>
        <div class="grow" style="min-width:0">
            <div style="display:flex;gap:6px;align-items:center"><b style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(j.title)}</b>${owPill(j.status)}</div>
            <div style="margin-top:3px;display:flex;gap:6px;align-items:center"><i class="fa-solid fa-${k[1]}" style="color:${k[2]};font-size:11px;width:13px"></i><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(head)}</span></div>
            ${detail ? `<div class="sub muted" style="margin-left:19px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(detail)}</div>` : ''}
            <div class="sub muted" style="margin-top:4px;display:flex;gap:10px">${dist ? `<span><i class="fa-solid fa-location-arrow"></i> ${esc(dist)}</span>` : ''}<span><i class="fa-solid fa-sack-dollar"></i> ${owMoney(j.wage)}</span>${j.emergency ? '<span style="color:#ff453a;font-weight:700">EMERGENCY</span>' : ''}${owDue(j)}<span class="muted">${esc(j.ref)}</span></div>
        </div></div>`;
}
async function owRenderList(list, jobs, emptyHtml) {
    if (!jobs.length) { list.innerHTML = emptyHtml; return; }
    list.innerHTML = `<div class="group">${jobs.map(owJobRow).join('')}</div>`;
    await owAddresses(jobs);
    if (document.body.contains(list)) list.innerHTML = `<div class="group">${jobs.map(owJobRow).join('')}</div>`;
}

const OpsWork = {
    root: null, nav: null, me: null, focus: null, params: null,

    async open(root, params, focus) {
        this.root = root;
        this.focus = focus || null;
        this.params = params || null;
        root.innerHTML = '<div class="spinner" style="margin-top:300px"></div>';
        const s = owFix(await rpc('opsnetSession'));
        this.me = null;
        if (s && s.loggedIn) {
            const m = await owRpc('opsMe');
            this.me = m && m.me;
        }
        this.home();
    },

    home() {
        const root = this.root;
        if (!root) return;
        root.innerHTML = '';
        const nav = this.nav = new Nav(root);
        const me = this.me;
        const focusCo = this.focus && me && me.companies.find((c) => c.code === this.focus);
        if (focusCo) return OwPages.company(nav, focusCo, true);
        nav.push({
            title: 'OPS Work',
            large: true,
            grouped: true,
            render(c) {
                const cos = me ? me.companies : [];
                c.innerHTML = `
                    ${me ? `<div class="group-header">Signed in as ${esc(me.name)}${me.super ? ' · Super Admin' : ''}</div>
                    <div class="group">
                        <div class="row tap has-icon" data-p="mine">${owIcon('person-digging', '#ff9f0a')}<div class="grow">My Jobs</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="earnings">${owIcon('sack-dollar', '#30d158')}<div class="grow">Earnings</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="training">${owIcon('graduation-cap', '#bf5af2')}<div class="grow"><div>Training & certifications</div><div class="sub muted">Needed for installation jobs</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="kit">${owIcon('van-shuttle', '#64d2ff')}<div class="grow">My van & tools</div><i class="fa-solid fa-chevron-right chev"></i></div>
                    </div>
                    ${me.companies.some((c) => c.code === 'network' || c.code === 'fibre') ? `<div class="group"><div class="row tap has-icon" data-p="lineTool">${owIcon('ethernet', '#30d158')}<div class="grow"><div>Line at this address</div><div class="sub muted">Customer, package, IPs, router settings, speed test</div></div><i class="fa-solid fa-chevron-right chev"></i></div></div>` : ''}
                    <div class="group-header">My companies</div>
                    <div class="group">${cos.length ? cos.map((co) => `<div class="row tap has-icon" data-co="${co.code}">${owIcon(co.icon, co.color)}
                        <div class="grow"><div>${esc(co.name)}</div><div class="sub muted">${esc(co.role)}${co.balance != null ? ' · ' + owMoney(co.balance) : ''}</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`).join('')
                        : '<div class="row"><div class="grow muted">You don’t work for any OPS company yet — apply below.</div></div>'}</div>
                    ${me.others.length ? `<div class="group-header">Apply to join</div><div class="group">${me.others.map((co) => `<div class="row tap has-icon" data-apply="${co.code}">${owIcon(co.icon, co.color)}
                        <div class="grow"><div>${esc(co.name)}</div><div class="sub muted">${esc(co.tagline || '')}</div></div>${co.applied ? '<span class="sub muted">Applied</span>' : '<i class="fa-solid fa-plus chev"></i>'}</div>`).join('')}</div>` : ''}`
                    : `<div class="group"><div class="row tap has-icon" data-p="login">${owIcon('right-to-bracket', '#0a84ff')}<div class="grow"><div>Staff sign in</div><div class="sub muted">Work for OPS Network, OPS Secure, OPS Fibre…</div></div><i class="fa-solid fa-chevron-right chev"></i></div></div>`}
                    <div class="group-header">Customers</div>
                    <div class="group">
                        <div class="row tap has-icon" data-p="services">${owIcon('screwdriver-wrench', '#5e5ce6')}<div class="grow"><div>Request a service</div><div class="sub muted">Internet, CCTV, phone lines, IT, power, solar…</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="broadband">${owIcon('wifi', '#0a84ff')}<div class="grow"><div>My broadband</div><div class="sub muted">Your line, speed test, bills, report a fault</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="requests">${owIcon('file-invoice-dollar', '#64d2ff')}<div class="grow">My requests & invoices</div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="mystuff">${owIcon('file-signature', '#ff9f0a')}<div class="grow"><div>Quotes, contracts & warranties</div><div class="sub muted">Accept quotes · your kit and its warranty</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                        <div class="row tap has-icon" data-p="tickets">${owIcon('headset', '#30d158')}<div class="grow"><div>Support</div><div class="sub muted">Ask any OPS company for help</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                    </div>
                    ${me && (me.super || me.companies.some((co) => (co.perms || []).includes('admin.settings'))) ? `<div class="group-header">Server</div><div class="group"><div class="row tap has-icon" data-p="admin">${owIcon('sliders', '#8e8e93')}<div class="grow"><div>Admin settings</div><div class="sub muted">Systems on/off, play mode, jobs, companies</div></div><i class="fa-solid fa-chevron-right chev"></i></div></div>` : ''}
                    ${me ? `<div class="group"><div class="row tap has-icon" data-p="pw">${owIcon('key', '#636366')}<div class="grow">Change Password</div></div>
                        <div class="row tap has-icon" data-p="logout">${owIcon('right-from-bracket', '#ff3b30')}<div class="grow">Sign Out</div></div></div>` : ''}`;
                c.addEventListener('click', async (e) => {
                    const co = e.target.closest('[data-co]');
                    if (co) return OwPages.company(nav, cos.find((x) => x.code === co.dataset.co));
                    const ap = e.target.closest('[data-apply]');
                    if (ap) {
                        const note = await UI.prompt('Apply to join', 'Tell them about yourself (optional)', { placeholder: 'Experience, availability…' });
                        if (note === null) return;
                        const r = await owRpc('opsApply', { company: ap.dataset.apply, note });
                        if (r && r.ok) { UI.toast('Application sent'); OpsWork.refresh(); }
                        return;
                    }
                    const p = e.target.closest('[data-p]');
                    if (!p) return;
                    const k = p.dataset.p;
                    if (k === 'login') return OwPages.login(nav);
                    if (k === 'logout') { await rpc('opsnetLogout'); OpsWork.me = null; return OpsWork.home(); }
                    if (k === 'pw') return OpsNet.changePassword ? OpsNet.changePassword() : null;
                    if (OwPages[k]) OwPages[k](nav);
                });
                if (me && me.defaultPassword) UI.alert({ title: 'Change your password', message: 'This account still has its default password. Change it now.' }).then(() => OpsNet.changePassword && OpsNet.changePassword());
                const p = OpsWork.params; OpsWork.params = null;
                if (p && p.page === 'job' && p.id && me) OwPages.job(nav, p.id);
                else if (p && p.page === 'earnings' && me) OwPages.earnings(nav);
                else if (p && p.page === 'invoices') OwPages.requests(nav);
                else if (p && p.page === 'broadband') OwPages.broadband(nav);
                else if (p && p.page === 'mystuff') OwPages.mystuff(nav);
            },
        });
    },

    async refresh() { const m = await owRpc('opsMe'); if (m) { this.me = m.me; this.home(); } },
};

const OW_LINE = { up: ['Online', '#30d158'], degraded: ['Degraded', '#ff9f0a'], down: ['Down', '#ff3b30'] };
const OW_SVC = { pending_install: ['Installation booked', '#ff9f0a'], active: ['Active', '#30d158'], suspended: ['Suspended', '#ff3b30'], cancelled: ['Cancelled', '#8e8e93'] };
const owChip = (map, k) => { const [l, c] = map[k] || [k || '—', '#8e8e93']; return `<span class="on-pill" style="--c:${c}">${esc(l)}</span>`; };
function owSpeedResult(r) {
    if (!r || r.error) return UI.alert({ title: 'Speed test', message: (r && r.error) || 'Couldn’t run the test' });
    UI.alert({ title: `${r.down_mbps} Mbps down`, message: `${r.up_mbps} Mbps up · ${r.ping_ms} ms ping · ${r.jitter_ms} ms jitter\n${r.via === 'ethernet' ? 'Wired (Ethernet)' : 'Over Wi-Fi'} · ${r.pct}% of ${r.package} (${r.plan_down} Mbps)\nLine ${r.line}` });
}

const OW_CERT = { valid: ['Certified', '#30d158'], expired: ['Expired', '#ff9f0a'], none: ['Not taken', '#8e8e93'] };
const owDate = (t) => (t ? new Date(t * 1000).toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) : '—');

const OwPages = {
    training(nav) {
        nav.push({
            title: 'Training', grouped: true, backLabel: 'OPS Work',
            render(c, ctx) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = await owRpc('opsTraining');
                    if (!r || r.disabled) { c.innerHTML = UI.empty('fa-solid fa-graduation-cap', 'Training is off', 'Your server has switched training off.'); return; }
                    if (!r.certs) { c.innerHTML = UI.empty('fa-solid fa-graduation-cap', 'Sign in', 'Training is for OPS staff.'); return; }
                    const st = (x) => (x.cert && x.cert.valid ? owChip(OW_CERT, 'valid') + `<span class="sub muted"> until ${owDate(x.cert.expires)}</span>`
                        : x.cert ? owChip(OW_CERT, 'expired') : `<span class="sub muted">${x.families.filter((f) => f.safety.state === 'done').length}/${x.families.length} safety · exam ${x.exam.state === 'done' ? '✓' : '—'}${x.needPractical ? ` · practical ${x.practical.state === 'done' ? '✓' : '—'}` : ''}</span>`);
                    const row = (x) => `<div class="row tap has-icon" data-cert="${x.code}" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">${owIcon(x.icon || 'graduation-cap', x.color || '#bf5af2')}
                        <div class="grow"><div><b>${esc(x.name)}</b></div><div class="sub muted" style="white-space:normal">${esc(x.company || '')} · ${x.families.map((f) => esc(f.name)).join(', ')}</div><div style="margin-top:5px">${st(x)}</div></div><i class="fa-solid fa-chevron-right chev"></i></div>`;
                    const mine = r.certs.filter((x) => x.mine), other = r.certs.filter((x) => !x.mine);
                    c.innerHTML = `<div class="group-header">Your companies’ courses</div><div class="group">${mine.map(row).join('') || '<div class="row"><div class="grow muted">Join an OPS company to see its courses</div></div>'}</div>
                        ${other.length ? `<div class="group-header">Other courses</div><div class="group">${other.map(row).join('')}</div>` : ''}
                        <div class="group-footer">Each course: read the lessons, pass each job family’s health &amp; safety module, pass the exam (${r.passMark}%)${r.certs[0] && r.certs[0].needPractical ? ' and do the practical at an OPS Academy training centre' : ''}. The full classroom is on OPS Hub → Classroom.</div>`;
                    c._r = r;
                };
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => { const x = e.target.closest('[data-cert]'); if (x) OwPages.course(nav, c._r.certs.find((y) => y.code === x.dataset.cert), c._r); });
            },
        });
    },

    course(nav, cert, all, back) {
        if (!cert) return;
        nav.push({
            title: cert.name, grouped: true, backLabel: back || 'Training',
            render(c) {
                const done = (x) => x && x.state === 'done';
                const tick = '<i class="fa-solid fa-check" style="color:#30d158"></i>', chev = '<i class="fa-solid fa-chevron-right chev"></i>';
                c.innerHTML = `${cert.cert && cert.cert.valid ? `<div class="group" style="margin-top:12px"><div class="row has-icon">${owIcon('award', '#30d158')}<div class="grow"><div><b>Certified</b></div><div class="sub muted">Until ${owDate(cert.cert.expires)}</div></div></div></div>` : ''}
                    ${cert.families.map((f) => `<div class="group-header">${esc(f.name)} · ${f.jobs} job type${f.jobs === 1 ? '' : 's'}${f.required ? ' · certificate required' : ''}</div><div class="group">
                        <div class="row tap has-icon" data-lesson="${f.code}">${owIcon('book-open', '#0a84ff')}<div class="grow"><div>Lesson</div><div class="sub muted">The job, the kit, every step, what goes wrong</div></div>${done(f.lesson) ? tick : chev}</div>
                        <div class="row tap has-icon" data-safety="${f.code}">${owIcon('helmet-safety', '#ff9f0a')}<div class="grow"><div>Health &amp; safety</div><div class="sub muted">${done(f.safety) ? `Passed ${f.safety.score}% · until ${owDate(f.safety.expires)}` : 'Needed before you can take these jobs'}</div></div>${done(f.safety) ? tick : chev}</div></div>`).join('')}
                    <div class="group-header">Certification</div><div class="group">
                        <div class="row tap has-icon" data-exam>${owIcon('file-pen', '#bf5af2')}<div class="grow"><div>Exam · ${cert.questions} questions</div><div class="sub muted">${done(cert.exam) ? `Passed ${cert.exam.score}%` : `Pass mark ${all.passMark}%`}</div></div>${done(cert.exam) ? tick : chev}</div>
                        ${cert.needPractical ? `<div class="row tap has-icon" data-practical>${owIcon('person-chalkboard', '#30d158')}<div class="grow"><div>Practical</div><div class="sub muted">${done(cert.practical) ? `Passed ${cert.practical.score}%` : 'At an OPS Academy training centre, step by step with the assessor'}</div></div>${done(cert.practical) ? tick : chev}</div>
                        <div class="row tap has-icon" data-centre>${owIcon('location-dot', '#636366')}<div class="grow">GPS to the training centre</div></div>` : ''}</div>`;
                c.addEventListener('click', async (e) => {
                    const l = e.target.closest('[data-lesson]'), s = e.target.closest('[data-safety]');
                    if (l) return OwPages.lesson(nav, l.dataset.lesson);
                    if (all.signedIn === false && (s || e.target.closest('[data-exam],[data-practical]')))
                        return UI.alert({ title: 'Sign in to take it', message: 'Everyone can read the lessons. Sign in to OPS Work with your OPS account to take the health & safety modules, exams and the practical — results count in game, on the laptop and on OPS Hub.' });
                    if (s) return OwPages.quiz(nav, 'safety', s.dataset.safety);
                    if (e.target.closest('[data-exam]')) return OwPages.quiz(nav, 'exam', cert.code);
                    if (e.target.closest('[data-centre]') && all.centres && all.centres[0]) { nui('opsGps', all.centres[0]); return UI.toast('Waypoint set', 'fa-solid fa-location-dot'); }
                    if (e.target.closest('[data-practical]')) {
                        const r = await nui('opsPractical', { code: cert.code });
                        if (r && r.error) UI.alert({ title: 'Practical', message: r.error + (r.centres ? ' — a waypoint has been set.' : '') });
                    }
                });
            },
        });
    },

    lesson(nav, family) {
        nav.push({
            title: 'Lesson', grouped: true, backLabel: 'Course',
            async render(c, ctx) {
                c.innerHTML = owSpin;
                const r = await owRpc('opsLesson', { family });
                if (!r || !r.family) { c.innerHTML = UI.empty('fa-solid fa-book', 'Not found', ''); return; }
                const f = r.family;
                ctx.setTitle && ctx.setTitle(f.name);
                const para = (t) => `<div class="row"><div class="grow" style="white-space:normal;line-height:1.45">${esc(t)}</div></div>`;
                const blk = 'style="display:block;white-space:normal"';
                c.innerHTML = `<div class="group-header">Overview</div><div class="group">${para(f.overview)}</div>
                    <div class="group-header">The equipment — what it does</div><div class="group">${(f.equipment || []).map((x) => `<div class="row" ${blk}><b>${esc(x.name)}</b><div class="sub" style="margin-top:3px">${esc(x.what)}</div><div class="sub muted" style="margin-top:3px"><i class="fa-solid fa-hand-pointer"></i> ${esc(x.how)}</div></div>`).join('')}</div>
                    <div class="group-header">Tools &amp; PPE</div><div class="group">${f.tools.concat(f.ppe).map((x) => `<div class="row" ${blk}><b>${esc(x.name)}</b><div class="sub muted">${esc(x.what || '')}</div></div>`).join('')}</div>
                    <div class="group-header">Step by step</div><div class="group">${(f.steps || []).map((x, i) => `<div class="row tap" data-step="${i}" ${blk}><b>${i + 1}. ${esc(x.title)}</b><div class="sub" style="margin-top:3px">${esc(x.detail)}</div>${x.where ? `<div class="sub muted" style="margin-top:3px"><i class="fa-solid fa-location-dot"></i> ${esc(x.where)}</div>` : ''}</div>`).join('')}</div>
                    <div class="group-header">Health &amp; safety</div><div class="group">${(f.safety || []).map((x) => `<div class="row" ${blk}><b style="color:#ff9f0a">${esc(x.hazard)}</b><div class="sub">${esc(x.risk)}</div><div class="sub muted" style="margin-top:3px"><i class="fa-solid fa-shield"></i> ${esc(x.control)}</div></div>`).join('')}</div>
                    <div class="group-header">What goes wrong</div><div class="group">${(f.mistakes || []).map((x) => `<div class="row" ${blk}><b style="color:#ff453a">${esc(x.mistake)}</b><div class="sub">${esc(x.consequence)}</div></div>`).join('')}</div>
                    <div class="group-footer">Tap a step to see the move. The full classroom, with whole-system explainers, is on OPS Hub → Classroom.</div>`;
                c.addEventListener('click', (e) => { const s = e.target.closest('[data-step]'); if (s) { const st = f.steps[+s.dataset.step]; nui('opsDoStep', { title: st.title, secs: 5, anim: st.anim }); } });
            },
        });
    },

    quiz(nav, kind, ref) {
        nav.push({
            title: kind === 'safety' ? 'Health & safety' : 'Exam', grouped: true, backLabel: 'Course',
            async render(c, ctx) {
                c.innerHTML = owSpin;
                const r = await owRpc(kind === 'safety' ? 'opsSafetyQuiz' : 'opsCourse', kind === 'safety' ? { family: ref } : { code: ref });
                if (!r || r.error || !r.questions) { c.innerHTML = UI.empty('fa-solid fa-hourglass-half', 'Not now', (r && r.error) || 'Try again'); return; }
                ctx.setTitle && ctx.setTitle(r.name);
                const answers = {};
                c.innerHTML = `${kind === 'safety' ? `<div class="group-header">Read first</div><div class="group">${(r.hazards || []).map((h) => `<div class="row" style="display:block;white-space:normal"><b style="color:#ff9f0a">${esc(h.hazard)}</b><div class="sub muted"><i class="fa-solid fa-shield"></i> ${esc(h.control)}</div></div>`).join('')}</div>` : ''}
                    ${r.questions.map((q, i) => `<div class="group-header">Question ${i + 1} of ${r.questions.length}</div><div class="group">
                    <div class="row"><div class="grow" style="white-space:normal"><b>${esc(q.q)}</b></div></div>
                    ${q.a.map((opt, k) => `<div class="row tap" data-q="${i}" data-a="${k + 1}"><i class="fa-regular fa-circle" style="color:#0a84ff;width:20px"></i><div class="grow" style="white-space:normal">${esc(opt)}</div></div>`).join('')}</div>`).join('')}
                    <div style="padding:16px"><button class="btn block" data-submit>Submit answers</button></div>`;
                c.addEventListener('click', async (e) => {
                    const o = e.target.closest('[data-q]');
                    if (o) {
                        answers[+o.dataset.q + 1] = +o.dataset.a;
                        $$(`[data-q="${o.dataset.q}"] i`, c).forEach((i) => { i.className = 'fa-regular fa-circle'; });
                        $('i', o).className = 'fa-solid fa-circle-check';
                        return;
                    }
                    const sub = e.target.closest('[data-submit]');
                    if (!sub || sub.disabled) return;
                    if (Object.keys(answers).length < r.questions.length) return UI.toast('Answer every question', 'fa-solid fa-circle-exclamation');
                    const list = r.questions.map((_, i) => answers[i + 1]);
                    sub.disabled = true;    // one attempt per tap
                    const res = await owRpc(kind === 'safety' ? 'opsSafetyAnswer' : 'opsExam', kind === 'safety' ? { family: ref, answers: list } : { code: ref, answers: list });
                    sub.disabled = false;
                    if (!res) return;
                    if (res.error) return UI.alert({ title: 'Training', message: res.error });
                    await UI.alert({ title: res.ok ? (res.certified ? 'Passed — certified!' : 'Passed') : 'Not this time',
                        message: `${res.right} of ${res.total} right (${res.score}%).${res.ok ? (res.needPractical ? ' Now do the practical at an OPS Academy training centre.' : '') : ' Revise the lesson and try again in a minute.'}` });
                    nav.pop();
                });
            },
        });
    },

    guide(nav, id) {
        nav.push({
            title: 'Job assistant', grouped: true, backLabel: 'Job',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const g = await owRpc('opsGuide', { id });
                    if (!g || g.error || g.disabled) { c.innerHTML = UI.empty('fa-solid fa-life-ring', 'No guide', (g && g.error) || 'The job assistant is off.'); return; }
                    const cur = g.steps[g.current - 1];
                    const mine = g.mine;
                    const blk = 'style="display:block;white-space:normal"';
                    c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row has-icon" style="align-items:flex-start">${owIcon('life-ring', '#0a84ff')}<div class="grow"><div><b>${esc(g.family.name)}</b></div><div class="sub muted" style="white-space:normal">${esc(g.family.summary)}</div></div></div>
                        ${g.cert ? `<div class="row has-icon">${owIcon('award', g.cert.have ? '#30d158' : (g.cert.required ? '#ff453a' : '#8e8e93'))}<div class="grow"><div>${esc(g.cert.name || g.cert.code)}</div><div class="sub muted">${g.cert.have ? 'You’re certified' : g.cert.required ? 'Required — OPS Work → Training' : 'Recommended'}</div></div></div>` : ''}
                        ${!g.safetyDone ? `<div class="row tap has-icon" data-train>${owIcon('helmet-safety', '#ff9f0a')}<div class="grow"><div>Safety module not done</div><div class="sub muted">Training → this course</div></div></div>` : ''}</div>
                        ${mine && g.needRA && !g.ra ? `<div class="group-header">Before you start</div><div class="group"><div class="row tap has-icon" data-ra>${owIcon('clipboard-check', '#ff9f0a')}<div class="grow"><div><b>Do the risk assessment</b></div><div class="sub muted">Needed before work and before completing</div></div><i class="fa-solid fa-chevron-right chev"></i></div></div>` : ''}
                        ${cur && mine ? `<div class="group-header">Next step</div><div class="group"><div class="row" ${blk}><b>${g.current}. ${esc(cur.title)}</b><div class="sub" style="margin-top:4px">${esc(cur.detail)}</div>
                            ${cur.where ? `<div class="sub muted" style="margin-top:4px"><i class="fa-solid fa-location-dot"></i> ${esc(cur.where)}</div>` : ''}${cur.tool ? `<div class="sub muted"><i class="fa-solid fa-toolbox"></i> ${esc((g.tools.find((t) => t.id === cur.tool) || {}).name || cur.tool)}</div>` : ''}</div>
                            <div class="row tap has-icon" data-show="${g.current - 1}">${owIcon('person-running', '#30d158')}<div class="grow">Show me (animation)</div></div></div>` : ''}
                        ${g.check ? `<div class="group"><div class="row has-icon">${owIcon(g.check.ok ? 'circle-check' : 'hourglass-half', g.check.ok ? '#30d158' : '#ff9f0a')}<div class="grow"><div>${esc(g.check.label || 'Work check')}</div><div class="sub muted" style="white-space:normal">${g.check.have || 0} / ${g.check.need || 1}${g.check.detail ? ' · ' + esc(g.check.detail) : ''}</div></div></div></div>` : ''}
                        <div class="group-header">All steps</div><div class="group">${g.steps.map((s, i) => { const d = mine && i < g.current - 1, n = mine && i === g.current - 1;
                            return `<div class="row tap has-icon" data-show="${i}" style="align-items:flex-start">${owIcon(d ? 'check' : (n ? 'play' : 'circle'), d ? '#30d158' : (n ? '#0a84ff' : '#8e8e93'))}<div class="grow" style="white-space:normal"><div>${i + 1}. ${esc(s.title)}</div><div class="sub muted">${esc(s.detail)}</div></div></div>`; }).join('')}</div>
                        <div class="group-header">Tools ${g.mode === 'items' ? '(inventory)' : '(in your van)'}</div><div class="group">${g.tools.map((t) => `<div class="row has-icon">${owIcon('toolbox', t.missing ? '#ff453a' : '#64d2ff')}<div class="grow" style="white-space:normal"><div>${esc(t.name)}${t.missing ? ' <span style="color:#ff453a">· missing</span>' : ''}</div><div class="sub muted">${esc(t.what || '')}</div></div></div>`).join('') || '<div class="row"><div class="grow muted">No special tools</div></div>'}
                            ${g.depot ? `<div class="row tap has-icon" data-depot>${owIcon('warehouse', '#636366')}<div class="grow"><div>GPS to ${esc(g.depot.label)}</div><div class="sub muted">${g.depot.dist} m · ${g.mode === 'items' ? 'collect tools, PPE and parts here' : 'OPS depot'}</div></div></div>` : ''}
                            ${(g.missingParts || []).length ? `<div class="row"><div class="grow sub" style="color:#ff453a;white-space:normal">Parts to collect: ${g.missingParts.map((p) => esc(p.sku) + ' × ' + p.qty).join(', ')}</div></div>` : ''}</div>
                        <div class="group-header">Health &amp; safety</div><div class="group">${g.ppe.map((p) => `<div class="row has-icon">${owIcon('helmet-safety', p.have ? '#ff9f0a' : '#ff453a')}<div class="grow">${esc(p.name)}${p.have ? '' : ' <span style="color:#ff453a">· not in inventory</span>'}</div></div>`).join('')}
                            ${g.safety.map((h) => `<div class="row" ${blk}><b style="color:#ff9f0a">${esc(h.hazard)}</b><div class="sub muted">${esc(h.control)}</div></div>`).join('')}</div>
                        <div class="group-header">What goes wrong</div><div class="group">${g.mistakes.map((m) => `<div class="row" ${blk}><b style="color:#ff453a">${esc(m.mistake)}</b><div class="sub muted">${esc(m.consequence)}</div></div>`).join('')}</div>
                        <div class="group-footer">Tip: type /jobhelp in game for this without opening the phone.</div>`;
                    c._g = g;
                };
                load();
                c.addEventListener('click', async (e) => {
                    const g = c._g; if (!g) return;
                    const sh = e.target.closest('[data-show]');
                    if (sh) { const s = g.steps[+sh.dataset.show]; return nui('opsDoStep', { title: s.title, secs: 6, anim: s.anim }); }
                    if (e.target.closest('[data-depot]') && g.depot) { nui('opsGps', g.depot); return UI.toast('Waypoint set', 'fa-solid fa-location-dot'); }
                    if (e.target.closest('[data-train]')) return OwPages.training(nav);
                    if (e.target.closest('[data-ra]')) return OwPages.risk(nav, g, load);
                });
            },
        });
    },

    risk(nav, g, done) {
        nav.push({
            title: 'Risk assessment', grouped: true, backLabel: 'Assistant',
            render(c) {
                const items = g.ppe.map((p) => ({ key: 'ppe:' + p.id, label: `I’m wearing / have: ${p.name}`, sub: p.what || '' }))
                    .concat(g.safety.map((h, i) => ({ key: 'h:' + (i + 1), label: h.hazard, sub: h.control })));
                c.innerHTML = `<div class="group-header">${esc(g.job.ref)} · ${esc(g.family.name)}</div><div class="group">${items.map((it) => `<div class="row tap" data-k="${it.key}" style="align-items:flex-start"><i class="fa-regular fa-square" style="color:#0a84ff;width:22px;margin-top:2px"></i><div class="grow" style="white-space:normal"><div>${esc(it.label)}</div><div class="sub muted">${esc(it.sub)}</div></div></div>`).join('')}</div>
                    <div class="group-footer">Only tick what’s really in place. Skipping controls on risky work can cause an accident — it’s logged against the job.</div>
                    <div style="padding:8px 16px 24px"><button class="btn block" data-go>Confirm risk assessment</button></div>`;
                const on = new Set();
                c.addEventListener('click', async (e) => {
                    const r = e.target.closest('[data-k]');
                    if (r) { const k = r.dataset.k; if (on.has(k)) on.delete(k); else on.add(k); $('i', r).className = on.has(k) ? 'fa-solid fa-square-check' : 'fa-regular fa-square'; return; }
                    if (!e.target.closest('[data-go]')) return;
                    if (on.size < items.length && !await UI.confirm('Not everything is in place', `${items.length - on.size} control(s) not ticked. Carry on anyway?`, 'Carry on', true)) return;
                    const res = await owRpc('opsRiskAssess', { id: g.job.id, checked: [...on] });
                    if (!res) return;
                    if (res.error) return UI.alert({ title: 'Risk assessment', message: res.error });
                    UI.toast(res.incident ? 'Logged — there was an incident' : 'Risk assessment recorded', res.incident ? 'fa-solid fa-triangle-exclamation' : 'fa-solid fa-clipboard-check');
                    nav.pop(); if (done) done();
                });
            },
        });
    },

    admin(nav) {
        nav.push({
            title: 'Admin settings', grouped: true, backLabel: 'OPS Work',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = await owRpc('opsAdminState');
                    if (!r || !r.groups) { c.innerHTML = UI.empty('fa-solid fa-lock', 'Not allowed', 'You need the admin settings permission.'); return; }
                    const ctl = (it) => it.kind === 'bool' ? UI.switchHtml(it.value === true, `data-set="${it.res}|${it.path}"`)
                        : it.kind === 'color' ? `<input type="color" class="field" data-sel="${it.res}|${it.path}" value="${esc(String(it.value || '#5b3df5'))}" style="width:46px;height:30px;padding:0">`
                        : (it.kind === 'text' || it.kind === 'url') ? `<button class="btn" data-txt="${it.res}|${it.path}" data-v="${esc(String(it.value ?? ''))}" style="padding:4px 12px;max-width:150px;overflow:hidden;text-overflow:ellipsis">${esc(String(it.value || 'Set…'))}</button>`
                        : it.kind === 'select' ? `<select class="field" data-sel="${it.res}|${it.path}" style="max-width:130px">${it.opts.map((o) => `<option ${o === it.value ? 'selected' : ''}>${o}</option>`).join('')}</select>`
                            : `<button class="btn" data-num="${it.res}|${it.path}" data-v="${esc(String(it.value ?? ''))}" style="padding:4px 12px">${esc(String(it.value ?? '—'))}</button>`;
                    c.innerHTML = r.groups.map((g) => `<div class="group-header">${esc(g.title)}</div><div class="group">${g.items.map((it) => `<div class="row"><div class="grow" style="white-space:normal"><div>${esc(it.label)}</div><div class="sub muted">${esc(it.res.replace('opslabs-', ''))} · ${esc(it.path)}${it.over ? ' · changed' : ''}</div></div>${ctl(it)}</div>`).join('')}</div>`).join('')
                        + `<div class="group-header">More</div><div class="group">
                            <div class="row tap has-icon" data-go="jobs">${owIcon('briefcase', '#0a84ff')}<div class="grow"><div>Jobs</div><div class="sub muted">Switch job types on/off, prices and wages</div></div><i class="fa-solid fa-chevron-right chev"></i></div>
                            <div class="row tap has-icon" data-go="cos">${owIcon('building', '#5e5ce6')}<div class="grow"><div>Companies</div><div class="sub muted">Switch whole companies on/off</div></div><i class="fa-solid fa-chevron-right chev"></i></div></div>
                        <div class="group-footer">Everything else — every setting of every system — is on OPS Hub → Settings, with an explanation of each.</div>`;
                };
                const save = async (res, path, value) => { const x = await owRpc('opsAdminSet', { res, path, value }); if (x && x.ok) UI.toast('Saved', 'fa-solid fa-sliders'); else if (x) UI.alert({ title: 'Settings', message: x.error }); };
                load();
                c.addEventListener('change', (e) => {
                    const s = e.target.closest('[data-set]'), sel = e.target.closest('[data-sel]');
                    if (s) { const [res, path] = s.dataset.set.split('|'); save(res, path, s.checked); }
                    if (sel) { const [res, path] = sel.dataset.sel.split('|'); save(res, path, sel.value); }
                });
                c.addEventListener('click', async (e) => {
                    const tx = e.target.closest('[data-txt]');
                    if (tx) { const [res, path] = tx.dataset.txt.split('|'); const v = await UI.prompt(path, 'New value', { value: tx.dataset.v }); if (v !== null) { await save(res, path, v); load(); } return; }
                    const n = e.target.closest('[data-num]');
                    if (n) { const [res, path] = n.dataset.num.split('|'); const v = await UI.prompt(path, 'New value', { value: n.dataset.v, type: 'number' }); if (v !== null && v !== '') { await save(res, path, Number(v)); load(); } return; }
                    const g = e.target.closest('[data-go]');
                    if (g) return g.dataset.go === 'jobs' ? OwPages.adminJobs(nav) : OwPages.adminCos(nav);
                });
            },
        });
    },

    adminJobs(nav) {
        nav.push({
            title: 'Jobs', grouped: true, backLabel: 'Admin',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = await owRpc('opsAdminJobs');
                    if (!r || !r.jobs) { c.innerHTML = UI.empty('fa-solid fa-lock', 'Not allowed', ''); return; }
                    const by = {};
                    r.jobs.forEach((j) => { (by[j.company] = by[j.company] || []).push(j); });
                    c.innerHTML = Object.keys(by).map((co) => `<div class="group-header">${esc(co)}</div><div class="group">${by[co].map((j) => `<div class="row" style="align-items:flex-start"><div class="grow" style="white-space:normal"><div>${esc(j.title)}${j.custom ? ' <span class="sub muted">(custom)</span>' : ''}</div>
                        <div class="sub muted"><a data-price="${j.code}" data-v="${j.price}" style="color:#0a84ff">${owMoney(j.price)}</a> · wage <a data-wage="${j.code}" data-v="${j.wage}" style="color:#0a84ff">${owMoney(j.wage)}</a> · auto ${UI.switchHtml(j.auto, `data-auto="${j.code}"`)}</div></div>${UI.switchHtml(j.enabled, `data-on="${j.code}"`)}</div>`).join('')}</div>`).join('')
                        + '<div class="group-footer">The right-hand switch turns the job on/off everywhere. “auto” = it appears on the job board by itself. New job types, checks and parts: OPS Hub → Jobs.</div>';
                };
                const set = async (code, field, value) => { const x = await owRpc('opsAdminJob', { code, field, value }); if (x && x.ok) UI.toast('Saved'); else if (x) UI.alert({ title: 'Jobs', message: x.error }); };
                load();
                c.addEventListener('change', (e) => { const on = e.target.closest('[data-on]'), au = e.target.closest('[data-auto]'); if (on) set(on.dataset.on, 'enabled', on.checked); if (au) set(au.dataset.auto, 'auto', au.checked); });
                c.addEventListener('click', async (e) => {
                    const p = e.target.closest('[data-price]') || e.target.closest('[data-wage]');
                    if (!p) return;
                    const field = p.dataset.price ? 'price' : 'wage', code = p.dataset.price || p.dataset.wage;
                    const v = await UI.prompt(field === 'price' ? 'Customer price' : 'Engineer wage', '$', { value: p.dataset.v, type: 'number' });
                    if (v !== null && v !== '') { await set(code, field, Number(v)); load(); }
                });
            },
        });
    },

    adminCos(nav) {
        nav.push({
            title: 'Companies', grouped: true, backLabel: 'Admin',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = await owRpc('opsAdminCompanies');
                    if (!r || !r.companies) { c.innerHTML = UI.empty('fa-solid fa-lock', 'Not allowed', ''); return; }
                    c.innerHTML = `<div class="group" style="margin-top:12px">${r.companies.map((co) => `<div class="row has-icon">${owIcon(co.icon || 'building', co.color || '#8e8e93')}<div class="grow"><div>${esc(co.name)}</div><div class="sub muted">${esc(co.tagline || '')}</div></div>${UI.switchHtml(+co.active === 1, `data-co="${co.id}"`)}</div>`).join('')}</div>
                        <div class="group-footer">A switched-off company disappears from OPS Work, gets no jobs and can’t be booked. Edit names, colours, VAT and wages — or create new companies — on OPS Hub → Companies.</div>`;
                };
                load();
                c.addEventListener('change', async (e) => { const s = e.target.closest('[data-co]'); if (s) { const x = await owRpc('opsAdminCompany', { id: +s.dataset.co, active: s.checked }); if (x && x.ok) UI.toast('Saved'); } });
            },
        });
    },

    kit(nav) {
        nav.push({
            title: 'My van & tools', grouped: true, backLabel: 'OPS Work',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = await owRpc('opsMyKit');
                    if (!r || r.loggedOut) { c.innerHTML = UI.empty('fa-solid fa-van-shuttle', 'Sign in', ''); return; }
                    c.innerHTML = `<div class="group-header">Company vehicles</div><div class="group">${(r.vehicles || []).map((v) => `<div class="row has-icon" style="align-items:flex-start;padding-top:11px;padding-bottom:11px">${owIcon('van-shuttle', v.color || '#64d2ff')}
                        <div class="grow"><div><b>${esc(v.label || v.model)}</b> <span class="sub muted">${esc(v.plate)}</span></div><div class="sub muted">${esc(v.company)} · ${v.mileage} km${v.service_due_at ? ' · service ' + owDate(v.service_due_at) : ''}${v.status !== 'available' ? ' · ' + esc(v.status) : ''}</div></div>
                        ${v.status === 'available' ? (v.out_at ? `<button class="btn" data-in="${v.id}" style="padding:6px 12px">Return</button>` : `<button class="btn" data-out="${v.id}" style="padding:6px 12px">Take out</button>`) : ''}</div>`).join('')
                        || '<div class="row"><div class="grow muted">No van assigned — your manager allocates them on OPS Hub.</div></div>'}</div>
                        <div class="group-header">Tools issued to you</div><div class="group">${(r.tools || []).map((t) => `<div class="row has-icon">${owIcon('toolbox', '#ff9f0a')}<div class="grow"><div>${esc(t.kind)}</div><div class="sub muted">${esc(t.serial)} · ${esc(t.company)} · ${esc(t.condition)}${t.calibration_due ? ' · calibration ' + owDate(t.calibration_due) : ''}</div></div></div>`).join('')
                        || '<div class="row"><div class="grow muted">No tools issued.</div></div>'}</div>`;
                };
                load();
                c.addEventListener('click', async (e) => {
                    const o = e.target.closest('[data-out]'), i = e.target.closest('[data-in]');
                    if ((o || i) && (o || i).disabled) return;
                    if (o || i) (o || i).disabled = true;   // one van per tap
                    if (o) { const r = await nui('opsVanOut', { id: +o.dataset.out }); if (r && r.ok) UI.toast('Your van is outside', 'fa-solid fa-van-shuttle'); else UI.alert({ title: 'Can’t take it out', message: (r && r.error) || 'Try again' }); return load(); }
                    if (i) { const r = await nui('opsVanIn'); if (r && r.ok) UI.toast(`Returned · ${r.km} km`); else UI.alert({ title: 'Return the van', message: (r && r.error) || 'Stand next to it' }); return load(); }
                });
            },
        });
    },

    mystuff(nav) {
        nav.push({
            title: 'My services', grouped: true, backLabel: 'OPS Work',
            render(c, ctx) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = owFix(await owRpc('opsMyQuotes')) || {};
                    const now = r.now || Date.now() / 1000;
                    const QS = { sent: ['Waiting for you', '#ff9f0a'], accepted: ['Accepted', '#30d158'], declined: ['Declined', '#8e8e93'], expired: ['Expired', '#8e8e93'] };
                    c.innerHTML = `<div class="group-header">Quotes</div>${(r.quotes || []).map((q) => `<div class="group">
                        <div class="row has-icon" style="align-items:flex-start;padding-top:11px">${owIcon(q.icon || 'file-invoice', q.color || '#ff9f0a')}<div class="grow"><div><b>${esc(q.title)}</b></div><div class="sub muted">${esc(q.company)} · ${esc(q.number || '')}${q.status === 'sent' ? ' · valid until ' + owDate(q.valid_until) : ''}</div></div>${owChip(QS, q.status)}</div>
                        ${(q.items || []).map((it) => `<div class="row"><div class="grow">${esc(it.description || '')}${+it.qty > 1 ? ` × ${it.qty}` : ''}${it.contract ? ' <span class="sub muted">(per period)</span>' : ''}</div><div>${owMoney((+it.qty || 1) * (+it.unit || 0))}</div></div>`).join('')}
                        <div class="row"><div class="grow muted">Total incl. tax</div><b>${owMoney(q.total)}</b></div>
                        ${q.status === 'sent' ? `<div class="row"><button class="btn" data-acc="${q.id}" style="flex:1">Accept</button><button class="btn secondary" data-dec="${q.id}" style="flex:1;margin-left:8px">Decline</button></div>` : ''}
                        ${q.jobs ? `<div class="row"><div class="grow sub muted">Booked: ${esc(q.jobs)}</div></div>` : ''}</div>`).join('') || '<div class="group"><div class="row"><div class="grow muted">No quotes. Ask a company for one in Support.</div></div></div>'}
                        <div class="group-header">Contracts</div><div class="group">${(r.contracts || []).map((k) => `<div class="row has-icon">${owIcon('file-contract', k.color || '#5e5ce6')}<div class="grow"><div>${esc(k.title)}</div><div class="sub muted">${esc(k.company)} · ${esc(k.sla)} SLA, ${k.response_hours} h response · ${owMoney(k.fee)}/period${k.status !== 'active' ? ' · ' + esc(k.status) : ''}</div></div></div>`).join('')
                            || '<div class="row"><div class="grow muted">No contracts.</div></div>'}</div>
                        <div class="group-header">Your installed kit</div><div class="group">${(r.assets || []).map((a) => { const w = a.warranty_until && a.warranty_until > now;
                            return `<div class="row has-icon">${owIcon('microchip', w ? '#30d158' : '#8e8e93')}<div class="grow"><div>${esc(a.name)}</div><div class="sub muted">${esc(a.serial)} · ${esc(a.company)} · ${w ? 'warranty until ' + owDate(a.warranty_until) : 'out of warranty'}</div></div></div>`; }).join('')
                            || '<div class="row"><div class="grow muted">Nothing installed yet.</div></div>'}</div>
                        <div class="group-footer">Repairs to kit under warranty, or covered by a contract, are free.</div>`;
                };
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-acc]'), d = e.target.closest('[data-dec]');
                    if (!a && !d) return;
                    if ((a || d).disabled) return;
                    if (a && !await UI.confirm('Accept this quote?', 'The work is booked straight away; you pay when each job is done (contracts bill every period).', 'Accept')) return;
                    $$('[data-acc],[data-dec]', (a || d).parentElement).forEach((b) => { b.disabled = true; });   // no double booking
                    const r = await owRpc('opsQuoteDecide', { id: +(a || d).dataset[a ? 'acc' : 'dec'], accept: !!a });
                    if (r && r.ok) UI.toast(a ? 'Accepted — work booked' : 'Declined'); else if (r) UI.alert({ title: 'Quote', message: r.error });
                    load();
                });
            },
        });
    },

    tickets(nav) {
        nav.push({
            title: 'Support', grouped: true, backLabel: 'OPS Work',
            render(c, ctx) {
                const ST = { open: ['Open', '#0a84ff'], pending: ['Waiting for you', '#ff9f0a'], closed: ['Closed', '#8e8e93'] };
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = owFix(await owRpc('opsMyTickets')) || {};
                    c.innerHTML = `<div style="padding:12px 16px 0"><button class="btn block" data-new>New support request</button></div>
                        <div class="group" style="margin-top:12px">${(r.tickets || []).map((t) => `<div class="row tap has-icon" data-t="${t.id}">${owIcon(t.icon || 'headset', t.color || '#30d158')}<div class="grow"><div>${esc(t.subject)}</div><div class="sub muted">${esc(t.company)} · ${esc(t.ref || '')} · ${(t.messages || []).length} message${(t.messages || []).length === 1 ? '' : 's'}</div></div>${owChip(ST, t.status)}</div>`).join('')
                            || '<div class="row"><div class="grow muted">No support requests yet.</div></div>'}</div>`;
                    c._t = r.tickets || [];
                };
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', async (e) => {
                    if (e.target.closest('[data-new]')) {
                        const sv = owFix(await rpc('opsServices')) || {};
                        const seen = {}, list = [];
                        (sv.services || []).forEach((x) => { if (x.company && !seen[x.company]) { seen[x.company] = 1; list.push({ label: x.companyName || x.company, value: x.company }); } });
                        const co = await UI.pick('Which company?', list.length ? list : [{ label: 'OPS Network', value: 'network' }, { label: 'OPS Secure', value: 'secure' }, { label: 'OPS Web', value: 'web' }]);
                        if (!co) return;
                        const subject = await UI.prompt('What’s it about?', '', { placeholder: 'Quote for CCTV at my shop' });
                        if (!subject) return;
                        const text = await UI.prompt('Details', 'Tell them more (optional)', {});
                        const r = await owRpc('opsTicketNew', { company: co, subject, text: text || '' });
                        if (r && r.ok) UI.toast('Sent · ' + r.ref); else if (r) UI.alert({ title: 'Support', message: r.error });
                        return load();
                    }
                    const t = e.target.closest('[data-t]');
                    if (t) OwPages.ticket(nav, (c._t || []).find((x) => x.id === +t.dataset.t), load);
                });
            },
        });
    },

    ticket(nav, t, done) {
        if (!t) return;
        nav.push({
            title: t.ref || 'Ticket', grouped: true, backLabel: 'Support',
            render(c) {
                c.innerHTML = `<div class="group-header">${esc(t.company)} · ${esc(t.subject)}</div><div class="group">${(t.messages || []).map((m) => `<div class="row has-icon" style="align-items:flex-start">${owIcon(m.staff ? 'headset' : 'user', m.staff ? (t.color || '#30d158') : '#8e8e93')}
                    <div class="grow"><div style="white-space:pre-wrap">${esc(m.text || '—')}</div><div class="sub muted">${esc(m.from || '')} · ${new Date((m.at || 0) * 1000).toLocaleString()}</div></div></div>`).join('')}</div>
                    <div style="padding:12px 16px"><button class="btn block" data-reply>Reply</button></div>`;
                c.addEventListener('click', async (e) => {
                    if (!e.target.closest('[data-reply]')) return;
                    const text = await UI.prompt('Reply', '', {});
                    if (!text) return;
                    const r = await owRpc('opsTicketReply', { id: t.id, text });
                    if (r && r.ok) { UI.toast('Sent'); nav.pop(); done && done(); } else if (r) UI.alert({ title: 'Support', message: r.error });
                });
            },
        });
    },

    broadband(nav) {
        nav.push({
            title: 'My broadband', grouped: true, backLabel: 'OPS Work',
            render(c, ctx) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = owFix(await nui('ispMine'));
                    if (!r || r.offline) { c.innerHTML = UI.empty('fa-solid fa-plug-circle-xmark', 'Offline', 'OPS Network systems aren’t reachable.'); return; }
                    const list = r.services || [];
                    c.innerHTML = (r.owed > 0 ? `<div class="group" style="margin-top:12px"><div class="row has-icon">${owIcon('file-invoice-dollar', '#ff3b30')}<div class="grow"><div><b>${owMoney(r.owed)} to pay</b></div><div class="sub muted">Unpaid bills suspend your line after the grace period</div></div><button class="btn" data-act="pay" style="padding:6px 14px">Pay</button></div></div>` : '')
                        + (list.length ? list.map((s) => `
                        <div class="group" style="margin-top:12px">
                            <div class="row has-icon" style="align-items:flex-start">${owIcon('wifi', '#0a84ff')}<div class="grow"><div><b>${esc(s.package || 'Broadband')}</b></div><div class="sub muted">${esc(s.address || '')} · ${esc(s.ref || '')}</div>
                                <div style="display:flex;gap:5px;margin-top:6px;flex-wrap:wrap">${owChip(OW_SVC, s.status)}${s.status === 'active' ? owChip(OW_LINE, s.line || 'down') : ''}${s.overdue ? '<span class="on-pill" style="--c:#ff3b30">Bill overdue</span>' : ''}</div></div></div>
                            ${s.outage ? `<div class="row has-icon">${owIcon('triangle-exclamation', '#ff3b30')}<div class="grow"><div>${esc(s.outage.title)}</div><div class="sub muted">${esc(s.outage.ref)} · engineers are on it</div></div></div>` : ''}
                            <div class="row"><div class="grow muted">Speed</div><div>${s.down} / ${s.up} Mbps</div></div>
                            <div class="row"><div class="grow muted">Monthly</div><div>${owMoney(s.price)}</div></div>
                            ${(s.ips || []).length ? `<div class="row"><div class="grow muted">${s.ip_mode === 'dynamic' ? 'Public IP' : 'Static IPs'}</div><div style="text-align:right;font-family:ui-monospace,monospace;font-size:13px">${s.ips.slice(0, 3).map(esc).join('<br>')}${s.ips.length > 3 ? `<br>+${s.ips.length - 3} more` : ''}</div></div>` : ''}
                            ${s.config && s.config.wifi ? `<div class="row"><div class="grow muted">Wi-Fi</div><div>${esc(s.config.wifi.ssid)}${s.config.wifi.secured ? ' <i class="fa-solid fa-lock" style="font-size:11px"></i>' : ''}</div></div>` : ''}
                            ${(s.tests || []).length ? `<div class="row"><div class="grow muted">Last speed test</div><div>${s.tests[0].down_mbps} / ${s.tests[0].up_mbps} Mbps</div></div>` : ''}
                            ${s.status === 'active' ? `<div class="row tap has-icon" data-act="speed">${owIcon('gauge-high', '#30d158')}<div class="grow">Run a speed test</div></div>
                            <div class="row tap has-icon" data-act="fault" data-svc="${s.id}">${owIcon('screwdriver-wrench', '#ff9f0a')}<div class="grow">Report a fault / slow speeds</div></div>` : ''}
                        </div>`).join('') : UI.empty('fa-solid fa-wifi', 'No broadband yet', 'Get OPS Fibre at home or for your business.'))
                        + `<div style="padding:12px 16px"><button class="btn block" data-act="order">${list.length ? 'Order another line' : 'Get OPS Network broadband'}</button></div>`;
                };
                load();
                ctx.opts.onResume = load;
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'order') return OwPages.order(nav, load);
                    if (a.dataset.act === 'speed') { UI.toast('Testing…', 'fa-solid fa-gauge-high'); return owSpeedResult(owFix(await nui('ispSpeedtest'))); }
                    if (a.dataset.act === 'pay') { const r = owFix(await nui('ispPay')); UI.alert({ title: r && r.ok ? 'Paid' : 'Couldn’t pay', message: r && r.ok ? `${owMoney(r.paid)} paid — thank you.` : ((r && r.error) || 'Try again') }); return load(); }
                    if (a.dataset.act === 'fault') {
                        const pick = await UI.pick('What’s wrong?', [{ label: 'No internet', value: 'No internet' }, { label: 'Slow speeds', value: 'Slow speeds' }, { label: 'Wi-Fi keeps dropping', value: 'Wi-Fi keeps dropping' }, { label: 'Something else', value: 'Other fault' }]);
                        if (!pick) return;
                        const text = await UI.prompt(pick, 'Tell us more (optional)', {});
                        const r = owFix(await nui('ispTicket', { service: +a.dataset.svc, subject: pick, text: text || '' }));
                        UI.alert({ title: r && r.ok ? 'Fault reported' : 'Couldn’t report', message: r && r.ok ? `Ticket ${r.ref}. An engineer will be in touch.` : ((r && r.error) || 'Try again') });
                    }
                });
            },
        });
    },

    order(nav, done) {
        nav.push({
            title: 'Choose a package', grouped: true, backLabel: 'Broadband',
            async render(c) {
                c.innerHTML = owSpin;
                const list = owFix(await nui('ispPackages')) || [];
                const seg = { residential: 'Home', business: 'Business', government: 'Public sector' };
                const groups = {};
                (Array.isArray(list) ? list : []).forEach((p) => { (groups[p.segment] = groups[p.segment] || []).push(p); });
                c.innerHTML = Object.keys(seg).filter((k) => groups[k]).map((k) => `<div class="group-header">${seg[k]}</div><div class="group">${groups[k].map((p) => `
                    <div class="row tap" data-pkg="${p.id}" style="align-items:flex-start;padding-top:12px;padding-bottom:12px"><div class="grow"><div><b>${esc(p.name)}</b></div>
                        <div class="sub muted">${esc(p.desc || '')}</div><div class="sub" style="margin-top:4px;white-space:normal">${p.down >= 1000 ? p.down / 1000 + ' Gb' : p.down + ' Mb'} down · ${p.up >= 1000 ? p.up / 1000 + ' Gb' : p.up + ' Mb'} up · ${p.contract} months${p.ip !== 'dynamic' ? ' · static IP' : ''}</div></div>
                        <div style="text-align:right;margin-left:10px"><b>${owMoney(p.price)}</b><div class="sub muted">a month</div>${p.setup ? `<div class="sub muted">+${owMoney(p.setup)} setup</div>` : ''}</div></div>`).join('')}</div>`).join('')
                    + '<div class="group-footer">An OPS Network engineer installs it where you are standing now. You pay the first month (and any setup) when it goes live, then every billing period.</div>';
                c.addEventListener('click', async (e) => {
                    const p = e.target.closest('[data-pkg]'); if (!p) return;
                    const pkg = list.find((x) => x.id === +p.dataset.pkg);
                    const addr = await UI.prompt(pkg.name, 'Address for the installation (your home or business name)', { placeholder: 'e.g. 1076 Procopio Dr' });
                    if (addr === null) return;
                    const r = owFix(await nui('ispOrder', { package: pkg.id, address: addr }));
                    if (r && r.ok) { await UI.alert({ title: 'Installation booked', message: `Line ${r.ref}. An engineer will come to install it — you’ll get a message when they’re on the way.` }); nav.pop(); done && done(); }
                    else UI.alert({ title: 'Couldn’t order', message: (r && r.error) || 'Try again' });
                });
            },
        });
    },

    lineTool(nav) {
        nav.push({
            title: 'Line at this address', grouped: true, backLabel: 'OPS Work',
            render(c) {
                const load = async () => {
                    c.innerHTML = owSpin;
                    const r = owFix(await nui('ispLookup'));
                    if (!r || r.error || r.offline) { c.innerHTML = UI.empty('fa-solid fa-ethernet', 'No line here', (r && r.error) || 'Stand inside the customer’s property.'); return; }
                    const cfg = r.config || {};
                    const fw = (cfg.firewall || {}).rules || [];
                    c.innerHTML = `<div class="group" style="margin-top:12px">
                        <div class="row has-icon">${owIcon('house-signal', '#0a84ff')}<div class="grow"><div><b>${esc(r.customer || '')}</b></div><div class="sub muted">${esc(r.ref || '')} · ${esc(r.package || '')}</div></div>${owChip(OW_SVC, r.status)}</div>
                        <div class="row"><div class="grow muted">Line</div>${owChip(OW_LINE, r.line || 'down')}</div>
                        <div class="row"><div class="grow muted">Public IPs</div><div style="text-align:right;font-family:ui-monospace,monospace;font-size:13px">${(r.ips || []).map(esc).join('<br>') || '—'}</div></div>
                        <div class="row"><div class="grow muted">LAN</div><div>${esc((cfg.lan || {}).subnet || '—')} · gw ${esc((cfg.lan || {}).gateway || '')}</div></div>
                        <div class="row"><div class="grow muted">DHCP</div><div>${cfg.dhcp && cfg.dhcp.enabled ? esc(cfg.dhcp.from + ' – ' + cfg.dhcp.to) : 'off'}</div></div>
                        <div class="row"><div class="grow muted">DNS</div><div>${esc(((cfg.dns || {}).servers || []).join(', '))}</div></div>
                        <div class="row"><div class="grow muted">Wi-Fi</div><div>${esc((cfg.wifi || {}).ssid || '—')}${(cfg.wifi || {}).password ? ' <i class="fa-solid fa-lock" style="font-size:11px"></i>' : ' (open)'}</div></div>
                        <div class="row"><div class="grow muted">VLANs · firewall · VPN</div><div>${(cfg.vlans || []).length} · ${fw.length} rules · ${(cfg.vpn || []).length}</div></div>
                    </div>
                    <div class="group"><div class="row tap has-icon" data-act="speed">${owIcon('gauge-high', '#30d158')}<div class="grow">Run a speed test</div></div></div>
                    <div class="group-footer">Change router settings (firewall, VLANs, VPN, DHCP, Wi-Fi) on OPS Hub → OPS Network → the line.</div>`;
                };
                load();
                c.addEventListener('click', async (e) => { if (e.target.closest('[data-act=speed]')) { UI.toast('Testing…', 'fa-solid fa-gauge-high'); owSpeedResult(owFix(await nui('ispSpeedtest'))); load(); } });
            },
        });
    },

    login(nav) {
        nav.push({
            title: 'Staff Sign In', grouped: true,
            render(c) {
                c.innerHTML = `<div class="group" style="margin-top:16px">
                    <div class="row"><input class="field" data-f="u" placeholder="Username" autocomplete="off" spellcheck="false" maxlength="24"></div>
                    <div class="row"><input class="field" data-f="p" type="password" placeholder="Password"></div></div>
                    <div class="dl-error" style="color:#ff453a;padding:0 20px"></div>
                    <div style="padding:0 16px 36px"><button class="btn block" data-act="in">Sign In</button>
                    <button class="btn block secondary" data-act="up" style="margin-top:10px">Create an account</button></div>
                    <div class="group-footer">One account for every OPS company, here and on OPS Hub. New accounts apply to join a company, then a manager approves you.</div>`;
                const btns = $$('[data-act=in],[data-act=up]', c);
                const go = async (signup) => {
                    if (btns[0].disabled) return;
                    const user = $('[data-f=u]', c).value.trim(), pass = $('[data-f=p]', c).value;
                    if (!user || !pass) { $('.dl-error', c).textContent = 'Enter your username and password'; return; }
                    btns.forEach((b) => { b.disabled = true; });     // one request at a time (no double sign-up)
                    const r = await rpc(signup ? 'opsnetSignup' : 'opsnetLogin', { username: user, password: pass });
                    if (r && r.ok) { const m = await owRpc('opsMe'); OpsWork.me = m && m.me; return OpsWork.home(); }
                    btns.forEach((b) => { b.disabled = false; });
                    $('.dl-error', c).textContent = (r && r.error) || 'Something went wrong';
                };
                $('[data-act=in]', c).onclick = () => go(false);
                $('[data-act=up]', c).onclick = () => go(true);
                c.addEventListener('input', () => { $('.dl-error', c).textContent = ''; });
                c.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target.matches('input')) go(false); });
            },
        });
    },

    company(nav, co, root) {
        nav.push({
            title: co.name, grouped: true, large: !!root, backLabel: 'OPS Work', noBack: !!root,
            render(c, ctx) {
                const load = async () => {
                    const r = await owRpc('opsCompany', { company: co.code });
                    if (!r) return;
                    if (r.error) { c.innerHTML = UI.empty('fa-solid fa-circle-exclamation', 'Unavailable', r.error); return; }
                    const has = (p) => r.perms.includes(p);
                    const n = r.counts || {};
                    c.innerHTML = `
                        <div class="group" style="margin-top:12px"><div class="row has-icon">${owIcon(co.icon, co.color)}<div class="grow"><div><b>${esc(co.name)}</b></div><div class="sub muted">${esc(co.tagline || '')}</div></div></div>
                            ${r.company.balance != null ? `<div class="row"><div class="grow muted">Company account</div><b>${owMoney(r.company.balance)}</b></div>` : ''}
                            <div class="row"><div class="grow muted">Open · active · done this week</div><b>${n.open || 0} · ${n.active || 0} · ${n.week || 0}</b></div></div>
                        <div class="group">
                            ${has('jobs.view') ? `<div class="row tap has-icon" data-p="board">${owIcon('clipboard-list', '#0a84ff')}<div class="grow">Job board</div><span class="sub muted">${n.open || 0} open</span><i class="fa-solid fa-chevron-right chev"></i></div>` : ''}
                            <div class="row tap has-icon" data-p="mine">${owIcon('person-digging', '#ff9f0a')}<div class="grow">My jobs</div><i class="fa-solid fa-chevron-right chev"></i></div>
                            ${has('jobs.dispatch') ? `<div class="row tap has-icon" data-p="dispatch">${owIcon('plus', '#30d158')}<div class="grow">New job (dispatch)</div></div>` : ''}
                            ${has('employees.view') ? `<div class="row tap has-icon" data-p="people">${owIcon('users', '#5e5ce6')}<div class="grow">Employees</div><span class="sub muted">${(r.employees || []).filter((e) => e.status === 'applied').length || ''} ${((r.employees || []).filter((e) => e.status === 'applied').length) ? 'applied' : ''}</span><i class="fa-solid fa-chevron-right chev"></i></div>` : ''}
                            ${has('finance.view') ? `<div class="row tap has-icon" data-p="finance">${owIcon('building-columns', '#30d158')}<div class="grow">Finance</div><i class="fa-solid fa-chevron-right chev"></i></div>` : ''}
                            ${has('company.manage') ? `<div class="row tap has-icon" data-p="post">${owIcon('bullhorn', '#ff375f')}<div class="grow">Post an announcement</div></div>` : ''}
                        </div>
                        <div class="group-header">News</div>
                        <div class="group">${(r.messages || []).length ? r.messages.map((m) => `<div class="row"><div class="grow"><div><b>${esc(m.title)}</b></div><div class="sub muted">${esc(m.body || '')}</div><div class="sub muted">${esc(m.author || '')} · ${owWhen(m.at)}</div></div></div>`).join('') : '<div class="row"><div class="grow muted">No announcements</div></div>'}</div>`;
                    c.onclick = async (e) => {
                        const p = e.target.closest('[data-p]');
                        if (!p) return;
                        const k = p.dataset.p;
                        if (k === 'board') return OwPages.board(nav, co);
                        if (k === 'mine') return OwPages.mine(nav);
                        if (k === 'people') return OwPages.people(nav, co, r);
                        if (k === 'finance') return OwPages.finance(nav, co, r);
                        if (k === 'dispatch') return OwPages.dispatch(nav, co, r, load);
                        if (k === 'post') {
                            const t = await UI.prompt('Announcement', 'Title', { placeholder: 'e.g. Fibre outage in Mirror Park' });
                            if (!t) return;
                            const b = await UI.prompt('Announcement', 'Details (optional)', {});
                            const x = await owRpc('opsPost', { company: co.code, title: t, body: b || '' });
                            if (x && x.ok) { UI.toast('Posted'); load(); }
                        }
                    };
                };
                c.innerHTML = owSpin;
                load();
                ctx.opts.onResume = load;
            },
        });
    },

    board(nav, co) {
        nav.push({
            title: 'Job board', grouped: true, backLabel: co.name,
            render(c, ctx) {
                let filter = 'open';
                c.innerHTML = `<div class="segmented" style="margin-top:12px"><button data-f="open">Available</button><button data-f="all">All active</button></div><div class="ow-list"></div>`;
                const list = $('.ow-list', c);
                const load = async () => {
                    $$('[data-f]', c).forEach((b) => b.classList.toggle('on', b.dataset.f === filter));
                    const r = await owRpc('opsJobs', { company: co.code, filter });
                    if (!r) return;
                    owRenderList(list, r.jobs || [], UI.empty('fa-solid fa-clipboard-check', 'No Jobs', 'New work appears here as customers need it.'));
                };
                list.innerHTML = owSpin; load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => {
                    const f = e.target.closest('[data-f]'); if (f) { filter = f.dataset.f; return load(); }
                    const j = e.target.closest('[data-job]'); if (j) OwPages.job(nav, +j.dataset.job);
                });
            },
        });
    },

    mine(nav) {
        nav.push({
            title: 'My jobs', grouped: true, backLabel: 'Back',
            render(c, ctx) {
                let filter = 'mine';
                c.innerHTML = `<div class="segmented" style="margin-top:12px"><button data-f="mine">Active</button><button data-f="done">Completed</button></div><div class="ow-list"></div>`;
                const list = $('.ow-list', c);
                const load = async () => {
                    $$('[data-f]', c).forEach((b) => b.classList.toggle('on', b.dataset.f === filter));
                    const r = await owRpc('opsJobs', { filter });
                    if (!r) return;
                    owRenderList(list, r.jobs || [], UI.empty('fa-solid fa-mug-hot', filter === 'mine' ? 'Nothing On' : 'Nothing Yet', filter === 'mine' ? 'Take a job from a company’s job board.' : ''));
                };
                list.innerHTML = owSpin; load();
                ctx.opts.onResume = load;
                c.addEventListener('click', (e) => {
                    const f = e.target.closest('[data-f]'); if (f) { filter = f.dataset.f; return load(); }
                    const j = e.target.closest('[data-job]'); if (j) OwPages.job(nav, +j.dataset.job);
                });
            },
        });
    },

    job(nav, id) {
        nav.push({
            title: 'Job', grouped: true, backLabel: 'Back',
            render(c, ctx) {
                let timer = null;
                const load = async () => {
                    const r = await owRpc('opsJob', { id });
                    if (!r) return;
                    if (r.error) { c.innerHTML = UI.empty('fa-solid fa-circle-exclamation', 'Unavailable', r.error); return; }
                    const j = r.job;
                    ctx.setTitle(j.ref);
                    if (!OW_ADDR.has(j.id)) await owAddresses([j]);
                    const [head, detail, dist] = owAddr(j);
                    const k = OW_KIND[j.customerKind] || ['Customer', 'location-dot', '#8e8e93'];
                    const chk = j.check && typeof j.check === 'object' ? j.check : null;
                    const working = j.mine && (j.status === 'assigned' || j.status === 'in_progress');
                    const pct = chk ? Math.min(100, Math.round((Number(chk.have) || 0) / (Number(chk.need) || 1) * 100)) : 0;
                    const col = j.emergency ? '#ff3b30' : (j.color || '#0a84ff');
                    c.innerHTML = `
                        <div style="margin:12px 16px 0;border-radius:18px;padding:16px;color:#fff;background:linear-gradient(140deg,${col},#111 140%)">
                            <div style="display:flex;gap:10px;align-items:center;opacity:.85;font-size:13px;font-weight:600"><i class="fa-solid fa-${j.icon || 'briefcase'}"></i>${esc(j.companyName || '')}<span style="margin-left:auto">${esc(j.ref)}</span></div>
                            <div style="font-size:21px;font-weight:800;margin-top:6px;line-height:1.2">${esc(j.title)}</div>
                            <div style="display:flex;gap:6px;margin-top:10px;flex-wrap:wrap">${owPill(j.status)}${j.emergency ? '<span class="on-pill" style="--c:#fff">EMERGENCY</span>' : ''}${j.sla ? `<span class="on-pill" style="--c:#fff">SLA ${esc(j.sla)}</span>` : ''}</div>
                        </div>
                        <div class="group-header">Where</div>
                        <div class="group">
                            <div class="row has-icon" style="align-items:flex-start"><span class="ri" style="background:${k[2]}"><i class="fa-solid fa-${k[1]}"></i></span>
                                <div class="grow"><div style="font-size:17px;font-weight:700">${esc(head)}</div>${detail ? `<div class="sub muted">${esc(detail)}</div>` : ''}
                                ${dist ? `<div class="sub" style="margin-top:4px;color:#0a84ff;font-weight:600"><i class="fa-solid fa-location-arrow"></i> ${esc(dist)} from you</div>` : ''}</div></div>
                            ${j.x != null ? `<div class="row tap has-icon" data-act="gps"><span class="ri" style="background:#0a84ff"><i class="fa-solid fa-route"></i></span><div class="grow" style="color:#0a84ff;font-weight:600">Set GPS to this address</div></div>`
                                : `<div class="row tap has-icon" data-act="web" data-co="${esc(j.company || '')}"><span class="ri" style="background:#ff9f0a"><i class="fa-solid fa-compass"></i></span><div class="grow" style="color:#0a84ff;font-weight:600">Online job — open the Browser</div></div>`}
                        </div>
                        <div class="group-header">Customer</div>
                        <div class="group">
                            <div class="row"><div class="grow muted">Name</div><div>${esc(j.customer || '—')}</div></div>
                            <div class="row"><div class="grow muted">Type</div><div>${esc(k[0])}</div></div>
                            ${j.customerPhone ? `<div class="row"><div class="grow muted">Phone</div><div>${esc(j.customerPhone)}</div></div>` : ''}
                            ${j.appointment_at ? `<div class="row"><div class="grow muted">Appointment</div><div>${new Date(j.appointment_at * 1000).toLocaleString()}</div></div>` : ''}
                        </div>
                        <div class="group-header">The job</div>
                        <div class="group">
                            <div class="row"><div class="grow">${esc(j.description || '')}</div></div>
                            <div class="row"><div class="grow muted">Your wages</div><b style="color:#30d158">${owMoney(j.wage)}</b></div>
                            <div class="row"><div class="grow muted">Customer pays</div><div>${j.price ? owMoney(j.price) : 'No charge'}</div></div>
                            ${j.assigned ? `<div class="row"><div class="grow muted">Engineer</div><div>${esc(j.assigned)}</div></div>` : ''}
                            ${owDue(j) ? `<div class="row"><div class="grow muted">SLA</div><div>${owDue(j)}</div></div>` : ''}
                            ${j.cert ? `<div class="row tap" data-act="training"><div class="grow muted">Certification needed</div><div style="color:#0a84ff">${esc(j.certName || j.cert)}</div></div>` : ''}
                            ${j.result ? `<div class="row"><div class="grow muted">Result</div><div>${esc(j.result)}</div></div>` : ''}
                        </div>
                        ${working && chk ? `<div class="group-header">Work check</div><div class="group">
                            <div class="row"><div class="grow"><div><i class="fa-solid fa-${chk.ok ? 'circle-check' : 'hourglass-half'}" style="color:${chk.ok ? '#30d158' : '#ff9f0a'}"></i> ${esc(chk.label || '')}</div><div class="sub muted">${esc(chk.detail || '')}</div>
                            <div style="height:6px;border-radius:3px;background:rgba(127,127,127,.25);margin-top:6px"><div style="height:6px;border-radius:3px;width:${pct}%;background:${chk.ok ? '#30d158' : '#ff9f0a'}"></div></div></div>
                            <b style="margin-left:10px">${esc(String(chk.have ?? 0))} / ${esc(String(chk.need ?? 1))}</b></div></div>
                            <div class="group-footer">${j.checkKind === 'onsite' ? 'Go to the address, tap Start work and stay on site until it’s done.' : 'Do the real work at the address (/towers): only work done since you accepted the job counts.'}</div>` : ''}
                        <div style="padding:6px 16px 20px;display:grid;gap:10px">
                            <button class="btn block secondary" data-act="guide"><i class="fa-solid fa-life-ring"></i> Guide me — steps, tools &amp; safety</button>
                            ${j.canTake ? '<button class="btn block" data-act="take">Accept job</button>' : ''}
                            ${working && j.checkKind === 'onsite' ? '<button class="btn block secondary" data-act="work">Start work</button>' : ''}
                            ${working ? '<button class="btn block" data-act="done">Complete job</button>' : ''}
                            ${working || (j.canDispatch && j.status !== 'completed' && j.assigned) ? '<button class="btn block destructive" data-act="release">Hand back</button>' : ''}
                        </div>`;
                };
                c.innerHTML = owSpin; load();
                timer = setInterval(() => { if (document.body.contains(c)) load(); else clearInterval(timer); }, 5000);
                ctx.opts.onLeave = () => clearInterval(timer);
                let busy = false;
                c.addEventListener('click', async (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    const act = a.dataset.act;
                    // accept / start / complete / hand back: one request at a time (a double tap must not complete twice)
                    if (['take', 'work', 'done', 'release'].includes(act)) {
                        if (busy) return;
                        busy = true;
                        try { await jobAct(act); } finally { busy = false; }
                        return;
                    }
                    if (act === 'web') { Phone.openApp('browser', { url: a.dataset.co === 'domains' ? 'https://opsdomains.sa/my' : 'https://opsweb.sa/panel' }); return; }
                    if (act === 'gps') { const r = await owRpc('opsJob', { id }); if (r && r.job && r.job.x != null) { nui('setWaypoint', { x: r.job.x, y: r.job.y }); UI.toast('Waypoint set', 'fa-solid fa-location-dot'); } return; }
                    if (act === 'training') return OwPages.training(nav);
                    if (act === 'guide') return OwPages.guide(nav, id);
                });
                const jobAct = async (act) => {
                    if (act === 'take') { const r = await owRpc('opsAccept', { id }); if (r && r.ok) { if (r.x != null) nui('setWaypoint', { x: r.x, y: r.y }); UI.toast('Job accepted · waypoint set'); } else if (r && r.training) { if (await UI.alert({ title: 'Certification needed', message: r.error, buttons: [{ label: 'Later', value: false }, { label: 'Training', value: true, style: 'bold' }] })) return OwPages.training(nav); } else if (r) UI.alert({ title: 'Can’t take it', message: r.error }); return load(); }
                    if (act === 'work') { const r = await owRpc('opsWork', { id }); if (r && r.ok) UI.toast(`Working… ${Math.max(0, r.secs - r.elapsed)} s`, 'fa-solid fa-screwdriver-wrench'); else if (r && (r.needRA || r.needTools)) { if (await UI.alert({ title: 'Not yet', message: r.error, buttons: [{ label: 'Later', value: false }, { label: 'Guide me', value: true, style: 'bold' }] })) return OwPages.guide(nav, id); } else if (r) UI.alert({ title: 'Not yet', message: r.error }); return load(); }
                    if (act === 'done') {
                        const r = await owRpc('opsComplete', { id });
                        if (r && r.ok) { Sound.play && Sound.play('unlock'); UI.alert({ title: 'Job complete', message: `Wages paid: ${owMoney(r.wage)}${r.invoice ? `\nInvoice ${r.invoice} · ${owMoney(r.price)} · ${r.paid ? 'paid' : 'outstanding'}` : ''}` }); }
                        else if (r && (r.needRA || r.needTools || r.needParts)) { if (await UI.alert({ title: 'Not finished', message: r.error, buttons: [{ label: 'Later', value: false }, { label: 'Guide me', value: true, style: 'bold' }] })) return OwPages.guide(nav, id); }
                        else if (r) UI.alert({ title: 'Not finished', message: r.error });
                        return load();
                    }
                    if (act === 'release') { if (await UI.confirm('Hand the job back?', 'It goes back on the job board.', 'Hand back', true)) { await owRpc('opsRelease', { id }); load(); } }
                };
            },
        });
    },

    earnings(nav) {
        nav.push({
            title: 'Earnings', grouped: true, backLabel: 'OPS Work',
            async render(c) {
                c.innerHTML = owSpin;
                const r = await owRpc('opsEarnings');
                if (!r) return;
                c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row"><div class="grow muted">This week</div><b>${owMoney(r.week)}</b></div><div class="row"><div class="grow muted">Recent total</div><b>${owMoney(r.total)}</b></div></div>
                    <div class="group">${(r.wages || []).length ? r.wages.map((w) => `<div class="row"><div class="grow"><div>${esc(w.label || '')}</div><div class="sub muted">${esc(w.company || '')} · ${owWhen(w.at)}</div></div><b>${owMoney(w.amount)}</b></div>`).join('') : '<div class="row"><div class="grow muted">No wages yet</div></div>'}</div>`;
            },
        });
    },

    people(nav, co, data) {
        nav.push({
            title: 'Employees', grouped: true, backLabel: co.name,
            render(c) {
                const can = data.perms.includes('employees.manage');
                const draw = () => {
                    c.innerHTML = `<div class="group" style="margin-top:12px">${(data.employees || []).map((e) => `<div class="row ${can ? 'tap' : ''} has-icon" data-m="${e.id}">${owIcon(e.status === 'applied' ? 'user-clock' : 'user', e.status === 'applied' ? '#ff9f0a' : '#5e5ce6')}
                        <div class="grow"><div>${esc(e.display_name || e.username)}</div><div class="sub muted">${esc(e.role || '')} · ${esc(e.status)}${e.note ? ' · ' + esc(e.note) : ''}</div></div></div>`).join('') || '<div class="row"><div class="grow muted">Nobody yet</div></div>'}</div>`;
                };
                draw();
                if (!can) return;
                c.addEventListener('click', async (ev) => {
                    const m = ev.target.closest('[data-m]'); if (!m) return;
                    const e = data.employees.find((x) => x.id === +m.dataset.m);
                    const opts = (data.roles || []).map((r) => ({ label: (e.status === 'applied' ? 'Approve as ' : 'Make ') + r.name, value: 'role:' + r.code }));
                    opts.push({ label: 'Remove from company', value: 'remove', style: 'destructive' });
                    const pick = await UI.pick(e.display_name || e.username, opts);
                    if (!pick) return;
                    const res = pick === 'remove' ? await owRpc('opsMember', { id: e.id, action: 'remove' }) : await owRpc('opsMember', { id: e.id, action: e.status === 'applied' ? 'approve' : 'role', role: pick.slice(5) });
                    if (res && res.ok) { UI.toast('Saved'); nav.pop(); }
                });
            },
        });
    },

    finance(nav, co, data) {
        nav.push({
            title: 'Finance', grouped: true, backLabel: co.name,
            render(c) {
                c.innerHTML = `<div class="group" style="margin-top:12px"><div class="row"><div class="grow muted">Account balance</div><b>${owMoney(data.company.balance)}</b></div></div>
                    <div class="group-header">Transactions</div>
                    <div class="group">${(data.transactions || []).map((t) => `<div class="row"><div class="grow"><div>${esc(t.memo || t.kind)}</div><div class="sub muted">${esc(t.kind)} · ${owWhen(t.at)}</div></div><b style="color:${t.amount < 0 ? '#ff453a' : '#30d158'}">${owMoney(t.amount)}</b></div>`).join('') || '<div class="row"><div class="grow muted">No transactions</div></div>'}</div>
                    <div class="group-footer">Full accounts, invoices and payroll: OPS Hub.</div>`;
            },
        });
    },

    dispatch(nav, co, data, reload) {
        nav.push({
            title: 'New job', grouped: true, backLabel: co.name,
            render(c) {
                c.innerHTML = `<div class="group" style="margin-top:12px">
                    <div class="row"><select class="field" data-f="type">${(data.jobTypes || []).map((t) => `<option value="${t.code}">${esc(t.title)}</option>`).join('')}</select></div>
                    <div class="row"><input class="field" data-f="loc" placeholder="Location name (job goes where you stand)"></div>
                    <div class="row"><div class="grow">Emergency callout</div>${UI.switchHtml(false, 'data-f="em"')}</div></div>
                    <div style="padding:0 16px"><button class="btn block" data-act="go">Create job</button></div>`;
                $('[data-act=go]', c).onclick = async (ev) => {
                    const btn = ev.currentTarget;
                    if (btn.disabled) return;
                    btn.disabled = true;    // one job per tap
                    const em = $('[data-f=em] input', c) || $('[data-f=em]', c);
                    const r = await owRpc('opsDispatch', { company: co.code, type: $('[data-f=type]', c).value, location: $('[data-f=loc]', c).value, emergency: !!(em && em.checked) });
                    btn.disabled = false;
                    if (r && r.ok) { UI.toast('Job ' + r.ref + ' created'); nav.pop(); reload && reload(); } else if (r) UI.alert({ title: 'Couldn’t create', message: r.error });
                };
            },
        });
    },

    services(nav) {
        nav.push({
            title: 'Request a service', grouped: true, backLabel: 'OPS Work',
            async render(c) {
                c.innerHTML = owSpin;
                const r = owFix(await rpc('opsServices'));
                if (!r) return;
                const by = {};
                (r.services || []).forEach((s) => { (by[s.companyName] = by[s.companyName] || []).push(s); });
                c.innerHTML = Object.keys(by).sort().map((name) => `<div class="group-header">${esc(name)}</div><div class="group">${by[name].map((s) => `<div class="row tap has-icon" data-s="${s.code}">${owIcon(s.icon, s.color)}
                    <div class="grow"><div>${esc(s.title)}</div><div class="sub muted">${esc(s.desc || '')}</div></div><span class="sub muted">from ${owMoney(s.price)}</span></div>`).join('')}</div>`).join('')
                    + '<div class="group-footer">An engineer comes to where you are now. You pay when the job is done (from your bank).</div>';
                c.addEventListener('click', async (e) => {
                    const s = e.target.closest('[data-s]'); if (!s) return;
                    const svc = r.services.find((x) => x.code === s.dataset.s);
                    const addr = await UI.prompt(svc.title, `${svc.companyName} · from ${owMoney(svc.price)}. Where are you? (address or business name)`, { placeholder: 'e.g. 12 Forum Drive' });
                    if (addr === null) return;
                    const x = owFix(await rpc('opsRequest', { type: svc.code, address: addr }));
                    if (x && x.ok) UI.alert({ title: 'Request sent', message: `Reference ${x.ref}. You’ll get a message when an engineer is on the way.` });
                    else UI.alert({ title: 'Couldn’t send', message: (x && x.error) || 'Try again' });
                });
            },
        });
    },

    requests(nav) {
        nav.push({
            title: 'My requests', grouped: true, backLabel: 'OPS Work',
            async render(c) {
                c.innerHTML = owSpin;
                const r = owFix(await rpc('opsServices'));
                if (!r) return;
                c.innerHTML = `<div class="group-header">Requests</div><div class="group">${(r.requests || []).map((j) => `<div class="row"><div class="grow"><div>${esc(j.title)}</div><div class="sub muted">${esc(j.companyName || '')} · ${esc(j.ref)}${j.assigned ? ' · ' + esc(j.assigned) : ''}</div></div>${owPill(j.status)}</div>`).join('') || '<div class="row"><div class="grow muted">No requests</div></div>'}</div>
                    <div class="group-header">Invoices</div><div class="group">${(r.invoices || []).map((i) => `<div class="row"><div class="grow"><div>${esc(i.number)} · ${esc(i.company)}</div><div class="sub muted">${owWhen(i.issued_at)}</div></div><b>${owMoney(i.total)}</b>&nbsp;<span class="sub muted">${esc(i.status)}</span></div>`).join('') || '<div class="row"><div class="grow muted">No invoices</div></div>'}</div>`;
            },
        });
    },
};

/* ---------------- the apps ---------------- */
const OPSWORK_ICON = '<i class="fa-solid fa-briefcase" style="font-size:28px;color:#fff"></i>';
Apps.register({
    id: 'opswork', name: 'OPS Work', resumable: false,
    splash: 'linear-gradient(160deg,#1c1c1e,#0a84ff 80%)',
    icon: { bg: 'linear-gradient(150deg,#0b3d91,#0a84ff 60%,#5e5ce6)', html: () => OPSWORK_ICON },
    open(root, params) { return OpsWork.open(root, params, null); },
    onClose() { OpsWork.root = null; },
});
// a branded app per company — the same app, opened on that company
[
    ['network', 'OPS Network', 'network-wired', '#0a84ff'], ['fibre', 'OPS Fibre', 'circle-nodes', '#30d158'], ['secure', 'OPS Secure', 'video', '#ff375f'],
    ['comms', 'OPS Comms', 'phone', '#bf5af2'], ['systems', 'OPS Systems', 'laptop-code', '#64d2ff'], ['domains', 'OPS Domains', 'globe', '#c9a400'],
    ['web', 'OPS Web', 'code', '#ff9f0a'], ['data', 'OPS Data', 'server', '#5e5ce6'], ['cloud', 'OPS Cloud', 'cloud', '#40c8e0'],
    ['pos', 'OPS POS', 'cash-register', '#ff9f0a'],
    // OPS America (US fiber) sub-companies
    ['usfiber', 'OPS America Fiber', 'flag-usa', '#2f6bff'], ['usosp', 'OPS America OSP', 'person-digging', '#e5484d'], ['usnet', 'OPS America NetOps', 'diagram-project', '#8e7dff'],
].forEach(([code, name, icon, color]) => Apps.register({
    id: 'ops_' + code, name, resumable: false, defaultInstalled: false,
    splash: `linear-gradient(160deg,#111,${color})`,
    icon: { bg: `linear-gradient(150deg,${color},#111 140%)`, html: () => `<i class="fa-solid fa-${icon}" style="font-size:28px;color:#fff"></i>` },
    open(root, params) { return OpsWork.open(root, params, code); },
    onClose() { OpsWork.root = null; },
}));
