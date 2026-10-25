-- Bodycam client: start / stop (key, command, phone app, auto triggers), the officer's position for Xon Sight /live,
-- and the relay for the video: the NUI (html/recorder.js) records the game view and hands each finished part over
-- here in chunks, which go to the server as latent events — one at a time, each acknowledged before the next.

local RES = GetCurrentResourceName()
local recording = false
local busy = false
local session = nil
local lastManualStop = 0
local autoDeniedUntil = 0
local uploading = 0
local street = ''

-- server requests ---------------------------------------------------------------------------------------------------

local pending, seq = {}, 0
local function request(action, data, timeout)
    seq = seq + 1
    local id = seq
    local p = promise.new()
    pending[id] = p
    TriggerServerEvent('opslabs-bodycam:request', id, action, data)
    SetTimeout(timeout or 15000, function() if pending[id] then pending[id] = nil p:resolve(nil) end end)
    return Citizen.Await(p)
end
RegisterNetEvent('opslabs-bodycam:reply', function(id, result)
    local p = pending[id]
    if p then pending[id] = nil p:resolve(result) end
end)

-- call sign on first load ---------------------------------------------------------------------------------------------
-- playerSpawned fires on every spawn (deaths included), so this is guarded to ask once a session; the server
-- decides whether to actually prompt (right job, no call sign yet) - this just drives the on-screen keyboard.

local askedCallsign = false
AddEventHandler('playerSpawned', function()
    if askedCallsign then return end
    askedCallsign = true
    CreateThread(function()
        Wait(3000) -- let the framework finish loading job / metadata before asking the server
        local r = request('checkCallsignPrompt')
        if not r or not r.prompt then return end
        AddTextEntry('OPSBC_CALLSIGN', ('Set your %s call sign (e.g. 1-ADAM-12) — Esc to skip'):format(r.jobLabel or 'unit'))
        DisplayOnscreenKeyboard(1, 'OPSBC_CALLSIGN', '', '', '', '', '', 24)
        local text
        while true do
            Wait(0)
            local status = UpdateOnscreenKeyboard()
            if status == 1 then text = GetOnscreenKeyboardResult() break
            elseif status == 2 or status == 3 then break end
        end
        if text and text:match('%S') then
            local res = request('setCallsign', { callsign = text })
            if res and res.ok then
                BeginTextCommandThefeedPost('STRING')
                AddTextComponentSubstringPlayerName(('Call sign set: %s'):format(res.callsign))
                EndTextCommandThefeedPostTicker(false, true)
            end
        end
    end)
end)

-- state -------------------------------------------------------------------------------------------------------------

local function state()
    return {
        recording = recording, busy = busy, uploading = uploading,
        startedAt = session and session.startedAt or nil, trigger = session and session.trigger or nil,
        note = session and session.note or '', serial = session and session.serial or nil, officer = session and session.officer or nil,
        keybind = Config.Keybind, command = Config.Command,
    }
end

local function changed() TriggerEvent('opslabs-bodycam:state', state()) end   -- OPS Phone listens (Bodycam app)

local REASONS = {
    wrong_job = 'Your job isn\'t issued a bodycam', off_duty = 'Go on duty to use your bodycam', grade = 'Your rank isn\'t issued a bodycam',
    no_item = 'You don\'t have a bodycam', not_allowed = 'You aren\'t issued a bodycam', vest_off = 'Put your vest on first (/vest)',
}

local function start(trigger)
    if recording or busy then return recording end
    busy = true
    local r = request('start', { trigger = trigger or 'manual' })
    busy = false
    if not r or not r.ok then
        if trigger == 'manual' then Config.Notify(r and REASONS[r.reason] or 'The bodycam isn\'t responding', 'error') end
        if trigger ~= 'manual' then autoDeniedUntil = GetGameTimer() + 60000 end
        changed()
        return false
    end
    recording, session = true, r.session
    -- hand off whatever's in the pre-roll buffer first (it stops itself once this 'start' message arrives), then
    -- the real, full-quality recording - see html/recorder.js Preroll.flush()/View start.
    SendNUIMessage({ action = 'start', session = session })
    Config.Notify(trigger == 'manual' and 'Bodycam recording' or ('Bodycam recording (auto: ' .. trigger .. ')'), 'success')
    if ChestCam then ChestCam.Start() end
    changed()
    return true
end

