-- OPS POS (client): [E] at a till opens the POS screen (NUI), screens light up on live tills, the customer display
-- shows the basket to people standing near it, the cash drawer slides open on cash sales, and customers approve
-- payments (card on their phone through opslabs-phone, cash with a prompt).

local Terminals = {}         -- server list: { id, x, y, z, heading, kit = { reader = {id, x, y, z}, ... }, store }
local open = nil             -- terminal id while the POS screen is up
local Displays = {}          -- terminal id -> { until, data }
local glows = {}             -- fixture id -> { ent, base }
local shown = false

local function vec(t) return vector3(t.x, t.y, t.z) end

local function setTerminals(list) Terminals = list or {} end
RegisterNetEvent('opslabs-pos:terminals', setTerminals)
CreateThread(function()
    Wait(2000)
    setTerminals(lib.callback.await('opslabs-pos:terminals', false))
end)

---------------------------------------------------------------------------
-- the POS screen
---------------------------------------------------------------------------
local function close()
    if not open then return end
    open = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

local function openTill(t)
    local data = lib.callback.await('opslabs-pos:open', false, t.id)
    if not data or data.error then
        return lib.notify({ type = 'error', title = 'OPS POS', description = data and data.error or 'The till is not responding' })
    end
    open = t.id
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', data = data })
end

-- [E] at the nearest till
CreateThread(function()
    while true do
        local wait = 750
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local near, nd
        for _, t in ipairs(Terminals) do
            local d = #(pos - vec(t))
            if d < Config.UseDistance and (not nd or d < nd) then near, nd = t, d end
        end
        if near and not open then
            wait = 0
            if not shown then
                shown = true
                lib.showTextUI(('[E] %s'):format(near.store and near.store.name or 'OPS POS · set up this till'), { icon = 'cash-register' })
            end
            if IsControlJustReleased(0, 38) then
                lib.hideTextUI()
                shown = false
                openTill(near)
            end
        elseif shown then
            shown = false
            lib.hideTextUI()
        end
        -- walked away from an open till
        if open then
            local t
            for _, x in ipairs(Terminals) do if x.id == open then t = x end end
            if not t or #(pos - vec(t)) > Config.UseDistance + 2.0 then close() end
        end
        Wait(wait)
    end
end)

-- NUI → server
local function relay(name, fn)
    RegisterNUICallback(name, function(body, cb) cb(fn(body or {}) or {}) end)
end
RegisterNUICallback('close', function(_, cb) cb(true) close() end)
relay('setup', function(b) return lib.callback.await('opslabs-pos:setup', false, open, b.name) end)
relay('reopen', function() return lib.callback.await('opslabs-pos:open', false, open) end)
relay('clock', function(b) return lib.callback.await('opslabs-pos:clock', false, b.store) end)
relay('carried', function() return { items = lib.callback.await('opslabs-pos:carried', false) } end)
relay('product', function(b) return lib.callback.await('opslabs-pos:product', false, b.store, b.action, b.data) end)
relay('customers', function() return { list = lib.callback.await('opslabs-pos:customers', false, open) } end)
relay('charge', function(b) return lib.callback.await('opslabs-pos:charge', false, open, b.basket, b.customer, b.method, b.redeem) end)
relay('report', function(b) return lib.callback.await('opslabs-pos:report', false, b.store) end)
relay('refund', function(b) return lib.callback.await('opslabs-pos:refund', false, b.store, b.sale) end)
relay('cashup', function(b) return lib.callback.await('opslabs-pos:cashup', false, b.store) end)
relay('settings', function(b) return lib.callback.await('opslabs-pos:settings', false, b.store, b.data) end)
relay('payLicence', function(b) return lib.callback.await('opslabs-pos:payLicence', false, b.store) end)
RegisterNUICallback('basket', function(b, cb)
    cb(true)
    if open then TriggerServerEvent('opslabs-pos:basket', open, b.lines, b.total, b.customer) end
end)
RegisterNUICallback('beep', function(_, cb)
    cb(true)
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDS', true)
end)

---------------------------------------------------------------------------
-- paying: the server asks the customer
---------------------------------------------------------------------------
local PayWait = {}      -- payment id -> promise, while the customer looks at their phone
AddEventHandler('opslabs-pos:payResult', function(id, ok)
    local p = PayWait[id]
    if not p then return end
    PayWait[id] = nil
    p:resolve(ok)
end)

