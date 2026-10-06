Config = {}

-- Whether the target of a carry must accept (via the rps_lib target option
-- shown on the requester's ped) before the carry starts. Set to false to
-- restore the old instant-carry behavior with no permission step.
Config.RequirePermission = false

-- How long (ms) a pending carry request stays valid before being auto-declined.
Config.RequestTimeout = 15000
