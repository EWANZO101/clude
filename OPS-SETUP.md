# OPS Hub · Network · Power — the city's technology ecosystem (start here)

Four resources work together (plus **opslabs-connect** when the server is connected to the OPS Hub as one of several servers — see *Multi-server* below):

| Resource | What it is |
|---|---|
| **opslabs-props** | Every 3D model (masts, cabinets, poles, CCTV, data-centre racks, fuel stations, substations …) — `stream/` only. |
| **opslabs-towers** | The physical world: mobile masts & Wi-Fi, fibre/copper cabling, mains electricity & the grid, solar, fuel, OPS Track, the OPS Network ISP engine, OPS Secure CCTV, OPS Data centres & the cloud scheduler, gunshot sensors, faults, buildings, roadworks, ladders & harnesses. `/towers` in game. |
| **opslabs-phone** | The phone and everything people use: OPS Work (jobs, training, assistant, admin), the Browser (OPS Search, domains, websites, email, cloud), OPS Mobile plans, the business layer (quotes, contracts, stock, assets, fleet, tickets, alerts), live settings. |
| **OPS Hub** (website, `/opt/opsphone-store`) | Management for every company and the whole server: dashboards, jobs, customers, ISP, CCTV, web & domains, data & cloud, classroom, settings, jobs & companies editors, customer portal, status page. |

Start order (server.cfg): `opslabs-connect` (only if used) before `opslabs-towers`, then `[rps]` (which contains opslabs-props and opslabs-phone). Database: oxmysql — every table is created automatically on start.

## Configure everything — three ways

1. **Files**
   - `opslabs-towers/config.lua` — every physical system (each has an `Enabled` switch and its own section, commented).
   - `opslabs-phone/config.lua` — phone, OPS Mobile, `Platform` (automatic jobs), `Features` (Web, Cloud, Business, Training, Assistant) and `Work` (play mode, depots, safety, training, animations).
   - `opslabs-phone/sql/ops_catalog.json` — companies, roles & permissions, job types (prices, wages, checks, parts, certificates), customer places, ISP pools, domain/hosting/cloud prices, stock lines, suppliers, SLA tiers, contract types.
   - `opslabs-phone/sql/ops_guides.json` — the training & job-assistant content (27 job families covering every job type + 13 system explainers).
   - `opslabs-phone/config_server.lua` — secrets only (never shown anywhere).
2. **OPS Hub** → Settings (every value of both config files with its explanation, plus catalogue sections), **Jobs** (edit or create job types), **Companies** (edit, switch off, create).
3. **In game** → OPS Work → Admin settings (super admins / `admin.settings`): systems on/off, play mode, jobs and companies.

Values set on OPS Hub or in game override the files and apply within ~15 s (switching a whole system on/off needs a restart). "Reset" returns to the file's value. Every change is in OPS Hub → Platform audit. The classroom has a slideshow course on all of this: OPS Hub → Classroom → *Configuring OPS*.

## Play modes

- **Standalone** (default) — no inventory items. Tools are in the van; kit is placed from `/towers`.
- **Items** — `Config.Work.Mode = 'items'`. Tools, PPE and parts are inventory items:
  1. Add the items to your inventory: `opslabs-phone/items/` (ox_inventory, ESX SQL, QBCore — see its README).
  2. Set `Config.Work.Depots` (where engineers collect them; blip + [E]).
  3. Engineers collect tools & PPE for their accepted jobs and the jobs' parts (from company stock) at the depot; jobs need their tools to start and use their consumables on completion; placing kit from `/towers` uses the matching item (`Config.Work.ModelItems`), removing it gives it back.

## Training, health & safety, the job assistant

- Every job family has a **lesson**, a **health & safety module**, an **exam** and (optionally) an in-game **practical** at an OPS Academy training centre (`Config.Work.TrainingCentres`). Certification = exam (+ practical). Installation jobs need their certificate; every family's jobs need its safety module (both switchable).
- **Learn anywhere — one set of records:**
  - **OPS Academy app** on the phone and on in-game laptops (courses, lessons, safety modules, exams, practical, system explainers, slideshows);
  - **opsacademy.sa** in the in-game Browser (phone or laptop);
  - **OPS Work → Training** for staff;
  - **OPS Hub → Classroom** on the web (`/admin/ops/classroom`), which is now open to everyone, signed in or not.
  Anyone can read everything. Signing in (OPS Work in game, or OPS Hub) records lessons and lets you take the safety modules and exams.
- **Guide me** on any job (or `/jobhelp`): the next step, tools & where to get them, PPE, hazards, what goes wrong; "Show me" plays the step's animation.
- **Risk assessment** before on-site work and before completing; skipping controls on risky work can cause accidents (falls, shocks) — logged in `ops_incidents`, shown in the Operations centre and alerted to managers.
- On-site work plays each step of the job with its own animation (`Config.Work.Anims`).

## OPS America — the US version (US fiber-to-the-home)

A parent group with three sub-companies, sharing one `/towers` menu (**OPS America Fiber**) that uses the same models, items, splicing, light and power as OPS Openline under their US names:

| Company | Does | Jobs |
|---|---|---|
| **OPS America Fiber** (`usfiber`) | The ISP: drops (aerial / buried), NID, ONT, gateway, activation, trouble tickets | 8 |
| **OPS America Outside Plant** (`usosp`) | FDH, FDT, messenger strand, feeder / distribution fiber, handholes, vaults, splice closures, fiber cuts, OTDR | 8 |
| **OPS America Network Ops** (`usnet`) | Central office: OLT, ODF, aggregation / edge routers, BNG, DC power, HVAC · NOC PON alarms | 8 |

- Training: 6 courses, 3 certificates (US FTTH installer, US outside plant & splicing, US central office & NOC) and the *US fiber network* system explainer.
- ISP provider **OPS America Fiber** with symmetric XGS-PON plans (300 Mbps – 5 Gig) in `Config.Isp.Providers`.
- Everything is in `sql/ops_catalog.json` / `sql/ops_guides.json` (codes `us*`, `us_*`) — switch the companies or jobs off like any other.

## Branding — make it your own

Everything players and staff see follows **`Config.Brand`** in `opslabs-phone/config.lua` (or OPS Hub → Settings → *Branding*, or in game → OPS Work → Admin settings):

- **Name** — your main brand (e.g. *Skyline*). Every platform name follows it: the phone/laptop/router OS (*Skyline OS*), accounts (*Skyline ID*), the staff website (*Skyline Hub*), the jobs app (*Skyline Work*), training, the app store, search, depots and the certificate authority. Any of them can be set on its own.
- **Full / Group / Color / Accent / Logo** — website titles, the parent company, colours and an https logo image (OPS Hub shows it everywhere the logo appears).
- **Sites** — your own addresses for the in-game websites (search, domains, web hosting, cloud, academy). The old addresses keep working.
- **Companies** — rename, recolour, switch off or create them on OPS Hub → Companies; the new names show on phones, laptops, `/towers` menus and every website.
- **Company roles** — `companyRoles` in `sql/ops_catalog.json` (OPS Hub → Settings → Catalogue) says which company is the ISP, the fibre network, the mobile network, web hosting, domains, cloud, data centres, CCTV, power … Give a role to any company, including one you created.

Changes apply live (within ~30 s); nothing is hard-coded to the OPS names.

## Sub-companies, leasing and stores — a telecom market (like Openreach / EE / Vodafone, all fictional)

The **main company** (`companyRoles.main`, default OPS Network) owns the network. Other companies — yours or players' — run on it:

- **Start a company:** OPS Hub → *Start a company*. Players apply (or open straight away) under the main company and become its owner; the main company approves them on **OPS Hub → Network overview**. Rules in `sql/ops_catalog.json` → `market` (OPS Hub → Settings → Catalogue → *market*): `subCompanies`, `playerCreate`, `approval`, `maxPerPlayer`, `startingBalance`, `billingDays`, `graceDays`, and the starting wholesale price list.
- **Wholesale and leases:** provider companies (fibre, mobile, data …) sell *fibre access* (per customer line or flat), *mobile network access* (MVNO), *mast leases*, *dark fibre*, *rack space* and *colocation*. Each provider edits its own price list (OPS Hub → company → Market → *Wholesale*) and approves requests. Leases are billed in game every `billingDays` from the lessee's company account; unpaid → overdue → suspended after `graceDays` (no new customers until paid; existing customers keep service).
- **Retail:** with fibre access a company sells its **own broadband packages**; with mobile access its **own mobile plans** (company → Market → *Packages & plans*). Customers order them in game (OPS Work → My broadband; Settings → Mobile Service) or from the company's store. Installs and repairs are done by the network company's engineers (the job says who it is for); the retailer bills the customer and gets the money. The customer's **router and phone show the retailer's name** as their provider/network.
- **Stores:** every company has a public store at **`/shop/<name>`** (list of all: `/shop`) with its own name, logo, colours and *About us*. It shows the company's broadband packages, mobile plans and anything else it adds (devices, services, products). Orders arrive on company → Store.
- **Network reports:** outages, faults on masts/poles/cables/cabinets, customer fault tickets and lease problems are routed every 30 s to **every company they touch** (the retailer whose customers lost service, the mobile companies on a faulty mast, whoever leases that mast …) — company → Market → *Network reports*. Companies can also report a problem to their network provider there. The main company sees everything on **OPS Hub → Network overview**: outages, damaged kit, every company's open reports, complaints, safety incidents, lease requests, applications and each sub-company's lines, mobile customers, leases and balance.
- **Companies are not hard-coded:** OPS Hub → Companies — rename, recolour, set a logo, make one a sub-company of another, set its owner, what it provides and may lease (`may_lease`, empty = anything), approve, switch off, or delete one that has no history.

Permissions: `market.view` (reports, leases), `market.manage` (request/end leases, packages and plans, wholesale prices and approvals for providers), `store.manage` (the store). Owners have all of them; directors get all three, managers `market.view` + `store.manage`.
Tables: `sql/ops_market.sql` (created by opslabs-phone on start). An existing OPS Hub install also needs the grants in `/opt/opsphone-store/migrations/2026-10-04-market.sql`.

