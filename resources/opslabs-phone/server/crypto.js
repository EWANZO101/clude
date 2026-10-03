// Cryptographic helpers for the Spotify / TIDAL sign-in (Lua has no secure RNG or SHA-256).
// all server JS files of a resource share one scope: keep this file's names private
(() => {
const crypto = require('crypto');

const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** random URL-safe string (OAuth state, PKCE verifier) */
exports('RandomToken', (bytes) => b64url(crypto.randomBytes(Math.min(Math.max(bytes | 0, 16), 96))));

/** PKCE S256 challenge for a verifier */
exports('PkceChallenge', (verifier) => b64url(crypto.createHash('sha256').update(String(verifier)).digest()));

/** standard base64 (HTTP Basic auth) */
exports('Base64', (text) => Buffer.from(String(text), 'utf8').toString('base64'));
})();
