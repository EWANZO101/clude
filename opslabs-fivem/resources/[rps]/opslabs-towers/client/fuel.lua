-- OPS Fuel (client): vehicles burn fuel; fill up only at dispensers built in game; e-stop, tank gauge / pump controller,
-- tanker loading at the bulk terminal gantry and offloading at a fill point. Server: server/fuel.lua.

local CF = Config.Fuel or {}
if not CF.Enabled then return end
local PROD = CF.Products or {}
local GREEN, RED, ORANGE, BLUE = '#30d158', '#ff453a', '#ff9f0a', '#0a84ff'

local ELECTRIC, DIESEL = {}, {}
for _, m in ipairs(CF.Electric or {}) do ELECTRIC[joaat(m)] = true end
for _, m in ipairs(CF.DieselModels or {}) do DIESEL[joaat(m)] = true end
local TANKER = {}
for m, cap in pairs(CF.Tankers or {}) do TANKER[joaat(m)] = { name = m, cap = cap } end

--- what goes in this vehicle: 'petrol' | 'diesel' | 'electric' | nil (doesn't use road fuel)
local function fuelType(veh)
    local model, class = GetEntityModel(veh), GetVehicleClass(veh)
    if (CF.NoFuelClasses or {})[class] then return nil end
    if ELECTRIC[model] then return 'electric' end
    if DIESEL[model] or (CF.DieselClasses or {})[class] then return 'diesel' end
    return 'petrol'
end
local function suits(ftype, p)
    if ftype == 'diesel' then return p == 'dsl' end
    if ftype == 'petrol' then return p == 'ul' or p == 'sup' end
    return false
end

local function getFuel(veh)
    local v = Entity(veh).state.fuel
    if v == nil then
        v = math.random((CF.StartLevel or { 35, 85 })[1], (CF.StartLevel or { 35, 85 })[2]) + 0.0
        if NetworkGetEntityIsNetworked(veh) then Entity(veh).state:set('fuel', v, true) end
        SetVehicleFuelLevel(veh, v)
    end
    return v
end
local function setFuel(veh, v)
    v = math.max(0.0, math.min(100.0, v + 0.0))
    SetVehicleFuelLevel(veh, v)
    Entity(veh).state:set('fuel', v, true)
end
exports('GetFuel', function(veh) return getFuel(veh) end)
exports('SetFuel', function(veh, v) setFuel(veh, v) end)

---------------------------------------------------------------------------
-- consumption (the driver's client does the burning)
---------------------------------------------------------------------------
CreateThread(function()
    local lastSync, synced = 0, {}
    while true do
        Wait(1000)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and fuelType(veh) then
            local fuel = getFuel(veh)
            if GetIsVehicleEngineRunning(veh) then
                local rpm = GetVehicleCurrentRpm(veh)
                local burn = (CF.Idle or 0.06) / 60 + (CF.Burn or 1.1) / 60 * math.max(0, rpm - 0.2) ^ 1.5 * 1.6
                fuel = math.max(0.0, fuel - burn)
                SetVehicleFuelLevel(veh, fuel)
                if math.abs((synced[veh] or 0) - fuel) > 0.4 or GetGameTimer() - lastSync > 15000 then
                    Entity(veh).state:set('fuel', fuel, true)
                    synced[veh], lastSync = fuel, GetGameTimer()
                end
                -- the wrong fuel in the tank: rough running, engine damage, stalls
                if Entity(veh).state.misfuel then
                    SetVehicleEngineHealth(veh, math.max(-100.0, GetVehicleEngineHealth(veh) - 6.0))
                    if math.random() < 0.08 then SetVehicleEngineOn(veh, false, true, false) end
                    if fuel < 5.0 then Entity(veh).state:set('misfuel', nil, true) end
                end
            end
            if fuel <= 0.0 then
                SetVehicleEngineOn(veh, false, true, true)
                if GetGameTimer() % 20000 < 1000 then lib.notify({ type = 'error', description = 'Out of fuel', icon = 'gas-pump' }) end
            end
        end
    end
end)
-- keep empty vehicles from starting
CreateThread(function()
    while true do
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= 0 and fuelType(veh) and (Entity(veh).state.fuel or 1) <= 0.0 then
            SetVehicleEngineOn(veh, false, true, true)
            Wait(0)
        else Wait(500) end
    end
end)

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function fixtures() return CablingFixtures and CablingFixtures() or {} end
local function nearestVehicle(c, maxd, filter)
    local best, bd
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(v) - c)
        if d < (bd or maxd) and (not filter or filter(v)) then best, bd = v, d end
    end
    return best
end
local function plateOf(v) return (GetVehicleNumberPlateText(v) or ''):gsub('^%s+', ''):gsub('%s+$', '') end
local function money(n) return ('$%.2f'):format(n or 0) end
local function err(r) lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end

---------------------------------------------------------------------------
-- dispensing
---------------------------------------------------------------------------
local pumping = nil
RegisterNetEvent('opslabs-towers:fuel:stop', function(msg) if pumping then pumping.stop = msg end end)

local function pump(f, veh, g, want)
    local ftype = fuelType(veh)
    local cap = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fPetrolTankVolume')
    if not cap or cap < 5 then cap = 65.0 end
    local level = getFuel(veh)
    local room = (100.0 - level) / 100.0 * cap
    want = math.min(want or room, room)
    if want < 0.5 then return lib.notify({ type = 'inform', description = 'The tank is already full' }) end
    local r = lib.callback.await('opslabs-towers:fuel:start', false, f.id, g.product, want)
    if not r or r.error then return err(r) end
    local ped = PlayerPedId()
    local vpos = GetEntityCoords(veh)
    local dpos = vector3(f.x, f.y, f.z)
    pumping = { stop = nil }
    lib.requestAnimDict('timetable@gardener@filling_can')
    TaskTurnPedToFaceEntity(ped, veh, 800)
    Wait(800)
    TaskPlayAnim(ped, 'timetable@gardener@filling_can', 'gar_ig_5_filling_can', 2.0, 2.0, -1, 49, 0, false, false, false)
    local done, broke = 0.0, false
    local rate = (CF.FlowLpm or 40) * 4 / 60
    local last = GetGameTimer()
    while done < r.litres do
        Wait(0)
        local t = GetGameTimer()
        done = math.min(r.litres, done + rate * (t - last) / 1000)
        last = t
        lib.showTextUI(('%s  ·  %.2f L  ·  %s   [X] stop'):format(r.label, done, money(done * r.price)), { position = 'right-center', icon = 'gas-pump' })
        if IsControlJustPressed(0, 73) then break end
        if pumping.stop then lib.notify({ type = 'error', description = pumping.stop }) break end
        if not DoesEntityExist(veh) then break end
        if #(GetEntityCoords(veh) - vpos) > 2.5 then broke = true break end
        if #(GetEntityCoords(ped) - dpos) > (CF.CarDistance or 5.0) + 3.0 then break end
        if GetIsVehicleEngineRunning(veh) and t % 3000 < 20 then lib.notify({ type = 'inform', description = 'Switch the engine off while refuelling' }) end
    end
    lib.hideTextUI()
    StopAnimTask(ped, 'timetable@gardener@filling_can', 'gar_ig_5_filling_can', 1.0)
    pumping = nil
    local fin = lib.callback.await('opslabs-towers:fuel:finish', false, done, broke)
    if DoesEntityExist(veh) and done > 0 then
        setFuel(veh, level + done / cap * 100.0)
        if not suits(ftype, g.product) then
            Entity(veh).state:set('misfuel', true, true)
            lib.notify({ type = 'error', description = ('That’s %s in a %s vehicle — the engine won’t like it. Run it dry or get it drained.'):format(g.label, ftype), duration = 9000 })
        end
    end
    if broke then lib.notify({ type = 'error', description = 'You drove off with the nozzle in — the breakaway coupling parted. Fuel stopped.', duration = 9000 }) end
    if fin and fin.ok then
        lib.notify({ type = fin.paid and 'success' or 'error', icon = 'gas-pump',
            description = fin.paid and ('%.2f L of %s · %s paid'):format(fin.litres, g.label, money(fin.cost)) or ('%.2f L — couldn’t pay %s'):format(fin.litres, money(fin.cost)) })
    end
end

local function dispenserMenu(f)
    local d = lib.callback.await('opslabs-towers:fuel:dispenser', false, f.id)
    if not d or d.error then return err(d) end
    local veh = nearestVehicle(vector3(f.x, f.y, f.z), CF.CarDistance or 5.0)
    local ftype = veh and fuelType(veh)
    local options = {}
    if d.fault then options[#options + 1] = { title = d.fault, icon = 'triangle-exclamation', iconColor = RED, readOnly = true } end
    if d.breakaway then
        options[#options + 1] = { title = 'Reset the breakaway coupling', description = 'Reconnect the hose and reset the valve', icon = 'link', iconColor = ORANGE, onSelect = function()
            if lib.progressCircle({ duration = 6000, label = 'Refitting the breakaway coupling', canCancel = true, disable = { move = true } }) then
                local r = lib.callback.await('opslabs-towers:fuel:breakawayReset', false, f.id)
                if r and r.ok then lib.notify({ type = 'success', description = 'Coupling reset' }) else err(r) end
            end
        end }
    end
    if not veh then options[#options + 1] = { title = 'Park a vehicle beside the pump', description = 'Within 5 m — the hose doesn’t reach any further', icon = 'car', readOnly = true }
    elseif ftype == 'electric' then options[#options + 1] = { title = 'This is an electric vehicle', description = 'Charge it at an EV charger', icon = 'car-battery', iconColor = BLUE, readOnly = true }
    elseif not ftype then options[#options + 1] = { title = 'That vehicle doesn’t take road fuel', icon = 'ban', readOnly = true }
    else
        local cap = GetVehicleHandlingFloat(veh, 'CHandlingData', 'fPetrolTankVolume')
        if not cap or cap < 5 then cap = 65.0 end
        local level = getFuel(veh)
        options[#options + 1] = { title = ('Tank %d %%'):format(math.floor(level)), progress = level, colorScheme = level < 20 and 'red' or 'green',
            description = ('%s · %.0f L tank · takes %s'):format(GetDisplayNameFromVehicleModel(GetEntityModel(veh)), cap, ftype == 'diesel' and 'diesel' or 'unleaded / super'), icon = 'gauge', readOnly = true }
        if #d.grades == 0 then options[#options + 1] = { title = 'No fuel piped to this dispenser', description = 'Lay product pipe from a tank to it', icon = 'faucet', readOnly = true } end
        for _, g in ipairs(d.grades) do
            local ok = suits(ftype, g.product)
            options[#options + 1] = { title = ('%s · %s / L'):format(g.label, money(g.price):sub(1, -1)), icon = 'gas-pump', iconColor = PROD[g.product] and PROD[g.product].color or GREEN,
                description = (g.litres < 1 and 'Sold out' or (ok and 'Right fuel for this vehicle' or 'WRONG FUEL for this vehicle')) .. (' · %s in stock'):format(g.litres >= 1000 and (math.floor(g.litres / 1000) .. 'k L') or (g.litres .. ' L')),
                disabled = d.fault ~= nil or g.litres < 1, arrow = true, onSelect = function()
                    local room = (100.0 - getFuel(veh)) / 100.0 * cap
                    lib.registerContext({ id = 'fuel_amount', title = g.label, menu = 'fuel_disp', options = {
                        { title = ('Fill it up · ~%.0f L · ~%s'):format(room, money(room * g.price)), icon = 'fill-drip', onSelect = function() pump(f, veh, g, nil) end },
                        { title = '10 litres', description = money(10 * g.price), icon = 'droplet', onSelect = function() pump(f, veh, g, 10) end },
                        { title = '25 litres', description = money(25 * g.price), icon = 'droplet', onSelect = function() pump(f, veh, g, 25) end },
                        { title = 'Spend an amount…', icon = 'dollar-sign', onSelect = function()
                            local v = lib.inputDialog('Pre-pay', { { type = 'number', label = 'Dollars', min = 1, max = 2000, required = true } })
                            if v and v[1] then pump(f, veh, g, v[1] / g.price) end
                        end },
                    } })
                    lib.showContext('fuel_amount')
                end }
        end
    end
    lib.registerContext({ id = 'fuel_disp', title = (d.station or 'OPS Fuel') .. ' · pump ' .. f.id, options = options })
    lib.showContext('fuel_disp')
end

---------------------------------------------------------------------------
-- tank gauge / pump controller
---------------------------------------------------------------------------
local function atgMenu(f)
    local r = lib.callback.await('opslabs-towers:fuel:atg', false, f.id)
    if not r or r.error then return err(r) end
    local options = {}
    local function act(action, a, msg)
        local res = lib.callback.await('opslabs-towers:fuel:atgAct', false, f.id, action, a)
        if res and res.ok then if msg then lib.notify({ type = 'success', description = msg }) end atgMenu(f) else err(res) end
    end
    if r.estop then
        options[#options + 1] = { title = 'EMERGENCY STOP ACTIVE', description = r.manage and 'Make the forecourt safe, then reset' or 'Staff must reset it', icon = 'circle-stop', iconColor = RED,
            disabled = not r.manage, onSelect = function() act('reset_estop', nil, 'E-stop reset · pumps available') end }
    end
    for _, a in ipairs(r.alarms or {}) do
        if not a.info then options[#options + 1] = { title = a.text, description = os.date and '' or '', icon = 'bell', iconColor = ORANGE, readOnly = true } end
    end
    if #(r.tanks or {}) == 0 then options[#options + 1] = { title = 'No tanks on this station', description = ('Fit underground tanks within %d m'):format(CF.StationRadius or 70), icon = 'oil-well', readOnly = true } end
    for _, t in ipairs(r.tanks or {}) do
        local warn = {}
        if t.leak then warn[#warn + 1] = 'LEAK' end
        if t.water > 0 then warn[#warn + 1] = ('water %d mm'):format(t.water) end
        if not t.vented then warn[#warn + 1] = 'no vent' end
        if not t.filled then warn[#warn + 1] = 'no fill pipe' end
        if t.dispensers == 0 then warn[#warn + 1] = 'feeds no pump' end
        options[#options + 1] = { title = ('T%d %s · %s L (%s %%)'):format(t.id, t.label, t.litres, t.pct), progress = t.pct, colorScheme = t.pct < 10 and 'red' or t.pct < 25 and 'yellow' or 'green',
            description = ('%.1f °C · variance %+d L%s'):format(t.temp, t.variance, #warn > 0 and (' · ' .. table.concat(warn, ' · ')) or ''),
            icon = 'oil-well', iconColor = (t.leak or t.water > 0) and RED or (PROD[t.product] or {}).color, readOnly = true }
    end
    local dl = {}
    for _, d in ipairs(r.dispensers or {}) do dl[#dl + 1] = ('#%d %s'):format(d.id, d.fault and '✗' or '✓') end
    options[#options + 1] = { title = ('Dispensers: %d'):format(#(r.dispensers or {})), description = #dl > 0 and table.concat(dl, '  ') or 'None in range', icon = 'gas-pump', readOnly = true }
    options[#options + 1] = { title = ('Sales: %s · %.1f L'):format(money(r.salesTotal), r.litresSold), icon = 'receipt', arrow = true, onSelect = function()
        local o = {}
        for _, s in ipairs(r.sales or {}) do
            o[#o + 1] = { title = ('%s · %.2f L %s · %s'):format(os.date and '' or '', s.litres, (PROD[s.product] or {}).short or s.product, money(s.total)), description = ('Pump %d · %s%s'):format(s.disp, s.who, s.paid and '' or ' · UNPAID'), readOnly = true }
        end
        for _, dv in ipairs(r.deliveries or {}) do
            o[#o + 1] = { title = ('Delivery · %d L %s'):format(dv.litres, (PROD[dv.product] or {}).label or dv.product), description = ('Tanker %s · %s'):format(dv.plate, dv.who), icon = 'truck', readOnly = true }
        end
        if #o == 0 then o[1] = { title = 'No transactions yet', readOnly = true } end
        lib.registerContext({ id = 'fuel_sales', title = 'Transactions', menu = 'fuel_atg', options = o })
        lib.showContext('fuel_sales')
    end }
    if r.manage then
        options[#options + 1] = { title = 'Set prices', description = ('UL %s · SUP %s · DSL %s per litre'):format(money(r.prices.ul), money(r.prices.sup), money(r.prices.dsl)), icon = 'tag', onSelect = function()
            local v = lib.inputDialog('Prices per litre', {
                { type = 'number', label = 'Unleaded 95', default = r.prices.ul, min = 0.1, max = 20, precision = 3, step = 0.01 },
                { type = 'number', label = 'Super 98', default = r.prices.sup, min = 0.1, max = 20, precision = 3, step = 0.01 },
                { type = 'number', label = 'Diesel', default = r.prices.dsl, min = 0.1, max = 20, precision = 3, step = 0.01 } })
            if v then
                for i, p in ipairs({ 'ul', 'sup', 'dsl' }) do if v[i] then lib.callback.await('opslabs-towers:fuel:atgAct', false, f.id, 'price', { product = p, price = v[i] }) end end
                lib.notify({ type = 'success', description = 'Prices updated on every pump' })
                atgMenu(f)
            end
        end }
        options[#options + 1] = { title = 'Rename station', description = r.name, icon = 'pen', onSelect = function()
            local v = lib.inputDialog('Station name', { { type = 'input', label = 'Name', default = r.name, max = 40 } })
            if v then act('name', { name = v[1] }, 'Renamed') end
        end }
        options[#options + 1] = { title = 'Reconcile stock (dip = book)', description = 'Accept the gauge readings as the new book stock', icon = 'scale-balanced', onSelect = function() act('reconcile', nil, 'Stock reconciled') end }
        options[#options + 1] = { title = 'Clear alarm list', icon = 'bell-slash', onSelect = function() act('clear_alarms', nil, 'Alarms cleared') end }
    end
    lib.registerContext({ id = 'fuel_atg', title = r.name .. ' · tank gauge', options = options })
    lib.showContext('fuel_atg')
end

---------------------------------------------------------------------------
-- tankers
---------------------------------------------------------------------------
local function findTanker(c, maxd)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then
        local has, trailer = GetVehicleTrailerVehicle(veh)
        if has and trailer ~= 0 and TANKER[GetEntityModel(trailer)] then return trailer end
        if TANKER[GetEntityModel(veh)] then return veh end
    end
    return nearestVehicle(c, maxd, function(v) return TANKER[GetEntityModel(v)] ~= nil end)
end

local function gantryMenu(f)
    local tk = findTanker(vector3(f.x, f.y, f.z), 18.0)
    if not tk then return lib.notify({ type = 'error', description = 'Park a fuel tanker trailer under the gantry' }) end
    local def = TANKER[GetEntityModel(tk)]
    local plate = plateOf(tk)
    local cur = lib.callback.await('opslabs-towers:fuel:tanker', false, plate) or { comps = {} }
    local n = CF.Compartments or 3
    local per = math.floor(def.cap / n)
    local opts = { { value = 'none', label = 'Leave empty' } }
    for _, p in ipairs({ 'ul', 'sup', 'dsl' }) do opts[#opts + 1] = { value = p, label = ('%s (bulk $%.2f/L)'):format(PROD[p].label, PROD[p].wholesale or 1) } end
    local rows = {}
    for i = 1, n do
        local c = cur.comps and (cur.comps[i] or cur.comps[tostring(i)])
        rows[#rows + 1] = { type = 'select', label = ('Compartment %d%s'):format(i, c and (' · has %d L %s'):format(c.litres, PROD[c.product].label) or ''), options = opts, default = c and c.product or 'none' }
    end
    rows[#rows + 1] = { type = 'slider', label = 'Fill each to (%)', min = 10, max = 100, step = 5, default = 100 }
    local v = lib.inputDialog(('Load tanker %s · %d × %d L'):format(plate, n, per), rows)
    if not v then return end
    local comps = {}
    for i = 1, n do
        if v[i] ~= 'none' then
            local c = cur.comps and (cur.comps[i] or cur.comps[tostring(i)])
            comps[i] = { product = v[i], litres = math.max(0, per * v[n + 1] / 100 - (c and c.litres or 0)) }
        end
    end
    if not lib.progressCircle({ duration = 12000, label = 'Loading through the bottom-loading arms…', canCancel = true, disable = { move = true, car = true } }) then return end
    local r = lib.callback.await('opslabs-towers:fuel:load', false, f.id, plate, def.name, comps)
    if not r or r.error then return err(r) end
    lib.notify({ type = 'success', description = ('Tanker loaded · bulk fuel %s'):format(money(r.cost)), icon = 'truck' })
end

local function fillMenu(f)
    local tk = findTanker(vector3(f.x, f.y, f.z), 25.0)
    if not tk then return lib.notify({ type = 'error', description = 'No fuel tanker within 25 m of the fill point' }) end
    local plate = plateOf(tk)
    local cur = lib.callback.await('opslabs-towers:fuel:tanker', false, plate) or { comps = {} }
    local options = {
        { title = 'Earth the tanker (static bonding)', description = 'Clamp the earth lead to the boss — always first', icon = 'bolt', iconColor = '#ffd60a', onSelect = function()
            if lib.progressCircle({ duration = 4000, label = 'Clamping the earth lead', canCancel = true, disable = { move = true } }) then
                lib.callback.await('opslabs-towers:fuel:earth', false, f.id, plate)
                lib.notify({ type = 'success', description = 'Tanker earthed' })
            end
            fillMenu(f)
        end },
    }
    local any = false
    for i = 1, CF.Compartments or 3 do
        local c = cur.comps and (cur.comps[i] or cur.comps[tostring(i)])
        if c and c.litres > 0 then
            any = true
            options[#options + 1] = { title = ('Offload compartment %d · %d L %s'):format(i, c.litres, PROD[c.product].label), icon = 'truck-droplet', iconColor = PROD[c.product].color,
                description = 'Hose to the ' .. PROD[c.product].label .. ' fill (colour-coded) · vapour return on', onSelect = function()
                    if not lib.progressCircle({ duration = math.min(30000, 6000 + c.litres), label = 'Offloading ' .. PROD[c.product].label .. '…', canCancel = true, disable = { move = true, car = true } }) then return end
                    local r = lib.callback.await('opslabs-towers:fuel:deliver', false, f.id, plate, i)
                    if not r or r.error then return err(r) end
                    lib.notify({ type = 'success', description = ('%d L delivered%s'):format(r.litres, r.left > 0 and (' · %d L left on board (tank full)'):format(r.left) or ''), duration = 8000 })
                    for _, n in ipairs(r.notes or {}) do lib.notify({ type = 'inform', description = n, duration = 8000 }) end
                end }
        end
    end
    if not any then options[#options + 1] = { title = ('Tanker %s is empty'):format(plate), description = 'Load it at a bulk terminal gantry', icon = 'truck', readOnly = true } end
    lib.registerContext({ id = 'fuel_fill', title = 'Fill point · tanker ' .. plate, options = options })
    lib.showContext('fuel_fill')
end

local function tankMenu(f)
    lib.registerContext({ id = 'fuel_tank', title = 'Tank chamber #' .. f.id, options = {
        { title = 'Pump out water', description = 'Water-finding paste, then pump the water bottom out', icon = 'droplet-slash', onSelect = function()
            if lib.progressCircle({ duration = 15000, label = 'Pumping water out of the tank', canCancel = true, disable = { move = true } }) then
                lib.callback.await('opslabs-towers:fuel:tankWork', false, f.id, 'water'); lib.notify({ type = 'success', description = 'Water removed' })
            end
        end },
        { title = 'Repair leak', description = 'Pressure-test the lines and reseal', icon = 'wrench', onSelect = function()
            if lib.progressCircle({ duration = 25000, label = 'Testing and sealing the tank & lines', canCancel = true, disable = { move = true } }) then
                lib.callback.await('opslabs-towers:fuel:tankWork', false, f.id, 'leak'); lib.notify({ type = 'success', description = 'Leak repaired · tank back in service' })
            end
        end },
    } })
    lib.showContext('fuel_tank')
end

---------------------------------------------------------------------------
-- [E] at fuel kit
---------------------------------------------------------------------------
local KIT = {
    [CF.Dispenser] = { '[E] Fuel pump', dispenserMenu, 2.2 },
    [CF.Controller] = { '[E] Tank gauge & pump controller', atgMenu, 1.4 },
    [CF.FillPoint] = { '[E] Tanker fill point', fillMenu, 2.0 },
    [CF.Gantry] = { '[E] Load tanker', gantryMenu, 9.0 },
    [CF.EStop] = { '[E] EMERGENCY STOP', function(f)
        local r = lib.callback.await('opslabs-towers:fuel:estop', false, f.id)
        if r and r.ok then lib.notify({ type = 'error', description = 'EMERGENCY STOP — every pump at ' .. r.station .. ' is off', duration = 8000 }) else err(r) end
    end, 1.4 },
}
for m in pairs(CF.Tanks or {}) do KIT[m] = { '[E] Tank chamber · water / leak work', tankMenu, 1.4 } end

CreateThread(function()
    local shown = nil
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local best, bd
        if GetVehiclePedIsIn(PlayerPedId(), false) == 0 or true then
            for _, f in pairs(fixtures()) do
                local k = KIT[f.model]
                if k and math.abs(f.x - pos.x) < 12 and math.abs(f.y - pos.y) < 12 then
                    local d = #(pos - vector3(f.x, f.y, f.z + (f.model == CF.Gantry and 0 or 0.8)))
                    if d < k[3] and (not bd or d < bd) then best, bd = f, d end
                end
            end
        end
        if best and not pumping then
            local k = KIT[best.model]
            if shown ~= best.id then lib.showTextUI(k[1], { icon = 'gas-pump' }) shown = best.id end
            for _ = 1, 25 do
                Wait(0)
                if IsControlJustPressed(0, 38) then lib.hideTextUI() shown = nil k[2](best) break end
            end
        else
            if shown then lib.hideTextUI() shown = nil end
            Wait(500)
        end
    end
end)
