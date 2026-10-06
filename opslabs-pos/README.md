# opslabs-pos — OPS POS Systems

Tills for stores, built on OPS kit. OPS POS Systems is an OPS platform company (code `pos` in
`opslabs-phone/sql/ops_catalog.json`): its engineers fit the kit (jobs `pos_install`, `pos_lane`, `pos_reader`,
`pos_support`; stock, supplier Tillcraft, certificate and Academy guide included), and stores pay it a software
licence plus a fee on every card payment.

## The kit (opslabs-props models, placed from `/towers` → OPS POS Systems)

| Piece | Model | What it does on the till |
|---|---|---|
| Terminal | `opslabs_pos_terminal` | The till: sell, stock, staff hours, reports. Screen lights up (`_on`) when the till is live |
| Card reader | `opslabs_pos_cardreader` | Card / contactless payments — the customer approves on their phone (OPS Pay) |
| Cash drawer | `opslabs_pos_drawer` | Cash payments; slides open (`_open`) on a cash sale |
| Receipt printer | `opslabs_pos_printer` | The customer gets an `ops_receipt` item with the sale on it |
| Barcode scanner | `opslabs_pos_scanner` | Scan / type a barcode + Enter to add; the till beeps |
| Customer display | `opslabs_pos_display` | People near it see the basket and total as it's rung up |

Everything within `Config.KitRadius` (3 m) of a terminal joins that till.

## Using it

1. **Set up** — a boss of a business (rps_bossmenu boss access, or an ESX grade in `Config.BossGrades`) presses
   [E] at an unclaimed terminal. Set-up fee + the first licence period come out of the society account
   (`society_<job>`) and go to the OPS POS company.
2. **Products** — bosses add products from what they're carrying (Stock tab: item, quantity, price, category,
   barcode). Staff receive more stock the same way. Bosses change prices, take stock out or remove products.
3. **Selling** — staff of the business clock in, tap products into the sale, pick the customer at the counter and
   press Card or Cash. Card: the customer's phone shows an OPS Pay sheet (Face ID) — no working phone falls back to
   tapping a bank card. Cash: the customer confirms handing it over. The customer gets the items, a receipt and
   loyalty points; stock goes down.
4. **Money** — card sales go to the society account less `Config.Payments.CardFeePct` (to OPS POS). Cash goes into
   the drawer; a boss cashes up into the society (Manage tab).
5. **Manage** (bosses) — today / 7 days takings by card / cash / shop, recent sales with refunds, staff hours,
   top products, loyal customers, low stock, store name and sales tax, licence status.
6. **Licence** — billed to the society every `Config.Licence.PeriodDays`; unpaid for `GraceDays` → the till is
   suspended until a boss pays it.

## NPC shops (rps_shops)

A till set up within `Config.NpcShops.LinkDistance` of an rps_shops shop runs that shop (linked on its first sale;
`/posshop <store> <shopId|none>` links by hand). Then the shop's takings go to the business (cash into the drawer,
card into the society), they show in the till's reports, and a customer short of cash can pay by card if the till
has a card reader. rps_shops calls the exports `NpcCardPay`, `NpcCardRefund` and `NpcSale`
(`rps_shops/server/main.lua`, only when opslabs-pos is running).

## Tables

`opslabs_pos_stores`, `opslabs_pos_products`, `opslabs_pos_sales`, `opslabs_pos_shifts`, `opslabs_pos_loyalty` —
created on start. Item: `ops_receipt` (added to ox_inventory `data/items.lua`, image `web/images/ops_receipt.png`).
