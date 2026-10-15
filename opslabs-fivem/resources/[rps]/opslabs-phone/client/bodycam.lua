-- Bodycam app: the camera itself is opslabs-bodycam (records, uploads, Xon Sight); the phone only shows its state and
-- starts / stops it. Without that resource the app is hidden (config.bodycam in server/main.lua).
local BC = 'opslabs-bodycam'
local function up() return GetResourceState(BC) == 'started' end

RegisterNUICallback('bodycamState', function(_, cb)
    if not up() then return cb({ access = { allowed = false, reason = 'not_allowed' } }) end
    local access = exports[BC]:CanUse() or {}
    cb({ state = exports[BC]:GetState(), access = { allowed = access.allowed == true, reason = access.reason } })
end)

RegisterNUICallback('bodycamToggle', function(_, cb)
    if not up() then return cb({}) end
    local was = exports[BC]:IsRecording()
    local ok = exports[BC]:Toggle()
    local r = { state = exports[BC]:GetState() }
    if not was and not ok then             -- refused: tell the app why
        local access = exports[BC]:CanUse() or {}
        r.access = { allowed = access.allowed == true, reason = access.reason }
    end
    cb(r)
end)

RegisterNUICallback('bodycamNote', function(body, cb)
    if not up() then return cb({ ok = false }) end
    cb({ ok = exports[BC]:SetNote(type(body) == 'table' and body.note or '') })
end)

RegisterNUICallback('bodycamRecent', function(_, cb) cb(up() and exports[BC]:GetRecent() or {}) end)
RegisterNUICallback('bodycamLive', function(_, cb) cb(up() and exports[BC]:GetLive() or {}) end)

AddEventHandler('opslabs-bodycam:state', function(s) SendNUIMessage({ action = 'bodycamState', data = s }) end)
AddEventHandler('opslabs-bodycam:uploadedPart', function(r) SendNUIMessage({ action = 'bodycamUploaded', data = r }) end)
