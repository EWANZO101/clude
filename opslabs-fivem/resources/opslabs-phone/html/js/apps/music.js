'use strict';

/* =====================================================================
   Music — one playback engine shared by the music apps, Control Center,
   the lock screen and the Dynamic Island.
   Plays direct audio links (mp3/ogg/aac/m4a), internet radio streams and
   YouTube links (via the YouTube IFrame API). Audio is local to the player.
   ===================================================================== */

const YT_RE = /(?:youtube\.com\/(?:watch\?v=|shorts\/|embed\/)|youtu\.be\/)([\w-]{11})/i;
const ytId = (url) => { const m = String(url || '').match(YT_RE); return m ? m[1] : null; };

function trackHue(t) {
    let h = 0;
    const s = (t.title || '') + (t.artist || '');
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
    return h;
}
/** album art as a css background (generated gradient when there is no cover) */
function artBg(t) {
    if (!t) return '#333';
    if (t.art && /^(https?:|data:image\/)/.test(t.art)) return `url('${cssUrl(t.art)}') center/cover`;
    if (t.kind === 'youtube' && t.url && ytId(t.url)) return `url('https://i.ytimg.com/vi/${ytId(t.url)}/hqdefault.jpg') center/cover`;
    const h = trackHue(t);
    return `linear-gradient(135deg, hsl(${h} 70% 55%), hsl(${(h + 50) % 360} 75% 35%))`;
}

