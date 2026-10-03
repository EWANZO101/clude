# StockTool — Project Structure

```
stocktool/
├── app/
│   ├── __init__.py              # App factory
│   ├── extensions.py            # db, login_manager, jwt
│   ├── models/
│   │   ├── __init__.py
│   │   ├── user.py              # User, roles
│   │   ├── item.py              # Item (inventory)
│   │   ├── tool.py              # Tool (asset)
│   │   ├── tool_history.py      # Check-out/in log
│   │   ├── audit_log.py         # Full audit trail
│   │   └── barcode.py            # Barcode records
│   ├── routes/                  # Web UI blueprints (Parts 3-6, 8)
│   ├── api/                     # REST API blueprints (Part 7)
│   ├── templates/               # Jinja2 HTML (Part 8)
│   └── static/                  # CSS/JS/images
├── instance/
│   └── stocktool.db             # SQLite DB (auto-created)
├── scripts/
│   └── init_db.py               # DB init + first-run admin
├── config.py                    # App configuration
├── run.py                       # Entry point
└── requirements.txt
```
