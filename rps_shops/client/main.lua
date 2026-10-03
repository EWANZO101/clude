local spawnedPeds = {}
local targetZones = {}
local blips = {}

local uiOpen = false
local currentShop = nil
local currentBrand = nil

local function notify(brand, message, type)
    Bridge.Notify(message, type, brand and brand.Locale.ShopTitle)
end

local function buildProductImage(product)
    if product.image and product.image ~= '' then
        return product.image
    end

    return Bridge.GetItemImage(product.item)
end

local function openShop(shopId)
    if uiOpen then
        return
    end

    local shop, brand = Config.GetShop(shopId)

    if not shop then
        notify(nil, Config.DefaultLocale.InvalidShop, 'error')
        return
    end

    local payload = lib.callback.await(
        'rps_shops:server:getShopData',
        false,
        shopId
    )

    if not payload or not payload.success then
        notify(
            brand,
            payload and payload.message or brand.Locale.InvalidShop,
            'error'
        )
        return
    end

    local categories = {}

    for i = 1, #brand.Categories do
        categories[#categories + 1] = brand.Categories[i]
    end

    local products = {}

    for productId, productData in pairs(payload.products or {}) do
        local configured = brand.Products[productId]

        if configured then
            products[#products + 1] = {
                id = productId,
                item = configured.item,
                label = configured.label,
                description = configured.description,
                category = configured.category,
                price = productData.price,
                originalPrice = productData.originalPrice,
                onSale = productData.onSale,
                stock = productData.stock,
                unlimitedStock = productData.unlimitedStock,
                maxPerPurchase = configured.maxPerPurchase or 1,
                image = buildProductImage(configured)
            }
        end
    end

    table.sort(products, function(a, b)
        return a.label < b.label
    end)

    currentShop = shopId
    currentBrand = brand
    uiOpen = true

    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'open',
        data = {
            theme = brand.theme,
            shopId = shopId,
            shopLabel = shop.label,
            tagline = brand.UI.StoreTagline,
            footer = brand.UI.FooterText,
            accent = brand.UI.Accent,
            accentAlt = brand.UI.AccentAlt,
            showImages = brand.UI.ShowItemImages,
            priceBoard = brand.UI.PriceBoard,
            fuelBoard = brand.UI.FuelBoard,
            currencySymbol = Config.Currency.Symbol,
            currencyLabel = Config.Currency.Label,
            categories = categories,
            products = products
        }
    })
end

local function closeShop()
    if not uiOpen then
        return
    end

    uiOpen = false
    currentShop = nil
    currentBrand = nil

    SetNuiFocus(false, false)

    SendNUIMessage({
        action = 'close'
    })
end

local function playPurchaseAnimation()
    if not Config.PurchaseAnimation.Enabled then
        return
    end

    CreateThread(function()
        lib.requestAnimDict(Config.PurchaseAnimation.Dict)

        TaskPlayAnim(
            PlayerPedId(),
            Config.PurchaseAnimation.Dict,
            Config.PurchaseAnimation.Clip,
            8.0,
            -8.0,
            Config.PurchaseAnimation.Duration,
            49,
            0.0,
            false,
            false,
            false
        )

        Wait(Config.PurchaseAnimation.Duration)

        StopAnimTask(
            PlayerPedId(),
            Config.PurchaseAnimation.Dict,
            Config.PurchaseAnimation.Clip,
            1.0
        )
    end)
end

RegisterNUICallback('close', function(_, cb)
    closeShop()
    cb({ ok = true })
end)

RegisterNUICallback('purchase', function(data, cb)
    if not uiOpen or not currentShop then
        cb({
            success = false,
            message = Config.DefaultLocale.InvalidShop
        })
        return
    end

    local brand = currentBrand

    local result = lib.callback.await(
        'rps_shops:server:purchase',
        false,
        currentShop,
        data.cart
    )

    if not result then
        cb({
            success = false,
            message = brand.Locale.PurchaseFailed
        })
        return
    end

    if result.success then
        playPurchaseAnimation()

        notify(
            brand,
            result.message or brand.Locale.PurchaseFailed,
            'success'
        )
    else
        notify(
            brand,
            result.message or brand.Locale.PurchaseFailed,
            'error'
        )
    end

    cb(result)
end)

