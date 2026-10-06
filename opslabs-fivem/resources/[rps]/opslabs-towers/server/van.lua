-- OPS van roof spotlight: the server writes the van's 'spot' state bag so anyone inside can work it
-- (clients may only write state on vehicles they own, which passengers don't).
local S = (Config.Van or {}).Spotlight or {}
local lastMsg = {}

local function num(v, lo, hi) v = tonumber(v) or 0.0 return math.max(lo, math.min(hi, v)) end

RegisterNetEvent('opslabs-towers:van:spot', function(net, d)
    local src = source
    local now = GetGameTimer()
    if lastMsg[src] and now - lastMsg[src] < 50 then return end
    lastMsg[src] = now
    local veh = NetworkGetEntityFromNetworkId(tonumber(net) or -1)
    if veh == 0 or not DoesEntityExist(veh) or Entity(veh).state.opsvan ~= true then return end
    local ped = GetPlayerPed(src)
    local inside = GetVehiclePedIsIn(ped, false) == veh
    local st = Entity(veh).state
    if d == false or (type(d) == 'table' and d.fit) then          -- fitting / removing happens at the back doors
        if inside or #(GetEntityCoords(ped) - GetEntityCoords(veh)) > 8.0 or not CanCable(src) then return end
        st:set('spot', d and { on = false, s = 0.0, r = 0.0, p = 0.0, t = 0.0 } or nil, true)
        return
    end
    if type(d) ~= 'table' or not inside or not st.spot then return end
    st:set('spot', { on = d.on == true, s = num(d.s, -(S.Slide or 0.62), S.Slide or 0.62), r = num(d.r, 0.0, S.Raise or 0.35),
        p = num(d.p, -180.0, 180.0), t = num(d.t, S.TiltDown or -50.0, S.TiltUp or 40.0) }, true)
end)

AddEventHandler('playerDropped', function() lastMsg[source] = nil end)
