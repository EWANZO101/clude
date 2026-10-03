-- Relays climbing / harness sounds to players near the one making them (positions come from the server, not the client).
local RANGE = (Config.Sounds or {}).Range or 30.0
local NAMES = {}
for name in pairs((Config.Sounds or {}).Variants or {}) do NAMES[name] = true end
local last = {}

RegisterNetEvent('opslabs-animations:sfx', function(list)
    local src = source
    if type(list) ~= 'table' then return end
    local now = GetGameTimer()
    if last[src] and now - last[src] < 90 then return end
    last[src] = now
    local clean = {}
    for i = 1, math.min(3, #list) do
        local n = list[i]
        if type(n) == 'table' and NAMES[n[1]] then clean[#clean + 1] = { n[1], math.max(0.0, math.min(1.0, tonumber(n[2]) or 1.0)) } end
    end
    if #clean == 0 then return end
    local p = GetEntityCoords(GetPlayerPed(src))
    for _, id in ipairs(GetPlayers()) do
        local t = tonumber(id)
        if t ~= src and #(GetEntityCoords(GetPlayerPed(t)) - p) <= RANGE then
            TriggerClientEvent('opslabs-animations:sfx', t, src, clean)
        end
    end
end)

AddEventHandler('playerDropped', function() last[source] = nil end)
