-- Voice calls. Audio is routed through pma-voice call channels; the server
-- owns call state so neither side can join a channel it wasn't invited to.
-- Calls to and from OPS Hub lines (server/voip.lua) have no player on the Hub end: call.hub = { bridgeId, line, label }
-- and the audio goes through the OPS Voice bridge instead of a pma-voice channel.

local calls = {}      -- [callId] = { id, caller, callee, callerNumber, calleeNumber, state, startedAt, logId, hub? }
local inCall = {}     -- [source] = callId
local nextCallId = 1000

local function contactView(owner, number)
    return { number = number, name = ContactName(owner, number) }
end

--- the players on a call (an OPS Hub end has no player, so caller or callee can be nil)
local function players(call)
    local list = {}
    if call.caller then list[#list + 1] = call.caller end
    if call.callee then list[#list + 1] = call.callee end
    return list
end

--- can `target` take a call to `number` from `fromNumber` right now?
local function canRing(target, number, fromNumber)
    return target and not inCall[target] and HasPhoneItem(target) and not (PhoneDead and PhoneDead(target))
        and not (Phones[target].settings.airplane) and not IsBlocked(number, fromNumber)
        and (not Carrier or Carrier.HasService(Phones[target].identifier))
        and not (Carrier and Carrier.Network(target) and (Carrier.Network(target).cell or 0) <= 0)
end

local function finish(call, status)
    if not call or call.ended then return end
    call.ended = true

    local duration = call.startedAt and (os.time() - call.startedAt) or 0
    if call.voice then FW.VoiceCallEnded(call.id, players(call)) end
    if call.logId then
        MySQL.update('UPDATE opslabs_phone_calls SET status = ?, duration = ? WHERE id = ?', { status, duration, call.logId })
    end

    Emit('call.ended', { from = call.callerNumber, to = call.calleeNumber, status = status, duration = duration })
    if call.hub and not call.hub.quiet and Voip then Voip.Ended(call.hub.bridgeId, status) end
    -- minutes count against the caller's plan
    if Carrier and duration > 0 and call.callerIdentifier then Carrier.Record(call.callerIdentifier, 'call', duration) end

    for _, src in ipairs(players(call)) do
        inCall[src] = nil
        Push(src, 'callEnded', { id = call.id, status = status, duration = duration })
    end

    if status == 'missed' and call.callee then
        Notify(call.callee, {
            app = 'phone', title = 'Missed Call', icon = 'fa-phone-slash',
            body = ContactName(call.calleeNumber, call.callerNumber) or (call.hub and call.hub.label) or call.callerNumber,
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

    calls[call.id] = call
    inCall[src] = call.id

    -- an OPS Hub line: the bridge rings the softphones that have it open (nobody there: it rings out like any phone)
    local line = Voip and Voip.Line(number)
    if line then
        call.hub = { line = number, label = line.label }
        Voip.Incoming(call, phone)
        SetTimeout(Config.Calls.RingTimeout * 1000, function()
            if calls[call.id] == call and call.state == 'ringing' then finish(call, 'missed') end
        end)
        return { id = call.id, contact = { number = number, name = ContactName(phone.number, number) or line.label } }
    end

    local target = GetSourceByNumber(number)
    local reachable = canRing(target, number, phone.number)

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
    -- out of minutes: the network ends the call (an OPS Hub caller has no plan)
    local left = Carrier and call.callerIdentifier and Carrier.CallSecondsLeft(call.callerIdentifier)
    if left then
        SetTimeout(math.max(1, left) * 1000, function()
            if calls[call.id] == call and call.state == 'active' then
                Notify(call.caller, { app = 'phone', title = 'Call ended', icon = 'fa-phone-slash', body = "You've run out of call minutes." })
                finish(call, 'answered')
            end
        end)
    end
    if call.hub then
        -- a call from OPS Hub: the bridge listens in this player's own voice channel, the Hub caller plays on the phone
        Voip.Answered(call.hub.bridgeId, src)
        Push(src, 'callAccepted', { id = call.id, channel = 0, voip = Voip.Playback(call.hub.bridgeId) })
        return true
    end
    call.voice = true
    FW.VoiceCallStarted(call.id, { call.caller, call.callee })   -- voice systems that connect calls on the server (SaltyChat, YaCA)
    for _, s in ipairs({ call.caller, call.callee }) do
        -- peer: the other phone's server id, for voice systems that connect two players instead of a channel
        Push(s, 'callAccepted', { id = call.id, channel = call.id, peer = s == call.caller and call.callee or call.caller })
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
    for _, s in ipairs(players(call)) do
        Notify(s, { app = 'phone', title = 'Call Failed', icon = 'fa-phone-slash', body = s == src and 'You lost signal.' or 'The other person lost signal.' })
    end
    finish(call, call.state == 'active' and 'answered' or 'missed')
end)

---------------------------------------------------------------------------
-- OPS Hub end of a call (server/voip.lua: the bridge's REST routes)
---------------------------------------------------------------------------
HubCalls = {}

--- OPS Hub dials a player. Returns the call, or nil + error ('no_number').
function HubCalls.Dial(bridgeId, fromLine, label, to)
    local number = NormalizeNumber(to)
    if number == '' then return nil, 'no_number' end
    if not MySQL.scalar.await('SELECT 1 FROM opslabs_phone_users WHERE phone_number = ?', { number }) then return nil, 'no_number' end

    local logId = MySQL.insert.await('INSERT INTO opslabs_phone_calls (caller, callee, status) VALUES (?, ?, ?)', { fromLine, number, 'missed' })
    nextCallId = nextCallId + 1
    local call = {
        id = nextCallId, callerNumber = fromLine, calleeNumber = number, state = 'ringing', logId = logId,
        hub = { bridgeId = bridgeId, line = fromLine, label = label },
    }
    calls[call.id] = call

    local target = GetSourceByNumber(number)
    if canRing(target, number, fromLine) then
        call.callee = target
        inCall[target] = call.id
        Push(target, 'incomingCall', { id = call.id, number = fromLine, name = ContactName(number, fromLine) or label })
    end
    SetTimeout(Config.Calls.RingTimeout * 1000, function()
        if calls[call.id] == call and call.state == 'ringing' then finish(call, 'missed') end
    end)
    return call
end

--- a Hub user answered a player's call to a Hub line: returns the caller's server id
function HubCalls.Answer(id, bridgeId)
    local call = calls[tonumber(id)]
    if not call or not call.hub or call.hub.bridgeId ~= bridgeId or call.state ~= 'ringing' or not call.caller then return nil end
    call.state = 'active'
    call.startedAt = os.time()
    local left = Carrier and Carrier.CallSecondsLeft(call.callerIdentifier)
    if left then
        SetTimeout(math.max(1, left) * 1000, function()
            if calls[call.id] == call and call.state == 'active' then
                Notify(call.caller, { app = 'phone', title = 'Call ended', icon = 'fa-phone-slash', body = "You've run out of call minutes." })
                finish(call, 'answered')
            end
        end)
    end
    Push(call.caller, 'callAccepted', { id = call.id, channel = 0, voip = Voip.Playback(bridgeId) })
    return call.caller
end

--- the Hub end hung up / declined / gave up (the bridge already knows)
function HubCalls.End(id, bridgeId, reason)
    local call = calls[tonumber(id)]
    if not call or not call.hub or call.hub.bridgeId ~= bridgeId then return false end
    call.hub.quiet = true
    local status = call.state == 'active' and 'answered' or (reason == 'declined' and 'declined' or 'missed')
    finish(call, status)
    return true
end

--- the bridge (re)started and knows no calls: end every call with an OPS Hub end, so nobody is left "on a call"
function HubCalls.Reset()
    local n = 0
    for _, call in pairs(calls) do
        if call.hub then
            call.hub.quiet = true
            finish(call, call.state == 'active' and 'answered' or 'missed')
            n = n + 1
        end
    end
    return n
end

--- the bridge couldn't ring anyone, or answered: remember its id for the call
function HubCalls.SetBridge(id, bridgeId)
    local call = calls[tonumber(id)]
    if call and call.hub then call.hub.bridgeId = bridgeId end
    return call
end
