-- Every NUI screen talks to the CAD through here. `withOfficer` is the one gate every real action goes
-- through: eligible for an MDT at all (FW.Eligible), and linked to a real CAD account (Officer.Get). Being
-- "on duty" is enforced by the CAD itself on the actions that need it (e.g. creating an incident requires an
-- ActiveOfficer CAD-side) - its own error comes back through Cad.DescribeError rather than being guessed here.

local function withOfficer(src, fn)
    local ok, why = FW.Eligible(src)
    if not ok then return { error = 'You are not issued an MDT (' .. tostring(why) .. ').' } end
    local o = Officer.Get(src)
    if not o then Dbg('withOfficer: src=%s has no linked CAD token', src) return { error = 'not_linked' } end
    local data, status = fn(o.token)
    Dbg('withOfficer: src=%s cadUser=%s status=%s', src, o.username, status)
    if status ~= 200 then return { error = Cad.DescribeError(status, data) } end
    return { ok = true, data = data }
end

--- session state for the NUI boot screen: linked?, username, and (best-effort) current duty status
lib.callback.register('opslabs-mdt:status', function(src)
    local ok = FW.Eligible(src)
    if not ok then return { denied = true } end
    local o = Officer.Get(src)
    if not o then return { linked = false } end
    local data, status = Cad.AsOfficer(o.token, 'GET', '/leo/active-officer')
    return {
        linked = true,
        username = o.username,
        onDuty = status == 200,
        officer = status == 200 and data or nil,
        cadConfigured = Cad.Configured(),
    }
end)

lib.callback.register('opslabs-mdt:link', function(src, d)
    -- the generic NUI 'call' dispatcher (client/main.lua) always sends the JS side's data object as-is, i.e.
    -- { token = "..." } here - not a bare string. Every other handler in this file already does `d.whatever`;
    -- this one named its parameter `token` and used it directly, so Officer.Link got handed the whole table
    -- and tostring()'d it into literally "table: 0x..." - which is exactly what the CAD's own log just showed
    -- being sent as the header value. Confirmed root cause of every single 403 so far.
    local token = type(d) == 'table' and d.token or d
    Dbg('server link: src=%s token length=%d', src, #tostring(token or ''))
    local ok, result = Officer.Link(src, token)
    Dbg('server link: Officer.Link returned ok=%s result=%s', ok, tostring(result))
    if not ok then return { error = result } end
    return { ok = true, username = result }
end)

lib.callback.register('opslabs-mdt:unlink', function(src)
    Officer.Unlink(src)
    return { ok = true }
end)

-- search --------------------------------------------------------------------------------------------------

lib.callback.register('opslabs-mdt:searchName', function(src, d)
    d = type(d) == 'table' and d or {}
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/search/name', { name = tostring(d.name or '') }) end)
end)

lib.callback.register('opslabs-mdt:searchPlate', function(src, d)
    d = type(d) == 'table' and d or {}
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/search/vehicle', { plateOrVin = tostring(d.plate or '') }) end)
end)

lib.callback.register('opslabs-mdt:searchWeapon', function(src, d)
    d = type(d) == 'table' and d or {}
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/search/weapon', { serialNumber = tostring(d.serial or '') }) end)
end)

lib.callback.register('opslabs-mdt:citizenRecords', function(src, d)
    d = type(d) == 'table' and d or {}
    local id = tostring(d.citizenId or '')
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'GET', '/citizen/' .. id .. '/records') end)
end)

-- dispatch board --------------------------------------------------------------------------------------------

lib.callback.register('opslabs-mdt:activeOfficers', function(src)
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'GET', '/leo/active-officers?includeAll=true') end)
end)

lib.callback.register('opslabs-mdt:calls', function(src)
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'GET', '/911-calls?includeEnded=false&includeAll=true') end)
end)

-- BOLOs ---------------------------------------------------------------------------------------------------

lib.callback.register('opslabs-mdt:bolos', function(src)
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'GET', '/bolos?includeAll=true') end)
end)

lib.callback.register('opslabs-mdt:createBolo', function(src, d)
    d = type(d) == 'table' and d or {}
    local kind = tostring(d.type or 'VEHICLE')
    local body = {
        type = kind, description = tostring(d.description or ''),
        name = kind == 'PERSON' and tostring(d.name or '') or nil,
        plate = kind == 'VEHICLE' and tostring(d.plate or '') or nil,
        color = kind == 'VEHICLE' and tostring(d.color or '') or nil,
        model = kind == 'VEHICLE' and tostring(d.model or '') or nil,
    }
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/bolos', body) end)
end)

lib.callback.register('opslabs-mdt:deleteBolo', function(src, d)
    d = type(d) == 'table' and d or {}
    local id = tostring(d.id or '')
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'DELETE', '/bolos/' .. id) end)
end)

-- citations / warnings / arrest reports --------------------------------------------------------------------

--- the CAD's own penal code list, for the violation picker - the global token (effectively full permissions,
--- same one snailycad-framework already uses) so an ordinary officer token that lacks ManageValues still works
lib.callback.register('opslabs-mdt:penalCodes', function(src)
    local ok = FW.Eligible(src)
    if not ok then return { error = 'not_eligible' } end
    if not Officer.Get(src) then return { error = 'not_linked' } end
    local data, status = Cad.Global('GET', '/admin/values/penal_code')
    if status ~= 200 then return { error = Cad.DescribeError(status, data) } end
    return { ok = true, data = data }
end)

lib.callback.register('opslabs-mdt:createCitation', function(src, d)
    d = type(d) == 'table' and d or {}
    local violations = {}
    for _, v in ipairs(d.violations or {}) do
        violations[#violations + 1] = {
            penalCodeId = v.penalCodeId, fine = tonumber(v.fine), jailTime = tonumber(v.jailTime),
            bail = tonumber(v.bail), communityService = v.communityService,
        }
    end
    local body = {
        type = tostring(d.type or 'TICKET'), citizenId = tostring(d.citizenId or ''),
        violations = violations, postal = tostring(d.postal or '0'), notes = d.notes,
        plateOrVin = d.plate, descriptionData = nil, publishStatus = 'PUBLISHED',
    }
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/records', body) end)
end)

-- warrants --------------------------------------------------------------------------------------------------

lib.callback.register('opslabs-mdt:activeWarrants', function(src)
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'GET', '/records/active-warrants?includeAll=true') end)
end)

lib.callback.register('opslabs-mdt:createWarrant', function(src, d)
    d = type(d) == 'table' and d or {}
    local body = { citizenId = tostring(d.citizenId or ''), status = 'ACTIVE', description = tostring(d.description or '') }
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/records/create-warrant', body) end)
end)

--- "serve" a warrant: mark it inactive, same as the CAD's own UI does
lib.callback.register('opslabs-mdt:serveWarrant', function(src, d)
    d = type(d) == 'table' and d or {}
    local id = tostring(d.id or '')
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'PUT', '/records/warrant/' .. id, { status = 'INACTIVE' }) end)
end)

-- incident reports ------------------------------------------------------------------------------------------

lib.callback.register('opslabs-mdt:createIncident', function(src, d)
    d = type(d) == 'table' and d or {}
    local body = {
        description = tostring(d.description or ''), postal = d.postal,
        firearmsInvolved = d.firearmsInvolved == true, injuriesOrFatalities = d.injuriesOrFatalities == true,
        arrestsMade = d.arrestsMade == true, isActive = true, unitsInvolved = {},
    }
    return withOfficer(src, function(token) return Cad.AsOfficer(token, 'POST', '/incidents', body) end)
end)
