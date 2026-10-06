-- stock[shopId][productId] = number | false (unlimited)
local stock = {}

local function productAllowedInShop(shop, productId, product)
    if not product.enabled then
        return false
    end

    if shop.productIds then
        local found = false

        for i = 1, #shop.productIds do
            if shop.productIds[i] == productId then
                found = true
                break
            end
        end

        if not found then
            return false
        end
    end

    if shop.categoryIds then
        local found = false

        for i = 1, #shop.categoryIds do
            if shop.categoryIds[i] == product.category then
                found = true
                break
            end
        end

        if not found then
            return false
        end
    end

    return true
end

local function getProductPrice(shop, product)
    local basePrice =
        product.salePrice
        and tonumber(product.salePrice)
        or tonumber(product.price)

    local multiplier =
        tonumber(shop.priceMultiplier)
        or 1.0

    return math.max(
        0,
        math.floor(
            (basePrice * multiplier) + 0.5
        )
    )
end

local function getOriginalPrice(shop, product)
    local multiplier =
        tonumber(shop.priceMultiplier)
        or 1.0

    return math.max(
        0,
        math.floor(
            ((tonumber(product.price) or 0) * multiplier) + 0.5
        )
    )
end

local function getShopStock(shopId, productId)
    if not Config.Stock.Enabled then
        return false
    end

    if stock[shopId]
        and stock[shopId][productId] ~= nil then

        return stock[shopId][productId]
    end

    return false
end

local function setShopStock(shopId, productId, amount)
    stock[shopId] = stock[shopId] or {}
    stock[shopId][productId] = amount
end

local function buildStockPayload(shopId, brand)
    local payload = {}

    for productId, product in pairs(brand.Products) do
        if product.stock == false
            or not Config.Stock.Enabled then

            payload[productId] = false
        else
            payload[productId] =
                getShopStock(
                    shopId,
                    productId
                )
        end
    end

    return payload
end

local function broadcastStock(shopId, brand)
    TriggerClientEvent(
        'rps_shops:client:stockUpdate',
        -1,
        shopId,
        buildStockPayload(shopId, brand)
    )
end

--- Calls fn(shopId, shop, brand) for every enabled shop, optionally only one brand.
local function forEachShop(brandId, fn)
    for shopId in pairs(Config.Shops) do
        local shop, brand = Config.GetShop(shopId)

        if shop and (not brandId or brand.id == brandId) then
            fn(shopId, shop, brand)
        end
    end
end

--- Resets stock to the configured maximums (all brands, or just brandId).
local function initializeStock(brandId)
    forEachShop(brandId, function(shopId, shop, brand)
        stock[shopId] = {}

        for productId, product in pairs(brand.Products) do
            if productAllowedInShop(
                shop,
                productId,
                product
            ) then

                if Config.Stock.Enabled
                    and product.stock ~= false then

                    stock[shopId][productId] =
                        math.max(
                            0,
                            math.floor(
                                tonumber(product.stock) or 0
                            )
                        )
                else
                    stock[shopId][productId] = false
                end
            end
        end
    end)
end

local function playerNearShop(source, shop, brand)
    local ped = GetPlayerPed(source)

    if ped == 0 then
        return false
    end

    local playerCoords =
        GetEntityCoords(ped)

    return #(
        playerCoords - shop.coords
    ) <= brand.Security.MaxServerDistance
end

local function buildShopProducts(shopId, shop, brand)
    local products = {}

    for productId, product in pairs(brand.Products) do
        if productAllowedInShop(
            shop,
            productId,
            product
        ) then

            local currentStock =
                getShopStock(
                    shopId,
                    productId
                )

            products[productId] = {
                price = getProductPrice(
                    shop,
                    product
                ),

                originalPrice =
                    getOriginalPrice(
                        shop,
                        product
                    ),

                onSale =
                    product.salePrice ~= false
                    and product.salePrice ~= nil,

                stock =
                    currentStock == false
                    and 0
                    or currentStock,

                unlimitedStock =
                    currentStock == false
            }
        end
    end

    return products
end

lib.callback.register(
    'rps_shops:server:getShopData',
    function(source, shopId)

        local shop, brand = Config.GetShop(shopId)

        if not shop then
            return {
                success = false,
                message = Config.DefaultLocale.InvalidShop
            }
        end

        if not playerNearShop(
            source,
            shop,
            brand
        ) then

            return {
                success = false,
                message = brand.Locale.TooFar
            }
        end

        return {
            success = true,
            products =
                buildShopProducts(
                    shopId,
                    shop,
                    brand
                )
        }
    end
)

