-- Sparks (dating): a profile per character, a deck of people who fit what you're looking for, like / pass, a match
-- when it's mutual, then private chat. Unmatch and report at any time; reported / unmatched people never show again.
-- Config.Dating. Profiles are only for characters aged MinAge or over.

local CD = Config.Dating or {}
if CD.Enabled == false then return end
local MIN_AGE = math.max(18, tonumber(CD.MinAge) or 18)
local GENDERS = { man = true, woman = true, nonbinary = true }
local SEEKING = { men = true, women = true, everyone = true }

local function now() return os.time() end

CreateThread(function()
    while not DatabaseReady do Wait(100) end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_dating_profiles` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `identifier` VARCHAR(60) NOT NULL,
        `name` VARCHAR(40) NOT NULL,
        `age` INT NOT NULL,
        `gender` VARCHAR(12) NOT NULL DEFAULT 'man',
        `seeking` VARCHAR(12) NOT NULL DEFAULT 'everyone',
        `bio` VARCHAR(500) NULL,
        `job` VARCHAR(60) NULL,
        `area` VARCHAR(60) NULL,
        `photos` TEXT NULL,
        `interests` TEXT NULL,
        `active` TINYINT(1) NOT NULL DEFAULT 1,
        `created_at` INT NOT NULL,
        `updated_at` INT NOT NULL,
        PRIMARY KEY (`id`), UNIQUE KEY `identifier` (`identifier`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_dating_swipes` (
        `from_id` INT NOT NULL, `to_id` INT NOT NULL, `liked` TINYINT(1) NOT NULL, `at` INT NOT NULL,
        PRIMARY KEY (`from_id`, `to_id`), KEY `to_id` (`to_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_dating_matches` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `a` INT NOT NULL, `b` INT NOT NULL,
        `a_read` INT NOT NULL DEFAULT 0, `b_read` INT NOT NULL DEFAULT 0,
        `ended` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` INT NOT NULL, `last_at` INT NOT NULL,
        PRIMARY KEY (`id`), UNIQUE KEY `pair` (`a`, `b`), KEY `b` (`b`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_dating_messages` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `match_id` INT NOT NULL, `sender` INT NOT NULL, `body` VARCHAR(1000) NOT NULL, `at` INT NOT NULL,
        PRIMARY KEY (`id`), KEY `match_id` (`match_id`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `opslabs_phone_dating_reports` (
        `id` INT NOT NULL AUTO_INCREMENT, `reporter` INT NOT NULL, `target` INT NOT NULL, `reason` VARCHAR(300) NULL, `at` INT NOT NULL,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end
local function mine(phone) return MySQL.single.await('SELECT * FROM opslabs_phone_dating_profiles WHERE identifier = ?', { phone.identifier }) end

local function card(p)
    return { id = p.id, name = p.name, age = p.age, gender = p.gender, bio = p.bio, job = p.job, area = p.area,
        photos = decode(p.photos, {}), interests = decode(p.interests, {}) }
end

--- does a (gender) suit what b is seeking
local function suits(gender, seeking)
    return seeking == 'everyone' or (seeking == 'men' and gender == 'man') or (seeking == 'women' and gender == 'woman')
end

local function notifyProfile(profileId, notif)
    local ident = MySQL.scalar.await('SELECT identifier FROM opslabs_phone_dating_profiles WHERE id = ?', { profileId })
    local src = ident and GetSourceByIdentifier(ident)
    if src then Notify(src, notif) Push(src, 'datingChanged') end
end

local function matchFor(me, matchId)
    local m = MySQL.single.await('SELECT * FROM opslabs_phone_dating_matches WHERE id = ? AND (a = ? OR b = ?)', { tonumber(matchId) or 0, me.id, me.id })
    return m
end

---------------------------------------------------------------------------
-- profile
---------------------------------------------------------------------------
Register('datingProfile', function(_, phone)
    local p = mine(phone)
    return { profile = p and card(p) or nil, seeking = p and p.seeking or nil, active = p and p.active == 1 or nil, minAge = MIN_AGE, maxPhotos = CD.MaxPhotos or 4, suggestedName = phone.name }
end)

Register('datingSave', function(_, phone, d)
    local name = Clean(d.name or '', 40)
    local age = math.floor(tonumber(d.age) or 0)
    if name == '' then return { error = 'Add your name' } end
    if age < MIN_AGE or age > 99 then return { error = ('Sparks is for ages %d and over'):format(MIN_AGE) } end
    local gender = GENDERS[d.gender] and d.gender or 'man'
    local seeking = SEEKING[d.seeking] and d.seeking or 'everyone'
    local photos = {}
    for _, u in ipairs(type(d.photos) == 'table' and d.photos or {}) do
        local c = CleanUrl(u)
        if c and #photos < (CD.MaxPhotos or 4) then photos[#photos + 1] = c end
    end
    local interests = {}
    for _, t in ipairs(type(d.interests) == 'table' and d.interests or {}) do
        local c = Clean(tostring(t), 20)
        if c ~= '' and #interests < 8 then interests[#interests + 1] = c end
    end
    local t = now()
    MySQL.query.await([[INSERT INTO opslabs_phone_dating_profiles (identifier, name, age, gender, seeking, bio, job, area, photos, interests, active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), age = VALUES(age), gender = VALUES(gender), seeking = VALUES(seeking),
        bio = VALUES(bio), job = VALUES(job), area = VALUES(area), photos = VALUES(photos), interests = VALUES(interests), active = VALUES(active), updated_at = VALUES(updated_at)]],
        { phone.identifier, name, age, gender, seeking, d.bio and Clean(d.bio, 500) or nil, d.job and Clean(d.job, 60) or nil, d.area and Clean(d.area, 60) or nil,
          json.encode(photos), json.encode(interests), d.active == false and 0 or 1, t, t })
    return { ok = true }
end)

---------------------------------------------------------------------------
-- the deck and swiping
---------------------------------------------------------------------------
Register('datingDeck', function(_, phone)
    local me = mine(phone)
    if not me then return { needProfile = true } end
    local rows = MySQL.query.await([[SELECT p.* FROM opslabs_phone_dating_profiles p
        WHERE p.active = 1 AND p.id <> ? AND p.age >= ?
          AND NOT EXISTS (SELECT 1 FROM opslabs_phone_dating_swipes s WHERE s.from_id = ? AND s.to_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM opslabs_phone_dating_reports r WHERE (r.reporter = ? AND r.target = p.id) OR (r.reporter = p.id AND r.target = ?))
          AND NOT EXISTS (SELECT 1 FROM opslabs_phone_dating_swipes s2 WHERE s2.from_id = p.id AND s2.to_id = ? AND s2.liked = 0)
        ORDER BY (SELECT COUNT(*) FROM opslabs_phone_dating_swipes s3 WHERE s3.from_id = p.id AND s3.to_id = ? AND s3.liked = 1) DESC, RAND() LIMIT 40]],
        { me.id, MIN_AGE, me.id, me.id, me.id, me.id, me.id }) or {}
    local out = {}
    for _, p in ipairs(rows) do
        if suits(p.gender, me.seeking) and suits(me.gender, p.seeking) and #out < 20 then out[#out + 1] = card(p) end
    end
    return { cards = out, active = me.active == 1 }
end)

Register('datingSwipe', function(_, phone, d)
    local me = mine(phone)
    local other = me and MySQL.single.await('SELECT * FROM opslabs_phone_dating_profiles WHERE id = ? AND active = 1', { tonumber(d.id) or 0 })
    if not me or not other or other.id == me.id then return { error = 'Not available' } end
    local liked = d.like == true
    MySQL.query.await('INSERT INTO opslabs_phone_dating_swipes (from_id, to_id, liked, at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE liked = VALUES(liked), at = VALUES(at)',
        { me.id, other.id, liked and 1 or 0, now() })
    if not liked then return { ok = true } end
    local back = MySQL.scalar.await('SELECT liked FROM opslabs_phone_dating_swipes WHERE from_id = ? AND to_id = ?', { other.id, me.id })
    if back ~= 1 and back ~= true then return { ok = true } end
    local a, b = math.min(me.id, other.id), math.max(me.id, other.id)
    MySQL.query.await('INSERT INTO opslabs_phone_dating_matches (a, b, created_at, last_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE ended = 0, last_at = VALUES(last_at)', { a, b, now(), now() })
    local mid = MySQL.scalar.await('SELECT id FROM opslabs_phone_dating_matches WHERE a = ? AND b = ?', { a, b })
    notifyProfile(other.id, { app = 'dating', title = 'It’s a match!', body = ('You and %s like each other'):format(me.name), icon = 'fa-heart' })
    return { ok = true, match = { id = mid, profile = card(other) } }
end)

---------------------------------------------------------------------------
-- matches and chat
---------------------------------------------------------------------------
Register('datingMatches', function(_, phone)
    local me = mine(phone)
    if not me then return { needProfile = true, matches = {} } end
    local rows = MySQL.query.await([[SELECT m.*, p.id AS pid, p.name, p.age, p.gender, p.bio, p.job, p.area, p.photos, p.interests,
            (SELECT body FROM opslabs_phone_dating_messages x WHERE x.match_id = m.id ORDER BY x.id DESC LIMIT 1) AS last_body,
            (SELECT sender FROM opslabs_phone_dating_messages x WHERE x.match_id = m.id ORDER BY x.id DESC LIMIT 1) AS last_sender,
            (SELECT COUNT(*) FROM opslabs_phone_dating_messages x WHERE x.match_id = m.id AND x.sender <> ? AND x.at > IF(m.a = ?, m.a_read, m.b_read)) AS unread
        FROM opslabs_phone_dating_matches m JOIN opslabs_phone_dating_profiles p ON p.id = IF(m.a = ?, m.b, m.a)
        WHERE (m.a = ? OR m.b = ?) AND m.ended = 0 ORDER BY m.last_at DESC]], { me.id, me.id, me.id, me.id, me.id }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local c = card({ id = r.pid, name = r.name, age = r.age, gender = r.gender, bio = r.bio, job = r.job, area = r.area, photos = r.photos, interests = r.interests })
        out[#out + 1] = { id = r.id, profile = c, last = r.last_body, lastMine = r.last_sender == me.id, unread = tonumber(r.unread) or 0, at = r.last_at, new = r.last_body == nil }
    end
    return { matches = out }
end)

Register('datingChat', function(_, phone, d)
    local me = mine(phone)
    local m = me and matchFor(me, d.match)
    if not m or m.ended == 1 then return { error = 'This match has ended' } end
    MySQL.update.await(('UPDATE opslabs_phone_dating_matches SET %s = ? WHERE id = ?'):format(m.a == me.id and 'a_read' or 'b_read'), { now(), m.id })
    local msgs = MySQL.query.await('SELECT id, sender, body, at FROM opslabs_phone_dating_messages WHERE match_id = ? ORDER BY id DESC LIMIT 100', { m.id }) or {}
    local out = {}
    for i = #msgs, 1, -1 do out[#out + 1] = { id = msgs[i].id, body = msgs[i].body, at = msgs[i].at, mine = msgs[i].sender == me.id } end
    return { messages = out }
end)

local sendAt = {}
Register('datingSend', function(src, phone, d)
    local me = mine(phone)
    local m = me and matchFor(me, d.match)
    if not m or m.ended == 1 then return { error = 'This match has ended' } end
    local body = Clean(d.body or '', 1000)
    if body == '' then return { error = 'Empty message' } end
    if sendAt[src] and GetGameTimer() - sendAt[src] < 600 then return { error = 'Slow down' } end
    sendAt[src] = GetGameTimer()
    local t = now()
    local id = MySQL.insert.await('INSERT INTO opslabs_phone_dating_messages (match_id, sender, body, at) VALUES (?, ?, ?, ?)', { m.id, me.id, body, t })
    MySQL.update.await(('UPDATE opslabs_phone_dating_matches SET last_at = ?, %s = ? WHERE id = ?'):format(m.a == me.id and 'a_read' or 'b_read'), { t, t, m.id })
    local other = m.a == me.id and m.b or m.a
    local ident = MySQL.scalar.await('SELECT identifier FROM opslabs_phone_dating_profiles WHERE id = ?', { other })
    local peer = ident and GetSourceByIdentifier(ident)
    if peer then
        Push(peer, 'datingMessage', { match = m.id, id = id, body = body, at = t })
        Notify(peer, { app = 'dating', title = me.name, body = body, icon = 'fa-heart', data = { match = m.id } })
    end
    return { ok = true, id = id, at = t }
end)
AddEventHandler('playerDropped', function() sendAt[source] = nil end)

Register('datingUnmatch', function(_, phone, d)
    local me = mine(phone)
    local m = me and matchFor(me, d.match)
    if not m then return { error = 'Not found' } end
    MySQL.update.await('UPDATE opslabs_phone_dating_matches SET ended = 1 WHERE id = ?', { m.id })
    local other = m.a == me.id and m.b or m.a
    MySQL.query.await('INSERT INTO opslabs_phone_dating_swipes (from_id, to_id, liked, at) VALUES (?, ?, 0, ?) ON DUPLICATE KEY UPDATE liked = 0, at = VALUES(at)', { me.id, other, now() })
    return { ok = true }
end)

Register('datingReport', function(_, phone, d)
    local me = mine(phone)
    local target = tonumber(d.id)
    if not me or not target then return { error = 'Not found' } end
    MySQL.insert.await('INSERT INTO opslabs_phone_dating_reports (reporter, target, reason, at) VALUES (?, ?, ?, ?)', { me.id, target, d.reason and Clean(d.reason, 300) or nil, now() })
    MySQL.update.await('UPDATE opslabs_phone_dating_matches SET ended = 1 WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)', { me.id, target, target, me.id })
    MySQL.query.await('INSERT INTO opslabs_phone_dating_swipes (from_id, to_id, liked, at) VALUES (?, ?, 0, ?) ON DUPLICATE KEY UPDATE liked = 0', { me.id, target, now() })
    print(('[opslabs-phone] Sparks report: profile %d reported profile %d: %s'):format(me.id, target, tostring(d.reason or '')))
    return { ok = true }
end)