RegisterNetEvent(
    'rps_shops:client:stockUpdate',
    function(shopId, stock)

        if not uiOpen or currentShop ~= shopId then
            return
        end

        SendNUIMessage({
            action = 'stockUpdate',
            stock = stock
        })
    end
)

RegisterNetEvent(
    'rps_shops:client:notify',
    function(message, type, title)
        Bridge.Notify(message, type, title)
    end
)

local function spawnShopPed(shopId, shop, brand)
    if not shop.ped or not shop.ped.enabled then
        return
    end

    local model = joaat(shop.ped.model)

    lib.requestModel(model)

    local coords = shop.ped.coords

    local ped = CreatePed(
        0,
        model,
        coords.x,
        coords.y,
        coords.z - 1.0,
        coords.w,
        false,
        false
    )

    SetEntityAsMissionEntity(
        ped,
        true,
        true
    )

    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)

    if shop.ped.scenario
        and shop.ped.scenario ~= '' then

        TaskStartScenarioInPlace(
            ped,
            shop.ped.scenario,
            0,
            true
        )
    end

    Bridge.AddEntityTarget(
        ped,
        {
            {
                name = ('rps_shops:%s'):format(shopId),
                icon = brand.Target.Icon,
                label = brand.Target.Label,
                distance = Config.TargetDistance,

                onSelect = function()
                    openShop(shopId)
                end
            }
        },
        Config.TargetDistance
    )

    spawnedPeds[#spawnedPeds + 1] = ped

    SetModelAsNoLongerNeeded(model)
end

local function createShopZone(shopId, shop, brand)
    if not shop.zone or not shop.zone.enabled then
        return
    end

    local zoneName = ('rps_shops:zone:%s'):format(shopId)

    local id = Bridge.AddBoxZone(
        zoneName,
        shop.zone.coords,
        shop.zone.size,
        shop.zone.rotation or 0.0,
        {
            {
                name = zoneName,
                icon = brand.Target.Icon,
                label = brand.Target.Label,
                distance = Config.TargetDistance,

                onSelect = function()
                    openShop(shopId)
                end
            }
        },
        Config.TargetDistance
    )

    targetZones[#targetZones + 1] = id
end

local function createShopBlip(shop, brand)
    if not brand.Blip.Enabled then
        return
    end

    if not shop.blip
        or shop.blip.enabled == false then
        return
    end

    local blip = AddBlipForCoord(
        shop.coords.x,
        shop.coords.y,
        shop.coords.z
    )

    SetBlipSprite(
        blip,
        shop.blip.sprite or brand.Blip.Sprite
    )

    SetBlipColour(
        blip,
        shop.blip.colour or brand.Blip.Colour
    )

    SetBlipScale(
        blip,
        shop.blip.scale or brand.Blip.Scale
    )

    SetBlipAsShortRange(
        blip,
        brand.Blip.ShortRange
    )

    BeginTextCommandSetBlipName('STRING')

    AddTextComponentString(
        shop.blip.label or shop.label
    )

    EndTextCommandSetBlipName(blip)

    blips[#blips + 1] = blip
end

CreateThread(function()
    Bridge.WaitForTarget()

    for shopId in pairs(Config.Shops) do
        local shop, brand = Config.GetShop(shopId)

        if shop then
            spawnShopPed(shopId, shop, brand)
            createShopZone(shopId, shop, brand)
            createShopBlip(shop, brand)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    closeShop()

    for i = 1, #spawnedPeds do
        local ped = spawnedPeds[i]

        if DoesEntityExist(ped) then
            Bridge.RemoveEntityTarget(ped)
            DeleteEntity(ped)
        end
    end

    for i = 1, #targetZones do
        Bridge.RemoveZone(targetZones[i])
    end

    for i = 1, #blips do
        if DoesBlipExist(blips[i]) then
            RemoveBlip(blips[i])
        end
    end
end)
