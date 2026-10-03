"""
DatabaseManager — self-provisioning, self-migrating.
On !setup-tickets or explicit reset, drops and recreates all tables cleanly.
"""

import logging
import os
import secrets
import string
import pymysql
from pymysql.cursors import DictCursor
from dotenv import set_key, load_dotenv

log = logging.getLogger("cfrp_bot.db")

ENV_FILE = os.path.join(os.path.dirname(__file__), "..", ".env")
DB_NAME  = "cfrp_bot"
DB_USER  = "cfrp_bot"

# ── Schema ─────────────────────────────────────────────────────────────────────

TABLES_IN_ORDER = [
    ("ticket_counter", """
        CREATE TABLE IF NOT EXISTS ticket_counter (
            id      INT PRIMARY KEY DEFAULT 1,
            counter INT NOT NULL DEFAULT 0
        )
    """),
    ("application_types", """
        CREATE TABLE IF NOT EXISTS application_types (
            id                  INT AUTO_INCREMENT PRIMARY KEY,
            name                VARCHAR(100)  NOT NULL,
            app_key             VARCHAR(64)   NOT NULL UNIQUE,
            apply_url           VARCHAR(512)  NOT NULL DEFAULT '',
            emoji               VARCHAR(16)   NOT NULL DEFAULT '🎫',
            channel_name        VARCHAR(100)  NOT NULL DEFAULT '',
            category_id         VARCHAR(64)   NULL,
            discord_channel_id  VARCHAR(64)   NULL,
            auto_role_id        VARCHAR(64)   NULL,
            created_at          DATETIME      DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_auto_role_id (auto_role_id)
        )
    """),
    ("tickets", """
        CREATE TABLE IF NOT EXISTS tickets (
            id              INT AUTO_INCREMENT PRIMARY KEY,
            ticket_number   VARCHAR(16)   NOT NULL DEFAULT '',
            channel_id      VARCHAR(64)   NOT NULL UNIQUE,
            user_id         VARCHAR(64)   NOT NULL,
            opened_by_name  VARCHAR(100)  NOT NULL DEFAULT '',
            app_key         VARCHAR(64)   NOT NULL,
            claimed_by      VARCHAR(64)   NULL,
            status          ENUM('open','closed') DEFAULT 'open',
            opened_at       DATETIME      NULL,
            closed_at       DATETIME      NULL,
            closed_by       VARCHAR(64)   NULL,
            INDEX idx_user_id       (user_id),
            INDEX idx_status        (status),
            INDEX idx_ticket_number (ticket_number)
        )
    """),
    ("ticket_messages", """
        CREATE TABLE IF NOT EXISTS ticket_messages (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            ticket_id   INT           NOT NULL,
            author_id   VARCHAR(64)   NOT NULL,
            author_name VARCHAR(100)  NOT NULL,
            content     TEXT,
            sent_at     DATETIME      DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (ticket_id) REFERENCES tickets(id) ON DELETE CASCADE
        )
    """),
    ("staff_overrides", """
        CREATE TABLE IF NOT EXISTS staff_overrides (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            type        ENUM('user','channel') NOT NULL,
            target_id   VARCHAR(64)   NOT NULL UNIQUE,
            set_by      VARCHAR(64)   NOT NULL,
            set_at      DATETIME      DEFAULT CURRENT_TIMESTAMP
        )
    """),
    ("kb_corrections", """
        CREATE TABLE IF NOT EXISTS kb_corrections (
            id           INT AUTO_INCREMENT PRIMARY KEY,
            question     TEXT          NOT NULL,
            wrong_answer TEXT,
            raw_feedback TEXT,
            submitted_at DATETIME      DEFAULT CURRENT_TIMESTAMP,
            resolved     TINYINT(1)    DEFAULT 0
        )
    """),
    ("sessions", """
        CREATE TABLE IF NOT EXISTS sessions (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            user_id     VARCHAR(64)   NOT NULL,
            channel_id  VARCHAR(64)   NOT NULL,
            last_active DATETIME      DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uniq_session (user_id, channel_id)
        )
    """),
]

DROP_ORDER = [
    "ticket_messages", "tickets", "ticket_counter",
    "sessions", "kb_corrections", "staff_overrides", "application_types",
]

