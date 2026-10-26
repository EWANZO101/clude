--- A module's settings as shared by modules/server.lua (from config_server.lua's ServerConfig.Modules), or nil when
--- that module is turned off. Waits for the server to share them.
function ModuleConfig(name)
    local all = GlobalState['opslabs-bodycam:modules']
    while all == nil do
        Wait(250)
        all = GlobalState['opslabs-bodycam:modules']
    end
    return all[name] or nil
end
