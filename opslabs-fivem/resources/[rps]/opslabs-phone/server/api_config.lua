-- Server-only API settings (never sent to clients).
--
-- The API is served by the FiveM HTTP server at:
--   http://<server-ip>:30120/opslabs-phone/api/v1/...
--
-- Set the key in server.cfg so it never lives in the resource folder:
--   set opslabs_phone_api_key "a-long-random-secret"
-- The API stays disabled until a key of at least 24 characters is set.

ApiConfig = {
    Key = GetConvar('opslabs_phone_api_key', ''),

    -- Origins allowed to call the API from a browser (your website).
    -- Use { '*' } to allow any origin.
    CorsOrigins = { 'http://localhost:3000' },

    -- Simple per-IP rate limit
    RateLimit = { Requests = 120, Window = 60 },

    -- Outgoing webhooks: every phone event is POSTed as JSON to these URLs
    -- so a website can stay in sync in real time. The secret is sent in the
    -- X-OpsLabs-Secret header so your site can verify the request.
    Webhooks = {
        -- 'https://your-site.com/api/phone-events',
    },
    WebhookSecret = GetConvar('opslabs_phone_webhook_secret', ''),

    -- Which events to send (set to false to skip)
    Events = {
        ['user.created']      = true,
        ['user.setup']        = true,
        ['message.sent']      = true,
        ['call.ended']        = true,
        ['mail.sent']         = true,
        ['chirp.posted']      = true,
        ['bank.transfer']     = true,
        ['service.request']   = true,
    },
}
