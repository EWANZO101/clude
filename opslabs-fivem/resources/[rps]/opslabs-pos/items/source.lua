-- Single source of truth for opslabs-pos's inventory items. Mirrors opslabs-bodycam/items/source.lua's shape —
-- edit here, then keep ox_inventory.lua / esx_items.sql / qb_items.lua in this folder in step with it by hand.
--
-- To add a new item: add an entry below, then add it to all three generated files following the existing pattern.

return {
    {
        key = 'ops_receipt',
        label = 'Receipt',
        weight = 1,
        stack = false,   -- every sale gives its own copy — each carries different per-sale metadata, see below
        usable = false,
        wiredBy = 'Config.ReceiptItem',
        description = 'A till receipt from an OPS POS store.',
        note = 'Given with per-sale metadata (store name, itemised lines, total — server/main.lua ~line 583) via '
            .. 'ox_inventory\'s AddItem(..., meta). Only when ox_inventory is running and the store has a printer '
            .. '(Config, per-store `kit.printer`); on another inventory system or without a printer it\'s a plain, '
            .. 'un-itemised copy, or a phone notification instead with no item at all.',
    },
}
