-- players, jobs, money and items go through FW (bridge/: the detected framework and inventory adapters)

Phones = {}          -- [source] = { identifier, number, email, name, settings }
local numberIndex = {} -- [number] = source

local PREFIX = 'opslabs-phone:'

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

--- oxmysql returns TINYINT(1) columns as booleans and other ints as numbers;
--- this accepts either so `true`, 1 and '1' all count as yes.
function IsTrue(v)
    return v == true or v == 1 or v == '1'
end

function Clean(s, max)
    s = trim(s):gsub('[%c]', ' ')
    if max and #s > max then s = s:sub(1, max) end
    return s
end

function CleanUrl(url)
    url = trim(url)
    if url == '' then return nil end
    if not url:match('^https?://') or #url > 1024 then return nil end
    return url
end

local formatDigits = select(2, Config.NumberFormat:gsub('[%dX]', ''))

--- Strips everything but digits and re-applies Config.NumberFormat when the
--- digit count matches, so "5551234" and "555 1234" both become "555-1234".
function NormalizeNumber(n)
    local digits = Clean(n, 20):gsub('%D', '')
    if #digits ~= formatDigits then return digits end
    local i = 0
    return (Config.NumberFormat:gsub('[%dX]', function()
        i = i + 1
        return digits:sub(i, i)
    end))
end

local function generateNumber()
    while true do
        local number = Config.NumberFormat:gsub('X', function() return tostring(math.random(0, 9)) end)
        local reserved = Config.Voip and Config.Voip.Reserved and number:match(Config.Voip.Reserved)   -- OPS Hub lines
        local exists = reserved or MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE phone_number = ?', { number })
        if not exists then return number end
    end
end

local function generateEmail(p)
    local fullName = p.name or ''
    local firstRaw, lastRaw = fullName:match('^(%S+)%s+(.+)$')
    local first = (p.firstname or firstRaw or fullName):lower():gsub('[^%a]', '')
    local last = (p.lastname or lastRaw or ''):lower():gsub('[^%a]', '')
    local base = (last ~= '' and (first .. '.' .. last) or first)
    if base == '' then base = 'user' end
    local domain = GetMailDomain()
    local email, i = base .. '@' .. domain, 1
    while MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE email = ?', { email }) do
        i = i + 1
        email = ('%s%d@%s'):format(base, i, domain)
    end
    return email
end

function HasPhoneItem(src)
    if not Config.RequireItem or not FW.HasInventory() then return true, 'black' end   -- no inventory: nothing to require
    for item, color in pairs(Config.Items) do
        if FW.ItemCount(src, item) > 0 then return true, color end
    end
    -- the phone is lying on a wireless charger (server/dock.lua): still yours, still rings
    local docked = DockedPhoneOf and DockedPhoneOf(src)
    if docked then return true, Config.Items[docked.item] or 'black' end
    return false
end

--- Loads (or creates) the phone profile of an online player.
function GetPhone(src)
    src = tonumber(src)
    if not src then return nil end
    if Phones[src] then return Phones[src] end

    local p = FW.Player(src)
    if not p or not p.identifier then return nil end
    AwaitDatabase()

    local identifier = p.identifier
    local row = MySQL.single.await('SELECT * FROM opslabs_phone_users WHERE identifier = ?', { identifier })
    if not row then
        row = {
            identifier = identifier,
            phone_number = generateNumber(),
            email = generateEmail(p),
            settings = '{}',
        }
        MySQL.insert.await('INSERT INTO opslabs_phone_users (identifier, phone_number, email, settings) VALUES (?, ?, ?, ?)',
            { row.identifier, row.phone_number, row.email, row.settings })
        Emit('user.created', { number = row.phone_number, email = row.email, name = p.name })
    elseif not row.email then
        row.email = generateEmail(p)
        MySQL.update.await('UPDATE opslabs_phone_users SET email = ? WHERE identifier = ?', { row.email, identifier })
    end

    MySQL.update('UPDATE opslabs_phone_users SET char_first = ?, char_last = ?, char_job = ? WHERE identifier = ?',
        { p.firstname or p.name, p.lastname or '', p.job and p.job.name or nil, identifier })

    local phone = {
        source = src,
        identifier = identifier,
        number = row.phone_number,
        email = row.email,
        name = (row.display_name and row.display_name ~= '') and row.display_name or p.name,
        setupDone = IsTrue(row.setup_done),
        settings = json.decode(row.settings or '{}') or {},
    }
    Phones[src] = phone
    numberIndex[phone.number] = src
    return phone
end

