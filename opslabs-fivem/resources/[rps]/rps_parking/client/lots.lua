-- Keeps Config.ParkingLots in sync with the server (ParkingLots table, edited with the lot editor).
-- Fires the local event 'rps_parking:lotsChanged' after every update.

local function ApplyLots(encoded)
    if type(encoded) ~= 'table' then return end
    for i = #Config.ParkingLots, 1, -1 do Config.ParkingLots[i] = nil end
    for _, t in ipairs(encoded) do
        local lot = LotUtil.Decode(t)
        if lot then Config.ParkingLots[#Config.ParkingLots + 1] = lot end
    end
    TriggerEvent('rps_parking:lotsChanged')
end

AddStateBagChangeHandler('rps_parking_lots', 'global', function(_, _, value)
    ApplyLots(value)
end)

-- after every client file has registered its lotsChanged handler
CreateThread(function()
    if GlobalState.rps_parking_lots then ApplyLots(GlobalState.rps_parking_lots) end
end)