local function stop(reason)
    if not recording then return false end
    recording = false
    SendNUIMessage({ action = 'stop' })
    if reason == 'manual' then lastManualStop = GetGameTimer() end
    CreateThread(function() request('stop', { reason = reason or 'manual' }) end)
    Config.Notify(reason == 'manual' and 'Bodycam stopped — footage is uploading' or ('Bodycam stopped: ' .. tostring(reason)), 'inform')
    if ChestCam then ChestCam.Stop() end
    session = nil
    changed()
    return true
end

-- pre-roll eligibility: only officers actually issued a bodycam should pay for the rolling buffer. Cheap single
-- round trip, checked occasionally rather than on every frame - duty/job status doesn't change that often.
local preRollWanted = false
CreateThread(function()
    if not (Config.PreRoll and Config.PreRoll.Enabled) then return end
    while true do
        local can = (not recording) and request('canUse')
        local want = can and can.allowed or false
        if want ~= preRollWanted then
            preRollWanted = want
            SendNUIMessage({ action = 'preroll', enabled = want, config = Config.PreRoll })
        end
        Wait(20000)
    end
end)

-- live video (MediaMTX WHIP) ------------------------------------------------------------------------------------
-- Entirely separate from recording above: no evidence item, no upload, just a real-time feed to Xon Sight /live.
-- Started from the MDT laptop (opslabs-mdt calls exports('StartLive') directly - both run client-side on the
-- same player, no server round trip needed between the two resources) or Config.LiveStream.Command.

local live, liveKind, liveBusy = false, nil, false

local function liveState() return { active = live, kind = liveKind } end
local function liveChanged() TriggerEvent('opslabs-bodycam:liveState', liveState()) end

local LIVE_REASONS = { not_configured = 'Live video is not set up on this server', portal_unreachable = 'The evidence portal is unreachable' }

local function startLive(opts)
    if live or liveBusy then return live end
    liveBusy = true
    local kind = (type(opts) == 'table' and opts.kind) or (Config.LiveStream or {}).Kind or 'dashcam'
    local r = request('liveStart', { kind = kind })
    liveBusy = false
    if not r or not r.ok then
        Config.Notify((r and LIVE_REASONS[r.reason]) or 'Could not start live video', 'error')
        liveChanged()
        return false
    end
    live, liveKind = true, kind
    SendNUIMessage({ action = 'liveStart', whip = r.whip, token = r.token, config = Config.LiveStream })
    Config.Notify('Live video started', 'success')
    liveChanged()
    return true
end

local function stopLive(reason)
    if not live then return false end
    live, liveKind = false, nil
    SendNUIMessage({ action = 'liveStop' })
    CreateThread(function() request('liveStop') end)
    Config.Notify(reason and reason ~= 'manual' and ('Live video stopped: ' .. tostring(reason)) or 'Live video stopped', 'inform')
    liveChanged()
    return true
end

RegisterNetEvent('opslabs-bodycam:remoteStopLive', function(reason) stopLive(reason or 'external') end)

RegisterNUICallback('liveState', function(d, cb)
    cb(true)
    if d and d.state == 'error' and live then
        Config.Notify('Live video connection failed' .. (d.error and (': ' .. tostring(d.error)) or ''), 'error')
        stopLive('connection failed')
    end
end)

if Config.LiveStream and Config.LiveStream.Command and Config.LiveStream.Command ~= '' then
    RegisterCommand(Config.LiveStream.Command, function() if live then stopLive('manual') else startLive() end end, false)
end

exports('StartLive', function(opts) return startLive(opts) end)
exports('StopLive', function(reason) return stopLive(reason or 'manual') end)
exports('IsLive', function() return live end)
exports('GetLiveState', liveState)

local function toggle() if recording then return stop('manual') end return start('manual') end

RegisterCommand(Config.Command or 'bodycam', function() toggle() end, false)
if Config.Keybind and Config.Keybind ~= '' then
    RegisterKeyMapping(Config.Command or 'bodycam', 'Bodycam: start / stop recording', 'keyboard', Config.Keybind)
end

RegisterNetEvent('opslabs-bodycam:remoteStart', function(reason) start(reason or 'external') end)
RegisterNetEvent('opslabs-bodycam:remoteStop', function(reason) stop(reason or 'external') end)

-- NUI: config + the video relay ------------------------------------------------------------------------------------

RegisterNUICallback('ready', function(_, cb)
    cb({ video = Config.Video, hud = Config.Hud, beep = Config.Beep, voice = Config.Voice, upload = Config.Upload })
    if recording then SendNUIMessage({ action = 'start', session = session }) end
end)

