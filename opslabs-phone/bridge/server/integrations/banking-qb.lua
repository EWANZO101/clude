-- qb-banking (QBCore's bank, new version). Experimental: from its source (server.lua), tested against fakes.
-- Job accounts are keyed by the job name.
local A = { label = 'qb-banking', resource = 'qb-banking', status = 'experimental', builtin = true }
local function qb() return exports['qb-banking'] end
local function job(society) return (society:gsub('^society_', '')) end

function A.AddSocietyMoney(society, amount) return qb():AddMoney(job(society), amount, 'OPS Phone') ~= false end

-- qb-banking's RemoveMoney doesn't check the balance: we do
function A.RemoveSocietyMoney(society, amount)
    if (tonumber(qb():GetAccountBalance(job(society))) or 0) < amount then return false end
    return qb():RemoveMoney(job(society), amount, 'OPS Phone') ~= false
end

-- a statement line on the player's checking account (online players only; reason is max 50 characters)
function A.LogTransaction(identifier, amount, label)
    local src = FW.SourceOf(identifier)
    if not src then return end
    qb():CreateBankStatement(src, 'checking', math.abs(amount), label:sub(1, 50), amount < 0 and 'withdraw' or 'deposit', 'player')
end

Bridge.RegisterIntegration('banking', 'qb-banking', A)
