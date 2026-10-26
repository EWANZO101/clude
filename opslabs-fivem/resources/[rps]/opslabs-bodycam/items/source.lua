-- Single source of truth for opslabs-bodycam's inventory items. Everything in `ox_inventory.lua`, `esx_items.sql`
-- and `qb_items.lua` in this folder is generated from this table by hand — edit here first, then regenerate those
-- three files (and re-paste/re-run them per items/README.md) so the live item records stay in step.
--
-- To add a new item: add an entry below, then add it to all three generated files following the existing pattern.
-- Fields:
--   key          the item name used everywhere (config.lua, items.lua, save data) — never rename one that's live
--   label        shown to players
--   weight       grams
--   stack        true = multiple sit in one inventory slot (not for anything meant to be "worn")
--   usable       true = the resource registers a use-handler for it at runtime (server/vest.lua, Bridge.UsableItem)
--   wiredBy      which Config.* field in opslabs-bodycam/config.lua actually reads this item name
--   description  shown in the inventory tooltip

return {
    {
        key = 'bodycam',
        label = 'OPS Body Cam',
        weight = 100,
        stack = true,
        usable = false,
        wiredBy = 'Config.Access.Item',
        description = 'Carrying this is what Config.Access checks for (item / job_and_item / job_or_item mode). '
            .. 'This is the access-gate item — the camera itself is the vest below.',
    },
    {
        key = 'ops_vest',
        label = 'Black Duty Vest',
        weight = 2500,
        stack = false,
        usable = true,   -- Bridge.UsableItem(Config.Vest.Item, ...) in server/vest.lua — puts it on / takes it off
        wiredBy = 'Config.Vest.Item',
        description = 'All-black plate carrier with an OPS Body Cam dock. Use to put it on / take it off.',
    },
    {
        key = 'dash_cam',
        label = 'OPS Dash Cam',
        weight = 100,
        stack = true,
        usable = false,
        wiredBy = nil,   -- not wired to anything yet — see items/README.md
        description = 'Matches opslabs-bodycam\'s Config.LiveStream feed ("OPS DASH CAM"). Not currently required '
            .. 'to use it — add `Item = \'dash_cam\'` to that config block to require it, the same way Config.Access does.',
    },
}
