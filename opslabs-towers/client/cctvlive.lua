-- OPS Secure CCTV live on OPS Hub (server/cctvlive.lua). Whatever camera this game is showing — in the CCTV viewer, or
-- as a CCTV relay (/cctvrelay) — is grabbed as a small JPEG (html/cctvcap.js) and sent to the server for OPS Hub.

local CV = Config.Cctv or {}
if not CV.Enabled then return end

local seq, lastAt = 0, 0
local function capture(camId, q)
    seq = seq + 1
    SendNUIMessage({ action = 'cctvCapture', cam = camId, seq = seq, w = 640, h = 360, q = q or 0.6 })
end

RegisterNUICallback('cctvFrame', function(body, cb)
    cb(true)
    if type(body) ~= 'table' or type(body.jpg) ~= 'string' or #body.jpg < 200 then return end
    TriggerLatentServerEvent('opslabs-towers:cctv:frame', 120000, tonumber(body.cam), body.jpg)
end)

--- the in-game viewer calls this every frame with the camera on screen: one picture a second goes to OPS Hub
function CctvLiveTick(camId)
    local now = GetGameTimer()
    if now - lastAt < 1000 then return end
    lastAt = now
    capture(camId)
end
function CctvLiveStop() TriggerServerEvent('opslabs-towers:cctv:stopWatching') end

---------------------------------------------------------------------------
-- relay: show the cameras OPS Hub viewers have open, one after another, and send each picture
---------------------------------------------------------------------------

local relaying = false
local relayGoHome = nil       -- puts the relay's ped back (set while relaying)
local function txt(x, y, s, scale, r, g, b)
    SetTextFont(4) SetTextScale(scale, scale) SetTextColour(r or 255, g or 255, b or 255, 230) SetTextOutline()
    BeginTextCommandDisplayText('STRING') AddTextComponentSubstringPlayerName(s) EndTextCommandDisplayText(x, y)
end

local function relay()
    local r = lib.callback.await('opslabs-towers:cctv:relay', false, true)
    if not r or r.error then return lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
    relaying = true
    lib.notify({ type = 'success', title = 'CCTV relay', description = 'On — your screen shows the cameras OPS Hub viewers are watching. /cctvrelay or BACKSPACE to stop.', duration = 9000 })
    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    local current, label, lastPos = nil, 'Waiting for OPS Hub viewers…', nil
    -- players and cars only stream to a game near its ped: for cameras far from where the relay stands, its (hidden,
    -- frozen) ped goes with the camera and comes back when the relay stops
    local ped = PlayerPedId()
    local home, homeHeading, away = GetEntityCoords(ped), GetEntityHeading(ped), false
    local function goNear(c)
        local far = #(home - vector3(c.x, c.y, c.z)) > (CV.RelayMoveBeyond or 450.0)
        if far then
            if not away then
                away = true
                FreezeEntityPosition(ped, true)
                SetEntityVisible(ped, false, false)
                NetworkSetEntityInvisibleToNetwork(ped, true)
                SetEntityCollision(ped, false, false)
                SetEntityInvincible(ped, true)
            end
            SetEntityCoordsNoOffset(ped, c.x, c.y, c.z + 2.0, false, false, false)
        elseif away then
            SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false)
        end
    end
    local function goHome()
        relayGoHome = nil
        if not away then return end
        away = false
        SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false)
        SetEntityHeading(ped, homeHeading)
        SetEntityCollision(ped, true, true)
        NetworkSetEntityInvisibleToNetwork(ped, false)
        SetEntityVisible(ped, true, false)
        SetEntityInvincible(ped, false)
        FreezeEntityPosition(ped, false)
    end
    DisplayRadar(false)
    -- the overlay is drawn every frame (it's part of the picture the Hub gets, like a real NVR's)
    CreateThread(function()
        while relaying do
            Wait(0)
            DisableAllControlActions(0)
            EnableControlAction(0, 245, true) EnableControlAction(0, 249, true)
            if IsDisabledControlJustPressed(0, 177) then relaying = false end
            if not current then DrawRect(0.5, 0.5, 1.0, 1.0, 8, 10, 14, 255) end
            txt(0.03, 0.03, label, 0.5)
            txt(0.03, 0.065, ('%02d:%02d  OPS SECURE · LIVE'):format(GetClockHours(), GetClockMinutes()), 0.38, 200, 210, 220)
            if current and (GetGameTimer() // 600) % 2 == 0 then txt(0.92, 0.03, '● LIVE', 0.5, 255, 60, 60) end
        end
    end)
    relayGoHome = goHome
    while relaying do
        local list = lib.callback.await('opslabs-towers:cctv:relayNext', false) or {}
        if #list == 0 then
            if current then RenderScriptCams(false, false, 0, true, true) ClearFocus() ClearTimecycleModifier() SetNightvision(false) SetSeethrough(false) end
            current, label = nil, 'CCTV relay · waiting for OPS Hub viewers…'
            Wait(1500)
        end
        for _, c in ipairs(list) do
            if not relaying then break end
            local pos = vector3(c.x, c.y, c.z)
            SetCamCoord(cam, c.x, c.y, c.z)
            SetCamRot(cam, c.ptz and -15.0 or -12.0, 0.0, (c.heading or 0.0) + 180.0, 2)
            SetCamFov(cam, math.max(25.0, math.min(100.0, (c.fov or 90) * 0.8)))
            SetFocusPosAndVel(c.x, c.y, c.z, 0.0, 0.0, 0.0)
            if not current then RenderScriptCams(true, false, 0, true, true) end
            current = c.id
            label = ('%s · %s'):format(c.system or 'CCTV', c.name or ('Camera ' .. c.id))
            ClearTimecycleModifier()
            SetTimecycleModifier(c.status == 'fault_lens' and 'BlackOut' or 'scanline_cam_cheap')
            local h = GetClockHours()
            SetNightvision(c.ir and (h >= 20 or h < 6) or false)
            SetSeethrough(c.thermal or false)
            -- somewhere new: let the world (and the players / cars there) stream in round it before taking the picture
            if not lastPos or #(lastPos - pos) > 200.0 then
                goNear(c)
                NewLoadSceneStartSphere(c.x, c.y, c.z, 120.0, 0)
                local t0 = GetGameTimer()
                while not IsNewLoadSceneLoaded() and GetGameTimer() - t0 < 3000 do Wait(50) end
                NewLoadSceneStop()
                Wait(250)
            end
            lastPos = pos
            Wait(c.focus and 250 or 400)
            capture(c.id, c.focus and 0.7 or 0.55)
            Wait(150)
        end
    end
    lib.callback.await('opslabs-towers:cctv:relay', false, false)
    goHome()
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)
    ClearFocus()
    ClearTimecycleModifier()
    SetNightvision(false)
    SetSeethrough(false)
    DisplayRadar(true)
    lib.notify({ type = 'inform', title = 'CCTV relay', description = 'Off' })
end

RegisterCommand('cctvrelay', function()
    if relaying then relaying = false return end
    CreateThread(relay)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and relaying then
        relaying = false
        if relayGoHome then relayGoHome() end
        RenderScriptCams(false, false, 0, true, true)
        ClearFocus() ClearTimecycleModifier() SetNightvision(false) SetSeethrough(false) DisplayRadar(true)
    end
end)
