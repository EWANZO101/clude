'use strict';

/*
 * Browser preview backend. Only active when the page is opened outside FiveM
 * (e.g. double-click html/index.html) so the UI can be designed without the
 * game. It is never used in-game.
 */
if (!IN_GAME) {
    const now = Date.now();
    const db = {
        contacts: [
            { id: 1, name: 'Ashley Carter', number: '555-0142', email: 'ashley.carter@opslabs.cloud', avatar: null, favorite: 1, blocked: 0 },
            { id: 2, name: 'Lamar Davis', number: '555-0199', email: null, avatar: null, favorite: 1, blocked: 0 },
            { id: 3, name: 'Mechanic Mike', number: '555-3321', email: null, avatar: null, favorite: 0, blocked: 0 },
            { id: 4, name: 'Tracey De Santa', number: '555-8812', email: 'tracey@opslabs.cloud', avatar: null, favorite: 0, blocked: 0 },
        ],
        messages: {
            '555-0142': [
                { id: 1, mine: false, message: 'Hey! Are you coming to Legion Square tonight?', created_at: now - 3600e3 * 3 },
                { id: 2, mine: true, message: 'Yeah, around 9 👍', created_at: now - 3600e3 * 2.9 },
                { id: 3, mine: false, message: '', attachment: { type: 'location', x: 195, y: -933 }, created_at: now - 3600e3 * 2.8 },
                { id: 4, mine: false, message: "I'll be here", created_at: now - 3600e3 * 2.8 },
            ],
            '555-0199': [{ id: 5, mine: false, message: 'Yo homie, call me when you get this', created_at: now - 86400e3 }],
        },
        notes: [{ id: 1, title: 'Groceries', body: 'Milk\nEggs\nCoffee', updated_at: now - 7200e3 }],
        photos: [],
        posts: [
            { id: 1, content: 'Traffic on the Del Perro Freeway is insane right now #LosSantos', image: null, created_at: now - 600e3, handle: 'lamar', display_name: 'Lamar Davis', likes: 12, replies: 2, liked: 0, mine: 0 },
            { id: 2, content: 'Just bought a new Pegassi at PDM 🏎️', image: null, created_at: now - 7200e3, handle: 'tracey', display_name: 'Tracey De Santa', likes: 41, replies: 7, liked: 1, mine: 0 },
        ],
        calls: [
            { id: 1, number: '555-0199', outgoing: false, status: 'missed', duration: 0, time: now - 1800e3 },
            { id: 2, number: '555-0142', outgoing: true, status: 'answered', duration: 184, time: now - 86400e3 },
        ],
        mail: [{ id: 1, sender: 'noreply@mazebank.ls', sender_name: 'Maze Bank', receiver: 'you', subject: 'Welcome to online banking', body: 'Your account is ready.\n\nThanks for banking with us.', is_read: 0, created_at: now - 4000e3 }],
    };

    const mockIncoming = {}, mockOutgoing = {};
    // ?carrier=pending | none | out shows the other carrier states
    const cMode = (location.search.match(/carrier=(\w+)/) || [])[1];
    window._carrier = {
        enabled: true, name: 'OPS Mobile', number: '6677', credit: 250, storeUrl: 'https://opsphone-store.opslabsystems.cloud',
        line: cMode === 'none' ? undefined : {
            status: cMode === 'pending' ? 'pending' : 'active', installed: cMode !== 'pending', service: cMode !== 'pending' && cMode !== 'out',
            plan: { code: 'essential', name: 'Essential', color: '#0a84ff', price: 500, period_days: 7 },
            period_start: Math.floor(now / 1000) - 86400, period_end: Math.floor(now / 1000) + 6 * 86400, auto_renew: true,
            iccid: '89441234567890123456', activation_code: cMode === 'pending' ? 'ABCD-EFGH-IJKL-MNOP' : null,
            usage: { sms: { used: 412, limit: 500 }, minutes: { used: 38, limit: 300 }, data_mb: { used: cMode === 'out' ? 5120 : 1843.2, limit: 5120 } },
        },
    };
    // OPS Work (server/platform.lua)
    const owJobs = [
        { id: 12, ref: 'NET-00012', company: 'network', companyName: 'OPS Network', color: '#0a84ff', icon: 'network-wired', title: 'Router installation', description: 'Fit and set up a new router / gateway for the customer.', status: 'open', priority: 'normal', emergency: false, location: '1076 Procopio Dr', x: -467.88, y: 6206.16, z: 28.57, price: 750, wage: 350, customer: '1076 Procopio Dr', customerKind: 'residential', customerAddress: '1076 Procopio Dr', sla: 'standard', created_at: 1759550000 },
        { id: 13, ref: 'NET-00013', company: 'network', companyName: 'OPS Network', color: '#0a84ff', icon: 'network-wired', title: 'Internet outage', description: 'Customer has no internet — emergency callout.', status: 'open', emergency: true, location: 'Mission Row Police Department', x: 425.1, y: -979.5, z: 30.7, price: 0, wage: 600, customer: 'Mission Row Police Department', customerKind: 'police', customerAddress: 'Mission Row Police Department', sla: 'critical' },
        { id: 14, ref: 'NET-00014', company: 'network', companyName: 'OPS Network', color: '#0a84ff', icon: 'network-wired', title: 'Business network installation', description: 'Gateway, PoE switch and two access points, all cabled.', status: 'assigned', mine: true, location: 'Fleeca Bank', x: 149.9, y: -1040.7, z: 29.4, price: 2600, wage: 1100, customer: 'Fleeca Bank', customerKind: 'business', customerAddress: 'Fleeca Bank', sla: 'business',
          checkKind: 'all', check: { ok: false, label: 'All parts', have: 0, need: 1, detail: '✓ Gateway: 1/1 · ✓ PoE switch: 1/1 · ✗ Access points: 1/2 · ✗ CAT6: 4/10' } },
    ];
    Object.assign(window, { __owJobs: owJobs });
    // ---- in-game internet (Browser) mocks
    const webSite = { theme: { color: '#7a4b2a', mode: 'light', font: 'serif' }, contact: { email: 'hello@beanmachine.ls', phone: '555-0199', address: 'Vespucci Blvd, Little Seoul' },
        pages: [{ slug: '', title: 'Home', blocks: [
            { t: 'hero', title: 'Bean Machine', text: 'Fresh coffee, all day, every day in Los Santos.', button: 'See the menu', href: '/menu', align: 'center' },
            { t: 'features', heading: 'Why us', items: [{ icon: 'mug-hot', title: 'Roasted daily', text: 'Beans roasted in Little Seoul every morning.' }, { icon: 'wifi', title: 'Free Wi-Fi', text: 'OPS Network fibre, 900 Mbps.' }, { icon: 'clock', title: 'Open late', text: 'Until midnight, every day.' }] },
            { t: 'quote', text: 'Best flat white in the city.', by: 'Lamar D.' },
            { t: 'hours', heading: 'Opening hours', items: [{ day: 'Mon – Fri', time: '6am – midnight' }, { day: 'Sat – Sun', time: '8am – midnight' }] },
            { t: 'cta', title: 'Thirsty?', text: 'Order ahead and skip the queue.', button: 'Contact us', href: '/contact' }] },
            { slug: 'menu', title: 'Menu', blocks: [{ t: 'list', heading: 'Coffee', items: [{ name: 'Espresso', price: '$3', text: 'Double shot' }, { name: 'Flat white', price: '$4.50', text: '' }, { name: 'Iced latte', price: '$5', text: 'Oat milk +50c' }] }] },
            { slug: 'contact', title: 'Contact', blocks: [{ t: 'contact', heading: 'Get in touch', text: 'Questions, catering, jobs — drop us a line.', form: true }] }] };
    const webDom = { id: 4, name: 'beanmachine.ls', tld: 'ls', status: 'active', auto: true, privacy: true, locked: true, created: now / 1000 - 86400 * 9, expires: now / 1000 + 86400 * 21, owner: 'John Doe', price: 30,
        records: [{ id: 1, host: '@', type: 'A', value: '198.18.10.80', prio: 0, ttl: 3600 }, { id: 2, host: 'www', type: 'CNAME', value: '@', prio: 0, ttl: 3600 }, { id: 3, host: '@', type: 'MX', value: 'mx.opsweb.sa', prio: 10, ttl: 3600 }, { id: 4, host: '@', type: 'TXT', value: 'v=spf1 include:opsweb.sa ~all', prio: 0, ttl: 3600 }],
        mx: 'mx.opsweb.sa', cert: { issuer: 'OPS Trust CA', subject: 'beanmachine.ls', kind: 'dv', expires: now / 1000 + 86400 * 25, status: 'valid' } };
    const webCat = { tlds: [{ tld: 'ls', price: 30, desc: 'Los Santos — the city’s own' }, { tld: 'sa', price: 45, desc: 'San Andreas, state-wide' }, { tld: 'biz', price: 35, desc: 'For businesses' }, { tld: 'shop', price: 30, desc: 'Stores and online shops' }, { tld: 'club', price: 20, desc: 'Clubs, crews and communities' }, { tld: 'gov.sa', price: 0, desc: 'Government only', restricted: ['government'] }],
        plans: [{ code: 'starter', name: 'Starter', price: 20, sites: 1, mailboxes: 3, ssl: 'dv' }, { code: 'business', name: 'Business', price: 45, sites: 5, mailboxes: 15, ssl: 'dv' }, { code: 'pro', name: 'Pro', price: 90, sites: 20, mailboxes: 60, ssl: 'ov' }],
        services: [{ code: 'web_build', price: 600, desc: 'An OPS Web designer builds and publishes your site' }, { code: 'web_ssl', price: 80, desc: 'We install and configure SSL for you' }, { code: 'web_mail', price: 60, desc: 'We set up email on your domain' }] };
    const cloudCat = { plans: [{ code: 'nano', name: 'Nano', vcpu: 1, ram: 2, disk: 25, price: 12 }, { code: 'small', name: 'Small', vcpu: 2, ram: 4, disk: 60, price: 24 }, { code: 'medium', name: 'Medium', vcpu: 4, ram: 8, disk: 120, price: 48 }, { code: 'large', name: 'Large', vcpu: 8, ram: 32, disk: 320, price: 110 }],
        images: [{ code: 'opsweb', name: 'OPS Web server (nginx)' }, { code: 'ubuntu', name: 'Ubuntu 24.04 LTS' }, { code: 'windows', name: 'Windows Server 2025', extra: 20 }] };
    const vmA = { id: 7, name: 'web-1', plan: 'small', vcpu: 2, ram: 4, disk: 60, image: 'opsweb', imageName: 'OPS Web server (nginx)', region: 'LS-1', ip: '198.18.20.10', desired: 'running', state: 'running', status: 'active', price: 24, next: now / 1000 + 86400 * 20, booted: now / 1000 - 7200, firewall: [22, 80, 443], host: 'rack 12 · U33' };
    const webInternal = (host, path) => {
        const base = { kind: 'internal', host, url: 'https://' + host + (path === '/' ? '' : path), secure: true, cert: { issuer: 'OPS Trust CA', subject: host, kind: 'ev', org: 'OPS Group', status: 'valid' } };
        if (host === 'ops.sa') return Object.assign(base, { data: { app: 'search', host, path, popular: [{ title: 'Bean Machine', description: 'Coffee in Little Seoul', domain: 'beanmachine.ls', host: '@' }, { title: 'LS Customs', description: 'Tuning and repairs', domain: 'lscustoms.biz', host: '@' }] } });
        if (host === 'opsdomains.sa') return Object.assign(base, { data: Object.assign({ app: 'domains', host, path }, webCat) });
        if (host === 'opsweb.sa') return Object.assign(base, { data: Object.assign({ app: 'web', host, path }, webCat) });
        if (host === 'opscloud.sa') return Object.assign(base, { data: { app: 'cloud', host, path, plans: cloudCat.plans, images: cloudCat.images, capacity: { 'LS-1': { hosts: 3, vcpu: 384, ram: 1536, usedVcpu: 40, usedRam: 120, waiting: false } } } });
        if (host === 'opsdata.sa') return Object.assign(base, { data: { app: 'company', host, path, company: { code: 'data', name: 'OPS Data', tagline: 'Data-centre services', color: '#5e5ce6', icon: 'server', completed: 41, staff: 4,
            services: [{ title: 'Server fault', desc: 'A server in the data hall has failed.', price: 0 }], halls: [{ id: 1, region: 'LS-1', racks: 2, temp: 24.5, load: 7.2, cooling: 30, servers: 18, down: 1, power: 'ups', charge: 100 }],
            platform: { opsweb: { up: 2, total: 2 }, dns: { up: 1, total: 2 }, mail: { up: 0, total: 0 } } } } });
        return Object.assign(base, { data: { app: 'company', host, path, company: { code: 'network', name: 'OPS Network', tagline: 'Internet service provider', color: '#0a84ff', icon: 'network-wired', completed: 182, staff: 9,
            services: [{ title: 'Router installation', desc: 'Fit and set up a new router / gateway.', price: 750 }, { title: 'Internet outage', desc: 'Customer has no internet — emergency.', price: 0 }],
            outages: [{ ref: 'INC-00004', title: 'Fibre fault · Paleto Bay', area: 'Paleto Bay', status: 'investigating', planned: 0 }],
            packages: [{ name: 'Fibre 500', segment: 'residential', down_mbps: 500, up_mbps: 75, price: 45 }, { name: 'Business 1G', segment: 'business', down_mbps: 1000, up_mbps: 200, price: 120 }] } } });
    };
    const rpcs = {
        webBrowse: (d) => {
            const m = String(d.url).match(/^(?:(https?):\/\/)?([^/?#]+)([^?#]*)/i) || [];
            const host = (m[2] || '').toLowerCase().replace(/^www\./, ''), path = (m[3] || '/').replace(/\/+$/, '') || '/';
            if (host === 'opsacademy.sa') return { kind: 'internal', host, url: 'https://' + host + (path === '/' ? '' : path), secure: true, cert: { issuer: 'OPS Trust CA', subject: host, kind: 'ev', org: 'OPS Group', status: 'valid' }, data: { app: 'academy', host, path } };
            if (['ops.sa', 'opsdomains.sa', 'opsweb.sa', 'opsnetwork.sa', 'opscloud.sa', 'opsdata.sa'].includes(host)) return webInternal(host, path);
            if (host === 'beanmachine.ls') { const pg = webSite.pages.find((p) => '/' + p.slug === path || (path === '/' && p.slug === ''));
                return { kind: 'site', url: 'https://beanmachine.ls' + (path === '/' ? '' : path), host, ip: '198.18.10.80', secure: true, hosted: 'OPS Web', cert: webDom.cert,
                    site: { id: 1, title: 'Bean Machine', theme: webSite.theme, contact: webSite.contact, nav: webSite.pages.map((p) => ({ slug: p.slug, title: p.title })) }, page: pg, notFound: !pg }; }
            if (host === 'expired.ls') return { kind: 'parked', reason: 'expired', host, domain: host, secure: false };
            if (host === 'parked.ls') return { kind: 'parked', reason: 'parked', host, domain: host, secure: false };
            if (host === 'myserver.biz') return { kind: 'parked', reason: 'default_server', host, ip: '198.51.100.10', secure: false };
            if (host === 'old.shop' && !d.proceed) return { kind: 'interstitial', host, url: 'https://old.shop', code: 'NET::ERR_CERT_DATE_INVALID', cert: { subject: 'old.shop', expires: now / 1000 - 86400 * 4, status: 'expired' } };
            if (host === 'down.biz') return { kind: 'error', code: 'ERR_CONNECTION_TIMED_OUT', title: 'This site can’t be reached', text: 'down.biz took too long to respond.', hint: 'The server may be offline, or its internet connection is down.', host };
            return { kind: 'error', code: 'DNS_PROBE_FINISHED_NXDOMAIN', title: 'This site can’t be reached', text: host + '’s server IP address could not be found.', hint: 'Check the address for typos, or search for it instead.', host };
        },
        webSearch: (d) => ({ total: 3, results: [{ url: 'https://beanmachine.ls', title: 'Bean Machine', snippet: 'Fresh coffee, all day, every day in Los Santos.', secure: true, color: '#7a4b2a' },
            { url: 'https://opsweb.sa', title: 'OPS Web — websites, hosting and business email', snippet: 'Website builder, hosting, email.', secure: true },
            { url: 'http://lscustoms.biz', title: 'LS Customs', snippet: 'Tuning, respray and repairs near the airport — ' + d.q, secure: false }] }),
        webForm: () => ({ ok: true }),
        webCloud: (d) => {
            if (d.action === 'mine') return { vms: [vmA, Object.assign({}, vmA, { id: 8, name: 'db-1', ip: '198.18.20.11', image: 'ubuntu', imageName: 'Ubuntu 24.04 LTS', state: 'host_down', firewall: [22] })], work: [], plans: cloudCat.plans, images: cloudCat.images,
                capacity: { 'LS-1': { hosts: 3, vcpu: 384, ram: 1536, usedVcpu: 40, usedRam: 120 } } };
            if (d.action === 'get') return { vm: Object.assign({}, vmA, { log: ['2026-10-04 11:02:10  Ordered: Small · OPS Web server (nginx) · LS-1', '2026-10-04 11:02:25  Booting on Rack A1 U33', '2026-10-04 11:02:25  nginx 1.27 started', '2026-10-04 11:02:25  OPS Web agent connected — ready to host your site'],
                snapshots: [{ id: 1, name: 'before-launch', size_gb: 14, created_at: now / 1000 - 3600 }], sites: [{ id: 1, title: 'Bean Machine', host: '@', domain: 'beanmachine.ls', published: 1 }] }) };
            return { ok: true, id: 7, ip: '198.18.20.12', ref: 'CLO-00003', price: 150 };
        },
        mailFrom: () => ['john.doe@opslabs.cloud', 'hello@beanmachine.ls'],
        webDomains: (d) => {
            if (d.action === 'check') return { label: d.name, list: webCat.tlds.map((t, i) => ({ name: d.name + '.' + t.tld, tld: t.tld, price: t.price, desc: t.desc, available: i !== 1 && !t.restricted, taken: i === 1, restricted: t.restricted })) };
            if (d.action === 'whois') return { name: d.name, registered: true, registrar: 'OPS Domains', registrant: 'REDACTED FOR PRIVACY', status: 'active', created: now / 1000 - 86400 * 30, expires: now / 1000 + 86400 * 20, locked: true, nameservers: ['ns1.opsdomains.sa', 'ns2.opsdomains.sa'] };
            if (d.action === 'mine') return { domains: [webDom, Object.assign({}, webDom, { id: 5, name: 'johnstuning.biz', status: 'expired', auto: false })], work: [] };
            if (d.action === 'get') return { domain: webDom };
            return { ok: true, id: 4, name: d.name, code: 'A1B2C3D4' };
        },
        webHost: (d) => {
            if (d.action === 'mine') return { hosting: [{ id: 1, plan: 'business', name: 'Business', price: 45, status: 'active', next: now / 1000 + 86400 * 12, sites: 2, maxSites: 5, ssl: 'dv' }],
                sites: [{ id: 1, title: 'Bean Machine', host: 'beanmachine.ls', url: 'https://beanmachine.ls', published: true, live: true, status: 'ok', views: 431 }, { id: 2, title: 'John’s Tuning', host: null, published: false, status: 'ok', selfIp: '198.51.100.10' }],
                domains: [webDom], mailboxes: [{ id: 1, address: 'hello@beanmachine.ls', deliver_to: '555-2024', catch_all: 0 }], ips: [{ ip: '198.51.100.10', ref: 'LINE-00001' }], work: [],
                limits: { sites: 5, mailboxes: 15, ssl: 'dv' }, plans: webCat.plans, services: webCat.services, number: '555-2024' };
            if (d.action === 'site_get') return { site: { id: 1, title: 'Bean Machine', description: 'Coffee in Little Seoul', keywords: 'coffee, cafe', published: true, status: 'ok', views: 431, host: 'beanmachine.ls', url: 'https://beanmachine.ls', domainId: 4, sub: '@', live: true,
                cert: webDom.cert, data: JSON.parse(JSON.stringify(webSite)), domains: [{ id: 4, name: 'beanmachine.ls' }] } };
            return { ok: true, id: 1, ref: 'WEB-00012', price: 600, name: 'beanmachine.ls', url: 'https://beanmachine.ls', address: 'info@beanmachine.ls' };
        },
        opsMe: () => ({ me: { id: 1, username: 'admin', name: 'Ben Jja', super: true, companies: [{ id: 1, code: 'network', name: 'OPS Network', tagline: 'Internet service provider', color: '#0a84ff', icon: 'network-wired', role: 'Super Admin', balance: 25400, perms: ['jobs.view', 'jobs.take', 'jobs.dispatch', 'finance.view', 'employees.view', 'employees.manage', 'company.manage'] },
            { id: 2, code: 'secure', name: 'OPS Secure', tagline: 'CCTV & security', color: '#ff375f', icon: 'video', role: 'CCTV Engineer', perms: ['jobs.view', 'jobs.take'] }], others: [{ id: 3, code: 'web', name: 'OPS Web', tagline: 'Websites & hosting', color: '#ff9f0a', icon: 'code' }] } }),
        opsTraining: () => ({ passMark: 75, centres: [{ label: 'OPS Academy · LSIA', x: -1324, y: -3036 }], certs: [{ code: 'cctv_install', name: 'CCTV installer', company: 'OPS Secure', color: '#ff375f', icon: 'video', mine: true, needPractical: true, questions: 10, cert: { valid: true, expires: now / 1000 + 86400 * 50 }, exam: { state: 'done', score: 90 }, practical: { state: 'done', score: 100 }, families: [{ code: 'cctv_install', name: 'CCTV camera installation', jobs: 8, required: true, lesson: { state: 'done' }, safety: { state: 'done', score: 100, expires: now / 1000 + 86400 * 50 } }, { code: 'cctv_recorders', name: 'CCTV recorders, recording & remote viewing', jobs: 4, required: true, lesson: { state: 'none' }, safety: { state: 'none' } }, { code: 'cctv_maint', name: 'CCTV maintenance, faults & removal', jobs: 4, required: false, lesson: { state: 'none' }, safety: { state: 'none' } }] },{ code: 'network_install', name: 'Network installation', company: 'OPS Network', color: '#0a84ff', icon: 'network-wired', mine: true, needPractical: true, questions: 10, exam: { state: 'none' }, practical: { state: 'none' }, families: [{ code: 'net_router', name: 'Router installation & replacement', jobs: 2, required: true, lesson: { state: 'none' }, safety: { state: 'none' } }, { code: 'net_lan', name: 'LAN, Wi-Fi & PoE installation', jobs: 5, required: true, lesson: { state: 'none' }, safety: { state: 'none' } }] },{ code: 'dc_ops', name: 'Data centre operations', company: 'OPS Data', color: '#5e5ce6', icon: 'server', mine: false, needPractical: true, questions: 5, exam: { state: 'none' }, practical: { state: 'none' }, families: [{ code: 'dc', name: 'Data centre operations', jobs: 5, required: true, lesson: { state: 'none' }, safety: { state: 'none' } }] }] }),
        opsAcademy: () => Object.assign(rpcs.opsTraining(), { signedIn: !!window.MOCK_ACADEMY_IN, name: 'Pierre D.', courses: rpcs.opsTraining().certs.map((c) => window.MOCK_ACADEMY_IN ? c : Object.assign({}, c, { mine: false, cert: null, exam: null, practical: null, families: c.families.map((f) => Object.assign({}, f, { lesson: null, safety: null })) })), systems: [{"code": "mobile_network", "name": "OPS Mobile network", "icon": "tower-cell", "intro": "Every phone call, text and bit of mobile data goes through OPS Mobile's masts. Each tower covers a radius; phones show bars based on the strongest tower in range. With Enforce on, no signal means no calls, texts or data."}, {"code": "power_grid", "name": "Electricity: San Andreas Power & Light", "icon": "bolt", "intro": "Power stations feed 400 kV transmission to substations, which step it down to 11 kV feeders, then pole transformers to LV, and a service drop to each property's cut-out and meter. The consumer unit then feeds sockets, lights and chargers."}, {"code": "fibre_copper", "name": "Fibre & copper network (OPS Openline)", "icon": "circle-nodes", "intro": "Exchanges house the OLT (fibre light source), the MDF (copper), core routers and power plant (rectifiers, batteries, generator)."}, {"code": "isp", "name": "OPS Network ISP", "icon": "wifi", "intro": "A line is a customer, a package and an ONT. Ordering raises an install job; completing it activates the line: ONT linked, public IPs assigned, router settings pushed, first bill taken."}, {"code": "cctv", "name": "OPS Secure CCTV", "icon": "video", "intro": "A system is a recorder (NVR or DVR) and its cameras. IP cameras use PoE over CAT6; analogue cameras need a DVR; wireless cameras need Wi-Fi and a powered NVR on site."}, {"code": "datacentre_cloud", "name": "OPS Data centres & OPS Cloud", "icon": "server", "intro": "Racks, UPS, generators and CRAC cooling within 25 m form a hall. Racks need power (UPS or socket), a ToR switch and a CAT6 uplink to an online router."}, {"code": "web_domains", "name": "The in-game internet: domains, websites, DNS, email & SSL", "icon": "globe", "intro": "A real web for the city, on phones (mobile data) and laptops (Ethernet). ops.sa is OPS Search."}, {"code": "track", "name": "OPS Track", "icon": "location-crosshairs", "intro": "GPS trackers fitted in vehicles: live position, theft alerts and an immobiliser on Pro units."}, {"code": "fuel", "name": "OPS Fuel", "icon": "gas-pump", "intro": "Underground or bunded tanks, automatic tank gauges, dispensers, a canopy, an emergency stop, a tanker fill point and vent stacks."}, {"code": "solar", "name": "San Andreas Solar", "icon": "solar-panel", "intro": "Panels → DC isolator → hybrid inverter → consumer unit, with a home battery beside the inverter."}, {"code": "jobs_business", "name": "Jobs, money & the business layer", "icon": "briefcase", "intro": "Open → accepted (a snapshot of the world is taken) → the work is done for real → checked against the world → the customer pays → the company is credited → you're paid wages → an invoice is issued."}, {"code": "training_safety", "name": "Training, certification, safety & the job assistant", "icon": "graduation-cap", "intro": "Each job family has a course: classroom lessons, a safety module, an exam and (if enabled) an in-game practical at the OPS Academy. Installation work needs the family's certification to be accepted."}], slideshows: [{"code": "config", "name": "Configuring OPS", "desc": "Every way to change how the OPS systems work — files, OPS Hub and the phone — and what each setting group does.", "icon": "sliders", "count": 11}, {"code": "firstjob", "name": "Your first OPS job", "desc": "From signing in to getting paid — what an engineer does, step by step.", "icon": "person-digging", "count": 7}], training: true }),
        opsSystem: () => ({"system": {"code": "cctv", "name": "OPS Secure CCTV", "company": "secure", "icon": "video", "sections": [{"title": "Systems", "body": "A system is a recorder (NVR or DVR) and its cameras. IP cameras use PoE over CAT6; analogue cameras need a DVR; wireless cameras need Wi-Fi and a powered NVR on site."}, {"title": "Power & budgets", "body": "The NVR has 8 PoE ports and a 120 W budget; PoE switches add more. A camera without power, a channel or a path stays offline."}, {"title": "Recording & events", "body": "Motion, heat, ANPR plate reads and doorbell rings are recorded as events. Recording modes are motion, continuous or off."}, {"title": "Who can watch", "body": "The owner, people they share with, members of an organisation job (e.g. police) and staff. Remote viewing needs the NVR online and remote viewing on."}, {"title": "Faults", "body": "Lens, cable and dead faults raise OPS Secure jobs. OPS Hub → CCTV systems shows everything live."}]}, "families": [{"code": "cctv_install", "name": "CCTV camera installation"}, {"code": "cctv_recorders", "name": "CCTV recorders, recording & remote viewing"}]}),
        opsSlides: () => ({"show": {"name": "Configuring OPS", "desc": "Every way to change how the OPS systems work — files, OPS Hub and the phone — and what each setting group does.", "icon": "sliders", "slides": [{"title": "Three ways to configure everything", "icon": "sliders", "body": ["The config files: opslabs-towers/config.lua, opslabs-phone/config.lua, opslabs-phone/sql/ops_catalog.json and sql/ops_guides.json.", "OPS Hub → Settings, Jobs, Companies: every value, with its explanation, saved in the database.", "OPS Work → Admin settings on the phone: the most-used switches, every job and every company.", "What wins: a value set on OPS Hub or the phone overrides the file. \"Reset\" puts it back to the file’s value."]}, {"title": "What lives where", "icon": "folder-tree", "body": ["opslabs-towers/config.lua — mobile masts and Wi-Fi, cabling, mains electricity, the power grid, solar, fuel, OPS Track, the ISP, CCTV, data centres, gunshot sensors, faults, buildings, roadworks, lighting, vans.", "opslabs-phone/config.lua — the phone itself, OPS Mobile plans, the OPS platform (automatic jobs), Features (web, cloud, business, training, assistant) and Work (play mode, depots, safety, training, animations).", "sql/ops_catalog.json — companies, roles and permissions, job types, customer places, ISP pools, domain/hosting/cloud prices, stock lines, suppliers, contracts and SLA tiers.", "sql/ops_guides.json — the training and job-assistant content: steps, tools, safety, mistakes, quizzes, exams and the classroom explainers.", "config_server.lua — secrets (API keys, logins). Never shown on OPS Hub."]}, {"title": "OPS Hub → Settings", "icon": "toggle-on", "body": ["Quick settings: play mode, every system on/off, automatic jobs and the safety & training rules.", "The two full editors list every setting of opslabs-towers and opslabs-phone as a tree. Search by name or by what it does — each one shows the comment from the config file.", "Changes are saved straight away and applied in game within about 15 seconds. A few values are read when a script starts (for example turning a whole system on or off) — those apply on the next restart.", "Every change is in the Platform audit log with who made it."]}, {"title": "Jobs editor", "icon": "briefcase", "body": ["Switch any job type on or off, change the customer price and the engineer’s wage, decide whether it appears on its own, if it can be an emergency, the certification it needs, whether warranty/contracts make it free.", "Parts: which stock items the job uses up (e.g. {\"cat6\": 20, \"rj45\": 2}).", "The check (advanced): how the game proves the work was done — time on site, kit fitted, cable laid, ONT online, dial tone, live supply, cameras online, speed test, router settings, websites, data centre…", "Create your own job types for any company: they appear in OPS Work within 30 seconds."]}, {"title": "Companies editor", "icon": "building", "body": ["Edit any company’s name, tagline, colour, icon, VAT and wage share.", "Switch a company off: it disappears from OPS Work, gets no jobs and can’t be booked — handy if your server doesn’t want OPS Fuel or solar.", "Create new companies, then give them job types in the Jobs editor and roles in Roles & permissions."]}, {"title": "Prices & catalogue", "icon": "tags", "body": ["Settings → Prices & catalogue edits whole catalogue sections as JSON: domain endings and prices, hosting and cloud plans, certificate prices, stock lines and suppliers, SLA tiers and contract types, roles, the customer places that get automatic jobs.", "OPS Hub uses them at once. The game writes them into sql/ops_catalog.json on start — restart opslabs-phone and opslabs-towers to use them."]}, {"title": "Play modes: standalone or items", "icon": "boxes-stacked", "body": ["Standalone (default): no inventory items needed. Tools are assumed to be in the van; kit is placed from /towers.", "Items: tools, PPE and parts are inventory items. Engineers collect them at an OPS depot (Work.Depots) for the jobs they’ve accepted; jobs need their tools to start and use up their parts; placing kit from /towers uses its item (Work.ModelItems).", "Add the items to your inventory first: opslabs-phone/items/ has ready-made definitions for ox_inventory, ESX and QBCore."]}, {"title": "Training & certification settings", "icon": "graduation-cap", "body": ["Features.Training switches the whole training system on/off.", "Work.RequireSafetyTraining: the family’s safety module before taking its jobs. Work.RequirePractical: an in-game practical at an OPS Academy centre (Work.TrainingCentres) as part of each certification. Work.PassMark: the pass mark for quizzes and exams.", "Per job: the Jobs editor decides which certification a job needs and whether it’s required.", "Content (lessons, steps, quizzes) is in sql/ops_guides.json — edit it to change what’s taught."]}, {"title": "Health & safety settings", "icon": "helmet-safety", "body": ["Work.SafetyBriefing: a dynamic risk assessment before on-site work and before completing a job.", "Work.SafetyIncidents: skip controls on risky work and accidents can happen (falls, shocks) — logged as safety incidents and alerted to managers.", "Work.Anims: the animation used for each step type (dict/clip or scenario)."]}, {"title": "Switching systems off", "icon": "power-off", "body": ["Each big system has an Enabled switch: Mains, Grid, OpsIsp, Cctv, DataCentre, Track, Fuel, Gunshot, Faults (opslabs-towers) and Features.* plus Carrier.Enabled (opslabs-phone).", "Turning a system off stops its engine on the next restart; its jobs stay available unless you also switch them off in the Jobs editor (or switch the company off).", "Enforce (opslabs-towers) decides whether phones need real tower signal."]}, {"title": "Good habits", "icon": "circle-check", "body": ["Change one thing at a time and watch the game for a minute.", "Use \"Reset\" to go back to the file’s value; the audit log shows every change.", "Keep a copy of your config files before big edits, and test risky changes on a copy of the server."]}]}}),
        opsLesson: () => ({ family: {"code": "cctv_install", "name": "CCTV camera installation", "summary": "Fit IP, PTZ, ANPR, thermal and wireless cameras and get them live on the customer's recorder.", "overview": "An OPS Secure system is a recorder (NVR for IP cameras, DVR for analogue ones) with cameras connected to it. IP cameras take power and data over CAT6 from the NVR's PoE ports (8 ports, 120 W budget) or a PoE switch cabled to the NVR. Wireless cameras and doorbells need a powered NVR on site and Wi-Fi in range. A camera is only 'online' when it has a path, power, a free channel and no fault. Jobs check for cameras online on a recorder near the site.", "equipment": [{"name": "IP cameras (bullet, dome, turret, fisheye)", "what": "Record video over the network, powered by PoE.", "how": "/towers → OPS Secure → 'IP cameras (PoE)'. Cable to the NVR or a PoE switch."}, {"name": "PTZ / ANPR / thermal", "what": "Pan-tilt-zoom with 30× zoom; number-plate reading; heat detection. They draw more PoE.", "how": "/towers → OPS Secure → 'Specialist cameras'."}, {"name": "Wireless camera & video doorbell", "what": "Need a socket (wireless camera) or nothing (doorbell), a powered NVR on site and Wi-Fi in range.", "how": "/towers → OPS Secure → 'Wireless & doorbells'."}, {"name": "PoE switch", "what": "Adds PoE ports when the NVR's are full, up to its own budget.", "how": "Cable the switch to the NVR, and the cameras to the switch."}, {"name": "CAT6", "what": "Data and power to each IP camera.", "how": "'Pull CAT6 from the nearest box', crimp both ends onto camera and NVR/switch."}], "steps": [{"title": "Agree camera positions", "detail": "Walk the site with the customer: entrances, tills, car park. Avoid pointing at neighbours' windows.", "tool": null, "anim": "clipboard", "where": "On site", "secs": 8}, {"title": "Mount the cameras", "detail": "Use the ladder and place each camera from the OPS Secure menu, aimed at the area to cover.", "tool": "ladder", "anim": "reach", "where": "/towers → OPS Secure", "secs": 8}, {"title": "Run CAT6 to each camera", "detail": "Pull CAT6 from the box to each camera and back to the NVR or PoE switch.", "tool": "crimper", "anim": "carry", "where": "From the nearest CAT6 box", "secs": 8}, {"title": "Crimp and terminate", "detail": "Crimp both ends and terminate them onto the camera and the NVR/switch.", "tool": "crimper", "anim": "crimp", "where": "Each camera and the recorder", "secs": 8}, {"title": "Check power & channels", "detail": "[E] at the NVR → system: each camera should say 'ok'. 'No PoE' means the budget is full; 'No channel' means the NVR is full.", "tool": "laptop", "anim": "type", "where": "[E] at the NVR", "secs": 8}, {"title": "Watch and focus", "detail": "Watch each camera from the NVR or monitor and check the view.", "tool": "laptop", "anim": "inspect", "where": "[E] at the NVR → Watch", "secs": 8}, {"title": "Complete", "detail": "Press Check on the job.", "tool": null, "anim": "phone", "where": "OPS Work → the job", "secs": 8}], "safety": [{"hazard": "Working at height", "risk": "A fall from a ladder or pole can cause serious injury.", "control": "Use a ladder at a 1-in-4 angle on firm ground with three points of contact. Above 2 m on a pole, clip on your harness."}, {"hazard": "Privacy", "risk": "Cameras that film neighbours or public areas unfairly break privacy law.", "control": "Point cameras at the customer's own property and put up 'CCTV in operation' signs."}, {"hazard": "Electricity", "risk": "Mains voltage can give a fatal shock and cause burns.", "control": "Never open powered kit. Isolate and prove dead with a voltage tester before touching terminals."}], "mistakes": [{"mistake": "More PoE cameras than the NVR budget", "consequence": "Extra cameras show 'No PoE' and stay offline. Add a PoE switch."}, {"mistake": "Analogue camera cabled to an NVR (or IP to a DVR)", "consequence": "'Wrong recorder' — that camera never comes online."}, {"mistake": "Wireless camera with no Wi-Fi in range", "consequence": "'No Wi-Fi' — it can't reach the recorder."}, {"mistake": "Recorder with no socket within 3 m", "consequence": "The whole system is unpowered: nothing records."}, {"mistake": "Cameras fitted before accepting", "consequence": "They don't count — the check needs cameras added after acceptance."}], "tools": [{"id": "ladder", "name": "Ladder", "what": "Reaches walls, ceilings and pole steps. Place it at a 1-in-4 angle on firm ground."}, {"id": "drill", "name": "Cordless drill & fixings", "what": "Drills walls for cable entry and fixes brackets, cameras and boxes with the right plugs and screws."}, {"id": "crimper", "name": "RJ45 crimper & cable tester", "what": "Fits RJ45 plugs onto CAT6 and proves all eight cores are connected in the right order."}, {"id": "laptop", "name": "Engineer laptop & console cable", "what": "Configures routers, NVRs and servers, runs speed tests and opens OPS Hub."}], "ppe": [{"id": "hivis", "name": "Hi-vis vest & hard hat", "what": "Makes you visible to traffic and protects your head from falling objects and low beams."}, {"id": "harness", "name": "Fall-arrest harness", "what": "Clipped to a pole or anchor point, it stops a fall when you work above 2 m."}, {"id": "glasses", "name": "Safety glasses", "what": "Protect your eyes from fibre shards, drilling dust and laser light."}]} }),
        opsSafetyQuiz: () => ({ name: 'CCTV camera installation', hazards: [{"hazard": "Working at height", "risk": "A fall from a ladder or pole can cause serious injury.", "control": "Use a ladder at a 1-in-4 angle on firm ground with three points of contact. Above 2 m on a pole, clip on your harness."}, {"hazard": "Privacy", "risk": "Cameras that film neighbours or public areas unfairly break privacy law.", "control": "Point cameras at the customer's own property and put up 'CCTV in operation' signs."}, {"hazard": "Electricity", "risk": "Mains voltage can give a fatal shock and cause burns.", "control": "Never open powered kit. Isolate and prove dead with a voltage tester before touching terminals."}], questions: [{"q": "Where should cameras point?", "a": ["At the customer's own property", "Into neighbours' windows", "At the sky"]}, {"q": "Working above 2 m on a wall you need…", "a": ["Nothing", "A chair", "A ladder set properly, or a harness on a pole"]}, {"q": "Signs saying CCTV is in use are…", "a": ["Banned", "Required", "Optional decoration"]}] }),
        opsGuide: () => ({"mine": true, "family": {"code": "cctv_install", "name": "CCTV camera installation", "summary": "Fit IP, PTZ, ANPR, thermal and wireless cameras and get them live on the customer's recorder."}, "steps": [{"title": "Agree camera positions", "detail": "Walk the site with the customer: entrances, tills, car park. Avoid pointing at neighbours' windows.", "tool": null, "anim": "clipboard", "where": "On site", "secs": 8}, {"title": "Mount the cameras", "detail": "Use the ladder and place each camera from the OPS Secure menu, aimed at the area to cover.", "tool": "ladder", "anim": "reach", "where": "/towers → OPS Secure", "secs": 8}, {"title": "Run CAT6 to each camera", "detail": "Pull CAT6 from the box to each camera and back to the NVR or PoE switch.", "tool": "crimper", "anim": "carry", "where": "From the nearest CAT6 box", "secs": 8}, {"title": "Crimp and terminate", "detail": "Crimp both ends and terminate them onto the camera and the NVR/switch.", "tool": "crimper", "anim": "crimp", "where": "Each camera and the recorder", "secs": 8}, {"title": "Check power & channels", "detail": "[E] at the NVR → system: each camera should say 'ok'. 'No PoE' means the budget is full; 'No channel' means the NVR is full.", "tool": "laptop", "anim": "type", "where": "[E] at the NVR", "secs": 8}, {"title": "Watch and focus", "detail": "Watch each camera from the NVR or monitor and check the view.", "tool": "laptop", "anim": "inspect", "where": "[E] at the NVR → Watch", "secs": 8}, {"title": "Complete", "detail": "Press Check on the job.", "tool": null, "anim": "phone", "where": "OPS Work → the job", "secs": 8}], "current": 3, "check": {"ok": false, "have": 1, "need": 2, "label": "Cameras online on a recorder", "detail": "1 camera says No PoE"}, "tools": [{"id": "ladder", "name": "Ladder", "what": "Reaches walls, ceilings and pole steps. Place it at a 1-in-4 angle on firm ground.", "missing": false}, {"id": "drill", "name": "Cordless drill & fixings", "what": "Drills walls for cable entry and fixes brackets, cameras and boxes with the right plugs and screws.", "missing": false}, {"id": "crimper", "name": "RJ45 crimper & cable tester", "what": "Fits RJ45 plugs onto CAT6 and proves all eight cores are connected in the right order.", "missing": true}, {"id": "laptop", "name": "Engineer laptop & console cable", "what": "Configures routers, NVRs and servers, runs speed tests and opens OPS Hub.", "missing": false}], "ppe": [{"id": "hivis", "name": "Hi-vis vest & hard hat", "have": true}, {"id": "harness", "name": "Fall-arrest harness", "have": true}, {"id": "glasses", "name": "Safety glasses", "have": true}], "missingParts": [{"sku": "cat6", "qty": 40}], "safety": [{"hazard": "Working at height", "risk": "A fall from a ladder or pole can cause serious injury.", "control": "Use a ladder at a 1-in-4 angle on firm ground with three points of contact. Above 2 m on a pole, clip on your harness."}, {"hazard": "Privacy", "risk": "Cameras that film neighbours or public areas unfairly break privacy law.", "control": "Point cameras at the customer's own property and put up 'CCTV in operation' signs."}, {"hazard": "Electricity", "risk": "Mains voltage can give a fatal shock and cause burns.", "control": "Never open powered kit. Isolate and prove dead with a voltage tester before touching terminals."}], "mistakes": [{"mistake": "More PoE cameras than the NVR budget", "consequence": "Extra cameras show 'No PoE' and stay offline. Add a PoE switch."}, {"mistake": "Analogue camera cabled to an NVR (or IP to a DVR)", "consequence": "'Wrong recorder' — that camera never comes online."}, {"mistake": "Wireless camera with no Wi-Fi in range", "consequence": "'No Wi-Fi' — it can't reach the recorder."}, {"mistake": "Recorder with no socket within 3 m", "consequence": "The whole system is unpowered: nothing records."}, {"mistake": "Cameras fitted before accepting", "consequence": "They don't count — the check needs cameras added after acceptance."}], "ra": null, "needRA": true, "mode": "items", "depot": {"label": "OPS Depot · LSIA", "x": -1318, "y": -3027, "dist": 842}, "cert": {"code": "cctv_install", "name": "CCTV installer", "required": true, "have": true}, "safetyDone": true, "job": {"id": 14, "ref": "SEC-00014", "title": "Install CCTV cameras"}}),
        opsRiskAssess: () => ({ ok: true, skipped: [] }),
        opsAdminState: () => ({ groups: [{ title: 'Play mode', items: [{ res: 'opslabs-phone', path: 'Work.Mode', label: 'How jobs are worked', kind: 'select', opts: ['standalone', 'items'], value: 'standalone' }] }, { title: 'OPS systems', items: [{ res: 'opslabs-phone', path: 'Features.Web', label: 'In-game internet', kind: 'bool', value: true }, { res: 'opslabs-towers', path: 'Cctv.Enabled', label: 'OPS Secure CCTV', kind: 'bool', value: true, over: true }, { res: 'opslabs-towers', path: 'Fuel.Enabled', label: 'OPS Fuel', kind: 'bool', value: false, over: true }] }, { title: 'Jobs & safety', items: [{ res: 'opslabs-phone', path: 'Platform.JobEvery', label: 'Seconds between new-job checks', kind: 'number', value: 240 }, { res: 'opslabs-phone', path: 'Work.SafetyBriefing', label: 'Risk assessment before work', kind: 'bool', value: true }] }] }),
        opsAdminJobs: () => ({ jobs: [{ code: 'cctv_install', title: 'Install CCTV cameras', company: 'OPS Secure', enabled: true, auto: true, price: 1600, wage: 550 }, { code: 'cctv_fault', title: 'CCTV fault finding', company: 'OPS Secure', enabled: false, auto: true, price: 0, wage: 250 }, { code: 'net_router', title: 'Router installation', company: 'OPS Network', enabled: true, auto: true, price: 750, wage: 350 }] }),
        opsAdminCompanies: () => ({ companies: [{ id: 1, name: 'OPS Network', tagline: 'Internet service provider', color: '#0a84ff', icon: 'network-wired', active: 1 }, { id: 2, name: 'OPS Fuel', tagline: 'Fuel stations', color: '#e2202a', icon: 'gas-pump', active: 0 }] }),
        opsCourse: () => ({ code: 'network_install', name: 'Network installation', pass: 75, questions: [{ q: 'The maximum length of a CAT6 run is about…', a: ['10 m', '100 m', '1 km'] }, { q: 'PoE lets a switch…', a: ['Boost the internet speed', 'Power devices over the network cable', 'Encrypt Wi-Fi'] }] }),
        opsExam: () => ({ ok: true, score: 100, right: 2, total: 2 }),
        opsMyKit: () => ({ vehicles: [{ id: 1, plate: 'OPS 1', label: 'Vapid Speedo van', model: 'speedo', company: 'OPS Secure', color: '#ff375f', mileage: 412, service_due_at: now / 1000 + 86400 * 12, status: 'available' }],
            tools: [{ kind: 'Cable crimper & tester', serial: 'T3A9F21', company: 'OPS Secure', condition: 'good', calibration_due: now / 1000 + 86400 * 50 }, { kind: 'Ladder', serial: 'T77B0C1', company: 'OPS Secure', condition: 'worn' }] }),
        opsMyQuotes: () => ({ now: now / 1000, quotes: [{ id: 1, number: 'SEC-Q00002', title: 'CCTV for the shop', company: 'OPS Secure', color: '#ff375f', icon: 'video', status: 'sent', valid_until: now / 1000 + 86400 * 5, total: 2496.4,
                items: [{ description: 'Install CCTV cameras', qty: 1, unit: 1333.33 }, { description: 'NVR 16ch PoE', qty: 1, unit: 672 }, { description: 'Support & repairs contract · Premium SLA', qty: 1, unit: 75, contract: 'support' }] }],
            contracts: [{ title: 'Support · Fleeca Bank', company: 'OPS Secure', color: '#ff375f', sla: 'premium', response_hours: 8, fee: 90, status: 'active' }],
            assets: [{ name: 'IP camera (bullet/dome)', serial: 'CAM-IP-3F2A1B', company: 'OPS Secure', warranty_until: now / 1000 + 86400 * 28 }, { name: 'Fibre ONT', serial: 'ONT-0A71C2', company: 'OPS Network', warranty_until: now / 1000 - 3600 }] }),
        opsMyTickets: () => ({ tickets: [{ id: 3, ref: 'TSEC-00003', subject: 'Camera 2 blurry', company: 'OPS Secure', color: '#ff375f', icon: 'video', status: 'pending', messages: [{ from: 'Biz Owner', text: 'Since the rain', at: now / 1000 - 3600 }, { from: 'Dispatch (OPS Secure)', text: 'An engineer is booked for this afternoon.', at: now / 1000 - 600, staff: true }] }] }),
        opsJobs: (d) => ({ jobs: d.filter === 'mine' ? owJobs.filter((j) => j.mine) : owJobs }),
        opsJob: (d) => ({ job: Object.assign({ canTake: true }, owJobs.find((j) => j.id === d.id)) }),
        opsCompany: () => ({ company: { balance: 25400 }, perms: ['jobs.view', 'jobs.take', 'jobs.dispatch', 'finance.view', 'employees.view', 'company.manage'], counts: { open: 7, active: 2, week: 11 }, messages: [{ title: 'Fibre outage in Mirror Park', body: 'Cabinet 4 is down — expect callouts.', author: 'Dispatch', at: 1759550000 }] }),
        init: () => ({
            carrier: window._carrier,
            number: '555-2024', email: 'john.doe@opslabs.cloud', name: 'John Doe', job: 'Mechanic', setupDone: !!window._setupDone || !location.search.includes('setup'), mailDomain: 'opslabs.cloud', numberFormat: '555-XXXX', defaultUnits: { temp: 'F', distance: 'mi', speed: 'mph', weight: 'lb', clock: '12', date: 'MDY', week: 'sun' },
            settings: {}, frameColor: '#9aadf6', badges: { messages: 1, phone: 1, mail: 1 },
            config: {
                wallpapers: [
                    { id: 'ios18', label: 'Bloom', css: 'radial-gradient(120% 80% at 20% 10%, #ff8a5c 0%, transparent 55%), radial-gradient(110% 90% at 90% 30%, #8a5cff 0%, transparent 60%), radial-gradient(120% 100% at 40% 100%, #2b6bff 0%, transparent 60%), #0b0b2a' },
                    { id: 'teal', label: 'Lagoon', css: 'radial-gradient(100% 70% at 80% 0%, #6fe7d2 0%, transparent 60%), radial-gradient(120% 90% at 0% 100%, #1f7a8c 0%, transparent 65%), #062a35' },
                    { id: 'pink', label: 'Blush', css: 'radial-gradient(90% 70% at 10% 0%, #ffc1e3 0%, transparent 60%), radial-gradient(120% 100% at 100% 100%, #ff5fa2 0%, transparent 60%), #3a0f2a' },
                ],
                ringtones: [{ id: 'reflection', label: 'Reflection' }, { id: 'opening', label: 'Opening' }, { id: 'radar', label: 'Radar' }, { id: 'chime', label: 'Chime' }],
                services: [
                    { id: 'police', label: 'Police', number: '911', icon: 'fa-shield-halved', color: '#1c6dd0' },
                    { id: 'ambulance', label: 'EMS', number: '912', icon: 'fa-truck-medical', color: '#e5383b' },
                    { id: 'mechanic', label: 'Mechanic', number: '913', icon: 'fa-wrench', color: '#f08c00' },
                    { id: 'taxi', label: 'Taxi', number: '914', icon: 'fa-taxi', color: '#f5c518' },
                ],
                places: [
                    { name: 'Legion Square', coords: { x: 195, y: -933 }, icon: 'fa-tree' },
                    { name: 'Pillbox Hospital', coords: { x: 298, y: -584 }, icon: 'fa-hospital' },
                    { name: 'Sandy Shores', coords: { x: 1853, y: 3686 }, icon: 'fa-sun' },
                ],
                cameraEnabled: false,
                music: { Apps: { soundwave: { name: 'Soundwave' }, tide: { name: 'Tide' } }, Stations: [
                    { title: 'Groove Salad', artist: 'SomaFM · Ambient / Downtempo', url: 'https://ice1.somafm.com/groovesalad-128-mp3' },
                    { title: 'Beat Blender', artist: 'SomaFM · Deep House', url: 'https://ice1.somafm.com/beatblender-128-mp3' },
                    { title: 'Indie Pop Rocks!', artist: 'SomaFM · Indie Pop', url: 'https://ice1.somafm.com/indiepop-128-mp3' },
                    { title: 'Fluid', artist: 'SomaFM · Instrumental Hip-Hop', url: 'https://ice1.somafm.com/fluid-128-mp3' },
                ] },
            },
        }),
        saveSettings: () => true,
        getContacts: () => db.contacts,
        saveContact: (d) => { if (d.id) { Object.assign(db.contacts.find((c) => c.id === d.id), d); return d.id; } const id = Date.now(); db.contacts.push({ ...d, id, favorite: 0, blocked: 0 }); return id; },
        deleteContact: (d) => { db.contacts = db.contacts.filter((c) => c.id !== d.id); return true; },
        toggleFavorite: (d) => { const c = db.contacts.find((x) => x.id === d.id); c.favorite = c.favorite ? 0 : 1; return true; },
        toggleBlock: () => true,
        getConversations: () => Object.entries(db.messages).map(([number, list]) => {
            const last = list[list.length - 1];
            const c = db.contacts.find((x) => x.number === number);
            return { number, name: c && c.name, last: last.message, attachment: last.attachment ? last.attachment.type : null, time: last.created_at, unread: last.mine ? 0 : 1 };
        }).sort((a, b) => b.time - a.time),
        getMessages: (d) => db.messages[d.number] || [],
        sendMessage: (d) => { (db.messages[d.number] ||= []).push({ id: Date.now(), mine: true, message: d.message, attachment: d.attachment && d.attachment.type === 'location' ? { type: 'location', x: 0, y: 0 } : d.attachment, created_at: Date.now() }); return true; },
        deleteConversation: (d) => { delete db.messages[d.number]; return true; },
        getRecents: () => db.calls,
        clearRecents: () => { db.calls = []; return true; },
        startCall: (d) => {
            setTimeout(() => window.postMessage({ action: 'callAccepted', data: { id: 1, channel: 1 } }, '*'), 2500);
            return { id: 1, contact: { number: d.number } };
        },
        answerCall: () => { setTimeout(() => window.postMessage({ action: 'callAccepted', data: { id: 2 } }, '*'), 50); return true; },
        endCall: (d) => { setTimeout(() => window.postMessage({ action: 'callEnded', data: { id: d.id, status: 'answered' } }, '*'), 50); return true; },
        getNotes: () => db.notes,
        saveNote: (d) => { if (d.id) { Object.assign(db.notes.find((n) => n.id === d.id), d, { updated_at: Date.now() }); return d.id; } const id = Date.now(); db.notes.unshift({ ...d, id, updated_at: Date.now() }); return id; },
        deleteNote: (d) => { db.notes = db.notes.filter((n) => n.id !== d.id); return true; },
        getPhotos: () => db.photos,
        savePhoto: (d) => { db.photos.unshift({ id: Date.now(), url: d.url, favorite: 0, created_at: Date.now() }); return true; },
        deletePhoto: (d) => { db.photos = db.photos.filter((p) => p.id !== d.id); return true; },
        favoritePhoto: (d) => { const p = db.photos.find((x) => x.id === d.id); p.favorite = p.favorite ? 0 : 1; return true; },
        getMail: (d) => (d.box === 'sent' ? [] : db.mail),
        readMail: (d) => { const m = db.mail.find((x) => x.id === d.id); if (m) m.is_read = 1; return true; },
        deleteMail: (d) => { db.mail = db.mail.filter((x) => x.id !== d.id); return true; }, sendMail: () => true,
        chirpProfile: () => ({ handle: 'johndoe', display_name: 'John Doe', bio: '', avatar: null }),
        // OPS Traffic
        trafficFeed: () => ({ police: true, closer: true, incidents: [
            { id: 11, kind: 'pursuit', label: '10-80 · Police pursuit', icon: 'fa-car-on', color: '#0a84ff', street: 'Route 68 / Joshua Rd, Grand Senora Desert', detail: 'Black Sultan heading east at speed — keep clear', source: 'police', reporter: 'Ofc. Reyes', confirms: 1, dist: 640, x: 1, y: 1, created_at: Math.floor(Date.now() / 1000) - 120, updated_at: Math.floor(Date.now() / 1000) - 5 },
            { id: 12, kind: 'accident', label: 'Accident', icon: 'fa-car-burst', color: '#ff9f0a', street: 'Strawberry Ave / Davis Ave, Davis', detail: 'Two cars, left lane blocked', source: 'player', reporter: 'Ben Jja', confirms: 3, dist: 230, x: 2, y: 2, created_at: Math.floor(Date.now() / 1000) - 300 },
            { id: 13, kind: 'closure', label: 'Road closed', icon: 'fa-road-barrier', color: '#ff453a', street: 'Vespucci Blvd, Little Seoul', detail: 'Closed both ways — use Calais Ave', source: 'police', confirms: 1, dist: 1850, x: 3, y: 3, created_at: Math.floor(Date.now() / 1000) - 1400, mine: true },
            { id: 'gs4', kind: 'shots', label: 'Gun violence', icon: 'fa-gun', color: '#bf5af2', street: 'Grove St, Davis', detail: '6 shots heard by 3 sensors · police responding', source: 'sensor', confirms: 3, dist: 980, x: 4, y: 4, created_at: Math.floor(Date.now() / 1000) - 600, live: true },
            { id: 14, kind: 'fire', label: 'Fire', icon: 'fa-fire', color: '#ff6b00', street: 'Popular St, La Mesa', detail: 'Fire reported automatically', source: 'auto', confirms: 2, dist: 3100, x: 5, y: 5, created_at: Math.floor(Date.now() / 1000) - 900 },
            { id: 'rw1', kind: 'works', label: 'Planned work', icon: 'fa-person-digging', color: '#30d158', detail: 'Fibre works 06:00–18:00 · temporary traffic lights', source: 'works', dist: 420, x: 6, y: 6, live: true },
            { id: 'jb9', kind: 'works', label: 'Planned work', icon: 'fa-person-digging', color: '#30d158', street: 'Mirror Park Blvd', detail: 'San Andreas Power & Light crew on site · Replace pole transformer', source: 'crew', dist: 2600, x: 7, y: 7, created_at: Math.floor(Date.now() / 1000) - 2000, live: true },
        ] }),
        trafficReport: () => ({ ok: true, id: 99 }), trafficVote: () => ({ ok: true }), trafficClear: () => ({ ok: true }), trafficPursuit: () => ({ ok: true, id: 98 }),
        // Sparks
        datingProfile: () => ({ minAge: 18, maxPhotos: 4, seeking: 'everyone', active: true, profile: { id: 1, name: 'John', age: 27, gender: 'man', bio: 'Mechanic by day, karaoke legend by night.', job: 'Mechanic', area: 'Vinewood', photos: [], interests: ['Cars', 'Music'] } }),
        datingSave: () => ({ ok: true }),
        datingDeck: () => ({ active: true, cards: [
            { id: 2, name: 'Maya', age: 25, bio: 'Sunset drives up the coast and too much coffee. Swipe right if you know a good taco truck.', job: 'Paramedic', area: 'Del Perro', photos: [], interests: ['Beach', 'Coffee', 'Dogs'] },
            { id: 3, name: 'Alex', age: 29, bio: 'Weekend racer.', job: 'Engineer', area: 'Sandy Shores', photos: [], interests: ['Racing', 'Gym'] },
        ] }),
        datingSwipe: (d) => (d.id === 2 && d.like ? { ok: true, match: { id: 7, profile: { id: 2, name: 'Maya', age: 25, photos: [] } } } : { ok: true }),
        datingMatches: () => ({ matches: [
            { id: 7, profile: { id: 2, name: 'Maya', age: 25, photos: [], bio: 'Sunset drives' }, new: true, unread: 0, at: Math.floor(Date.now() / 1000) - 60 },
            { id: 8, profile: { id: 4, name: 'Sam', age: 31, photos: [], bio: 'Bookworm' }, last: 'Coffee at Bean Machine tomorrow?', lastMine: false, unread: 2, at: Math.floor(Date.now() / 1000) - 300 },
        ] }),
        datingChat: () => ({ messages: [{ id: 1, body: 'Hey! Loved your karaoke pic 😄', mine: false }, { id: 2, body: 'Haha thanks — you sing?', mine: true }, { id: 3, body: 'Coffee at Bean Machine tomorrow?', mine: false }] }),
        datingSend: () => ({ ok: true }), datingUnmatch: () => ({ ok: true }), datingReport: () => ({ ok: true }),
        chirpUpdateProfile: () => ({ ok: true }),
        chirpFeed: (d) => (d.replyTo ? [] : d.handle ? db.posts.filter((p) => p.handle === d.handle) : d.following ? db.posts.filter((p) => p.mine || (db.follows ||= new Set(['lamar'])).has(p.handle)) : db.posts),
        chirpUser: (d) => { const p = db.posts.find((x) => x.handle === d.handle); const f = (db.follows ||= new Set(['lamar'])); return p ? { handle: p.handle, display_name: p.display_name, avatar: null, bio: p.mine ? '' : 'Grove Street for life', followers: 12 + (f.has(p.handle) ? 1 : 0), following: 40, followed: f.has(p.handle), mine: !!p.mine } : null; },
        chirpFollow: (d) => { const f = (db.follows ||= new Set(['lamar'])); if (f.has(d.handle)) { f.delete(d.handle); return { following: false }; } f.add(d.handle); return { following: true }; },
        chirpPost: (d) => { db.posts.unshift({ id: Date.now(), content: d.content, image: d.image, created_at: Date.now(), handle: 'johndoe', display_name: 'John Doe', likes: 0, replies: 0, liked: 0, mine: 1 }); return 1; },
        chirpLike: (d) => { const p = db.posts.find((x) => x.id === d.id); p.liked = p.liked ? 0 : 1; return !!p.liked; },
        chirpDelete: (d) => { db.posts = db.posts.filter((p) => p.id !== d.id); return true; },
        getBank: () => ({
            name: 'John Doe', balance: 48250, cash: 1320,
            transactions: [{ label: 'Transfer from 555-0142 — rent', amount: 1200, created_at: now - 7200e3 }, { label: 'Bill: Repair', amount: -350, created_at: now - 86400e3 }],
            bills: [{ id: 1, label: 'Speeding ticket', amount: 250, target: 'society_police' }],
        }),
        transfer: () => ({ ok: true }), payBill: () => ({ ok: true }),
        getVehicles: () => [
            { plate: 'OPS 2024', model: 1, type: 'car', name: null, stored: true, parking: 'Legion Square', fuel: 76, engine: 980, body: 940, mileage: 1240.5 },
            { plate: '8KX 221', model: 2, type: 'car', name: 'Daily', stored: false, fuel: 22, engine: 610, body: 720 },
        ],
        serviceRequest: () => true,
        getServiceRequests: () => ({ member: true, requests: [{ id: 1, caller_name: 'Ashley Carter', caller_number: '555-0142', message: 'Car broke down near the pier', status: 'open', x: 0, y: 0, created_at: now - 300e3 }] }),
        handleServiceRequest: () => true,
        nearbyPlayers: () => [{ id: 2, name: 'Lamar Davis' }],
        setupInfo: () => ({ name: 'John Doe', number: '555-2024', email: 'john.doe@opslabs.cloud', emailUser: 'john.doe', domain: 'opslabs.cloud', numberFormat: '555-XXXX', suggestions: ['555-1188', '555-7070', '555-4242'], takenNumbers: ['555-0142', '555-0199', '555-3321', '555-8812'], takenEmails: ['ashley.carter', 'tracey'], takenComplete: true }),
        setupCheck: (d) => {
            const r = {};
            if (d.number !== undefined) r.number = /^555-?\d{4}$/.test(d.number) ? (d.number.replace('-', '') === '5550142' ? { ok: false, error: 'That number is taken' } : { ok: true, value: d.number }) : { ok: false, error: 'Use the format 555-0000' };
            if (d.emailUser !== undefined) r.email = /^[a-z0-9][a-z0-9._-]{2,29}$/.test(d.emailUser) ? { ok: true } : { ok: false, error: '3–30 letters, numbers, dots, dashes or underscores' };
            return r;
        },
        completeSetup: (d) => {
            if (window.MOCK_FAIL_SETUP) { window.MOCK_FAIL_SETUP--; return null; }   // simulate a lost reply
            window._setupDone = true;
            const init = rpcs.init();
            Object.assign(init, { name: d.name, number: d.number, email: d.emailUser + '@opslabs.cloud', settings: d.settings, setupDone: true });
            return { ok: true, init };
        },
        changeOpsId: (d) => (/^[a-z0-9][a-z0-9._-]{2,29}$/.test(d.emailUser) ? { ok: true, email: d.emailUser + '@opslabs.cloud' } : { error: '3–30 letters, numbers, dots, dashes or underscores' }),
        changeName: (d) => ({ ok: true, name: d.name }),
        musicLibrary: (d) => (window._mlib ||= []).filter((t) => t.app === d.app),
        musicAdd: (d) => { (window._mlib ||= []).unshift({ id: Date.now(), app: d.app, title: d.title || 'Untitled', artist: d.artist, url: d.url, art: d.art, kind: d.kind, playlist: d.playlist, liked: false }); return { ok: true }; },
        musicUpdate: (d) => { const t = (window._mlib || []).find((x) => x.id === d.id); if (t && d.liked !== undefined) t.liked = d.liked; if (t && d.playlist !== undefined) t.playlist = d.playlist; return true; },
        musicDelete: (d) => { window._mlib = (window._mlib || []).filter((x) => x.id !== d.id); return true; },
        oauthStatus: () => ({ spotify: { configured: true, connected: !!window._spConnected, name: window._spConnected ? 'John Doe' : null, product: 'premium' }, tidal: { configured: true, connected: !!window._tdConnected, name: window._tdConnected ? 'john@example.com' : null, product: 'GB' } }),
        oauthStart: (d) => { setTimeout(() => { window._spConnected = d.provider === 'spotify'; window.postMessage({ action: 'oauthConnected', data: { provider: d.provider, name: 'John Doe' } }, '*'); }, 1200); return { url: 'about:blank#' + d.provider }; },
        oauthDisconnect: () => { window._spConnected = false; return true; },
        spotifyApi: (d) => {
            const img = (h) => [{ url: `data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><rect width='64' height='64' fill='hsl(${h},70%,45%)'/></svg>`)}` }];
            const tr = (i) => ({ type: 'track', uri: 'spotify:track:' + i, name: ['Midnight City', 'Blinding Lights', 'Levitating', 'Heat Waves', 'As It Was'][i % 5], artists: [{ name: ['M83', 'The Weeknd', 'Dua Lipa', 'Glass Animals', 'Harry Styles'][i % 5] }], album: { images: img(i * 60) }, duration_ms: 200000 });
            window._spState ||= { playing: false, item: null, progress: 0 };
            const S = window._spState;
            if (d.method === 'GET' && d.path === '/v1/me/playlists') return { status: 200, data: { items: [{ id: 'p1', uri: 'spotify:playlist:p1', name: 'Drive Mix', images: img(140), owner: { display_name: 'John' } }, { id: 'p2', uri: 'spotify:playlist:p2', name: 'Chill', images: img(200), owner: { display_name: 'Spotify' } }] } };
            if (d.method === 'GET' && d.path.endsWith('/tracks')) return { status: 200, data: { items: [0, 1, 2, 3, 4].map((i) => ({ track: tr(i) })) } };
            if (d.method === 'GET' && d.path === '/v1/me/player/recently-played') return { status: 200, data: { items: [{ track: tr(3) }, { track: tr(1) }] } };
            if (d.method === 'GET' && d.path === '/v1/search') return { status: 200, data: { tracks: { items: [tr(0), tr(2)] } } };
            if (d.method === 'GET' && d.path === '/v1/me/player') return S.item ? { status: 200, data: { is_playing: S.playing, progress_ms: S.progress, item: S.item, shuffle_state: false, repeat_state: 'off', device: { name: 'DESKTOP-PC' } } } : { status: 204 };
            if (d.method === 'PUT' && d.path === '/v1/me/player/play') { S.playing = true; if (d.body) S.item = tr(d.body.offset ? +d.body.offset.uri.split(':').pop() : d.body.uris ? +d.body.uris[0].split(':').pop() : 0); return { status: 204 }; }
            if (d.method === 'PUT' && d.path === '/v1/me/player/pause') { S.playing = false; return { status: 204 }; }
            if (d.method === 'POST' && d.path === '/v1/me/player/next') { S.item = tr((+S.item.uri.split(':').pop() + 1) % 5); return { status: 204 }; }
            return { status: 204 };
        },
        carrierStatus: () => window._carrier,
        carrierInstall: (d) => {
            const v = window._carrier;
            if (!v.line) return { error: 'no_line' };
            if (d.code && d.code.replace(/\s/g, '').toUpperCase() !== v.line.activation_code) return { error: 'wrong_code' };
            Object.assign(v.line, { installed: true, status: 'active', service: true, period_end: Math.floor(Date.now() / 1000) + 7 * 86400, activation_code: null });
            return v;
        },
        carrierRadioMinute: () => true,
        carrierShop: () => ({ balance: window._bank ?? 2400, credit: window._carrier.credit || 0, carrier: window._carrier, plans: [
            { id: 2, code: 'essential', kind: 'plan', name: 'Essential', description: 'Everyday texting, calls and apps.', price: 500, period_days: 7, sms: 500, minutes: 300, data_mb: 5120, color: '#0a84ff', featured: false, sort: 1 },
            { id: 3, code: 'plus', kind: 'plan', name: 'Plus', description: 'Unlimited texts and calls with plenty of data.', price: 900, period_days: 7, sms: -1, minutes: -1, data_mb: 20480, color: '#5e5ce6', featured: true, sort: 2 },
            { id: 4, code: 'unlimited', kind: 'plan', name: 'Unlimited', description: 'Everything unlimited.', price: 1500, period_days: 7, sms: -1, minutes: -1, data_mb: -1, color: '#ff375f', featured: false, sort: 3 },
            { id: 5, code: 'data-5gb', kind: 'addon', name: '5 GB Data Boost', description: 'Extra data until your plan renews.', price: 200, period_days: 0, sms: 0, minutes: 0, data_mb: 5120, color: '#30d158', sort: 10 },
            { id: 6, code: 'texts-500', kind: 'addon', name: '500 Texts', description: 'Extra texts until your plan renews.', price: 100, period_days: 0, sms: 500, minutes: 0, data_mb: 0, color: '#30d158', sort: 11 }] }),
        carrierBuy: (d) => {
            const shop = rpcs.carrierShop(); const item = shop.plans.find((p) => p.code === d.code);
            const fromCredit = Math.min(window._carrier.credit || 0, item.price);
            window._carrier.credit = (window._carrier.credit || 0) - fromCredit;
            window._bank = (window._bank ?? 2400) - (item.price - fromCredit);
            const l = window._carrier.line;
            if (item.kind === 'addon') { if (item.data_mb) l.usage.data_mb.limit += item.data_mb; if (item.sms) l.usage.sms.limit += item.sms; }
            else Object.assign(l, { plan: { code: item.code, name: item.name, color: item.color, price: item.price, period_days: item.period_days }, usage: { sms: { used: 0, limit: item.sms }, minutes: { used: 0, limit: item.minutes }, data_mb: { used: 0, limit: item.data_mb } } });
            return { ok: true, carrier: window._carrier, balance: window._bank, credit: window._carrier.credit };
        },
        carrierRenew: () => ({ ok: true, carrier: window._carrier }),
        carrierAutoRenew: (d) => { window._carrier.line.auto_renew = d.on; return { ok: true, carrier: window._carrier }; },
        carrierActivity: () => ({ daily: Array.from({ length: 14 }, (_, i) => ({ day: `2026-09-${String(18 + i).padStart(2, '0')}`, sms: i, seconds: i * 40, data_kb: ((i * 7919) % 300000) + 20000 })),
            events: [{ type: 'addon', detail: '5 GB Data Boost', amount: 200, at: Date.now() / 1000 - 3600 }, { type: 'subscribe', detail: 'Essential', amount: 500, at: Date.now() / 1000 - 86400 }, { type: 'install', detail: 'eSIM installed', amount: 0, at: Date.now() / 1000 - 86000 }] }),
        tidalApi: (d) => (window._tdMock ? window._tdMock(d) : { status: 200, data: { data: [], included: [] } }),
        devSession: () => ({ loggedIn: !!window._devAuthed }),
        devLogin: (d) => ((d.email || '').toLowerCase() === 'opsphone@ops.com' && d.password === '2026'
            ? ((window._devAuthed = true), { ok: true })
            : { error: 'Incorrect email or password.' }),
        devLogout: () => { window._devAuthed = false; return { ok: true }; },
        devStats: () => ({ online: 12, users: 248, messages: 5120, places: Phone.config.places.length }),
        devSavePlace: (d) => {
            const list = Phone.config.places.filter((p) => !(p.source === 'db' && p.id === d.id));
            list.push({ id: d.id || Date.now() % 100000, source: 'db', name: d.name, icon: d.icon, category: d.category, coords: { x: d.x, y: d.y, z: d.z }, blip: d.blip, blipSprite: d.blipSprite, blipColor: d.blipColor });
            setTimeout(() => window.postMessage({ action: 'placesUpdated', data: list }, '*'), 30);
            return { ok: true };
        },
        devDeletePlace: (d) => { setTimeout(() => window.postMessage({ action: 'placesUpdated', data: Phone.config.places.filter((p) => !(p.source === 'db' && p.id === d.id)) }, '*'), 30); return { ok: true }; },
        devTeleport: () => ({ ok: true }),
        devAddWallpaper: () => ({ ok: true }), devDeleteWallpaper: () => ({ ok: true }),
        devFindUsers: () => [{ number: '555-0142', email: 'ashley.carter@opslabs.cloud', name: 'Ashley Carter', online: true }],
        devSetNumber: (d) => ({ ok: true, number: d.newNumber }),
        devBroadcast: () => ({ ok: true, delivered: 12 }),
        startLiveLocation: (d) => {
            const id = Date.now() % 100000;
            (db.messages[d.number] ||= []).push({ id, mine: true, message: '', attachment: { type: 'live', shareId: id }, created_at: Date.now() });
            mockOutgoing[id] = { id, number: d.number, expires: d.minutes ? Math.floor(Date.now() / 1000) + d.minutes * 60 : 0 };
            return { ...mockOutgoing[id] };
        },
        stopLiveLocation: (d) => { delete mockOutgoing[d.id]; return true; },
        getLiveShares: () => ({ incoming: Object.values(mockIncoming), outgoing: Object.values(mockOutgoing), now: Math.floor(Date.now() / 1000) }),
        shareContact: () => true,
        laptopNet: () => window._laptopNet,
    };

    // Mock.laptop() opens the laptop desktop; Mock.unplug() / Mock.plugIn() flip its Ethernet
    window._laptopNet = { id: 7, power: { level: 64, charging: true, plugged: true }, link: true, internet: true, via: { kind: 'router', name: 'Office Gateway Pro' }, gateway: 'Office Gateway Pro', ip: '192.168.12.107', router_ip: '192.168.12.1', mac: '3C:A6:2F:4E:91:07', speed: 1000,
        isp: { provider: 'OPS Fibre', plan: 'Fibre 500', down: 500, up: 75, live: true } };

    const nuis = {
        cctvList: () => ({ systems: [{ id: 7, name: 'Mission Row PD CCTV', cams: 6, org_job: 'police', owner: 'LSPD', powered: true, recording: true, internet: true, remote: true },
            { id: 9, name: 'Home · 1076 Procopio Dr', cams: 2, owner: 'Ben Jja', powered: true, recording: true, internet: false, remote: false }] }),
        cctvSystem: (d) => (d.id === 9 ? { error: 'The recorder isn’t connected to the internet' } : { id: 7, name: 'Mission Row PD CCTV', recording: true, cams: [
            { id: 1, name: 'Front entrance', online: true, status: 'ok', statusText: 'Live' }, { id: 2, name: 'Car park ANPR', anpr: true, online: true, status: 'ok', statusText: 'Live' },
            { id: 3, name: 'Yard PTZ', ptz: true, online: true, status: 'fault_lens', statusText: 'Picture degraded — dirty / fogged lens' }, { id: 4, name: 'Cells corridor', online: false, status: 'fault_cable', statusText: 'Cable fault' }] }),
        cctvEvents: (d) => (d.kind === 'anpr' ? [{ kind: 'anpr', detail: 'OPS 123 · 48 km/h', camera: 'Car park ANPR', at: Math.floor(Date.now() / 1000) - 90 }]
            : [{ kind: 'motion', detail: '2 moving', camera: 'Front entrance', at: Math.floor(Date.now() / 1000) - 40 }, { kind: 'ring', detail: 'Doorbell rung', camera: 'Doorbell', at: Math.floor(Date.now() / 1000) - 600 }]),
        cctvWatch: () => true,
        trafficHere: () => ({ street: 'Strawberry Ave / Davis Ave, Davis', pursuit: false }),
        trafficStreets: (d) => (d.points || []).map(() => 'Mirror Park Blvd, Mirror Park'),
        trafficPursuitTrack: () => true,
        ispMine: () => ({ owed: 120, services: [{ id: 1, ref: 'LINE-00001', package: 'Business Fibre 1G', address: '1076 Procopio Dr', status: 'active', line: 'degraded', overdue: true, down: 1000, up: 200, price: 120, ip_mode: 'static',
            ips: ['198.51.100.10', '198.51.100.11', '198.51.100.12', '198.51.100.13', '198.51.100.14'], config: { wifi: { ssid: 'Procopio-Office', secured: true } }, tests: [{ down_mbps: 612, up_mbps: 140 }],
            outage: { ref: 'INC-00004', title: 'Fibre fault · Paleto Bay' } }] }),
        ispPackages: () => [{ id: 1, name: 'Fibre 150', segment: 'residential', desc: 'Streaming and browsing', down: 150, up: 30, price: 25, setup: 0, contract: 12, ip: 'dynamic' },
            { id: 2, name: 'Fibre 900', segment: 'residential', desc: 'Gaming and big households', down: 900, up: 110, price: 55, setup: 0, contract: 18, ip: 'dynamic' },
            { id: 5, name: 'Business Fibre 1G', segment: 'business', desc: '5 static IPs, 8 h fix', down: 1000, up: 200, price: 120, setup: 50, contract: 24, ip: 'static' },
            { id: 9, name: 'Government 1G', segment: 'government', desc: 'Dedicated, 4 h fix', down: 1000, up: 1000, price: 300, setup: 0, contract: 36, ip: 'dedicated' }],
        ispOrder: () => ({ ok: true, ref: 'LINE-00002' }),
        ispPay: () => ({ ok: true, paid: 120 }),
        ispTicket: () => ({ ok: true, ref: 'TKT-00003' }),
        ispSpeedtest: () => ({ down_mbps: 874, up_mbps: 181, ping_ms: 4, jitter_ms: 1, via: 'ethernet', pct: 87, package: 'Business Fibre 1G', plan_down: 1000, line: 'up' }),
        ispLookup: () => ({ customer: 'Procopio Office', ref: 'LINE-00001', package: 'Business Fibre 1G', status: 'active', line: 'up', ips: ['198.51.100.10', '198.51.100.11'],
            config: { lan: { subnet: '192.168.1.0/24', gateway: '192.168.1.1' }, dhcp: { enabled: true, from: '192.168.1.100', to: '192.168.1.199' }, dns: { servers: ['203.0.113.53', '203.0.113.54'] },
                wifi: { ssid: 'Procopio-Office', password: 'x' }, vlans: [{ id: 20 }], firewall: { rules: [{}, {}] }, vpn: [] } }),
        opsAddresses: (d) => (d.points || []).map((p, i) => ({ street: ['Procopio Dr', 'Sinner St', 'Vespucci Blvd'][i % 3], cross: ['Paleto Blvd', 'Atlee St', 'Alta St'][i % 3], zone: ['Paleto Bay', 'Mission Row', 'Pillbox Hill'][i % 3], dist: Math.round(Math.hypot(p.x - 215, p.y + 810)), dir: ['N', 'E', 'SW'][i % 3] })),
        getWorld: () => ({ weather: 'clear', hour: new Date().getHours(), minute: 0, zone: 'Los Santos', serverId: 1 }),
        getLocation: () => ({ x: 215.31, y: -810.12, z: 30.73, h: 157.4, street: 'Alta St', cross: 'Vinewood Blvd', zone: 'Downtown' }),
        liveDistances: () => Object.fromEntries(Object.values(mockIncoming).map((s) => [s.id, Math.hypot(s.x - 215, s.y + 810)])),
        liveFollow: () => true,
        liveFlash: () => true,
        vehicleLabels: () => ({ 1: { name: 'Sultan RS', make: 'Karin' }, 2: { name: 'Blista', make: 'Dinka' } }),
        laptopClose: () => { window.postMessage({ action: 'laptop', data: { open: false } }, '*'); return true; },
        close: () => { window.postMessage({ action: 'close' }, '*'); setTimeout(() => window.postMessage({ action: 'open' }, '*'), 900); return true; },
    };

    window.Mock = {
        async nui(endpoint, data) {
            await sleep(window.MOCK_LATENCY ?? 60);
            if (endpoint === 'rpc') {
                const fn = rpcs[data.name];
                return fn ? JSON.parse(JSON.stringify(fn(data.data || {}) ?? null)) : null;
            }
            return nuis[endpoint] ? nuis[endpoint](data) : true;
        },
        /** Lamar starts sharing his live location and walks around */
        live() {
            const id = 77;
            (db.messages['555-0199'] ||= []).push({ id: Date.now(), mine: false, message: '', attachment: { type: 'live', shareId: id }, created_at: Date.now() });
            let t = 0;
            const step = () => {
                t++;
                mockIncoming[id] = { id, number: '555-0199', name: 'Lamar Davis', x: 150 + t * 6, y: -1000 + t * 4, z: 30, h: 0, expires: 0, updated: Math.floor(Date.now() / 1000), dist: Math.hypot(150 + t * 6 - 215, -1000 + t * 4 + 810) };
                window.postMessage({ action: 'liveLocation', data: mockIncoming[id] }, '*');
            };
            step();
            window.postMessage({ action: 'message', data: { number: '555-0199', message: '' } }, '*');
            this._liveTimer = setInterval(step, 2000);
        },
        endLive() { clearInterval(this._liveTimer); delete mockIncoming[77]; window.postMessage({ action: 'liveLocationEnded', data: { id: 77 } }, '*'); },
        laptop() { window.postMessage({ action: 'close' }, '*'); window.postMessage({ action: 'laptop', data: { open: true, id: 7, net: window._laptopNet } }, '*'); },
        unplug() { window._laptopNet = { id: 7, link: false, internet: false, reason: 'unplugged', mac: '3C:A6:2F:4E:91:07' }; },
        plugIn() { window._laptopNet = { id: 7, power: { level: 64, charging: true, plugged: true }, link: true, internet: true, via: { kind: 'router', name: 'Office Gateway Pro' }, gateway: 'Office Gateway Pro', ip: '192.168.12.107', router_ip: '192.168.12.1', mac: '3C:A6:2F:4E:91:07', speed: 1000, isp: { provider: 'OPS Fibre', plan: 'Fibre 500', down: 500, up: 75, live: true } }; },
        incomingCall() { window.postMessage({ action: 'incomingCall', data: { id: 2, number: '555-0199', name: 'Lamar Davis' } }, '*'); },
        message() {
            window.postMessage({ action: 'message', data: { number: '555-0199', message: 'You there?' } }, '*');
            window.postMessage({ action: 'notify', data: { app: 'messages', title: 'Lamar Davis', body: 'You there?', data: { number: '555-0199' } } }, '*');
        },
    };

    document.addEventListener('DOMContentLoaded', () => setTimeout(async () => {
        document.body.classList.add('preview');
        await handlers.init(await rpc('init'));
        setTimeout(() => window.postMessage({ action: 'open' }, '*'), 200);
    }, 0));
}