SEED_APP_TYPES = [
    ("Whitelist",            "whitelist",    "https://web.goldenshoresrp.com/applications/apply/whitelist",   "✅", "whitelist-tickets"),
    ("Support",              "support",      "",                                                        "🎫", "Support-Ticket"),
    ("Business Application", "business",     "",                                                        "💼", "business-applications"),
    ("Gang Application",     "gang",         "",                                                        "🔫", "gang-applications"),
    ("1 of 1",               "1of1",         "",                                                        "⭐", "1of1-ticket"),
    ("Citizen Support",      "citizen",      "",                                                        "👤", "Citizen-Support"),
    ("Dispatch",             "dispatch",     "https://web.goldenshoresrp.com/applications/apply/dispatch",     "🚨", "dispatch-tickets"),
    ("East Customs",         "east-customs", "https://web.goldenshoresrp.com/applications/apply/east-customs", "🔧", "east-customs-tickets"),
    ("EMS",                  "ems",          "https://web.goldenshoresrp.com/applications/apply/ems",          "🏥", "ems-tickets"),
    ("Fire",                 "fire",         "https://web.goldenshoresrp.com/applications/apply/fire",         "🔥", "fire-tickets"),
    ("LS Customs",           "ls-customs",   "https://web.goldenshoresrp.com/applications/apply/ls-customs",   "🚗", "ls-customs-tickets"),
    ("Police",               "police",       "https://web.goldenshoresrp.com/applications/apply/police",       "👮", "police-tickets"),
    ("Tuner Shop",           "tuner-shop",   "https://web.goldenshoresrp.com/applications/apply/tuner-shop",   "🔩", "tuner-shop-tickets"),
]


def _gen_password(length=32):
    return "".join(secrets.choice(string.ascii_letters + string.digits + "!@#^&*")
                   for _ in range(length))


def _try_root_connect(host, port):
    for kwargs in [
        dict(unix_socket="/var/run/mysqld/mysqld.sock", user="root", password=""),
        dict(unix_socket="/tmp/mysql.sock",             user="root", password=""),
        dict(host=host, port=port, user="root", password=""),
        dict(host=host, port=port, user="root", password="root"),
        dict(host=host, port=port, user="root", password="mysql"),
        dict(host=host, port=port, user="root", password="mariadb"),
    ]:
        try:
            return pymysql.connect(charset="utf8mb4", connect_timeout=3, **kwargs)
        except Exception:
            continue
    return None


