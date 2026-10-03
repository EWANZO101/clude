-- OPS Network uniform: admins' changes (clothes per gender, branding positions) live in uniform.json in this resource.
local RES = GetCurrentResourceName()
local U = json.decode(LoadResourceFile(RES, 'uniform.json') or '') or {}

local function merged()
    local base = Config.Uniform or {}
    local br = {}
    for k, b in pairs(base.Branding or {}) do
        local saved = U.Branding and U.Branding[k]
        br[k] = { model = b.model, bone = b.bone, face = b.face, at = (saved and type(saved.at) == 'table') and saved.at or b.at }   -- old-format saves are ignored
    end
    return { Name = base.Name, Male = U.Male or base.Male, Female = U.Female or base.Female, Branding = br }
end

lib.callback.register('opslabs-towers:uniform:get', function() return merged() end)

lib.callback.register('opslabs-towers:uniform:save', function(src, part, value)
    if not IsTowerAdmin(src) then return { error = 'Only admins can change the uniform' } end
    if part ~= 'Male' and part ~= 'Female' and part ~= 'Branding' then return { error = 'bad request' } end
    if type(value) ~= 'table' then return { error = 'bad request' } end
    local clean = {}
    if part == 'Branding' then
        for k, b in pairs(value) do
            local base = (Config.Uniform.Branding or {})[k]
            if base and type(b) == 'table' and type(b.at) == 'table' then
                clean[k] = { model = base.model, bone = base.bone, face = base.face,
                    at = { up = tonumber(b.at.up) or 0.0, forward = tonumber(b.at.forward) or 0.0, right = tonumber(b.at.right) or 0.0 } }
            end
        end
    else
        for k, v in pairs(value) do
            if type(k) == 'string' and k:match('^[%a_]+%d?$') and math.tointeger(tonumber(v)) then clean[k] = math.tointeger(tonumber(v)) end
        end
    end
    U[part] = clean
    SaveResourceFile(RES, 'uniform.json', json.encode(U, { indent = true }), -1)
    TriggerClientEvent('opslabs-towers:uniform', -1, merged())
    return { ok = true }
end)
