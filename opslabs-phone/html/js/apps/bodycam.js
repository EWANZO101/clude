'use strict';

/* =====================================================================
   Bodycam (opslabs-bodycam, client/bodycam.lua)
   - start / stop your body worn camera, see how long it has been
     recording and what started it, add a note (incident number…)
     that goes into the evidence caption
   - My footage: your recorded parts and whether the Xon Sight
     evidence portal has them
   - Live: who is recording right now (the same list as /live)
   Only shown to players issued a bodycam (config.bodycam).
   ===================================================================== */

const BC_RED = '#ff3b30';
const BC_REASON = {
    wrong_job: 'Your job isn’t issued a bodycam.', off_duty: 'Go on duty to use your bodycam.', grade: 'Your rank isn’t issued a bodycam yet.',
    no_item: 'You aren’t carrying a bodycam.', not_allowed: 'You aren’t issued a bodycam.',
};
const bcSince = (t) => fmtDuration(Math.floor(Date.now() / 1000) - t);

const Bodycam = {
    state: { recording: false },
    redraw: null,

    /** state pushed from the game (client/bodycam.lua) — island + open app */
    update(s) {
        this.state = s || { recording: false };
        if (this.state.recording) {
            Island.start('bodycam', {
                priority: 80,
                compact: () => ({ left: '<span class="isl-recdot"></span><span style="font-size:11px;font-weight:700;margin-left:4px">BWC</span>', right: `<span class="isl-num" style="color:#ff453a">${bcSince(this.state.startedAt)}</span>` }),
                minimal: () => '<span class="isl-recdot"></span>',
                onTap: () => Phone.openApp('bodycam'),
            });
        } else Island.end('bodycam');
        if (this.redraw) this.redraw();
    },

    open(root) {
        root.innerHTML = '';
        const nav = new Nav(root);
        nav.push({
            title: 'Bodycam', large: true, grouped: true,
            render: (c, ctx) => {
                let tab = 'mine', access = null, clock = null;
                const draw = () => {
                    const s = this.state;
                    if (access && !access.allowed && !s.recording) {
                        c.innerHTML = UI.empty('fa-solid fa-video-slash', 'No bodycam', BC_REASON[access.reason] || 'You aren’t issued a bodycam.');
                        return;
                    }
                    const rec = s.recording;
                    c.innerHTML = `
                        <div class="bc-card ${rec ? 'on' : ''}">
                            <div class="bc-lens"><i class="fa-solid fa-${rec ? 'circle' : 'video'}"></i></div>
                            <div class="bc-status">${rec ? 'Recording' : 'Standby'}</div>
                            <div class="bc-time">${rec ? bcSince(s.startedAt) : '—'}</div>
                            <div class="bc-sub">${rec ? esc(s.trigger && s.trigger !== 'manual' ? 'Started automatically: ' + s.trigger : 'Started by you') + (s.serial ? ' · ' + esc(s.serial) : '') : esc(`Key ${s.keybind || ''} or /${s.command || 'bodycam'} also starts it`)}</div>
                            ${s.uploading ? `<div class="bc-up"><i class="fa-solid fa-cloud-arrow-up"></i> Uploading ${s.uploading} part${s.uploading === 1 ? '' : 's'}…</div>` : ''}
                        </div>
                        <div style="padding:0 16px 14px"><button class="btn block ${rec ? 'danger' : ''}" data-act="toggle" ${s.busy ? 'disabled' : ''}>${rec ? 'Stop recording' : 'Start recording'}</button></div>
                        ${rec ? `<div class="group-header">Note on this recording</div>
                            <div class="group"><div class="row"><input class="field grow" data-f="note" maxlength="80" placeholder="Incident no., call, plate…" value="${esc(s.note || '')}"><button class="nav-btn bold" data-act="note">Save</button></div></div>
                            <div class="group-footer">Added to the evidence caption of every part recorded from now on.</div>` : ''}
                        <div class="segmented" style="margin:14px 16px 8px"><button data-t="mine">My footage</button><button data-t="live">Live</button></div>
                        <div class="bc-list"><div class="spinner" style="margin:30px auto"></div></div>
                        <div class="group-footer">Every recording goes to the Xon Sight evidence portal. Each part is uploaded when it finishes; long recordings are split into parts.</div>`;
                    $$('[data-t]', c).forEach((b) => b.classList.toggle('on', b.dataset.t === tab));
                    list();
                };
                let lseq = 0;
                const list = async () => {
                    const my = ++lseq;
                    const box = $('.bc-list', c);
                    if (!box) return;
                    const rows = (await nui(tab === 'mine' ? 'bodycamRecent' : 'bodycamLive')) || [];
                    if (my !== lseq || !box.isConnected) return;
                    if (tab === 'mine') {
                        box.innerHTML = rows.length ? `<div class="group">${rows.map((r) => `
                            <div class="row has-icon"><span class="ri" style="background:${r.sent ? '#30d158' : '#ff9f0a'}"><i class="fa-solid fa-${r.sent ? 'cloud' : 'clock'}"></i></span>
                                <div class="grow" style="min-width:0"><div>Part ${r.part} · ${fmtDuration(r.duration || 0)} <span class="muted" style="font-size:13px">${r.startedAt ? shortAgo(r.startedAt * 1000) : ''}</span></div>
                                <div class="sub muted bc-cap">${esc(r.caption || '')}</div></div>
                                <span class="sub muted">${r.sent ? '#' + esc(String(r.evidenceId)) : 'Pending'}</span></div>`).join('')}</div>`
                            : '<div class="group"><div class="row"><div class="grow muted">Nothing recorded yet</div></div></div>';
                    } else {
                        box.innerHTML = rows.length ? `<div class="group">${rows.map((r) => `
                            <div class="row has-icon"><span class="ri" style="background:${BC_RED}"><i class="fa-solid fa-circle"></i></span>
                                <div class="grow"><div>${esc(r.name || 'Unknown')}</div><div class="sub muted">${esc(r.job || '')}</div></div>
                                <span class="sub" style="color:${BC_RED}">${bcSince(r.startedAt)}</span></div>`).join('')}</div>`
                            : '<div class="group"><div class="row"><div class="grow muted">Nobody is recording</div></div></div>';
                    }
                };

                c.innerHTML = '<div class="spinner" style="margin:60px auto"></div>';
                (async () => {
                    const r = await nui('bodycamState');
                    access = r && r.access;
                    if (r && r.state) this.update(r.state);
                    draw();
                })();
                this.redraw = () => { if (c.isConnected) draw(); };
                clock = setInterval(() => {
                    if (!c.isConnected) return clearInterval(clock);
                    const t = $('.bc-time', c);
                    if (t && this.state.recording) t.textContent = bcSince(this.state.startedAt);
                }, 1000);
                ctx.opts.onResume = () => draw();

                c.addEventListener('click', async (e) => {
                    const t = e.target.closest('[data-t]');
                    if (t) { tab = t.dataset.t; $$('[data-t]', c).forEach((b) => b.classList.toggle('on', b.dataset.t === tab)); return list(); }
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'toggle') {
                        a.disabled = true;
                        const r = await nui('bodycamToggle');
                        if (r && r.state) this.update(r.state);
                        if (r && r.access) { access = r.access; draw(); }
                    } else if (a.dataset.act === 'note') {
                        const v = $('[data-f=note]', c).value.trim();
                        const r = await nui('bodycamNote', { note: v });
                        UI.toast(r && r.ok ? 'Note saved' : 'Not recording', r && r.ok ? 'fa-solid fa-check' : 'fa-solid fa-circle-exclamation');
                    }
                });
            },
        });
    },
};

Phone.on('bodycamState', (s) => Bodycam.update(s));
Phone.on('bodycamUploaded', (r) => { if (r && r.sent) UI.toast(`Bodycam part ${r.part} sent to evidence`, 'fa-solid fa-cloud-arrow-up'); if (Bodycam.redraw) Bodycam.redraw(); });

Apps.register({
    id: 'bodycam', name: 'Bodycam', resumable: false,
    splash: `linear-gradient(160deg,#111,#3a0b08)`,
    icon: { bg: 'linear-gradient(150deg,#2c2c2e,#0b0b0c 130%)', html: () => `<i class="fa-solid fa-video" style="font-size:26px;color:#fff"></i><span style="position:absolute;top:13px;right:13px;width:9px;height:9px;border-radius:50%;background:${Bodycam.state.recording ? BC_RED : '#555'}"></span>` },
    open(root) { return Bodycam.open(root); },
    onClose() { Bodycam.redraw = null; },
});
