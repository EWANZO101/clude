'use strict';

/* =====================================================================
   OPSHUB licensing in the phone UI (server/license.lua, opslabs-license)
   - first launch / unlicensed: the OPSHUB License Setup screen covers
     the phone (before its own setup). A server admin enters the key:
     validate → register this server → receive the signed configuration
     → OPS Phone setup carries on. Everyone else sees why it's locked.
   - licensed: apps the license doesn't include are hidden; calls into
     modules it doesn't include come back as { __license } → a notice.
   ===================================================================== */

// app id → OPSHUB module (apps not listed are part of the phone core, module 'phone')
const LICENSE_APP_MODULES = {
    messages: 'phone.messages', phone: 'phone.calls', contacts: 'phone.contacts', mail: 'phone.mail',
    camera: 'phone.camera', photos: 'phone.camera', wallet: 'phone.wallet', maps: 'phone.maps',
    chirp: 'phone.social', dating: 'phone.social', browser: 'phone.browser',
    opswork: 'phone.opswork', opsnet: 'phone.opswork', academy: 'phone.opswork',
    traffic: 'phone.traffic', secureview: 'phone.secureview', dev: 'phone.admin',
};

const License = {
    s: { status: 'starting', modules: [], allowAll: false },
    _set: new Set(),
    _busy: false,

    update(s) {
        if (!s) return;
        const was = this.active();
        this.s = Object.assign({}, this.s, s);
        this._set = new Set(this.s.modules || []);
        if (this.active()) this.hide(); else this.show();
        if (was !== this.active() && typeof renderHome === 'function') renderHome();
    },

    active() { return this.s.status === 'active'; },
    has(code) { return this.active() && (this.s.allowAll || this._set.has(code)); },

    /** may this app show? (core.js isInstalled) */
    allowsApp(id) {
        if (!this.active()) return true;                       // the license screen covers everything anyway
        const base = String(id).startsWith('ops_') ? 'phone.opswork' : LICENSE_APP_MODULES[id];
        return base ? this.has(base) : this.has('phone');
    },

    blocked(module) {
        const names = { 'phone.messages': 'Messages', 'phone.calls': 'Calls', 'phone.contacts': 'Contacts', 'phone.mail': 'Mail', 'phone.camera': 'Camera & Photos',
            'phone.wallet': 'Wallet', 'phone.maps': 'Maps', 'phone.social': 'Social apps', 'phone.browser': 'The browser', 'phone.opswork': 'OPS Work',
            'phone.traffic': 'OPS Traffic', 'phone.secureview': 'Secure View', 'phone.laptop': 'The laptop', 'phone.admin': 'Admin tools', phone: 'OPS Phone' };
        if (typeof UI !== 'undefined' && UI.toast) UI.toast(`${names[module] || module} isn't included in this server's OPSHUB license`, 'fa-solid fa-lock');
        if (module === 'phone') this.show();
    },

    /* ------------------------------------------------------------------ the license screen */
    host() {
        let h = $('#lic-gate');
        if (!h) {
            h = el('<div class="lic-gate" id="lic-gate"></div>');
            screenEl().appendChild(h);
            h.addEventListener('input', (e) => {
                if (e.target.id !== 'lic-key') return;
                // type or paste anything: shown as OPSHUB-XXXX-XXXX-XXXX-XXXX
                // the OPSHUB- prefix is a fixed label: only the 16 characters are typed (a pasted full key loses its prefix)
                let raw = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
                if (raw.startsWith('OPSHUB')) raw = raw.slice(6);
                raw = raw.replace(/[01IO]/g, '');                         // OPSHUB keys never use 0 1 I O
                if (raw.startsWith('PSHUB')) raw = raw.slice(5);          // typed the prefix letter by letter (its O dropped above)
                raw = raw.slice(0, 16);
                e.target.value = raw ? raw.match(/.{1,4}/g).join('-') : '';
                $('#lic-go').disabled = raw.length !== 16;
                $('#lic-err').textContent = '';
            });
            h.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target.id === 'lic-key' && !$('#lic-go').disabled) this.activate(); });
            h.addEventListener('click', (e) => {
                if (e.target.closest('#lic-go')) this.activate();
                if (e.target.closest('#lic-retry')) this.retry();
            });
        }
        return h;
    },

    show() {
        const h = this.host();
        const s = this.s;
        const status = s.status || 'starting';
        const head = `<div class="lic-logo"><i class="fa-solid fa-key"></i></div><div class="lic-brand">OPSHUB</div>`;
        let body;
        if (status === 'starting') {
            body = `<h1>Checking license…</h1><p>Contacting OPSHUB.</p><div class="lic-spin"></div>`;
        } else if (status === 'missing') {
            body = `<h1>OPS Phone isn't activated</h1><p>${esc(s.message || 'The OPSHUB license resource (opslabs-license) isn\'t running on this server.')}</p>
                <button class="lic-btn ghost" id="lic-retry">Check again</button>`;
        } else {
            // never activated, suspended, revoked, expired, OPSHUB unreachable … the key can always be (re-)entered
            const heads = { unlicensed: ['Activate OPS Phone', 'OPS Phone needs a valid <b>OPSHUB license</b> to run on this server. Enter the key from your OPSHUB client portal — you only do this once.'],
                suspended: ['License suspended', ''], revoked: ['License revoked', ''], expired: ['License expired', ''],
                paused: ['Weekly owner check missed', ''] };
            const [title, intro] = heads[status] || ['License not valid', ''];
            body = `
                <h1>${esc(title)}</h1>
                <p>${intro || esc(s.message || 'OPS is switched off on this server until it has a valid license.')}</p>
                <div class="lic-field"><span>OPSHUB-</span><input id="lic-key" autocomplete="off" spellcheck="false" placeholder="XXXX-XXXX-XXXX-XXXX" maxlength="40" value=""></div>
                <div class="lic-err" id="lic-err"></div>
                <button class="lic-btn" id="lic-go" disabled>Activate</button>
                <button class="lic-btn ghost" id="lic-retry" style="margin-top:8px">Check again</button>
                <ol class="lic-steps" id="lic-steps"><li>Validate license</li><li>Register this server</li><li>Receive configuration</li></ol>
                <p class="lic-small" style="margin-top:14px">No license yet? Get one at <b data-no-i18n>opsphone-store.opslabsystems.cloud/license</b> — then enter it here, or put it in <b data-no-i18n>opslabs-license/config.lua</b> (Config.LicenseKey).</p>`;
        }
        h.innerHTML = `<div class="lic-card">${head}${body}<div class="lic-foot">Licensed &amp; secured by OPSHUB</div></div>`;
        h.classList.add('show');
        const k = $('#lic-key');
        if (k) setTimeout(() => k.focus(), 300);
    },

    hide() { const h = $('#lic-gate'); if (h) h.classList.remove('show'); },

    /** Check again: the server checks in with OPSHUB right now (not just its last answer) */
    async retry() {
        const b = $('#lic-retry');
        if (!b || b.disabled) return;
        b.disabled = true;
        b.textContent = 'Checking with OPSHUB…';
        const s = await nui('rpc', { name: 'licenseRefresh', data: {} });
        if (s) this.update(s);
        const b2 = $('#lic-retry');
        if (b2) { b2.disabled = false; b2.textContent = 'Check again'; }
        if (s && s.status !== 'active') { const e = $('#lic-err'); if (e) e.textContent = s.message || 'Still not licensed.'; }
    },

    async activate() {
        if (this._busy) return;
        const key = 'OPSHUB-' + ($('#lic-key').value || '').trim();
        this._busy = true;
        $('#lic-go').disabled = true;
        $('#lic-err').textContent = '';
        const steps = [...$$('#lic-steps li')];
        const mark = (i, cls) => steps[i] && steps[i].classList.add(cls);
        mark(0, 'run');
        const t1 = setTimeout(() => { mark(0, 'done'); mark(1, 'run'); }, 700);
        const r = await nui('rpc', { name: 'licenseActivate', data: { key } });   // → server/license.lua → opslabs-license → OPSHUB
        clearTimeout(t1);
        this._busy = false;
        if (!r || r.error) {
            steps.forEach((li) => li.classList.remove('run', 'done'));
            $('#lic-err').textContent = (r && r.error) || 'Couldn\'t reach the server — try again.';
            $('#lic-go').disabled = false;
            return;
        }
        [0, 1].forEach((i) => mark(i, 'done'));
        mark(2, 'run');
        setTimeout(() => {
            mark(2, 'done');
            Sound.play('unlock');
            setTimeout(() => {
                this.update(r.license);
                if (Phone.needsSetup && typeof Setup !== 'undefined') Setup.show();
            }, 600);
        }, 600);
    },
};

Phone.on('license', (s) => License.update(s));
// the license comes with the phone's init data; the browser preview (no game) counts as licensed
Phone.on('init', (d) => License.update((d && d.config && d.config.license) || (typeof IN_GAME !== 'undefined' && !IN_GAME ? { status: 'active', allowAll: true } : { status: 'starting' })));
Phone.on('open', () => { if (!License.active()) License.show(); });
