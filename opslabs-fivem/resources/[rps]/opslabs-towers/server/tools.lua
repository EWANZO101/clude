-- Electrical safety state on placed power poles (SAPL tools): fuses pulled with the operating rod, portable earths on.
-- A pole reads DEAD on the voltage detector when its fuses are out; earths may only go on a dead pole.
local Power = {}            -- [poleId] = { fusesOut = bool, earthed = bool }

local function isPowerPole(id)
    local f = Cabling.fixtures[id]
    return f and f.model:find('^opslabs_power_pole') ~= nil, f
end

lib.callback.register('opslabs-towers:power:states', function() return Power end)

--- fuses out / earthed on a placed power pole (the mains network reads this)
function PolePowerState(id) return Power[id] end
--- OPS Hub (server/grid.lua GridAction): pull / refit a pole's cut-out fuses or take its earths off from control
function PoleSetPower(id, key, value)
    id = tonumber(id)
    local f = id and Cabling.fixtures[id]
    if not f or not f.model:find('^opslabs_power_pole') then return nil, 'Not a power pole' end
    local s = Power[id] or { fusesOut = false, earthed = false }
    if key == 'fusesOut' then
        if not value and s.earthed then return nil, 'Working earths are on — take them off first' end
        s.fusesOut = value == true
    elseif key == 'earthed' then
        if value then return nil, 'Earths can only be fitted on site' end
        s.earthed = false
    else return nil, 'bad request' end
    Power[id] = s
    TriggerClientEvent('opslabs-towers:power', -1, id, s)
    if MainsDirty then MainsDirty() end
    return true
end

--- the power restoration kit: earths off, fuses in
function PoleRestore(id)
    id = tonumber(id)
    Power[id] = { fusesOut = false, earthed = false }
    TriggerClientEvent('opslabs-towers:power', -1, id, Power[id])
    if MainsDirty then MainsDirty() end
end

lib.callback.register('opslabs-towers:power:set', function(src, id, key, value)
    id = tonumber(id)
    if not CanCable(src) then return { error = 'Only engineers can work on the network' } end
    local ok, f = isPowerPole(id)
    if not ok then return { error = 'Not a power pole' } end
    local ped = GetPlayerPed(src)
    if #(GetEntityCoords(ped) - vector3(f.x, f.y, f.z)) > 25.0 then return { error = 'Too far away' } end
    local s = Power[id] or { fusesOut = false, earthed = false }
    if key == 'earthed' then
        if value and not s.fusesOut then return { error = 'live' } end
        s.earthed = value == true
    elseif key == 'fusesOut' then
        if not value and s.earthed then return { error = 'Take the earths off before putting the fuses back in' } end
        s.fusesOut = value == true
    else
        return { error = 'bad request' }
    end
    Power[id] = s
    TriggerClientEvent('opslabs-towers:power', -1, id, s)
    if MainsDirty then MainsDirty() end
    return { ok = true, state = s }
end)
