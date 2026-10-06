-- Publishes the branding to every resource and every player (GlobalState['ops:brand']):
--   brand   = OpsBrand() (shared/brand.lua) — the main company and every platform name
--   stock   = the built-in names those replace
--   renames = companies renamed on OPS Hub: { from = catalogue name, to = current name }
-- opslabs-towers and the phone UI use it to show this server's names everywhere. Re-published when settings or companies change.

local last
local function payload()
    local renames = {}
    for _, c in ipairs((Ops and Ops.catalog and Ops.catalog.companies) or {}) do
        local row = Ops.company(c.code)
        if row and row.name and row.name ~= c.name then renames[#renames + 1] = { from = c.name, to = row.name } end
    end
    return { brand = OpsBrand(), stock = OPS_BRAND_STOCK, sites = OPS_SITE_STOCK, renames = renames }
end

function OpsBrandPublish()
    local ok, p = pcall(payload)
    if not ok then return end
    local s = json.encode(p)
    if s ~= last then last = s GlobalState['ops:brand'] = p end
end
exports('Brand', function() return (GlobalState['ops:brand'] or {}).brand or OpsBrand() end)

AddEventHandler('opslabs:configChanged', function(res) if res == GetCurrentResourceName() then OpsBrandPublish() end end)
CreateThread(function()
    Wait(2000)
    while true do OpsBrandPublish() Wait(30000) end     -- companies renamed on OPS Hub show up within 30 s
end)
