-- Renewed-Banking (Qbox's default bank). Experimental: from its source (server/main.lua), tested against fakes.
-- Job accounts are keyed by the job name ('police', not 'society_police').
local A = { label = 'Renewed-Banking', resource = 'Renewed-Banking', status = 'experimental', builtin = true }
local function rb() return exports['Renewed-Banking'] end
local function job(society) return (society:gsub('^society_', '')) end

function A.AddSocietyMoney(society, amount) return rb():addAccountMoney(job(society), amount) == true end
-- removeAccountMoney refuses when the account is short
function A.RemoveSocietyMoney(society, amount) return rb():removeAccountMoney(job(society), amount) == true end

-- the bank's own history (moves no money). Renewed-Banking only keeps it for players who are loaded.
function A.LogTransaction(identifier, amount, label)
    if not FW.SourceOf(identifier) then return end
    rb():handleTransaction(identifier, label, math.abs(amount), label, 'OPS Phone', amount < 0 and label or 'You',
        amount < 0 and 'withdraw' or 'deposit')
end

Bridge.RegisterIntegration('banking', 'Renewed-Banking', A)
