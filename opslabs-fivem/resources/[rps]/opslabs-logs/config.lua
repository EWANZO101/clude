-- OPS Logs — organizes, dedupes and summarizes FXServer console output so a busy/spammy server's logs
-- stay readable. Works with any resource's logs (Lua or JS) — it only relies on the "[tag] message" shape
-- every FXServer console line already has, no per-script integration needed.
--
-- This file is the Lua-side settings only (this resource's command + HTTP handler run in Lua so they stay
-- wrapped by opslabs-license/guard.lua — see server/main.lua). The log-tailing settings (which file/unit
-- to watch, dedupe window, etc.) are JS-side and live in config.json instead, since that half runs in
-- this resource's Node runtime and can't parse Lua syntax. Both files' settings are documented in README.md.
Config = {}

-- Discord webhook URL — posts once per brand-new distinct warning/error signature (rate-limited to avoid
-- a burst of new errors flooding the channel). Blank disables this. (Which level counts — 'warn' or
-- 'error' — is config.json's discordMinLevel, since that's decided on the JS side before Lua ever sees it.)
Config.DiscordWebhook = ''

-- Who may run /serverlog in-game (add_ace group.admin opslabs.logs allow). The server console is always allowed.
Config.AdminAce = 'opslabs.logs'