function GetSourceByNumber(number)
    local src = numberIndex[number]
    if src and Phones[src] and Phones[src].number == number then return src end
    return nil
end

function GetSourceByIdentifier(identifier)
    for src, phone in pairs(Phones) do
        if phone.identifier == identifier then return src end
    end
    return FW.SourceOf(identifier)
end

function Push(src, action, data)
    TriggerClientEvent(PREFIX .. 'push', src, action, data)
end

--- Phone notification: { app, title, body, icon?, data? }
function Notify(src, notif)
    Push(src, 'notify', notif)
end

--- Display name for a number as saved in the owner's contacts.
function ContactName(owner, number)
    return MySQL.scalar.await('SELECT name FROM opslabs_phone_contacts WHERE owner = ? AND number = ? LIMIT 1', { owner, number })
end

function IsBlocked(owner, number)
    return MySQL.scalar.await('SELECT 1 FROM opslabs_phone_contacts WHERE owner = ? AND number = ? AND blocked = 1', { owner, number }) ~= nil
end

--- Registers a server callback callable from the NUI. The handler receives
--- (source, phone, data) and only runs for players with a loaded phone.
function Register(name, handler)
    lib.callback.register(PREFIX .. name, function(src, data)
        local phone = GetPhone(src)
        if not phone then return nil end
        data = type(data) == 'table' and data or {}
        -- OPSHUB license: the phone core and each app's module (server/license.lua)
        local lic = LicenseGate and LicenseGate(src, name)
        if lic then return lic end
        -- at a laptop with no working Ethernet nothing online goes through
        if Laptop and Laptop.Offline(src, name) then return { __carrier = 'data', reason = 'no_ethernet' } end
        -- mobile plan: texts / calls / online apps need service and allowance
        local gate = Carrier and CarrierGates and CarrierGates[name]
        if gate then
            local allowed, why = Carrier.Check(phone, gate, data, src)
            if not allowed then return { __carrier = gate, reason = why } end
        end
        local ok, result = pcall(handler, src, phone, data)
        if not ok then
            print(('^1[opslabs-phone] error in %s: %s^7'):format(name, result))
            return nil
        end
        if gate then pcall(Carrier.AfterAction, phone, name, gate, data, result, src) end
        return result
    end)
end

--- Drops the cached profile so the next access reloads it from the database.
function ReloadPhone(src)
    local phone = Phones[src]
    if phone then numberIndex[phone.number] = nil end
    Phones[src] = nil
    return GetPhone(src)
end

local function unload(src)
    local phone = Phones[src]
    if phone then
        numberIndex[phone.number] = nil
        Phones[src] = nil
    end
    if EndCallFor then EndCallFor(src) end
    if EndLiveSharesFor then EndLiveSharesFor(src) end
end

AddEventHandler('playerDropped', function() unload(source) end)
FW.OnPlayerUnloaded(unload)
FW.OnPlayerLoaded(function(src)
    unload(src)
    CreateThread(function() GetPhone(src) end)
end)

---------------------------------------------------------------------------
-- core
---------------------------------------------------------------------------

lib.callback.register(PREFIX .. 'canOpen', function(src)
    return HasPhoneItem(src)
end)

-- vectors don't survive JSON cleanly; send plain tables to the UI
function placesForUi()
    local list = {}
    for i, p in ipairs(Config.Places) do
        list[i] = { name = p.name, icon = p.icon, coords = { x = p.coords.x, y = p.coords.y, z = p.coords.z } }
    end
    return list
end

