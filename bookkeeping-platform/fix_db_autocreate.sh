#!/bin/bash
set -e

cd /root/bookkeeping-platform

echo "== Bookkeeping Platform DB Fix =="

python3 - <<'PY'
from app import create_app
from app.extensions import db

app = create_app("development")

with app.app_context():
    print("Database:", db.engine.url)
    print("Tables before:", db.inspect(db.engine).get_table_names())

    db.create_all()

    print("Tables after:", db.inspect(db.engine).get_table_names())

    if "users" in db.inspect(db.engine).get_table_names():
        print("SUCCESS: users table exists.")
    else:
        print("ERROR: users table was NOT created.")
        raise SystemExit(1)
PY

echo
echo "Database initialization complete."
