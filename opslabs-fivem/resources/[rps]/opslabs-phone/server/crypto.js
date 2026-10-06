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
/** Ops-Networks account passwords: salted scrypt, "scrypt$N$r$p$salt$hash" (never stored plain) */
const SCRYPT = { N: 16384, r: 8, p: 1, len: 32 };
exports('HashPassword', (password) => {
    const salt = crypto.randomBytes(16);
    const hash = crypto.scryptSync(String(password), salt, SCRYPT.len, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p });
    return ['scrypt', SCRYPT.N, SCRYPT.r, SCRYPT.p, salt.toString('base64'), hash.toString('base64')].join('$');
});

/** constant-time check of a password against a HashPassword() string */
exports('VerifyPassword', (password, stored) => {
    try {
        const parts = String(stored || '').split('$');
        if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
        const N = parseInt(parts[1], 10), r = parseInt(parts[2], 10), p = parseInt(parts[3], 10);
        if (!(N >= 1024 && N <= 1048576 && r >= 1 && r <= 32 && p >= 1 && p <= 16)) return false;
        const salt = Buffer.from(parts[4], 'base64');
        const expected = Buffer.from(parts[5], 'base64');
        if (expected.length < 16) return false;
        const hash = crypto.scryptSync(String(password), salt, expected.length, { N, r, p, maxmem: 256 * N * r + 1024 * 1024 });
        return crypto.timingSafeEqual(hash, expected);
    } catch (_) {
        return false;
    }
});
})();