--- Everything the UI needs to start (also returned after setup).
function BuildInit(src, phone)
    local _, color = HasPhoneItem(src)
    local unreadMessages = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_messages WHERE receiver = ? AND is_read = 0', { phone.number })
    local addrs = WebMailAddresses and WebMailAddresses(phone) or { phone.email }
    local unreadMail = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_mail WHERE receiver IN (' .. string.rep('?', #addrs, ', ') .. ') AND is_read = 0 AND deleted = 0', addrs)
    local missedCalls = MySQL.scalar.await([[SELECT COUNT(*) FROM opslabs_phone_calls
        WHERE callee = ? AND status = 'missed' AND created_at > NOW() - INTERVAL 1 DAY]], { phone.number })

    if Carrier then Carrier.EnsureStarter(phone.identifier) end
    return {
        brand = GlobalState['ops:brand'],
        carrier = Carrier and Carrier.View(phone.identifier) or nil,
        number = phone.number,
        email = phone.email,
        name = phone.name,
        job = FW.JobLabel(src),
        setupDone = phone.setupDone,
        mailDomain = GetMailDomain(),
        numberFormat = Config.NumberFormat,
        defaultUnits = type(Config.DefaultUnits) == 'table' and Config.DefaultUnits or {},
        settings = phone.settings,
        frameColor = phone.settings.frameColor or Config.FrameColors[color or 'black'] or Config.FrameColors.black,
        badges = { messages = unreadMessages, mail = unreadMail, phone = missedCalls },
        config = {
            wallpapers = GetAllWallpapers and GetAllWallpapers() or Config.Wallpapers,
            ringtones = Config.Ringtones,
            frameColors = Config.FrameColors,
            services = Config.Services,
            places = GetAllPlaces and GetAllPlaces() or placesForUi(),
            cameraEnabled = CameraStorageReady and CameraStorageReady() or false,
            cameraMaxVideo = Config.Camera.MaxVideoSeconds or 60,
            music = Config.Music,
            batteriesWidget = Config.BatteriesWidget ~= false,
            traffic = (Config.Traffic or {}).Enabled ~= false,     -- features switched off in config.lua: the UI hides them
            buds = (Config.Buds or {}).Enabled ~= false,
            safemag = (Config.SafeMag or {}).Enabled ~= false,
            license = LicenseForUi and LicenseForUi(src) or nil,      -- OPSHUB license (server/license.lua)
        },
    }
end

Register('init', function(src, phone) return BuildInit(src, phone) end)

local SETTING_TYPES = {
    wallpaper = 'string', ringtone = 'string', darkMode = 'boolean', airplane = 'boolean',
    dnd = 'boolean', silent = 'boolean', brightness = 'number', volume = 'number',
    passcode = 'string', frameColor = 'string', alarms = 'table', worldClocks = 'table',
    autoLock = 'number', zoom = 'number', faceId = 'boolean',
    reduceTransparency = 'boolean', reduceMotion = 'boolean', perf = 'string',
    language = 'string', region = 'string', units = 'string', clock24 = 'boolean',
    unitTemp = 'string', unitDistance = 'string', unitSpeed = 'string', unitWeight = 'string',
    clockFormat = 'string', dateFormat = 'string', weekStart = 'string', mapStyle = 'string', apps = 'table', homeOrder = 'table',
    batteriesWidget = 'boolean',   -- Settings → Battery: show the Batteries widget
    traffic = 'table',      -- OPS Traffic alert choices: { alerts = bool, accident = bool, closure = bool, … }
    bluetooth = 'boolean',
    buds = 'table',         -- OPS Buds: { paired, name, mode, earDetect, convAware } (server/buds.lua CleanBuds)
    alertsInfo = 'boolean', alertsWarning = 'boolean', alertsSevere = 'boolean',   -- Emergency Alerts: which kinds sound (extreme always does)
}

--- installed-apps map from the Store: only { appId = true/false }
local function cleanApps(v)
    local out, n = {}, 0
    for id, on in pairs(v) do
        if type(id) == 'string' and id:match('^[%w_]+$') and type(on) == 'boolean' and n < 64 then
            out[id] = on
            n = n + 1
        end
    end
    return out
end

--- Merges whitelisted settings into a phone and saves them.
function ApplySettings(phone, data)
    for k, v in pairs(data) do
        if k == 'apps' and type(v) == 'table' then v = cleanApps(v) end
        if k == 'homeOrder' and type(v) == 'table' then
            local list = {}
            for _, id in ipairs(v) do
                if type(id) == 'string' and id:match('^[%w_]+$') and #list < 64 then list[#list + 1] = id end
            end
            v = list
        end
        if k == 'buds' and type(v) == 'table' then v = CleanBuds and CleanBuds(v) or nil end
        if k == 'traffic' and type(v) == 'table' then
            local t = {}
            for key, on in pairs(v) do if type(key) == 'string' and key:match('^%a+$') and #key <= 12 and type(on) == 'boolean' then t[key] = on end end
            v = t
        end
        if SETTING_TYPES[k] and type(v) == SETTING_TYPES[k] then
            if type(v) == 'string' then v = Clean(v, 600) end
            phone.settings[k] = v
        end
    end
    MySQL.update.await('UPDATE opslabs_phone_users SET settings = ? WHERE identifier = ?', { json.encode(phone.settings), phone.identifier })
end

Register('saveSettings', function(_, phone, data)
    ApplySettings(phone, data)
    return true
end)

---------------------------------------------------------------------------
-- contacts
---------------------------------------------------------------------------

Register('getContacts', function(_, phone)
    return MySQL.query.await('SELECT id, name, number, email, avatar, favorite, blocked FROM opslabs_phone_contacts WHERE owner = ? ORDER BY name', { phone.number })
end)