const Music = {
    audio: null,
    yt: null,
    _ytReady: null,
    queue: [],
    index: -1,
    track: null,
    app: null,
    playing: false,
    loading: false,
    shuffle: false,
    repeat: 'off',   // off | all | one
    _resumeAfterCall: false,
    _timer: null,

    remote: null,   // { provider, progress, duration, at } while controlling Spotify Connect

    get position() {
        if (!this.track) return 0;
        if (this.remote) return Math.min(this.remote.duration, this.remote.progress + (this.playing ? (Date.now() - this.remote.at) / 1000 : 0));
        if (this.track.kind === 'youtube') return this.yt && this.yt.getCurrentTime ? this.yt.getCurrentTime() || 0 : 0;
        return this.audio ? this.audio.currentTime || 0 : 0;
    },
    get duration() {
        if (this.remote) return this.remote.duration || Infinity;
        if (!this.track || this.track.kind === 'radio') return Infinity;
        if (this.track.kind === 'youtube') return this.yt && this.yt.getDuration ? this.yt.getDuration() || 0 : 0;
        const d = this.audio ? this.audio.duration : 0;
        return isFinite(d) ? d : Infinity;
    },
    get isLive() { return !isFinite(this.duration); },

    volume() { return Math.max(0, Math.min(1, Phone.settings.volume ?? 0.7)); },
    setVolume(v) {
        if (this.audio) this.audio.volume = v;
        if (this.yt && this.yt.setVolume) this.yt.setVolume(Math.round(v * 100));
    },

    _audio() {
        if (this.audio) return this.audio;
        const a = new Audio();
        a.preload = 'auto';
        a.addEventListener('playing', () => { this.loading = false; this.playing = true; this._emit(); });
        a.addEventListener('pause', () => { this.playing = false; this._emit(); });
        a.addEventListener('waiting', () => { this.loading = true; this._emit(); });
        a.addEventListener('ended', () => this._ended());
        a.addEventListener('error', () => this._failed());
        this.audio = a;
        return a;
    },

    _loadYT() {
        if (this._ytReady) return this._ytReady;
        this._ytReady = new Promise((resolve) => {
            if (window.YT && window.YT.Player) return resolve(true);
            const prev = window.onYouTubeIframeAPIReady;
            window.onYouTubeIframeAPIReady = () => { if (prev) prev(); resolve(true); };
            const s = document.createElement('script');
            s.src = 'https://www.youtube.com/iframe_api';
            s.onerror = () => resolve(false);
            document.head.appendChild(s);
            setTimeout(() => resolve(!!(window.YT && window.YT.Player)), 10000);
        });
        return this._ytReady;
    },

    async _playYT(id) {
        const ok = await this._loadYT();
        if (!ok) return this._failed();
        if (!document.getElementById('yt-host')) {
            const host = document.createElement('div');
            host.id = 'yt-wrap';
            host.innerHTML = '<div id="yt-host"></div>';
            document.body.appendChild(host);
        }
        if (this.yt && this.yt.loadVideoById) {
            this.yt.loadVideoById(id);
            this.yt.setVolume(Math.round(this.volume() * 100));
            return;
        }
        this.yt = new YT.Player('yt-host', {
            width: 200, height: 200, videoId: id,
            playerVars: { autoplay: 1, controls: 0, playsinline: 1, disablekb: 1, modestbranding: 1 },
            events: {
                onReady: (e) => { e.target.setVolume(Math.round(this.volume() * 100)); e.target.playVideo(); },
                onStateChange: (e) => {
                    const S = YT.PlayerState;
                    if (e.data === S.PLAYING) {
                        this.loading = false; this.playing = true;
                        // fill in the title from YouTube for links added without one
                        const d = e.target.getVideoData && e.target.getVideoData();
                        if (d && d.title && this.track && (!this.track.title || this.track.title === 'Untitled')) {
                            this.track.title = d.title;
                            if (!this.track.artist && d.author) this.track.artist = d.author;
                            if (this.track.id) rpc('musicUpdate', { id: this.track.id, title: d.title });
                        }
                        this._emit();
                    } else if (e.data === S.PAUSED) { this.playing = false; this._emit(); }
                    else if (e.data === S.BUFFERING) { this.loading = true; this._emit(); }
                    else if (e.data === S.ENDED) this._ended();
                },
                onError: () => this._failed(),
            },
        });
    },

    _stopAll() {
        if (this.audio) { this.audio.pause(); this.audio.removeAttribute('src'); this.audio.load(); }
        if (this.yt && this.yt.stopVideo) this.yt.stopVideo();
    },

    /** play a track; queue = the list it came from (for next/previous) */
    play(track, queue, app) {
        if (!track) return;
        if (this.remote) SpotifyRemote.detach();
        this.queue = (queue && queue.length ? queue : [track]).slice();
        this.index = Math.max(0, this.queue.findIndex((t) => t === track || (t.url === track.url && t.title === track.title)));
        this.app = app || this.app;
        this._start();
    },
    _start() {
        const t = this.queue[this.index];
        if (!t) return;
        this.track = { ...t, kind: t.kind || (ytId(t.url) ? 'youtube' : 'track') };
        this.loading = true;
        this.playing = true;
        this._stopAll();
        if (this.track.kind === 'youtube') this._playYT(ytId(this.track.url));
        else {
            const a = this._audio();
            a.src = this.track.url;
            a.volume = this.volume();
            a.play().catch(() => this._failed());
        }
        this._tick();
        this._emit();
    },
    _failed() {
        if (!this.track) return;
        this.loading = false;
        this.playing = false;
        UI.toast(I18N.t("Couldn't play this song"), 'fa-solid fa-circle-exclamation');
        this._emit();
    },
    _ended() {
        if (this.repeat === 'one') return this._start();
        if (this.index < this.queue.length - 1 || this.repeat === 'all' || this.shuffle) return this.next();
        this.playing = false;
        this._emit();
    },

    toggle() { this.playing ? this.pause() : this.resume(); },
    pause() {
        if (this.remote) return SpotifyRemote.pause();
        if (!this.track) return;
        if (this.track.kind === 'youtube') this.yt && this.yt.pauseVideo && this.yt.pauseVideo();
        else if (this.audio) this.audio.pause();
        this.playing = false;
        this._emit();
    },
    resume() {
        if (this.remote) return SpotifyRemote.resume();
        if (!this.track) return;
        if (this.track.kind === 'youtube') { if (this.yt && this.yt.playVideo) this.yt.playVideo(); else this._start(); }
        else if (this.audio && this.audio.src) {
            // radio: jump back to live instead of resuming stale buffer
            if (this.track.kind === 'radio') { this.audio.src = this.track.url; }
            this.audio.play().catch(() => this._failed());
        } else this._start();
        this.playing = true;
        this._tick();
        this._emit();
    },
    next() {
        if (this.remote) return SpotifyRemote.next();
        if (!this.queue.length) return;
        if (this.shuffle && this.queue.length > 1) {
            let i; do { i = Math.floor(Math.random() * this.queue.length); } while (i === this.index);
            this.index = i;
        } else this.index = (this.index + 1) % this.queue.length;
        this._start();
    },
    prev() {
        if (this.remote) return SpotifyRemote.prev();
        if (!this.queue.length) return;
        if (this.position > 3 && !this.isLive) return this.seek(0);
        this.index = (this.index - 1 + this.queue.length) % this.queue.length;
        this._start();
    },
    seek(sec) {
        if (this.remote) return SpotifyRemote.seek(sec);
        if (!this.track || this.isLive) return;
        if (this.track.kind === 'youtube') this.yt && this.yt.seekTo && this.yt.seekTo(sec, true);
        else if (this.audio) this.audio.currentTime = sec;
        this._emit();
    },
    stop() {
        this._stopAll();
        this.track = null; this.playing = false; this.queue = []; this.index = -1;
        this._emit();
    },

    _tick() {
        clearInterval(this._timer);
        this._timer = setInterval(() => {
            if (!this.track) return clearInterval(this._timer);
            Phone.emit('musicProgress');
        }, 500);
    },
    _emit() {
        Phone.emit('music');
        musicSyncSystem();
    },
};

