"""
Migration script - run this once to update your existing forum.db.
Usage: python migrate.py
"""
import sqlite3, os, glob

search_root = os.path.dirname(os.path.abspath(__file__))
found = glob.glob(os.path.join(search_root, '**', 'forum.db'), recursive=True)

if not found:
    print("No forum.db found. Just run: python app.py")
    exit(0)

for db_path in found:
    print(f"Migrating: {db_path}")
    conn = sqlite3.connect(db_path)
    cur  = conn.cursor()

    # 1. Add missing columns to reports
    cur.execute("PRAGMA table_info(reports)")
    cols = [r[1] for r in cur.fetchall()]
    for col, typ in [("claim_token","TEXT"), ("updated_at","DATETIME")]:
        if col not in cols:
            cur.execute(f"ALTER TABLE reports ADD COLUMN {col} {typ}")
            print(f"  + Added reports.{col}")
        else:
            print(f"  - reports.{col} already exists")

    # 2. Create report_messages table if missing
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='report_messages'")
    if not cur.fetchone():
        cur.execute("""CREATE TABLE report_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            report_id INTEGER NOT NULL REFERENCES reports(id),
            sender VARCHAR(10) NOT NULL,
            sender_label VARCHAR(80),
            content TEXT NOT NULL,
            is_read BOOLEAN DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP)""")
        print("  + Created report_messages table")
    else:
        print("  - report_messages already exists")

    # 3. Make reports.post_id nullable so posts can be deleted without losing reports
    cur.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='reports'")
    row = cur.fetchone()
    schema = row[0] if row else ''
    if 'post_id INTEGER NOT NULL' in schema:
        print("  * Making reports.post_id nullable (table rebuild)...")
        cur.executescript("""
            PRAGMA foreign_keys=OFF;
            CREATE TABLE reports_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                report_id VARCHAR(20) UNIQUE,
                post_id INTEGER REFERENCES posts(id),
                post_ref_id VARCHAR(20),
                portal_user_id INTEGER REFERENCES report_portal_users(id),
                reporter_display_name VARCHAR(100),
                is_anonymous BOOLEAN,
                description TEXT NOT NULL,
                links TEXT,
                other_info TEXT,
                status VARCHAR(20) DEFAULT 'pending',
                admin_reply TEXT,
                admin_seen BOOLEAN DEFAULT 0,
                ip_address VARCHAR(45),
                claim_token TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            INSERT INTO reports_new
                SELECT id, report_id, post_id, post_ref_id, portal_user_id,
                       reporter_display_name, is_anonymous, description, links,
                       other_info, status, admin_reply, admin_seen, ip_address,
                       claim_token, created_at, updated_at
                FROM reports;
            DROP TABLE reports;
            ALTER TABLE reports_new RENAME TO reports;
            PRAGMA foreign_keys=ON;
        """)
        print("  + reports.post_id is now nullable")
    else:
        print("  - reports.post_id already nullable")

    conn.commit()
    conn.close()
    print("  Done!\n")

print("Migration complete. Now run: python app.py")
