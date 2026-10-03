# Ledgerly

A small Flask + Tailwind app for client payment schedules and multi-currency
contracts: company setup, contract creation, a flexible payment schedule
builder with live editable preview, a searchable ISO 4217 currency selector,
a payment dashboard, shareable client links (optionally PIN-protected), a
rich-text agreement/terms editor with a typed e-signature block, per-company
document branding (name, colors, logo), PDF download, reminder settings, and
a full schedule-change audit trail with staff approve/reject.

## Run it locally

```bash
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt
python3 app.py
```

Open **http://localhost:5000** and click **"Set up your company"** to create
your workspace (this creates a `Company` + your first user). Then:

1. **Clients** → add a client.
2. **+ New contract** → title, client, total amount, search/select a
   currency (try typing `pound`, `GBP`, or `£`), and optionally: paste in
   agreement/terms text, tick "let the client set up the schedule
   themselves," tick "protect the share link with a PIN" (a 4-digit PIN is
   generated automatically — you'll see it on the contract page after), and
   set a "maximum months to pay off the full balance" if you want to cap how
   far out the client can spread their own schedule.
3. You'll land on the **schedule builder** — pick a frequency (monthly,
   weekly, quarterly, custom dates, etc.) and an amount mode (split evenly,
   percentage, or custom per instalment), click **Generate preview**, edit
   any date/label/amount inline, then **Confirm schedule**. (You can skip
   this step entirely and let the client build it instead — see below.)
4. On the contract page you can **Send for signing** (locks the currency),
   mark instalments **paid**, **Download PDF**, edit the **Agreement &
   sharing** settings (terms text, PIN, whether the client can self-serve
   the schedule), or **copy the share link** to send to the client.
5. **The share link** (`/share/<token>`) is a public, no-login page — this
   is the one to send the client, **not** `/contracts/<id>/...` links (those
   require a staff login and will just redirect the client to a sign-in
   page). If a PIN was set, the client enters it once (held in their browser
   session) before seeing anything. From there they can:
   - View the schedule and **download the PDF**.
   - **Set up the payment schedule themselves** at `/share/<token>/schedule`
     — any frequency, any amounts, fully their choice — if no schedule
     exists yet and you've allowed it. If you set a "maximum months to pay"
     on the contract, the final instalment can't fall later than that many
     months after their first payment; this is enforced both live in the
     browser as they edit dates and again on the server when they submit,
     so it can't be bypassed by disabling JavaScript.
   - **Request a change** to an existing schedule — this is *staged*, not
     applied immediately; it shows up as "pending" on your **audit trail**
     page with **Approve & apply** / **Reject** buttons. The same
     maximum-months cap applies to change requests too.
   - **Read the agreement** and **sign it** by typing their name — this sets
     the contract to "signed" and the signature appears on the share page
     and in the downloaded PDF.
6. **Reminders** (top nav) configures days-before-due / on-due / overdue
   notification rules per company.
