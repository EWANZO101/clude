-- Network faults in game: engineers see a red marker over every open fault nearby, and next
-- to one press the repair key (Config.Faults.RepairKey, default U; rebindable) to diagnose it
-- and carry out the repair. Faults at height need you up the pole with your harness clipped on.
-- /cable → Network faults lists them all (distance, set waypoint, details).

local CF = Config.Faults or { Types = {} }
local list = {}                 -- active faults (from the server)
local engineer = false
local working = false
local SEV_COLOR = { critical = { 255, 59, 48 }, high = { 255, 149, 0 }, medium = { 255, 214, 10 }, low = { 142, 142, 147 } }
local SEV_HEX = { critical = '#ff3b30', high = '#ff9500', medium = '#ffd60a', low = '#8e8e93' }

RegisterNetEvent('opslabs-towers:faults', function(l) list = type(l) == 'table' and l or {} end)

CreateThread(function()
    while true do
        engineer = lib.callback.await('opslabs-towers:cable:can', false) == true
        Wait(engineer and 300000 or 60000)
    end
end)

function FaultSummary()
    local crit = 0
    for _, f in ipairs(list) do if f.severity == 'critical' then crit = crit + 1 end end
    if #list == 0 then return 'No open faults on the network' end
    return ('%d open fault%s%s · go there and repair them'):format(#list, #list == 1 and '' or 's', crit > 0 and (' · %d critical'):format(crit) or '')
end

local function reach(f) return (CF.RepairRange or 3.0) + (f.at_height and 1.0 or 0.0) + (f.asset and f.type == 'tower_power' and 12.0 or 0.0) end

local function nearest()
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for _, f in ipairs(list) do
        local d = #(pos - vector3(f.x, f.y, f.z))
        if d <= reach(f) and d < (bd or math.huge) then best, bd = f, d end
    end
    return best
end

--- the actual repair: harness check, progress bar, tell the server. `working` is re-asserted here regardless of
--- how the fix-steps menu closed, so there's never a window where a second repair can be started underneath it.
local function doRepair(full)
    working = true
    if full.at_height and CF.RequireHarness ~= false and not (HarnessClipped and HarnessClipped(full.pole_id)) then
        working = false
        return lib.notify({ type = 'error', description = 'Clip your harness on to this pole first (' .. (HarnessKeyLabel and HarnessKeyLabel() or 'J') .. ')' })
    end
    local t = CF.Types[full.type] or {}
    local onPole = PoleClimb ~= nil
    ClimbPaused = onPole
    local done = lib.progressBar({ duration = (t.repairSeconds or 25) * 1000, label = 'Repairing: ' .. full.label, canCancel = true,
        disable = { move = true, combat = true, car = true },
        anim = (not onPole) and { dict = 'mini@repair', clip = 'fixing_a_ped', flag = 49 } or nil })
    ClimbPaused = false
    if done then
        local r = lib.callback.await('opslabs-towers:faults:repair', false, full.id)
        if r and r.ok then
            PlaySoundFrontend(-1, 'Hack_Success', 'DLC_HEIST_BIOLAB_PREP_HACKING_SOUNDS', true)
            lib.notify({ type = 'success', title = 'Fault cleared', description = full.label .. ' repaired' .. ((full.affected_count or 0) > 0 and (' · %d customers back online'):format(full.affected_count) or '') })
        else
            lib.notify({ type = 'error', description = (r and r.error) or 'Repair failed' })
        end
    end
    working = false
end

--- step-by-step: diagnosis up top, tick each fix step off as you do it (just your own checklist — there's no way
--- to auto-verify flavour-text steps), then "Start repair" when you're ready. Mirrors coach.lua's guideMenu().
local function fixStepsMenu(full, checked)
    local options = {
        { title = full.label, description = (full.location or (full.asset and full.asset.label) or '') .. (full.symptoms and #full.symptoms > 0 and (' · ' .. table.concat(full.symptoms, ' · ')) or ''),
            icon = 'triangle-exclamation', iconColor = SEV_HEX[full.severity] or '#8e8e93', readOnly = true },
    }
    if full.diagnosis and full.diagnosis ~= '' then
        options[#options + 1] = { title = 'Diagnosis', description = full.diagnosis, icon = 'stethoscope', iconColor = '#636366', readOnly = true }
    end
    for i, step in ipairs(full.fix_steps or {}) do
        options[#options + 1] = { title = ('%d. %s'):format(i, step), icon = checked[i] and 'square-check' or 'square',
            iconColor = checked[i] and '#30d158' or '#8e8e93', onSelect = function() checked[i] = not checked[i] fixStepsMenu(full, checked) end }
    end
    if full.tools and #full.tools > 0 then
        options[#options + 1] = { title = 'Tools', description = table.concat(full.tools, ', '), icon = 'toolbox', iconColor = '#636366', readOnly = true }
    end
    if full.at_height then
        options[#options + 1] = { title = 'Work at height', description = 'Be up the pole with your harness clipped on', icon = 'person-falling', iconColor = '#ff9500', readOnly = true }
    end
    options[#options + 1] = { title = 'Start repair', icon = 'screwdriver-wrench', iconColor = '#0a84ff', onSelect = function() doRepair(full) end }
    options[#options + 1] = { title = 'Not now', icon = 'xmark', onSelect = function() working = false end }
    if PoleClimb or LadderClimb then ForceClassicMenus = true ClimbPaused = true end
    lib.registerContext({ id = 'fault_fix', root = true, title = ('Fault #%d'):format(full.id), options = options,
        onExit = function() ClimbPaused = false working = false end })
    lib.showContext('fault_fix')
end

--- diagnose → step through the fix → do the repair
local function repair(f)
    if working then return end
    working = true
    local d = lib.callback.await('opslabs-towers:faults:diagnose', false, f.id)
    if not d or not d.ok then
        working = false
        return lib.notify({ type = 'error', description = (d and d.error) or 'Could not reach the fault' })
    end
    fixStepsMenu(d.fault, {})
end

--- client/target.lua: is there a fault here this player can repair?
function FaultAtHand() return engineer and not working and nearest() ~= nil end

RegisterCommand('opsrepair', function()
    if not engineer or working then return end
    local f = nearest()
    if f then repair(f) end
end, false)
RegisterKeyMapping('opsrepair', 'OPS Network: repair the fault in front of you', 'keyboard', CF.RepairKey or 'U')
local function keyLabel() return (GetControlInstructionalButton(0, joaat('opsrepair') | 0x80000000, true) or ''):gsub('^t_', '') end

-- markers + prompt
CreateThread(function()
    local shown = nil
    while true do
        if not engineer or #list == 0 then
            if shown then lib.hideTextUI() shown = nil end
            Wait(1500)
        else
            local pos = GetEntityCoords(PlayerPedId())
            local any = false
            local t = GetGameTimer() / 1000
            for _, f in ipairs(list) do
                local d = #(pos - vector3(f.x, f.y, f.z))
                if d < 80.0 then
                    any = true
                    local c = SEV_COLOR[f.severity] or SEV_COLOR.medium
                    DrawMarker(0, f.x, f.y, f.z + 1.1 + math.sin(t * 2.5) * 0.08, 0, 0, 0, 0, 0, 0, 0.35, 0.35, 0.35, c[1], c[2], c[3], 190, false, true, 2, false, nil, nil, false)
                end
            end
            local near = not working and nearest()
            if near and shown ~= near.id then
                local k = keyLabel()
                lib.showTextUI(('[%s] Repair: %s'):format(k ~= '' and k or (CF.RepairKey or 'U'), near.label), { icon = 'screwdriver-wrench', style = { borderLeft = '4px solid ' .. (SEV_HEX[near.severity] or '#ff9500') } })
                shown = near.id
            elseif not near and shown then
                lib.hideTextUI() shown = nil
            end
            Wait(any and 0 or 1000)
        end
    end
end)

---------------------------------------------------------------------------
-- /cable → Network faults
---------------------------------------------------------------------------

local function ago(ts)
    if not ts then return '' end
    local s = math.max(0, GetCloudTimeAsInt() - ts)
    if s < 3600 then return ('%d min ago'):format(math.floor(s / 60)) end
    if s < 86400 then return ('%d h ago'):format(math.floor(s / 3600)) end
    return ('%d days ago'):format(math.floor(s / 86400))
end

function FaultsMenu()
    local pos = GetEntityCoords(PlayerPedId())
    local rows = {}
    for _, f in ipairs(list) do rows[#rows + 1] = { f = f, d = #(pos - vector3(f.x, f.y, f.z)) } end
    table.sort(rows, function(a, b) return a.d < b.d end)
    local options = {}
    if #rows == 0 then options[1] = { title = 'No open faults', description = 'The network is healthy. Faults appear here (and on the website and Ops-Networks app) when they happen.', icon = 'circle-check', iconColor = '#30d158', readOnly = true } end
    for _, r in ipairs(rows) do
        local f = r.f
        options[#options + 1] = {
            title = ('#%d · %s'):format(f.id, f.label), icon = 'triangle-exclamation', iconColor = SEV_HEX[f.severity],
            description = ('%s · %s · %.0f m away%s'):format(f.asset or '', f.severity, r.d, f.at_height and ' · at height' or ''),
            metadata = { { label = 'Status', value = f.status }, { label = 'Pole', value = f.pole_id and ('#' .. f.pole_id) or '—' } },
            arrow = true,
            onSelect = function()
                local sub = {
                    { title = 'Set waypoint', icon = 'location-dot', onSelect = function() SetNewWaypoint(f.x, f.y) lib.notify({ type = 'inform', description = 'Waypoint set to fault #' .. f.id }) end },
                    { title = 'Repair it', description = r.d <= reach(f) and 'You are at the fault' or 'Go to the fault first (red marker)', icon = 'screwdriver-wrench', disabled = r.d > reach(f), onSelect = function() repair(f) end },
                }
                lib.registerContext({ id = 'opslabs_fault_one', title = ('Fault #%d'):format(f.id), menu = 'opslabs_faults', options = sub })
                lib.showContext('opslabs_fault_one')
            end,
        }
    end
    lib.registerContext({ id = 'opslabs_faults', title = 'Network faults', options = options })
    lib.showContext('opslabs_faults')
end

AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() then lib.hideTextUI() end end)
