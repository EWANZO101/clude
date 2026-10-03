# 🛒 RPS Shops v2.0.0 — Every Store in One Script

**24/7 Supermarket • LTD Gasoline • YouTool • Digital Den** now ship together in one resource, `rps_shops`. Each store keeps its own look, and you only install and configure one script.

## ✨ Features

**🏪 4 store chains, 18 locations ready to go**
• 24/7 Supermarket: 9 vanilla counters
• LTD Gasoline: 5 vanilla counters
• YouTool: Senora Fwy, Davis and Paleto Bay
• Digital Den: an electronics store, ready for your MLO
• Turn a whole chain or a single location on or off in one line

**🎨 A themed UI for each chain**
• Every brand has its own design: 24/7 green, LTD red and yellow, YouTool hazard orange, Digital Den purple
• Live receipt-style cart, category sidebar, search, sale badges and stock counters
• LTD fuel price board and YouTool tool rental board (just for show)
• Item images detected automatically for your inventory

**🔒 Server-side security**
• Every price, stock count and cart is checked on the server
• Distance checks, per-item limits and caps on cart size
• If an item can't be added, the purchase rolls back and the player gets a refund

**📦 Stock system**
• Stock is kept per location, with restocks on a timer you can set for each brand
• Stock updates live for everyone who has the shop open
• Unlimited-stock items and per-location price multipliers

**⚙️ Easy to configure**
• One shared config, plus one file per brand
• Limit any location to certain products or categories
• Sale prices, receipts with purchase details, blips, peds and target zones
• Every message can be changed (full locale per brand)

**🔌 Works with your stack (via rps_lib)**
• ESX / QBCore / QBox / standalone
• ox_inventory, tgiann, qb, ps, lj inventories
• ox_target, qb-target, tgiann-target
• Pay with cash as an item or as a framework account (cash or bank)

**🛠️ Admin commands**
• `/restockshops [brand]` restocks everything or one chain
• The old per-brand commands still work (`/restock247`, `/restockltd`, `/restockyoutool`, `/digitaldenrestock`)

## 📥 Upgrading from the separate scripts
1. Delete `rps_247Supermarget`, `rps_LtdGasline`, `rps_YouTool` and `rps_DigitalDen`
2. Drop in `rps_shops` and add any missing items from `OX_INVENTORY_ITEMS_EXAMPLE.lua`
3. `ensure rps_shops` (after `ox_lib` and `rps_lib`)

**Requires:** `ox_lib`, `rps_lib`

## 📋 Full Feature List
- 4 store chains in one resource: 24/7 Supermarket, LTD Gasoline, YouTool, Digital Den
- 18 locations set up out of the box (vanilla GTA V counters)
- Each chain has its own themed UI (colours, logo, layout, receipt)
- Category sidebar with item counts
- Live search by name, description or item
- Receipt-style cart with +/− quantity, remove and clear
- Running totals, including how much the player saved on sale items
- Sale prices with original price crossed out and a "deal" badge
- Stock badges: in stock, low stock, sold out
- Live stock updates for everyone with the shop open
- Stock kept separately per location
- Automatic restock on a timer, set per brand (% of max stock each cycle)
- Unlimited-stock option per product
- Per-product purchase limit
- Max different items and max total units per purchase
- Price multiplier per location (e.g. pricier out in the sticks)
- Limit a location to certain products or categories
- Server-side checks on prices, stock, cart and distance
- Rollback and refund if the player can't receive an item
- Inventory space check before charging
- Receipt item with shop, total and date (per brand, optional)
- Cashier peds with scenarios, target zones, or both
- Configurable blips per brand and per location
- Purchase hand-over animation
- Item images resolved automatically for your inventory, or set your own
- Pay with cash as an item, or with a framework account (cash or bank)
- ESX / QBCore / QBox / standalone via rps_lib
- ox_inventory, tgiann, qb, ps and lj inventory support via rps_lib
- ox_target, qb-target and tgiann-target support via rps_lib
- Notifications through rps_lib
- Every message editable, per brand
- Turn whole chains or single locations on or off
- Easy to add new chains (brand config + theme folder)
- `/restockshops [brand]` plus the old per-brand restock commands
- ACE permissions for admin commands
- Example ox_inventory item definitions included
- Browser preview of each UI for easy editing

🔗 **Download:** <LINK>
💬 **Support:** <DISCORD LINK>
