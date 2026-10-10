'use strict';

/* =====================================================================
   OPS OS Setup Assistant — runs the first time a character opens the phone.
   Hello → Language → Region → Name → Number → OPS ID (email) →
   Face Unlock & Passcode → Appearance → Performance → Done
   ===================================================================== */

const HELLOS = ['hello', 'hola', 'bonjour', 'hallo', 'olá', 'ciao', 'hej'];

const Setup = {
    el: null,
    info: null,
    state: null,
    step: 0,
    steps: ['hello', 'language', 'units', 'name', 'number', 'email', 'passcode', 'appearance', 'performance', 'done'],

    get active() { return !!this.el; },

    async show() {
        if (this.el) return;
        this.state = {
            language: Phone.settings.language || 'en',
            region: Phone.settings.region || 'US',
            name: Phone.profile?.name || '',
            number: Phone.profile?.number || '',
            emailUser: (Phone.profile?.email || '').split('@')[0],
            passcode: '',
            faceId: true,
            darkMode: !!Phone.settings.darkMode,
            perf: null,
        };
        this.el = el('<div class="setup" id="setup"><div class="st-track"></div></div>');
        $('#screen').appendChild(this.el);
        screenEl().classList.add('in-setup');
        this.go(0, false);
        this.info = await rpc('setupInfo');
        if (this.info) {
            Object.assign(this.state, { name: this.info.name, number: this.info.number, emailUser: this.info.emailUser });
            this.taken = {
                number: new Set(this.info.takenNumbers || []),
                email: new Set(this.info.takenEmails || []),
                complete: this.info.takenComplete !== false,
            };
            this.suggestions = this.makeSuggestions(3);
            const page = this.el && $('.st-step.st-number:last-child', this.el);
            if (page) this.renderChips(page);
        }
    },

    hide() {
        if (!this.el) return;
        const n = this.el;
        this.el = null;
        screenEl().classList.remove('in-setup');
        n.classList.add('leaving');
        setTimeout(() => n.remove(), 380);
    },

    go(i, animate = true) {
        const track = $('.st-track', this.el);
        const dir = i >= this.step ? 1 : -1;
        this.step = i;
        const id = this.steps[i];
        const page = el(`<div class="st-step st-${id}">${this.render(id)}</div>`);
        const old = $('.st-step', track);
        if (old && animate) {
            page.style.transform = `translateX(${dir * 100}%)`;
            track.appendChild(page);
            page.getBoundingClientRect();
            requestAnimationFrame(() => {
                page.style.transform = '';
                old.style.transform = `translateX(${-dir * 30}%)`;
                old.style.opacity = '0';
                setTimeout(() => old.remove(), 450);
            });
        } else {
            if (old) old.remove();
            track.appendChild(page);
        }
        this.bind(id, page);
    },

    next() { if (this.step < this.steps.length - 1) this.go(this.step + 1); },
    back() { if (this.step > 1) this.go(this.step - 1); },

    head(icon, title, sub, color = 'var(--tint)') {
        return `
            ${this.step > 1 && this.step < this.steps.length - 1 ? '<button class="st-back nav-btn" data-st="back"><i class="fa-solid fa-chevron-left"></i>Back</button>' : ''}
            <div class="st-head">
                <div class="st-icon" style="color:${color}"><i class="fa-solid ${icon}"></i></div>
                <h1>${esc(title)}</h1>
                ${sub ? `<p>${esc(sub)}</p>` : ''}
            </div>`;
    },

    render(id) {
        const s = this.state;
        switch (id) {
            case 'hello':
                return `
                    <div class="st-hello">
                        <div class="st-hello-word">hello</div>
                        <div class="st-hello-sub">OPS OS</div>
                    </div>
                    <button class="st-hello-go" data-st="next">Tap to set up <i class="fa-solid fa-arrow-right"></i></button>`;
            case 'language':
                return `${this.head('fa-globe', 'Set Up Your Phone', 'Choose your language')}
                    <div class="st-body scroll"><div class="group">${LANGUAGES.map((l) => `
                        <div class="row tap" data-lang="${l.id}"><div class="grow" data-no-i18n>${esc(l.native)}</div>${s.language === l.id ? '<i class="fa-solid fa-check check"></i>' : '<i class="fa-solid fa-chevron-right chev"></i>'}</div>`).join('')}
                    </div></div>`;
            case 'units':
                return `${this.head('fa-ruler-combined', 'Units & Formats', 'Pick each one — they don’t depend on your language.')}
                    <div class="st-region-top"><div class="st-preview units-preview" data-no-i18n>${unitsPreviewHtml()}</div></div>
                    <div class="st-body scroll st-region-list"><div class="units-editor">${unitsEditorHtml()}</div></div>
                    <div class="st-foot"><button class="btn block" data-st="next">Continue</button></div>`;
            case 'name':
                return `${this.head('fa-id-card', 'What’s your name?', 'This is shown on your contact card and to people you message.')}
                    <div class="st-body">
                        <div class="group"><div class="row"><input class="field" data-f="name" maxlength="40" placeholder="Name" value="${esc(s.name)}"></div></div>
                        <div class="st-error"></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="name">Continue</button></div>`;
            case 'number': {
                const fmt = (this.info && this.info.numberFormat) || Phone.profile?.numberFormat || '555-XXXX';
                return `${this.head('fa-phone', 'Choose Your Number', 'Keep the number you were given or pick your own.', '#34c759')}
                    <div class="st-body">
                        <div class="group"><div class="row"><i class="fa-solid fa-phone muted"></i><input class="field st-big" data-f="number" maxlength="20" autocomplete="off" placeholder="${esc(fmt.replace(/X/g, '0'))}" value="${esc(s.number)}" inputmode="numeric"></div></div>
                        <div class="st-check" data-check="number"></div>
                        <div class="st-chips"></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="number">Continue</button></div>`;
            }
            case 'email': {
                const domain = (this.info && this.info.domain) || Phone.profile?.mailDomain || 'opslabs.cloud';
                return `${this.head('fa-envelope', 'Create Your OPS ID', 'Your email address for Mail. You can sign in to other services with it.', '#1a8cfb')}
                    <div class="st-body">
                        <div class="group"><div class="row st-email"><input class="field" data-f="emailUser" maxlength="60" placeholder="example" value="${esc(s.emailUser)}" spellcheck="false" autocomplete="off" autocapitalize="off"><span class="muted" data-no-i18n>@${esc(domain)}</span></div></div>
                        <div class="st-address" data-no-i18n><b>${esc(s.emailUser || 'example')}</b>@${esc(domain)}</div>
                        <div class="st-check" data-check="email"></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="email">Continue</button></div>`;
            }
            case 'passcode':
                return `${this.head('fa-face-smile', 'Face Unlock & Passcode Setup', 'A passcode protects your phone. Face Unlock opens it when you raise it.', '#34c759')}
                    <div class="st-body">
                        <div class="st-pc-label">${s.passcode ? 'Passcode set' : 'Create Passcode'}</div>
                        <div class="st-dots">${'<i></i>'.repeat(4)}</div>
                        <div class="st-pad">${['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'del'].map((k) => k === '' ? '<span></span>' : `<button data-k="${k}">${k === 'del' ? '<i class="fa-solid fa-delete-left"></i>' : k}</button>`).join('')}</div>
                        <div class="group" style="margin-top:14px"><div class="row"><div class="grow">Face Unlock</div>${UI.switchHtml(s.faceId, 'data-f="faceId"')}</div></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="next" ${s.passcode ? '' : 'disabled'} data-pc-continue>Continue</button><button class="nav-btn st-skip" data-st="skipcode">Set Up Later</button></div>`;
            case 'appearance':
                return `${this.head('fa-circle-half-stroke', 'Choose a Look', 'You can change this any time in Settings.')}
                    <div class="st-body">
                        <div class="appearance">${[['light', 'Light', false], ['dark', 'Dark', true]].map(([k, l, d]) => `
                            <button data-look="${k}" class="${s.darkMode === d ? 'on' : ''}">
                                <span class="ap-phone ${k}" style="background:${wallpaperCss(Phone.settings.wallpaper)}"><i></i><i></i><i></i></span>
                                <span>${l}</span>
                                <span class="ap-check">${s.darkMode === d ? '<i class="fa-solid fa-circle-check"></i>' : '<i class="fa-regular fa-circle"></i>'}</span>
                            </button>`).join('')}
                        </div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="next">Continue</button></div>`;
            case 'performance':
                return `${this.head('fa-gauge-high', 'Optimising for Your PC', 'Testing how your PC runs the phone so it stays smooth.', '#ff9500')}
                    <div class="st-body">
                        <div class="st-bench"><div class="spinner" style="margin:6px auto"></div><span>Testing…</span></div>
                        <div class="st-presets"></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="next" disabled data-perf-continue>Continue</button></div>`;
            case 'done':
                return `
                    <div class="st-done">
                        <div class="st-done-logo"><i class="fa-solid fa-circle-check"></i></div>
                        <h1>Welcome to OPS OS</h1>
                        <p data-no-i18n>${esc(s.name)} · ${esc(s.number)}<br>${esc(s.emailUser)}@${esc((this.info && this.info.domain) || 'opslabs.cloud')}</p>
                        <div class="st-error"></div>
                    </div>
                    <div class="st-foot"><button class="btn block" data-st="finish">Get Started</button></div>`;
        }
        return '';
    },

    /** tidy what the player types: OPS ID = lowercase local part only, number = digits/dash */
    cleanInput(kind, v) {
        v = String(v || '');
        // '@' may be typed (people type full addresses); only the part before it is used
        if (kind === 'email') return v.toLowerCase().replace(/[^a-z0-9._@-]/g, '').slice(0, 60);
        return v.replace(/[^0-9-]/g, '').slice(0, 20);
    },

    /** the value actually checked / saved */
    finalValue(kind, v) {
        v = this.cleanInput(kind, v);
        if (kind === 'email') return v.split('@')[0].slice(0, 30);
        // apply the server's number format once the digit count matches ("5557070" -> "555-7070")
        const fmt = (this.info && this.info.numberFormat) || Phone.profile?.numberFormat || '';
        const digits = v.replace(/\D/g, '');
        const slots = (fmt.match(/[\dX]/g) || []).length;
        if (fmt && digits.length === slots) { let i = 0; return fmt.replace(/[\dX]/g, () => digits[i++]); }
        return v;
    },

    numberFormat() { return (this.info && this.info.numberFormat) || Phone.profile?.numberFormat || '555-XXXX'; },

    /** formats digits progressively as they are typed: "55570" -> "555-70" */
    formatAsYouType(v) {
        const fmt = this.numberFormat();
        const digits = String(v).replace(/\D/g, '');
        let out = '', i = 0;
        for (const ch of fmt) {
            if (i >= digits.length) break;
            if (/[\dX]/.test(ch)) out += digits[i++];
            else out += ch;
        }
        return out;
    },

    /** random free numbers in the server's format, picked on the phone (instant) */
    makeSuggestions(count) {
        const fmt = this.numberFormat();
        const out = new Set();
        for (let tries = 0; out.size < count && tries < 200; tries++) {
            const n = fmt.replace(/X/g, () => String(Math.floor(Math.random() * 10)));
            if (!(this.taken && this.taken.number.has(n)) && n !== Phone.profile?.number) out.add(n);
        }
        return [...out];
    },

    renderChips(page) {
        const box = $('.st-chips', page);
        if (!box) return;
        box.innerHTML = (this.suggestions || []).map((n) => `<button data-num="${esc(n)}">${esc(n)}</button>`).join('') +
            '<button class="st-chip-more" data-more="1" title="More"><i class="fa-solid fa-shuffle"></i></button>';
    },

    /** instant checks that don't need the server; returns a result or null */
    localCheck(kind, value) {
        if (kind === 'number') {
            const fmt = this.numberFormat();
            const re = new RegExp('^' + fmt.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/X/g, '\\d') + '$');
            if (!re.test(value)) return { ok: false, error: `${I18N.t('Use the format')} ${fmt.replace(/X/g, '0')}` };
            if (value === Phone.profile?.number) return { ok: true };
            if (this.taken && this.taken.number.has(value)) return { ok: false, error: I18N.t('That number is taken') };
            if (this.taken && this.taken.complete) return { ok: true };
            return null;
        }
        if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(value)) return { ok: false, error: I18N.t('3–30 letters, numbers, dots, dashes or underscores') };
        if (Phone.profile?.email && value === Phone.profile.email.split('@')[0]) return { ok: true };
        if (this.taken && this.taken.email.has(value)) return { ok: false, error: I18N.t('That address is taken') };
        if (this.taken && this.taken.complete) return { ok: true };
        return null;
    },

    showCheck(kind, page, r) {
        const box = $(`[data-check=${kind}]`, page);
        if (!box || !document.body.contains(box)) return;
        box.className = 'st-check ' + (r.ok ? 'ok' : 'bad');
        box.textContent = r.ok ? I18N.t('Available ✓') : r.error;
    },

    /** instant when possible, server round trip only as a fallback (latest request wins) */
    async validate(kind, value, page) {
        const local = this.localCheck(kind, value);
        if (local) { this._checkSeq = (this._checkSeq || 0) + 1; this.showCheck(kind, page, local); return local; }
        const seq = (this._checkSeq = (this._checkSeq || 0) + 1);
        const box = $(`[data-check=${kind}]`, page);
        const slow = setTimeout(() => { if (seq === this._checkSeq && box) { box.className = 'st-check'; box.textContent = I18N.t('Checking…'); } }, 150);
        const res = await rpc('setupCheck', kind === 'number' ? { number: value } : { emailUser: value });
        clearTimeout(slow);
        const r = (res && res[kind]) || { ok: false, error: I18N.t('Could not check, try again') };
        if (seq === this._checkSeq) this.showCheck(kind, page, r);
        return r;
    },

    // live feedback while typing: instant locally, short debounce only for server fallback
    check(kind, value, page) {
        if (this.localCheck(kind, value)) return this.validate(kind, value, page);
        this._debouncedCheck(kind, value, page);
    },
    _debouncedCheck: debounce(function (kind, value, page) { Setup.validate(kind, value, page); }, 150),

    /** Continue on the number / OPS ID steps: validate the current value right now */
    async submitField(kind, page) {
        const f = kind === 'number' ? 'number' : 'emailUser';
        const inp = $(`[data-f=${f}]`, page);
        const btn = $(`[data-st=${kind}]`, page);
        const value = this.finalValue(kind, inp.value);
        inp.value = value;
        if (btn.classList.contains('busy')) return;
        btn.classList.add('busy');
        const r = await this.validate(kind, value, page);
        btn.classList.remove('busy');
        if (!r.ok) {
            const g = inp.closest('.group');
            g.classList.remove('shake'); void g.offsetWidth; g.classList.add('shake');
            inp.focus();
            return;
        }
        if (kind === 'number') this.state.number = value; else this.state.emailUser = value;
        this.next();
    },

    bind(id, page) {
        const s = this.state;
        page.addEventListener('click', async (e) => {
            const st = e.target.closest('[data-st]');
            const lang = e.target.closest('[data-lang]');
            if (lang) {
                s.language = lang.dataset.lang;
                Phone.settings.language = s.language;
                I18N.set(s.language);
                return this.next();
            }
            if (e.target.closest('[data-more]')) {
                this.suggestions = this.makeSuggestions(3);
                return this.renderChips(page);
            }
            const num = e.target.closest('[data-num]');
            if (num) {
                const inp = $('[data-f=number]', page);
                inp.value = num.dataset.num;
                inp.dispatchEvent(new Event('input'));
                return;
            }
            const theme = e.target.closest('[data-look]');
            if (theme) {
                s.darkMode = theme.dataset.look === 'dark';
                Phone.settings.darkMode = s.darkMode;
                applySettings();
                const fresh = el(`<div>${this.render('appearance')}</div>`);
                $('.appearance', page).replaceWith($('.appearance', fresh));
                return;
            }
            const preset = e.target.closest('[data-preset]');
            if (preset) {
                s.perf = preset.dataset.preset;
                $$('[data-preset]', page).forEach((p) => p.classList.toggle('on', p === preset));
                Perf.apply(s.perf);
                $('[data-perf-continue]', page).disabled = false;
                return;
            }
            const key = e.target.closest('[data-k]');
            if (key) return this.passKey(key.dataset.k, page);
            if (!st) return;

            switch (st.dataset.st) {
                case 'next': return this.next();
                case 'back': return this.back();
                case 'name': {
                    const v = $('[data-f=name]', page).value.trim();
                    if (v.length < 2) { $('.st-error', page).textContent = I18N.t('Enter your name (at least 2 characters)'); return; }
                    s.name = v;
                    return this.next();
                }
                case 'number': return this.submitField('number', page);
                case 'email': return this.submitField('email', page);
                case 'skipcode': s.passcode = ''; return this.next();
                case 'finish': return this.finish(page);
            }
        });

        if (id === 'hello') {
            let i = 0;
            const word = $('.st-hello-word', page);
            const iv = setInterval(() => {
                if (!document.body.contains(word)) return clearInterval(iv);
                i = (i + 1) % HELLOS.length;
                word.classList.add('swap');
                setTimeout(() => { word.textContent = HELLOS[i]; word.classList.remove('swap'); }, 350);
            }, 2200);
            drag(page, { onEnd: (_dx, dy, vy, _vx, _e, moved) => { if (moved && (dy < -60 || vy < -0.5)) this.next(); } });
        }
        if (id === 'name') setTimeout(() => $('[data-f=name]', page).focus(), 420);
        if (id === 'units') {
            // the editor writes straight into Phone.settings so the preview + status bar update live
            bindUnitsEditor(page, () => {});
        }
        if (id === 'number') this.renderChips(page);
        if (id === 'number' || id === 'email') {
            const f = id === 'number' ? 'number' : 'emailUser';
            const inp = $(`[data-f=${f}]`, page);
            const addr = $('.st-address b', page);
            inp.addEventListener('input', () => {
                const clean = id === 'number' ? this.formatAsYouType(inp.value) : this.cleanInput(id, inp.value);
                if (clean !== inp.value) {
                    const pos = Math.max(0, (inp.selectionStart || clean.length) - (inp.value.length - clean.length));
                    inp.value = clean;
                    try { inp.setSelectionRange(pos, pos); } catch (_) { /* ignore */ }
                }
                const value = this.finalValue(id, clean);
                if (addr) addr.textContent = value || 'example';
                // remember the latest value even before Continue (e.g. going Back)
                if (id === 'number') s.number = value; else s.emailUser = value;
                this.check(id, value, page);
            });
            if (inp.value) this.check(id, this.finalValue(id, inp.value), page);
            setTimeout(() => { inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length); }, 420);
        }
        if (id === 'passcode') {
            page.addEventListener('change', (e) => { if (e.target.dataset.f === 'faceId') s.faceId = e.target.checked; });
            this._pc = { first: null, entry: '' };
        }
        if (id === 'performance') this.runBench(page);
        page.addEventListener('keydown', (e) => {
            if (e.key !== 'Enter') return;
            const btn = $('.st-foot .btn:not([disabled])', page);
            if (btn) btn.click();
        });
    },

    passKey(k, page) {
        const pc = this._pc;
        if (k === 'del') pc.entry = pc.entry.slice(0, -1);
        else if (pc.entry.length < 4) { pc.entry += k; Sound.play('key', k); }
        $$('.st-dots i', page).forEach((d, i) => d.classList.toggle('on', i < pc.entry.length));
        if (pc.entry.length < 4) return;
        const label = $('.st-pc-label', page);
        if (!pc.first) {
            pc.first = pc.entry;
            pc.entry = '';
            setTimeout(() => {
                label.textContent = I18N.t('Enter Passcode');
                $$('.st-dots i', page).forEach((d) => d.classList.remove('on'));
            }, 200);
        } else if (pc.entry === pc.first) {
            this.state.passcode = pc.entry;
            label.textContent = I18N.t('Passcode set');
            $('[data-pc-continue]', page).disabled = false;
        } else {
            pc.first = null;
            pc.entry = '';
            const dots = $('.st-dots', page);
            dots.classList.add('shake');
            label.textContent = I18N.t('Create Passcode');
            setTimeout(() => { dots.classList.remove('shake'); $$('i', dots).forEach((d) => d.classList.remove('on')); }, 450);
        }
    },

    async runBench(page) {
        // measure on the heaviest profile so the result reflects worst case
        Phone.settings.reduceTransparency = false;
        Phone.settings.reduceMotion = false;
        applySettings();
        const r = await Perf.benchmark(page, 1500);
        if (!document.body.contains(page)) return;
        this.state.perf = r.recommended;
        Perf.apply(r.recommended);
        $('.st-bench', page).innerHTML = `
            <div class="st-bench-res"><b>${r.fps}</b><span>fps</span></div>
            <div class="st-bench-res"><b>${r.loadMs}</b><span>ms load</span></div>
            <div class="st-bench-res"><b>${r.p95}</b><span>ms worst</span></div>`;
        $('.st-presets', page).innerHTML = Object.entries(Perf.PRESETS).map(([id, p]) => `
            <button class="st-preset ${id === r.recommended ? 'on' : ''}" data-preset="${id}">
                <i class="fa-solid ${p.icon}"></i>
                <div class="grow"><b>${esc(p.label)}</b>${id === r.recommended ? ' <span class="st-rec">Recommended</span>' : ''}<small>${esc(p.desc)}</small></div>
            </button>`).join('');
        $('[data-perf-continue]', page).disabled = false;
    },

    async finish(page) {
        const s = this.state;
        const btn = $('[data-st=finish]', page);
        if (btn.classList.contains('busy')) return;
        btn.classList.add('busy');
        btn.innerHTML = `<span class="btn-spin"></span>${esc(I18N.t('Setting Up…'))}`;
        $('.st-error', page).textContent = '';
        const res = await rpc('completeSetup', {
            name: s.name,
            number: s.number,
            emailUser: s.emailUser,
            settings: {
                language: s.language,
                region: s.region,
                ...unitSettings(),
                darkMode: s.darkMode,
                passcode: s.passcode,
                faceId: s.faceId,
                ...Perf.settingsFor(s.perf || 'balanced'),
            },
        });
        if (!res || res.error) {
            btn.classList.remove('busy');
            btn.textContent = I18N.t(res ? 'Get Started' : 'Try Again');
            const steps = { name: 'name', number: 'number', email: 'email' };
            if (res && steps[res.field]) {
                UI.alert({ title: res.error });
                return this.go(this.steps.indexOf(steps[res.field]));
            }
            $('.st-error', page).textContent = res ? res.error
                : nui.lastFailure === 'outdated'
                    ? I18N.t('The server is running an old version of the phone. An admin needs to run “refresh” and then “restart opslabs-phone” in the server console.')
                    : I18N.t("Couldn't reach the server. Check your connection and tap Try Again.");
            return;
        }
        Phone.needsSetup = false;
        this.completedFor = res.init && res.init.email;
        this.hide();          // leave setup immediately, apply the new profile underneath
        unlockPhone();
        Sound.play('unlock');
        handlers.init(res.init);
    },
};

Phone.on('reset', () => Setup.hide());
