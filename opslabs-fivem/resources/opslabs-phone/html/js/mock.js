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
    const rpcs = {
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
        readMail: () => true, deleteMail: () => true, sendMail: () => true,
        chirpProfile: () => ({ handle: 'johndoe', display_name: 'John Doe', bio: '', avatar: null }),
        chirpUpdateProfile: () => ({ ok: true }),
        chirpFeed: (d) => (d.replyTo ? [] : db.posts),
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
    };

    const nuis = {
        getWorld: () => ({ weather: 'clear', hour: new Date().getHours(), minute: 0, zone: 'Los Santos', serverId: 1 }),
        getLocation: () => ({ x: 215.31, y: -810.12, z: 30.73, h: 157.4, street: 'Alta St', cross: 'Vinewood Blvd', zone: 'Downtown' }),
        liveDistances: () => Object.fromEntries(Object.values(mockIncoming).map((s) => [s.id, Math.hypot(s.x - 215, s.y + 810)])),
        liveFollow: () => true,
        liveFlash: () => true,
        vehicleLabels: () => ({ 1: { name: 'Sultan RS', make: 'Karin' }, 2: { name: 'Blista', make: 'Dinka' } }),
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
