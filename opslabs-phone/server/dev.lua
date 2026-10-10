-- Developer app: manage Maps locations (+ in-game blips), global wallpapers,
-- phone numbers and broadcasts from inside the phone. The app is on every
-- phone; every action requires a logged-in Developer session (see
-- config_server.lua), checked here on the server.

-- Logged-in Developer sessions, per player. A session lasts until the player
-- logs out, switches character or disconnects.
local sessions = {}
local attempts = {}   -- [src] = { count, lockedUntil }

function IsDev(src)
    return sessions[src] == true
end

local function endSession(src)
    sessions[src] = nil
    attempts[src] = nil
end

AddEventHandler('playerDropped', function() endSession(source) end)
AddEventHandler('esx:playerLogout', function(src) endSession(src) end)
AddEventHandler('esx:playerLoaded', function(src) endSession(src) end)

Register('devSession', function(src)
    return { loggedIn = IsDev(src) }
end)

Register('devLogin', function(src, phone, data)
    local cfg = ServerConfig.DevLogin
    local now = os.time()
    local a = attempts[src] or { count = 0, lockedUntil = 0 }
    attempts[src] = a

    if a.lockedUntil > now then
        return { error = ('Too many attempts. Try again in %d seconds.'):format(a.lockedUntil - now) }
    end

    local email = tostring(data.email or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    local password = tostring(data.password or '')

    if cfg.Password and cfg.Password ~= '' and email == tostring(cfg.Email):lower() and password == tostring(cfg.Password) then
        sessions[src] = true
        attempts[src] = nil
        print(('^3[opslabs-phone]^7 %s (%s) logged into the Developer app'):format(phone.name, phone.identifier))
        return { ok = true }
    end

    a.count = a.count + 1
    if a.count >= cfg.MaxAttempts then
        a.count = 0
        a.lockedUntil = now + cfg.LockoutSeconds
        print(('^1[opslabs-phone]^7 Developer app locked for %s (%s) after failed logins'):format(phone.name, phone.identifier))
        return { error = ('Too many attempts. Try again in %d seconds.'):format(cfg.LockoutSeconds) }
    end
    return { error = 'Incorrect username or password.', remaining = cfg.MaxAttempts - a.count }
end)

Register('devLogout', function(src)
    sessions[src] = nil
    return { ok = true }
end)

local function DevRegister(name, handler)
    Register(name, function(src, phone, data)
        if not IsDev(src) then return { error = 'Please sign in to the Developer app', loggedOut = true } end
        return handler(src, phone, data)
    end)
end

---------------------------------------------------------------------------
-- places (Maps app + optional GTA map blips)
---------------------------------------------------------------------------

local dbPlaces = {}
local dbWallpapers = {}

local function loadPlaces()
    dbPlaces = MySQL.query.await('SELECT * FROM opslabs_phone_places ORDER BY category, name') or {}
end

local function loadWallpapers()
    dbWallpapers = MySQL.query.await('SELECT * FROM opslabs_phone_wallpapers ORDER BY id') or {}
end

--- Config.Places + places added in-game, in the shape the UI expects.
function GetAllPlaces()
    local list = placesForUi()
    for _, p in ipairs(list) do p.source = 'config' end
    for _, p in ipairs(dbPlaces) do
        list[#list + 1] = {
            id = p.id, source = 'db', name = p.name, icon = p.icon, category = p.category,
            coords = { x = p.x, y = p.y, z = p.z },
            blip = IsTrue(p.blip), blipSprite = p.blip_sprite, blipColor = p.blip_color,
        }
    end
    return list
end

local function blipPlaces()
    local list = {}
    for _, p in ipairs(dbPlaces) do
        if IsTrue(p.blip) then
            list[#list + 1] = { id = p.id, name = p.name, x = p.x, y = p.y, z = p.z, sprite = p.blip_sprite, color = p.blip_color }
        end
    end
    return list
end

function GetAllWallpapers()
    local list = {}
    for _, w in ipairs(Config.Wallpapers) do list[#list + 1] = w end
    for _, w in ipairs(dbWallpapers) do
        -- single quotes + percent-encoding so the css is safe inside html style="" attributes
        local safe = w.url:gsub('[\'"()%s<>\\]', function(c) return ('%%%02X'):format(c:byte()) end)
        list[#list + 1] = { id = 'db' .. w.id, dbId = w.id, label = w.label, css = ("url('%s') center/cover"):format(safe) }
    end
    return list
end

local function broadcastPlaces()
    local places = GetAllPlaces()
    for src in pairs(Phones) do Push(src, 'placesUpdated', places) end
    TriggerClientEvent('opslabs-phone:placeBlips', -1, blipPlaces())
end

local function broadcastWallpapers()
    local list = GetAllWallpapers()
    for src in pairs(Phones) do Push(src, 'wallpapersUpdated', list) end
end

lib.callback.register('opslabs-phone:getPlaceBlips', function()
    return blipPlaces()
end)

CreateThread(function()
    AwaitDatabase()
    loadPlaces()
    loadWallpapers()
    TriggerClientEvent('opslabs-phone:placeBlips', -1, blipPlaces())
end)

local function cleanIcon(icon)
    icon = tostring(icon or ''):match('^fa%-[%w%-]+$')
    return icon or 'fa-location-dot'
end

DevRegister('devSavePlace', function(src, phone, data)
    local name = Clean(data.name, 80)
    if name == '' then return { error = 'Name is required' } end
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if data.useMyPosition or not (x and y and z) then
        local c = GetEntityCoords(GetPlayerPed(src))
        x, y, z = tonumber(data.px) or c.x, tonumber(data.py) or c.y, tonumber(data.pz) or c.z
    end
    if not (x and y and z) then return { error = 'Invalid position' } end
    local values = {
        name, cleanIcon(data.icon), Clean(data.category, 30) ~= '' and Clean(data.category, 30) or 'General',
        x, y, z, data.blip and 1 or 0,
        math.floor(tonumber(data.blipSprite) or 1), math.floor(tonumber(data.blipColor) or 0),
    }
    local id = tonumber(data.id)
    if id then
        values[#values + 1] = id
        MySQL.update.await('UPDATE opslabs_phone_places SET name = ?, icon = ?, category = ?, x = ?, y = ?, z = ?, blip = ?, blip_sprite = ?, blip_color = ? WHERE id = ?', values)
    else
        values[#values + 1] = phone.identifier
        id = MySQL.insert.await('INSERT INTO opslabs_phone_places (name, icon, category, x, y, z, blip, blip_sprite, blip_color, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', values)
    end
    loadPlaces()
    broadcastPlaces()
    return { ok = true, id = id }
end)

DevRegister('devDeletePlace', function(_, _, data)
    MySQL.update.await('DELETE FROM opslabs_phone_places WHERE id = ?', { tonumber(data.id) })
    loadPlaces()
    broadcastPlaces()
    return { ok = true }
end)

DevRegister('devTeleport', function(src, _, data)
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if data.waypoint then
        TriggerClientEvent('opslabs-phone:devTeleport', src, { waypoint = true })
        return { ok = true }
    end
    if not (x and y and z) then return { error = 'Invalid position' } end
    TriggerClientEvent('opslabs-phone:devTeleport', src, { x = x, y = y, z = z })
    return { ok = true }
end)

---------------------------------------------------------------------------
-- wallpapers
---------------------------------------------------------------------------

DevRegister('devAddWallpaper', function(_, phone, data)
    local url = CleanUrl(data.url)
    if not url then return { error = 'A valid http(s) image URL is required' } end
    local label = Clean(data.label, 40)
    MySQL.insert.await('INSERT INTO opslabs_phone_wallpapers (label, url, created_by) VALUES (?, ?, ?)', { label ~= '' and label or 'Custom', url, phone.identifier })
    loadWallpapers()
    broadcastWallpapers()
    return { ok = true }
end)

DevRegister('devDeleteWallpaper', function(_, _, data)
    MySQL.update.await('DELETE FROM opslabs_phone_wallpapers WHERE id = ?', { tonumber(data.id) })
    loadWallpapers()
    broadcastWallpapers()
    return { ok = true }
end)

---------------------------------------------------------------------------
-- players / numbers / broadcast / stats
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- world cleanup (opslabs-towers Config.WorldCleanup): hide GTA fuel pumps, poles, traffic lights
---------------------------------------------------------------------------
local TOWERS = 'opslabs-towers'
local CLEAN_KEYS = { Enabled = 'boolean', GasStations = 'boolean', Poles = 'boolean', TrafficLights = 'boolean', Radius = 'number', Extra = 'table' }

DevRegister('devWorldCleanup', function()
    if GetResourceState(TOWERS) ~= 'started' then return { error = 'opslabs-towers is not running' } end
    local W = exports[TOWERS]:GetSetting('WorldCleanup') or {}
    local M = W.Models or {}
    return { enabled = W.Enabled ~= false, gas = W.GasStations ~= false, poles = W.Poles ~= false, lights = W.TrafficLights ~= false, radius = W.Radius or 400,
        extra = W.Extra or {}, counts = { gas = #(M.GasStations or {}), poles = #(M.Poles or {}), lights = #(M.TrafficLights or {}) } }
end)

DevRegister('devSetWorldCleanup', function(src, _, data)
    if GetResourceState(TOWERS) ~= 'started' then return { error = 'opslabs-towers is not running' } end
    local key = tostring(data.key or '')
    if not CLEAN_KEYS[key] then return { error = 'Unknown setting' } end
    local v = data.value
    if CLEAN_KEYS[key] == 'number' then v = math.max(100, math.min(1500, tonumber(v) or 400)) end
    if CLEAN_KEYS[key] == 'table' then
        local list = {}
        for _, m in ipairs(type(v) == 'table' and v or {}) do
            m = tostring(m):lower():gsub('[^%w_]', '')
            if m ~= '' and not m:find('^opslabs_') and #list < 100 then list[#list + 1] = m end
        end
        v = list
    end
    if CLEAN_KEYS[key] == 'boolean' then v = v == true end
    exports[TOWERS]:SetSetting('WorldCleanup.' .. key, v, GetPlayerName(src) .. ' (dev app)')
    return { ok = true }
end)

DevRegister('devStats', function()
    local online = 0
    for _ in pairs(Phones) do online = online + 1 end
    return {
        online = online,
        users = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_users'),
        messages = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_messages'),
        places = #dbPlaces + #Config.Places,
        calls = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_calls'),
        posts = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_chirp_posts'),
    }
end)

DevRegister('devFindUsers', function(_, _, data)
    local q = '%' .. Clean(data.query, 40) .. '%'
    local rows = MySQL.query.await([[
        SELECT p.identifier, p.phone_number AS number, p.email, u.firstname, u.lastname
        FROM opslabs_phone_users p LEFT JOIN users u ON u.identifier = p.identifier
        WHERE p.phone_number LIKE ? OR CONCAT(IFNULL(u.firstname, ''), ' ', IFNULL(u.lastname, '')) LIKE ? OR p.email LIKE ?
        ORDER BY u.firstname LIMIT 30]], { q, q, q }) or {}
    for _, r in ipairs(rows) do
        r.name = ((r.firstname or '') .. ' ' .. (r.lastname or '')):gsub('^%s+', ''):gsub('%s+$', '')
        r.online = GetSourceByIdentifier(r.identifier) ~= nil and Phones[GetSourceByIdentifier(r.identifier)] ~= nil
        r.identifier = nil
        r.firstname, r.lastname = nil, nil
    end
    return rows
end)

DevRegister('devSetNumber', function(_, _, data)
    local user = MySQL.single.await('SELECT identifier, phone_number, email, settings FROM opslabs_phone_users WHERE phone_number = ?', { NormalizeNumber(data.number) })
    if not user then return { error = 'Phone not found' } end
    local result, _, message = ApplyPhoneUpdate(user, { number = data.newNumber })
    if not result then return { error = message } end
    return result
end)

DevRegister('devMailDomain', function()
    return { domain = GetMailDomain(), default = Config.MailDomain }
end)

-- Changes the mail domain for new addresses; with migrate = true every
-- existing address (and mail history) moves to the new domain too.
DevRegister('devSetMailDomain', function(src, phone, data)
    local domain = tostring(data.domain or ''):lower():gsub('%s', '')
    if not domain:match('^[a-z0-9][a-z0-9%-%.]*%.[a-z][a-z]+$') or #domain > 60 then
        return { error = 'Enter a domain like opslabs.cloud' }
    end
    local old = GetMailDomain()
    if data.migrate and domain ~= old then
        local ok = MySQL.transaction.await({
            { query = "UPDATE opslabs_phone_mail SET receiver = CONCAT(SUBSTRING_INDEX(receiver, '@', 1), '@', ?) WHERE receiver LIKE ?", values = { domain, '%@' .. old } },
            { query = "UPDATE opslabs_phone_mail SET sender = CONCAT(SUBSTRING_INDEX(sender, '@', 1), '@', ?) WHERE sender LIKE ?", values = { domain, '%@' .. old } },
            { query = "UPDATE opslabs_phone_users SET email = CONCAT(SUBSTRING_INDEX(email, '@', 1), '@', ?) WHERE email LIKE ?", values = { domain, '%@' .. old } },
        })
        if not ok then return { error = 'Could not move existing addresses (an address already exists on the new domain).' } end
        for s in pairs(Phones) do ReloadPhone(s) Push(s, 'reload') end
    end
    SetKV('mail_domain', domain)
    print(('^3[opslabs-phone]^7 %s changed the mail domain %s -> %s%s'):format(phone.name, old, domain, data.migrate and ' (migrated)' or ''))
    return { ok = true, domain = domain }
end)

---------------------------------------------------------------------------
-- OPSHUB license (opslabs-license): see it, change the key, check in now, release this server
local function lic() return GetResourceState('opslabs-license') == 'started' and exports['opslabs-license'] or nil end

DevRegister('devLicenseState', function()
    local L = lic()
    if not L then return { installed = false } end
    local ok, s = pcall(function() return L:State() end)
    return { installed = true, state = ok and s or nil }
end)

DevRegister('devLicenseKey', function(src, _, d)
    local L = lic()
    if not L then return { error = 'opslabs-license isn\'t running' } end
    local key = tostring(d and d.key or '')
    print(('^3[opslabs-phone]^7 %s changed the OPSHUB license key from the Developer app'):format(GetPlayerName(src) or src))
    local ok, r = pcall(function() return L:ChangeKey(key) end)
    if not ok then ok, r = pcall(function() return L:Activate(0, key) end) end      -- older opslabs-license: no ChangeKey yet
    if not ok then return { error = 'Activation failed' } end
    if r ~= true then return { error = r } end
    return { ok = true }
end)

DevRegister('devLicenseRefresh', function()
    local L = lic()
    if not L then return { error = 'opslabs-license isn\'t running' } end
    local ok, s = pcall(function() return L:Refresh() end)
    return ok and { ok = true, state = s } or { error = 'Check-in failed' }
end)

DevRegister('devLicenseRelease', function(src)
    local L = lic()
    if not L then return { error = 'opslabs-license isn\'t running' } end
    print(('^1[opslabs-phone]^7 %s released this server from its OPSHUB license (Developer app)'):format(GetPlayerName(src) or src))
    local ok = pcall(function() return L:Release() end)
    if not ok then return { error = 'This needs the newer opslabs-license — restart the server first, or release it in the OPSHUB client portal' } end
    return { ok = true }
end)

-- OPS Hub connection (multi-server, opslabs-connect): status, pairing code, forget the paired token

local function hubConnect()
    return GetResourceState('opslabs-connect') == 'started' and exports['opslabs-connect'] or nil
end

DevRegister('devHubStatus', function()
    local c = hubConnect()
    if not c then return { installed = false } end
    local s = c:status()
    s.installed = true
    return s
end)

DevRegister('devHubPair', function(src, phone)
    local c = hubConnect()
    if not c then return { error = 'Install and start the opslabs-connect resource first.' } end
    local r = c:startPairing()
    if not r.error then print(('^3[opslabs-phone]^7 %s (%s) requested an OPS Hub pairing code'):format(phone.name, phone.identifier)) end
    return r
end)

DevRegister('devHubForget', function(src, phone)
    local c = hubConnect()
    if not c then return { error = 'opslabs-connect is not running.' } end
    local r = c:forget()
    if r.ok then print(('^3[opslabs-phone]^7 %s (%s) removed the paired OPS Hub token'):format(phone.name, phone.identifier)) end
    return r
end)

DevRegister('devBroadcast', function(_, _, data)
    local title, body = Clean(data.title, 80), Clean(data.body, 300)
    if body == '' then return { error = 'Message is required' } end
    local n = 0
    for src in pairs(Phones) do
        Notify(src, { app = 'dev', title = title ~= '' and title or 'Server', body = body, icon = 'fa-bullhorn' })
        n = n + 1
    end
    return { ok = true, delivered = n }
end)
