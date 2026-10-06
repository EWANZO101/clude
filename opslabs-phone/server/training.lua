-- OPS training, job assistant, health & safety and items mode.
--
-- Content: sql/ops_guides.json — 21 job families (every job type), each with equipment, tools & PPE, steps with
-- animations, hazards & controls, common mistakes and their consequences, a safety quiz and an exam; plus system
-- explainers for the OPS Hub classroom.
--
-- Certification (per cert code, shared by one or more families):  exam ≥ PassMark  [+ in-game practical at an OPS
-- Academy training centre when Config.Work.RequirePractical]  →  certified for validDays.
-- Each family also has a safety module (quiz) that must be passed before taking its jobs (Config.Work.RequireSafetyTraining).
-- Before on-site work / completing a job: a dynamic risk assessment (Config.Work.SafetyBriefing). Skipping controls on
-- risky work can cause an accident (Config.Work.SafetyIncidents) — logged in ops_incidents.
-- Items mode (Config.Work.Mode = 'items'): tools / PPE / parts are inventory items collected at an OPS depot.

local RES = GetCurrentResourceName()
local GUIDE = json.decode(LoadResourceFile(RES, 'sql/ops_guides.json') or '{}') or {}
local FAM = GUIDE.families or {}
local TOOLS = GUIDE.tools or {}
local FAMILY_OF = {}
for code, f in pairs(FAM) do f.code = code for _, j in ipairs(f.jobs or {}) do FAMILY_OF[j] = code end end
local DAY = 86400

local function W() return Config.Work or {} end
local function F() return Config.Features or {} end
local function now() return os.time() end
local function decode(s, d) if type(s) ~= 'string' or s == '' then return d end local ok, v = pcall(json.decode, s) return ok and v or d end

-- certificates: every cert code used by a family; exam = its families' exam questions
local CERTS = {}
local catalogCerts = {}
for _, c in ipairs(((Ops.catalog or {}).business or {}).certs or {}) do catalogCerts[c.code] = c end
for code, f in pairs(FAM) do
    if f.cert then
        local c = CERTS[f.cert] or { code = f.cert, name = f.certName or f.cert, families = {}, exam = {}, company = f.company,
            validDays = (catalogCerts[f.cert] or {}).validDays or 60 }
        c.families[#c.families + 1] = code
        for _, q in ipairs(f.exam or {}) do if #c.exam < 10 then c.exam[#c.exam + 1] = q end end
        CERTS[f.cert] = c
    end
end
for _, c in pairs(CERTS) do table.sort(c.families) end
TrainingCerts, TrainingFamilies, TrainingFamilyOf = CERTS, FAM, FAMILY_OF

CreateThread(function()
    AwaitDatabase()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS ops_training (account_id INT NOT NULL, kind VARCHAR(12) NOT NULL, ref VARCHAR(40) NOT NULL,
        score INT NULL, at INT NOT NULL, expires_at INT NULL, PRIMARY KEY (account_id, kind, ref))]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS ops_incidents (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, account_id INT NULL, name VARCHAR(80) NULL,
        company_id INT NULL, job_id INT NULL, kind VARCHAR(16) NOT NULL, detail VARCHAR(255) NULL, x FLOAT NULL, y FLOAT NULL, z FLOAT NULL, at INT NOT NULL, KEY at (at))]])
end)

---------------------------------------------------------------------------
-- records
---------------------------------------------------------------------------
local function record(aid, kind, ref, score, validDays)
    MySQL.query.await([[INSERT INTO ops_training (account_id, kind, ref, score, at, expires_at) VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE score = VALUES(score), at = VALUES(at), expires_at = VALUES(expires_at)]], { aid, kind, ref, score, now(), validDays and (now() + validDays * DAY) or nil })
end
local function has(aid, kind, ref)
    return MySQL.scalar.await('SELECT 1 FROM ops_training WHERE account_id = ? AND kind = ? AND ref = ? AND (expires_at IS NULL OR expires_at > ?)', { aid, kind, ref, now() }) ~= nil
end
local function certValid(aid, code)
    return MySQL.scalar.await('SELECT 1 FROM ops_member_certs WHERE account_id = ? AND cert = ? AND expires_at > ?', { aid, code, now() }) ~= nil
end

