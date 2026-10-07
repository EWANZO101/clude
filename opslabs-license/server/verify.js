// OPSHUB licensing: checks a license certificate's Ed25519 signature (Node's crypto; Lua has no Ed25519).
// verifyCertificate(certBase64, sigBase64, publicKeyPem) → the certificate's JSON text, or false.
const crypto = require('crypto');

exports('verifyCertificate', (certB64, sigB64, pem) => {
    try {
        const body = Buffer.from(String(certB64 || ''), 'base64');
        const sig = Buffer.from(String(sigB64 || ''), 'base64');
        if (!body.length || sig.length !== 64) return false;
        const ok = crypto.verify(null, body, crypto.createPublicKey(String(pem || '').trim()), sig);
        return ok ? body.toString('utf8') : false;
    } catch (e) {
        return false;
    }
});
