-- Live sync module (was xonsight-livesync): pushes the separate XonSight resource's active recorders to the
-- portal's /live page. Settings: config_server.lua → ServerConfig.Modules.LiveSync (off by default - see there).

local cfg = (ServerConfig.Modules or {}).LiveSync or {}

local function log(...)
    if cfg.Debug then
        print("[opslabs-bodycam:livesync]", ...)
    end
end

if cfg.Enabled ~= true then return end

-- exports.XonSight:GetActiveRecorders() isn't documented field-by-field, so
-- this reads several plausible field names per entry and skips anything with
-- no usable id. If your XonSight version uses different field names, adjust
-- the `or` chains below to match.
--
-- lastFrame mirrors the camera sample shape used by XonSight's own storage
-- (recording/sv_storage.lua's `frame_data` samples: x, y, z, rx/ry/rz, fov) -
-- adjust the field names below if GetActiveRecorders() exposes it differently.
local function buildLastFrame(recorder)
    local frame = recorder.lastFrame or recorder.lastSample or recorder.frame

    local x = (frame and frame.x) or recorder.x
    local y = (frame and frame.y) or recorder.y
    local z = (frame and frame.z) or recorder.z
    local heading = (frame and (frame.heading or frame.rz)) or recorder.heading or recorder.rz
    local pitch = (frame and (frame.pitch or frame.rx)) or recorder.pitch or recorder.rx
    local fov = (frame and frame.fov) or recorder.fov

    if x == nil or y == nil or z == nil then
        return nil
    end

    return {
        x = x,
        y = y,
        z = z,
        heading = heading or 0.0,
        pitch = pitch or 0.0,
        fov = fov or 50.0,
    }
end

local function buildRecorderPayload(active)
    local recorders = {}

    for _, recorder in pairs(active or {}) do
        local id = recorder.id or recorder.source or recorder.playerId
        if id then
            recorders[#recorders + 1] = {
                id = tostring(id),
                name = recorder.name or recorder.playerName or recorder.officer or ("Unit " .. tostring(id)),
                job = recorder.job or recorder.jobName or "",
                startedAt = recorder.startedAt or recorder.since or recorder.startTime,
                lastFrame = buildLastFrame(recorder),
            }
        end
    end

    return recorders
end

local function syncRecorders()
    local siteUrl = Modules.SiteUrl()
    if siteUrl == "" then
        return
    end

    local ok, active = pcall(function()
        return exports.XonSight:GetActiveRecorders()
    end)

    if not ok then
        log("GetActiveRecorders() call failed:", active)
        return
    end

    local payload = json.encode({
        recorders = buildRecorderPayload(active),
        syncedAt = os.time(),
    })

    PerformHttpRequest(siteUrl .. "/api/xonsight/recorders/sync", function(statusCode)
        if not statusCode or statusCode < 200 or statusCode >= 300 then
            log("sync failed, status:", statusCode)
        end
    end, "POST", payload, Modules.Headers())
end

CreateThread(function()
    while true do
        Wait(cfg.PollIntervalMs or 5000)
        syncRecorders()
    end
end)
