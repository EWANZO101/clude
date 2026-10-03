"""Generates the actual CloudLoader FiveM resource - the single resource a
customer installs, per the spec's "Universal FiveM Loader" section. Unlike
the injector templates (which are per-product, per-upload), this is
generic: one build works for every customer, configured entirely through
convars in their server.cfg.
"""

FXMANIFEST_LUA = """\
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'CloudLoader'
description 'Universal loader for {site_name} - configure once at {api_base}/portal/servers'
author '{site_name}'
version '1.0.0'

client_script 'client.lua'

server_scripts {{
    'api.lua',
    'module_loader.lua',
    'updater.lua',
    'server.lua',
}}
"""

API_LUA = """\
-- api.lua
-- Shared HTTP helper. CloudLoader talks to {site_name} exclusively - no
-- other third-party integrations, per platform policy.

CloudLoaderApi = CloudLoaderApi or {{}}
CloudLoaderApi.Base = GetConvar('cloudloader_site_url', '{api_base}')

--- POSTs JSON to the platform API.
--- @param path string endpoint path
--- @param body table request body, JSON-encoded
--- @param callback function(success: boolean, status: number, data: table)
--- @param overrideBase string|nil optional base URL, e.g. a developer's
---   own custom domain for their product's calls specifically - falls
---   back to the platform's own domain if not given.
function CloudLoaderApi.Post(path, body, callback, overrideBase)
    local base = overrideBase or CloudLoaderApi.Base
    local url = base .. path
    PerformHttpRequest(url, function(statusCode, responseText, headers)
        local ok, data = pcall(json.decode, responseText or '{{}}')
        if not ok then data = {{}} end
        callback(statusCode == 200, statusCode, data or {{}})
    end, 'POST', json.encode(body or {{}}), {{
        ['Content-Type'] = 'application/json'
    }})
end
"""

SERVER_LUA = """\
-- server.lua
-- Fetches your product config automatically using a single server token -
-- no manual per-product setup. Buy a product, attach it to this server in
-- your {site_name} portal, restart - it just works.
--
-- server.cfg setup (this is the ONLY line you need):
--   setr cloudloader_server_token "srv_..."
--
-- Get your token from {api_base}/portal/servers

CloudLoader = CloudLoader or {{}}
CloudLoader.LicensedProducts = {{}}
CloudLoader.Config = {{}} -- per-product remote config, keyed by product_id - modules read CloudLoader.Config[productId]

local function fetchConfig(callback)
    local token = GetConvar('cloudloader_server_token', '')
    if token == '' then
        print('^1[CloudLoader] No cloudloader_server_token set in server.cfg.^0')
        print('^1[CloudLoader] Get one from {api_base}/portal/servers^0')
        callback(nil)
        return
    end

    CloudLoaderApi.Post('/api/server/config', {{ server_token = token }}, function(success, status, data)
        if success and data.products then
            callback(data.products)
        else
            print(('^1[CloudLoader] Could not fetch server config: %s^0'):format((data and data.error) or ('HTTP ' .. tostring(status))))
            callback(nil)
        end
    end)
end

local function loadRemoteConfig(entry)
    CloudLoaderApi.Post('/api/config/load/' .. entry.product_id, {{
        api_key = entry.api_key,
        license_key = entry.license_key,
    }}, function(success, status, data)
        if success and data.config then
            CloudLoader.Config[entry.product_id] = data.config
        end
    end, entry.api_base)
end

local function activateProduct(entry)
    CloudLoaderApi.Post('/api/license/activate/' .. entry.product_id, {{
        api_key = entry.api_key,
        license_key = entry.license_key,
        server_id = GetConvar('sv_hostname', GetCurrentResourceName()),
    }}, function(success, status, data)
        if success and data.valid then
            print(('^2[CloudLoader] %s licensed - %s^0'):format(entry.product_id, entry.product_name or entry.product_id))
            CloudLoader.LicensedProducts[entry.product_id] = entry
            loadRemoteConfig(entry)
            CloudLoaderModules.LoadForProduct(entry)
        else
            print(('^1[CloudLoader] %s license check failed: %s^0'):format(entry.product_id, (data and data.message) or ('HTTP ' .. tostring(status))))
        end
    end, entry.api_base)
end

CreateThread(function()
    Wait(1000) -- let other resources finish starting first
    fetchConfig(function(products)
        if not products then return end
        if #products == 0 then
            print('^3[CloudLoader] Server token is valid but no products are attached yet. Attach some in your portal.^0')
        end
        for _, entry in ipairs(products) do
            activateProduct(entry)
        end
    end)
end)

-- Re-fetch + re-validate every 30 minutes: new attachments start working,
-- revoked licenses stop, and remote config picks up any changes a
-- developer made - all without a server restart.
CreateThread(function()
    while true do
        Wait(30 * 60 * 1000)
        fetchConfig(function(products)
            if not products then return end
            for _, entry in ipairs(products) do
                activateProduct(entry)
            end
        end)
    end
end)
"""

