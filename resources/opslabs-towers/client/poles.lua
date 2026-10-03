-- Telegraph poles: walk up to one and press E to climb it. On the pole: W / S up and down,
-- A / D move round it, G mounts equipment (CBT, DP, splice enclosure) at your height or
-- removes what's next to you, X climbs down.

local CC = Config.Cabling
local POLES = { opslabs_pole_07m = 7.0, opslabs_pole_10m = 10.0, opslabs_pole_13m = 13.0 }
local climbing = false

-- pole radius at a height (matches the model's taper)
local function radiusAt(H, z)
    local rb, rt = 0.115 + H * 0.002, 0.075
    return rb + (rt - rb) * math.max(0.0, math.min(1.0, z / H))
end

-- heading that points a prop's -Y front outward along d (= a ped facing back in towards the pole)
local function headingFor(dx, dy) return math.deg(math.atan(dx, -dy)) % 360 end

local function equipLabel(model)
    for _, e in ipairs(CC.Equipment) do if e.model == model then return e.label end end
    return model
end

local function canClimb()
    if not CC.ClimbJobs then return true end
    local ok, job = pcall(function() return exports.es_extended:getSharedObject().GetPlayerData().job.name end)
    if not ok then return true end
    for _, j in ipairs(CC.ClimbJobs) do if j == job then return true end end
    return false
end

local function nearestPole(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for _, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if POLES[f.model] then
            local d = #(vector2(pos.x, pos.y) - vector2(f.x, f.y))
            if d < (bd or maxDist) and pos.z > f.z - 1.5 and pos.z < f.z + 3.0 then best, bd = f, d end
        end
    end
    return best, bd
end

local function loadAnim(dict)
    if not DoesAnimDictExist(dict) then return false end
    RequestAnimDict(dict)
    local t = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - t < 2000 do Wait(0) end
    return HasAnimDictLoaded(dict)
end

local ANIM = 'laddersbase'

-- climbing poses, shared with ladders.lua:
--   up / down : the ladder climb cycle (hands and feet working up / down)
--   hold      : feet on the pegs, holding on
--   work      : holding on with the legs, hands working in front (upper-body layer on top)
local WORK_DICT, WORK_CLIP = 'amb@prop_human_movie_bulb@base', 'base'
ClimbAnims = { ladder = false, work = false, clip = nil, started = 0, cycleOk = true }

function ClimbAnims.load()
    ClimbAnims.ladder = loadAnim(ANIM)
    ClimbAnims.work = loadAnim(WORK_DICT)
    ClimbAnims.clip, ClimbAnims.cycleOk = nil, true
    return ClimbAnims.ladder
end

function ClimbAnims.set(ped, state)
    if not ClimbAnims.ladder then return end
    local clip = (state == 'up' and 'climb_up') or (state == 'down' and 'climb_down') or 'base_left_hand_up'
    if clip ~= 'base_left_hand_up' and not ClimbAnims.cycleOk then clip = 'base_left_hand_up' end
    if ClimbAnims.clip ~= clip then
        TaskPlayAnim(ped, ANIM, clip, 4.0, 4.0, -1, 1, 0, false, false, false)
        ClimbAnims.clip, ClimbAnims.started = clip, GetGameTimer()
    elseif not IsEntityPlayingAnim(ped, ANIM, clip, 3) then
        -- a climb clip that never starts isn't in this game build: fall back to the hold pose
        if clip ~= 'base_left_hand_up' and GetGameTimer() - ClimbAnims.started > 400 then ClimbAnims.cycleOk = false end
        TaskPlayAnim(ped, ANIM, clip, 4.0, 4.0, -1, 1, 0, false, false, false)
    end
    if state == 'work' and ClimbAnims.work then
        if not IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) then
            TaskPlayAnim(ped, WORK_DICT, WORK_CLIP, 3.0, 3.0, -1, 49, 0, false, false, false)   -- upper body, looped
        end
    elseif IsEntityPlayingAnim(ped, WORK_DICT, WORK_CLIP, 3) then
        StopAnimTask(ped, WORK_DICT, WORK_CLIP, 2.0)
    end
end

function ClimbAnims.unload(ped)
    if ClimbAnims.work then StopAnimTask(ped, WORK_DICT, WORK_CLIP, 2.0) RemoveAnimDict(WORK_DICT) end
    if ClimbAnims.ladder then RemoveAnimDict(ANIM) end
    ClimbAnims.clip = nil
end

---------------------------------------------------------------------------
-- equipment on the pole
---------------------------------------------------------------------------

local function poleMenu(pole, H, angle, h, onClose)
    local options = {}
    local z = pole.z + h + 1.2                      -- roughly chest height
    local d = vector2(math.cos(angle), math.sin(angle))
    local r = radiusAt(H, z - pole.z)
    for _, e in ipairs(CC.Equipment) do
        if e.pole and IsModelInCdimage(joaat(e.model)) then
            local blocked = false
            for _, f in pairs(CablingFixtures()) do
                if not POLES[f.model] and math.abs(f.z - (z - 0.15)) < 0.5 and #(vector2(f.x, f.y) - vector2(pole.x, pole.y)) < 0.4 then
                    local fa = math.atan(f.y - pole.y, f.x - pole.x)
                    local diff = math.abs((fa - angle + math.pi) % (2 * math.pi) - math.pi)
                    if diff < math.rad(70) then blocked = true end
                end
            end
            options[#options + 1] = { title = 'Mount: ' .. e.label, disabled = blocked,
                description = blocked and 'No room — something is already fitted here. Move up, down or round the pole.' or ('At %.1f m, on this side of the pole'):format(z - pole.z),
                icon = 'plus', onSelect = function()
                local done = lib.progressBar({ duration = 4000, label = 'Strapping the bracket to the pole', canCancel = true,
                    disable = { move = true, combat = true } })
                if done then
                    local res = lib.callback.await('opslabs-towers:fixture:save', false, {
                        model = e.model, x = pole.x + d.x * r, y = pole.y + d.y * r, z = z - 0.15, heading = headingFor(d.x, d.y) })
                    if res and res.ok then
                        PlaySoundFrontend(-1, 'PICK_UP', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
                        lib.notify({ type = 'success', description = e.label .. ' mounted' })
                    else
                        lib.notify({ type = 'error', description = (res and res.error == 'not allowed') and 'Only network engineers can fit equipment' or (res and res.error) or 'Failed' })
                    end
                end
                onClose()
            end }
        end
    end
    -- what's already on the pole near you
    for _, f in pairs(CablingFixtures()) do
        if not POLES[f.model] and #(vector3(f.x, f.y, f.z) - vector3(pole.x, pole.y, z)) < 1.6 then
            options[#options + 1] = { title = 'Remove: ' .. equipLabel(f.model), description = ('At %.1f m'):format(f.z - pole.z), icon = 'trash', iconColor = '#ff5a5f', onSelect = function()
                if lib.progressBar({ duration = 3000, label = 'Unbolting it from the pole', canCancel = true, disable = { move = true, combat = true } }) then
                    if not lib.callback.await('opslabs-towers:fixture:delete', false, f.id) then
                        lib.notify({ type = 'error', description = 'Only network engineers can remove equipment' })
                    end
                end
                onClose()
            end }
        end
    end
    if #options == 0 then options[1] = { title = 'Nothing to fit here', readOnly = true } end
    lib.registerContext({ id = 'pole_equipment', title = 'On the pole', options = options, onExit = onClose })
    lib.showContext('pole_equipment')
end

---------------------------------------------------------------------------
-- climbing
---------------------------------------------------------------------------

-- pole steps (pegs) on the model: every 0.4 m from 2.4 m up to 1 m below the top
local function nearestPeg(H, feet)
    if feet < 2.2 then return nil end
    local k = math.floor((feet - 2.4) / 0.4 + 0.5)
    local z = 2.4 + math.max(0, k) * 0.4
    if z > H - 1.0 then z = z - 0.4 end
    return z
end

local function climb(pole)
    local H = POLES[pole.model]
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local angle = math.atan(pos.y - pole.y, pos.x - pole.x)
    local h = 0.0                                   -- feet height above the pole base
    local top = H - 1.9
    local menuOpen = false
    local still = 0.0                               -- seconds without moving
    climbing = true

    local haveAnim = ClimbAnims.load()
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)

    local sf = PlaceHud.buttons({ { 'Climb', { 32, 33 } }, { 'Move round', { 34, 35 } }, { 'Equipment', 47 }, { 'Climb down', 73 } })
    local leaving = false
    local last = GetGameTimer()
    while climbing do
        Wait(0)
        local now = GetGameTimer()
        local dt = math.min(0.1, (now - last) / 1000)
        last = now
        for _, ctl in ipairs({ 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 44, 47, 73, 140, 141, 142 }) do DisableControlAction(0, ctl, true) end
        DisablePlayerFiring(PlayerId(), true)

        local state = 'hold'
        if leaving then
            h = h - 1.6 * dt                        -- climbing down
            state = 'down'
            if h <= 0 then break end
        elseif not menuOpen then
            local up, down = IsDisabledControlPressed(0, 32) and h < top, IsDisabledControlPressed(0, 33) and h > 0
            if up then h = math.min(top, h + CC.ClimbSpeed * dt) state = 'up' end
            if down then h = math.max(0.0, h - CC.ClimbSpeed * dt) state = 'down' end
            if IsDisabledControlPressed(0, 34) then angle = angle + 1.4 * dt end
            if IsDisabledControlPressed(0, 35) then angle = angle - 1.4 * dt end
            if up or down then
                still = 0.0
                if math.floor(h / 0.4) ~= math.floor((h + (up and -1 or 1) * CC.ClimbSpeed * dt) / 0.4) then
                    PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true)   -- boot on the next step
                end
            else
                still = still + dt
                -- settle the feet onto the nearest pair of pegs
                local peg = nearestPeg(H, h)
                if peg then
                    local d = peg - h
                    h = h + math.max(-0.8 * dt, math.min(0.8 * dt, d))
                end
            end
            if IsDisabledControlJustPressed(0, 47) then
                menuOpen = true
                poleMenu(pole, H, angle, h, function() menuOpen = false end)
            end
            if IsDisabledControlJustPressed(0, 73) then
                if h <= 0.3 then break end
                leaving = true
            end
        end
        if state == 'hold' and (menuOpen or (still > 0.7 and h > 1.5)) then state = 'work' end

        local zc = h + 1.0
        local r = radiusAt(H, zc) + 0.27            -- in close, legs round the pole
        local x, y = pole.x + math.cos(angle) * r, pole.y + math.sin(angle) * r
        SetEntityCoordsNoOffset(ped, x, y, pole.z + zc, false, false, false)
        -- face the pole. The ladder clip is authored facing backwards, so turn round while it plays
        SetEntityHeading(ped, (headingFor(math.cos(angle), math.sin(angle)) + ((haveAnim and CC.ClimbAnimFlip ~= false) and 180.0 or 0.0)) % 360)
        ClimbAnims.set(ped, state)
        PlaceHud.draw(sf, ('On the %d m pole'):format(math.floor(H)), leaving and 'Climbing down…'
            or ('Height %.1f m%s'):format(h + 1.0, (nearestPeg(H, h) and math.abs(nearestPeg(H, h) - h) < 0.02) and '   ·   feet on the steps' or ''), { 140, 100, 60 })
        if IsPedDeadOrDying(ped, true) then break end
    end

    PlaceHud.release(sf)
    lib.hideContext(false)
    local r = radiusAt(H, 0) + 0.7
    ClimbAnims.unload(ped)
    ClearPedTasks(ped)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetEntityCoords(ped, pole.x + math.cos(angle) * r, pole.y + math.sin(angle) * r, pole.z + 0.1, false, false, false, false)
    climbing = false
end

---------------------------------------------------------------------------
-- prompt at the base of a pole
---------------------------------------------------------------------------

CreateThread(function()
    local shown = false
    while true do
        local pole = not climbing and not NearLadder and not IsPedInAnyVehicle(PlayerPedId(), false) and nearestPole(1.3)
        if pole then
            if not shown then lib.showTextUI('[E] Climb the pole', { icon = 'person-arrow-up-from-line' }) shown = true end
            Wait(0)
            if IsControlJustPressed(0, 38) then
                lib.hideTextUI() shown = false
                if canClimb() then climb(pole)
                else lib.notify({ type = 'error', description = 'You need climbing gear and training for that' }) end
            end
        else
            if shown then lib.hideTextUI() shown = false end
            Wait(400)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and climbing then
        local ped = PlayerPedId()
        climbing = false
        ClearPedTasks(ped)
        SetEntityCollision(ped, true, true)
        FreezeEntityPosition(ped, false)
    end
end)
