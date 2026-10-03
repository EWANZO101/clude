"""
setup_check.py -- run by setup.sh / setup.bat. Makes sure everything the
kiosk's admin area and welding-wire feature need actually exists:

  1. All DB tables are created / migrated (via migrate.py's own logic).
  2. At least one active admin account exists, so there's always a way
     to log into the admin area on a fresh install -- without this,
     running migrate.py alone leaves a kiosk with a DB but no way to
     log in and use it.
  3. The wire-code catalogue has at least the two codes named in the
     spec (belt-and-braces on top of migrate.py's own seeding).
  4. The libraries the wire PDF report needs (reportlab) actually
     import -- so a missing/broken install is caught here, not the
     first time someone clicks "Generate Report".

Safe to re-run any time: every step checks before it acts, same
convention as migrate.py.
"""
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))


def _ensure_admin():
    from main import run_create_user_inprocess
    from app import create_app
    from app.models import LocalUser

    app = create_app()
    with app.app_context():
        existing_admin = LocalUser.query.filter_by(role="admin", is_active=True).first()
        if existing_admin:
            print(f"[OK] Admin account already exists: '{existing_admin.username}' "
                  f"(badge_code={existing_admin.badge_code}).")
            return

        print("[SETUP] No active admin account found -- creating one ...")
        badge = run_create_user_inprocess(username="admin", badge_code=None, role="admin")
        if badge:
            print(f"[OK] Created admin account. Login badge code: {badge}")
            print("      (Scan/enter this badge code on the kiosk login screen, "
                  "or type username 'admin'.)")
        else:
            print("[FAIL] Could not create an admin account -- see error above.", file=sys.stderr)
            sys.exit(1)


def _ensure_wire_codes():
    from app import create_app
    from app.models import db, WireCode

    app = create_app()
    with app.app_context():
        for name in ("1.2 Code Wire", "1.6 Code Wire"):
            if not WireCode.query.filter_by(name=name).first():
                print(f"[SETUP] Adding missing wire code '{name}' ...")
                db.session.add(WireCode(name=name))
        db.session.commit()
        active = WireCode.query.filter_by(is_active=True).order_by(WireCode.name).all()
        print(f"[OK] Wire codes available: {', '.join(c.name for c in active) or '(none)'}")


def _check_pdf_dependency():
    try:
        import reportlab  # noqa: F401
        print(f"[OK] reportlab is installed (v{reportlab.Version}) -- PDF reports will work.")
    except ImportError:
        print("[FAIL] reportlab is NOT installed -- 'Generate Report' will fail. "
              "Run: pip install -r requirements.txt", file=sys.stderr)
        sys.exit(1)


def _run_migrations():
    print("[SETUP] Running database migration ...")
    import migrate
    migrate.main()


def main():
    print("=" * 60)
    print(" StockTool Kiosk -- DB / Admin / Welding Wire setup check")
    print("=" * 60)
    _check_pdf_dependency()
    _run_migrations()
    _ensure_wire_codes()
    _ensure_admin()
    print("=" * 60)
    print(" Setup complete. The database and admin area are ready.")
    print("=" * 60)


if __name__ == "__main__":
    main()
