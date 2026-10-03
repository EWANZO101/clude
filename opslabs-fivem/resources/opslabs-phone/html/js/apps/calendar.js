'use strict';

Apps.register({
    id: 'calendar',
    name: 'Calendar',
    icon: {
        bg: '#fff',
        html: () => {
            const d = new Date();
            return `<div style="position:absolute;top:7px;left:0;right:0;text-align:center;font-size:10.5px;font-weight:600;color:#ff3b30;letter-spacing:.2px">${d.toLocaleDateString(Phone.locale, { weekday: 'long' }).toUpperCase()}</div>
                <div style="position:absolute;top:17px;left:0;right:0;text-align:center;font-size:36px;font-weight:300;color:#000;letter-spacing:-1px">${d.getDate()}</div>`;
        },
    },
    open(root) {
        const nav = new Nav(root);
        let view = new Date();
        view.setDate(1);
        nav.push({
            title: '',
            noBack: true,
            className: 'calendar-page',
            left: '<button class="nav-btn" data-act="prev"><i class="fa-solid fa-chevron-left"></i></button>',
            right: '<button class="nav-btn" data-act="today">Today</button><button class="nav-btn" data-act="next"><i class="fa-solid fa-chevron-right"></i></button>',
            render(content, ctx) {
                const draw = () => {
                    const today = new Date();
                    const y = view.getFullYear(), m = view.getMonth();
                    const first = (new Date(y, m, 1).getDay() - weekOffset() + 7) % 7;
                    const days = new Date(y, m + 1, 0).getDate();
                    const cells = [];
                    for (let i = 0; i < first; i++) cells.push('<span></span>');
                    for (let d = 1; d <= days; d++) {
                        const isToday = d === today.getDate() && m === today.getMonth() && y === today.getFullYear();
                        const dow = (first + d - 1 + weekOffset()) % 7;
                        cells.push(`<span class="${isToday ? 'today' : ''} ${dow === 0 || dow === 6 ? 'weekend' : ''}">${d}</span>`);
                    }
                    content.innerHTML = `
                        <div class="cal-year tint">${y}</div>
                        <div class="cal-month">${view.toLocaleDateString(Phone.locale, { month: 'long' })}</div>
                        <div class="cal-dow">${weekLetters().map((d) => `<span>${d}</span>`).join('')}</div>
                        <div class="cal-grid">${cells.join('')}</div>
                        <div class="cal-today">
                            <div class="muted" style="font-size:13px;font-weight:600">${today.toLocaleDateString(Phone.locale, { weekday: 'long', month: 'long', day: 'numeric' }).toUpperCase()}</div>
                            <div class="cal-event"><i></i><div><b>No Events</b><span class="muted">Enjoy your day in Los Santos</span></div></div>
                        </div>`;
                };
                draw();
                ctx.page.addEventListener('click', (e) => {
                    const a = e.target.closest('[data-act]');
                    if (!a) return;
                    if (a.dataset.act === 'prev') view.setMonth(view.getMonth() - 1);
                    if (a.dataset.act === 'next') view.setMonth(view.getMonth() + 1);
                    if (a.dataset.act === 'today') { view = new Date(); view.setDate(1); }
                    draw();
                });
                drag(content, {
                    onEnd: (dx, _dy, _vy, _vx, _e, moved) => {
                        if (!moved || Math.abs(dx) < 60) return;
                        view.setMonth(view.getMonth() + (dx < 0 ? 1 : -1));
                        draw();
                    },
                });
            },
        });
    },
});