RegisterNetEvent('opslabs-pos:payPrompt', function(d)
    local ok
    if d.method == 'card' and GetResourceState('opslabs-phone') == 'started' then
        -- contactless on the phone (opslabs-phone client/pay.lua answers with opslabs-pos:payResult);
        -- nil = no working phone, fall back to tapping the bank card
        local p = promise.new()
        PayWait[d.id] = p
        TriggerEvent('opslabs-phone:payRequest', d)
        SetTimeout(((d.timeout or 30) + 1) * 1000, function() if PayWait[d.id] then PayWait[d.id] = nil p:resolve(false) end end)
        ok = Citizen.Await(p)
    end
    if ok == nil then
        local lines = {}
        for i, l in ipairs(d.lines or {}) do
            if i > 6 then lines[#lines + 1] = '…' break end
            lines[#lines + 1] = ('%d × %s — %s%.2f'):format(l.qty or 1, l.label or '?', d.currency or '$', l.total or 0)
        end
        local what = d.method == 'card' and 'Tap your bank card to pay' or 'Hand over the cash'
        local res = lib.alertDialog({
            header = ('%s · %s%.2f'):format(d.merchant or 'OPS POS', d.currency or '$', d.total or 0),
            content = what .. '\n\n' .. table.concat(lines, '  \n'),
            centered = true, cancel = true, labels = { confirm = d.method == 'card' and 'Pay' or 'Hand over', cancel = 'Cancel' },
        })
        ok = res == 'confirm'
        if ok then
            local ped = PlayerPedId()
            lib.requestAnimDict('mp_common')
            TaskPlayAnim(ped, 'mp_common', 'givetake1_a', 8.0, -8.0, 1500, 49, 0, false, false, false)
        end
    end
    TriggerServerEvent('opslabs-pos:payRespond', d.id, ok == true)
end)

RegisterNetEvent('opslabs-pos:receipt', function(r)
    lib.notify({ type = 'success', title = r.store, description = ('Paid %s%.2f by %s%s'):format(Config.Currency, r.total, r.method,
        (r.points or 0) > 0 and (' · +%d points'):format(r.points) or ''), duration = 6000 })
end)

---------------------------------------------------------------------------
-- the hardware: lit screens, the drawer, the customer display
---------------------------------------------------------------------------
local function baseEntity(f, model)
    local e = GetClosestObjectOfType(f.x, f.y, f.z, 0.35, joaat(model), false, false, false)
    return e ~= 0 and e or nil
end

local function swap(id, f, model, variant)
    local h = joaat(model .. variant)
    if not IsModelInCdimage(h) then return end
    lib.requestModel(h, 5000)
    local e = CreateObjectNoOffset(h, f.x, f.y, f.z, false, false, false)
    SetEntityHeading(e, f.heading or 0.0)
    SetEntityCoordsNoOffset(e, f.x, f.y, f.z, false, false, false)
    FreezeEntityPosition(e, true)
    SetEntityCollision(e, false, false)
    SetModelAsNoLongerNeeded(h)
    local base = baseEntity(f, model)
    if base then SetEntityVisible(base, false, false) end
    glows[id] = { ent = e, base = base, model = model }
end

local function unswap(id)
    local g = glows[id]
    if not g then return end
    if DoesEntityExist(g.ent) then DeleteEntity(g.ent) end
    if g.base and DoesEntityExist(g.base) then SetEntityVisible(g.base, true, false) end
    glows[id] = nil
end

-- screens on: terminal, customer display and card reader of every live till nearby
CreateThread(function()
    local M = Config.Models
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local want = {}
        for _, t in ipairs(Terminals) do
            if t.store and t.store.active and #(pos - vec(t)) < 30.0 then
                want[t.id] = { f = t, model = M.terminal }
                for kind, model in pairs({ display = M.display, reader = M.reader }) do
                    local k = t.kit[kind]
                    if k then want[k.id] = { f = k, model = model } end
                end
            end
        end
        for id, g in pairs(glows) do
            if not g.drawer and (not want[id] or not DoesEntityExist(g.ent)) then unswap(id) end
        end
        for id, w in pairs(want) do
            if not glows[id] then swap(id, w.f, w.model, '_on') end
        end
        Wait(1500)
    end
end)

-- a cash sale: the drawer slides open for a few seconds
RegisterNetEvent('opslabs-pos:drawer', function(id)
    for _, t in ipairs(Terminals) do
        local k = t.kit.drawer
        if k and k.id == id then
            unswap(id)
            swap(id, k, Config.Models.drawer, '_open')
            if glows[id] then glows[id].drawer = true end
            PlaySoundFromCoord(-1, 'ROBBERY_MONEY_TOTAL', k.x, k.y, k.z, 'HUD_FRONTEND_CUSTOM_SOUNDSET', false, 0, false)
            SetTimeout(4500, function() unswap(id) end)
        end
    end
end)

-- the basket, shown above the customer display to people nearby
RegisterNetEvent('opslabs-pos:display', function(d)
    Displays[d.terminal] = { untilAt = GetGameTimer() + (d.paid and 6000 or 90000), d = d }
end)

local function text3d(x, y, z, s, scale, r, g, b)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, scale)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    SetTextColour(r or 255, g or 255, b or 255, 230)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

CreateThread(function()
    while true do
        local wait = 500
        local now = GetGameTimer()
        for tid, e in pairs(Displays) do
            if now > e.untilAt then
                Displays[tid] = nil
            else
                local t
                for _, x in ipairs(Terminals) do if x.id == tid then t = x end end
                local k = t and t.kit.display
                if k then
                    wait = 0
                    local d = e.d
                    local z = k.z + 0.62
                    text3d(k.x, k.y, z, d.store, 0.32, 255, 159, 10)
                    if d.paid then
                        text3d(k.x, k.y, z - 0.06, ('Paid %s%.2f · Thank you!'):format(Config.Currency, d.paid), 0.3, 50, 215, 75)
                    else
                        local y = z - 0.06
                        for _, l in ipairs(d.lines or {}) do
                            text3d(k.x, k.y, y, ('%d × %s   %s%.2f'):format(l.qty, l.label, Config.Currency, l.total), 0.26)
                            y = y - 0.045
                        end
                        text3d(k.x, k.y, y - 0.01, ('TOTAL %s%.2f'):format(Config.Currency, d.total or 0), 0.32, 255, 159, 10)
                    end
                end
            end
        end
        Wait(wait)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(glows) do unswap(id) end
    if open then SetNuiFocus(false, false) end
    if shown then lib.hideTextUI() end
end)
