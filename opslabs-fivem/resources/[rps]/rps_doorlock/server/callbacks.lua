exports.rps_lib:RegisterServerCallback('rps_doorlock:server:GetOpCrimeId', function(source)
    if GetResourceState('op-crime') == 'started' then
        local identifier = exports.rps_lib:GetIdentifier(source)
        if identifier then
            local success, ret1, ret2 = pcall(function()
                return exports['op-crime']:getPlayerOrganisation(identifier)
            end)
            if success then
                if type(ret2) == "table" and ret2.orgIndex then
                    return tostring(ret2.orgIndex)
                elseif type(ret1) == "table" and ret1.orgIndex then
                    return tostring(ret1.orgIndex)
                elseif type(ret2) == "table" and ret2.identifier then
                    return tostring(ret2.identifier)
                end
            end
        end
    end
    return nil
end)

exports.rps_lib:RegisterServerCallback('rps_doorlock:server:SearchCharacters', function(source, query)
    if not query or query == "" then return {} end

    -- rps_lib's character roster is fetched via a callback (it queries the
    -- framework's DB directly), so it's bridged into this synchronous
    -- callback handler with a promise, same pattern rps_lib uses internally
    -- for lib.awaitCallback.
    local p = promise.new()
    exports.rps_lib:GetAllCharacters(function(characters) p:resolve(characters) end)
    local characters = Citizen.Await(p)

    local lowerQuery = string.lower(query)
    local matches = {}
    for _, char in ipairs(characters or {}) do
        if char.name and string.find(string.lower(char.name), lowerQuery, 1, true) then
            table.insert(matches, { id = char.identifier, name = char.name })
            if #matches >= 5 then break end
        end
    end
    return matches
end)