local function issueIfReady(a, code)
    local c = CERTS[code]
    if not c or not has(a.id, 'exam', code) then return false end
    if W().RequirePractical ~= false and not has(a.id, 'practical', code) then return false end
    local score = MySQL.scalar.await("SELECT score FROM ops_training WHERE account_id = ? AND kind = 'exam' AND ref = ?", { a.id, code })
    MySQL.query.await([[INSERT INTO ops_member_certs (account_id, cert, issued_at, expires_at, issued_by, score) VALUES (?, ?, ?, ?, 'training', ?)
        ON DUPLICATE KEY UPDATE issued_at = VALUES(issued_at), expires_at = VALUES(expires_at), issued_by = VALUES(issued_by), score = VALUES(score)]],
        { a.id, code, now(), now() + c.validDays * DAY, score })
    Ops.audit(Ops.nameOf(a), nil, 'cert.issued', code, tostring(score))
    return true
end

local function familyOfJob(j) local code = FAMILY_OF[j.type] return code and FAM[code], code end

---------------------------------------------------------------------------
-- gates used by platform.lua
---------------------------------------------------------------------------
function BizCertName(code) return CERTS[code] and CERTS[code].name or ((catalogCerts[code] or {}).name) end

--- accepting a job: safety module for its family, and the certification if the work needs one
function BizCertBlock(a, j)
    if F().Training == false or Ops.isSuper(a) then return nil end
    local t = Ops.types[j.type] or {}
    local fam, famCode = familyOfJob(j)
    if fam and W().RequireSafetyTraining ~= false and not has(a.id, 'safety', famCode) then
        return ('Do the health & safety module for “%s” first — OPS Work → Training'):format(fam.name)
    end
    local cert = t.cert or (fam and fam.cert)
    local required = t.certRequired
    if required == nil then required = fam and fam.certRequired end
    if cert and required and not certValid(a.id, cert) then
        return ('This job needs the “%s” certification — OPS Work → Training'):format(BizCertName(cert) or cert)
    end
    return nil
end

local function itemsMode() return W().Mode == 'items' end
local function placedSkus() local set = {} for _, sku in pairs(W().ModelItems or {}) do set[sku] = true end return set end
--- the parts a job takes from your inventory on completion: consumables (kit you place from /towers used its item already)
local function consumables(t)
    local out, placed = {}, placedSkus()
    for sku, qty in pairs((t or {}).parts or {}) do if not placed[sku] then out[sku] = qty end end
    return out
end
local function itemName(id) return (W().ItemPrefix or 'ops_') .. tostring(id):gsub('%-', '_') end
local function hasItem(src, id, n) return (FW.ItemCount(src, itemName(id)) or 0) >= (n or 1) end

