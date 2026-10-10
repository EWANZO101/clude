-- okokBanking (paid resource). Experimental and partly unverified: written from okok's published export list —
-- the return values aren't documented, so a society withdrawal is only made when the balance can be read first.
-- Please report whether it works on your server.
local A = { label = 'okokBanking', resource = 'okokBanking', status = 'experimental', builtin = true }
local function ok() return exports['okokBanking'] end

local function balance(society)
    local a = ok():GetAccount(society)
    if type(a) == 'number' then return a end
    if type(a) == 'table' then return tonumber(a.value or a.money or a.balance) end
    return nil
end

-- the account must exist (AddMoney's return isn't documented): otherwise the money would be paid into nothing
function A.AddSocietyMoney(society, amount)
    if balance(society) == nil then return false end
    return ok():AddMoney(society, amount) ~= false
end

function A.RemoveSocietyMoney(society, amount)
    local have = balance(society)
    if not have or have < amount then return false end
    return ok():RemoveMoney(society, amount) ~= false
end

function A.LogTransaction(identifier, amount, label)
    ok():AddTransaction(identifier, {
        sender_identifier = amount < 0 and identifier or 'ops_phone', sender_name = amount < 0 and 'You' or label,
        receiver_identifier = amount < 0 and 'ops_phone' or identifier, receiver_name = amount < 0 and label or 'You',
        value = math.abs(amount), type = amount < 0 and 'withdraw' or 'deposit', reason = label,
    })
end

Bridge.RegisterIntegration('banking', 'okokBanking', A)
