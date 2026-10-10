-- ESX society accounts (esx_addonaccount). Verified: read from the live server's esx_addonaccount; the phone has
-- always used this. "police" and "society_police" both work.

local function getShared(name)
    local p = promise.new()
    TriggerEvent('esx_addonaccount:getSharedAccount', name, function(acc) p:resolve(acc or false) end)
    SetTimeout(3000, function() p:resolve(false) end)
    return Citizen.Await(p) or nil
end

local function shared(society)
    return getShared(society) or (not society:find('^society_') and getShared('society_' .. society)) or nil
end

local A = { label = 'esx_addonaccount', resource = 'esx_addonaccount', status = 'verified', builtin = true, frameworks = { esx = true } }

function A.AddSocietyMoney(society, amount)
    local acc = shared(society)
    if not acc then return false end
    acc.addMoney(amount)
    return true
end

-- esx_addonaccount's removeMoney doesn't check the balance: we do
function A.RemoveSocietyMoney(society, amount)
    local acc = shared(society)
    if not acc or (acc.money or 0) < amount then return false end
    acc.removeMoney(amount)
    return true
end

-- esx_banking keeps a statement (its `banking` table). Online: its logTransaction export (fills in the balance).
-- Offline: the same row it would write. TRANSFER shows as money out, TRANSFER_RECEIVE as money in.
function A.LogTransaction(identifier, amount, label)
    if not Bridge.Started('esx_banking') then return end
    local kind = amount < 0 and 'TRANSFER' or 'TRANSFER_RECEIVE'
    local src = FW.SourceOf(identifier)
    if src then
        exports.esx_banking:logTransaction(src, label, kind, math.abs(amount))
    else
        MySQL.insert('INSERT INTO banking (identifier, label, type, amount, time, balance) VALUES (?, ?, ?, ?, ?, ?)',
            { identifier, label, kind, math.abs(amount), os.time() * 1000, FW.GetOfflineMoney(identifier, 'bank') or 0 })
    end
end

Bridge.RegisterIntegration('banking', 'esx_addonaccount', A)
