-- Power for network kit (Config.Power). Worked out every few seconds from the mains network (server/mains.lua):
--   · Wi-Fi access points / routers / gateways / switches: a live outlet within SocketReach, or — for PoE devices —
--     CAT6 (terminated both ends) to a powered PoE switch with budget left
--   · ONTs: a live outlet within SocketReach
--   · cell towers: a live pole transformer within CellReach; otherwise their batteries carry them for CellBatteryMinutes
-- Unpowered kit drops off: Wi-Fi and cell coverage (main.lua), uplinks (cabling.lua) and ONT lights / service (isp.lua).

local CP = Config.Power or {}
if CP.NetworkNeedsPower == false then return end

local TowerPower, OntPower = {}, {}
local PoEUse = {}                  -- PoE source tower id -> watts in use
local Battery = {}                 -- cell tower id -> minutes left
local lastSig = nil

local function near(list, p, reach)
    for _, q in ipairs(list) do
        if math.abs(q.x - p.x) <= reach and math.abs(q.y - p.y) <= reach and math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 + ((q.z or p.z) - p.z) ^ 2) <= reach then return true end
    end
    return false
end

local function compute(dt)
    local outlets, txs = LiveOutlets or {}, LiveTx or {}
    local reach = CP.SocketReach or 3.0
    local tp, op, use = {}, {}, {}
    local ONT = (Config.Isp or {}).Ont or 'opslabs_ont'
    -- 1. plugged in
    for id, t in pairs(Towers or {}) do
        if t.type == 'cell' or not t.model then     -- masts (and map-only coverage points) run off the pole transformers
            local mains = near(txs, t, CP.CellReach or 350)
            Battery[id] = Battery[id] or (CP.CellBatteryMinutes or 120)
            if mains then Battery[id] = math.min(CP.CellBatteryMinutes or 120, Battery[id] + dt / 60 * 2)
            else Battery[id] = math.max(0, Battery[id] - dt / 60) end
            tp[id] = mains or Battery[id] > 0
        else
            tp[id] = near(outlets, t, reach)
        end
    end
    -- 2. PoE: access points cabled to a socket-powered PoE switch, until its budget runs out
    local links = {}
    for _, r in pairs(Cabling.runs) do
        if r.kind == 'cable' and r.start_term and r.end_term and r.start_tower and r.end_tower then
            links[#links + 1] = { r.start_tower, r.end_tower }
        end
    end
    table.sort(links, function(a, b) return (a[1] * 100000 + a[2]) < (b[1] * 100000 + b[2]) end)
    for _, l in ipairs(links) do
        for k = 1, 2 do
            local src, dev = Towers[l[k]], Towers[l[3 - k]]
            local budget = src and (CP.PoESources or {})[src.model]
            local draw = dev and (CP.PoEDevices or {})[dev.model]
            if budget and draw and tp[src.id] and not tp[dev.id] and (use[src.id] or 0) + draw <= budget then
                use[src.id] = (use[src.id] or 0) + draw
                tp[dev.id] = 'poe'
            end
        end
    end
    -- 3. ONTs
    for id, f in pairs(Cabling.fixtures) do
        if f.model == ONT then op[id] = near(outlets, f, reach) end
    end
    TowerPower, OntPower, PoEUse = tp, op, use
    -- something changed: uplinks and ONT lights follow
    local sig = json.encode({ tp, op })
    if sig ~= lastSig then
        lastSig = sig
        if RecomputeUplinks then RecomputeUplinks() end
        if RecomputeIsp then RecomputeIsp() end
    end
end

--- is this tower (cell / Wi-Fi / router) powered right now? true, 'poe', or false
function TowerPowered(id)
    local v = TowerPower[tonumber(id)]
    if v == nil then return true end       -- not worked out yet (just started): don't flicker
    return v
end
function OntPowered(id)
    local v = OntPower[tonumber(id)]
    if v == nil then return true end
    return v
end
function TowerPowerInfo(id)
    id = tonumber(id)
    local t = Towers and Towers[id]
    if not t then return nil end
    return { powered = TowerPower[id], poeUse = PoEUse[id], poeBudget = (CP.PoESources or {})[t.model], battery = Battery[id] }
end
exports('TowerPowered', TowerPowered)

CreateThread(function()
    Wait(8000)
    local last = os.clock()
    while true do
        local now = os.clock()
        compute(math.min(30, now - last))
        last = now
        Wait(3000)
    end
end)