local function buildValidatedCart(
    shopId,
    shop,
    brand,
    rawCart
)
    local locale = brand.Locale
    local security = brand.Security

    if type(rawCart) ~= 'table' then
        return nil,
            locale.InvalidCart
    end

    local validated = {}

    local differentItems = 0
    local totalUnits = 0
    local totalPrice = 0

    for i = 1, #rawCart do
        local entry = rawCart[i]

        if type(entry) ~= 'table'
            or type(entry.id) ~= 'string' then

            return nil,
                locale.InvalidCart
        end

        local productId =
            entry.id

        local quantity =
            math.floor(
                tonumber(entry.quantity)
                or 0
            )

        local product =
            brand.Products[productId]

        if not product
            or not productAllowedInShop(
                shop,
                productId,
                product
            ) then

            return nil,
                locale.InvalidCart
        end

        local maxPerPurchase =
            math.max(
                1,
                math.floor(
                    tonumber(
                        product.maxPerPurchase
                    )
                    or 1
                )
            )

        if quantity < 1
            or quantity > maxPerPurchase then

            return nil,
                locale.InvalidCart
        end

        differentItems =
            differentItems + 1

        totalUnits =
            totalUnits + quantity

        if differentItems
            > security.MaxDifferentItemsPerPurchase
            or totalUnits
            > security.MaxTotalUnitsPerPurchase then

            return nil,
                locale.InvalidCart
        end

        local currentStock =
            getShopStock(
                shopId,
                productId
            )

        if currentStock ~= false
            and quantity > currentStock then

            return nil,
                locale.OutOfStock
                    :format(
                        product.label
                    )
        end

        local unitPrice =
            getProductPrice(
                shop,
                product
            )

        totalPrice =
            totalPrice
            + (unitPrice * quantity)

        validated[#validated + 1] = {
            id = productId,
            item = product.item,
            label = product.label,
            quantity = quantity,
            unitPrice = unitPrice,
            metadata = product.metadata
        }
    end

    if #validated == 0 then
        return nil,
            locale.InvalidCart
    end

    return {
        items = validated,
        total = totalPrice,
        totalUnits = totalUnits
    }
end

local function canCarryCart(
    source,
    cart
)
    for i = 1, #cart.items do
        local item = cart.items[i]

        if not Bridge.CanCarryItem(
            source,
            item.item,
            item.quantity
        ) then
            return false
        end
    end

    return true
end

local function opsPos()
    return GetResourceState('opslabs-pos') == 'started'
end

local function refundCurrency(
    source,
    amount
)
    if amount <= 0 then
        return
    end

    Bridge.AddCurrency(
        source,
        amount
    )
end

local function rollbackAddedItems(
    source,
    addedItems
)
    for i = 1, #addedItems do
        local added =
            addedItems[i]

        Bridge.RemoveItem(
            source,
            added.item,
            added.quantity,
            added.metadata
        )
    end
end

lib.callback.register(
    'rps_shops:server:purchase',
    function(
        source,
        shopId,
        rawCart
    )
        local shop, brand =
            Config.GetShop(shopId)

        if not shop then
            return {
                success = false,
                message =
                    Config.DefaultLocale.InvalidShop
            }
        end

        local locale = brand.Locale

        if not playerNearShop(
            source,
            shop,
            brand
        ) then
            return {
                success = false,
                message =
                    locale.TooFar
            }
        end

        local cart, cartError =
            buildValidatedCart(
                shopId,
                shop,
                brand,
                rawCart
            )

        if not cart then
            return {
                success = false,
                message =
                    cartError
                    or locale.InvalidCart
            }
        end

        if not canCarryCart(
            source,
            cart
        ) then
            return {
                success = false,
                message =
                    locale.InventoryFull
            }
        end

        local currencyCount =
            Bridge.GetCurrency(
                source
            )

        -- OPS POS (opslabs-pos): a shop run from an OPS POS till with a card reader takes card / phone payments
        -- when the customer is short of cash
        local paidByCard = false

        if currencyCount
            < cart.total
            and opsPos() then

            local ok, paid = pcall(function()
                return exports['opslabs-pos']:NpcCardPay(
                    source,
                    shopId,
                    shop.label,
                    shop.coords,
                    cart.total,
                    cart.items
                )
            end)

            paidByCard =
                ok and paid == true
        end

        if not paidByCard then
            if currencyCount
                < cart.total then

                return {
                    success = false,
                    message =
                        locale.NoMoney
                            :format(
                                Config.Currency.Label
                            )
                }
            end

            local removed =
                Bridge.RemoveCurrency(
                    source,
                    cart.total
                )

            if not removed then
                return {
                    success = false,
                    message =
                        locale.NoMoney
                            :format(
                                Config.Currency.Label
                            )
                }
            end
        end

        local addedItems = {}

        for i = 1, #cart.items do
            local item =
                cart.items[i]

            local success =
                Bridge.AddItem(
                    source,
                    item.item,
                    item.quantity,
                    item.metadata
                )

            if not success then
                rollbackAddedItems(
                    source,
                    addedItems
                )

                if paidByCard then
                    pcall(function()
                        exports['opslabs-pos']:NpcCardRefund(
                            source,
                            cart.total
                        )
                    end)
                else
                    refundCurrency(
                        source,
                        cart.total
                    )
                end

                return {
                    success = false,
                    message =
                        locale.InventoryFull
                }
            end

            addedItems[#addedItems + 1] = {
                item = item.item,
                quantity = item.quantity,
                metadata = item.metadata
            }
        end

        -- Only reduce stock after the complete transaction succeeded.
        if Config.Stock.Enabled then
            for i = 1, #cart.items do
                local item =
                    cart.items[i]

                local current =
                    getShopStock(
                        shopId,
                        item.id
                    )

                if current ~= false then
                    setShopStock(
                        shopId,
                        item.id,
                        math.max(
                            0,
                            current
                            - item.quantity
                        )
                    )
                end
            end
        end

        if brand.Receipt.Enabled then
            local receiptMetadata = {
                label = locale.ReceiptLabel,
                shop = shop.label,
                total = cart.total,
                purchased = os.date(
                    '%Y-%m-%d %H:%M:%S'
                )
            }

            if Bridge.CanCarryItem(
                source,
                brand.Receipt.Item,
                1
            ) then
                Bridge.AddItem(
                    source,
                    brand.Receipt.Item,
                    1,
                    receiptMetadata
                )
            end
        end

        -- OPS POS: the takings go to the business whose till runs this shop
        if opsPos() then
            pcall(function()
                exports['opslabs-pos']:NpcSale(
                    source,
                    shopId,
                    shop.label,
                    shop.coords,
                    cart,
                    paidByCard and 'card' or 'cash'
                )
            end)
        end

        local stockPayload =
            buildStockPayload(
                shopId,
                brand
            )

        TriggerClientEvent(
            'rps_shops:client:stockUpdate',
            -1,
            shopId,
            stockPayload
        )

        return {
            success = true,

            message =
                locale.PurchaseComplete
                    :format(
                        Config.Currency.Symbol,
                        cart.total
                    ),

            stock =
                stockPayload,

            total =
                cart.total
        }
    end
)

