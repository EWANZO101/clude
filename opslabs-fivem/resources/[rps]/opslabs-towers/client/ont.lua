-- ONT status: walk up to an ONT and a panel pops up with its lights (POWER, PON, LOS, LAN,
-- INTERNET) and line details; walk away and it closes. Engineers provision the internet
-- service from Network cabling → Telecom equipment → the ONT → Internet service.

local CI = Config.Isp
local status, receivedAt = {}, 0
local showing = nil

RegisterNetEvent('opslabs-towers:ont', function(s)
    status = {}
    for k, v in pairs(s or {}) do status[tonumber(k)] = v end
    receivedAt = GetGameTimer()
end)

--- what the lights show right now (blinking settles on the client as time passes)
local function view(id)
    local s = status[id]
    if not s then return { pon = 'off', los = true, lan = 'off', internet = 'off', service = 'none', serial = '—' } end
    local elapsed = (GetGameTimer() - receivedAt) / 1000
    local o = {}
    for k, v in pairs(s) do o[k] = v end
    if s.pon == 'on' and elapsed < (s.ponBlink or 0) then o.pon = 'blink' end
    if s.internet == 'on' then
        if o.pon == 'blink' then o.internet = 'off'
        elseif elapsed < (s.authBlink or 0) then o.internet = 'blink' end
    end
    if o.lan == 'traffic' and o.internet ~= 'on' then o.lan = 'on' end
    o.uptime = math.floor((s.uptime or 0) + elapsed)
    return o
end

local function nearestOnt(maxDist)
    local pos = GetEntityCoords(PlayerPedId())
    local best, bd
    for id, f in pairs(CablingFixtures and CablingFixtures() or {}) do
        if f.model == CI.Ont then
            local d = #(pos - vector3(f.x, f.y, f.z))
            if d < (bd or maxDist) and math.abs(pos.z - f.z) < 2.5 then best, bd = id, d end
        end
    end
    return best
end

--- what an ONT reports right now (power meter / network tester read this)
function OntReading(id) return view(id) end

CreateThread(function()
    local lastSend = 0
    while true do
        local ped = PlayerPedId()
        local id = not IsPedInAnyVehicle(ped, false) and not IsPauseMenuActive() and nearestOnt(CI.PopupDistance or 1.8)
        if id then
            if showing ~= id or GetGameTimer() - lastSend > 1000 then
                local v = view(id)
                SendNUIMessage({ action = 'ont', ont = v })
                if Coach then Coach('ont', v) end
                showing, lastSend = id, GetGameTimer()
            end
            Wait(200)
        else
            if showing then SendNUIMessage({ action = 'hide' }) showing = nil end
            Wait(400)
        end
    end
end)

---------------------------------------------------------------------------
-- provisioning menu (opened from the ONT in the Telecom equipment list)
---------------------------------------------------------------------------

function IspMenu(f, back)
    local s = view(f.id)
    local summary = s.los and 'No fibre signal (LOS)'
        or s.service == 'none' and 'Fibre live · no service'
        or s.service == 'suspended' and ('Suspended · ' .. (s.provider or ''))
        or ('%s · %s (%d/%d)'):format(s.provider or '?', s.plan or '?', s.down or 0, s.up or 0)
    local options = {
        { title = summary, description = s.rx and ('Rx %.1f dBm · %d m of fibre · %d joints'):format(s.rx, s.distance or 0, s.joints or 0) or 'Splice fibre from a cabinet through to this ONT',
          icon = 'wifi', iconColor = s.los and '#ff453a' or s.service == 'active' and '#30d158' or '#ff9f0a', readOnly = true },
        { title = s.service == 'none' and 'Provision internet service' or 'Change provider / plan', icon = 'plus', onSelect = function()
            local provs, plans = {}, {}
            for _, p in ipairs(CI.Providers) do
                provs[#provs + 1] = { value = p.id, label = p.name }
                for _, pl in ipairs(p.plans) do plans[#plans + 1] = { value = p.id .. ':' .. pl.id, label = ('%s · %s (%d/%d Mbps)'):format(p.name, pl.name, pl.down, pl.up) } end
            end
            local v = lib.inputDialog('Internet service', {
                { type = 'select', label = 'Provider & plan', options = plans, required = true, default = plans[1] and plans[1].value },
                { type = 'input', label = 'Customer / address (shown on the ONT)', default = s.customer or '', max = 80 },
            })
            if v then
                local pid, plid = v[1]:match('^([^:]+):(.+)$')
                local r = lib.callback.await('opslabs-towers:isp:provision', false, f.id, pid, plid, v[2] ~= '' and v[2] or nil)
                if r and r.ok then lib.notify({ type = 'success', description = 'Line provisioned — the ONT will authenticate in a few seconds' })
                else lib.notify({ type = 'error', description = (r and r.error) or 'Failed' }) end
                Wait(300)
            end
            IspMenu(f, back)
        end },
    }
    if s.service == 'active' then
        options[#options + 1] = { title = 'Suspend service', icon = 'pause', onSelect = function()
            lib.callback.await('opslabs-towers:isp:setStatus', false, f.id, 'suspended') Wait(300) IspMenu(f, back)
        end }
    elseif s.service == 'suspended' then
        options[#options + 1] = { title = 'Resume service', icon = 'play', iconColor = '#30d158', onSelect = function()
            lib.callback.await('opslabs-towers:isp:setStatus', false, f.id, 'active') Wait(300) IspMenu(f, back)
        end }
    end
    if s.service ~= 'none' then
        options[#options + 1] = { title = 'Cease service', description = 'Removes the provider from this line', icon = 'xmark', iconColor = '#ff453a', onSelect = function()
            if lib.alertDialog({ header = 'Cease this line?', centered = true, cancel = true }) == 'confirm' then
                lib.callback.await('opslabs-towers:isp:setStatus', false, f.id, 'cease') Wait(300)
            end
            IspMenu(f, back)
        end }
    end
    lib.registerContext({ id = 'isp_menu', title = 'Internet service · ONT #' .. f.id, onBack = back, menu = back and 'cable_fixture' or nil, options = options })
    lib.showContext('isp_menu')
end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and showing then SendNUIMessage({ action = 'hide' }) end
end)
