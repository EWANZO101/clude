-- Runs after every config file. Fills in brand defaults and flattens every
-- brand's Locations into Config.Shops (shopId -> shop, with shop.brand = brandId).

Config.Shops = {}

for brandId, brand in pairs(Config.Brands) do
    brand.id = brandId
    brand.theme = brand.theme or brandId

    brand.Locale = brand.Locale or {}
    for key, text in pairs(Config.DefaultLocale) do
        if brand.Locale[key] == nil then
            brand.Locale[key] = text
        end
    end

    local security = {}
    for key, value in pairs(Config.Security) do
        security[key] = value
    end
    for key, value in pairs(brand.Security or {}) do
        security[key] = value
    end
    brand.Security = security

    brand.Stock = brand.Stock or {}
    brand.Stock.RestockMinutes = brand.Stock.RestockMinutes or Config.Stock.RestockMinutes

    brand.UI = brand.UI or {}
    brand.Target = brand.Target or {}
    brand.Receipt = brand.Receipt or { Enabled = false }
    brand.Blip = brand.Blip or { Enabled = false }
    brand.Categories = brand.Categories or {}
    brand.Products = brand.Products or {}

    if brand.enabled ~= false then
        for shopId, shop in pairs(brand.Locations or {}) do
            if Config.Shops[shopId] then
                print(('^1[rps_shops]^7 Duplicate location id "%s" (brands %s and %s) - skipping the %s one.'):format(
                    shopId, Config.Shops[shopId].brand, brandId, brandId
                ))
            else
                shop.brand = brandId
                Config.Shops[shopId] = shop
            end
        end
    end
end

--- Returns shop, brand for an enabled shop, or nil.
function Config.GetShop(shopId)
    local shop = type(shopId) == 'string' and Config.Shops[shopId]

    if not shop or not shop.enabled then
        return nil
    end

    local brand = Config.Brands[shop.brand]

    if not brand or brand.enabled == false then
        return nil
    end

    return shop, brand
end
