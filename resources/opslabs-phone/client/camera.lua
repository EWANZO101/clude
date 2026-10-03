-- Camera app: a scripted camera that the phone UI shows live inside its screen
-- (the NUI reads the game view through WebGL, so no screenshot resource is
-- needed). The phone stays open: drag on the viewfinder to aim, WASD to walk.
--   rear  : held at eye height in front of the face, ped turns with it
--   front : selfie at arm's length, looking back at the player
-- Zoom changes the FOV like the iPhone lenses, Portrait uses real depth of field.

CameraActive = false

local cam
local front = false
local yaw, pitch = 0.0, 0.0           -- rear camera aim
local sYaw, sPitch = 0.0, 8.0         -- selfie orbit around the face
local zoom, fov = 1.0, 50.0
local portrait = false
local dragging = false
local focusDist = 6.0
local flashUntil = 0
local torch = false

local BASE_FOV = 50.0                 -- "1x"
local HEAD = 31086

local function fovForZoom(z)
    -- same field of view a real lens with this zoom factor would give
    return math.max(6.0, math.min(95.0, 2.0 * math.deg(math.atan(math.tan(math.rad(BASE_FOV / 2)) / z))))
end

local function dir(p, y)
    local rp, ry = math.rad(p), math.rad(y)
    return vector3(-math.sin(ry) * math.cos(rp), math.cos(ry) * math.cos(rp), math.sin(rp))
end

local function lookRot(from, to)
    local d = to - from
    return math.deg(math.atan(d.z, math.sqrt(d.x * d.x + d.y * d.y))), math.deg(math.atan(-d.x, d.y))
end

--- distance to whatever is under the given screen point (0..1), for focus / portrait
local function probe(pos, p, y, u, v)
    local aspect = GetAspectRatio(false)
    local tv = math.tan(math.rad(fov / 2))
    local yo = math.deg(math.atan(-(u - 0.5) * 2 * tv * aspect))
    local po = math.deg(math.atan(-(v - 0.5) * 2 * tv))
    local target = pos + dir(p + po, y + yo) * 60.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(pos.x, pos.y, pos.z, target.x, target.y, target.z, -1, PlayerPedId(), 4)
    local _, hit, at = GetShapeTestResult(ray)
    if hit == 1 then return #(at - pos) end
    return 40.0
end

local function stopCamera(silent)
    if not CameraActive then return end
    CameraActive = false
    dragging = false
    RenderScriptCams(false, true, 250, true, true)
    if cam then DestroyCam(cam, false) cam = nil end
    ClearFocus()
    if not silent then SendNUIMessage({ action = 'cameraClosed' }) end
    if PhoneOpen then PlayPhoneAnim('text') end
end
StopPhoneCamera = stopCamera

