-- Voice calls. Audio is routed through pma-voice call channels; the server
-- owns call state so neither side can join a channel it wasn't invited to.

local calls = {}      -- [callId] = { id, caller, callee, callerNumber, calleeNumber, state, startedAt, logId }
local inCall = {}     -- [source] = callId
local nextCallId = 1000

local function contactView(owner, number)
    return { number = number, name = ContactName(owner, number) }
end

local function finish(call, status)
    if not call or call.ended then return end
    call.ended = true

    local duration = call.startedAt and (os.time() - call.startedAt) or 0
    if call.logId then
        MySQL.update('UPDATE opslabs_phone_calls SET status = ?, duration = ? WHERE id = ?', { status, duration, call.logId })
    end

    Emit('call.ended', { from = call.callerNumber, to = call.calleeNumber, status = status, duration = duration })
    -- minutes count against the caller's plan
    if Carrier and duration > 0 and call.callerIdentifier then Carrier.Record(call.callerIdentifier, 'call', duration) end

    for _, src in ipairs({ call.caller, call.callee }) do
        if src then
            inCall[src] = nil
            Push(src, 'callEnded', { id = call.id, status = status, duration = duration })
        end
    end

    if status == 'missed' and call.callee then
        Notify(call.callee, {
            app = 'phone', title = 'Missed Call', icon = 'fa-phone-slash',
            body = ContactName(call.calleeNumber, call.callerNumber) or call.callerNumber,
            data = { number = call.callerNumber },
        })
    end
    calls[call.id] = nil
end

function EndCallFor(src)
    local id = inCall[src]
    if id and calls[id] then
        local call = calls[id]
        finish(call, call.state == 'active' and 'answered' or 'missed')
    end
end

Register('startCall', function(src, phone, data)
    local number = NormalizeNumber(data.number)
    if number == '' or number == phone.number then return { error = 'invalid' } end
    if inCall[src] then return { error = 'busy' } end

    -- service numbers become a dispatch request instead of a call
    for _, service in ipairs(Config.Services) do
        if service.number == number then
            CreateServiceRequest(src, phone, service.id, 'Phone call to ' .. service.label)
            return { error = 'service', label = service.label }
        end
    end

    local logId = MySQL.insert.await('INSERT INTO opslabs_phone_calls (caller, callee, status) VALUES (?, ?, ?)', { phone.number, number, 'missed' })

    nextCallId = nextCallId + 1
    local call = {
        id = nextCallId, caller = src, callerNumber = phone.number, calleeNumber = number,
        state = 'ringing', logId = logId, callerIdentifier = phone.identifier,
    }

    local target = GetSourceByNumber(number)
    local reachable = target and not inCall[target] and HasPhoneItem(target) and not (PhoneDead and PhoneDead(target))
        and not (Phones[target].settings.airplane) and not IsBlocked(number, phone.number)
        and (not Carrier or Carrier.HasService(Phones[target].identifier))
        and not (Carrier and Carrier.Network(target) and (Carrier.Network(target).cell or 0) <= 0)

    calls[call.id] = call
    inCall[src] = call.id

    if reachable then
        call.callee = target
        inCall[target] = call.id
        Push(target, 'incomingCall', { id = call.id, number = phone.number, name = ContactName(number, phone.number) })
    end

    -- timeout: unreachable phones just ring out
    SetTimeout(Config.Calls.RingTimeout * 1000, function()
        if calls[call.id] == call and call.state == 'ringing' then
            finish(call, 'missed')
        end
    end)

    return { id = call.id, contact = contactView(phone.number, number) }
end)

Register('answerCall', function(src, _, data)
    local call = calls[tonumber(data.id)]
    if not call or call.callee ~= src or call.state ~= 'ringing' then return false end
    call.state = 'active'
    call.startedAt = os.time()
    -- out of minutes: the network ends the call
    local left = Carrier and Carrier.CallSecondsLeft(call.callerIdentifier)
    if left then
        SetTimeout(math.max(1, left) * 1000, function()
            if calls[call.id] == call and call.state == 'active' then
                Notify(call.caller, { app = 'phone', title = 'Call ended', icon = 'fa-phone-slash', body = "You've run out of call minutes." })
                finish(call, 'answered')
            end
        end)
    end
    for _, s in ipairs({ call.caller, call.callee }) do
        Push(s, 'callAccepted', { id = call.id, channel = call.id })
    end
    return true
end)

Register('endCall', function(src, _, data)
    local call = calls[tonumber(data.id)]
    if not call or (call.caller ~= src and call.callee ~= src) then return false end
    local status = call.state == 'active' and 'answered' or (call.callee == src and 'declined' or 'missed')
    finish(call, status)
    return true
end)

Register('getRecents', function(_, phone)
    local rows = MySQL.query.await([[
        SELECT c.*, ct.name AS contact_name FROM opslabs_phone_calls c
        LEFT JOIN opslabs_phone_contacts ct ON ct.owner = ? AND ct.number = IF(c.caller = ?, c.callee, c.caller)
        WHERE c.caller = ? OR c.callee = ?
        ORDER BY c.id DESC LIMIT 100]], { phone.number, phone.number, phone.number, phone.number })
    local list = {}
    for _, r in ipairs(rows) do
        local outgoing = r.caller == phone.number
        list[#list + 1] = {
            id = r.id,
            number = outgoing and r.callee or r.caller,
            name = r.contact_name,
            outgoing = outgoing,
            status = r.status,
            duration = r.duration,
            time = r.created_at,
        }
    end
    return list
end)

Register('clearRecents', function(_, phone)
    MySQL.update.await('DELETE FROM opslabs_phone_calls WHERE caller = ? OR callee = ?', { phone.number, phone.number })
    return true
end)

-- opslabs-towers: losing signal drops the call (calls to emergency services aren't phone calls here)
AddEventHandler('opslabs-towers:changed', function(src, cov)
    if not cov or (cov.cell or 0) > 0 then return end
    local id = inCall[src]
    local call = id and calls[id]
    if not call then return end
    for _, s in ipairs({ call.caller, call.callee }) do
        if s then Notify(s, { app = 'phone', title = 'Call Failed', icon = 'fa-phone-slash', body = s == src and 'You lost signal.' or 'The other person lost signal.' }) end
    end
    finish(call, call.state == 'active' and 'answered' or 'missed')
end)
