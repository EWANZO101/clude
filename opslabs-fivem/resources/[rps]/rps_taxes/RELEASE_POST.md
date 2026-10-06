# 💸 rps_taxes – Automatic Bank & Vehicle Tax System

**Put a real economy sink on your server.** On a timer you choose, every online player is taxed on their bank balance and on the vehicles they own. The money goes into your government, police, EMS or any other society accounts, split however you like.

Players get a notification, a mail on their phone and an entry in their banking app. Staff get a full Discord log of every cycle.

> 📺 **Preview:** *[video link]*
> 📥 **Download:** *[link]*
> 📚 **Docs / support:** *[link]*

---

## ✨ Highlights

- 🏦 **Bank balance tax** – a percentage of each player's bank balance, with a minimum balance and a max cap
- 🚗 **Vehicle ownership tax** – a flat amount per owned vehicle, read straight from your framework's vehicle table
- 💼 **Multi-account revenue split** – send collected tax to several society accounts by percentage
- 📱 **Phone integration** – tax notice mail plus a banking-app transaction on lb-phone and qb-phone
- 📜 **Discord logging** – queued and throttled, with per-event channels, so it never lags your server
- 🔌 **Multi-framework** – ESX, QBCore and QBox through `rps_lib`
- 🔓 **Open source** – no escrow, every file is readable and editable

---

## 🏦 Bank tax

- Taxes a **percentage of each player's bank balance** every cycle (e.g. 1%)
- **Minimum balance** – players below it aren't taxed
- **Max tax per collection** – cap what the richest players pay (or `0` for no limit)
- **Job exemptions** – e.g. `police`, `ambulance`, `government` pay no bank tax

## 🚗 Vehicle tax

- **Flat amount per vehicle** a player owns
- **Minimum vehicle count** before tax applies, and a **max tax cap**
- **Vehicle table detected automatically** – `owned_vehicles` on ESX, `player_vehicles` on QBCore / QBox – or set your own table and column
- Vehicle counts for all players are loaded in **one database query per cycle**, not one per player
- **Separate job exemptions** from the bank tax

## 💳 Collection

- Runs automatically on a **configurable interval** (in minutes)
- Optional **collection on resource start**, after a configurable delay
- **Allow debt** (balance can go negative) or **skip players who can't pay** and tell them what they owe
- Players are processed **one after another, with a short pause in between**, so big servers don't hitch

## 💼 Multi-account revenue split

Send each cycle's revenue to **as many society accounts as you want**:

```lua
accounts = {
    { account = 'government', share = 0.70 },
    { account = 'police',     share = 0.20 },
    { account = 'ambulance',  share = 0.10 },
    { account = 'mechanic',   share = 1.0, from = 'vehicle', reason = 'Road Tax' },
}
```

- **Split by percentage** across any number of accounts
- **Split bank tax and vehicle tax separately** – e.g. all road tax to the mechanics, bank tax shared between government and police
- **Custom transaction reason** per account
- Works with **qb-banking**, **Renewed-Banking** and **esx_addonaccount** societies (on ESX the `society_` prefix is added automatically)
- One failed deposit **doesn't block the others**
- **Shares are checked at startup** – the system won't start if your percentages add up to more than 100%

## 📱 Phone & notifications

- **In-game notification** with the full breakdown (bank / vehicles / total) – codem, ox_lib or your framework's own notify
- **Tax notice mail** to the player's phone, with a detailed breakdown
- **Payment failed mail** when a player can't cover their taxes
- **Banking-app transaction** so players see the tax in their phone's bank / wallet app
- lb-phone **falls back to an SMS** if the player has no mail account set up
- All texts, mail subjects, sender name and currency symbol are **editable in the config**

## 📜 Discord logs

- Logs **taxes collected, failed and exempt per player**, plus a **summary per cycle**, system start, errors and manual triggers
- The **cycle summary** shows players taxed, total collected, failed, exempt and **every account deposit** (✅ / ❌)
- **Queued & throttled** – messages are sent one by one with a delay, so a big cycle never blocks the server or hits Discord rate limits
- **Per-cycle cap** – after X messages, only the summary is sent
- **Separate channel per event** if you want one (e.g. summaries to a staff channel, failures to another)
- **Webhook URLs are kept server-side** in `server/webhooks.lua`, so players can't see them
- Optional **player identifiers** (license, Steam, clickable Discord mention)
- Custom bot name, avatar, colours and footer
- `/testtaxwebhook` to check your setup in one command

---

## 🔌 Compatibility

| | Supported |
|---|---|
| **Frameworks** | ESX, QBCore, QBox (auto-detected by `rps_lib`) |
| **Notifications** | codem-supreme-notification, ox_lib, framework default (via `rps_lib`) |
| **Phone** | lb-phone, qb-phone (via `rps_lib`) |
| **Banking** | qb-banking, Renewed-Banking (via `rps_lib`), esx_addonaccount |

## 📦 Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- [oxmysql](https://github.com/overextended/oxmysql)
- `rps_lib`

## ⚙️ Installation

1. Put `rps_taxes` in your resources folder
2. Add to `server.cfg` after ox_lib, oxmysql, your framework and rps_lib:
   ```
   ensure rps_lib
   ensure rps_taxes
   ```
3. Set your tax rates, interval and accounts in `config.lua`
4. *(Optional)* Paste your Discord webhook URL into `server/webhooks.lua` and set `Config.Webhook.enabled = true`
5. *(ESX + revenue split)* Make sure every account you list exists in your `addon_account` table (e.g. `society_government`)
6. Restart and check the console – it prints the framework, phone, bank and notification system it found

## 🎮 Commands

| | |
|---|---|
| `/collecttaxes` | Run a tax collection right now (admin) |
| `/checktax [id]` | Show a player's bank balance, vehicles and what they'd pay, without charging them (admin) |
| `/testtaxwebhook` | Send a test message to your Discord webhook (admin) |

All commands work from the **server console** too. Admin = `admin` / `superadmin` group on ESX, framework admin permission on QBCore / QBox.

## 🧩 Exports (server)

```lua
exports.rps_taxes:CollectTaxes()                 -- run a cycle, returns a summary incl. deposits
exports.rps_taxes:ProcessPlayerTax(source)       -- tax one player now
exports.rps_taxes:CalculatePlayerTax(source)     -- { bankTax, vehicleTax, bankBalance, vehicleCount } – no charge
exports.rps_taxes:GetPlayerVehicleCount(identifier)
```

Use `CalculatePlayerTax` to show players their upcoming tax in a city hall menu or phone app.

## 🔧 Config highlights

- Tax interval, collect on start, start delay, currency symbol, debug mode
- Bank tax %, minimum balance, max tax, exempt jobs
- Vehicle tax per vehicle, minimum vehicles, max tax, vehicle table, exempt jobs
- Allow negative balance (debt) or skip players who can't pay
- Revenue accounts, shares, per-tax split and transaction reasons
- Notification position, duration and types
- Phone mail, banking alert, sender name / number, mail subjects
- Discord events, colours, identifiers, throttle and per-cycle cap
- Every player-facing message and mail text

---

**Version:** 1.1.0
*Feedback and bug reports welcome – [support link]*
