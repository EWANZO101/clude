# OpsLab Systems — subdomain platform

The site is now split into two Flask apps that share one codebase:

| App | Where it lives | What it does |
|---|---|---|
| **Hub app** (`app/`) | `web.yourdomain.com` | Everything that was already here: homepage/landing, login, tickets, admin, portal, billing, licenses, reviews, roadmap, partners, on-site call-out booking. Unchanged except the homepage and nav. |
| **Subsites app** (`subsites/`) | `websites.` / `fivem.` / `techsupport.` / `hosting.` / `sys-setup.` / `onsite.yourdomain.com` | Six standalone, single-purpose marketing sites — one per division. No database, no login. Content comes from `app/services_data.py`. |

The homepage at `web.yourdomain.com` is now a landing page: a short
hero, an About OpsLab Systems section, and a grid of the six services that
link straight out to their subdomains. All shared account/ticket/admin
functionality still lives on the hub, and every subsite links back to it
for "Client login" / "Get started" / "Open a ticket".

## 1. Local development

Run them separately, on two ports, no DNS needed:

```bash
# terminal 1 — hub app (unchanged)
python3 run.py                 # http://127.0.0.1:5041

# terminal 2 — the six subsites
python3 run_subsites.py        # http://127.0.0.1:5050
```

Since your browser has no `*.yourdomain.com` DNS locally, view each
subsite via its `/preview/<key>` route instead of a real subdomain:

- http://127.0.0.1:5050/preview/websites
- http://127.0.0.1:5050/preview/fivem
- http://127.0.0.1:5050/preview/techsupport
- http://127.0.0.1:5050/preview/hosting
- http://127.0.0.1:5050/preview/sys-setup
- http://127.0.0.1:5050/preview/onsite

