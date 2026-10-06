-- Engineer console (Config.Console): every ox_lib context menu in this resource — /towers, the tool kits, nearby kit,
-- fuel, CCTV, grid, ladders, van … — is shown in one full-screen panel (html/console.*) instead of stacked list menus:
-- a sidebar with the main sections, breadcrumbs, search across every menu opened so far, cards with icons, live
-- values, progress bars and keyboard control. The menus themselves are unchanged (same options, same onSelect code),
-- so everything keeps working; Config.Console.Enabled = false brings the old menus back (live, no restart).

local Menus = {}            -- id -> registered context (after client/menu.lua set its Back / parent)
local current = nil         -- id of the menu on screen
local open = false
local trail = {}            -- breadcrumb ids
local ROOT = 'towers_main'
local prevRegister, prevShow, prevHide, prevGetOpen = lib.registerContext, lib.showContext, lib.hideContext, lib.getOpenContextMenu

-- each player picks their own style (/towers → Menu style), kept on their PC; Config.MenuStyle.Default otherwise.
-- ForceClassicMenus (the pole quick menu, Z up a pole) shows the small menus whatever the style.
local STYLE_KEY = 'opslabs-towers:menuStyle'
function MenuStyle()
    local ok, v = pcall(GetResourceKvpString, STYLE_KEY)
    if ok and (v == 'console' or v == 'classic') then return v end
    return ((Config.MenuStyle or {}).Default == 'classic') and 'classic' or 'console'
end
function SetMenuStyle(v) SetResourceKvp(STYLE_KEY, v == 'classic' and 'classic' or 'console') end
ForceClassicMenus = false
local function enabled()
    if ForceClassicMenus or (Config.Console or {}).Enabled == false then return false end
    return MenuStyle() == 'console'
end

local function icon(i)
    if type(i) ~= 'string' or i == '' then return nil end
    if i:find('^fa[srlbd]? ') or i:find('^fa%-') then return i end
    return 'fa-solid fa-' .. i
end

local function plain(v)
    local t = type(v)
    if t == 'string' or t == 'number' or t == 'boolean' then return v end
    return nil
end