MODULE_LOADER_LUA = """\
-- module_loader.lua
-- Module Delivery System: fetches the list of modules a licensed product
-- has available, downloads each one's code, caches it to disk, and
-- executes it (server-side directly, client-side via a network event).
-- The module code never has to exist in this resource on disk beforehand
-- - it's delivered from {site_name} at runtime.

CloudLoaderModules = CloudLoaderModules or {{}}
CloudLoaderModules.ClientModuleCache = CloudLoaderModules.ClientModuleCache or {{}} -- name -> code, for late joiners

local function cacheModule(productId, name, code)
    SaveResourceFile(GetCurrentResourceName(), ('cache/modules/%s_%s.lua'):format(productId, name), code, -1)
end

local function runServerModule(name, code)
    local chunk, err = load(code, name)
    if not chunk then
        print(('^1[CloudLoader] Failed to compile module %s: %s^0'):format(name, err))
        return
    end
    local ok, runErr = pcall(chunk)
    if not ok then
        print(('^1[CloudLoader] Error running module %s: %s^0'):format(name, runErr))
    else
        print(('^2[CloudLoader] Loaded server module: %s^0'):format(name))
    end
end

local function dispatchClientModule(name, code)
    CloudLoaderModules.ClientModuleCache[name] = code
    -- Broadcasts to whoever's connected right now; the request/response
    -- handler below covers anyone who joins later.
    TriggerClientEvent('cloudloader:loadModule', -1, name, code)
    print(('^2[CloudLoader] Dispatched client module: %s^0'):format(name))
end

function CloudLoaderModules.LoadForProduct(entry)
    CloudLoaderApi.Post('/api/module/list/' .. entry.product_id, {{
        api_key = entry.api_key,
        license_key = entry.license_key,
        channel = entry.channel or 'stable',
    }}, function(success, status, data)
        if not (success and data.modules) then
            print(('^1[CloudLoader] Could not list modules for %s^0'):format(entry.product_id))
            return
        end

        for _, mod in ipairs(data.modules) do
            CloudLoaderApi.Post(('/api/module/download/%s/%s'):format(entry.product_id, mod.name), {{
                api_key = entry.api_key,
                license_key = entry.license_key,
                channel = entry.channel or 'stable',
            }}, function(dlSuccess, dlStatus, dlData)
                if dlSuccess and dlData.code then
                    cacheModule(entry.product_id, mod.name, dlData.code)
                    if dlData.side == 'client' then
                        dispatchClientModule(mod.name, dlData.code)
                    else
                        runServerModule(mod.name, dlData.code)
                    end
                else
                    print(('^1[CloudLoader] Failed to download module %s^0'):format(mod.name))
                end
            end, entry.api_base)
        end
    end, entry.api_base)
end

-- Late joiners: client.lua asks for everything on its own resource start
-- (fires on join and on resource restart) rather than relying on the
-- server guessing when a client is ready to receive triggered events -
-- that's the reliable pattern, unlike a playerJoining broadcast which can
-- race the client resource's own startup.
RegisterNetEvent('cloudloader:requestModules')
AddEventHandler('cloudloader:requestModules', function()
    local src = source
    for name, code in pairs(CloudLoaderModules.ClientModuleCache) do
        TriggerClientEvent('cloudloader:loadModule', src, name, code)
    end
end)
"""

UPDATER_LUA = """\
-- updater.lua
-- Checks each configured product for a newer version and logs a notice.

CreateThread(function()
    Wait(5000)
    while true do
        for productId, entry in pairs(CloudLoader and CloudLoader.LicensedProducts or {{}}) do
            CloudLoaderApi.Post('/api/update/check/' .. productId, {{
                api_key = entry.api_key,
                current_version = entry.installed_version or '0.0.0',
            }}, function(success, status, data)
                if success and data.update_available then
                    print(('^3[CloudLoader] Update available for %s: -> %s^0'):format(productId, data.latest_version))
                end
            end, entry.api_base)
        end
        Wait(6 * 60 * 60 * 1000)
    end
end)
"""

CLIENT_LUA = """\
-- client.lua
-- Listens for modules dispatched from the server and executes them
-- locally. This is how client-side module code is "delivered from the
-- platform" without ever shipping as a file in this resource.

RegisterNetEvent('cloudloader:loadModule')
AddEventHandler('cloudloader:loadModule', function(name, code)
    local chunk, err = load(code, name)
    if not chunk then
        print(('^1[CloudLoader] Failed to compile client module %s: %s^0'):format(name, err))
        return
    end
    local ok, runErr = pcall(chunk)
    if not ok then
        print(('^1[CloudLoader] Error running client module %s: %s^0'):format(name, runErr))
    else
        print(('^2[CloudLoader] Loaded client module: %s^0'):format(name))
    end
end)

-- Ask the server for anything already loaded - covers joining after
-- modules were already dispatched to everyone else, and resource
-- restarts on the client side.
CreateThread(function()
    Wait(2000) -- give the server side a moment to finish its own startup
    TriggerServerEvent('cloudloader:requestModules')
end)
"""


def render_cloudloader_files(site_name: str, api_base: str):
    ctx = dict(site_name=site_name, api_base=api_base)
    return {
        "fxmanifest.lua": FXMANIFEST_LUA.format(**ctx),
        "api.lua": API_LUA.format(**ctx),
        "server.lua": SERVER_LUA.format(**ctx),
        "module_loader.lua": MODULE_LOADER_LUA.format(**ctx),
        "updater.lua": UPDATER_LUA.format(**ctx),
        "client.lua": CLIENT_LUA.format(**ctx),
    }
