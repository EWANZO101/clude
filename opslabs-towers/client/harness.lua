-- Safety harness: wear it, check it, and once you're up a pole clip the pole strap round the
-- pole. While clipped you can't climb down or step off until you unclip; work at height (fault
-- repairs) needs it clipped. The harness key (Config.Harness.Key, default J, rebindable) opens
-- the menu — it never touches G (pole / ladder equipment menu). Everyone nearby sees the orange
-- pole strap and the lanyard between the climber and the pole (synced through a state bag).

local CH = Config.Harness or { Key = 'J', ClipSeconds = 2.5, WearSeconds = 3.0, ShowOthers = 60.0 }
local clipped = nil             -- { pole = id, x, y } while clipped on
local checkedAt = nil           -- game timer of the last pre-use check
local busy = false

local function worn() return HarnessOn and HarnessOn() or false end

function HarnessKeyLabel()
    local k = (GetControlInstructionalButton(0, joaat('opsharness') | 0x80000000, true) or ''):gsub('^t_', '')
    return '[' .. (k ~= '' and k or CH.Key or 'J') .. ']'
end

--- clipped on (to a given pole, when poleId is passed)
function HarnessClipped(poleId)
    if not clipped then return false end
    return poleId == nil or clipped.pole == poleId
end

local function publish()
    LocalPlayer.state:set('opsHarness', { worn = worn(), clipped = clipped ~= nil, pole = clipped and clipped.pole or nil,
        x = clipped and clipped.x or nil, y = clipped and clipped.y or nil }, true)
end

function HarnessForceOff()
    if clipped then clipped = nil publish() end
end

local function progress(label, secs)
    busy = true
    ClimbPaused = PoleClimb ~= nil
    local ok = lib.progressBar({ duration = math.floor(secs * 1000), label = label, canCancel = true, disable = { move = true, combat = true, car = true } })
    ClimbPaused = false
    busy = false
    return ok
end

local function clipOn()
    local c = PoleClimb
    if not c then return lib.notify({ type = 'error', description = 'Climb the pole first, then clip on' }) end
    if not worn() then return lib.notify({ type = 'error', description = 'Put your harness on first' }) end
    if not checkedAt then lib.notify({ type = 'warning', description = 'Tip: do a pre-use check of the harness before you rely on it' }) end
    TriggerEvent('opslabs:harness', 'strap')
    if progress('Passing the pole strap round the pole and clipping on', CH.ClipSeconds or 2.5) then
        clipped = { pole = c.pole.id, x = c.pole.x, y = c.pole.y }
        publish()
        TriggerEvent('opslabs:harness', 'clip')
        if GetResourceState('opslabs-animations') ~= 'started' then PlaySoundFrontend(-1, 'CLICK_BACK', 'WEB_NAVIGATION_SOUNDS_PHONE', true) end
        lib.notify({ type = 'success', description = 'Clipped on — you can lean back and work hands-free' })
    end
end

local function unclip()
    if not clipped then return end
    if progress('Unclipping the pole strap', 1.5) then
        clipped = nil
        publish()
        TriggerEvent('opslabs:harness', 'unclip')
        lib.notify({ type = 'inform', description = PoleClimb and 'Unclipped — three points of contact on the way down' or 'Unclipped' })
    end
end

