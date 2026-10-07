-- OPSHUB licensing in OPS Phone. The license itself lives in opslabs-license (the only place with the key and the signed
-- certificate); the phone just asks it which modules this server has:
--   · every NUI call goes through Register() (server/main.lua) → LicenseGate(): the phone core needs module 'phone',
--     each app's calls need that app's module (below)
--   · the UI gets the license with init (config.license) and live updates, hides apps that aren't licensed and shows the
--     OPSHUB license screen until the server is licensed (html/js/license.js)

local L = { status = 'starting', modules = {}, set = {}, allowAll = false }

local function refresh(s)
    if type(s) ~= 'table' then return end
    L = s
    L.set = {}
    for _, m in ipairs(s.modules or {}) do L.set[m] = true end
end
AddEventHandler('opslabs-license:state', refresh)

local function pull()
    if GetResourceState('opslabs-license') == 'started' then
        local ok, s = pcall(function() return exports['opslabs-license']:State() end)
        if ok then refresh(s) end
    else
        refresh({ status = 'missing', message = 'The OPSHUB license resource (opslabs-license) isn\'t running', modules = {} })
    end
end
CreateThread(function() while true do pull() Wait(30000) end end)
AddEventHandler('onResourceStart', function(r) if r == 'opslabs-license' then SetTimeout(3000, pull) end end)
AddEventHandler('onResourceStop', function(r) if r == 'opslabs-license' then pull() end end)

function LicenseHas(code)
    if L.status ~= 'active' then return false end
    return L.allowAll == true or L.set[code] == true
end

-- which module each phone server call belongs to (anything not listed is the phone core)
local EXACT = {
    sendMessage = 'phone.messages', getMessages = 'phone.messages', getConversations = 'phone.messages', deleteConversation = 'phone.messages',
    startCall = 'phone.calls', answerCall = 'phone.calls', endCall = 'phone.calls', getRecents = 'phone.calls', clearRecents = 'phone.calls',
    getContacts = 'phone.contacts', saveContact = 'phone.contacts', deleteContact = 'phone.contacts', toggleFavorite = 'phone.contacts',
    toggleBlock = 'phone.contacts', shareContact = 'phone.contacts',
    getMail = 'phone.mail', readMail = 'phone.mail', sendMail = 'phone.mail', deleteMail = 'phone.mail', mailFrom = 'phone.mail',
    cameraUploadToken = 'phone.camera', getPhotos = 'phone.camera', savePhoto = 'phone.camera', deletePhoto = 'phone.camera', favoritePhoto = 'phone.camera',
    getBank = 'phone.wallet', transfer = 'phone.wallet', payBill = 'phone.wallet',
    getLiveShares = 'phone.maps', startLiveLocation = 'phone.maps', stopLiveLocation = 'phone.maps', stopAllLiveLocation = 'phone.maps',
    laptopNet = 'phone.laptop',
}
local PREFIXES = { { '^chirp', 'phone.social' }, { '^dating', 'phone.social' }, { '^web', 'phone.browser' }, { '^opsnet', 'phone.opswork' },
    { '^ops', 'phone.opswork' }, { '^traffic', 'phone.traffic' }, { '^cctv', 'phone.secureview' }, { '^dev', 'phone.admin' } }
-- always allowed: what the phone needs to start, set itself up and show the license screen
local ALWAYS = { init = true, setupInfo = true, setupCheck = true, completeSetup = true, saveSettings = true, licenseState = true, licenseActivate = true, licenseRefresh = true }

function LicenseModuleFor(name)
    if EXACT[name] then return EXACT[name] end
    for _, p in ipairs(PREFIXES) do if name:find(p[1]) then return p[2] end end
    return nil
end

--- nil = allowed, otherwise what the NUI gets back
function LicenseGate(src, name)
    if ALWAYS[name] then return nil end
    if not LicenseHas('phone') then return { __license = 'phone' } end
    local m = LicenseModuleFor(name)
    if m and not LicenseHas(m) then return { __license = m } end
    return nil
end

-- who may enter the key on the phone: FiveM permission (opshub.license / command, checked by opslabs-license) or an ESX
-- admin group
local ADMIN_GROUPS = { 'owner', 'superadmin', 'admin', 'god', 'dev', 'developer' }
local function canManage(src)
    -- not licensed yet: anyone may enter the key (it only works with a real OPSHUB key); once licensed, only admins
    -- can change it, so a player can't swap the server onto another license
    if L.status ~= 'active' then return true end
    if FW.IsAdmin and FW.IsAdmin(src, ADMIN_GROUPS) then return true end
    if GetResourceState('opslabs-license') == 'started' then
        local ok, r = pcall(function() return exports['opslabs-license']:CanManage(src) end)
        return ok and r == true
    end
    return false
end

--- for the UI (init payload and the license screen)
function LicenseForUi(src)
    local can = canManage(src)
    local mods = {}
    for _, m in ipairs(L.modules or {}) do mods[#mods + 1] = m end
    return { status = L.status, message = L.message, modules = mods, allowAll = L.allowAll == true, customer = L.customer,
        keyTail = L.keyTail, expiresAt = L.expiresAt, canManage = can }
end

Register('licenseState', function(src) pull() return LicenseForUi(src) end)

--- "Check again": the server checks in with OPSHUB now, then answers with the fresh state
Register('licenseRefresh', function(src)
    if GetResourceState('opslabs-license') == 'started' then
        local ok, s = pcall(function() return exports['opslabs-license']:Refresh() end)
        if ok then refresh(s) end
    end
    pull()
    return LicenseForUi(src)
end)

Register('licenseActivate', function(src, _, d)
    if GetResourceState('opslabs-license') ~= 'started' then return { error = 'The OPSHUB license resource (opslabs-license) isn\'t running on this server' } end
    if not canManage(src) then return { error = 'Only a server admin can activate the license' } end
    print(('[opslabs-phone] OPSHUB license activation from the phone by %s (%s)'):format(GetPlayerName(src) or '?', FW.Identifier(src) or '?'))
    -- the phone checked the admin itself (ESX groups included), so it hands the key over with the console's authority
    local ok, r = pcall(function() return exports['opslabs-license']:Activate(0, d and d.key) end)
    if not ok then return { error = 'Activation failed' } end
    if r ~= true then return { error = r } end
    pull()
    return { ok = true, license = LicenseForUi(src) }
end)
