'use strict';

/* =====================================================================
   Spotify / TIDAL accounts in the music apps
   - Connect: opens the player's own browser on the official sign-in
     page; the server finishes the OAuth flow and keeps the tokens.
   - Spotify (Soundwave): your playlists, liked songs, recently played and
     search; playback is Spotify Connect — it plays on the Spotify app on
     your PC/phone and is controlled from here (Spotify Premium).
   - TIDAL (Tide): your playlists, My Tracks and catalogue search; TIDAL's
     API has no playback control, so tracks open in TIDAL.
   ===================================================================== */

const STREAM_FOR_APP = { soundwave: 'spotify', tide: 'tidal' };
const STREAM_NAME = { spotify: 'Spotify', tidal: 'TIDAL' };

/** open a link in the player's real browser (FiveM NUI), or a new tab in preview */
function openExternal(url) {
    if (typeof window.invokeNative === 'function') window.invokeNative('openUrl', url);
    else window.open(url, '_blank', 'noopener');
}

const Streaming = {
    status: null,
    async refresh() {
        this.status = (await rpc('oauthStatus')) || {};
        return this.status;
    },
    async connect(provider) {
        const res = await rpc('oauthStart', { provider });
        if (!res || res.error) return UI.alert({ title: I18N.t("Can't connect right now"), message: (res && res.error) || '' });
        openExternal(res.url);
        this.waitSheet(provider, res.url);
    },
    waitSheet(provider, url) {
        const name = STREAM_NAME[provider];
        const sheet = UI.sheet({
            title: name,
            left: I18N.t('Cancel'),
            medium: true,
            render(body) {
                body.innerHTML = `
                    <div class="st-connect">
                        <div class="stc-icon ${provider}"><i class="${provider === 'spotify' ? 'fa-brands fa-spotify' : 'fa-solid fa-water'}"></i></div>
                        <h3>${esc(I18N.t('Finish signing in in your browser'))}</h3>
                        <p>${esc(I18N.t('Your browser opened the official sign-in page. Log in, tap Agree, then come back to the game.'))}</p>
                        <div class="spinner" style="margin:18px auto 10px"></div>
                        <button class="btn gray small" data-act="reopen">${esc(I18N.t('Open the page again'))}</button>
                    </div>`;
                body.addEventListener('click', (e) => { if (e.target.closest('[data-act=reopen]')) openExternal(url); });
            },
        });
        const off = Phone.on('oauthConnected', (d) => {
            if (d.provider !== provider) return;
            off();
            sheet.close();
            UI.toast(`${name}: ${d.name || I18N.t('Connected')}`, 'fa-solid fa-circle-check');
            this.refresh();
        });
    },
    async disconnect(provider) {
        if (!(await UI.confirm(`${I18N.t('Disconnect')} ${STREAM_NAME[provider]}?`, I18N.t('You can connect again any time.'), I18N.t('Disconnect'), true))) return false;
        await rpc('oauthDisconnect', { provider });
        if (provider === 'spotify' && Music.remote) SpotifyRemote.detach(true);
        await this.refresh();
        return true;
    },
    spotify(method, path, query, body) { return rpc('spotifyApi', { method, path, query, body }); },
    tidal(path, query) { return rpc('tidalApi', { path, query }); },
};
Phone.on('init', () => Streaming.refresh());

/* ---------------------------------------------------------------------
   Spotify Connect remote — drives the shared Music engine so the Dynamic
   Island, lock screen and Control Center all work for Spotify too.
   --------------------------------------------------------------------- */