local function metaOf(m)
    if type(m) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(m) do
        if type(v) == 'table' then out[#out + 1] = { label = plain(v.label), value = plain(v.value), progress = plain(v.progress) }
        elseif type(k) == 'string' then out[#out + 1] = { label = k, value = plain(v) }
        else out[#out + 1] = { value = plain(v) } end
        if #out >= 6 then break end
    end
    return #out > 0 and out or nil
end

local function optionsOf(ctx)
    local list = {}
    local opts = ctx.options or {}
    local keys = {}
    for k in pairs(opts) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) if type(a) == type(b) then return a < b end return type(a) == 'number' end)
    for _, k in ipairs(keys) do
        local o = opts[k]
        if type(o) == 'table' then
            list[#list + 1] = {
                k = k, title = plain(o.title) or (type(k) == 'string' and k) or '', description = plain(o.description),
                icon = icon(o.icon), color = plain(o.iconColor), arrow = o.arrow == true or o.menu ~= nil,
                readOnly = o.readOnly == true or (not o.onSelect and not o.menu and not o.event and not o.serverEvent),
                disabled = o.disabled == true, progress = tonumber(o.progress), scheme = plain(o.colorScheme), meta = metaOf(o.metadata),
                image = type(o.image) == 'string' and o.image:find('^https?://') and o.image or nil,
            }
        end
    end
    return list
end

local function sidebar()
    local root = Menus[ROOT]
    if not root then return nil end
    local out = {}
    for _, o in ipairs(optionsOf(root)) do
        if not o.readOnly then out[#out + 1] = { k = o.k, title = o.title, icon = o.icon, color = o.color } end
    end
    return out
end

local function push(id)
    local ctx = Menus[id]
    if not ctx then return end
    -- breadcrumbs follow client/menu.lua's parents
    local crumbs, p = {}, id
    for _ = 1, 12 do
        local m = Menus[p]
        if not m then break end
        table.insert(crumbs, 1, { id = p, title = plain(m.title) or p })
        p = m.menu
        if not p then break end
    end
    trail = crumbs
    SendNUIMessage({ action = 'console', show = true, menu = { id = id, title = plain(ctx.title) or '', canBack = ctx.menu ~= nil or ctx.onBack ~= nil,
        options = optionsOf(ctx) }, crumbs = crumbs, sections = sidebar(), root = id == ROOT, brand = (Config.Console or {}).Title })
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(false)
    open = true
end

local function hide(silent)
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    if not silent then SendNUIMessage({ action = 'console', show = false }) end
end

lib.registerContext = function(ctx)
    local r = prevRegister(ctx)               -- client/menu.lua: parents, Back, rebuilding
    if type(ctx) == 'table' and ctx.id then Menus[ctx.id] = ctx end
    return r
end

lib.showContext = function(id)
    if not enabled() or not Menus[id] then hide() return prevShow(id) end
    current = id
    push(id)
end

lib.hideContext = function(onExit)
    if open then
        hide()
        local ctx = current and Menus[current]
        if onExit and ctx and ctx.onExit then pcall(ctx.onExit) end
        return
    end
    return prevHide(onExit)
end

lib.getOpenContextMenu = function()
    if open then return current end
    return prevGetOpen()
end

--- run an option: the panel steps aside (dialogs, placing kit, progress bars need the game) and comes back if the
--- option opens another menu
local function run(ctx, o)
    if not o or o.disabled or o.readOnly then return end
    hide(false)
    CreateThread(function()
        if o.onSelect then
            local ok, err = pcall(o.onSelect, o.args)
            if not ok then print(('[opslabs-towers] menu action failed: %s'):format(err)) end
        elseif o.menu then
            lib.showContext(o.menu)
        elseif o.event then
            TriggerEvent(o.event, o.args)
        elseif o.serverEvent then
            TriggerServerEvent(o.serverEvent, o.args)
        end
    end)
end

RegisterNUICallback('consoleSelect', function(d, cb)
    cb(true)
    local ctx = Menus[d.menu]
    if not ctx then return end
    local o = (ctx.options or {})[tonumber(d.k) or d.k]
    run(ctx, o)
end)

RegisterNUICallback('consoleSection', function(d, cb)
    cb(true)
    local root = Menus[ROOT]
    local o = root and (root.options or {})[tonumber(d.k) or d.k]
    if o then run(root, o) end
end)

RegisterNUICallback('consoleBack', function(_, cb)
    cb(true)
    local ctx = current and Menus[current]
    if not ctx or not (ctx.menu or ctx.onBack) then
        hide()
        if ctx and ctx.onExit then pcall(ctx.onExit) end
        return
    end
    hide(true)
    if ctx.onBack then pcall(ctx.onBack) end          -- client/menu.lua rebuilds and reopens the parent
    if not open and ctx.menu and Menus[ctx.menu] then lib.showContext(ctx.menu) end
end)

RegisterNUICallback('consoleCrumb', function(d, cb)
    cb(true)
    if d.id and Menus[d.id] then lib.showContext(d.id) end
end)

RegisterNUICallback('consoleClose', function(_, cb)
    cb(true)
    local ctx = current and Menus[current]
    hide()
    if ctx and ctx.onExit then pcall(ctx.onExit) end
end)

--- search: every option of every menu opened this session
RegisterNUICallback('consoleSearch', function(d, cb)
    local q = tostring(d.q or ''):lower()
    local out = {}
    if #q >= 2 then
        for id, ctx in pairs(Menus) do
            for _, o in ipairs(optionsOf(ctx)) do
                if not o.readOnly and not o.disabled and (o.title:lower():find(q, 1, true) or (o.description or ''):lower():find(q, 1, true)) then
                    o.menu, o.menuTitle = id, plain(ctx.title) or id
                    out[#out + 1] = o
                    if #out >= 40 then break end
                end
            end
            if #out >= 40 then break end
        end
    end
    cb(out)
end)

AddEventHandler('opslabs:configChanged', function(res)
    if res == GetCurrentResourceName() and open and not enabled() then hide() if current then prevShow(current) end end
end)
AddEventHandler('onResourceStop', function(res) if res == GetCurrentResourceName() and open then SetNuiFocus(false, false) end end)