function HarnessMenu()
    if busy then return end
    local c = PoleClimb
    local w = worn()
    local status = (w and 'Harness on' or 'Harness off') .. ' · ' .. (clipped and ('clipped on to pole #' .. tostring(clipped.pole)) or 'not clipped on')
    local checked = checkedAt and ('checked %d min ago'):format(math.floor((GetGameTimer() - checkedAt) / 60000)) or 'not checked yet'
    local options = {
        { title = status, description = 'Pre-use check: ' .. checked, icon = clipped and 'link' or 'link-slash', iconColor = clipped and '#30d158' or (w and '#ff9f0a' or '#8e8e93'), readOnly = true },
    }
    if clipped then
        options[#options + 1] = { title = 'Unclip from the pole', description = 'Do this before you climb down or step on to a ladder', icon = 'link-slash', onSelect = unclip }
    elseif c then
        options[#options + 1] = { title = 'Clip on to this pole', description = ('Pole strap round the pole at %.1f m · lanyard to your harness'):format(c.h + 1.0),
            icon = 'link', iconColor = '#30d158', disabled = not w, onSelect = clipOn }
    end
    if not c then
        options[#options + 1] = { title = w and 'Take the harness off' or 'Put the harness on', icon = 'vest', disabled = clipped ~= nil,
            description = w and 'Stow it in the van' or 'Full-body harness, pole strap and lanyard',
            onSelect = function()
                if progress(w and 'Taking the harness off' or 'Putting the harness on and adjusting the straps', CH.WearSeconds or 3.0) then
                    if HarnessSet then HarnessSet(not w) end
                    publish()
                    TriggerEvent('opslabs:harness', w and 'off' or 'on')
                    lib.notify({ type = w and 'inform' or 'success', description = w and 'Harness off' or ('Harness on · clip on once you are up the pole: ' .. HarnessKeyLabel()) })
                end
            end }
    end
    options[#options + 1] = { title = 'Pre-use check', description = 'Webbing, stitching, buckles, karabiner gate and the lanyard', icon = 'clipboard-check', disabled = not w,
        onSelect = function()
            TriggerEvent('opslabs:harness', 'check')
            if progress('Checking webbing, stitching, buckles and karabiner', 4.0) then
                checkedAt = GetGameTimer()
                lib.notify({ type = 'success', description = 'Harness checked · no cuts, fraying or damaged hardware' })
            end
        end }
    lib.registerContext({ id = 'opslabs_harness', title = 'Safety harness', root = true, options = options })
    lib.showContext('opslabs_harness')
end

RegisterCommand('opsharness', function() HarnessMenu() end, false)
RegisterKeyMapping('opsharness', 'OPS Network: safety harness (clip on / off)', 'keyboard', CH.Key or 'J')

---------------------------------------------------------------------------
-- what everyone sees: the pole strap at the climber's waist and the lanyard to it
---------------------------------------------------------------------------

local props = {}   -- server id -> { strap, lanyard }

local function model(name)
    local h = joaat(name)
    if not IsModelInCdimage(h) then return nil end
    lib.requestModel(h, 3000)
    return h
end

local function spawnPair(sid)
    local hs, hl = model('opslabs_harness_strap'), model('opslabs_lanyard')
    if not hs or not hl then return nil end
    local p = { strap = CreateObjectNoOffset(hs, 0.0, 0.0, -100.0, false, false, false), lanyard = CreateObjectNoOffset(hl, 0.0, 0.0, -100.0, false, false, false) }
    for _, e in pairs(p) do SetEntityCollision(e, false, false) FreezeEntityPosition(e, true) end
    props[sid] = p
    return p
end

local function dropPair(sid)
    local p = props[sid]
    if p then for _, e in pairs(p) do if DoesEntityExist(e) then DeleteEntity(e) end end end
    props[sid] = nil
end

CreateThread(function()
    while true do
        local me = PlayerPedId()
        local pos = GetEntityCoords(me)
        local seen = {}
        for _, pid in ipairs(GetActivePlayers()) do
            local ped = GetPlayerPed(pid)
            local sid = GetPlayerServerId(pid)
            local st = Player(sid).state.opsHarness
            if type(st) == 'table' and st.clipped and st.x and #(pos - GetEntityCoords(ped)) < (CH.ShowOthers or 60.0) then
                seen[sid] = true
                local p = props[sid] or spawnPair(sid)
                if p then
                    local hip = GetPedBoneCoords(ped, 11816, 0.0, 0.0, 0.0)     -- pelvis
                    local dx, dy = hip.x - st.x, hip.y - st.y
                    local dl = math.sqrt(dx * dx + dy * dy)
                    if dl > 0.01 then dx, dy = dx / dl, dy / dl end
                    local sz = hip.z - 0.05
                    -- strap round the pole, D-ring (model -Y) facing the climber
                    SetEntityCoordsNoOffset(p.strap, st.x, st.y, sz, false, false, false)
                    SetEntityHeading(p.strap, math.deg(math.atan(dx, -dy)) % 360)
                    -- lanyard: from the D-ring to the harness, stretched to fit
                    local a = vector3(st.x + dx * 0.195, st.y + dy * 0.195, sz)
                    local b = hip + vector3(-dx * 0.08, -dy * 0.08, 0.02)
                    local f = b - a
                    local L = #f
                    if L > 0.02 then
                        local fn = f / L
                        local r = vector3(fn.y, -fn.x, 0.0)
                        if #r < 0.01 then r = vector3(1.0, 0.0, 0.0) end
                        r = r / #r
                        local u = vector3(r.y * fn.z - r.z * fn.y, r.z * fn.x - r.x * fn.z, r.x * fn.y - r.y * fn.x)
                        SetEntityMatrix(p.lanyard, fn.x * L, fn.y * L, fn.z * L, r.x, r.y, r.z, u.x, u.y, u.z, a.x, a.y, a.z)
                    end
                end
            end
        end
        for sid in pairs(props) do if not seen[sid] then dropPair(sid) end end
        Wait(next(props) and 0 or 750)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for sid in pairs(props) do dropPair(sid) end
    if clipped then clipped = nil publish() end
end)