Register('saveContact', function(_, phone, data)
    local name, number = Clean(data.name, 60), NormalizeNumber(data.number)
    if name == '' or number == '' then return false end
    local email = data.email and Clean(data.email, 100) or nil
    local avatar = CleanUrl(data.avatar)
    if data.id then
        MySQL.update.await('UPDATE opslabs_phone_contacts SET name = ?, number = ?, email = ?, avatar = ? WHERE id = ? AND owner = ?',
            { name, number, email, avatar, tonumber(data.id), phone.number })
        return tonumber(data.id)
    end
    return MySQL.insert.await('INSERT INTO opslabs_phone_contacts (owner, name, number, email, avatar) VALUES (?, ?, ?, ?, ?)',
        { phone.number, name, number, email, avatar })
end)

Register('deleteContact', function(_, phone, data)
    MySQL.update.await('DELETE FROM opslabs_phone_contacts WHERE id = ? AND owner = ?', { tonumber(data.id), phone.number })
    return true
end)

Register('toggleFavorite', function(_, phone, data)
    MySQL.update.await('UPDATE opslabs_phone_contacts SET favorite = 1 - favorite WHERE id = ? AND owner = ?', { tonumber(data.id), phone.number })
    return true
end)

Register('toggleBlock', function(_, phone, data)
    local number = NormalizeNumber(data.number)
    local affected = MySQL.update.await('UPDATE opslabs_phone_contacts SET blocked = 1 - blocked WHERE owner = ? AND number = ?', { phone.number, number })
    if affected == 0 then
        MySQL.insert.await('INSERT INTO opslabs_phone_contacts (owner, name, number, blocked) VALUES (?, ?, ?, 1)', { phone.number, number, number })
    end
    return true
end)

-- Share contact with the closest player (OpsDrop)
Register('shareContact', function(src, phone, data)
    local target = tonumber(data.target)
    if not target or not Phones[target] then return false end
    local dist = #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target)))
    if dist > 5.0 then return false end
    Notify(target, {
        app = 'contacts', title = 'OpsDrop', icon = 'fa-address-card',
        body = ('%s shared a contact: %s'):format(phone.name, Clean(data.name, 60)),
        data = { type = 'contact', name = Clean(data.name, 60), number = NormalizeNumber(data.number) },
    })
    return true
end)

---------------------------------------------------------------------------
-- messages
---------------------------------------------------------------------------

Register('getConversations', function(_, phone)
    local rows = MySQL.query.await([[
        SELECT m.*, c.name AS contact_name, c.avatar AS contact_avatar FROM (
            SELECT IF(sender = ?, receiver, sender) AS other, MAX(id) AS last_id
            FROM opslabs_phone_messages WHERE sender = ? OR receiver = ?
            GROUP BY other
        ) t
        JOIN opslabs_phone_messages m ON m.id = t.last_id
        LEFT JOIN opslabs_phone_contacts c ON c.owner = ? AND c.number = t.other
        ORDER BY m.id DESC]], { phone.number, phone.number, phone.number, phone.number })

    local unread = MySQL.query.await('SELECT sender, COUNT(*) AS n FROM opslabs_phone_messages WHERE receiver = ? AND is_read = 0 GROUP BY sender', { phone.number })
    local unreadMap = {}
    for _, u in ipairs(unread) do unreadMap[u.sender] = u.n end

    local list = {}
    for _, r in ipairs(rows) do
        local other = r.sender == phone.number and r.receiver or r.sender
        list[#list + 1] = {
            number = other,
            name = r.contact_name,
            avatar = r.contact_avatar,
            last = r.message,
            attachment = r.attachment and (json.decode(r.attachment) or {}).type or nil,
            time = r.created_at,
            unread = unreadMap[other] or 0,
        }
    end
    return list
end)

Register('getMessages', function(_, phone, data)
    local other = NormalizeNumber(data.number)
    MySQL.update('UPDATE opslabs_phone_messages SET is_read = 1 WHERE sender = ? AND receiver = ? AND is_read = 0', { other, phone.number })
    local rows = MySQL.query.await([[
        SELECT * FROM (
            SELECT id, sender, message, attachment, created_at FROM opslabs_phone_messages
            WHERE (sender = ? AND receiver = ?) OR (sender = ? AND receiver = ?)
            ORDER BY id DESC LIMIT 200
        ) t ORDER BY id ASC]], { phone.number, other, other, phone.number })
    for _, r in ipairs(rows) do
        r.mine = r.sender == phone.number
        r.attachment = r.attachment and json.decode(r.attachment) or nil
        r.sender = nil
    end
    return rows
end)

