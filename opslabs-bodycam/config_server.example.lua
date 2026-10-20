-- Copy to config_server.lua (kept out of git: it holds the Xon Sight key).
ServerConfig = {}

ServerConfig.XonSight = {
    Url = 'https://xonsight.opslabsystems.cloud',     -- the evidence portal, no trailing slash
    Key = '',                    -- X-XonSight-Key: the same value as XONSIGHT_WEBHOOK_KEY in the portal's .env
    LiveSync = true,             -- keep /live up to date with who is recording
    SyncSeconds = 5,
    -- Evidence ids must be unique on the portal. They start here, so they never meet the ids another source
    -- (e.g. the XonSight resource) sends to the same portal.
    EvidenceIdOffset = 1000000,
    ServerTag = '',              -- put in front of every caption when several servers share one portal, e.g. 'S1'
    -- trigger (session.trigger, e.g. the auto-start reasons below) -> alert sent to the portal's Live page
    -- (POST /api/xonsight/alerts - an extension endpoint, not every Xon Sight deployment has it). Anything not
    -- listed here never fires an alert - keep it short, or routine triggers like sirens become noise on /live.
    -- AlertTriggers = {
    --     ['shots fired']  = { type = 'weapon_fired', message = 'Shots fired' },
    --     ['weapon drawn'] = { type = 'weapon_drawn', message = 'Weapon drawn' },
    -- },
}

-- Where the videos are kept. The portal only stores a link, so the files must be reachable from the internet over
-- https (the portal is https: a plain http video link won't play there).
ServerConfig.Storage = {
    -- folder for the .webm files. '' = <this resource>/media. FXServer only lets a resource write inside resource
    -- folders, so anything else must be a resource's folder (e.g. a dedicated storage resource)
    Dir = '',
    -- public https address of the videos, no trailing slash: a web server publishing the folder from disk (README).
    -- Required: FXServer itself doesn't serve them (sending video from a resource crashed the game server)
    PublicUrl = '',
    MaxSegmentMB = 64,           -- larger uploads are refused
}

-- Log recordings in MySQL (oxmysql, table created by itself) and retry evidence the portal didn't take.
-- Without oxmysql it still works; failed sends are then only retried until the next restart.
ServerConfig.Database = true

-- Voice in the videos (the officer's mic, people talking near them, radio) through the OPS Voice bridge
-- (/opt/opsvoip-bridge). Uses the OPS Voice convars opsvoip_url / opsvoip_key. Off when they aren't set.
ServerConfig.Audio = {
    Enabled = true,
    PublicUrl = '',      -- where the bridge's videos with sound are served (nginx → /var/lib/opsvoip-bridge/bodycam)
    KeepSilentCopy = false,    -- keep the video-only file as well
}