local function restockBrand(brandId)
    if not Config.Stock.Enabled then
        return
    end

    forEachShop(brandId, function(shopId, shop, brand)
        for productId, product in pairs(brand.Products) do
            if productAllowedInShop(
                shop,
                productId,
                product
            )
                and product.stock ~= false then

                local maximum =
                    math.max(
                        0,
                        math.floor(
                            tonumber(product.stock)
                            or 0
                        )
                    )

                local current =
                    getShopStock(
                        shopId,
                        productId
                    )

                local add =
                    math.max(
                        1,
                        math.ceil(
                            maximum
                            * Config.Stock.RestockPercent
                        )
                    )

                setShopStock(
                    shopId,
                    productId,
                    math.min(
                        maximum,
                        (current or 0) + add
                    )
                )
            end
        end

        broadcastStock(shopId, brand)
    end)
end

CreateThread(function()
    initializeStock()

    if not Config.Stock.AutoRestock then
        return
    end

    -- One restock timer per brand, so each chain keeps its own RestockMinutes.
    for brandId, brand in pairs(Config.Brands) do
        if brand.enabled ~= false then
            CreateThread(function()
                while true do
                    Wait(
                        math.max(
                            1,
                            brand.Stock.RestockMinutes
                        )
                        * 60000
                    )

                    restockBrand(brandId)
                end
            end)
        end
    end
end)

--- Resets stock for one brand (or all when brandId is nil) and tells the caller.
local function runRestockCommand(source, brandId, acePermission)
    if source ~= 0
        and not IsPlayerAceAllowed(
            source,
            acePermission
        )
        and not IsPlayerAceAllowed(
            source,
            Config.Admin.AcePermission
        ) then
        return
    end

    initializeStock(brandId)

    forEachShop(brandId, function(shopId, _, brand)
        broadcastStock(shopId, brand)
    end)

    local brand = brandId and Config.Brands[brandId]

    if source ~= 0 then
        Bridge.Notify(
            source,
            brand and brand.Locale.Restocked or 'All shops have been restocked.',
            'success',
            brand and brand.Locale.ShopTitle
        )
    end

    print(
        ('^2[rps_shops]^7 Stock reset to configured maximums (%s).'):format(
            brandId or 'all brands'
        )
    )
end

-- /restockshops           -> every brand
-- /restockshops youtool   -> one brand (id from config/brands)
RegisterCommand(
    Config.Admin.RestockCommand,
    function(source, args)
        local brandId = args[1]

        if brandId and not Config.Brands[brandId] then
            if source == 0 then
                print(('^1[rps_shops]^7 Unknown brand "%s".'):format(brandId))
            end
            return
        end

        runRestockCommand(
            source,
            brandId,
            brandId and Config.Brands[brandId].Admin
                and Config.Brands[brandId].Admin.AcePermission
                or Config.Admin.AcePermission
        )
    end,
    false
)

-- Each brand keeps its old restock command (e.g. /restock247, /restockyoutool).
for brandId, brand in pairs(Config.Brands) do
    if brand.enabled ~= false
        and brand.Admin
        and brand.Admin.RestockCommand then

        RegisterCommand(
            brand.Admin.RestockCommand,
            function(source)
                runRestockCommand(
                    source,
                    brandId,
                    brand.Admin.AcePermission or Config.Admin.AcePermission
                )
            end,
            false
        )
    end
end
