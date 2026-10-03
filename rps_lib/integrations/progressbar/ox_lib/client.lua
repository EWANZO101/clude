--[[
    integrations/progressbar/ox_lib/client.lua
    Draws the bar via ox_lib's own client export. Requires ox_lib running as
    its own resource.
]]

lib = lib or {}
lib.progressbars = lib.progressbars or {}
lib.progressbars.ox_lib = lib.progressbars.ox_lib or {}

local impl = lib.progressbars.ox_lib

--- Runs an ox_lib progress bar locally and blocks (via ox_lib's own promise)
--- until it finishes or is cancelled. `options` is passed straight through to
--- ox_lib — see https://overextended.dev/ox_lib/Modules/Interface/Client/progressBar
--- Returns true if it completed, false if cancelled.
function impl.ProgressBar(options)
    return exports.ox_lib:progressBar(options)
end