7. Every schedule create/edit, send, sign, and change request/approval is
   written to the contract's **audit trail** (`Instalments → View audit
   trail`), including who requested it and who approved or rejected it.
8. **Deleting a contract** — from the contract page or the contracts list,
   click **Delete**, confirm, and it's gone: the contract, its payment
   schedule and instalments, its audit trail, and its share link are all
   removed together. This can't be undone, and only someone logged into the
   same company can do it.
9. **Branding** (top nav) — set what appears on every PDF and public share
   page: a display name (defaults to your company name), a background
   color, an accent color, and an optional logo (PNG/JPG). Text and table
   colors on the PDF adjust automatically for contrast against whatever
   background you choose, so a dark navy or a light cream background both
   stay readable without any extra tuning.

## Notes on this build

- **Branding**: `pdf_export.py` derives a full PDF color theme
  (`build_theme()`) from `Company.brand_bg_color` /
  `brand_accent_color` — it paints the actual page background (not just an
  accent stripe) via a ReportLab `onPage` callback, and computes text/muted/
  table colors from the background's luminance so any color choice stays
  legible. The company's logo (if uploaded) or display name replaces the
  fixed "Ledgerly" header on both the PDF and the public share pages.
  Uploaded logos live in `uploads/` (git-ignored; created automatically) and
  are served read-only via `/uploads/<filename>` — that route is
  intentionally public with no login, since the logo needs to render on the
  no-login client share page too; only the image file itself is exposed,
  nothing else in that folder is guessable or sensitive.

- **Visual design**: dark "ledger" theme — near-black background with a
  subtle grain texture, gradient-and-shadow cards (`.card` in
  `templates/base.html`), a gold gradient primary button, and clean rounded
  status pills instead of a gimmicky rotated "stamp" look. Component classes
  (`.card`, `.btn-primary`, `.btn-secondary`, `.btn-danger-outline`,
  `.input-field`) live once in `base.html` and are duplicated into the three
  standalone public pages (`share.html`, `share_pin.html`,
  `share_schedule.html`) since those render outside the authenticated layout
  and can't `{% extends %}` it.

- **Storage**: SQLite (`ledgerly.db`, created automatically on first run).
  Fine for a prototype/demo; swap `SQLALCHEMY_DATABASE_URI` in `app.py` for
  Postgres etc. in production. The app self-heals its own schema on
  startup: if you're running an older `ledgerly.db` that predates a field
  added later (e.g. `agreement_text`, `pin_code`), it adds the missing
  columns automatically the moment you restart the app — no manual step,
  no lost data. You'll see lines like `[startup migration] added missing
  column contract.pin_code` in the console when that happens. (A standalone
  `migrate_add_agreement_fields.py` script is also included for the same
  purpose if you'd rather run it separately.)
- **Auth**: simple email/password via Flask-Login, one company per
  registration. Good enough to demo multi-user/multi-company isolation, not
  hardened for production (no password reset, rate limiting, 2FA, etc.).
- **Currency list**: `currencies.py` holds a maintained ISO 4217-style list
  (code, name, symbol, flag) that powers `/api/currencies`, used by the
  reusable `currency-select` JS widget (`static/js/currency-select.js`).
- **Reminders**: settings are stored and shown on the Reminders page, but no
  email/SMS sender is wired up yet — that's the natural next step (e.g. a
  scheduled job that queries upcoming/overdue `Payment` rows and calls an
  email provider).
- **Schedule change requests**: fully wired end to end. The client's first
  schedule (when none exists yet) is applied immediately since there's
  nothing to protect. Any change to an *existing* schedule — from the client
  via the share link — is staged in the audit log as `pending` and only
  takes effect once staff clicks **Approve & apply** on the audit trail page;
  **Reject** leaves the current schedule untouched. Staff edits from inside
  the dashboard still apply immediately (they don't need to approve
  themselves).
- **PIN protection**: optional per contract, 4 digits, auto-generated,
  regenerable from the Agreement & sharing page. Verified PINs are held in
  a signed session cookie scoped to that share token, so the client doesn't
  have to re-enter it on every page view in the same browser session.
- **Signing**: a typed-name signature (name + a typed "signature" string),
  not a drawn signature — swap in a `<canvas>`-based pad if you need an
  actual drawn signature image later. Signing sets `Contract.signed_at` /
  `signed_by_name` / `signature_text`, flips status to "signed," and is
  included in the PDF.
- **Agreement editor**: a rich-text editor (Quill, via CDN) supporting
  headings, bold/italic/underline, ordered/unordered lists, blockquotes, and
  links — not a plain textarea. Content is sanitized server-side
  (`richtext.py`, via `bleach`) against a small safe-tag allowlist before
  it's stored, and rendered with Tailwind's `prose` classes on the share
  page. The editor lives on both the "New contract" page and the
  "Agreement & sharing" settings page, each with a live preview of exactly
  what the client will see. The PDF export (`pdf_export.py`) parses the
  same stored HTML into headings/bold/italic/lists/blockquotes rather than
  flattening it to plain paragraphs, and defensively strips any leftover
  `<span>` markup (Quill 2.x inserts an internal `<span class="ql-ui">`
  marker inside list items for its own bullet/number UI — harmless in the
  browser, but ReportLab's PDF parser rejects a bare `class` attribute
  outright) so PDFs generate correctly even for agreements saved before
  this was excluded from the sanitizer allowlist. Agreements saved by an
  older version of this app (plain text with blank-line paragraphs) still
  render correctly too — it's detected automatically and formatted as
  paragraphs, no migration needed.
- **PDF export** uses ReportLab (`pdf_export.py`) and is available both to
  staff (`/contracts/<id>/pdf`) and on the public share page.

## Project structure

```
app.py                      # routes
models.py                   # SQLAlchemy models
scheduling.py                # frequency/amount → instalment-list logic
currencies.py                 # ISO 4217 reference data
pdf_export.py                  # ReportLab PDF builder
templates/                      # Jinja2 + Tailwind (CDN) templates
static/js/currency-select.js      # searchable currency dropdown
static/js/schedule-builder.js       # schedule builder + editable preview
```
