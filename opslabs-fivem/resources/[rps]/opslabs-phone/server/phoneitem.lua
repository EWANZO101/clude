-- Phone items. Which phone item a player holds, whether it's theirs, and its number on the item (Config.Items,
-- Config.PhoneItemMetadata). Uses GetPhone (server/main.lua) and DockedPhoneOf (server/dock.lua) at call time.

-- phone items carry their number (Config.PhoneItemMetadata; inventories with item metadata, e.g. ox_inventory)
local function itemMetadata()
    local m = Config.PhoneItemMetadata
    return m and m.Enabled ~= false and FW.HasItemSlots()
end

--- writes this phone's number on a phone item, keeping whatever else the item carries (durability …)
local function stampPhone(src, s, phone)
    local m = {}
    for k, v in pairs(s.metadata or {}) do m[k] = v end
    m.phone_number = phone.number
    m.description = ('📱 %s · %s'):format(phone.number, phone.name)
    FW.SetItemMetadata(src, s.slot, m)
end

--- is a phone item stamped with `number` someone else's? (no: the number was changed or deleted since)
local function belongsToSomeoneElse(number, phone)
    local owner = MySQL.scalar.await('SELECT identifier FROM opslabs_phone_users WHERE phone_number = ?', { number })
    return owner ~= nil and owner ~= phone.identifier
end

--- the player's own phone item: item name, its metadata (nil without item metadata). For the wireless charger.
function OwnPhoneItem(src)
    if itemMetadata() then
        local phone = GetPhone(src)
        for item in pairs(Config.Items) do
            for _, s in ipairs(FW.GetItemSlots(src, item)) do
                local n = s.metadata and s.metadata.phone_number
                if phone and (n == phone.number or n == nil) then return item, n and s.metadata or nil end
            end
        end
        return nil
    end
    for item in pairs(Config.Items) do
        if FW.ItemCount(src, item) > 0 then return item end
    end
end

--- true, frame colour when the player holds their own phone. false, nil, number when the only phone they hold is
--- someone else's (Config.PhoneItemMetadata.Lock) — the number says whose.
function HasPhoneItem(src)
    if not Config.RequireItem then return true, 'black' end
    if not FW.Await() then return false end                         -- the bridge isn't ready: never fail open
    if not FW.HasInventory() then return true, 'black' end          -- no inventory at all: nothing to require
    local lockedTo
    if itemMetadata() then
        local phone = GetPhone(src)
        local lock = Config.PhoneItemMetadata.Lock ~= false
        for item, color in pairs(Config.Items) do
            for _, s in ipairs(FW.GetItemSlots(src, item)) do
                local n = s.metadata and s.metadata.phone_number
                if not phone or n == phone.number then return true, color end
                if not n then                                       -- a new phone: it's yours now
                    stampPhone(src, s, phone)
                    return true, color
                end
                if not lock then return true, color end
                if belongsToSomeoneElse(n, phone) then
                    lockedTo = lockedTo or n
                else                                                -- its number isn't anyone's any more
                    stampPhone(src, s, phone)
                    return true, color
                end
            end
        end
    else
        for item, color in pairs(Config.Items) do
            if FW.ItemCount(src, item) > 0 then return true, color end
        end
    end
    -- the phone is lying on a wireless charger (server/dock.lua): still yours, still rings
    local docked = DockedPhoneOf and DockedPhoneOf(src)
    if docked then return true, Config.Items[docked.item] or 'black' end
    return false, nil, lockedTo
end
