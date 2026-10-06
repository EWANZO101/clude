'use strict';

function ServiceRequest(service) {
    UI.sheet({
        title: service.label,
        right: 'Send',
        render(body, api) {
            body.innerHTML = `
                <div style="display:flex;flex-direction:column;align-items:center;padding:6px 0 20px">
                    <div class="svc-big" style="background:${service.color}"><i class="fa-solid ${esc(service.icon)}"></i></div>
                    <div class="muted" style="margin-top:10px;font-size:14px">Your GPS location will be shared</div>
                </div>
                <div class="group"><div class="row"><textarea class="field" placeholder="Describe what's happening…" maxlength="400"></textarea></div></div>
                <div class="group-footer" style="margin-top:-24px">Emergency number: ${esc(service.number)}</div>`;
            const ta = $('textarea', body);
            ta.addEventListener('input', () => api.setRightEnabled(ta.value.trim().length > 2));
            api.setRightEnabled(false);
            setTimeout(() => ta.focus(), 350);
        },
        async onRight(api) {
            const ok = await rpc('serviceRequest', { service: service.id, message: $('textarea', api.body).value });
            api.close();
            if (ok) { Sound.play('sent'); UI.toast(`${service.label} notified`, 'fa-solid fa-tower-broadcast'); }
            else UI.alert({ title: 'Please wait', message: 'You recently sent a request. Try again in a moment.' });
        },
    });
}

Apps.register({
    id: 'services',
    name: 'Services',
    icon: { bg: 'linear-gradient(180deg,#ff5e57,#d70015)', glyph: 'fa-solid fa-tower-broadcast', size: 27 },
    open(root, _p, app) {
        const nav = new Nav(root);
        nav.push({
            title: 'Services',
            large: true,
            grouped: true,
            render(content, ctx) {
                const services = Phone.config.services || [];
                content.innerHTML = `
                    <div class="svc-grid">${services.map((s) => `
                        <button class="svc-tile" data-svc="${esc(s.id)}">
                            <span class="svc-icon" style="background:${esc(s.color)}"><i class="fa-solid ${esc(s.icon)}"></i></span>
                            <b>${esc(s.label)}</b><span>${esc(s.number)}</span>
                        </button>`).join('')}
                    </div>
                    <div class="group">
                        ${services.map((s) => `<div class="row tap has-icon" data-call="${esc(s.number)}"><span class="ri" style="background:${esc(s.color)}"><i class="fa-solid fa-phone"></i></span><div class="grow">Call ${esc(s.label)}</div><span class="value">${esc(s.number)}</span></div>`).join('')}
                    </div>
                    <div class="svc-dispatch"></div>`;

                const dispatch = $('.svc-dispatch', content);
                const loadDispatch = async () => {
                    const d = await rpc('getServiceRequests');
                    if (!d || !d.member) { dispatch.innerHTML = ''; return; }
                    const reqs = d.requests || [];
                    dispatch.innerHTML = `<div class="group-header big">Dispatch</div>
                        <div class="group">${reqs.length ? reqs.map((r) => `
                            <div class="row" style="align-items:flex-start;flex-direction:column;gap:6px">
                                <div style="display:flex;width:100%;gap:8px;align-items:center">
                                    <b class="grow">${esc(r.caller_name)}</b>
                                    <span class="svc-badge ${r.status}">${esc(r.status)}</span>
                                    <span class="muted" style="font-size:13px">${esc(shortAgo(r.created_at))}</span>
                                </div>
                                <div style="font-size:15px">${esc(r.message)}</div>
                                <div class="muted" style="font-size:13px">${esc(r.caller_number)}${r.handled_by ? ' · ' + esc(r.handled_by) : ''}</div>
                                <div style="display:flex;gap:8px;margin-top:2px">
                                    <button class="btn small" data-gps="${r.x},${r.y}"><i class="fa-solid fa-location-arrow"></i> GPS</button>
                                    ${r.status === 'open' ? `<button class="btn small gray" data-accept="${r.id}">Respond</button>` : ''}
                                    ${r.status !== 'closed' ? `<button class="btn small gray" data-closereq="${r.id}">Close</button>` : ''}
                                    <button class="btn small gray" data-call="${esc(r.caller_number)}"><i class="fa-solid fa-phone"></i></button>
                                </div>
                            </div>`).join('') : '<div class="row muted">No active requests</div>'}</div>`;
                };

                content.addEventListener('click', async (e) => {
                    const t = e.target.closest('[data-svc]');
                    if (t) return ServiceRequest(services.find((s) => s.id === t.dataset.svc));
                    const c = e.target.closest('[data-call]');
                    if (c) return Call.start(c.dataset.call);
                    const g = e.target.closest('[data-gps]');
                    if (g) { const [x, y] = g.dataset.gps.split(',').map(Number); nui('setWaypoint', { x, y }); return UI.toast('GPS set', 'fa-solid fa-location-arrow'); }
                    const acc = e.target.closest('[data-accept]');
                    if (acc) { await rpc('handleServiceRequest', { id: +acc.dataset.accept, status: 'accepted' }); return loadDispatch(); }
                    const cl = e.target.closest('[data-closereq]');
                    if (cl) { await rpc('handleServiceRequest', { id: +cl.dataset.closereq, status: 'closed' }); return loadDispatch(); }
                });
                app.on('serviceRequest', loadDispatch);
                ctx.opts.onResume = loadDispatch;
                loadDispatch();
            },
        });
    },
});