--- what the player is missing (items mode): tools for the family, and parts the job uses
local function missingKit(src, j)
    if not itemsMode() then return {}, {} end
    local fam = familyOfJob(j)
    local tools, parts = {}, {}
    for _, id in ipairs(fam and fam.tools or {}) do if not hasItem(src, id) then tools[#tools + 1] = id end end
    if W().ConsumeParts ~= false then
        for sku, qty in pairs(consumables(Ops.types[j.type])) do if not hasItem(src, sku, qty) then parts[#parts + 1] = { sku = sku, qty = qty } end end
    end
    return tools, parts
end

--- before starting on-site work / completing: risk assessment done, tools (and parts) with you in items mode
function BizBeforeWork(j, src, a, stage)
    local prog = decode(j.progress, {})
    if W().SafetyBriefing ~= false and not prog.ra then
        return { error = 'Do the risk assessment first — Guide me → Risk assessment', needRA = true }
    end
    local tools, parts = missingKit(src, j)
    if #tools > 0 then
        local names = {}
        for _, id in ipairs(tools) do names[#names + 1] = (TOOLS[id] or {}).name or id end
        return { error = 'You don’t have: ' .. table.concat(names, ', ') .. ' — collect them at the OPS depot (Guide me → GPS to depot)', needTools = tools }
    end
    if stage == 'complete' and #parts > 0 then
        local names = {}
        for _, p in ipairs(parts) do names[#names + 1] = ('%s × %s'):format(p.sku, p.qty) end
        return { error = 'Parts this job uses aren’t in your inventory: ' .. table.concat(names, ', ') .. ' — collect them at the OPS depot', needParts = parts }
    end
    return nil
end

--- items mode: completing takes the parts from your inventory (company stock was used when you collected them)
local baseCompleted = BizOnCompleted
function BizOnCompleted(j, c, cust, a, src)
    if itemsMode() and W().ConsumeParts ~= false then
        for sku, qty in pairs(consumables(Ops.types[j.type])) do
            if src then FW.RemoveItem(src, itemName(sku), qty) end
        end
        -- register assets etc. without taking stock a second time
        local t = Ops.types[j.type]
        local saved = t and t.parts
        if t then t.parts = nil end
        local ok, err = pcall(baseCompleted, j, c, cust, a)
        if t then t.parts = saved end
        if saved and cust then
            for sku, qty in pairs(saved) do
                local s = MySQL.single.await('SELECT * FROM ops_stock WHERE company_id = ? AND sku = ?', { c.id, sku })
                if s and s.unit == 'each' and tonumber(s.cost) >= 20 then
                    for _ = 1, math.min(qty, 10) do
                        MySQL.insert.await([[INSERT INTO ops_assets (company_id, customer_id, sku, name, serial, location, job_id, installed_at, warranty_until) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
                            { c.id, cust.id, sku, s.name, ('%s-%06X'):format(sku:upper():gsub('[^A-Z0-9]', ''):sub(1, 6), math.random(0, 0xffffff)), j.location, j.id, now(),
                              now() + (((Ops.catalog.business or {}).warrantyDays) or 30) * DAY })
                    end
                end
            end
        end
        if not ok then print('[training] completion: ' .. tostring(err)) end
        return
    end
    return baseCompleted(j, c, cust, a, src)
end

--- on-site work as a sequence of the family's steps (animations), scaled to the time left
function BizWorkPlan(j, secs)
    local fam = familyOfJob(j)
    if not fam or not fam.steps or #fam.steps == 0 or secs <= 0 then return nil end
    local total = 0
    for _, s in ipairs(fam.steps) do total = total + (s.secs or 8) end
    local plan = {}
    for _, s in ipairs(fam.steps) do
        plan[#plan + 1] = { title = s.title, anim = s.anim, secs = math.max(3, math.floor((s.secs or 8) / total * secs + 0.5)) }
    end
    return plan
end

---------------------------------------------------------------------------
-- RPCs: training (OPS Work → Training)
---------------------------------------------------------------------------
local function On(name, fn)
    Register(name, function(src, phone, d)
        local a = Ops.account(src)
        if not a then return { loggedOut = true } end
        a.src = src
        return fn(src, phone, d, a)
    end)
end

local function status(aid, kind, ref)
    local r = MySQL.single.await('SELECT * FROM ops_training WHERE account_id = ? AND kind = ? AND ref = ?', { aid, kind, ref })
    if not r then return { state = 'none' } end
    return { state = (r.expires_at and r.expires_at < now()) and 'expired' or 'done', score = r.score, at = r.at, expires = r.expires_at }
end

On('opsTraining', function(_, _, _, a)
    if F().Training == false then return { disabled = true } end
    local cos = {}
    for _, m in ipairs(MySQL.query.await("SELECT c.code FROM ops_members m JOIN ops_companies c ON c.id = m.company_id WHERE m.account_id = ? AND m.status = 'active'", { a.id }) or {}) do cos[m.code] = true end
    local list = {}
    for code, c in pairs(CERTS) do
        local co = Ops.company(c.company) or {}
        local mc = MySQL.single.await('SELECT * FROM ops_member_certs WHERE account_id = ? AND cert = ?', { a.id, code })
        local fams = {}
        local mine = Ops.isSuper(a)
        for _, fc in ipairs(c.families) do
            local f = FAM[fc]
            if cos[f.company] then mine = true end
            fams[#fams + 1] = { code = fc, name = f.name, jobs = #(f.jobs or {}), required = f.certRequired == true, safety = status(a.id, 'safety', fc), lesson = status(a.id, 'lesson', fc) }
        end
        list[#list + 1] = { code = code, name = c.name, company = co.name, color = co.color, icon = co.icon, mine = mine, families = fams,
            exam = status(a.id, 'exam', code), practical = status(a.id, 'practical', code), needPractical = W().RequirePractical ~= false,
            cert = mc and { expires = mc.expires_at, valid = mc.expires_at > now(), score = mc.score } or nil, questions = #c.exam, validDays = c.validDays }
    end
    table.sort(list, function(x, y) if x.mine ~= y.mine then return x.mine end return x.name < y.name end)
    return { certs = list, centres = W().TrainingCentres, passMark = W().PassMark or 75 }
end)

-- reading is open to everyone (phone, laptop, Browser → opsacademy.sa); signed-in OPS staff get it recorded
Register('opsLesson', function(src, _, d)
    local a = Ops.account(src)
    local f = FAM[tostring(d.family or '')]
    if not f then return { error = 'No such course' } end
    if a then record(a.id, 'lesson', f.code, nil, nil) end
    local tools = {}
    for _, id in ipairs(f.tools or {}) do tools[#tools + 1] = { id = id, name = (TOOLS[id] or {}).name, what = (TOOLS[id] or {}).what } end
    local ppe = {}
    for _, id in ipairs(f.ppe or {}) do ppe[#ppe + 1] = { id = id, name = (TOOLS[id] or {}).name, what = (TOOLS[id] or {}).what } end
    return { family = { code = f.code, name = f.name, summary = f.summary, overview = f.overview, equipment = f.equipment, steps = f.steps, safety = f.safety, mistakes = f.mistakes,
        tools = tools, ppe = ppe, cert = f.cert, certName = f.certName } }
end)

--- OPS Academy (phone / laptop app and opsacademy.sa): every course, system explainer and slideshow
Register('opsAcademy', function(src)
    local a = Ops.account(src)
    local cos = {}
    if a then for _, m in ipairs(MySQL.query.await("SELECT c.code FROM ops_members m JOIN ops_companies c ON c.id = m.company_id WHERE m.account_id = ? AND m.status = 'active'", { a.id }) or {}) do cos[m.code] = true end end
    local courses = {}
    for code, c in pairs(CERTS) do
        local co = Ops.company(c.company) or {}
        local fams, mine = {}, false
        for _, fc in ipairs(c.families) do
            local f = FAM[fc]
            if cos[f.company] then mine = true end
            fams[#fams + 1] = { code = fc, name = f.name, summary = f.summary, jobs = #(f.jobs or {}), required = f.certRequired == true,
                lesson = a and status(a.id, 'lesson', fc) or nil, safety = a and status(a.id, 'safety', fc) or nil }
        end
        local mc = a and MySQL.single.await('SELECT * FROM ops_member_certs WHERE account_id = ? AND cert = ?', { a.id, code })
        courses[#courses + 1] = { code = code, name = c.name, company = co.name, color = co.color, icon = co.icon, mine = mine, families = fams, questions = #c.exam,
            exam = a and status(a.id, 'exam', code) or nil, practical = a and status(a.id, 'practical', code) or nil, needPractical = W().RequirePractical ~= false,
            cert = mc and { expires = mc.expires_at, valid = mc.expires_at > now() } or nil }
    end
    table.sort(courses, function(x, y) if x.mine ~= y.mine then return x.mine end return x.name < y.name end)
    local systems = {}
    for _, s in ipairs(GUIDE.systems or {}) do systems[#systems + 1] = { code = s.code, name = s.name, icon = s.icon, intro = s.sections[1] and s.sections[1].body } end
    local shows = {}
    for code, s in pairs(GUIDE.slideshows or {}) do shows[#shows + 1] = { code = code, name = s.name, desc = s.desc, icon = s.icon, count = #s.slides } end
    table.sort(shows, function(x, y) return x.code > y.code end)
    return { signedIn = a ~= nil, name = a and Ops.nameOf(a), courses = courses, systems = systems, slideshows = shows, passMark = W().PassMark or 75,
        centres = W().TrainingCentres, training = F().Training ~= false }
end)
Register('opsSystem', function(_, _, d)
    for _, s in ipairs(GUIDE.systems or {}) do
        if s.code == d.code then
            local jobs = {}
            for code, f in pairs(FAM) do if s.company and f.company == s.company then jobs[#jobs + 1] = { code = code, name = f.name } end end
            return { system = s, families = jobs }
        end
    end
    return { error = 'Not found' }
end)
Register('opsSlides', function(_, _, d)
    local s = (GUIDE.slideshows or {})[tostring(d.code or '')]
    if not s then return { error = 'Not found' } end
    return { show = s }
end)

local quizzes = {}       -- src -> { kind, ref, order, at }
local failAt = {}
local function shuffleQuiz(src, kind, ref, qs)
    if failAt[src] and now() - failAt[src] < (W().RetryCooldown or 60) then return nil, ('Revise for a moment — you can try again in %d s'):format((W().RetryCooldown or 60) - (now() - failAt[src])) end
    local out, order = {}, {}
    for i, q in ipairs(qs) do
        local idx = {}
        for k = 1, #q.a do idx[k] = k end
        for k = #idx, 2, -1 do local r = math.random(k) idx[k], idx[r] = idx[r], idx[k] end
        local opts = {}
        for k, orig in ipairs(idx) do opts[k] = q.a[orig] end
        order[i] = idx
        out[i] = { q = q.q, a = opts }
    end
    quizzes[src] = { kind = kind, ref = ref, order = order, qs = qs, at = now() }
    return out
end
local function grade(src, kind, ref, answers)
    local z = quizzes[src]
    if not z or z.kind ~= kind or z.ref ~= ref then return nil end
    quizzes[src] = nil
    local right = 0
    for i, q in ipairs(z.qs) do
        local pick = tonumber(type(answers) == 'table' and answers[i] or nil)
        if pick and z.order[i][pick] == (q.ok or 0) + 1 then right = right + 1 end
    end
    local score = math.floor(right / math.max(1, #z.qs) * 100 + 0.5)
    local pass = score >= (W().PassMark or 75)
    if not pass then failAt[src] = now() end
    return { ok = pass, score = score, right = right, total = #z.qs }
end

On('opsSafetyQuiz', function(src, _, d, a)
    local f = FAM[tostring(d.family or '')]
    if not f then return { error = 'No such module' } end
    local qs, err = shuffleQuiz(src, 'safety', f.code, f.safetyQuiz or {})
    if not qs then return { error = err } end
    return { family = f.code, name = f.name, hazards = f.safety, ppe = f.ppe, questions = qs, pass = W().PassMark or 75 }
end)
On('opsSafetyAnswer', function(src, _, d, a)
    local f = FAM[tostring(d.family or '')]
    local r = f and grade(src, 'safety', f.code, d.answers)
    if not r then return { error = 'Start the module again' } end
    if r.ok then record(a.id, 'safety', f.code, r.score, (CERTS[f.cert] or {}).validDays or 60) end
    return r
end)

On('opsCourse', function(src, _, d, a)
    local c = CERTS[tostring(d.code or '')]
    if not c then return { error = 'No such course' } end
    local qs, err = shuffleQuiz(src, 'exam', c.code, c.exam)
    if not qs then return { error = err } end
    return { code = c.code, name = c.name, questions = qs, pass = W().PassMark or 75 }
end)
On('opsExam', function(src, _, d, a)
    local c = CERTS[tostring(d.code or '')]
    local r = c and grade(src, 'exam', c.code, d.answers)
    if not r then return { error = 'Start the exam again' } end
    if r.ok then
        record(a.id, 'exam', c.code, r.score, c.validDays)
        r.certified = issueIfReady(a, c.code)
        r.needPractical = not r.certified and W().RequirePractical ~= false
    end
    return r
end)

-- the practical: at an OPS Academy training centre, do the family's steps (animations + skill checks)
local practicals = {}    -- src -> { code, token, at, need }
local function nearCentre(src)
    local p = GetEntityCoords(GetPlayerPed(src))
    for _, c in ipairs(W().TrainingCentres or {}) do
        if math.sqrt((p.x - c.x) ^ 2 + (p.y - c.y) ^ 2) < 25.0 then return c end
    end
    return nil
end
On('opsPracticalStart', function(src, _, d, a)
    local c = CERTS[tostring(d.code or '')]
    if not c then return { error = 'No such course' } end
    if not nearCentre(src) then return { error = 'Practicals are done at an OPS Academy training centre', centres = W().TrainingCentres } end
    local f = FAM[c.families[1]]
    local steps, need = {}, 0
    for _, s in ipairs(f.steps or {}) do
        steps[#steps + 1] = { title = s.title, detail = s.detail, anim = s.anim, secs = s.secs or 8, tool = s.tool and (TOOLS[s.tool] or {}).name }
        need = need + (s.secs or 8)
    end
    local token = ('%08x'):format(math.random(0, 0x7fffffff))
    practicals[src] = { code = c.code, token = token, at = now(), need = need }
    return { ok = true, token = token, name = c.name, family = f.name, steps = steps, skillChecks = W().PracticalSkillChecks ~= false }
end)
On('opsPracticalDone', function(src, _, d, a)
    local p = practicals[src]
    practicals[src] = nil
    if not p or p.code ~= d.code or p.token ~= d.token then return { error = 'Start the practical again' } end
    if now() - p.at < p.need * 0.6 then return { error = 'That was too quick — do every step properly' } end
    if not nearCentre(src) then return { error = 'You left the training centre' } end
    local fails = math.max(0, math.floor(tonumber(d.fails) or 0))
    local score = math.max(0, 100 - fails * 20)
    if score < (W().PassMark or 75) then failAt[src] = now() return { ok = false, score = score } end
    record(a.id, 'practical', p.code, score, CERTS[p.code].validDays)
    return { ok = true, score = score, certified = issueIfReady(a, p.code) }
end)
AddEventHandler('playerDropped', function() quizzes[source] = nil practicals[source] = nil failAt[source] = nil end)

---------------------------------------------------------------------------
-- the job assistant ("Guide me" / /jobhelp)
---------------------------------------------------------------------------
local function nearestDepot(src)
    local p = GetEntityCoords(GetPlayerPed(src))
    local best, bd
    for _, dp in ipairs(W().Depots or {}) do
        local dd = math.sqrt((p.x - dp.x) ^ 2 + (p.y - dp.y) ^ 2)
        if not bd or dd < bd then best, bd = dp, dd end
    end
    return best, bd and math.floor(bd)
end

On('opsGuide', function(src, _, d, a)
    if F().Assistant == false then return { disabled = true } end
    local j
    if d.id then j = Ops.getJob(d.id)
    else
        j = MySQL.single.await("SELECT * FROM ops_jobs WHERE assigned_to = ? AND status IN ('assigned','in_progress') ORDER BY accepted_at DESC LIMIT 1", { a.id })
        if j then j = Ops.getJob(j.id) end
    end
    if not j then return { error = 'You have no job on — accept one in OPS Work first' } end
    local fam, famCode = familyOfJob(j)
    if not fam then return { error = 'No guide for this job yet' } end
    local mine = j.assigned_to == a.id and (j.status == 'assigned' or j.status == 'in_progress')
    local prog = decode(j.progress, {})
    local check = mine and Ops.verify(j, src, a) or nil
    -- where you are in the job: the check's progress through the steps
    local current = 1
    if mine then
        local frac = check and check.need and check.need > 0 and math.min(1, (check.have or 0) / check.need) or 0
        current = math.min(#fam.steps, 1 + math.floor(frac * (#fam.steps - 1) + 0.5))
        if check and check.ok then current = #fam.steps end
    end
    local tools, parts = missingKit(src, j)
    local missingSet = {}
    for _, id in ipairs(tools) do missingSet[id] = true end
    local tl = {}
    for _, id in ipairs(fam.tools or {}) do tl[#tl + 1] = { id = id, name = (TOOLS[id] or {}).name or id, what = (TOOLS[id] or {}).what, missing = missingSet[id] == true } end
    local ppe = {}
    for _, id in ipairs(fam.ppe or {}) do ppe[#ppe + 1] = { id = id, name = (TOOLS[id] or {}).name or id, what = (TOOLS[id] or {}).what, have = not itemsMode() or hasItem(src, id) } end
    local depot, dist = nearestDepot(src)
    local t = Ops.types[j.type] or {}
    local cert = t.cert or fam.cert
    local required = t.certRequired
    if required == nil then required = fam.certRequired end
    return {
        job = Ops.jobView(j, a), mine = mine, family = { code = famCode, name = fam.name, summary = fam.summary },
        steps = fam.steps, current = current, check = check, tools = tl, ppe = ppe, missingParts = parts,
        safety = fam.safety, mistakes = fam.mistakes, ra = prog.ra, needRA = W().SafetyBriefing ~= false,
        mode = W().Mode or 'standalone', depot = depot and { label = depot.label, x = depot.x, y = depot.y, z = depot.z, dist = dist } or nil,
        cert = cert and { code = cert, name = BizCertName(cert), required = required == true, have = certValid(a.id, cert) } or nil,
        safetyDone = has(a.id, 'safety', famCode),
    }
end)

--- the risk assessment: tick the controls (in items mode PPE you tick must be in your inventory)
On('opsRiskAssess', function(src, _, d, a)
    local j = Ops.getJob(d.id)
    if not j or j.assigned_to ~= a.id then return { error = 'Not your job' } end
    local fam = familyOfJob(j)
    if not fam then return { ok = true } end
    local ticked = {}
    for _, k in ipairs(type(d.checked) == 'table' and d.checked or {}) do ticked[tostring(k)] = true end
    if itemsMode() then
        for _, id in ipairs(fam.ppe or {}) do
            if ticked['ppe:' .. id] and not hasItem(src, id) then return { error = ('You ticked %s but you don’t have it — collect it at the depot'):format((TOOLS[id] or {}).name or id) } end
        end
    end
    local skipped = {}
    for i, h in ipairs(fam.safety or {}) do if not ticked['h:' .. i] then skipped[#skipped + 1] = h.hazard end end
    for _, id in ipairs(fam.ppe or {}) do if not ticked['ppe:' .. id] then skipped[#skipped + 1] = (TOOLS[id] or {}).name or id end end
    local prog = decode(j.progress, {})
    prog.ra = { at = now(), skipped = skipped }
    MySQL.update.await('UPDATE ops_jobs SET progress = ? WHERE id = ?', { json.encode(prog), j.id })
    local incident
    if #skipped > 0 and W().SafetyIncidents ~= false then
        -- the more controls skipped on risky work, the likelier an accident
        local risky = 0
        for _, s in ipairs(skipped) do
            local l = s:lower()
            if l:find('height') or l:find('harness') or l:find('ladder') then risky = risky + 2
            elseif l:find('electric') or l:find('glove') or l:find('isolation') or l:find('voltage') or l:find('dc') then risky = risky + 2
            else risky = risky + 1 end
        end
        if math.random() < math.min(0.6, risky * 0.08) then
            local kind
            for _, s in ipairs(skipped) do local l = s:lower() if l:find('height') or l:find('harness') or l:find('ladder') then kind = 'fall' break end end
            kind = kind or ((function() for _, s in ipairs(skipped) do local l = s:lower() if l:find('electric') or l:find('glove') or l:find('isolation') or l:find('dc') then return 'shock' end end end)()) or 'injury'
            local p = GetEntityCoords(GetPlayerPed(src))
            MySQL.insert('INSERT INTO ops_incidents (account_id, name, company_id, job_id, kind, detail, x, y, z, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                { a.id, Ops.nameOf(a), j.company_id, j.id, kind, ('Skipped: %s'):format(table.concat(skipped, ', ')):sub(1, 250), p.x, p.y, p.z, now() })
            incident = kind
            TriggerClientEvent('opslabs-phone:opsIncident', src, { kind = kind })
            if BizAlert then BizAlert(('incident:%d'):format(j.id), j.company_id, 'safety', 'bad', ('Safety incident on %s'):format(j.ref or j.id), ('%s — %s'):format(Ops.nameOf(a), kind)) end
        end
    end
    Ops.audit(Ops.nameOf(a), j.company_id, 'job.risk_assessment', j.ref, #skipped > 0 and ('skipped: ' .. table.concat(skipped, ', ')):sub(1, 380) or 'all controls in place')
    return { ok = true, skipped = skipped, incident = incident }
end)

--- the server-side helper for /jobhelp (client command)
lib.callback.register('opslabs-phone:jobhelp', function(src)
    local a = Ops.account(src)
    if not a then return { error = 'Sign in to OPS Work on your phone first' } end
    if F().Assistant == false then return { error = 'The job assistant is switched off' } end
    local row = MySQL.single.await("SELECT id FROM ops_jobs WHERE assigned_to = ? AND status IN ('assigned','in_progress') ORDER BY accepted_at DESC LIMIT 1", { a.id })
    if not row then return { error = 'You have no job on — accept one in OPS Work first' } end
    local j = Ops.getJob(row.id)
    local fam = familyOfJob(j)
    if not fam then return { error = 'No guide for this job yet' } end
    local check = Ops.verify(j, src, a)
    local frac = check and check.need and check.need > 0 and math.min(1, (check.have or 0) / check.need) or 0
    local current = math.min(#fam.steps, 1 + math.floor(frac * (#fam.steps - 1) + 0.5))
    if check and check.ok then current = #fam.steps end
    local tools = missingKit(src, j)
    local names = {}
    for _, id in ipairs(tools) do names[#names + 1] = (TOOLS[id] or {}).name or id end
    return { job = { id = j.id, ref = j.ref, title = j.title, x = j.x, y = j.y, z = j.z }, family = fam.name, steps = fam.steps, current = current,
        check = check, missing = names, depot = (nearestDepot(src)), ra = decode(j.progress, {}).ra ~= nil, needRA = W().SafetyBriefing ~= false }
end)

---------------------------------------------------------------------------
-- items mode: the OPS depot (collect tools / PPE / parts for your jobs, hand them back)
---------------------------------------------------------------------------
local function atDepot(src)
    local p = GetEntityCoords(GetPlayerPed(src))
    for _, dp in ipairs(W().Depots or {}) do
        if math.sqrt((p.x - dp.x) ^ 2 + (p.y - dp.y) ^ 2 + (p.z - dp.z) ^ 2) < (W().DepotRadius or 3.0) + 2.0 then return dp end
    end
end

lib.callback.register('opslabs-phone:depot', function(src, action, jobId)
    if not itemsMode() then return { error = 'Tools and parts are only items in items mode' } end
    if not atDepot(src) then return { error = 'Stand at the OPS depot counter' } end
    local a = Ops.account(src)
    if not a then return { error = 'Sign in to OPS Work first' } end
    local jobs = MySQL.query.await("SELECT * FROM ops_jobs WHERE assigned_to = ? AND status IN ('assigned','in_progress')", { a.id }) or {}
    if action == 'list' then
        local out = {}
        for _, j in ipairs(jobs) do
            local fam = FAM[FAMILY_OF[j.type] or '']
            local tools, parts = missingKit(src, j)
            out[#out + 1] = { id = j.id, ref = j.ref, title = j.title, family = fam and fam.name, tools = tools, parts = parts }
        end
        return { jobs = out }
    end
    local j
    for _, x in ipairs(jobs) do if x.id == tonumber(jobId) then j = x end end
    if action == 'tools' or action == 'parts' then
        if not j then return { error = 'Pick one of your jobs' } end
        local fam = FAM[FAMILY_OF[j.type] or ''] or {}
        local given = {}
        if action == 'tools' then
            local ids = {}
            for _, id in ipairs(fam.tools or {}) do ids[#ids + 1] = id end
            for _, id in ipairs(fam.ppe or {}) do ids[#ids + 1] = id end
            for _, id in ipairs(ids) do
                -- tools are issued (kept until handed back); PPE likewise
                if not hasItem(src, id) and FW.AddItem(src, itemName(id), 1) then given[#given + 1] = (TOOLS[id] or {}).name or id end
            end
        else
            for sku, qty in pairs((Ops.types[j.type] or {}).parts or {}) do
                local need = qty - (FW.ItemCount(src, itemName(sku)) or 0)
                if need > 0 then
                    local s = MySQL.single.await('SELECT * FROM ops_stock WHERE company_id = ? AND sku = ?', { j.company_id, sku })
                    if not s or tonumber(s.qty) < need then return { error = ('Not enough %s in stock (%s left) — the company needs to order more'):format(s and s.name or sku, s and s.qty or 0) } end
                    if FW.AddItem(src, itemName(sku), need) then
                        MySQL.update.await('UPDATE ops_stock SET qty = qty - ? WHERE id = ?', { need, s.id })
                        MySQL.insert.await('INSERT INTO ops_stock_moves (company_id, sku, qty, reason, ref, actor, at) VALUES (?, ?, ?, ?, ?, ?, ?)', { j.company_id, sku, -need, 'issued', j.ref, Ops.nameOf(a), now() })
                        given[#given + 1] = ('%s × %s'):format(s.name, need)
                    end
                end
            end
        end
        return { ok = true, given = given }
    end
    return { error = 'Unknown action' }
end)

--- towers kit placed / removed in items mode (opslabs-towers calls these): the model's item is used / given back
local function modelItem(model) return (W().ModelItems or {})[model] end
exports('WorkTakeForModel', function(src, model)
    if not itemsMode() then return true end
    local sku = modelItem(model)
    if not sku then return true end
    if (FW.ItemCount(src, itemName(sku)) or 0) < 1 then return false, ('You need a %s (%s) — collect it at the OPS depot'):format(sku, itemName(sku)) end
    FW.RemoveItem(src, itemName(sku), 1)
    return true
end)
exports('WorkGiveForModel', function(src, model)
    if not itemsMode() then return end
    local sku = modelItem(model)
    if sku then FW.AddItem(src, itemName(sku), 1) end
end)
exports('WorkMode', function() return W().Mode or 'standalone' end)
