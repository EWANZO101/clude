-- server/phoneitem.lua: phone items carry their number; someone else's phone is locked (Config.PhoneItemMetadata)
local F = dofile(H_ROOT .. '/bridge/tests/fakes.lua')

-- ox_inventory with slots: Search(src, 'slots', item) / SetMetadata(src, slot, md) / RemoveItem(.., metadata)
local function oxSlots(H, slots)
    H.resources.ox_inventory = 'started'
    H.exportsOf.ox_inventory = {
        GetItemCount = function(_, src, item) local n = 0 for _, s in ipairs(slots) do if s.name == item then n = n + 1 end end return n end,
        Search = function(_, src, kind, item) local out = {} for _, s in ipairs(slots) do if s.name == item then out[#out + 1] = s end end return out end,
        SetMetadata = function(_, src, slot, md) for _, s in ipairs(slots) do if s.slot == slot then s.metadata = md end end end,
        RemoveItem = function(_, src, item, n, md)
            for i, s in ipairs(slots) do
                if s.name == item and (not md or (s.metadata or {}).phone_number == md.phone_number) then table.remove(slots, i) return true end
            end
            return false
        end,
    }
end

local function phoneServer(slots, owners, extra)
    return boot(function(H)
        F.esx(H)
        oxSlots(H, slots)
        Config.Items = { phone = 'black', phone_blue = 'ultramarine' }
        Config.PhoneItemMetadata = { Enabled = true, Lock = true }
        _G.GetPhone = function(src) return src == 1 and { number = '555-0001', identifier = 'me', name = 'Me Myself' } or nil end
        _G.DockedPhoneOf = function() return nil end
        H.sqlHandler = function(kind, q, params) if q:find('SELECT identifier FROM opslabs_phone_users WHERE phone_number') then return owners[params[1]] end end
        if extra then extra(H) end
    end, nil, { 'server/phoneitem.lua' })
end

test('phone item: a new phone is stamped with your number and name, keeping its other metadata', function()
    local slots = { { slot = 3, name = 'phone_blue', metadata = { durability = 80 } } }
    local H = phoneServer(slots, {})
    local ok_, color = H.call(function() return HasPhoneItem(1) end)
    eq(ok_, true, 'opens') eq(color, 'ultramarine', 'colour from the item')
    eq(slots[1].metadata.phone_number, '555-0001', 'number stamped')
    ok(slots[1].metadata.description:find('555%-0001 · Me Myself'), 'tooltip')
    eq(slots[1].metadata.durability, 80, 'durability kept')
end)

test("phone item: someone else's phone is locked and says whose it is", function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0199' } } }
    local H = phoneServer(slots, { ['555-0199'] = 'lamar' })
    local ok_, _, locked = H.call(function() return HasPhoneItem(1) end)
    eq(ok_, false, 'locked') eq(locked, '555-0199', 'whose')
    eq(slots[1].metadata.phone_number, '555-0199', 'not re-stamped')
end)

test("phone item: holding your own phone and someone else's opens yours", function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0199' } }, { slot = 2, name = 'phone_blue', metadata = { phone_number = '555-0001' } } }
    local H = phoneServer(slots, { ['555-0199'] = 'lamar' })
    eq(H.call(function() return HasPhoneItem(1) end), true, 'opens')
end)

test('phone item: a phone whose number no longer belongs to anyone is re-stamped, not locked', function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0777' } } }
    local H = phoneServer(slots, {})
    eq(H.call(function() return HasPhoneItem(1) end), true, 'opens')
    eq(slots[1].metadata.phone_number, '555-0001', 're-stamped')
end)

test('phone item: Lock = false — any phone opens your own, stamps untouched', function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0199' } } }
    local H = phoneServer(slots, { ['555-0199'] = 'lamar' }, function() Config.PhoneItemMetadata.Lock = false end)
    eq(H.call(function() return HasPhoneItem(1) end), true, 'opens')
    eq(slots[1].metadata.phone_number, '555-0199', 'left alone')
end)

test('phone item: metadata off, or an inventory without item metadata — any phone item, as before', function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0199' } } }
    local H = phoneServer(slots, { ['555-0199'] = 'lamar' }, function() Config.PhoneItemMetadata.Enabled = false end)
    eq(H.call(function() return HasPhoneItem(1) end), true, 'metadata off')

    H = boot(function(H)
        F.qb(H)
        H.resources['qb-inventory'] = 'started'
        H.exportsOf['qb-inventory'] = { GetItemCount = function(_, src, item) return item == 'phone' and 1 or 0 end }
        Config.Items = { phone = 'black' }
        Config.PhoneItemMetadata = { Enabled = true, Lock = true }
        _G.GetPhone = function() return { number = '1', identifier = 'x', name = 'n' } end
        _G.DockedPhoneOf = function() return nil end
    end, nil, { 'server/phoneitem.lua' })
    eq(FW.HasItemSlots(), false, 'qb-inventory: no slot metadata')
    eq(H.call(function() return HasPhoneItem(1) end), true, 'count-based')
end)

test('phone item: the charger takes your own phone (with its number), never one you picked up', function()
    local slots = { { slot = 1, name = 'phone', metadata = { phone_number = '555-0199' } }, { slot = 2, name = 'phone_blue', metadata = { phone_number = '555-0001', durability = 50 } } }
    local H = phoneServer(slots, { ['555-0199'] = 'lamar' })
    local item, md = H.call(function() return OwnPhoneItem(1) end)
    eq(item, 'phone_blue', 'own phone') eq(md.durability, 50, 'its metadata')
    eq(H.call(function() return FW.RemoveItem(1, item, 1, { phone_number = md.phone_number }) end), true, 'removed that one')
    eq(slots[1].metadata.phone_number, '555-0199', "the other's phone stays")
end)