const SpotifyRemote = {
    timer: null,
    lastError: 0,

    toTrack(item) {
        if (!item) return null;
        const img = item.album && item.album.images && item.album.images[0];
        return {
            title: item.name, artist: (item.artists || []).map((a) => a.name).join(', '),
            art: img ? img.url : null, url: item.uri, kind: 'remote', provider: 'spotify',
        };
    },

    /** play a context (playlist/album uri) at an offset, or a list of track uris */
    async play({ context, offset, uris }, deviceId) {
        const body = context ? { context_uri: context, ...(offset ? { offset: { uri: offset } } : {}) } : { uris };
        const r = await Streaming.spotify('PUT', '/v1/me/player/play', deviceId ? { device_id: deviceId } : null, body);
        if (r && r.status >= 200 && r.status < 300) {
            if (Music.track && !Music.remote) Music._stopAll();
            this.attach();
            setTimeout(() => this.poll(), 700);
            return true;
        }
        return this.handleError(r, (id) => this.play({ context, offset, uris }, id));
    },

    async handleError(r, retryWithDevice) {
        const reason = r && r.data && r.data.error && (r.data.error.reason || r.data.error.message);
        if (r && r.status === 404) {
            // no active device: let the player pick one
            const d = await Streaming.spotify('GET', '/v1/me/player/devices');
            const devices = (d && d.data && d.data.devices) || [];
            if (!devices.length) {
                UI.alert({ title: I18N.t('Open Spotify first'), message: I18N.t('Open the Spotify app on your PC or phone, then try again. Music plays there and you control it from here.') });
                return false;
            }
            const i = await UI.actionSheet(I18N.t('Play on'), devices.map((dv) => ({ label: `${dv.name} · ${dv.type}` })));
            if (i === null) return false;
            return retryWithDevice ? retryWithDevice(devices[i].id) : false;
        }
        if (r && r.status === 403) {
            UI.alert({ title: I18N.t('Spotify Premium needed'), message: I18N.t('Spotify only lets Premium accounts control playback from other apps.') });
            return false;
        }
        if (r && r.status === 401) { UI.alert({ title: I18N.t('Please connect Spotify again') }); Streaming.refresh(); return false; }
        if (Date.now() - this.lastError > 3000) { this.lastError = Date.now(); UI.toast(reason || I18N.t("Spotify didn't respond"), 'fa-solid fa-circle-exclamation'); }
        return false;
    },

    attach() {
        Music.app = 'soundwave';
        if (!Music.remote) Music.remote = { provider: 'spotify', progress: 0, duration: Infinity, at: Date.now() };
        clearInterval(this.timer);
        this.timer = setInterval(() => this.poll(), Phone.state === 'open' ? 3000 : 6000);
    },
    detach(clear) {
        clearInterval(this.timer);
        this.timer = null;
        Music.remote = null;
        if (clear || (Music.track && Music.track.kind === 'remote')) { Music.track = null; Music.playing = false; Music._emit(); }
    },

    async poll() {
        const r = await Streaming.spotify('GET', '/v1/me/player');
        if (!Music.remote) return;
        if (!r || r.status === 204 || !r.data || !r.data.item) {
            if (r && (r.status === 204 || r.status === 200)) { Music.playing = false; Music._emit(); }
            return;
        }
        const s = r.data;
        Music.track = this.toTrack(s.item);
        Music.playing = !!s.is_playing;
        Music.loading = false;
        Music.shuffle = !!s.shuffle_state;
        Music.repeat = s.repeat_state === 'track' ? 'one' : s.repeat_state === 'context' ? 'all' : 'off';
        Music.remote = { provider: 'spotify', progress: (s.progress_ms || 0) / 1000, duration: (s.item.duration_ms || 0) / 1000, at: Date.now(), device: s.device && s.device.name };
        Music._emit();
    },

    async cmd(method, path, query) {
        const r = await Streaming.spotify(method, path, query);
        if (!r || r.status >= 300) return this.handleError(r);
        setTimeout(() => this.poll(), 400);
        return true;
    },
    pause() { Music.playing = false; Music._emit(); return this.cmd('PUT', '/v1/me/player/pause'); },
    resume() { Music.playing = true; Music._emit(); return this.cmd('PUT', '/v1/me/player/play'); },
    toggle() { return Music.playing ? this.pause() : this.resume(); },
    next() { return this.cmd('POST', '/v1/me/player/next'); },
    prev() { return this.cmd('POST', '/v1/me/player/previous'); },
    seek(sec) {
        if (Music.remote) { Music.remote.progress = sec; Music.remote.at = Date.now(); Music._emit(); }
        return this.cmd('PUT', '/v1/me/player/seek', { position_ms: Math.round(sec * 1000) });
    },
};
Phone.on('open', () => { if (Music.remote) { SpotifyRemote.attach(); SpotifyRemote.poll(); } });
Phone.on('close', () => { if (Music.remote) SpotifyRemote.attach(); });
Phone.on('reset', () => SpotifyRemote.detach(true));

/* ---------------------------------------------------------------------
   TIDAL (JSON:API) — resources come back in data + included
   --------------------------------------------------------------------- */

