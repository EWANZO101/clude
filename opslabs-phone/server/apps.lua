---------------------------------------------------------------------------
-- Notes
---------------------------------------------------------------------------

Register('getNotes', function(_, phone)
    return MySQL.query.await('SELECT id, title, body, updated_at FROM opslabs_phone_notes WHERE owner = ? ORDER BY updated_at DESC', { phone.identifier })
end)

Register('saveNote', function(_, phone, data)
    local title, body = Clean(data.title, 120), tostring(data.body or ''):sub(1, 20000)
    if data.id then
        MySQL.update.await('UPDATE opslabs_phone_notes SET title = ?, body = ? WHERE id = ? AND owner = ?', { title, body, tonumber(data.id), phone.identifier })
        return tonumber(data.id)
    end
    return MySQL.insert.await('INSERT INTO opslabs_phone_notes (owner, title, body) VALUES (?, ?, ?)', { phone.identifier, title, body })
end)

Register('deleteNote', function(_, phone, data)
    MySQL.update.await('DELETE FROM opslabs_phone_notes WHERE id = ? AND owner = ?', { tonumber(data.id), phone.identifier })
    return true
end)

---------------------------------------------------------------------------
-- Photos
---------------------------------------------------------------------------

Register('getPhotos', function(_, phone)
    return MySQL.query.await('SELECT id, url, favorite, created_at FROM opslabs_phone_photos WHERE owner = ? ORDER BY id DESC', { phone.identifier })
end)

Register('savePhoto', function(_, phone, data)
    local url = CleanUrl(data.url)
    if not url then return false end
    return MySQL.insert.await('INSERT INTO opslabs_phone_photos (owner, url) VALUES (?, ?)', { phone.identifier, url })
end)

Register('deletePhoto', function(_, phone, data)
    local url = MySQL.scalar.await('SELECT url FROM opslabs_phone_photos WHERE id = ? AND owner = ?', { tonumber(data.id), phone.identifier })
    MySQL.update.await('DELETE FROM opslabs_phone_photos WHERE id = ? AND owner = ?', { tonumber(data.id), phone.identifier })
    -- remove the file too, unless it's still used elsewhere (another library, a message, a Chirp post)
    local file = url and MediaFileFromUrl and MediaFileFromUrl(url)
    if file and MySQL.scalar.await([[SELECT (SELECT COUNT(*) FROM opslabs_phone_photos WHERE url = ?)
            + (SELECT COUNT(*) FROM opslabs_phone_messages WHERE attachment LIKE ?)
            + (SELECT COUNT(*) FROM opslabs_phone_chirp_posts WHERE image = ?)
            + (SELECT COUNT(*) FROM opslabs_phone_users WHERE settings LIKE ?)]], { url, '%' .. file .. '%', url, '%' .. file .. '%' }) == 0 then
        exports[GetCurrentResourceName()]:DeleteMedia(file)
    end
    return true
end)

Register('favoritePhoto', function(_, phone, data)
    MySQL.update.await('UPDATE opslabs_phone_photos SET favorite = 1 - favorite WHERE id = ? AND owner = ?', { tonumber(data.id), phone.identifier })
    return true
end)

---------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------

--- toEmailOrSource: an email address or a player server id.
function SendMail(toEmailOrSource, senderName, subject, body, senderEmail)
    local to = toEmailOrSource
    if type(to) == 'number' then
        local phone = GetPhone(to)
        if not phone then return false end
        to = phone.email
    end
    to = Clean(to, 100):lower()
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_mail (sender, sender_name, receiver, subject, body) VALUES (?, ?, ?, ?, ?)',
        { senderEmail or 'noreply@' .. GetMailDomain(), Clean(senderName, 100), to, Clean(subject, 160), tostring(body or ''):sub(1, 10000) })

    Emit('mail.sent', { id = id, from = senderEmail, from_name = senderName, to = to, subject = subject })

    local owner = WebMailOwner and WebMailOwner(to)       -- an address on a player's own domain (server/web.lua)
    for src, phone in pairs(Phones) do
        if phone.email == to or (owner and phone.number == owner) then
            Push(src, 'mail', { id = id })
            Notify(src, { app = 'mail', title = Clean(senderName, 100), body = Clean(subject, 160), icon = 'fa-envelope' })
        end
    end
    return id
