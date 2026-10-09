// OPS Voice: signed tokens the phone uses to hear an OPS Hub caller through the bridge (server/voip.lua).
// all server JS files of a resource share one scope: keep this file's names private
(() => {
const crypto = require('crypto');

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** "b64url(json).b64url(hmac-sha256)" — the bridge checks it with the same opsvoip_key */
exports('VoipToken', (payloadJson, key) => {
    const body = b64url(Buffer.from(String(payloadJson), 'utf8'));
    return `${body}.${b64url(crypto.createHmac('sha256', String(key)).update(body).digest())}`;
});
})();