class DatabaseManager:
    def __init__(self):
        load_dotenv(ENV_FILE)
        self.host     = os.getenv("DB_HOST",     "localhost")
        self.port     = int(os.getenv("DB_PORT", "3306"))
        self.user     = os.getenv("DB_USER",     "")
        self.password = os.getenv("DB_PASSWORD", "")
        self.db_name  = os.getenv("DB_NAME",     DB_NAME)

    # ── Boot ──────────────────────────────────────────────────────────────────

    def initialise(self):
        if not (self.user and self.password):
            self._provision()
        self._ensure_all_tables()
        self._auto_migrate()
        self._seed_app_types()
        log.info("Database ready.")

    def _provision(self):
        root = _try_root_connect(self.host, self.port)
        if not root:
            raise RuntimeError("Cannot connect as root. Add DB_PASSWORD to .env once.")
        pw = _gen_password()
        try:
            with root.cursor() as cur:
                cur.execute(f"CREATE DATABASE IF NOT EXISTS `{DB_NAME}` "
                            f"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
                cur.execute(f"DROP USER IF EXISTS '{DB_USER}'@'localhost'")
                cur.execute(f"CREATE USER '{DB_USER}'@'localhost' IDENTIFIED BY %s", (pw,))
                cur.execute(f"GRANT ALL PRIVILEGES ON `{DB_NAME}`.* TO '{DB_USER}'@'localhost'")
                cur.execute("FLUSH PRIVILEGES")
            root.commit()
        finally:
            root.close()
        abs_env = os.path.abspath(ENV_FILE)
        set_key(abs_env, "DB_HOST", self.host)
        set_key(abs_env, "DB_PORT", str(self.port))
        set_key(abs_env, "DB_NAME", DB_NAME)
        set_key(abs_env, "DB_USER", DB_USER)
        set_key(abs_env, "DB_PASSWORD", pw)
        self.user     = DB_USER
        self.password = pw
        self.db_name  = DB_NAME
        log.info("Provisioned MySQL user and saved credentials.")

    # ── Connection ────────────────────────────────────────────────────────────

    def _connect(self):
        return pymysql.connect(
            host=self.host, port=self.port,
            user=self.user, password=self.password,
            database=self.db_name, charset="utf8mb4",
            cursorclass=DictCursor, autocommit=False,
        )

    # ── Schema ────────────────────────────────────────────────────────────────

    def _ensure_all_tables(self):
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                for _, sql in TABLES_IN_ORDER:
                    cur.execute(sql.strip())
            conn.commit()
        finally:
            conn.close()

    def _auto_migrate(self):
        """Add missing columns, fix wrong types, and clear bad config — safe to call every startup."""
        migrations = [
            ("tickets", "ticket_number",  "VARCHAR(16)  NOT NULL DEFAULT ''", "FIRST"),
            ("tickets", "opened_by_name", "VARCHAR(100) NOT NULL DEFAULT ''", "AFTER user_id"),
            ("tickets", "opened_at",      "DATETIME NULL",                    "AFTER opened_by_name"),
        ]
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                for table, col, col_def, pos in migrations:
                    cur.execute(
                        "SELECT DATA_TYPE, COLUMN_TYPE FROM information_schema.columns "
                        "WHERE table_schema=%s AND table_name=%s AND column_name=%s",
                        (self.db_name, table, col)
                    )
                    row = cur.fetchone()
                    if row is None:
                        cur.execute(f"ALTER TABLE `{table}` ADD COLUMN `{col}` {col_def} {pos}")
                        log.info(f"Migration: added `{col}` to `{table}`")
                    else:
                        if col == "opened_at" and "varchar" in row["DATA_TYPE"].lower():
                            cur.execute(f"ALTER TABLE `{table}` MODIFY COLUMN `{col}` DATETIME NULL")
                            log.info(f"Migration: fixed type of `{col}` in `{table}`")

                # ── Clear any auto_role_id that was accidentally set to the staff role ──
                # This prevents regular users from being granted staff permissions
                # when their ticket is closed or their application is approved.
                staff_role_id = os.getenv("STAFF_ROLE_ID", "")
                if staff_role_id:
                    cur.execute(
                        "UPDATE application_types SET auto_role_id = NULL "
                        "WHERE auto_role_id = %s",
                        (str(staff_role_id),)
                    )
                    if cur.rowcount:
                        log.warning(
                            "Migration: cleared staff role (%s) from auto_role_id on %d "
                            "ticket type(s). Use !manage-roles to set the correct role.",
                            staff_role_id, cur.rowcount,
                        )

            conn.commit()
            log.info("Auto-migration done.")
        finally:
            conn.close()

    def drop_all_tables(self):
        """Drop every table in safe order (called by !setup-tickets reset)."""
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SET FOREIGN_KEY_CHECKS=0")
                for table in DROP_ORDER:
                    cur.execute(f"DROP TABLE IF EXISTS `{table}`")
                    log.info(f"Dropped table `{table}`")
                cur.execute("SET FOREIGN_KEY_CHECKS=1")
            conn.commit()
            log.info("All tables dropped.")
        finally:
            conn.close()

    def reset(self):
        """Full wipe + recreate + seed."""
        self.drop_all_tables()
        self._ensure_all_tables()
        self._seed_app_types()
        log.info("Database fully reset.")

    def ensure_tables(self):
        try:
            self._ensure_all_tables()
            self._auto_migrate()
        except Exception as e:
            log.warning(f"ensure_tables: {e}")

    def _seed_app_types(self):
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                for name, key, url, emoji, ch_name in SEED_APP_TYPES:
                    cur.execute(
                        "INSERT IGNORE INTO application_types "
                        "(name, app_key, apply_url, emoji, channel_name) VALUES (%s,%s,%s,%s,%s)",
                        (name, key, url, emoji, ch_name),
                    )
            conn.commit()
        finally:
            conn.close()

    # ── Ticket counter ────────────────────────────────────────────────────────

    def next_ticket_number(self) -> str:
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("INSERT INTO ticket_counter (id, counter) VALUES (1,1) "
                            "ON DUPLICATE KEY UPDATE counter = counter + 1")
                cur.execute("SELECT counter FROM ticket_counter WHERE id=1")
                row = cur.fetchone()
            conn.commit()
            return f"TICK-{row['counter']:04d}"
        finally:
            conn.close()

    # ── Ticket CRUD ───────────────────────────────────────────────────────────

    def create_ticket(self, channel_id, user_id, app_key,
                      ticket_number="", opened_by_name="", opened_at=None):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO tickets "
                    "(ticket_number, channel_id, user_id, app_key, opened_by_name, opened_at) "
                    "VALUES (%s,%s,%s,%s,%s,%s)",
                    (ticket_number, str(channel_id), str(user_id),
                     app_key, opened_by_name, opened_at),
                )
                conn.commit()
                return cur.lastrowid
        finally:
            conn.close()

    def get_ticket_by_channel(self, channel_id):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM tickets WHERE channel_id=%s", (str(channel_id),))
                return cur.fetchone()
        finally:
            conn.close()

    def get_open_ticket(self, user_id, app_key):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM tickets WHERE user_id=%s AND app_key=%s AND status='open'",
                            (str(user_id), app_key))
                return cur.fetchone()
        finally:
            conn.close()

    def close_ticket(self, channel_id, closed_by_id):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("UPDATE tickets SET status='closed', closed_at=NOW(), closed_by=%s "
                            "WHERE channel_id=%s", (str(closed_by_id), str(channel_id)))
            conn.commit()
        finally:
            conn.close()

    def claim_ticket(self, channel_id, staff_id):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("UPDATE tickets SET claimed_by=%s WHERE channel_id=%s",
                            (str(staff_id), str(channel_id)))
            conn.commit()
        finally:
            conn.close()

    def get_all_open_tickets(self):
        """Return all tickets with status=open."""
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM tickets WHERE status='open' ORDER BY id")
                return cur.fetchall()
        finally:
            conn.close()

    # ── Application types ─────────────────────────────────────────────────────

    def get_all_types(self):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM application_types ORDER BY id")
                return cur.fetchall()
        finally:
            conn.close()

    def get_type(self, app_key):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM application_types WHERE app_key=%s", (app_key,))
                return cur.fetchone()
        finally:
            conn.close()

    def add_type(self, name, app_key, url, emoji, channel_name):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO application_types (name, app_key, apply_url, emoji, channel_name) "
                    "VALUES (%s,%s,%s,%s,%s)",
                    (name, app_key, url, emoji, channel_name),
                )
            conn.commit()
        finally:
            conn.close()

    def update_type(self, app_key, url=None, emoji=None, name=None, channel_name=None):
        """
        Update one or more fields of a ticket type.
        All parameters are optional — only supplied fields are updated.
        """
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                if url is not None:
                    cur.execute(
                        "UPDATE application_types SET apply_url=%s WHERE app_key=%s",
                        (url, app_key),
                    )
                if emoji is not None:
                    cur.execute(
                        "UPDATE application_types SET emoji=%s WHERE app_key=%s",
                        (emoji, app_key),
                    )
                if name is not None:
                    cur.execute(
                        "UPDATE application_types SET name=%s WHERE app_key=%s",
                        (name, app_key),
                    )
                if channel_name is not None:
                    cur.execute(
                        "UPDATE application_types SET channel_name=%s WHERE app_key=%s",
                        (channel_name, app_key),
                    )
            conn.commit()
        finally:
            conn.close()

    def delete_type(self, app_key):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("DELETE FROM application_types WHERE app_key=%s", (app_key,))
            conn.commit()
        finally:
            conn.close()

    def set_type_category(self, app_key, category_id):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("UPDATE application_types SET category_id=%s WHERE app_key=%s",
                            (str(category_id), app_key))
            conn.commit()
        finally:
            conn.close()

    def set_auto_role(self, app_key, role_id):
        """
        Set (or clear) the auto-assign role for a ticket type.
        Pass role_id=None to store SQL NULL — not the string "None".
        """
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                value = str(role_id) if role_id is not None else None
                cur.execute(
                    "UPDATE application_types SET auto_role_id=%s WHERE app_key=%s",
                    (value, app_key),
                )
            conn.commit()
        finally:
            conn.close()

    # ── Silence overrides ─────────────────────────────────────────────────────

    def get_silenced(self):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT type, target_id FROM staff_overrides")
                rows = cur.fetchall()
            result = {"silenced_users": [], "silenced_channels": []}
            for row in rows:
                key = "silenced_users" if row["type"] == "user" else "silenced_channels"
                result[key].append(int(row["target_id"]))
            return result
        finally:
            conn.close()

    def silence(self, kind, target_id, set_by):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT IGNORE INTO staff_overrides (type, target_id, set_by) VALUES (%s,%s,%s)",
                    (kind, str(target_id), str(set_by)),
                )
            conn.commit()
        finally:
            conn.close()

    def unsilence(self, kind, target_id):
        self.ensure_tables()
        conn = self._connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "DELETE FROM staff_overrides WHERE type=%s AND target_id=%s",
                    (kind, str(target_id)),
                )
            conn.commit()
        finally:
            conn.close()


db = DatabaseManager()