end

--- the phone's own address plus any mailboxes on its owner's domains: WHERE fragment + values
local function mailWhere(phone, col)
    local list, catch = { phone.email }, {}
    if WebMailAddresses then list, catch = WebMailAddresses(phone) end
    local parts, vals = { col .. ' IN (' .. string.rep('?', #list, ', ') .. ')' }, {}
    for _, a in ipairs(list) do vals[#vals + 1] = a end
    for _, dom in ipairs(catch) do parts[#parts + 1] = col .. ' LIKE ?' vals[#vals + 1] = '%@' .. dom end
    return '(' .. table.concat(parts, ' OR ') .. ')', vals, list
end

Register('getMail', function(_, phone, data)
    if data.box == 'sent' then
        local w, vals = mailWhere(phone, 'sender')
        return MySQL.query.await('SELECT id, sender, sender_name, receiver, subject, body, 1 AS is_read, created_at FROM opslabs_phone_mail WHERE ' .. w .. ' ORDER BY id DESC LIMIT 100', vals)
    end
    local w, vals = mailWhere(phone, 'receiver')
    return MySQL.query.await('SELECT id, sender, sender_name, receiver, subject, body, is_read, created_at FROM opslabs_phone_mail WHERE ' .. w .. ' AND deleted = 0 ORDER BY id DESC LIMIT 100', vals)
end)

Register('readMail', function(_, phone, data)
    local w, vals = mailWhere(phone, 'receiver')
    table.insert(vals, 1, tonumber(data.id))
    MySQL.update('UPDATE opslabs_phone_mail SET is_read = 1 WHERE id = ? AND ' .. w, vals)
    return true
end)

Register('deleteMail', function(_, phone, data)
    local w, vals = mailWhere(phone, 'receiver')
    table.insert(vals, 1, tonumber(data.id))
    MySQL.update.await('UPDATE opslabs_phone_mail SET deleted = 1 WHERE id = ? AND ' .. w, vals)
    return true
end)

--- addresses this phone can send from (its own + mailboxes on its domains)
Register('mailFrom', function(_, phone)
    local _, _, list = mailWhere(phone, 'sender')
    return list
end)

Register('sendMail', function(_, phone, data)
    local to = Clean(data.to, 100):lower()
    if not to:match('^[%w%._%-+]+@[%w%._%-]+$') then return false end
    local from = phone.email
    if data.from and data.from ~= phone.email then
        local _, _, list = mailWhere(phone, 'sender')
        for _, a in ipairs(list) do if a == Clean(data.from, 100):lower() then from = a end end
    end
    if WebDeliverable then
        local ok, why = WebDeliverable(to)
        if not ok then
            -- it leaves the outbox like real mail, then bounces back
            MySQL.insert.await('INSERT INTO opslabs_phone_mail (sender, sender_name, receiver, subject, body, deleted) VALUES (?, ?, ?, ?, ?, 1)',
                { from, Clean(phone.name, 100), to, Clean(data.subject, 160), tostring(data.body or ''):sub(1, 10000) })
            WebBounce(phone.email, to, data.subject, why)
            return true
        end
    end
    return SendMail(to, phone.name, data.subject, data.body, from) and true
end)

---------------------------------------------------------------------------
-- Chirp (social feed)
---------------------------------------------------------------------------

local function getProfile(phone)
    local profile = MySQL.single.await('SELECT * FROM opslabs_phone_chirp_profiles WHERE identifier = ?', { phone.identifier })
    if profile then return profile end

    local base = phone.name:lower():gsub('[^%w]', '')
    if base == '' then base = 'user' end
    local handle, i = base:sub(1, 24), 1
    while MySQL.scalar.await('SELECT 1 FROM opslabs_phone_chirp_profiles WHERE handle = ?', { handle }) do
        i = i + 1
        handle = base:sub(1, 22) .. i
    end
    MySQL.insert.await('INSERT INTO opslabs_phone_chirp_profiles (identifier, handle, display_name) VALUES (?, ?, ?)', { phone.identifier, handle, phone.name })
    return { identifier = phone.identifier, handle = handle, display_name = phone.name }
end

Register('chirpProfile', function(_, phone)
    local p = getProfile(phone)
    p.identifier = nil
    return p
end)

Register('chirpUpdateProfile', function(_, phone, data)
    getProfile(phone)
    local handle = Clean(data.handle, 30):gsub('[^%w_]', '')
    if #handle < 3 then return { error = 'Handle must be at least 3 characters' } end
    local taken = MySQL.scalar.await('SELECT 1 FROM opslabs_phone_chirp_profiles WHERE handle = ? AND identifier <> ?', { handle, phone.identifier })
    if taken then return { error = 'That handle is taken' } end
    MySQL.update.await('UPDATE opslabs_phone_chirp_profiles SET handle = ?, display_name = ?, avatar = ?, bio = ? WHERE identifier = ?',
        { handle, Clean(data.display_name, 60), CleanUrl(data.avatar), Clean(data.bio, 200), phone.identifier })
    return { ok = true }
end)

Register('chirpFeed', function(_, phone, data)
    local rows = MySQL.query.await([[
        SELECT p.id, p.content, p.image, p.created_at, pr.handle, pr.display_name, pr.avatar,
            (SELECT COUNT(*) FROM opslabs_phone_chirp_likes l WHERE l.post_id = p.id) AS likes,
            (SELECT COUNT(*) FROM opslabs_phone_chirp_posts r WHERE r.reply_to = p.id) AS replies,
            EXISTS(SELECT 1 FROM opslabs_phone_chirp_likes l WHERE l.post_id = p.id AND l.identifier = ?) AS liked,
            p.author = ? AS mine
        FROM opslabs_phone_chirp_posts p
        JOIN opslabs_phone_chirp_profiles pr ON pr.identifier = p.author
        WHERE ]] .. (data.replyTo and 'p.reply_to = ?' or 'p.reply_to IS NULL') .. [[
        ORDER BY p.id DESC LIMIT 60]],
        data.replyTo and { phone.identifier, phone.identifier, tonumber(data.replyTo) } or { phone.identifier, phone.identifier })
    return rows
end)

Register('chirpPost', function(_, phone, data)
    local profile = getProfile(phone)
    local content = Clean(data.content, 280)
    if content == '' then return false end
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_chirp_posts (author, content, image, reply_to) VALUES (?, ?, ?, ?)',
        { phone.identifier, content, CleanUrl(data.image), tonumber(data.replyTo) })

    Emit('chirp.posted', { id = id, handle = profile.handle, content = content, reply_to = tonumber(data.replyTo) })

    if not data.replyTo then
        for src in pairs(Phones) do
            if src ~= phone.source then
                Notify(src, { app = 'chirp', title = profile.display_name .. ' (@' .. profile.handle .. ')', body = content, icon = 'fa-feather' })
            end
        end
    end
    return id
end)

Register('chirpLike', function(_, phone, data)
    local id = tonumber(data.id)
    local removed = MySQL.update.await('DELETE FROM opslabs_phone_chirp_likes WHERE post_id = ? AND identifier = ?', { id, phone.identifier })
    if removed == 0 then
        MySQL.insert.await('INSERT IGNORE INTO opslabs_phone_chirp_likes (post_id, identifier) VALUES (?, ?)', { id, phone.identifier })
    end
    return removed == 0
end)

Register('chirpDelete', function(_, phone, data)
    local id = tonumber(data.id)
    local deleted = MySQL.update.await('DELETE FROM opslabs_phone_chirp_posts WHERE id = ? AND author = ?', { id, phone.identifier })
    if deleted > 0 then
        MySQL.update('DELETE FROM opslabs_phone_chirp_likes WHERE post_id = ?', { id })
    end
    return deleted > 0
end)

---------------------------------------------------------------------------
-- Wallet / Bank
---------------------------------------------------------------------------

local lastTransfer = {}

local function logTx(identifier, label, amount)
    MySQL.insert('INSERT INTO opslabs_phone_bank_transactions (identifier, label, amount) VALUES (?, ?, ?)', { identifier, label, amount })
end

Register('getBank', function(src, phone)
    local tx = MySQL.query.await('SELECT label, amount, created_at FROM opslabs_phone_bank_transactions WHERE identifier = ? ORDER BY id DESC LIMIT 50', { phone.identifier })
    local bills = MySQL.query.await('SELECT id, label, amount, target FROM billing WHERE identifier = ? ORDER BY id DESC', { phone.identifier })
    return {
        name = phone.name,
        balance = FW.GetMoney(src, Config.Bank.Account),
        cash = FW.GetMoney(src, 'cash'),
        transactions = tx,
        bills = bills or {},
    }
end)

Register('transfer', function(src, phone, data)
    local amount = math.floor(tonumber(data.amount) or 0)
    if amount < 1 or amount > Config.Bank.MaxTransfer then return { error = 'Invalid amount' } end
    if lastTransfer[src] and os.time() - lastTransfer[src] < Config.Bank.TransferCooldown then return { error = 'Please wait a moment' } end

    local number = NormalizeNumber(data.number)
    local identifier = MySQL.scalar.await('SELECT identifier FROM opslabs_phone_users WHERE phone_number = ?', { number })
    if not identifier then return { error = 'No account linked to this number' } end
    if identifier == phone.identifier then return { error = "You can't send money to yourself" } end

    if FW.GetMoney(src, Config.Bank.Account) < amount then return { error = 'Insufficient funds' } end

    local note = Clean(data.note, 60)
    local targetSrc = GetSourceByIdentifier(identifier)

    if targetSrc then
        if not FW.RemoveMoney(src, amount, Config.Bank.Account, 'Phone transfer') then return { error = 'Insufficient funds' } end
        FW.AddMoney(targetSrc, amount, Config.Bank.Account, 'Phone transfer')
        Notify(targetSrc, { app = 'wallet', title = 'Money received', icon = 'fa-money-bill-transfer',
            body = ('%s sent you $%s%s'):format(phone.name, amount, note ~= '' and (' — ' .. note) or '') })
    else
        -- offline recipient: credit the stored accounts JSON directly
        local accountsJson = MySQL.scalar.await('SELECT accounts FROM users WHERE identifier = ?', { identifier })
        local accounts = accountsJson and json.decode(accountsJson)
        if not accounts then return { error = 'Recipient account unavailable' } end
        if not FW.RemoveMoney(src, amount, Config.Bank.Account, 'Phone transfer') then return { error = 'Insufficient funds' } end
        accounts[Config.Bank.Account] = (accounts[Config.Bank.Account] or 0) + amount
        MySQL.update.await('UPDATE users SET accounts = ? WHERE identifier = ?', { json.encode(accounts), identifier })
    end

    lastTransfer[src] = os.time()
    Emit('bank.transfer', { from = phone.number, to = number, amount = amount, note = note })
    logTx(phone.identifier, 'Transfer to ' .. number .. (note ~= '' and (' — ' .. note) or ''), -amount)
    logTx(identifier, 'Transfer from ' .. phone.number .. (note ~= '' and (' — ' .. note) or ''), amount)
    return { ok = true }
end)

Register('payBill', function(src, phone, data)
    local bill = MySQL.single.await('SELECT * FROM billing WHERE id = ? AND identifier = ?', { tonumber(data.id), phone.identifier })
    if not bill then return { error = 'Bill not found' } end
    if FW.GetMoney(src, Config.Bank.Account) < bill.amount then return { error = 'Insufficient funds' } end

    local deleted = MySQL.update.await('DELETE FROM billing WHERE id = ?', { bill.id })
    if deleted == 0 then return { error = 'Bill already paid' } end
    if not FW.RemoveMoney(src, bill.amount, Config.Bank.Account, 'Bill payment') then
        MySQL.insert.await('INSERT INTO billing (id, identifier, sender, target_type, target, label, amount) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { bill.id, bill.identifier, bill.sender, bill.target_type, bill.target, bill.label, bill.amount })   -- put the bill back
        return { error = 'Insufficient funds' }
    end

    if bill.target_type == 'society' then
        TriggerEvent('esx_addonaccount:getSharedAccount', bill.target, function(account)
            if account then account.addMoney(bill.amount) end
        end)
    else
        local senderSrc = FW.SourceOf(bill.sender)
        if senderSrc then FW.AddMoney(senderSrc, bill.amount, Config.Bank.Account, 'Bill paid') end
    end
    logTx(phone.identifier, 'Bill: ' .. bill.label, -bill.amount)
    return { ok = true }
end)

---------------------------------------------------------------------------
-- Garage
---------------------------------------------------------------------------

Register('getVehicles', function(_, phone)
    local rows = MySQL.query.await('SELECT `plate`, `vehicle`, `type`, `stored`, `parking`, `pound`, `custom_name`, `mileage` FROM owned_vehicles WHERE `owner` = ?', { phone.identifier })
    local list = {}
    for _, r in ipairs(rows or {}) do
        local props = r.vehicle and json.decode(r.vehicle) or {}
        list[#list + 1] = {
            plate = r.plate, model = props.model, type = r.type, name = r.custom_name,
            stored = IsTrue(r.stored), parking = r.parking, pound = r.pound, mileage = r.mileage,
            fuel = props.fuelLevel, engine = props.engineHealth, body = props.bodyHealth,
        }
    end
    return list
end)

---------------------------------------------------------------------------
-- Services / dispatch
---------------------------------------------------------------------------

local function serviceById(id)
    for _, s in ipairs(Config.Services) do if s.id == id then return s end end
end

local function isServiceMember(src, service)
    local job = FW.Job(src)
    if not job then return false end
    for _, j in ipairs(service.jobs) do if j == job then return true end end
    return false
end

local lastRequest = {}

function CreateServiceRequest(src, phone, serviceId, message)
    local service = serviceById(serviceId)
    if not service then return false end
    if lastRequest[src] and os.time() - lastRequest[src] < 30 then return false end
    lastRequest[src] = os.time()

    local c = GetEntityCoords(GetPlayerPed(src))
    message = Clean(message, 400)
    if message == '' then message = 'Assistance requested' end
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_service_requests (service, caller_number, caller_name, message, x, y, z) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { service.id, phone.number, phone.name, message, c.x, c.y, c.z })

    Emit('service.request', { id = id, service = service.id, number = phone.number, name = phone.name, message = message, x = c.x, y = c.y, z = c.z })

    for target in pairs(Phones) do
        if isServiceMember(target, service) then
            Notify(target, {
                app = 'services', title = service.label .. ' — ' .. phone.name, body = message, icon = service.icon,
                data = { type = 'gps', x = c.x, y = c.y },
            })
            Push(target, 'serviceRequest', { id = id })
        end
    end
    return id
end

Register('serviceRequest', function(src, phone, data)
    return CreateServiceRequest(src, phone, data.service, data.message) and true or false
end)

Register('getServiceRequests', function(src)
    local mine = {}
    for _, s in ipairs(Config.Services) do
        if isServiceMember(src, s) then mine[#mine + 1] = s.id end
    end
    if #mine == 0 then return { member = false } end
    local rows = MySQL.query.await([[SELECT * FROM opslabs_phone_service_requests
        WHERE service IN (?) AND created_at > NOW() - INTERVAL 1 DAY ORDER BY id DESC LIMIT 50]], { mine })
    return { member = true, requests = rows }
end)

Register('handleServiceRequest', function(src, phone, data)
    local req = MySQL.single.await('SELECT * FROM opslabs_phone_service_requests WHERE id = ?', { tonumber(data.id) })
    if not req then return false end
    local service = serviceById(req.service)
    if not service or not isServiceMember(src, service) then return false end
    local status = data.status == 'closed' and 'closed' or 'accepted'
    MySQL.update.await('UPDATE opslabs_phone_service_requests SET status = ?, handled_by = ? WHERE id = ?', { status, phone.name, req.id })
    if status == 'accepted' then
        SendMessage(service.number, req.caller_number, ('%s: %s is responding to your request.'):format(service.label, phone.name))
    end
    return true
end)

---------------------------------------------------------------------------
-- Nearby players (OpsDrop)
---------------------------------------------------------------------------

Register('nearbyPlayers', function(src)
    local coords = GetEntityCoords(GetPlayerPed(src))
    local list = {}
    for target, phone in pairs(Phones) do
        if target ~= src and #(coords - GetEntityCoords(GetPlayerPed(target))) <= 5.0 then
            list[#list + 1] = { id = target, name = phone.name }
        end
    end
    return list
end)

---------------------------------------------------------------------------
-- Music (Soundwave / Tide)
---------------------------------------------------------------------------

local function musicApp(app)
    app = tostring(app or '')
    return Config.Music.Apps[app] and app or nil
end

Register('musicLibrary', function(_, phone, data)
    local app = musicApp(data.app)
    if not app then return {} end
    local rows = MySQL.query.await('SELECT id, title, artist, url, art, kind, playlist, liked, created_at FROM opslabs_phone_music WHERE owner = ? AND app = ? ORDER BY id DESC LIMIT 500', { phone.identifier, app }) or {}
    for _, r in ipairs(rows) do r.liked = IsTrue(r.liked) end
    return rows
end)

Register('musicAdd', function(_, phone, data)
    local app = musicApp(data.app)
    local url = CleanUrl(data.url)
    if not app or not url then return { error = 'Paste a valid https link' } end
    local title = Clean(data.title, 120)
    if title == '' then title = 'Untitled' end
    local kind = data.kind == 'youtube' and 'youtube' or data.kind == 'radio' and 'radio' or 'track'
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM opslabs_phone_music WHERE owner = ? AND app = ?', { phone.identifier, app })
    if count >= 500 then return { error = 'Your library is full (500 songs)' } end
    local playlist = Clean(data.playlist, 60)
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_music (owner, app, title, artist, url, art, kind, playlist) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { phone.identifier, app, title, Clean(data.artist, 120), url, CleanUrl(data.art), kind, playlist ~= '' and playlist or nil })
    return { ok = true, id = id }
end)

Register('musicUpdate', function(_, phone, data)
    local id = tonumber(data.id)
    if not id then return false end
    if data.liked ~= nil then
        MySQL.update.await('UPDATE opslabs_phone_music SET liked = ? WHERE id = ? AND owner = ?', { data.liked and 1 or 0, id, phone.identifier })
    end
    if data.playlist ~= nil then
        local pl = Clean(data.playlist, 60)
        MySQL.update.await('UPDATE opslabs_phone_music SET playlist = ? WHERE id = ? AND owner = ?', { pl ~= '' and pl or nil, id, phone.identifier })
    end
    if data.title then
        MySQL.update.await('UPDATE opslabs_phone_music SET title = ? WHERE id = ? AND owner = ? AND title = ?', { Clean(data.title, 120), id, phone.identifier, 'Untitled' })
    end
    return true
end)

Register('musicDelete', function(_, phone, data)
    MySQL.update.await('DELETE FROM opslabs_phone_music WHERE id = ? AND owner = ?', { tonumber(data.id), phone.identifier })
    return true
end)
