-- OPS Secure CCTV (client): [E] at recorders, monitors, video walls, keyboards, cameras and doorbells, and the live
-- camera viewer (switch cameras, PTZ pan / tilt / zoom, thermal, IR at night, NO SIGNAL when a camera is down).
-- Server: server/cctv.lua. The phone's OPS Secure View app opens the same viewer remotely.

local CV = Config.Cctv or {}
if not CV.Enabled then return end
local CAM, REC, VIEW = CV.Cameras or {}, CV.Recorders or {}, CV.Viewers or {}
local GREEN, RED, ORANGE, BLUE, GREY = '#30d158', '#ff453a', '#ff9f0a', '#0a84ff', '#8e8e93'
local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function err(r) lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end

---------------------------------------------------------------------------
-- the viewer
---------------------------------------------------------------------------
local watching = false
local function txt(x, y, s, scale, r, g, b, a, right, font)
    SetTextFont(font or 4) SetTextScale(scale, scale) SetTextColour(r or 255, g or 255, b or 255, a or 230)
    SetTextOutline()
    if right then SetTextRightJustify(true) SetTextWrap(0.0, x) end
    BeginTextCommandDisplayText('STRING') AddTextComponentSubstringPlayerName(s) EndTextCommandDisplayText(x, y)
end

function CctvWatch(rid, remote, startCam)
    if watching then return end
    local sys = lib.callback.await('opslabs-towers:cctv:watch', false, rid, remote)
    if not sys or sys.error then return err(sys) end
    local cams = sys.cams or {}
    if #cams == 0 then return lib.notify({ type = 'inform', description = 'No cameras on this system yet' }) end
    watching = true
    local idx = 1
    for i, c in ipairs(cams) do if c.id == startCam then idx = i end end
    local ped = PlayerPedId()
    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    local pan, tilt, fov = 0.0, -12.0, 60.0
    local function apply()
        local c = cams[idx]
        pan, tilt = 0.0, c.ptz and -15.0 or -12.0
        fov = math.max(25.0, math.min(100.0, (c.fov or 90) * 0.8))
        SetCamCoord(cam, c.x, c.y, c.z)
        SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)
        SetCamFov(cam, fov)
        ClearTimecycleModifier()
        SetTimecycleModifier(c.status == 'fault_lens' and 'BlackOut' or 'scanline_cam_cheap')
        SetTimecycleModifierStrength(c.status == 'fault_lens' and 0.45 or 1.0)
        local h = GetClockHours()
        SetNightvision(c.ir and (h >= 20 or h < 6) or false)
        SetSeethrough(c.thermal or false)
    end
    apply()
    RenderScriptCams(true, false, 0, true, true)
    DisplayRadar(false)
    PlaySoundFrontend(-1, 'Camera_On', 'Phone_SoundSet_Michael', true)
    CreateThread(function()
        while watching do
            Wait(0)
            DisableAllControlActions(0)
            EnableControlAction(0, 245, true)        -- chat
            EnableControlAction(0, 249, true)        -- push to talk
            local c = cams[idx]
            -- switch camera
            local function step(d)
                idx = (idx - 1 + d) % #cams + 1
                apply()
                PlaySoundFrontend(-1, 'Change_Cam', 'MP_CCTV_SOUNDSET', true)
            end
            if IsDisabledControlJustPressed(0, 175) or IsDisabledControlJustPressed(0, 35) then step(1) end
            if IsDisabledControlJustPressed(0, 174) or IsDisabledControlJustPressed(0, 34) then step(-1) end
            -- PTZ: mouse / arrows pan & tilt, scroll zoom (fixed cameras can zoom digitally a little)
            if c.ptz then
                pan = pan - GetDisabledControlNormal(0, 1) * 6.0
                tilt = math.max(-80.0, math.min(10.0, tilt - GetDisabledControlNormal(0, 2) * 4.0))
                if IsDisabledControlPressed(0, 172) then tilt = math.min(10.0, tilt + 0.6) end
                if IsDisabledControlPressed(0, 173) then tilt = math.max(-80.0, tilt - 0.6) end
            end
            if IsDisabledControlJustPressed(0, 15) then fov = math.max(c.ptz and 6.0 or 30.0, fov - 5.0) SetCamFov(cam, fov) end
            if IsDisabledControlJustPressed(0, 14) then fov = math.min(100.0, fov + 5.0) SetCamFov(cam, fov) end
            SetCamRot(cam, tilt, 0.0, (c.heading or 0.0) + 180.0 + pan, 2)
            if CctvLiveTick then CctvLiveTick(c.id) end            -- client/cctvlive.lua: what you watch is live on OPS Hub
            if IsDisabledControlJustPressed(0, 177) or IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 194) then watching = false end
            -- overlay
            if not c.online then
                DrawRect(0.5, 0.5, 1.0, 1.0, 10, 10, 12, 255)
                txt(0.5 - 0.09, 0.44, 'NO SIGNAL', 1.1, 255, 255, 255, 255)
                txt(0.5 - 0.12, 0.52, c.statusText or 'Camera offline', 0.45, 255, 120, 120, 255)
            end
            txt(0.03, 0.03, ('%s · %s'):format(sys.name or 'CCTV', c.name or ('Camera ' .. idx)), 0.5)
            txt(0.03, 0.065, ('CAM %02d / %02d%s%s'):format(idx, #cams, c.ptz and '  PTZ' or '', c.thermal and '  THERMAL' or ''), 0.38, 200, 210, 220)
            if c.online and sys.recording and (GetGameTimer() // 600) % 2 == 0 then txt(0.97, 0.03, '● REC', 0.5, 255, 60, 60, 255, true) end
            txt(0.97, 0.065, ('%02d:%02d  %s'):format(GetClockHours(), GetClockMinutes(), remote and 'REMOTE' or 'LIVE'), 0.4, 220, 220, 220, 230, true)
            txt(0.03, 0.93, ('← → camera   %s   scroll zoom   BACKSPACE exit'):format(c.ptz and 'mouse pan / tilt' or ''), 0.36, 220, 220, 220, 200)
        end
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        ClearFocus()
        ClearTimecycleModifier()
        SetNightvision(false)
        SetSeethrough(false)
        DisplayRadar(true)
        PlaySoundFrontend(-1, 'Camera_Off', 'Phone_SoundSet_Michael', true)
        if CctvLiveStop then CctvLiveStop() end
    end)
end
exports('CctvWatch', CctvWatch)
AddEventHandler('opslabs-towers:cctv:remote', function(rid, camId) CctvWatch(rid, true, camId) end)

---------------------------------------------------------------------------
-- menus
---------------------------------------------------------------------------
local EVENT_ICON = { motion = { 'person-walking', BLUE }, heat = { 'fire', ORANGE }, anpr = { 'car', GREEN }, ring = { 'bell', ORANGE }, view = { 'eye', GREY } }
local function eventsMenu(rid, kind, back)
    local rows = lib.callback.await('opslabs-towers:cctv:events', false, rid, kind) or {}
    local o = {}
    for _, e in ipairs(rows) do
        local ic = EVENT_ICON[e.kind] or { 'circle', GREY }
        o[#o + 1] = { title = (e.kind == 'anpr' and 'Plate ' or '') .. (e.detail or e.kind), description = ('%s · %s'):format(e.camera or '—', os.date and '' or '') .. ('%d min ago'):format(math.floor((GetCloudTimeAsInt() - e.at) / 60)),
            icon = ic[1], iconColor = ic[2], onSelect = e.x and function() SetNewWaypoint(e.x + 0.0, e.y + 0.0) end or nil }
    end
    if #o == 0 then o[1] = { title = 'Nothing recorded yet', icon = 'film', readOnly = true } end
    lib.registerContext({ id = 'cctv_events', title = kind == 'anpr' and 'ANPR plate reads' or 'Recorded events', menu = back, options = o })
    lib.showContext('cctv_events')
end

local SiteMenu
local function configMenu(sys, f)
    local function save(d, msg)
        local r = lib.callback.await('opslabs-towers:cctv:config', false, sys.id, d)
        if r and r.ok then lib.notify({ type = 'success', description = msg or 'Saved' }) SiteMenu(f) else err(r) end
    end
    local o = {
        { title = 'Name the system', description = sys.name, icon = 'pen', onSelect = function()
            local v = lib.inputDialog('System name', { { type = 'input', label = 'Name', default = sys.name, max = 60 } })
            if v then save({ name = v[1] }) end
        end },
        { title = 'Recording · ' .. (sys.mode or 'motion'), description = ('Keeps %d days'):format(sys.retention or 7), icon = 'record-vinyl', onSelect = function()
            local v = lib.inputDialog('Recording', {
                { type = 'select', label = 'Mode', default = sys.mode, options = { { value = 'motion', label = 'On motion / plates' }, { value = 'continuous', label = 'Continuous + events' }, { value = 'off', label = 'Off' } } },
                { type = 'slider', label = 'Keep recordings (days)', min = 1, max = 90, default = sys.retention or 7 } })
            if v then save({ mode = v[1], retention = v[2] }, 'Recording set') end
        end },
        { title = 'Remote viewing · ' .. (sys.remote and 'ON' or 'off'), description = sys.internet and 'Recorder is online' or 'Recorder isn’t on the internet — cable it to a router', icon = 'mobile-screen', iconColor = sys.remote and GREEN or GREY,
          onSelect = function() save({ remote = not sys.remote }, sys.remote and 'Remote viewing off' or 'Remote viewing on — open OPS Secure View on your phone') end },
        { title = 'Owner · ' .. (sys.owner or 'none'), icon = 'user', onSelect = function()
            local v = lib.inputDialog('Owner', { { type = 'select', label = 'Who owns it', options = { { value = 'me', label = 'Me' }, { value = 'id', label = 'Player by server ID' } }, default = 'me' },
                { type = 'number', label = 'Server ID (if a player)', min = 1 } })
            if v then save({ owner = v[1] == 'me' and 'me' or v[2] }, 'Owner set') end
        end },
        { title = 'Organisation access · ' .. (sys.org_job or 'none'), description = 'Everyone with this job can watch (e.g. police)', icon = 'building-shield', onSelect = function()
            local v = lib.inputDialog('Organisation', { { type = 'input', label = 'Job name (blank = none)', default = sys.org_job or '' } })
            if v then save({ org_job = v[1] or '' }, 'Access updated') end
        end },
        { title = 'Share with a player', description = (#(sys.shared or {}) > 0) and (#sys.shared .. ' shared') or 'Nobody else', icon = 'share-nodes', onSelect = function()
            local o2 = { { title = 'Add someone (server ID)', icon = 'user-plus', onSelect = function()
                local v = lib.inputDialog('Share', { { type = 'number', label = 'Server ID', min = 1, required = true } })
                if v then save({ share = v[1] }, 'Shared') end
            end } }
            for _, x in ipairs(sys.shared or {}) do o2[#o2 + 1] = { title = 'Remove ' .. (x.name or x.id), icon = 'user-minus', iconColor = RED, onSelect = function() save({ unshare = x.id }, 'Removed') end } end
            lib.registerContext({ id = 'cctv_share', title = 'Shared with', menu = 'cctv_config', options = o2 })
            lib.showContext('cctv_share')
        end },
    }
    for _, c in ipairs(sys.cams or {}) do
        o[#o + 1] = { title = 'Rename · ' .. c.name, icon = 'video', iconColor = c.online and GREEN or RED, onSelect = function()
            local v = lib.inputDialog('Camera name', { { type = 'input', label = 'Name', default = c.name, max = 40 } })
            if v then save({ camera = c.id, cameraName = v[1] }) end
        end }
    end
    lib.registerContext({ id = 'cctv_config', title = 'Set up · ' .. (sys.name or 'CCTV'), menu = 'cctv_site', options = o })
    lib.showContext('cctv_config')
end

SiteMenu = function(f)
    local sys = lib.callback.await('opslabs-towers:cctv:site', false, f.id)
    if not sys or sys.error then return err(sys) end
    local o = {
        { title = sys.name, description = ('%s · %s · %s'):format(sys.powered and 'Powered' or 'NO POWER', sys.recording and 'Recording' or 'Not recording', sys.internet and 'Online' or 'Offline'),
          icon = 'server', iconColor = sys.powered and (sys.recording and GREEN or ORANGE) or RED, readOnly = true },
        { title = ('Channels %d / %d%s'):format(sys.used or 0, sys.channels or 0, (sys.poeBudget or 0) > 0 and (' · PoE %d / %d W · ports %d / %d'):format(sys.poeUsed or 0, sys.poeBudget, sys.portsUsed or 0, sys.poePorts or 0) or ''),
          description = sys.hddFault and 'HARD DRIVE FAILED — not recording' or nil, icon = 'hard-drive', iconColor = sys.hddFault and RED or BLUE, readOnly = true },
    }
    if sys.access then
        o[#o + 1] = { title = 'Watch cameras', description = ('%d camera%s'):format(#sys.cams, #sys.cams == 1 and '' or 's'), icon = 'tv', iconColor = BLUE, onSelect = function() CctvWatch(sys.id, false) end }
        o[#o + 1] = { title = 'Recorded events', icon = 'film', onSelect = function() eventsMenu(sys.id, nil, 'cctv_site') end }
        o[#o + 1] = { title = 'ANPR plate reads', icon = 'car', onSelect = function() eventsMenu(sys.id, 'anpr', 'cctv_site') end }
        for _, c in ipairs(sys.cams) do
            o[#o + 1] = { title = c.name, description = c.statusText .. (c.via and (' · ' .. c.via:gsub('_', ' ')) or ''), icon = c.ptz and 'arrows-spin' or c.anpr and 'car' or c.kind == 'wifi' and 'wifi' or 'video',
                iconColor = c.online and (c.status == 'fault_lens' and ORANGE or GREEN) or RED, onSelect = function() CctvWatch(sys.id, false, c.id) end }
        end
    end
    if sys.canConfigure then o[#o + 1] = { title = 'Set up the system', description = 'Name, recording, remote viewing, owner, sharing, camera names', icon = 'sliders', iconColor = ORANGE, onSelect = function() configMenu(sys, f) end } end
    if sys.hddFault and sys.canConfigure then
        o[#o + 1] = { title = 'Replace the hard drive', icon = 'screwdriver-wrench', iconColor = RED, onSelect = function()
            if lib.progressCircle({ duration = 12000, label = 'Swapping the surveillance HDD and formatting', canCancel = true, disable = { move = true } }) then
                local r = lib.callback.await('opslabs-towers:cctv:repair', false, sys.id, 'hdd')
                if r and r.ok then lib.notify({ type = 'success', description = 'New drive in — recording again' }) else err(r) end
            end
        end }
    end
    lib.registerContext({ id = 'cctv_site', title = 'CCTV · ' .. (sys.name or ''), options = o })
    lib.showContext('cctv_site')
end

local REPAIR = { lens = { 'clean', 'Clean and refocus the lens', 6000 }, cable = { 'reterminate', 'Re-terminate the camera cable', 9000 }, dead = { 'replace', 'Replace the camera', 14000 } }
local function cameraMenu(f)
    local c = lib.callback.await('opslabs-towers:cctv:camera', false, f.id)
    if not c then return end
    local o = { { title = c.name, description = c.statusText, icon = 'video', iconColor = c.online and (c.fault and ORANGE or GREEN) or RED, readOnly = true } }
    if c.staff then
        if c.fault and REPAIR[c.fault] then
            local r = REPAIR[c.fault]
            o[#o + 1] = { title = r[2], icon = 'screwdriver-wrench', iconColor = ORANGE, onSelect = function()
                if lib.progressCircle({ duration = r[3], label = r[2], canCancel = true, disable = { move = true }, anim = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 49 } }) then
                    local res = lib.callback.await('opslabs-towers:cctv:repair', false, f.id, r[1])
                    if res and res.ok then lib.notify({ type = 'success', description = 'Fixed — camera back on the recorder' }) else err(res) end
                end
            end }
        end
        o[#o + 1] = { title = 'Test the picture', description = 'Watch this camera on its recorder', icon = 'eye', onSelect = function() if c.rec then CctvWatch(c.rec, false, c.id) else lib.notify({ type = 'error', description = 'Not on a recorder — ' .. c.statusText }) end end }
    end
    lib.registerContext({ id = 'cctv_cam', title = 'Camera', options = o })
    lib.showContext('cctv_cam')
end

---------------------------------------------------------------------------
-- [E]
---------------------------------------------------------------------------
CreateThread(function()
    local shown
    while true do
        local sleep = 600
        local ped = PlayerPedId()
        if not watching and not IsPedInAnyVehicle(ped, false) then
            local pos = GetEntityCoords(ped)
            local best, bd, label, act
            for _, f in pairs(fixtures()) do
                local m = f.model
                local reach = (REC[m] or VIEW[m]) and 1.8 or m == 'opslabs_cctv_doorbell' and 1.5 or CAM[m] and 2.6 or nil
                if reach and math.abs(f.x - pos.x) < 4 and math.abs(f.y - pos.y) < 4 then
                    local d = #(pos - vector3(f.x, f.y, f.z + 0.4))
                    if d < reach and (not bd or d < bd) then
                        best, bd = f, d
                        if m == 'opslabs_cctv_doorbell' then label, act = '[E] Ring the doorbell  ·  [G] camera', 'bell'
                        elseif CAM[m] then label, act = '[E] Camera', 'cam'
                        elseif REC[m] then label, act = '[E] CCTV recorder', 'site'
                        else label, act = '[E] Watch CCTV', 'site' end
                    end
                end
            end
            if best then
                sleep = 0
                if shown ~= label then lib.showTextUI(label, { icon = 'video' }) shown = label end
                if IsControlJustPressed(0, 38) then
                    lib.hideTextUI() shown = nil
                    if act == 'bell' then
                        local r = lib.callback.await('opslabs-towers:cctv:ring', false, best.id)
                        PlaySoundFrontend(-1, 'DOOR_BUZZ', 'MP_PLAYER_APARTMENT', true)
                        lib.notify({ type = 'inform', description = r and r.offline and 'Ding dong… (the doorbell camera is offline)' or 'Ding dong — they’ve been notified' })
                    elseif act == 'cam' then cameraMenu(best)
                    else SiteMenu(best) end
                    Wait(400)
                elseif act == 'bell' and IsControlJustPressed(0, 47) then lib.hideTextUI() shown = nil cameraMenu(best) end
            elseif shown then lib.hideTextUI() shown = nil end
        elseif shown then lib.hideTextUI() shown = nil end
        Wait(sleep)
    end
end)
