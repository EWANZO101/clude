-- ox_core invoices (accounts_invoices). Experimental: from ox_core's source (sql/install.sql, server/accounts), tested
-- against fakes. An invoice is sent FROM the issuer's account (which receives the money) TO the billed account;
-- unpaid = payerId IS NULL. Paying goes through ox_core itself (PayAccountInvoice: one database transaction that moves
-- the money and marks it paid), so the phone never moves invoice money on its own.

local A = { label = 'ox_core invoices', resource = 'ox_core', status = 'experimental', builtin = true, frameworks = { ox = true } }

function A.GetBills(identifier)
    return MySQL.query.await([[SELECT i.id, i.message AS label, i.amount, f.label AS target
        FROM accounts_invoices i JOIN accounts a ON a.id = i.toAccount LEFT JOIN accounts f ON f.id = i.fromAccount
        WHERE a.owner = ? AND a.isDefault = 1 AND i.payerId IS NULL ORDER BY i.id DESC]], { tonumber(identifier) }) or {}
end

local ERRORS = { no_balance = 'Insufficient funds', invoice_paid = 'Bill already paid', no_invoice = 'Bill not found',
    no_permission = "You can't pay bills from this account" }

function A.PayBill(src, identifier, id)
    local bill = MySQL.single.await([[SELECT i.id, i.message AS label, i.amount FROM accounts_invoices i JOIN accounts a ON a.id = i.toAccount
        WHERE i.id = ? AND a.owner = ? AND i.payerId IS NULL]], { tonumber(id), tonumber(identifier) })
    if not bill then return nil, 'Bill not found or already paid' end
    local r = exports.ox_core:PayAccountInvoice(bill.id, tonumber(identifier))
    if not r or not r.success then return nil, ERRORS[r and r.message] or 'Could not pay the bill' end
    return bill
end

Bridge.RegisterIntegration('billing', 'ox_core', A)
