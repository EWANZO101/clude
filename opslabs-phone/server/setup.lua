-- First-run setup (the "Hello" flow): name, phone number, email address,
-- language/region, passcode, appearance and performance preset.

-- Lua pattern for a valid number, built from Config.NumberFormat ("555-XXXX" -> "^555%-%d%d%d%d$")
local numberPattern = '^' .. Config.NumberFormat:gsub('%p', '%%%0'):gsub('X', '%%d') .. '$'

function IsValidNumber(n)
    return type(n) == 'string' and n:match(numberPattern) ~= nil
end

local function numberTaken(number, identifier)
    return MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE phone_number = ? AND identifier <> ?', { number, identifier }) ~= nil
end

local function emailTaken(email, identifier)
    return MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE email = ? AND identifier <> ?', { email, identifier }) ~= nil
end

local function cleanEmailUser(u)
    u = tostring(u or ''):lower():gsub('%s', '')
    u = u:match('^([^@]*)') or ''   -- "name@opslabs.cloud" -> "name"
    if not u:match('^[a-z0-9][a-z0-9%._%-]+$') or #u < 3 or #u > 30 then return nil end
    return u
end

local function checkNumber(phone, raw)
    local number = NormalizeNumber(raw)
    if not IsValidNumber(number) then
        return nil, ('Use the format %s'):format(Config.NumberFormat:gsub('X', '0'))
    end
    if number ~= phone.number and numberTaken(number, phone.identifier) then return nil, 'That number is taken' end
    return number
end

local function checkEmail(phone, rawUser)
    local user = cleanEmailUser(rawUser)
    if not user then return nil, '3–30 letters, numbers, dots, dashes or underscores' end
    local email = user .. '@' .. GetMailDomain()
    if email ~= phone.email and emailTaken(email, phone.identifier) then return nil, 'That address is taken' end
    return email
end

local function randomNumbers(count)
    local out, tries = {}, 0
    while #out < count and tries < 50 do
        tries = tries + 1
        local n = Config.NumberFormat:gsub('X', function() return tostring(math.random(0, 9)) end)
        if not numberTaken(n, '') then out[#out + 1] = n end
    end
    return out
end

local TAKEN_LIMIT = 20000

Register('setupInfo', function(_, phone)
    local suggestedUser = phone.email and phone.email:match('^([^@]+)@') or phone.name:lower():gsub('[^%w]+', '.')
    -- numbers / OPS IDs already in use, so the phone can check availability
    -- instantly while typing (completeSetup still re-checks on the server)
    local rows = MySQL.query.await('SELECT phone_number, email FROM opslabs_phone_users WHERE identifier <> ? LIMIT ?', { phone.identifier, TAKEN_LIMIT }) or {}
    local takenNumbers, takenEmails = {}, {}
    local domain = '@' .. GetMailDomain()
    for i, r in ipairs(rows) do
        takenNumbers[i] = r.phone_number
        if r.email and r.email:sub(-#domain) == domain then takenEmails[#takenEmails + 1] = r.email:sub(1, -#domain - 1) end
    end
    return {
        takenNumbers = takenNumbers,
        takenEmails = takenEmails,
        takenComplete = #rows < TAKEN_LIMIT,
        name = phone.name,
        number = phone.number,
        email = phone.email,
        emailUser = suggestedUser,
        domain = GetMailDomain(),
        numberFormat = Config.NumberFormat,
        suggestions = randomNumbers(3),
    }
end)

Register('setupCheck', function(_, phone, data)
    local res = {}
    if data.number then
        local ok, err = checkNumber(phone, data.number)
        res.number = { ok = ok ~= nil, value = ok, error = err }
    end
    if data.emailUser then
        local ok, err = checkEmail(phone, data.emailUser)
        res.email = { ok = ok ~= nil, value = ok, error = err }
    end
    return res
end)

Register('completeSetup', function(src, phone, data)
    local started = os.clock()
    local function fail(msg, field)
        print(('^3[opslabs-phone] setup for %s not saved: %s^7'):format(phone.identifier, msg))
        return { error = msg, field = field }
    end
    local name = Clean(data.name, 60)
    if #name < 2 then return fail('Please enter your name', 'name') end
    local number, nErr = checkNumber(phone, (data.number and data.number ~= '') and data.number or phone.number)
    if not number then return fail(nErr, 'number') end
    local email, eErr = checkEmail(phone, data.emailUser)
    if not email then return fail(eErr, 'email') end

    -- number/email changes migrate history through the shared update path
    if number ~= phone.number or email ~= phone.email then
        local user = MySQL.single.await('SELECT identifier, phone_number, email, settings FROM opslabs_phone_users WHERE identifier = ?', { phone.identifier })
        local result, _, message = ApplyPhoneUpdate(user, { number = number, email = email }, { silent = true })
        if not result then return fail(message) end
    end

    MySQL.update.await('UPDATE opslabs_phone_users SET display_name = ?, setup_done = 1 WHERE identifier = ?', { name, phone.identifier })
    ReloadPhone(src)
    local fresh = GetPhone(src)
    if type(data.settings) == 'table' then ApplySettings(fresh, data.settings) end

    Emit('user.setup', { number = fresh.number, email = fresh.email, name = fresh.name })
    local init = BuildInit(src, fresh)
    print(('^2[opslabs-phone]^7 setup complete for %s (%s, %s) in %d ms'):format(fresh.name, fresh.number, fresh.email, math.floor((os.clock() - started) * 1000)))
    return { ok = true, init = init }
end)

-- change OPS ID / display name later from Settings
Register('changeOpsId', function(src, phone, data)
    local email, err = checkEmail(phone, data.emailUser)
    if not email then return { error = err } end
    if email ~= phone.email then
        local user = MySQL.single.await('SELECT identifier, phone_number, email, settings FROM opslabs_phone_users WHERE identifier = ?', { phone.identifier })
        local result, _, message = ApplyPhoneUpdate(user, { email = email }, { silent = true })
        if not result then return { error = message } end
    end
    return { ok = true, email = email }
end)

Register('changeName', function(src, phone, data)
    local name = Clean(data.name, 60)
    if #name < 2 then return { error = 'Please enter your name' } end
    MySQL.update.await('UPDATE opslabs_phone_users SET display_name = ? WHERE identifier = ?', { name, phone.identifier })
    ReloadPhone(src)
    return { ok = true, name = name }
end)
