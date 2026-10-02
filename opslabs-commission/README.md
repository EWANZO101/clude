# Cioda's Commission Site

A full-featured Flask commission tracking and management system.

---

## Quick Start

### 1. Install Python dependencies

```bash
pip install -r requirements.txt
```

### 2. Run the app

```bash
python app.py
```

Then open your browser to: **http://localhost:5000**

The SQLite database (`instance/commissions.db`) is created automatically on first run.

---

## Features

### Public Site (`/`)
- Price list for all commission types
- Commission request form (`/request`)
- Open/Closed status banner

### Customer Order Tracking (`/order/<unique_link>`)
- Order status badge (Awaiting Confirmation / Accepted / Declined / Pending / In Progress / Done)
- Payment status badge (Unpaid / Pending / Paid)
- ETA display
- Order receipt
- Full order history / log
- Invoice view
- Support ticket system (24-hour sessions)

### Admin Panel (`/admin`)
Login: **ciodrawz** / **ciodrawz2026!11**

| Section | What you can do |
|---|---|
| Dashboard | Overview stats + commission toggle |
| Orders | Create, view, update orders; generate unique links |
| Requests | Review/accept/decline/convert commission requests |
| Invoices | Create itemised invoices, mark as paid |
| Payments | Full payment history |
| Tickets | View and reply to support tickets |
| Form Editor | Add/remove/toggle fields on the request form |
| Settings | Discord webhook URL, closed message, CashApp key |

---

## Configuration

### Discord Webhooks
1. In your Discord server, go to **Channel Settings → Integrations → Webhooks**
2. Create a new webhook and copy the URL
3. Paste it in **Admin → Settings → Discord Webhook URL**

Webhook notifications fire for:
- New commission requests
- New orders created
- Payment received
- New support tickets
- Ticket replies
- Order status changes

### Commission Toggle
Use the toggle on the Dashboard or Settings page. When closed:
- The request form shows the "closed" message
- Users cannot submit new requests

### Unique Order Links
Every order gets a URL like:
```
http://yoursite.com/order/abc123def456...
```
Copy it from the order detail page and send it to your customer.

---

## Deployment (Production)

For production use, replace the dev server with **gunicorn**:

```bash
pip install gunicorn
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

Or use a service like **Railway**, **Render**, or **fly.io** — just point them at this folder.

Change the `app.secret_key` in `app.py` to a long random string before deploying publicly.

---

## File Structure

```
cioda-commissions/
├── app.py                  ← Main Flask application + all routes
├── requirements.txt
├── README.md
├── instance/
│   └── commissions.db      ← SQLite database (auto-created)
└── templates/
    ├── base.html           ← Shared styles + layout
    ├── device_select.html  ← "PC or Phone?" splash
    ├── index.html          ← Public homepage
    ├── request_form.html   ← Commission request form
    ├── request_submitted.html
    ├── closed.html
    ├── auth/
    │   └── login.html
    ├── customer/
    │   ├── order.html      ← Customer order tracker
    │   ├── new_ticket.html
    │   └── ticket.html
    └── admin/
        ├── base_admin.html ← Admin layout + sidebar
        ├── dashboard.html
        ├── orders.html
        ├── order_detail.html
        ├── new_order.html
        ├── requests.html
        ├── invoices.html
        ├── new_invoice.html
        ├── tickets.html
        ├── ticket_detail.html
        ├── payments.html
        ├── form_editor.html
        └── settings.html
```
