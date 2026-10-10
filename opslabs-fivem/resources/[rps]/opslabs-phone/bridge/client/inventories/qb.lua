-- qb-inventory, ps-inventory, lj-inventory (and tgiann-inventory, qb compatible): items live in the QBCore player data.
-- qb-core 1.3 sends OnPlayerUpdated('items', …); older versions (and the others) SetPlayerData with everything.
local def = {
    builtin = true,
    events = {
        inventory = {
            ['QBCore:Client:OnPlayerUpdated'] = function(key)
                if key == 'items' then return nil end   -- an item changed (which one isn't said)
                return false                             -- hunger, job, … : ignore
            end,
            ['QBCore:Player:SetPlayerData'] = function() return nil end,
        },
    },
}
for _, name in ipairs({ 'qb-inventory', 'ps-inventory', 'lj-inventory', 'tgiann-inventory' }) do
    Bridge.RegisterInventory(name, setmetatable({ label = name }, { __index = def }))
end
