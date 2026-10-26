-- Chest-mounted camera (optional realism): while recording, the game renders from a scripted camera clipped to the
-- officer's chest bone instead of their own free-look view, so the footage is a true body-worn-camera perspective -
-- fixed to the body's facing direction, not wherever the player aims the mouse. Technique, bone id, and offsets are
-- from Your-Spy/spy-bodycam's self-watch camera, adapted so the player keeps playing normally instead of being
-- teleported into a passive decoy ped (spy-bodycam's actual use case is watching someone else from outside).
--
-- Trade-off, by design: there's no way with these natives to render a second camera to an off-screen texture while
-- keeping the player's own view - RenderScriptCams replaces what's actually drawn to their screen, which is also
-- the same screen html/recorder.js captures as the recording. So while this is active the officer can't free-look
-- independent of their body heading: looking around means turning the character, same as a real chest cam. That's
-- why it's opt-in (Config.ChestCam.Enabled) rather than replacing the normal capture outright - it changes how
-- recording *feels to play through*, not just how the footage looks, and that's a real call for each server to make.

ChestCam = {}

local CC = Config.ChestCam or {}
local CHEST_BONE = 46240   -- same bone id spy-bodycam's AttachCamToPedBone call uses; left as-is, not re-derived

local cam = nil
local active = false
local inVehicleCam = false

local function footOffset()
    local o = CC.Offset or {}
    return o.x or 0.1, o.y or 0.025, o.z or 0.1
end

local function vehOffset()
    local o = CC.VehicleOffset or {}
    return o.x or 0.1, o.y or 0.25, o.z or -0.1
end

local function attach(ped, veh)
    local x, y, z = veh and vehOffset() or footOffset()
    AttachCamToPedBone(cam, ped, CHEST_BONE, x, y, z, true)
    inVehicleCam = veh
end

function ChestCam.Enabled()
    return CC.Enabled == true
end

function ChestCam.Start()
    if not ChestCam.Enabled() or active then return end
    local ped = PlayerPedId()
    cam = CreateCam('DEFAULT_SCRIPTED_FLY_CAMERA', true)
    attach(ped, IsPedInAnyVehicle(ped, false))
    SetCamFov(cam, CC.Fov or 100.0)
    SetCamRot(cam, 0.0, 0.0, GetEntityHeading(ped), 2)
    if CC.Shake then
        ShakeCam(cam, 'HAND_SHAKE', 1.0)
        SetCamShakeAmplitude(cam, CC.ShakeAmplitude or 0.3)
    end
    RenderScriptCams(true, false, 0, 1, 0)
    active = true

    -- follows the body's heading every frame (a real chest cam doesn't track your eyes), and swaps to the vehicle
    -- offset while seated - same idea as spy-bodycam's SetCamRotation()/SetCarCam() loops, merged into one
    CreateThread(function()
        while active do
            local p = PlayerPedId()
            SetCamRot(cam, 0.0, 0.0, GetEntityHeading(p), 2)
            local veh = IsPedInAnyVehicle(p, false)
            if veh ~= inVehicleCam then attach(p, veh) end
            Wait(0)
        end
    end)
end

function ChestCam.Stop()
    if not active then return end
    active = false
    RenderScriptCams(false, false, 0, 1, 0)
    if cam then
        DestroyCam(cam, false)
        cam = nil
    end
end

AddEventHandler('onResourceStop', function(r)
    if r == GetCurrentResourceName() and active then ChestCam.Stop() end
end)
