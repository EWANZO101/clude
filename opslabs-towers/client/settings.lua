-- Live settings on the client: overrides published by server/settings.lua (GlobalState 'opscfg:<resource>').
local RES = GetCurrentResourceName()
local DEFAULTS = {}
local function copy(v) if type(v) ~= 'table' then return v end local o = {} for k, x in pairs(v) do o[k] = copy(x) end return o end
local function parts(p) local t = {} for s in p:gmatch('[^%.]+') do t[#t + 1] = tonumber(s) or s end return t end
local function at(root, ps) local t = root for i = 1, #ps do if type(t) ~= 'table' then return nil end t = t[ps[i]] end return t end
local function set(root, ps, v) local t = root for i = 1, #ps - 1 do if type(t[ps[i]]) ~= 'table' then return end t = t[ps[i]] end t[ps[#ps]] = v end
local current = {}
local function apply(overrides)
    overrides = overrides or {}
    for p in pairs(current) do if overrides[p] == nil then set(Config, parts(p), copy(at(DEFAULTS, parts(p)))) end end
    for p, v in pairs(overrides) do set(Config, parts(p), v) end
    current = overrides
    TriggerEvent('opslabs:configChanged', RES)
end
CreateThread(function()
    DEFAULTS = copy(Config)
    apply(GlobalState['opscfg:' .. RES])
end)
AddStateBagChangeHandler('opscfg:' .. RES, 'global', function(_, _, value) apply(value) end)
