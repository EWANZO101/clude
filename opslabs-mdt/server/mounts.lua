-- Per-model mount offsets, calibrated in-game with /mdtmount (client/main.lua) instead of hand-editing
-- config.lua. Saved to this resource's own KVP store so it survives a restart and applies for everyone, not
-- just whoever calibrated it - Config.Mounts in config.lua is still the fallback for anything never calibrated.

local KVP = 'mounts'
Mounts = {}

local function load()
    local ok, data = pcall(json.decode, GetResourceKvpString(KVP) or '{}')
    Mounts = (ok and type(data) == 'table') and data or {}
    local n = 0 for _ in pairs(Mounts) do n = n + 1 end
    Dbg('mounts: loaded %d calibrated model(s) from KVP', n)
end
load()

lib.callback.register('opslabs-mdt:mounts', function(_) return Mounts end)

lib.callback.register('opslabs-mdt:saveMount', function(src, d)
    Dbg('server saveMount: src=%s data=%s', src, json.encode(d or {}))
    local ok, why = FW.Eligible(src)
    if not ok then Dbg('server saveMount: FW.Eligible failed (%s)', why) return { error = 'Not eligible (' .. tostring(why) .. ').' } end
    d = type(d) == 'table' and d or {}
    local model = tostring(d.model or '')
    if model == '' then return { error = 'No vehicle model given.' } end
    Mounts[model] = { x = d.x, y = d.y, z = d.z, rx = d.rx, ry = d.ry, rz = d.rz }
    SetResourceKvp(KVP, json.encode(Mounts))
    TriggerClientEvent('opslabs-mdt:mounts', -1, Mounts)
    Dbg('server saveMount: model=%s saved and broadcast', model)
    return { ok = true }
end)
