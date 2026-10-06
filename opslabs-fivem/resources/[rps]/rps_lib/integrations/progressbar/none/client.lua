--[[
    integrations/progressbar/none/client.lua
    Fallback used when no progress bar module is detected/configured. Waits
    out the requested duration with no UI, then reports completion, so
    calling code doesn't have to special-case the "no progress bar" server.
]]

lib = lib or {}
lib.progressbars = lib.progressbars or {}
lib.progressbars.none = lib.progressbars.none or {}

local impl = lib.progressbars.none

function impl.ProgressBar(options)
    lib.print('ProgressBar called but no progress bar module is configured (Config.ProgressBar = "none")')
    Wait(options and options.duration or 0)
    return true
end
