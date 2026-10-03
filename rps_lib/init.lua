--[[
    init.lua
    Runs first (see fxmanifest.lua's shared_scripts — right after ox_lib's own
    @ox_lib/init.lua, before every other file in this resource).

    Its only job: pre-seed this resource's own lib.* registries with rawset
    before anything else touches them. ox_lib's @ox_lib/init.lua wraps the
    shared 'lib' global in a metatable whose __index lazily loads ox_lib
    modules — and caches a placeholder FUNCTION for any key that doesn't
    match one, rather than leaving it nil. Several files in this resource
    populate their own registries with the idiom `lib.X = lib.X or {}`; the
    read half of that would be the very first touch of each key, tripping
    that lazy-loader and poisoning it with a function before we ever get to
    assign our own table. Pre-seeding them here with rawset bypasses the
    metatable entirely so every later `lib.X = lib.X or {}` just finds our
    real table already in place.

    If you add a new top-level lib.<name> registry populated with that same
    idiom, add '<name>' to the list below.
]]

lib = lib or {}

for _, key in ipairs({ 'frameworks', 'garages', 'progressbars', 'ambulances', 'notifications', 'inventories', 'targets', 'phones', 'banks' }) do
    if rawget(lib, key) == nil then
        rawset(lib, key, {})
    end
end