const fmtTrackTime = (s) => (isFinite(s) && s >= 0 ? `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}` : '');
const musicAppName = (id) => (Apps.byId[id] && Apps.byId[id].name) || 'Music';

/* ---------------------------------------------------------------------
   system surfaces: Dynamic Island, lock screen, Control Center
   --------------------------------------------------------------------- */

function musicSyncSystem() {
    const t = Music.track;
    const accent = Music.app === 'tide' ? '#33ffe7' : '#1ed760';
    if (!t) {
        Island.end('music');
    } else {
        Island.start('music', {
            priority: 50,
            compact: () => ({
                left: `<span class="isl-art" style="background:${artBg(Music.track)}"></span>`,
                right: `<span class="isl-eq ${Music.playing ? '' : 'paused'}" style="color:${accent}"><i></i><i></i><i></i><i></i></span>`,
            }),
            minimal: () => `<span class="isl-art" style="background:${artBg(Music.track)}"></span>`,
            expanded: () => {
                const tr = Music.track;
                if (!tr) return '';
                const d = Music.duration, p = Music.position;
                return `
                    <div class="isl-row">
                        <span class="isl-art big" style="background:${artBg(tr)}"></span>
                        <div class="grow"><div class="isl-title">${esc(tr.title || 'Untitled')}</div><div class="isl-cap">${esc(tr.artist || musicAppName(Music.app))}</div></div>
                        <span class="isl-eq ${Music.playing ? '' : 'paused'}" style="color:${accent}"><i></i><i></i><i></i><i></i></span>
                    </div>
                    ${isFinite(d) && d > 0 ? `<div class="isl-progress"><i style="width:${Math.min(100, (p / d) * 100)}%"></i></div><div class="isl-times"><span>${fmtTrackTime(p)}</span><span>-${fmtTrackTime(d - p)}</span></div>`
                        : '<div class="isl-times" style="margin-top:10px"><span>LIVE</span><span></span></div>'}
                    <div class="isl-ctrls">
                        <button data-isl-act="prev"><i class="fa-solid fa-backward"></i></button>
                        <button data-isl-act="toggle"><i class="fa-solid ${Music.playing ? 'fa-pause' : 'fa-play'}"></i></button>
                        <button data-isl-act="next"><i class="fa-solid fa-forward"></i></button>
                    </div>`;
            },
            onTap: () => Music.app && Phone.openApp(Music.app, { nowPlaying: true }),
            onAction: (act) => { if (Music[act]) Music[act](); Island.render(true); },
        });
    }
    renderLockMusic();
    if ($('#control-center').classList.contains('open')) renderControlCenter();
}

function renderLockMusic() {
    let w = $('#ls-music');
    const t = Music.track;
    if (!t) { if (w) w.remove(); return; }
    if (!w) {
        w = el('<div class="ls-music" id="ls-music"></div>');
        $('#ls-notifs').before(w);
        w.addEventListener('click', (e) => {
            const b = e.target.closest('[data-mu]');
            if (b) { e.stopPropagation(); Music[b.dataset.mu](); }
        });
    }
    const d = Music.duration, p = Music.position;
    w.innerHTML = `
        <div class="lsm-top"><span class="lsm-art" style="background:${artBg(t)}"></span>
            <div class="grow"><div class="lsm-title">${esc(t.title || 'Untitled')}</div><div class="lsm-artist">${esc(t.artist || musicAppName(Music.app))}</div></div></div>
        <div class="lsm-bar"><i style="width:${isFinite(d) && d > 0 ? Math.min(100, (p / d) * 100) : 100}%"></i></div>
        <div class="lsm-ctrls"><button data-mu="prev"><i class="fa-solid fa-backward"></i></button>
            <button data-mu="toggle"><i class="fa-solid ${Music.playing ? 'fa-pause' : 'fa-play'}"></i></button>
            <button data-mu="next"><i class="fa-solid fa-forward"></i></button></div>`;
}

Phone.on('musicProgress', () => {
    if (Phone.state === 'open' && Phone.locked) renderLockMusic();
    if (Island.expandedId === 'music') Island.render(true);
});
// pause for calls, resume afterwards (like a real phone)
Phone.on('incomingCall', () => { if (Music.playing) { Music._resumeAfterCall = true; Music.pause(); } });
Phone.on('callFinished', () => { if (Music._resumeAfterCall) { Music._resumeAfterCall = false; Music.resume(); } });
Phone.on('settings', (d) => { if (d && d.key === 'volume') Music.setVolume(Music.volume()); });
Phone.on('reset', () => Music.stop());