## Multi-server — the Server Owner Hub (`/new-hub`)

Other servers can run OPS too, each completely separate: **https://opsphone-store.opslabsystems.cloud/new-hub**.

- **Owners** create an account, add a server (name + free address `<name>.opslabsystems.cloud`), and connect it:
  - a **token** in server.cfg — `set ops_api_url "https://opsphone-store.opslabsystems.cloud"` + `set ops_server_token "opsk_…"` + `ensure opslabs-connect` (before opslabs-towers / opslabs-phone), or
  - a **pairing code** from the phone: Developer app → **OPS Hub Connection** → *Get a pairing code* → enter it on `/new-hub/pair` (no file editing).
- **Isolation:** every server gets its own MySQL database (`opst_<id>`, its own user with rights on nothing else), its own OPS Hub process (`ops-hub@<id>`, port 5300+id) and address, its own sign-in data. The game sends only OPS tables there (through **opslabs-connect**); framework tables stay on the owner's server; player names/jobs are mirrored.
- **Their Hub:** `/new-hub` → server → *Open* signs the owner into their own OPS Hub as super admin (companies, sub-companies, stores, network, reports, settings — everything in this file). Quick branding is on the server page too.
- **Domains:** the free subdomain goes live automatically (wildcard DNS `*.opslabsystems.cloud` → this box); custom domains by CNAME to it, then *Check* — certificates are issued automatically.
- **Tokens & API:** game tokens (`opsk_`) and read-only tokens (`opsr_`), stored hashed, revocable, rate limited; activity log per server. API v1 at `/api/v1` (`/server`, `/companies`, `/reports`, plus `/connect`, `/heartbeat`, `/db`, `/pair/*` for opslabs-connect). Docs: `/new-hub/docs`.
- **Self-hosting:** owners can download the whole Hub (`/new-hub` → server → Domains) and run it on their own machine against their own database — no token needed.
- **This server** (the original one) is unchanged: it keeps using `rps` and `opsphone-store.opslabsystems.cloud/admin`. Platform admins (`NEWHUB_ADMINS` in the Hub's `.env`) see and manage every server on `/new-hub`.

Machine side (root): `/opt/opsphone-store/deploy/install.sh` installs `ops-hub-api` (API, :5122), `ops-hub@.service`, and `ops-hub-reconcile` (timer + path) — the helper that creates databases, starts Hub processes, issues certificates and writes `/etc/nginx/sites-enabled/ops-hub-*.conf`. Deleted servers' databases are kept in `/var/backups/ops-hub` for 30 days. See `opslabs-connect/README.md` for the game side.

## Power: fault finder and restoration kit

San Andreas Power & Light crews (Config.Grid.CrewJobs) and engineers carry a **power fault finder** (`/powercheck`, tool kit → electrical tools, `/towers` → Tools): at any electrical kit, mast, router or ONT it traces the supply back to the power station and says exactly why there's no power. The **power restoration kit** fixes every cause it can and lists what still has to be built. See `opslabs-towers/README.md` → Tool kit; settings in `Config.PowerTools`.

## Device names

All network gear uses fictional makes (OPS Gateway Pro / Mini, OPS EdgeLink E5 / E7, OPS Switch 8 PoE, OPS Halo and OPS Beam access points, OPS Mesh M1, OPS HomeRouter AX4, OPS Controller C2). The model files have neutral names too (`opslabs_gw_pro`, `opslabs_edge_e5`, `opslabs_ap_halo` …); kit placed under the old names is converted automatically when opslabs-towers starts.

## Commands

| Command | Who | What |
|---|---|---|
| `/phone` (F1) | everyone | the phone |
| `/towers` | builders / admins | place and manage kit for every network |
| `/jobhelp` | company staff | the job assistant for your current job |
| `/track` | vehicle owners | OPS Track |
| `/opsshowcase` | admins | build the showcase at LSIA |

## Where things are

```
[rps]/
  OPS-SETUP.md            ← this file
  opslabs-props/          stream/ (models) · README.md (catalogue of models)
  opslabs-towers/         config.lua · client/ · server/ · html/ · README.md
  opslabs-connect/        multi-server: token / pairing, hosted OPS database (README.md)
  opslabs-phone/          config.lua · config_server.lua · client/ · server/ · html/ (phone UI) · sql/ (schemas, catalogue, guides)
                          items/ (inventory item definitions) · README.md
/root/fivem/opslabs-dev/props-source/   Blender sources, texture generators, build scripts, previews (not on the server)
/opt/opsphone-store/                     OPS Hub (Flask) — ops_*.py blueprints, templates/, ops_catalog.json + ops_guides.json copies
```

Keep the OPS Hub copies of `ops_catalog.json` and `ops_guides.json` in step with `opslabs-phone/sql/` when you edit the files
by hand (OPS Hub edits made in Settings/Jobs are stored in the database and need no copying).
