-- Parking logistics admin panel (ox_lib context menus)

local LotsByName = {}
local function RebuildLots()
    LotsByName = {}
    for _, lot in ipairs(Config.ParkingLots) do LotsByName[lot.name] = lot end
end
RebuildLots()
AddEventHandler('rps_parking:lotsChanged', RebuildLots)

local ActionLabels = {
    park = 'Parked', unpark = 'Unparked', ticket = 'Ticket', impound = 'Impounded',
    retrieve = 'Impound release', expire = 'Auto-impound',
    admin_release = 'Staff release', admin_impound = 'Staff impound',
    admin_waive = 'Fines waived', admin_delete = 'Record deleted', admin_lot = 'Lot edited',
}
local ActionIcons = {
    park = 'square-parking', unpark = 'key', ticket = 'file-invoice-dollar', impound = 'truck-pickup',
    retrieve = 'warehouse', expire = 'hourglass-end', admin_release = 'unlock', admin_impound = 'gavel',
    admin_waive = 'hand-holding-dollar', admin_delete = 'trash', admin_lot = 'draw-polygon',
}

local function notify(msg, t) Bridge.Notify(msg, t, 'Parking Admin') end
local function money(n) return ('$%s'):format(tostring(math.floor(n or 0)):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')) end

local function duration(minutes)
    minutes = minutes or 0
    if minutes < 60 then return ('%dm'):format(minutes) end
    if minutes < 1440 then return ('%dh %dm'):format(minutes // 60, minutes % 60) end
    return ('%dd %dh'):format(minutes // 1440, (minutes % 1440) // 60)
end

local function modelLabel(model)
    if not model then return 'Vehicle' end
    local name = GetDisplayNameFromVehicleModel(model)
    local label = GetLabelText(name)
    return label ~= 'NULL' and label or name
end

local function lotText(lotName, spot)
    local lot = lotName and LotsByName[lotName]
    if not lot then return 'No location' end
    return spot and ('%s #%d'):format(lot.label, spot) or lot.label
end

local OpenAdmin, OpenVehicle

---------------------------------------------------------------------------
-- Logs
---------------------------------------------------------------------------
local function LogOptions(logs, back)
    local options = {}
    for _, l in ipairs(logs) do
        local total = (l.amount or 0) + (l.fines or 0)
        local parts = { l.time, l.actor_name or 'System', lotText(l.lot, l.spot) }
        if total > 0 then parts[#parts + 1] = money(total) end
        if l.details and l.details ~= '' then parts[#parts + 1] = l.details end
        options[#options + 1] = {
            title = ('%s • %s'):format(ActionLabels[l.action] or l.action, l.plate or '-'),
            description = table.concat(parts, ' • '),
            icon = ActionIcons[l.action] or 'circle-info',
            onSelect = l.plate and function() OpenVehicle(l.plate, back or 'rps_parking_admin') end or nil,
        }
    end
    if #options == 0 then options[1] = { title = 'No log entries', readOnly = true, icon = 'circle-info' } end
    return options
end

local function OpenLogs(filter)
    local logs = lib.callback.await('rps_parking:admin:logs', false, filter or 'all')
    if not logs then return notify('Not authorized.', 'error') end

    local options = {
        {
            title = ('Filter: %s'):format(filter and filter ~= 'all' and (ActionLabels[filter] or filter) or 'All actions'),
            icon = 'filter',
            onSelect = function()
                local choices = { { value = 'all', label = 'All actions' } }
                for k, v in pairs(ActionLabels) do choices[#choices + 1] = { value = k, label = v } end
                local input = lib.inputDialog('Filter logs', {
                    { type = 'select', label = 'Action', options = choices, default = filter or 'all', required = true },
                })
                if input then OpenLogs(input[1]) end
            end,
        },
    }
    for _, o in ipairs(LogOptions(logs, 'rps_parking_admin_logs')) do options[#options + 1] = o end

    lib.registerContext({ id = 'rps_parking_admin_logs', title = 'Recent Activity', menu = 'rps_parking_admin', options = options })
    lib.showContext('rps_parking_admin_logs')
end

---------------------------------------------------------------------------
-- Vehicle details & actions
---------------------------------------------------------------------------
local function DoAction(plate, action, arg, back)
    local ok, msg, coords = lib.callback.await('rps_parking:admin:action', false, plate, action, arg)
    notify(msg, ok and 'success' or 'error')
    if ok and coords then
        SetEntityCoords(PlayerPedId(), coords.x + 2.0, coords.y, coords.z + 0.5, false, false, false, false)
        return
    end
    if ok then OpenVehicle(plate, back) end
end

local function Confirm(header, content)
    return lib.alertDialog({ header = header, content = content, centered = true, cancel = true }) == 'confirm'
end

OpenVehicle = function(plate, back)
    local res = lib.callback.await('rps_parking:admin:vehicle', false, plate)
    if not res then return notify('Not authorized.', 'error') end
    local info = res.info
    local options = {}

    if not info then
        options[1] = { title = ('%s has no active record'):format(plate), icon = 'circle-info', readOnly = true }
    else
        local statusText = info.status == 'parked' and ('Parked for %s'):format(duration(info.minutes))
            or info.status == 'impounded' and ('Impounded: %s'):format(info.reason or 'Unknown')
            or 'Unknown status'
        options[#options + 1] = {
            title = ('%s [%s]'):format(modelLabel(info.model), info.plate),
            description = ('Owner: %s\n%s\n%s'):format(info.owner or '?', info.location, statusText),
            icon = info.status == 'impounded' and 'truck-pickup' or 'car', readOnly = true,
        }
        options[#options + 1] = {
            title = ('Amount due: %s'):format(money(info.due)),
            description = ('Includes %s in fines'):format(money(info.fines)),
            icon = 'sack-dollar', readOnly = true,
        }

        if info.status == 'parked' then
            options[#options + 1] = { title = 'Teleport to vehicle', icon = 'location-arrow',
                onSelect = function() DoAction(plate, 'teleport', nil, back) end }
            options[#options + 1] = { title = 'Force unpark (waive fees)', icon = 'unlock',
                description = 'Unlocks the vehicle in place for its owner',
                onSelect = function()
                    if Confirm('Force unpark', ('Release **%s** and waive %s?'):format(plate, money(info.due))) then
                        DoAction(plate, 'release', nil, back)
                    end
                end }
            options[#options + 1] = { title = 'Send to impound', icon = 'gavel',
                onSelect = function()
                    local input = lib.inputDialog('Impound ' .. plate, {
                        { type = 'input', label = 'Reason', placeholder = 'Impounded by staff', max = 200 },
                    })
                    if input then DoAction(plate, 'impound', input[1], back) end
                end }
        end

        if (info.fines or 0) > 0 then
            options[#options + 1] = { title = ('Waive fines (%s)'):format(money(info.fines)), icon = 'hand-holding-dollar',
                onSelect = function() DoAction(plate, 'clearfines', nil, back) end }
        end

        if info.status == 'impounded' then
            options[#options + 1] = { title = 'Delete impound record', icon = 'trash',
                description = 'Removes it from the parking system (back to the owner\'s garage)',
                onSelect = function()
                    if Confirm('Delete record', ('Delete the impound record for **%s**?'):format(plate)) then
                        DoAction(plate, 'delete', nil, 'rps_parking_admin')
                    end
                end }
        end
    end

    options[#options + 1] = { title = ('History (%d entries)'):format(#res.logs), icon = 'clock-rotate-left',
        menu = 'rps_parking_admin_history' }

    lib.registerContext({ id = 'rps_parking_admin_history', title = ('History • %s'):format(plate),
        menu = 'rps_parking_admin_vehicle', options = LogOptions(res.logs) })
    lib.registerContext({ id = 'rps_parking_admin_vehicle', title = ('Vehicle • %s'):format(plate),
        menu = back or 'rps_parking_admin', options = options })
    lib.showContext('rps_parking_admin_vehicle')
end

---------------------------------------------------------------------------
-- Lots
---------------------------------------------------------------------------
local function OpenLot(lotName)
    local res = lib.callback.await('rps_parking:admin:lot', false, lotName)
    if not res then return notify('Not authorized.', 'error') end

    local options, id = {}, 'rps_parking_admin_lot'
    for _, b in ipairs(res.bays) do
        if b.plate then
            options[#options + 1] = {
                title = ('Bay %d • %s'):format(b.spot, b.plate),
                description = ('%s • %s • %s parked • due %s%s'):format(modelLabel(b.model), b.owner or '?',
                    duration(b.minutes), money(b.due), b.fines > 0 and (' (fines %s)'):format(money(b.fines)) or ''),
                icon = 'car', iconColor = '#e05252', arrow = true,
                onSelect = function() OpenVehicle(b.plate, id) end,
            }
        else
            options[#options + 1] = {
                title = ('Bay %d • Free'):format(b.spot), icon = 'square', iconColor = '#3cc85a', readOnly = true,
            }
        end
    end

    lib.registerContext({ id = id, title = res.label, menu = 'rps_parking_admin', options = options })
    lib.showContext(id)
end

local function OpenImpoundList()
    local list = lib.callback.await('rps_parking:admin:impounded', false)
    if not list then return notify('Not authorized.', 'error') end

    local options = {}
    for _, v in ipairs(list) do
        options[#options + 1] = {
            title = ('%s [%s]'):format(modelLabel(v.model), v.plate),
            description = ('%s • %s%s'):format(v.owner or '?', v.reason or 'Unknown',
                (v.fines or 0) > 0 and (' • fines %s'):format(money(v.fines)) or ''),
            icon = 'truck-pickup', arrow = true,
            onSelect = function() OpenVehicle(v.plate, 'rps_parking_admin_impound') end,
        }
    end
    if #options == 0 then options[1] = { title = 'The impound lot is empty', icon = 'circle-check', readOnly = true } end

    lib.registerContext({ id = 'rps_parking_admin_impound', title = 'Impound Lot', menu = 'rps_parking_admin', options = options })
    lib.showContext('rps_parking_admin_impound')
end

---------------------------------------------------------------------------
-- Dashboard
---------------------------------------------------------------------------
OpenAdmin = function()
    local o = lib.callback.await('rps_parking:admin:overview', false)
    if not o then return notify('You are not allowed to use this.', 'error') end

    local totalBays, takenBays = 0, 0
    for _, l in ipairs(o.lots) do totalBays = totalBays + l.total; takenBays = takenBays + l.taken end
    local t = o.today

    local options = {
        {
            title = ('Revenue today: %s'):format(money(o.revenue.today)),
            description = ('Last 7 days: %s • %s: %s'):format(money(o.revenue.week),
                o.retention > 0 and ('Last %d days'):format(o.retention) or 'All time', money(o.revenue.total)),
            icon = 'sack-dollar', readOnly = true,
        },
        {
            title = ('Occupancy: %d / %d bays'):format(takenBays, totalBays),
            description = ('%d parked • %d impounded • %s outstanding fees'):format(o.parked, o.impounded, money(o.outstanding)),
            icon = 'chart-simple', readOnly = true,
            progress = totalBays > 0 and math.floor(takenBays / totalBays * 100) or 0,
        },
        {
            title = 'Today',
            description = ('%d parked • %d unparked • %d tickets • %d impounds • %d releases'):format(
                t.park or 0, t.unpark or 0, t.ticket or 0, (t.impound or 0) + (t.admin_impound or 0) + (t.expire or 0), t.retrieve or 0),
            icon = 'calendar-day', readOnly = true,
        },
    }

    for _, l in ipairs(o.lots) do
        local pct = l.total > 0 and math.floor(l.taken / l.total * 100) or 0
        options[#options + 1] = {
            title = ('%s  (%d/%d)'):format(l.label, l.taken, l.total),
            description = ('%s • 7d: %s from %d stays • outstanding %s'):format(
                l.price > 0 and ('$%d/hr'):format(l.price) or 'Free', money(l.week), l.weekCount, money(l.outstanding)),
            icon = 'square-parking', progress = pct,
            colorScheme = pct >= 90 and 'red' or pct >= 60 and 'yellow' or 'green',
            arrow = true,
            onSelect = function() OpenLot(l.name) end,
        }
    end

    options[#options + 1] = { title = 'Search plate', icon = 'magnifying-glass',
        onSelect = function()
            local input = lib.inputDialog('Search plate', { { type = 'input', label = 'Plate', required = true, max = 8 } })
            if input and input[1] then OpenVehicle(input[1], 'rps_parking_admin') end
        end }
    options[#options + 1] = { title = ('Impound lot (%d)'):format(o.impounded), icon = 'truck-pickup', arrow = true,
        onSelect = OpenImpoundList }
    options[#options + 1] = { title = 'Recent activity', icon = 'list', arrow = true,
        onSelect = function() OpenLogs('all') end }
    options[#options + 1] = { title = 'Lot editor', description = 'Create / edit parking lots, zones, bays and machines',
        icon = 'draw-polygon', arrow = true, onSelect = function() OpenLotEditor() end }
    options[#options + 1] = { title = 'Refresh', icon = 'rotate', onSelect = OpenAdmin }

    lib.registerContext({ id = 'rps_parking_admin', title = 'Parking Logistics', options = options })
    lib.showContext('rps_parking_admin')
end

RegisterCommand(Config.Admin.command, OpenAdmin, false)
TriggerEvent('chat:addSuggestion', '/' .. Config.Admin.command, 'Parking logistics admin panel')