RegisterNUICallback('partBegin', function(d, cb)
    uploading = uploading + 1
    changed()
    if type(d.street) ~= 'string' or d.street == '' then d.street = street end
    cb(request('uploadBegin', d) or { ok = false })
end)

local acks = {}
RegisterNetEvent('opslabs-bodycam:ack', function(id, index, ok)
    local p = acks[id .. ':' .. index]
    if p then acks[id .. ':' .. index] = nil p:resolve(ok == true) end
end)

RegisterNUICallback('chunk', function(d, cb)
    local key = tostring(d.upload) .. ':' .. tostring(d.index)
    local p = promise.new()
    acks[key] = p
    TriggerLatentServerEvent('opslabs-bodycam:chunk', Config.Upload.BytesPerSecond or 1000000, d.upload, d.index, d.data)
    SetTimeout(90000, function() if acks[key] then acks[key] = nil p:resolve(false) end end)
    cb(Citizen.Await(p))
end)

RegisterNUICallback('partEnd', function(d, cb)
    uploading = math.max(0, uploading - 1)
    if d and d.error then Config.Notify('A bodycam part could not be uploaded (' .. tostring(d.error) .. ')', 'error') end
    changed()
    cb(true)
end)

RegisterNUICallback('partStarted', function(d, cb)
    cb(true)
    if d and d.session then TriggerServerEvent('opslabs-bodycam:partStarted', d.session, d.part) end
end)

-- /bodycammic: can the NUI use the microphone here? (if yes, the officer's own voice can go straight into the video)
RegisterCommand('bodycammic', function() SendNUIMessage({ action = 'micTest' }) end, false)
RegisterNUICallback('micResult', function(d, cb)
    cb(true)
    local msg = d.ok and ('Microphone OK: ' .. tostring(d.label or 'default') .. ' (' .. tostring(d.devices or '?') .. ' inputs)') or ('No microphone: ' .. tostring(d.error))
    print('[opslabs-bodycam] mic test: ' .. msg)
    Config.Notify(msg, d.ok and 'success' or 'error')
    TriggerServerEvent('opslabs-bodycam:micResult', d)
end)

RegisterNUICallback('maxLength', function(_, cb) cb(true) stop('maximum length reached') end)
RegisterNUICallback('cannotRecord', function(_, cb) cb(true) stop('this game client cannot record video') end)

RegisterNetEvent('opslabs-bodycam:uploaded', function(r)
    if r.error then
        Config.Notify(('Bodycam part %s was not saved (%s)'):format(r.part or '?', r.error), 'error')
    elseif not r.sent then
        Config.Notify(('Bodycam part %s saved — the evidence portal is unreachable, it will be sent again'):format(r.part), 'warning')
    end
    TriggerEvent('opslabs-bodycam:uploadedPart', r)
end)

-- position for /live + street for the picture overlay -----------------------------------------------------------------

local function streetHere(pos)
    local s1, s2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
    local name = GetStreetNameFromHashKey(s1)
    if s2 ~= 0 then name = name .. ' / ' .. GetStreetNameFromHashKey(s2) end
    local zone = GetLabelText(GetNameOfZone(pos.x, pos.y, pos.z))
    if zone and zone ~= '' and zone ~= 'NULL' then name = name .. ', ' .. zone end
    return name
end

CreateThread(function()
    local lastReport = 0
    while true do
        -- the overlay (local only - no network) also needs to stay fresh while the pre-roll buffer or a live
        -- broadcast is running, not just during a real recording, so its footage carries real location/heading
        -- too, not a blank/stale one from whenever recording last stopped. The /live position report to the
        -- server stays recording-only: pre-rolling and live-streaming aren't a recording session, there's
        -- nothing for the Live page's position marker to show from them (a live broadcast shows the actual
        -- picture there instead - see xonsight/api.py list_live_streams).
        if recording or preRollWanted or live then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            street = streetHere(pos)
            local rot = GetGameplayCamRot(2)
            SendNUIMessage({ action = 'overlay', street = street, x = pos.x, y = pos.y, heading = (360.0 - rot.z) % 360.0 })
            if recording then
                local now = GetGameTimer()
                if now - lastReport >= (Config.Live.ReportSeconds or 3) * 1000 then
                    lastReport = now
                    TriggerServerEvent('opslabs-bodycam:frame', {
                        x = pos.x, y = pos.y, z = pos.z,
                        heading = (360.0 - rot.z) % 360.0,      -- GTA turns anticlockwise; the portal's compass clockwise
                        pitch = rot.x, fov = GetGameplayCamFov(),
                    })
                end
            end
            Wait(1000)
        else
            Wait(500)
        end
    end
end)