/* ---------------------------------------------------------------------
   the apps
   --------------------------------------------------------------------- */

const MUSIC_THEMES = {
    soundwave: { accent: '#1ed760', name: 'Soundwave', cls: 'mu-sw' },
    tide: { accent: '#33ffe7', name: 'Tide', cls: 'mu-tide' },
};

function stationTracks() {
    return ((Phone.config.music && Phone.config.music.Stations) || []).map((s, i) => ({ ...s, kind: 'radio', station: i }));
}

function MusicAddSheet(appId, onDone, preset = {}) {
    UI.sheet({
        title: I18N.t('Add to Library'),
        right: I18N.t('Add'),
        render(body, api) {
            body.innerHTML = `
                <div class="group" style="margin-top:6px">
                    <div class="row"><span class="lbl">${esc(I18N.t('Link'))}</span><input class="field" data-f="url" placeholder="https:// (mp3, radio or YouTube)" value="${esc(preset.url || '')}"></div>
                </div>
                <div class="group">
                    <div class="row"><span class="lbl">${esc(I18N.t('Title'))}</span><input class="field" data-f="title" placeholder="${esc(I18N.t('Optional for YouTube'))}"></div>
                    <div class="row"><span class="lbl">${esc(I18N.t('Artist'))}</span><input class="field" data-f="artist"></div>
                    <div class="row"><span class="lbl">${esc(I18N.t('Cover'))}</span><input class="field" data-f="art" placeholder="https:// (optional)"></div>
                    <div class="row"><span class="lbl">${esc(I18N.t('Playlist'))}</span><input class="field" data-f="playlist" placeholder="${esc(I18N.t('Optional'))}" value="${esc(preset.playlist || '')}"></div>
                </div>
                <div class="group">
                    <div class="row"><div class="grow">${esc(I18N.t('Live radio stream'))}</div>${UI.switchHtml(false, 'data-f="radio"')}</div>
                </div>
                <div class="group-footer">${esc(I18N.t('Paste a direct audio link (.mp3, .ogg, .m4a), an internet radio stream or a YouTube link.'))}</div>`;
            const check = () => api.setRightEnabled(/^https?:\/\//.test($('[data-f=url]', body).value.trim()));
            body.addEventListener('input', check);
            check();
            setTimeout(() => $('[data-f=url]', body).focus(), 350);
        },
        async onRight(api) {
            const v = (f) => $(`[data-f=${f}]`, api.body).value.trim();
            const url = v('url');
            const kind = ytId(url) ? 'youtube' : $('[data-f=radio]', api.body).checked ? 'radio' : 'track';
            const res = await rpc('musicAdd', { app: appId, url, title: v('title'), artist: v('artist'), art: v('art'), playlist: v('playlist'), kind });
            if (!res || res.error) return UI.alert({ title: (res && res.error) || "Couldn't add" });
            api.close();
            UI.toast(I18N.t('Added to Library'), 'fa-solid fa-circle-check');
            onDone && onDone();
        },
    });
}

function registerMusicApp(id) {
    const theme = MUSIC_THEMES[id];
    Apps.register({
        id,
        get name() { return (Phone.config.music && Phone.config.music.Apps && Phone.config.music.Apps[id] && Phone.config.music.Apps[id].name) || theme.name; },
        dark: true,
        splash: '#000',
        defaultInstalled: false,
        icon: id === 'soundwave'
            ? { bg: 'linear-gradient(160deg,#1ed760,#0f8f3e)', html: () => `<svg viewBox="0 0 64 64" width="40" height="40" fill="none" stroke="#08130b" stroke-width="4.6" stroke-linecap="round"><path d="M14 24c12-4 26-3 37 3"/><path d="M17 33c10-3 21-2 30 3"/><path d="M20 41.5c8-2 16-1.5 23 2"/></svg>` }
            : { bg: '#000', html: () => `<svg viewBox="0 0 64 64" width="44" height="44" fill="#fff"><path d="M14 22l6-6 6 6-6 6zM26 22l6-6 6 6-6 6zM38 22l6-6 6 6-6 6zM26 34l6-6 6 6-6 6z"/></svg>` },
        open(root, params, app) {
            let tab = 'home';
            let lib = [];
            root.innerHTML = `
                <div class="mu ${theme.cls}" style="--mu-accent:${theme.accent}">
                    <div class="mu-page scroll"></div>
                    <div class="mu-mini hidden"></div>
                    <div class="mu-tabs">
                        <button data-tab="home" class="on"><i class="fa-solid fa-house"></i><span>${esc(I18N.t('Home'))}</span></button>
                        <button data-tab="search"><i class="fa-solid fa-magnifying-glass"></i><span>${esc(I18N.t('Search'))}</span></button>
                        <button data-tab="library"><i class="fa-solid fa-lines-leaning"></i><span>${esc(I18N.t('Your Library'))}</span></button>
                    </div>
                    <div class="mu-now"></div>
                </div>`;
            const page = $('.mu-page', root), mini = $('.mu-mini', root), now = $('.mu-now', root);
            swipeRows(page, '.mu-row[data-id]', { label: 'Remove', onDelete: async (row) => { await rpc('musicDelete', { id: +row.dataset.id }); await loadLib(); draw(); } });

            const loadLib = async () => { lib = (await rpc('musicLibrary', { app: id })) || []; };
            const trackRow = (t, list, i) => `
                <div class="mu-row ${Music.track && Music.track.url === t.url ? 'playing' : ''}" data-play="${i}" data-list="${list}" ${t.id ? `data-id="${t.id}"` : ''}>
                    <span class="mu-art" style="background:${artBg(t)}"></span>
                    <div class="grow"><div class="mu-t">${esc(t.title || 'Untitled')}</div><div class="mu-a">${t.kind === 'radio' ? '<span class="mu-live">LIVE</span>' : ''}${t.kind === 'youtube' ? '<i class="fa-brands fa-youtube"></i> ' : ''}${esc(t.artist || '')}</div></div>
                    ${t.id ? `<button class="mu-more" data-more="${t.id}"><i class="fa-solid fa-ellipsis"></i></button>` : ''}
                </div>`;
            const lists = { stations: () => stationTracks(), lib: () => lib, liked: () => lib.filter((t) => t.liked), search: () => [] };
            let searchResults = [];
            lists.search = () => searchResults;

            const greeting = () => {
                const h = new Date().getHours();
                return I18N.t(h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening');
            };

            const drawHome = () => {
                const st = stationTracks();
                const recent = lib.slice(0, 10);
                page.innerHTML = `
                    <div class="mu-head"><h1>${esc(greeting())}</h1><button class="mu-icon-btn" data-act="add"><i class="fa-solid fa-plus"></i></button></div>
                    <div class="mu-stream" data-stream-home></div>
                    <div class="mu-quick">
                        <button class="mu-q" data-tab="liked"><span class="mu-q-art liked"><i class="fa-solid fa-heart"></i></span><b>${esc(I18N.t('Liked Songs'))}</b></button>
                        ${st.slice(0, 5).map((t, i) => `<button class="mu-q" data-play="${i}" data-list="stations"><span class="mu-q-art" style="background:${artBg(t)}"></span><b>${esc(t.title)}</b></button>`).join('')}
                    </div>
                    ${recent.length ? `<h2 class="mu-h2">${esc(I18N.t('Recently Added'))}</h2>
                    <div class="mu-shelf">${recent.map((t, i) => `<button class="mu-card" data-play="${i}" data-list="lib"><span class="mu-card-art" style="background:${artBg(t)}"></span><b>${esc(t.title || 'Untitled')}</b><span>${esc(t.artist || '')}</span></button>`).join('')}</div>` : `
                    <div class="mu-empty"><i class="fa-solid fa-music"></i><b>${esc(I18N.t('Build your library'))}</b><span>${esc(I18N.t('Add songs from a link, an internet radio stream or YouTube.'))}</span><button class="mu-pill" data-act="add">${esc(I18N.t('Add a Song'))}</button></div>`}
                    <h2 class="mu-h2">${esc(I18N.t('Radio Stations'))}</h2>
                    <div class="mu-grid">${st.map((t, i) => `<button class="mu-card" data-play="${i}" data-list="stations"><span class="mu-card-art" style="background:${artBg(t)}"><i class="fa-solid fa-tower-broadcast"></i></span><b>${esc(t.title)}</b><span>${esc(t.artist)}</span></button>`).join('')}</div>`;
            };
            const drawSearch = (q = '') => {
                page.innerHTML = `
                    <div class="mu-head"><h1>${esc(I18N.t('Search'))}</h1></div>
                    <div class="mu-search"><i class="fa-solid fa-magnifying-glass"></i><input placeholder="${esc(I18N.t('What do you want to listen to?'))}" value="${esc(q)}"></div>
                    <div class="mu-stream-results"></div>
                    <div class="mu-results"></div>
                    <button class="mu-add-row" data-act="add"><span><i class="fa-solid fa-link"></i></span><div><b>${esc(I18N.t('Add from a link'))}</b><small>${esc(I18N.t('mp3, radio stream or YouTube'))}</small></div></button>`;
                const inp = $('input', page);
                const run = () => {
                    const qq = inp.value.trim().toLowerCase();
                    // pasting a link offers to add it straight away
                    if (/^https?:\/\//.test(inp.value.trim())) {
                        searchResults = [];
                        $('.mu-results', page).innerHTML = `<button class="mu-add-row" data-act="addlink"><span><i class="fa-solid fa-plus"></i></span><div><b>${esc(I18N.t('Add this link'))}</b><small>${esc(inp.value.trim())}</small></div></button>`;
                        return;
                    }
                    searchResults = qq ? [...stationTracks(), ...lib].filter((t) => ((t.title || '') + ' ' + (t.artist || '')).toLowerCase().includes(qq)) : [];
                    $('.mu-results', page).innerHTML = searchResults.map((t, i) => trackRow(t, 'search', i)).join('') || (qq ? `<div class="mu-none">${esc(I18N.t('No results'))}</div>` : '');
                };
                const runStream = debounce(() => StreamUI.search(id, $('.mu-stream-results', page), inp.value.trim()), 350);
                inp.addEventListener('input', () => { run(); runStream(); });
                run();
                setTimeout(() => inp.focus(), 50);
            };
            let libFilter = 'all';
            const drawLibrary = () => {
                const pls = [...new Set(lib.map((t) => t.playlist).filter(Boolean))];
                const items = libFilter === 'liked' ? lib.filter((t) => t.liked) : libFilter === 'all' ? lib : lib.filter((t) => t.playlist === libFilter);
                lists.view = () => items;
                page.innerHTML = `
                    <div class="mu-head"><h1>${esc(I18N.t('Your Library'))}</h1><button class="mu-icon-btn" data-act="add"><i class="fa-solid fa-plus"></i></button></div>
                    <div class="mu-chips">
                        <button data-filter="all" class="${libFilter === 'all' ? 'on' : ''}">${esc(I18N.t('All'))}</button>
                        <button data-filter="liked" class="${libFilter === 'liked' ? 'on' : ''}"><i class="fa-solid fa-heart"></i> ${esc(I18N.t('Liked'))}</button>
                        ${pls.map((p) => `<button data-filter="${esc(p)}" class="${libFilter === p ? 'on' : ''}">${esc(p)}</button>`).join('')}
                    </div>
                    ${items.length ? `<button class="mu-playall" data-act="playall"><i class="fa-solid fa-play"></i> ${esc(I18N.t('Play'))}</button><button class="mu-playall ghost" data-act="shuffleall"><i class="fa-solid fa-shuffle"></i> ${esc(I18N.t('Shuffle'))}</button>` : ''}
                    <div>${items.map((t, i) => trackRow(t, 'view', i)).join('') || `<div class="mu-none">${esc(I18N.t('Nothing here yet'))}</div>`}</div>`;
            };
            const draw = () => {
                $$('.mu-tabs [data-tab]', root).forEach((b) => b.classList.toggle('on', b.dataset.tab === tab || (tab === 'liked' && b.dataset.tab === 'library')));
                if (tab === 'home') { drawHome(); StreamUI.home(id, $('[data-stream-home]', page)); }
                else if (tab === 'search') drawSearch();
                else drawLibrary();
            };

            /* ---- mini player + now playing ---- */
            const drawMini = () => {
                const t = Music.track;
                mini.classList.toggle('hidden', !t || Music.app !== id);
                if (!t || Music.app !== id) return;
                const d = Music.duration, p = Music.position;
                mini.innerHTML = `
                    <span class="mu-art" style="background:${artBg(t)}"></span>
                    <div class="grow" data-act="now"><div class="mu-t">${esc(t.title || 'Untitled')}</div><div class="mu-a">${esc(t.artist || '')}</div></div>
                    <button data-mu="toggle"><i class="fa-solid ${Music.loading ? 'fa-spinner fa-spin' : Music.playing ? 'fa-pause' : 'fa-play'}"></i></button>
                    <button data-mu="next"><i class="fa-solid fa-forward"></i></button>
                    <i class="mu-mini-bar" style="width:${isFinite(d) && d > 0 ? (p / d) * 100 : 0}%"></i>`;
            };
            const drawNow = () => {
                const t = Music.track;
                if (!t) { now.classList.remove('show'); return; }
                const d = Music.duration, p = Music.position;
                const inLib = lib.find((x) => x.url === t.url);
                now.innerHTML = `
                    <div class="mn-bg" style="background:${artBg(t)}"></div>
                    <div class="mn-top"><button data-act="closenow"><i class="fa-solid fa-chevron-down"></i></button><span>${esc(t.kind === 'radio' ? I18N.t('Live Radio') : musicAppName(id))}</span><button data-act="share"><i class="fa-solid fa-arrow-up-from-bracket"></i></button></div>
                    <div class="mn-art" style="background:${artBg(t)}">${t.kind === 'radio' ? '<i class="fa-solid fa-tower-broadcast"></i>' : ''}</div>
                    <div class="mn-info"><div class="grow"><div class="mn-title">${esc(t.title || 'Untitled')}</div><div class="mn-artist">${esc(t.artist || '')}</div></div>
                        ${inLib ? `<button class="mn-like ${inLib.liked ? 'on' : ''}" data-like="${inLib.id}"><i class="fa-${inLib.liked ? 'solid' : 'regular'} fa-heart"></i></button>` : ''}</div>
                    <div class="mn-seek ${isFinite(d) && d > 0 ? '' : 'live'}"><div class="mn-seek-bar"><i style="width:${isFinite(d) && d > 0 ? (p / d) * 100 : 100}%"></i><b style="left:${isFinite(d) && d > 0 ? (p / d) * 100 : 100}%"></b></div>
                        <div class="mn-times"><span>${isFinite(d) && d > 0 ? fmtTrackTime(p) : '<span class="mu-live">LIVE</span>'}</span><span>${isFinite(d) && d > 0 ? '-' + fmtTrackTime(d - p) : ''}</span></div></div>
                    <div class="mn-ctrls">
                        <button data-mu="shuffle" class="${Music.shuffle ? 'on' : ''}"><i class="fa-solid fa-shuffle"></i></button>
                        <button data-mu="prev"><i class="fa-solid fa-backward-step"></i></button>
                        <button data-mu="toggle" class="mn-play"><i class="fa-solid ${Music.loading ? 'fa-spinner fa-spin' : Music.playing ? 'fa-pause' : 'fa-play'}"></i></button>
                        <button data-mu="next"><i class="fa-solid fa-forward-step"></i></button>
                        <button data-mu="repeat" class="${Music.repeat !== 'off' ? 'on' : ''}"><i class="fa-solid fa-repeat"></i>${Music.repeat === 'one' ? '<small>1</small>' : ''}</button>
                    </div>
                    <div class="mn-vol"><i class="fa-solid fa-volume-low"></i><input type="range" class="slider" min="0" max="100" value="${Math.round(Music.volume() * 100)}" data-vol><i class="fa-solid fa-volume-high"></i></div>`;
            };
            const openNow = () => { if (!Music.track) return; drawNow(); now.classList.add('show'); };
            const closeNow = () => now.classList.remove('show');

            // seek by dragging the progress bar
            now.addEventListener('pointerdown', (e) => {
                const bar = e.target.closest('.mn-seek-bar');
                if (!bar || Music.isLive) return;
                const seekTo = (ev) => {
                    const r = bar.getBoundingClientRect();
                    const k = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
                    Music.seek(k * Music.duration);
                };
                seekTo(e);
                const move = (ev) => seekTo(ev);
                const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
                window.addEventListener('pointermove', move);
                window.addEventListener('pointerup', up);
            });
            drag($('.mu-now', root), {
                onStart: (e) => !e.target.closest('.mn-seek-bar, input, button'),
                onEnd: (_dx, dy, vy, _vx, _e, moved) => { if (moved && (dy > 90 || vy > 0.6)) closeNow(); },
            });
            now.addEventListener('input', (e) => {
                if (e.target.dataset.vol !== undefined) {
                    const v = +e.target.value / 100;
                    Phone.settings.volume = v;
                    Sound.setVolume(v);
                    Music.setVolume(v);
                }
            });
            now.addEventListener('change', (e) => { if (e.target.dataset.vol !== undefined) Phone.saveSetting('volume', +e.target.value / 100); });

            /* ---- clicks ---- */
            root.addEventListener('click', async (e) => {
                const mu = e.target.closest('[data-mu]');
                if (mu) {
                    e.stopPropagation();
                    const a = mu.dataset.mu;
                    if (a === 'shuffle') Music.shuffle = !Music.shuffle;
                    else if (a === 'repeat') Music.repeat = Music.repeat === 'off' ? 'all' : Music.repeat === 'all' ? 'one' : 'off';
                    else Music[a]();
                    if (a === 'shuffle' || a === 'repeat') Music._emit();
                    return;
                }
                const tb = e.target.closest('.mu-tabs [data-tab], .mu-q[data-tab]');
                if (tb) {
                    tab = tb.dataset.tab === 'liked' ? 'library' : tb.dataset.tab;
                    if (tb.dataset.tab === 'liked') libFilter = 'liked';
                    return draw();
                }
                const pl = e.target.closest('[data-play]');
                if (pl && !e.target.closest('[data-more]')) {
                    const list = (lists[pl.dataset.list] || (() => []))();
                    const t = list[+pl.dataset.play];
                    if (t) { Music.play(t, list, id); openNow(); }
                    return;
                }
                const f = e.target.closest('[data-filter]');
                if (f) { libFilter = f.dataset.filter; return drawLibrary(); }
                const more = e.target.closest('[data-more]');
                if (more) {
                    const t = lib.find((x) => x.id === +more.dataset.more);
                    if (!t) return;
                    const i = await UI.actionSheet(t.title, [
                        { label: t.liked ? I18N.t('Remove from Liked Songs') : I18N.t('Add to Liked Songs') },
                        { label: I18N.t('Add to Playlist…') },
                        { label: I18N.t('Share') },
                        { label: I18N.t('Remove from Library'), destructive: true },
                    ]);
                    if (i === 0) { await rpc('musicUpdate', { id: t.id, liked: !t.liked }); }
                    if (i === 1) {
                        const name = await UI.prompt(I18N.t('Playlist'), '', { value: t.playlist || '' });
                        if (name === null) return;
                        await rpc('musicUpdate', { id: t.id, playlist: name });
                    }
                    if (i === 2) {
                        const c = await pickContact('Share');
                        if (c) { await rpc('sendMessage', { number: c.number, message: `🎵 ${t.title}${t.artist ? ' — ' + t.artist : ''}\n${t.url}` }); UI.toast('Sent to ' + c.name); }
                    }
                    if (i === 3) await rpc('musicDelete', { id: t.id });
                    if (i !== null) { await loadLib(); draw(); }
                    return;
                }
                const like = e.target.closest('[data-like]');
                if (like) {
                    const t = lib.find((x) => x.id === +like.dataset.like);
                    if (t) { t.liked = !t.liked; await rpc('musicUpdate', { id: t.id, liked: t.liked }); drawNow(); }
                    return;
                }
                const a = e.target.closest('[data-act]');
                if (!a) return;
                switch (a.dataset.act) {
                    case 'add': return MusicAddSheet(id, async () => { await loadLib(); draw(); });
                    case 'addlink': return MusicAddSheet(id, async () => { await loadLib(); draw(); }, { url: $('.mu-search input', page).value.trim() });
                    case 'now': return openNow();
                    case 'closenow': return closeNow();
                    case 'playall': { const l = lists.view(); if (l.length) { Music.shuffle = false; Music.play(l[0], l, id); openNow(); } return; }
                    case 'shuffleall': { const l = lists.view(); if (l.length) { Music.shuffle = true; Music.play(l[Math.floor(Math.random() * l.length)], l, id); openNow(); } return; }
                    case 'share': {
                        const t = Music.track;
                        const c = t && (await pickContact('Share'));
                        if (c) { await rpc('sendMessage', { number: c.number, message: `🎵 ${t.title}${t.artist ? ' — ' + t.artist : ''}\n${t.url}` }); UI.toast('Sent to ' + c.name); }
                        return;
                    }
                }
            });

            app.on('music', () => {
                drawMini();
                if (now.classList.contains('show')) drawNow();
                $$('.mu-row', page).forEach((r) => {
                    const list = (lists[r.dataset.list] || (() => []))();
                    const t = list[+r.dataset.play];
                    r.classList.toggle('playing', !!(t && Music.track && Music.track.url === t.url));
                });
            });
            app.on('musicProgress', () => {
                drawMini();
                if (now.classList.contains('show')) {
                    const d = Music.duration, p = Music.position;
                    if (isFinite(d) && d > 0) {
                        const bar = $('.mn-seek-bar i', now), dot = $('.mn-seek-bar b', now), times = $$('.mn-times > span', now);
                        if (bar) bar.style.width = (p / d) * 100 + '%';
                        if (dot) dot.style.left = (p / d) * 100 + '%';
                        if (times[0]) times[0].textContent = fmtTrackTime(p);
                        if (times[1]) times[1].textContent = '-' + fmtTrackTime(d - p);
                    }
                }
            });
            app.openNow = openNow;
            app.on('oauthConnected', async () => { await Streaming.refresh(); draw(); });
            app.on('streamOpenNow', () => openNow());

            draw();
            drawMini();
            loadLib().then(() => { draw(); if (params.nowPlaying) openNow(); });
        },
        onParams(params, app) { if (params.nowPlaying && app.openNow) app.openNow(); },
    });
}

registerMusicApp('soundwave');
registerMusicApp('tide');