const TidalLib = {
    index(doc) {
        const map = new Map();
        for (const x of (doc && doc.included) || []) map.set(x.type + ':' + x.id, x);
        return map;
    },
    rel(map, res, name) {
        const d = res && res.relationships && res.relationships[name] && res.relationships[name].data;
        return (Array.isArray(d) ? d : d ? [d] : []).map((r) => map.get(r.type + ':' + r.id)).filter(Boolean);
    },
    art(artwork) {
        const files = (artwork && artwork.attributes && artwork.attributes.files) || [];
        const f = files.find((x) => x.meta && x.meta.width >= 160 && x.meta.width <= 480) || files[0];
        return f ? f.href : null;
    },
    track(map, t) {
        const album = this.rel(map, t, 'albums')[0];
        return {
            id: t.id,
            title: (t.attributes && t.attributes.title) || 'Track',
            artist: this.rel(map, t, 'artists').map((a) => a.attributes && a.attributes.name).filter(Boolean).join(', '),
            art: this.art(this.rel(map, album, 'coverArt')[0]),
        };
    },
    playlist(map, pl) {
        const a = pl.attributes || {};
        return { id: pl.id, name: a.name || 'Playlist', count: a.numberOfItems || 0, art: this.art(this.rel(map, pl, 'coverArt')[0]) };
    },
    /** tracks of a relationship list (collection / playlist items / search), in order */
    tracks(doc, refs) {
        const map = this.index(doc);
        return (refs || []).filter((r) => r.type === 'tracks').map((r) => map.get('tracks:' + r.id)).filter(Boolean).map((t) => this.track(map, t));
    },
    cursor(doc) {
        const next = doc && doc.links && doc.links.next;
        const m = next && /[?&]page%5Bcursor%5D=([^&]+)|[?&]page\[cursor\]=([^&]+)/.exec(next);
        return m ? decodeURIComponent(m[1] || m[2]) : null;
    },
    TRACK_INCLUDE: 'items,items.artists,items.albums.coverArt',

    async playlists() {
        const [coll, own] = await Promise.all([
            Streaming.tidal('/v2/userCollectionPlaylists/me/relationships/items', { include: 'items,items.coverArt' }),
            Streaming.tidal('/v2/playlists', { 'filter[owners.id]': 'me', include: 'coverArt' }),
        ]);
        const out = new Map();
        if (own && own.data) {
            const map = this.index(own.data);
            for (const pl of own.data.data || []) out.set(pl.id, this.playlist(map, pl));
        }
        if (coll && coll.data) {
            const map = this.index(coll.data);
            for (const r of coll.data.data || []) {
                const pl = map.get('playlists:' + r.id);
                if (pl && !out.has(pl.id)) out.set(pl.id, this.playlist(map, pl));
            }
        }
        const failed = [coll, own].every((r) => !r || !r.data || r.status >= 300);
        return { list: [...out.values()], status: failed ? (coll && coll.status) || 0 : 200 };
    },
    /** one page of a playlist or of My Tracks ('favs') */
    async page(id, cursor) {
        const path = id === 'favs' ? '/v2/userCollectionTracks/me/relationships/items' : `/v2/playlists/${encodeURIComponent(id)}/relationships/items`;
        const query = { include: this.TRACK_INCLUDE };
        if (cursor) query['page[cursor]'] = cursor;
        const r = await Streaming.tidal(path, query);
        const doc = r && r.data;
        return { tracks: doc ? this.tracks(doc, doc.data) : [], cursor: this.cursor(doc), status: (r && r.status) || 0 };
    },
    async search(q) {
        const r = await Streaming.tidal('/v2/searchResults', { 'filter[query]': q.slice(0, 200), include: 'tracks,tracks.artists,tracks.albums.coverArt' });
        const doc = r && r.data;
        const result = doc && Array.isArray(doc.data) ? doc.data[0] : doc && doc.data;
        const refs = result && result.relationships && result.relationships.tracks && result.relationships.tracks.data;
        return { tracks: doc ? this.tracks(doc, refs).slice(0, 20) : [], status: (r && r.status) || 0 };
    },
};

/* ---------------------------------------------------------------------
   UI pieces used by the music apps
   --------------------------------------------------------------------- */

/** dark music sheet that keeps the app's accent colour (sheets live outside .mu) */
function musicSheet(body) {
    body.classList.add('mu-sheet');
    const sheet = body.closest('.sheet');
    sheet.classList.add('dark-sheet');
    const mu = document.querySelector('.app-window:last-child .mu');
    if (mu) sheet.style.setProperty('--mu-accent', mu.style.getPropertyValue('--mu-accent'));
}

const spImg = (o) => (o && o.images && o.images[0] && o.images[0].url) || null;
const spArt = (url, fallback) => (url ? `url('${cssUrl(url)}') center/cover` : fallback);