local function startCamera(data)
    if CameraActive then return end
    local ped = PlayerPedId()
    CameraActive = true
    front = data and data.front == true
    zoom, fov = 1.0, BASE_FOV
    portrait = false
    yaw, pitch = GetEntityHeading(ped), 0.0
    sYaw, sPitch = 0.0, 8.0

    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamFov(cam, fov)
    RenderScriptCams(true, true, 250, true, true)
    PlayPhoneAnim(front and 'text' or 'camera')

    CreateThread(function()
        local lastProbe = 0
        while CameraActive do
            ped = PlayerPedId()
            local inVeh = IsPedInAnyVehicle(ped, false)
            local head = GetPedBoneCoords(ped, HEAD, 0.0, 0.0, 0.0)

            -- look around while the viewfinder is being dragged
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)
            if dragging then
                local sens = 9.0 * (fov / BASE_FOV)
                local mx, my = GetDisabledControlNormal(0, 1), GetDisabledControlNormal(0, 2)
                if front then
                    sYaw = math.max(-70.0, math.min(70.0, sYaw + mx * 9.0))
                    sPitch = math.max(-25.0, math.min(40.0, sPitch + my * 6.0))
                else
                    yaw = yaw - mx * sens
                    pitch = math.max(-75.0, math.min(75.0, pitch - my * sens))
                end
            end

            local pos, rp, ry
            if front then
                local h = GetEntityHeading(ped) + sYaw
                pos = head + dir(sPitch, h) * 0.62 + vector3(0.0, 0.0, 0.02)
                rp, ry = lookRot(pos, head + vector3(0.0, 0.0, 0.01))
            else
                if not inVeh then
                    SetEntityHeading(ped, yaw)
                    SetGameplayCamRelativeHeading(0.0)
                end
                pos = head + dir(0.0, yaw) * 0.42 + vector3(0.0, 0.0, 0.03) -- just past the phone in the hands
                rp, ry = pitch, yaw
            end

            fov = fov + (fovForZoom(front and 1.0 or zoom) - fov) * 0.25
            SetCamCoord(cam, pos.x, pos.y, pos.z)
            SetCamRot(cam, rp, 0.0, ry, 2)
            SetCamFov(cam, fov)
            SetFocusPosAndVel(pos.x, pos.y, pos.z, 0.0, 0.0, 0.0)

            -- Portrait: real depth of field focused on the subject
            if portrait then
                local now = GetGameTimer()
                if not front and now - lastProbe > 400 then lastProbe = now; focusDist = probe(pos, rp, ry, 0.5, 0.5) end
                local f = front and 0.62 or focusDist
                SetUseHiDof()
                SetCamUseShallowDofMode(cam, true)
                SetCamNearDof(cam, math.max(0.05, f * 0.6))
                SetCamFarDof(cam, f * 1.35 + 0.4)
                SetCamDofStrength(cam, 1.0)
            else
                SetCamUseShallowDofMode(cam, false)
                SetCamDofStrength(cam, 0.0)
            end

            -- flash / torch light from the phone
            if torch or flashUntil > GetGameTimer() then
                local at = pos + dir(rp, ry) * 0.25
                DrawLightWithRange(at.x, at.y, at.z, 255, 250, 240, front and 3.0 or 14.0, torch and 2.0 or 8.0)
            end

            HideHudAndRadarThisFrame()
            DisableControlAction(0, 0, true)    -- change view
            DisableControlAction(0, 24, true)   -- attack
            DisableControlAction(0, 25, true)   -- aim
            DisableControlAction(0, 37, true)   -- weapon wheel
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 199, true)
            DisableControlAction(0, 200, true)
            DisablePlayerFiring(PlayerId(), true)
            if not PhoneOpen then break end
            Wait(0)
        end
        stopCamera(not PhoneOpen)
    end)
end

RegisterNUICallback('cameraStart', function(data, cb)
    startCamera(data)
    cb({ ok = true, aspect = GetAspectRatio(false) })
end)

RegisterNUICallback('cameraStop', function(_, cb)
    stopCamera(true)
    cb(true)
end)

RegisterNUICallback('cameraSet', function(data, cb)
    if data.front ~= nil and data.front ~= front then
        front = data.front == true
        sYaw, sPitch = 0.0, 8.0
        if not front then yaw, pitch = GetEntityHeading(PlayerPedId()), 0.0 end
        -- selfie: phone held low so the hands don't cover the face
        PlayPhoneAnim(front and 'text' or 'camera')
    end
    if data.zoom then zoom = math.max(0.5, math.min(15.0, tonumber(data.zoom) or 1.0)) end
    if data.portrait ~= nil then portrait = data.portrait == true end
    if data.torch ~= nil then torch = data.torch == true end
    cb(true)
end)

RegisterNUICallback('cameraDrag', function(data, cb)
    dragging = data.on == true
    cb(true)
end)

-- tap to focus: refocus the depth of field on what was tapped
RegisterNUICallback('cameraFocus', function(data, cb)
    if CameraActive and cam and not front then
        local c, r = GetCamCoord(cam), GetCamRot(cam, 2)
        focusDist = probe(c, r.x, r.z, tonumber(data.u) or 0.5, tonumber(data.v) or 0.5)
    end
    cb({ distance = focusDist })
end)

RegisterNUICallback('cameraFlash', function(data, cb)
    flashUntil = GetGameTimer() + math.min(tonumber(data.ms) or 250, 1500)
    cb(true)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stopCamera(true) end
end)