-- first person while recording: the camera records what the player sees, so the view is held in first person
-- (on foot and in vehicles) and put back afterwards ---------------------------------------------------------------------

CreateThread(function()
    if Config.Video.FirstPerson == false then return end
    local FIRST = 4
    while true do
        if recording then
            local savedPed, savedVeh = GetFollowPedCamViewMode(), GetFollowVehicleCamViewMode()
            while recording do
                if IsPedInAnyVehicle(PlayerPedId(), false) then
                    if GetFollowVehicleCamViewMode() ~= FIRST then SetFollowVehicleCamViewMode(FIRST) end
                elseif GetFollowPedCamViewMode() ~= FIRST then
                    SetFollowPedCamViewMode(FIRST)
                end
                DisableControlAction(0, 0, true)       -- INPUT_NEXT_CAMERA (V)
                DisableControlAction(0, 80, true)      -- INPUT_VEH_CINEMATIC_CAM
                DisableControlAction(0, 26, true)      -- INPUT_LOOK_BEHIND
                Wait(0)
            end
            SetFollowPedCamViewMode(savedPed)
            SetFollowVehicleCamViewMode(savedVeh)
        end
        Wait(250)
    end
end)

-- auto triggers -----------------------------------------------------------------------------------------------------

local function autoStart(reason)
    local now = GetGameTimer()
    if recording or busy or now < autoDeniedUntil then return end
    if now - lastManualStop < (Config.Auto.Cooldown or 15) * 1000 then return end
    CreateThread(function() start(reason) end)
end

-- "Drawn" means equipped - a gun or taser selected as the current weapon - not merely aiming (aiming implies
-- already drawn, so this covers that case too, just earlier). GetWeapontypeGroup/GROUP_* are the same natives
-- already proven elsewhere on this server (opslabs-towers/client/gunshots.lua, ox_inventory's weapon module).
local DRAWN_GROUPS = {
    [`GROUP_PISTOL`] = true, [`GROUP_SMG`] = true, [`GROUP_RIFLE`] = true, [`GROUP_MG`] = true,
    [`GROUP_SHOTGUN`] = true, [`GROUP_SNIPER`] = true, [`GROUP_HEAVY`] = true,
}
local function drawnWeaponReason(ped)
    local group = GetWeapontypeGroup(GetSelectedPedWeapon(ped))
    if group == `GROUP_STUNGUN` then return 'taser drawn' end
    if DRAWN_GROUPS[group] then return 'weapon drawn' end
    return nil
end

local MPH_TO_MS = 0.44704

CreateThread(function()
    local A = Config.Auto or {}
    if not (A.OnShooting or A.OnSiren or A.OnWeaponDrawn) then return end
    local lastSlow = 0
    while true do
        local ped = PlayerPedId()
        local armed = IsPedArmed(ped, 4)
        if not recording and armed then
            if A.OnShooting and IsPedShooting(ped) then
                autoStart('shots fired')
            elseif A.OnWeaponDrawn then
                local reason = drawnWeaponReason(ped)
                if reason then autoStart(reason) end
            end
        end
        local now = GetGameTimer()
        if not recording and A.OnSiren and now - lastSlow > 1000 then
            lastSlow = now
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and IsVehicleSirenOn(veh) then
                local minSpeed = (A.SirenSpeedMph or 0) * MPH_TO_MS
                if GetEntitySpeed(veh) >= minSpeed then autoStart('lights and siren') end
            end
        end
        Wait((armed and not recording) and 0 or 250)
    end
end)

-- exports (OPS Phone Bodycam app, MDTs, other scripts) -------------------------------------------------------------

exports('IsRecording', function() return recording end)
exports('GetState', state)
exports('Start', function(reason) return start(reason or 'manual') end)
exports('Stop', function(reason) return stop(reason or 'manual') end)
exports('Toggle', toggle)
exports('SetNote', function(note)
    if not recording then return false end
    local r = request('note', { note = note })
    if r and r.ok and session then
        session.note = r.note
        SendNUIMessage({ action = 'note', note = r.note })
        changed()
    end
    return r and r.ok or false
end)
exports('CanUse', function() return request('canUse') end)
exports('GetRecent', function() return request('recent') or {} end)
exports('GetLive', function() return request('live') or {} end)

AddEventHandler('onResourceStop', function(r)
    if r ~= RES then return end
    if recording then recording = false end
    if live then live = false end
end)
