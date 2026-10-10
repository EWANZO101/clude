-- esx_billing (the `billing` table). Verified: read from the live server's esx_billing, which the phone has always
-- used. A society bill's money goes to its shared account (banking integration), a player's to that player — online
-- or offline. esx_billing:paidBill is fired like esx_billing does, for scripts that listen to it.

local A = { label = 'esx_billing', resource = 'esx_billing', status = 'verified', builtin = true, frameworks = { esx = true } }

function A.GetBills(identifier)
    return MySQL.query.await('SELECT id, label, amount, target FROM billing WHERE identifier = ? ORDER BY id DESC', { identifier }) or {}
end

-- removes the bill first, so two taps (or the phone and esx_billing's menu) can't pay it twice
function A.TakeBill(identifier, id)
    local bill = MySQL.single.await('SELECT * FROM billing WHERE id = ? AND identifier = ?', { tonumber(id), identifier })
    if not bill or (tonumber(bill.amount) or 0) <= 0 then return nil end
    if MySQL.update.await('DELETE FROM billing WHERE id = ? AND identifier = ?', { bill.id, identifier }) ~= 1 then return nil end
    return bill
end

function A.RestoreBill(bill)
    MySQL.insert.await('INSERT INTO billing (id, identifier, sender, target_type, target, label, amount) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { bill.id, bill.identifier, bill.sender, bill.target_type, bill.target, bill.label, bill.amount })
end

function A.SettleBill(bill, payer)
    if bill.target_type == 'player' then
        local src = FW.SourceOf(bill.sender)
        if src then FW.AddMoney(src, bill.amount, Config.Bank.Account, 'Bill paid') else FW.AddOfflineMoney(bill.sender, bill.amount, Config.Bank.Account) end
    else
        FW.AddSocietyMoney(bill.target, bill.amount)
    end
    if payer then TriggerEvent('esx_billing:paidBill', payer, bill.id) end
end

Bridge.RegisterIntegration('billing', 'esx_billing', A)
