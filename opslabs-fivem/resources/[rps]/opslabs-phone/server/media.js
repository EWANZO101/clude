// Camera media storage: photos (jpg) and videos (webm) taken on the phone are
// written to <resource>/media and served at /<resource>/media/<file>.
// all server JS files of a resource share one scope: keep this file's names private
(() => {
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DIR = path.join(GetResourcePath(GetCurrentResourceName()), 'media');
fs.mkdirSync(DIR, { recursive: true });

const KINDS = {
    jpg: { magic: [0xff, 0xd8, 0xff], max: 8 * 1024 * 1024 },
    webm: { magic: [0x1a, 0x45, 0xdf, 0xa3], max: 40 * 1024 * 1024 },
};
const NAME = /^[A-Za-z0-9_-]{22}\.(jpg|webm)$/;

/** base64 (or data: URI) -> file; returns the file name or null */
exports('SaveMedia', (data, ext) => {
    const kind = KINDS[ext];
    if (!kind || typeof data !== 'string') return null;
    const buf = Buffer.from(data.replace(/^data:[^,]*,/, ''), 'base64');
    if (buf.length < 64 || buf.length > kind.max) return null;
    if (!kind.magic.every((b, i) => buf[i] === b)) return null;
    const name = crypto.randomBytes(16).toString('base64url') + '.' + ext;
    fs.writeFileSync(path.join(DIR, name), buf);
    return name;
});

/** file contents for the HTTP fallback (when nginx doesn't serve /media itself) */
exports('ReadMedia', (name) => {
    if (!NAME.test(String(name))) return null;
    try { return fs.readFileSync(path.join(DIR, name)); } catch { return null; }
});

// for the Lua HTTP fallback: binary can't cross from JS to Lua intact, so hand it over as base64 text
exports('ReadMediaBase64', (name) => {
    if (!NAME.test(String(name))) return null;
    try { return fs.readFileSync(path.join(DIR, name)).toString('base64'); } catch { return null; }
});

exports('DeleteMedia', (name) => {
    if (!NAME.test(String(name))) return false;
    try { fs.unlinkSync(path.join(DIR, name)); return true; } catch { return false; }
});
})();
