--[[
    integrations/progressbar/none/server.lua
    Fallback used when no progress bar module is detected/configured. Doesn't
    round-trip to the client at all — just resolves after the requested
    duration so calling code still gets a sensible completed/cancelled result.
]]

lib = lib or {}
lib.progressbars = lib.progressbars or {}
lib.progressbars.none = lib.progressbars.none or {}

local impl = lib.progressbars.none

function impl.ProgressBar(source, options, cb)
    SetTimeout(options and options.duration or 0, function()
        if cb then cb(true) end
    end)
end
