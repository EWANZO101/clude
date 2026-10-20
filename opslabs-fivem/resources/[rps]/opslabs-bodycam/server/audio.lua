-- Voice in the bodycam videos, through the OPS Voice bridge (/opt/opsvoip-bridge, recorder.js). While an officer
-- records, a listening bot sits in their pma-voice channel and hears their mic, people talking near them and radio
-- traffic; each saved video part is sent back with that voice mixed in (a new file in the bridge's folder, served at
-- ServerConfig.Audio.PublicUrl). Game sound (shots, sirens, engines) can't be recorded: FiveM doesn't expose it.
-- Without the bridge everything still works, the videos just have no sound.
-- Uses the same convars as OPS Voice: opsvoip_url, opsvoip_key.

Audio = {}

local cfg = ServerConfig.Audio or {}
local URL = GetConvar('opsvoip_url', '')
local KEY = GetConvar('opsvoip_key', '')

function Audio.Enabled() return cfg.Enabled ~= false and URL ~= '' and KEY ~= '' and (cfg.PublicUrl or '') ~= '' end

--- POST to the bridge; returns the decoded reply or nil (wait = false: fire and forget)
local function call(op, body, wait, timeoutMs)
    if not Audio.Enabled() then return nil end
    local p = wait and promise.new() or nil
    PerformHttpRequest(URL .. '/ctl/rec/' .. op, function(status, text)
        if not p then return end
        local ok, data = pcall(json.decode, text or '')
        p:resolve(status == 200 and ok and data or nil)
    end, 'POST', json.encode(body), { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. KEY })
    if not p then return nil end
    SetTimeout(timeoutMs or 15000, function() p:resolve(nil) end)
    return Citizen.Await(p)
end

function Audio.Start(id, src)
    local channel = Player(src).state.assignedChannel
    if not channel then return end
    local vc = ServerConfig.VoiceCommand or {}
    local voicePhrases = nil
    if vc.Enabled ~= false then voicePhrases = { on = vc.OnPhrases or {}, off = vc.OffPhrases or {} } end
    call('start', { id = id, serverId = src, channel = channel, voicePhrases = voicePhrases })
end

function Audio.Mark(id, part) call('mark', { id = id, part = part }) end
function Audio.Stop(id) call('stop', { id = id }) end

--- the saved video part with its voice: public URL of the new file, or nil (then the video stays silent)
function Audio.Mux(id, part, file, durationMs)
    local r = call('mux', { id = id, part = part, file = file, durationMs = durationMs }, true, 150000)
    if type(r) ~= 'table' or not r.ok or type(r.file) ~= 'string' then
        if r then print(('^3[opslabs-bodycam] no sound for %s part %s: %s^7'):format(id, part, tostring(r.reason or r.error))) end
        return nil
    end
    return (cfg.PublicUrl:gsub('/+$', '')) .. '/' .. r.file, r.file
end