function streamConnectCard(provider) {
    const st = (Streaming.status || {})[provider] || {};
    if (!st.configured) return '';
    const name = STREAM_NAME[provider];
    return `
        <div class="st-card-connect ${provider}">
            <i class="${provider === 'spotify' ? 'fa-brands fa-spotify' : 'fa-solid fa-water'}"></i>
            <div class="grow"><b>${esc(I18N.t('Connect') + ' ' + name)}</b>
                <span>${esc(provider === 'spotify' ? I18N.t('Your playlists, liked songs and search. Control playback on your Spotify app.') : I18N.t('Your playlists, My Tracks and search. Tracks open in TIDAL.'))}</span></div>
            <button class="mu-pill" data-stream-connect="${provider}">${esc(I18N.t('Connect'))}</button>
        </div>`;
}

const StreamUI = {
    async home(appId, box) {
        if (!box) return;
        const provider = STREAM_FOR_APP[appId];
        if (!Streaming.status) await Streaming.refresh();
        const st = (Streaming.status || {})[provider] || {};
        if (!st.connected) { box.innerHTML = streamConnectCard(provider); this.bind(box, appId); return; }

        const head = `<div class="st-account"><i class="${provider === 'spotify' ? 'fa-brands fa-spotify' : 'fa-solid fa-water'}"></i><span>${esc(STREAM_NAME[provider])} · ${esc(st.name || '')}${st.product && provider === 'spotify' ? ' · ' + esc(st.product) : ''}</span><button data-stream-disconnect="${provider}">${esc(I18N.t('Disconnect'))}</button></div>`;
        box.innerHTML = head + '<div class="spinner" style="margin:12px auto"></div>';
        this.bind(box, appId);
        if (provider === 'tidal') return this.tidalHome(box, head);
        const [pl, recent] = await Promise.all([
            Streaming.spotify('GET', '/v1/me/playlists', { limit: 20 }),
            Streaming.spotify('GET', '/v1/me/player/recently-played', { limit: 10 }),
        ]);
        if (!box.isConnected) return;
        if (pl && pl.status >= 400) { box.innerHTML = head + this.spError(pl); return; }
        const playlists = (pl && pl.data && pl.data.items) || [];
        const recents = ((recent && recent.data && recent.data.items) || []).map((x) => x.track).filter(Boolean);
        box.innerHTML = head + `
            <h2 class="mu-h2">${esc(I18N.t('Your Spotify'))}</h2>
            <div class="mu-shelf">
                <button class="mu-card" data-sp-liked><span class="mu-card-art" style="background:linear-gradient(135deg,#450af5,#c4efd9)"><i class="fa-solid fa-heart"></i></span><b>${esc(I18N.t('Liked Songs'))}</b><span>Spotify</span></button>
                ${playlists.map((p) => `<button class="mu-card" data-sp-playlist="${esc(p.id)}" data-sp-uri="${esc(p.uri)}" data-sp-name="${esc(p.name)}"><span class="mu-card-art" style="background:${spArt(spImg(p), '#333')}"></span><b>${esc(p.name)}</b><span>${esc((p.owner && p.owner.display_name) || '')}</span></button>`).join('')}
            </div>
            ${recents.length ? `<h2 class="mu-h2">${esc(I18N.t('Recently Played'))}</h2>
            <div>${recents.map((t) => this.spRow(t)).join('')}</div>` : ''}`;
        this.bind(box, appId);
    },

    /** Spotify refused the request: show its reason instead of an empty library */
    spError(r) {
        const reason = (r.data && r.data.error && (r.data.error.message || r.data.error.reason)) || (typeof r.data === 'string' ? r.data : '');
        let msg = I18N.t("Spotify didn't send your library. Try again in a moment.");
        if (/premium/i.test(reason)) msg = I18N.t("Spotify is blocking this server's Spotify app: the account that owns it on developer.spotify.com needs an active Spotify Premium subscription. Ask the server owner.");
        else if (r.status === 403) msg = I18N.t("Spotify hasn't allowed your account on this server's Spotify app yet. Ask the server owner to add your Spotify email under User Management.");
        else if (r.status === 401) msg = I18N.t('Please connect Spotify again');
        return `<div class="mu-note">${esc(msg)}</div>`;
    },

    async tidalHome(box, head) {
        const [pls, favs] = await Promise.all([TidalLib.playlists(), TidalLib.page('favs')]);
        if (!box.isConnected) return;
        if (pls.status >= 400 && favs.status >= 400) {
            box.innerHTML = head + `<div class="mu-note">${esc(pls.status === 401 || favs.status === 401 ? I18N.t('Please connect TIDAL again') : I18N.t("TIDAL didn't send your library. Try again in a moment."))}</div>`;
            return;
        }
        box.innerHTML = head + `
            <h2 class="mu-h2">${esc(I18N.t('Your TIDAL'))}</h2>
            <div class="mu-shelf">
                <button class="mu-card" data-td-list="favs" data-td-name="${esc(I18N.t('My Tracks'))}"><span class="mu-card-art" style="background:linear-gradient(135deg,#0b0b10,#00c2c7)"><i class="fa-solid fa-heart"></i></span><b>${esc(I18N.t('My Tracks'))}</b><span>TIDAL</span></button>
                ${pls.list.map((p) => `<button class="mu-card" data-td-list="${esc(p.id)}" data-td-name="${esc(p.name)}"><span class="mu-card-art" style="background:${spArt(p.art, '#1c1c22')}">${p.art ? '' : '<i class="fa-solid fa-list"></i>'}</span><b>${esc(p.name)}</b><span>${esc(p.count ? p.count + ' ' + I18N.t('songs') : 'TIDAL')}</span></button>`).join('')}
            </div>
            ${favs.tracks.length ? `<h2 class="mu-h2">${esc(I18N.t('My Tracks'))}</h2><div>${favs.tracks.slice(0, 10).map((t) => this.tdRow(t)).join('')}</div>` : ''}
            <div class="mu-note">${esc(I18N.t('TIDAL does not allow playback inside other apps, so tracks open in TIDAL.'))}</div>`;
    },

    tdRow(t) {
        return `<div class="mu-row" data-tidal-track="${esc(t.id)}">
            <span class="mu-art" style="background:${spArt(t.art, '#111')};display:grid;place-items:center;color:#fff">${t.art ? '' : '<i class="fa-solid fa-water"></i>'}</span>
            <div class="grow"><div class="mu-t">${esc(t.title)}</div><div class="mu-a">${esc(t.artist || 'TIDAL')}</div></div>
            <i class="fa-solid fa-arrow-up-right-from-square" style="color:#888"></i></div>`;
    },

    async openTidalList(id, name) {
        let cursor = null, loading = false;
        UI.sheet({
            title: name,
            left: I18N.t('Done'),
            render: (body) => {
                musicSheet(body);
                const url = id === 'favs' ? 'https://tidal.com/my-collection/tracks' : `https://tidal.com/browse/playlist/${encodeURIComponent(id)}`;
                body.innerHTML = `<button class="mu-playall" data-td-open style="margin-top:6px"><i class="fa-solid fa-arrow-up-right-from-square"></i> ${esc(I18N.t('Open in TIDAL'))}</button>
                    <div class="td-list"></div><div class="spinner" style="margin:14px auto"></div>`;
                const list = $('.td-list', body), spin = $('.spinner', body);
                const more = async () => {
                    if (loading) return;
                    loading = true;
                    const pg = await TidalLib.page(id, cursor);
                    loading = false;
                    if (!body.isConnected) return;
                    list.insertAdjacentHTML('beforeend', pg.tracks.map((t) => this.tdRow(t)).join(''));
                    cursor = pg.cursor;
                    spin.style.display = cursor ? '' : 'none';
                    if (!list.children.length) list.innerHTML = `<div class="mu-none">${esc(pg.status >= 400 ? I18N.t("TIDAL didn't respond") : I18N.t('Nothing here yet'))}</div>`;
                };
                more();
                // next page when scrolled near the bottom
                body.addEventListener('scroll', () => { if (cursor && body.scrollTop + body.clientHeight > body.scrollHeight - 300) more(); }, { passive: true });
                body.addEventListener('click', (e) => {
                    if (e.target.closest('[data-td-open]')) return openExternal(url);
                    const td = e.target.closest('[data-tidal-track]');
                    if (td) openExternal(`https://tidal.com/browse/track/${encodeURIComponent(td.dataset.tidalTrack)}`);
                });
            },
        });
    },

    spRow(t, context) {
        const img = t.album && spImg(t.album);
        return `<div class="mu-row" data-sp-track="${esc(t.uri)}" ${context ? `data-sp-context="${esc(context)}"` : ''}>
            <span class="mu-art" style="background:${spArt(img, '#333')}"></span>
            <div class="grow"><div class="mu-t">${esc(t.name)}</div><div class="mu-a"><i class="fa-brands fa-spotify"></i> ${esc((t.artists || []).map((a) => a.name).join(', '))}</div></div></div>`;
    },

    async search(appId, box, q) {
        if (!box) return;
        const provider = STREAM_FOR_APP[appId];
        const st = (Streaming.status || {})[provider] || {};
        if (!st.connected || q.length < 2 || /^https?:/i.test(q)) { box.innerHTML = ''; return; }
        box.innerHTML = '<div class="spinner" style="margin:12px auto"></div>';
        if (provider === 'spotify') {
            const r = await Streaming.spotify('GET', '/v1/search', { q, type: 'track', limit: 15 });
            if (!box.isConnected) return;
            const items = (r && r.data && r.data.tracks && r.data.tracks.items) || [];
            box.innerHTML = items.length ? `<h2 class="mu-h2">Spotify</h2>${items.map((t) => this.spRow(t)).join('')}` : '';
        } else {
            const r = await TidalLib.search(q);
            if (!box.isConnected) return;
            box.innerHTML = r.tracks.length ? `<h2 class="mu-h2">TIDAL</h2>${r.tracks.map((t) => this.tdRow(t)).join('')}`
                : (r.status >= 300 ? `<div class="mu-none">${esc(I18N.t("TIDAL search isn't available for this account"))}</div>` : '');
        }
        this.bind(box, appId);
    },

    async openPlaylist(appId, id, uri, name, root) {
        const now = $('.mu-now', root);
        const r = id === 'liked' ? await Streaming.spotify('GET', '/v1/me/tracks', { limit: 50 }) : await Streaming.spotify('GET', `/v1/playlists/${id}/tracks`, { limit: 50 });
        const items = ((r && r.data && r.data.items) || []).map((x) => x.track).filter((t) => t && t.uri && t.type === 'track');
        UI.sheet({
            title: name,
            left: I18N.t('Done'),
            render: (body) => {
                musicSheet(body);
                body.innerHTML = items.length
                    ? `<button class="mu-playall" data-sp-playall style="margin-top:6px"><i class="fa-solid fa-play"></i> ${esc(I18N.t('Play'))}</button>${items.map((t) => this.spRow(t, id === 'liked' ? null : uri)).join('')}`
                    : `<div class="mu-none">${esc(I18N.t('Nothing here yet'))}</div>`;
                body.addEventListener('click', async (e) => {
                    const row = e.target.closest('[data-sp-track]');
                    const all = e.target.closest('[data-sp-playall]');
                    if (!row && !all) return;
                    const ok = id === 'liked'
                        ? await SpotifyRemote.play({ uris: items.map((t) => t.uri).slice(row ? items.findIndex((t) => t.uri === row.dataset.spTrack) : 0).slice(0, 50) })
                        : await SpotifyRemote.play({ context: uri, offset: row ? row.dataset.spTrack : undefined });
                    if (ok) Phone.emit('streamOpenNow');
                });
            },
        });
    },

    bind(box, appId) {
        if (box._bound) return;
        box._bound = true;
        box.addEventListener('click', async (e) => {
            const c = e.target.closest('[data-stream-connect]');
            if (c) return Streaming.connect(c.dataset.streamConnect);
            const d = e.target.closest('[data-stream-disconnect]');
            if (d) { if (await Streaming.disconnect(d.dataset.streamDisconnect)) this.home(appId, box); return; }
            const pl = e.target.closest('[data-sp-playlist]');
            if (pl) return this.openPlaylist(appId, pl.dataset.spPlaylist, pl.dataset.spUri, pl.dataset.spName, box.closest('.mu'));
            if (e.target.closest('[data-sp-liked]')) return this.openPlaylist(appId, 'liked', null, I18N.t('Liked Songs'), box.closest('.mu'));
            const tr = e.target.closest('[data-sp-track]');
            if (tr) {
                const ok = tr.dataset.spContext ? await SpotifyRemote.play({ context: tr.dataset.spContext, offset: tr.dataset.spTrack }) : await SpotifyRemote.play({ uris: [tr.dataset.spTrack] });
                if (ok) Phone.emit('streamOpenNow');
                return;
            }
            const tl = e.target.closest('[data-td-list]');
            if (tl) return this.openTidalList(tl.dataset.tdList, tl.dataset.tdName);
            const td = e.target.closest('[data-tidal-track]');
            if (td) openExternal(`https://tidal.com/browse/track/${encodeURIComponent(td.dataset.tidalTrack)}`);
        });
    },
};
