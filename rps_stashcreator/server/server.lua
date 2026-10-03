local stashes = {}
local ResourceName = GetCurrentResourceName()

-- Helper to check if player is allowed
local function IsAdmin(source)
    if not exports.rps_lib:GetPlayerData(source) then return false end

    -- ACE group / permission check (QBCore/Qbox: real ACE permission string;
    -- ESX: admin/superadmin group membership, permission name is ignored)
    if exports.rps_lib:HasPermission(source, Config.AdminPermission) then
        return true
    end

    local identifiers = GetPlayerIdentifiers(source)

    -- Fallback allowlist: identifiers defined in Config.Admins
    for _, id in ipairs(identifiers) do
        for _, adminId in ipairs(Config.Admins) do
            if id == adminId then
                return true
            end
        end
    end

    return false
end

-- Load stashes from JSON
local function LoadStashes()
    local loadFile = LoadResourceFile(ResourceName, "stashes.json")
    if loadFile then
        stashes = json.decode(loadFile) or {}
    else
        stashes = {}
    end
    
    -- Register stashes in the server's actual inventory (tgiann-inventory) —
    -- rps_lib has no stash-registration abstraction, so this talks to it directly.
    for _, stash in ipairs(stashes) do
        exports['tgiann-inventory']:RegisterStash("stash_"..stash.id, stash.name, tonumber(stash.slots), tonumber(stash.weight) * 1000)
    end
    
    -- Ensure stashes are synced to any players already online (e.g. during script restart)
    TriggerClientEvent('rps_stashecreator:client:SyncStashes', -1, stashes)
end

-- Save stashes to JSON
local function SaveStashes()
    SaveResourceFile(ResourceName, "stashes.json", json.encode(stashes, {indent = true}), -1)
    TriggerClientEvent('rps_stashecreator:client:SyncStashes', -1, stashes)
end

-- Command to open the creator
RegisterCommand('stashcreator', function(source, args)
    if IsAdmin(source) then
        -- Format jobs cleanly to prevent NUI payload limits or JSON serialization errors
        local formattedJobs = {}
        local jobs = exports.rps_lib:GetJobs()
        if jobs then
            for k, v in pairs(jobs) do
                local grades = {}
                if v.grades then
                    for gradeLevel, gradeData in pairs(v.grades) do
                        grades[tostring(gradeLevel)] = { name = gradeData.name }
                    end
                end
                formattedJobs[k] = {
                    label = v.label or k,
                    grades = grades
                }
            end
        end
        TriggerClientEvent('rps_stashecreator:client:OpenUI', source, stashes, formattedJobs)
    else
        exports.rps_lib:Notify(source, "You do not have permission to use this.", "error")
    end
end, false)

-- Initialize on script start
CreateThread(function()
    Wait(1000) -- Wait for inventory to load just in case
    LoadStashes()
end)

-- Sync on player join (hook every framework's player-loaded event — only the
-- active framework's will ever actually fire)
AddEventHandler('esx:playerLoaded', function(playerId)
    TriggerClientEvent('rps_stashecreator:client:SyncStashes', playerId, stashes)
end)

RegisterNetEvent('QBCore:Server:PlayerLoaded', function()
    TriggerClientEvent('rps_stashecreator:client:SyncStashes', source, stashes)
end)

-- Search characters callback
exports.rps_lib:RegisterServerCallback('rps_stashecreator:server:SearchCharacters', function(source, query)
    if not query or query == "" then return {} end

    local p = promise.new()
    exports.rps_lib:GetAllCharacters(function(characters)
        p:resolve(characters or {})
    end)
    local characters = Citizen.Await(p)

    local needle = string.lower(query)
    local results = {}
    for _, char in ipairs(characters) do
        if char.name and string.find(string.lower(char.name), needle, 1, true) then
            table.insert(results, { citizenid = char.identifier, name = char.name })
            if #results >= 5 then break end
        end
    end
    return results
end)

-- Create Stash
RegisterNetEvent('rps_stashecreator:server:CreateStash', function(data)
    local src = source
    if not IsAdmin(src) then return end
    
    table.insert(stashes, data)
    exports['tgiann-inventory']:RegisterStash("stash_"..data.id, data.name, tonumber(data.slots), tonumber(data.weight) * 1000)
    SaveStashes()
end)

-- Update Stash
RegisterNetEvent('rps_stashecreator:server:UpdateStash', function(data)
    local src = source
    if not IsAdmin(src) then return end

    for i, stash in ipairs(stashes) do
        if tostring(stash.id) == tostring(data.id) then
            stashes[i] = data
            exports['tgiann-inventory']:RegisterStash("stash_"..data.id, data.name, tonumber(data.slots), tonumber(data.weight) * 1000)
            SaveStashes()
            break
        end
    end
end)

-- Delete Stash
RegisterNetEvent('rps_stashecreator:server:DeleteStash', function(id)
    local src = source
    if not IsAdmin(src) then return end
    
    for i, stash in ipairs(stashes) do
        if tostring(stash.id) == tostring(id) then
            table.remove(stashes, i)
            SaveStashes()
            break
        end
    end
end)
