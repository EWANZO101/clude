-- Your own integration (server): a bank, billing, garage or housing resource the phone doesn't know yet.
-- Files in bridge/custom/server/ load automatically. Does nothing until ENABLED = true. See bridge/README.md.
-- Then select it in config.lua: Config.Integrations.billing = 'my_billing' (or leave 'auto': it's picked when its
-- resource runs, before the built-in ones).

local ENABLED = false
if not ENABLED then return end

-- Billing: the Wallet's bills
Bridge.RegisterIntegration('billing', 'my_billing', {
    label = 'My Billing',
    resource = 'my_billing',              -- detected when this resource runs
    -- frameworks = { qb = true },        -- optional: only on these frameworks

    -- { { id, label, amount, target } } — unpaid bills of a character (identifier = FW.Identifier)
    GetBills = function(identifier)
        return MySQL.query.await('SELECT id, label, amount, society AS target FROM my_bills WHERE citizen = ? AND paid = 0', { identifier })
    end,
    -- mark it paid FIRST and return it (nil if it's gone): this is what stops a bill being paid twice
    TakeBill = function(identifier, id)
        local bill = MySQL.single.await('SELECT * FROM my_bills WHERE id = ? AND citizen = ? AND paid = 0', { id, identifier })
        if not bill or MySQL.update.await('UPDATE my_bills SET paid = 1 WHERE id = ? AND paid = 0', { id }) ~= 1 then return nil end
        return bill
    end,
    -- the player couldn't pay after all: undo TakeBill
    RestoreBill = function(bill) MySQL.update.await('UPDATE my_bills SET paid = 0 WHERE id = ?', { bill.id }) end,
    -- the money was taken from the payer (server id `payer`): give it to whoever is owed
    SettleBill = function(bill, payer) FW.AddSocietyMoney(bill.society, bill.amount) end,
})

-- Other kinds, same pattern:
--   banking: AddSocietyMoney(society, amount), RemoveSocietyMoney(society, amount) (refuse an overdraft),
--            LogTransaction(identifier, amount, label)   (optional: the bank's own statement; amount < 0 = out)
--   garage:  GetVehicles(identifier) -> { { plate, model (hash), name, stored, parking, pound, fuel, engine, body } }
--   housing: GetHomes(identifier) -> { { id, label, x, y, z, kind = 'owned' | 'rented' | 'key' } }
--   voice:   a new file in bridge/voice/ (loaded on server and client, so the server can detect it) — copy
--            bridge/voice/pma-voice.lua