(Links *between* subsites/hub inside those preview pages still point at
the real `https://<sub>.yourdomain.com` URLs, since those are meant
to be absolute — they just won't resolve until DNS is set up below.)

## 2. DNS

Point these at your server (A/AAAA records, or a single wildcard):

```
web            -> your server IP
websites       -> your server IP
fivem          -> your server IP
techsupport    -> your server IP
hosting        -> your server IP
sys-setup      -> your server IP
onsite         -> your server IP
```
or simply `*.yourdomain.com -> your server IP` and `yourdomain.com -> your server IP`.

## 3. Running in production — one independent process per subdomain

**Easiest path: run the all-in-one setup script.** `deploy/setup.sh`
installs nginx + certbot, creates **7 separate systemd services** (one per
hostname — see the table below), and writes an nginx server block for any
of this platform's hostnames that's actually missing. Safe to re-run any
time — and safe on a server shared with other, unrelated projects: it
never deletes, disables, or overwrites any nginx config or systemd
service it didn't create itself. If a hostname already has a working
config (however it was created), it's left completely untouched; only
genuinely missing pieces get added, and only new hostnames get new certs
issued (never `--expand`ing an existing certificate that might cover
other domains).

```bash
sudo bash deploy/setup.sh /full/path/to/opslabswebsite you@example.com your-domain.com
```

It expects DNS (step 2 above) to already be pointing at this server, and
checks that up front before doing anything.

### Why each subdomain is its own process, not one shared dispatcher

Earlier versions of this setup ran one process that inspected the Host
header to decide which of the six sites to render. In practice that's an
extra layer that can go wrong (nginx config drift, stale processes,
misconfigured proxy headers) and when it does, the symptom is exactly
"subdomains show the wrong site." The current setup removes that layer
entirely:

| Hostname | systemd service | Port | Serves |
|---|---|---|---|
| `web.<domain>` | `opslab-web` | 5800 | Hub app (`run.py`) — login, tickets, admin, portal, billing |
| `websites.<domain>` | `opslab-websites` | 5801 | Website Development only |
| `fivem.<domain>` | `opslab-fivem` | 5802 | FiveM Development only |
| `techsupport.<domain>` | `opslab-techsupport` | 5803 | Tech Support only |
| `hosting.<domain>` | `opslab-hosting` | 5804 | Hosting only |
| `sys-setup.<domain>` | `opslab-sys-setup` | 5805 | System Setup only |
| `onsite.<domain>` | `opslab-onsite` | 5806 | On-Site IT & Networking only |

Each subsite process is `wsgi_subsite.py` started with a fixed `SITE_KEY`
env var — it has no code path that can render any content other than the
one it was started with, and no Host-header logic to get confused by.
Each hostname also gets its own nginx `server { ... }` block pointing at
exactly one of those ports — nothing is shared or merged. If a subdomain
ever shows the wrong content again, it means either the wrong `SITE_KEY`
was set for that service, or nginx's `server_name`/`proxy_pass` for that
block point at the wrong port — both trivial to check with
`systemctl cat opslab-<label>` and `nginx -T | grep -B2 -A3 "server_name <label>"`.

### Why "SSL is broken" is usually a code problem, not a cert problem

If pages load over HTTPS but look broken, redirect-loop, mix http/https
content, or log users out constantly, it's almost never the certificate —
it's Flask not knowing the request came in over HTTPS, because nginx
terminates TLS and forwards plain HTTP internally. That's fixed at the
code level in this project already: both `app/__init__.py` and
`subsites/__init__.py` wrap the app in Werkzeug's `ProxyFix`, so
`request.is_secure`, generated URLs, and secure cookies all come out
correct — **as long as nginx is sending the `X-Forwarded-Proto` /
`X-Forwarded-Host` headers**, which `setup.sh` sets on every one of the
7 server blocks. If you hand-roll your own nginx config, make sure those
`proxy_set_header` lines are there in every block, or you'll be back to
the same symptoms even with a perfectly valid cert.

### Manual path (if you're not using setup.sh)

Run the hub and each subsite as separate processes, each with its own
`SITE_KEY`:

```bash
gunicorn -w 4 -b 127.0.0.1:5800 run:app                                    # hub
SITE_KEY=websites    gunicorn -w 2 -b 127.0.0.1:5801 wsgi_subsite:application
SITE_KEY=fivem       gunicorn -w 2 -b 127.0.0.1:5802 wsgi_subsite:application
SITE_KEY=techsupport gunicorn -w 2 -b 127.0.0.1:5803 wsgi_subsite:application
SITE_KEY=hosting     gunicorn -w 2 -b 127.0.0.1:5804 wsgi_subsite:application
SITE_KEY=sys-setup   gunicorn -w 2 -b 127.0.0.1:5805 wsgi_subsite:application
SITE_KEY=onsite      gunicorn -w 2 -b 127.0.0.1:5806 wsgi_subsite:application
```

Then put nginx (or Caddy) in front with **one server block per hostname**,
each with `server_name <label>.your-domain.com;` and `proxy_pass` to that
label's own port only — never one block covering multiple hostnames
pointing at one shared upstream, or you're back to the exact bug this
setup fixes.

### Legacy option: `wsgi.py` (single combined process, not recommended)

`wsgi.py` still exists and combines everything into one process that
dispatches by Host header — useful only if you're resource-constrained and
want to trade the isolation above for fewer processes. `setup.sh` does
**not** use this path.

## 4. Configuration

Environment variables (all required in production — there are no
real-looking defaults on purpose, to avoid ever silently using the wrong
domain):

```
PUBLIC_DOMAIN=your-domain.com   # the root domain everything lives under
HUB_SUBDOMAIN=web               # which subdomain runs the hub app
CONTACT_EMAIL=you@your-domain.com
```

`setup.sh` sets `PUBLIC_DOMAIN`/`HUB_SUBDOMAIN` in each systemd service
automatically from the domain you pass it. Set `CONTACT_EMAIL` yourself in
`$APP_DIR/.env` (picked up automatically by every service).

## 5. Editing content

- **Hub homepage / About / contact email** — `app/templates/index.html`
- **What each of the six sites says** (overview, packages, FAQs, etc.) —
  `app/services_data.py`. Both the hub's "Services" nav/footer and every
  subsite pull directly from this one file, so edit it once.
- **Subsite look & branding shell** (nav, footer) — `subsites/templates/layout.html`
- **Subsite page layout** (hero/overview/process/packages/FAQ order) —
  `subsites/templates/home.html`
- **On-site call-out phone/WhatsApp numbers** — appear in two places:
  `app/templates/onsitesupport.html` (the actual booking page, on the hub)
  and `subsites/templates/home.html` (the `key == 'onsite'` block, phone
  number shown directly on the onsite subsite).

## What changed vs. the old single-site app

- Old homepage's portfolio/company grid, "why OpsLab" feature grid, and
  testimonials slider were removed from the landing page to keep it a
  clean directory + About section, per your request. The reviews page and
  Testimonial data/model are untouched — reachable from Company → Reviews.
- The old "Cloud vs Onsite" gateway chooser (`gateway.html`, shown to
  first-time visitors) was removed, since On-Site is now its own dedicated
  subdomain instead of a fork on the homepage.
- `/services/<slug>` and `/services/` still exist and work on the hub
  (nothing was deleted), but are no longer linked from the main nav/footer
  — the six subdomains are the primary entry points now. Admin's package
  preview links still use them internally.
- `about.html` was removed; About content now lives directly on the new
  homepage (`#about` section). `/about` redirects there.