--- Sends a text message. Usable from other resources through the export.
function SendMessage(fromNumber, toNumber, message, attachment, fromName)
    message = Clean(message, 1000)
    if message == '' and not attachment then return false end
    if IsBlocked(toNumber, fromNumber) then return true end -- silently dropped

    local att = attachment and json.encode(attachment) or nil
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_messages (sender, receiver, message, attachment) VALUES (?, ?, ?, ?)',
        { fromNumber, toNumber, message, att })

    Emit('message.sent', { id = id, from = fromNumber, to = toNumber, message = message, attachment = attachment })

    local target = GetSourceByNumber(toNumber)
    if target then
        local display = ContactName(toNumber, fromNumber) or fromName or fromNumber
        Push(target, 'message', { id = id, number = fromNumber, message = message, attachment = attachment })
        Notify(target, {
            app = 'messages', title = display, icon = 'fa-comment',
            body = message ~= '' and message or (attachment and (attachment.type == 'location' and 'Shared a location' or attachment.type == 'live' and 'Started sharing their live location') or 'Attachment'),
            data = { number = fromNumber },
        })
    end
    return id
end

Register('sendMessage', function(src, phone, data)
    local to = NormalizeNumber(data.number)
    if to == '' or to == phone.number then return false end

    local attachment
    if type(data.attachment) == 'table' then
        if data.attachment.type == 'location' then
            local c = GetEntityCoords(GetPlayerPed(src))
            attachment = { type = 'location', x = c.x, y = c.y, z = c.z }
        elseif data.attachment.type == 'image' then
            local url = CleanUrl(data.attachment.url)
            if url then attachment = { type = 'image', url = url } end
        end
    end

    -- services numbers (911 etc.) turn into a dispatch request
    for _, service in ipairs(Config.Services) do
        if service.number == to then
            CreateServiceRequest(src, phone, service.id, data.message)
        end
    end

    return SendMessage(phone.number, to, data.message, attachment, phone.name)
end)

Register('deleteConversation', function(_, phone, data)
    local other = NormalizeNumber(data.number)
    MySQL.update.await('DELETE FROM opslabs_phone_messages WHERE (sender = ? AND receiver = ?) OR (sender = ? AND receiver = ?)',
        { phone.number, other, other, phone.number })
    return true
end)

---------------------------------------------------------------------------
-- exports for other resources
---------------------------------------------------------------------------

exports('GetPhoneNumber', function(src)
    local phone = GetPhone(src)
    return phone and phone.number
end)

exports('GetSourceByNumber', GetSourceByNumber)

exports('SendMessage', function(fromNumber, toNumber, message)
    return SendMessage(tostring(fromNumber), tostring(toNumber), message)
end)

exports('Notify', function(src, title, body, app, icon)
    Notify(src, { app = app or 'system', title = title, body = body, icon = icon })
end)

exports('SendMail', function(toEmailOrSource, senderName, subject, body)
    return SendMail(toEmailOrSource, senderName, subject, body)
end)

-- When a phone item is used from the inventory, open the phone
CreateThread(function()
    for item in pairs(Config.Items) do
        FW.UsableItem(item, function(src)
            TriggerClientEvent(PREFIX .. 'open', src)
        end)
    end
end)

---------------------------------------------------------------------------
-- stale manifest check
-- `restart` does not re-read fxmanifest.lua; only `refresh` does. If files
-- were added to the manifest since the last refresh they are silently not
-- loaded, so compare what is on disk with what the server actually loaded.
---------------------------------------------------------------------------

CreateThread(function()
    local res = GetCurrentResourceName()
    local manifest = LoadResourceFile(res, 'fxmanifest.lua') or ''
    local loaded = {}
    for _, kind in ipairs({ 'server_script', 'client_script', 'shared_script', 'file' }) do
        for i = 0, GetNumResourceMetadata(res, kind) - 1 do
            loaded[GetResourceMetadata(res, kind, i)] = true
        end
    end
    local missing = {}
    for entry in manifest:gmatch("'([%w_%-%./%*@]+%.[%a%*]+)'") do
        if not entry:find('^@') and not loaded[entry] then missing[#missing + 1] = entry end
    end
    if #missing > 0 then
        local line = '^1' .. ('='):rep(70)
        print(line)
        print('^1[opslabs-phone] fxmanifest.lua changed but the server is still using the old file list.^7')
        print('^1[opslabs-phone] Not loaded: ' .. table.concat(missing, ', ') .. '^7')
        print('^1[opslabs-phone] Run these in the server console:  refresh   then   restart opslabs-phone^7')
        print(line .. '^7')
    end
end)
