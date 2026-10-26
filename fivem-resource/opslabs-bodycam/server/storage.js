// Video files: each recorded part is written as <random>.webm to <resource>/media (or another resource's folder,
// config_server.lua Storage.Dir). FXServer only lets a resource write inside resource folders: /var/www is refused.
// A web server publishes the folder (Storage.PublicUrl) — never this resource (see the HTTP handler below).
// all server JS files of a resource share one scope: keep this file's names private
(() => {
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const OWN = path.join(GetResourcePath(GetCurrentResourceName()), 'media');
let DIR = OWN;
let MAX = 64 * 1024 * 1024;
const NAME = /^[A-Za-z0-9_-]{22}\.webm$/;
const WEBM = [0x1a, 0x45, 0xdf, 0xa3];

/** called by server/main.lua with Storage.Dir / MaxSegmentMB; returns the folder in use */
exports('ConfigureStorage', (dir, maxMb) => {
    if (typeof maxMb === 'number' && maxMb > 0) MAX = maxMb * 1024 * 1024;
    DIR = typeof dir === 'string' && dir !== '' ? dir : OWN;
    try {
        fs.mkdirSync(DIR, { recursive: true });
    } catch (e) {
        console.log(`^3[opslabs-bodycam] can't use ${DIR} for videos (${e.message.split('.')[0]}) - using ${OWN}^7`);
        DIR = OWN;
        fs.mkdirSync(DIR, { recursive: true });
    }
    return DIR;
});

/** base64 parts (already joined by Lua) → file; returns { name, bytes } or { error } */
exports('SaveVideo', (b64) => {
    if (typeof b64 !== 'string') return { error: 'invalid' };
    const buf = Buffer.from(b64, 'base64');
    if (buf.length < 1024) return { error: 'too_small' };
    if (buf.length > MAX) return { error: 'too_large' };
    if (!WEBM.every((b, i) => buf[i] === b)) return { error: 'not_webm' };
    const name = crypto.randomBytes(16).toString('base64url') + '.webm';
    try {
        fs.writeFileSync(path.join(DIR, name), buf, { mode: 0o644 });
    } catch (e) {
        console.log(`^1[opslabs-bodycam] could not write ${name} to ${DIR}: ${e.message}^7`);
        return { error: 'write_failed' };
    }
    return { name, bytes: buf.length };
});

exports('DeleteVideo', (name) => {
    if (!NAME.test(String(name))) return false;
    try { fs.unlinkSync(path.join(DIR, name)); return true; } catch { return false; }
});

// Zero-setup video hosting: when the operator hasn't stood up their own web server (Storage.PublicUrl
// left blank, main.lua's default path when nothing else is configured), the recorded file is pushed
// straight to the Xon Sight portal here instead, so evidence plays back with no extra setup at all -
// no PublicUrl, no companion script. This is an OUTBOUND POST (Node's own http/https client making a
// request), a completely different code path from SetHttpHandler below, which is what crashed the
// game server once trying to *serve* a large response (2026-10-14, see the comment on that handler) -
// making a request never touches that code at all.
let PORTAL = { url: '', token: '' };

/** called by main.lua's startup thread with the resolved XonSight.Url/token */
exports('ConfigurePortalUpload', (url, token) => {
    PORTAL = { url: (typeof url === 'string' ? url : '').replace(/\/+$/, ''), token: token || '' };
});

function portalAuthHeaders() {
    if (PORTAL.token) return { 'X-XonSight-Token': PORTAL.token };
    return null;
}

/** uploads an already-saved file (the name SaveVideo returned) to the portal's
 * /api/xonsight/media/upload; cb(ok, urlOrErrorReason) */
exports('UploadToPortal', (name, cb) => {
    if (!NAME.test(String(name))) return cb(false, 'bad_name');
    const authHeaders = portalAuthHeaders();
    if (!PORTAL.url || !authHeaders) return cb(false, 'not_configured');

    let data;
    try {
        data = fs.readFileSync(path.join(DIR, name));
    } catch (e) {
        return cb(false, 'read_failed');
    }

    const boundary = '----xonsight' + crypto.randomBytes(16).toString('hex');
    const head = Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="filename"\r\n\r\n${name}\r\n` +
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${name}"\r\nContent-Type: video/webm\r\n\r\n`
    );
    const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
    const body = Buffer.concat([head, data, tail]);

    let target;
    try {
        target = new URL(`${PORTAL.url}/api/xonsight/media/upload`);
    } catch (e) {
        return cb(false, 'bad_portal_url');
    }
    const client = target.protocol === 'http:' ? http : https;

    let done = false;
    const finish = (ok, result) => { if (!done) { done = true; cb(ok, result); } };

    const req = client.request(target, {
        method: 'POST',
        headers: Object.assign(
            { 'Content-Type': `multipart/form-data; boundary=${boundary}`, 'Content-Length': body.length },
            authHeaders
        ),
        timeout: 30000,
    }, (res) => {
        let text = '';
        res.on('data', (chunk) => { text += chunk; });
        res.on('end', () => {
            if (res.statusCode >= 200 && res.statusCode < 300) {
                finish(true, `${PORTAL.url}/media/${name}`);
            } else {
                finish(false, `http_${res.statusCode}`);
            }
        });
    });
    req.on('timeout', () => req.destroy(new Error('upload timed out')));
    req.on('error', (e) => finish(false, (e && e.message) || 'request_failed'));
    req.write(body);
    req.end();
});

const VOICE_KEY = GetConvar('opsvoip_key', '');     // same shared secret audio.lua already trusts, just the other direction
const REC_ID = /^bc-(\d+)-(\d+)$/;
const VOICE_COMMAND_MAX_AGE = 30;   // seconds - how stale a voice command can be before we refuse to act on it

function reply(res, status, body) {
    try {
        res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.send(JSON.stringify(body));
    } catch (e) { /* the caller gave up - a write to a closed request must never take the server down */ }
}

/** the OPS Voice bridge (voicecmd.js) calling back in: an officer said "xonsight on/off" over their own mic. */
function handleVoiceCommand(req, res, body) {
    // this HTTP handler runs in the resource's JS runtime, outside guard.lua's Lua-side reach - ask opslabs-license directly
    let licensed = false;
    try { licensed = global.exports['opslabs-license'].Allows(GetCurrentResourceName()) === true; } catch (e) { licensed = false; }
    if (!licensed) return reply(res, 503, { error: 'not licensed' });
    const given = String((req.headers && (req.headers.Authorization || req.headers.authorization)) || '').replace(/^Bearer\s+/, '');
    const keyOk = VOICE_KEY.length >= 24 && given.length === VOICE_KEY.length && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(VOICE_KEY));
    if (!keyOk) return reply(res, 401, { error: 'unauthorized' });
    let data;
    try { data = JSON.parse(body || '{}'); } catch (e) { return reply(res, 400, { error: 'invalid json' }); }
    const m = REC_ID.exec(String(data.recordingId || ''));
    if (!m) return reply(res, 400, { error: 'bad recordingId' });
    const src = Number(m[1]);
    const ts = Number(m[2]);
    if (!GetPlayerName(src)) return reply(res, 404, { error: 'player not connected' });
    const cmd = data.command === 'on' ? 'remoteStart' : data.command === 'off' ? 'remoteStop' : null;
    if (!cmd) return reply(res, 400, { error: 'command must be on or off' });

    if (cmd === 'remoteStop') {
        // "off" must only stop the exact session this recordingId was handed out for (set in Audio.Start,
        // server/audio.lua) - never a different, newer session that happens to be live for the same src now,
        // e.g. after FiveM recycles a disconnected officer's id onto someone else.
        let live = false;
        try { live = global.exports[GetCurrentResourceName()].IsLiveSession(src, data.recordingId) === true; } catch (e) { live = false; }
        if (!live) return reply(res, 409, { error: 'not the live session' });
    } else {
        // "on" has no session yet to check against - refuse anything old enough that the src could since
        // have been recycled onto a different, unconsenting player (STT/network lag on the bridge's end).
        if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > VOICE_COMMAND_MAX_AGE) return reply(res, 409, { error: 'stale command' });
    }

    TriggerClientEvent(`opslabs-bodycam:${cmd}`, src, 'voice command');
    reply(res, 200, { ok: true });
}

// No video bytes go out through FXServer's HTTP: sending them from a resource crashed the whole game server (live,
// 2026-10-14). The folder is served by a web server from disk instead (README: nginx + bind mount). The one
// exception is /voice-command (POST, Bearer opsvoip_key) - no video bytes involved, just a short JSON control
// message from the voice bridge.
SetHttpHandler((req, res) => {
    if (req.path === '/voice-command' && req.method === 'POST') {
        req.setDataHandler((body) => handleVoiceCommand(req, res, body));
        return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.send('bodycam videos are served by the web server, not FXServer');
});
})();
