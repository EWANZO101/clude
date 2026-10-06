'use strict';

/* =====================================================================
   Branding — this server's names on every screen (phone, laptop, router pages, stores, websites).
   The server sends { brand, stock, sites, renames } (server/brand.lua). Everything in the UI is written with the
   built-in names (OPS OS, OPS Work, opsweb.sa …); `Brand.rw()` swaps them for this server's, and the I18N text
   pass (i18n.js) runs it over the whole screen — so it costs nothing while the brand is the default.
   ===================================================================== */
const Brand = {
    data: { Name: 'OPS', Color: '#5b3df5', Accent: '#38bdf8' },
    pairs: [],
    re: null,
    active: false,

    set(p) {
        if (!p || !p.brand) return;
        this.data = p.brand;
        const pairs = [];
        const add = (from, to) => { if (from && to && from !== to) pairs.push([from, to]); };
        for (const [k, v] of Object.entries(p.stock || {})) add(v, p.brand[k]);
        for (const [k, v] of Object.entries(p.sites || {})) add(v, (p.brand.Sites || {})[k]);
        for (const r of p.renames || []) add(r.from, r.to);
        pairs.sort((a, b) => b[0].length - a[0].length);   // longest first: "OPS Hub · Network · Power" before "OPS Hub"
        this.pairs = pairs;
        this.map = new Map(pairs);
        this.re = pairs.length ? new RegExp('(?<![\\w-])(' + pairs.map(([f]) => f.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')(?![\\w-])', 'g') : null;
        // a bare "OPS" (e.g. "any OPS company") → the brand name; "OPS Network"-style company names are left to the renames
        this.bare = this.data.Name && this.data.Name !== 'OPS' ? this.data.Name : null;
        this.active = !!this.re || !!this.bare;
        const root = document.documentElement.style;
        root.setProperty('--brand', this.data.Color || '#5b3df5');
        root.setProperty('--brand-accent', this.data.Accent || '#38bdf8');
        // app names on the home screen, dock and store are text too — the I18N pass below rewrites them
        if (typeof I18N !== 'undefined') I18N.refresh();
    },

    /** built-in names → this server's names */
    rw(s) {
        if (!this.active || typeof s !== 'string' || !s) return s;
        if (this.re) s = s.replace(this.re, (m) => this.map.get(m) || m);
        if (this.bare) s = s.replace(/(?<![\w-])OPS(?![\w-]|\s+[A-Z])/g, this.bare);
        return s;
    },

    /** an internal site address with this server's domain (e.g. https://opsweb.sa → https://yourweb.sa) */
    url(u) { return this.rw(u); },
    get name() { return this.data.Name || 'OPS'; },
};
Phone.on('init', (d) => Brand.set(d && d.brand));
Phone.on('brand', (d) => Brand.set(d));
