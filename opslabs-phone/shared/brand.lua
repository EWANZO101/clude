-- Branding (Config.Brand) resolved into every name players see — shared by server and client.
-- The server publishes it as GlobalState['ops:brand'] so opslabs-towers (and anything else) can use it too.

local DEFAULTS = { Name = 'OPS', Full = 'OPS Hub · Network · Power', Group = 'OPS Group', Color = '#5b3df5', Accent = '#38bdf8' }
-- the built-in names every hard-coded string uses; the UI swaps them for this server's names
OPS_BRAND_STOCK = { OS = 'OPS OS', ID = 'OPS ID', Hub = 'OPS Hub', Work = 'OPS Work', Academy = 'OPS Academy', Store = 'OPS Store',
    Search = 'OPS Search', Depot = 'OPS Depot', Accounts = 'Ops-Networks', Trust = 'OPS Trust', Group = 'OPS Group', Full = 'OPS Hub · Network · Power' }
OPS_SITE_STOCK = { search = 'ops.sa', domains = 'opsdomains.sa', whois = 'whois.sa', web = 'opsweb.sa', cloud = 'opscloud.sa', academy = 'opsacademy.sa' }
local SUFFIX = { OS = ' OS', ID = ' ID', Hub = ' Hub', Work = ' Work', Academy = ' Academy', Store = ' Store', Search = ' Search', Depot = ' Depot', Accounts = ' Networks', Trust = ' Trust' }

local function str(v) return type(v) == 'string' and v:gsub('^%s+', ''):gsub('%s+$', '') or '' end

function OpsBrand()
    local B = Config.Brand or {}
    local name = str(B.Name) ~= '' and str(B.Name) or DEFAULTS.Name
    local out = { Name = name, Logo = str(B.Logo), Sites = {} }
    for k, def in pairs(DEFAULTS) do if k ~= 'Name' then out[k] = str(B[k]) ~= '' and str(B[k]) or def end end
    for k, suf in pairs(SUFFIX) do
        if str(B[k]) ~= '' then out[k] = str(B[k])
        elseif name == DEFAULTS.Name then out[k] = OPS_BRAND_STOCK[k]   -- untouched brand: keep the stock names exactly
        else out[k] = name .. suf end
    end
    if name ~= DEFAULTS.Name and (str(B.Full) == '' or str(B.Full) == DEFAULTS.Full) then out.Full = name end
    if name ~= DEFAULTS.Name and (str(B.Group) == '' or str(B.Group) == DEFAULTS.Group) then out.Group = name .. ' Group' end
    for k, def in pairs(OPS_SITE_STOCK) do
        local v = str((B.Sites or {})[k]):lower()
        out.Sites[k] = v ~= '' and v or def
    end
    if not out.Color:match('^#%x%x%x%x%x%x$') then out.Color = DEFAULTS.Color end
    if not out.Accent:match('^#%x%x%x%x%x%x$') then out.Accent = DEFAULTS.Accent end
    return out
end
