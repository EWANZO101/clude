"""Per-engine database backup and restore.

Backups are written on the *remote* host inside the project staging
directory, so they ride along in the project archive.
"""

from __future__ import annotations

import shlex
from typing import Optional

from .ssh import SSHConnection, SSHError
from .logging_setup import get_logger

log = get_logger("backup")


def _env_pw(password: str, var: str) -> str:
    """Pass a password via environment, never on the command line."""
    return f"{var}={shlex.quote(password)} " if password else ""


class DatabaseHandler:
    def __init__(self, ssh: SSHConnection):
        self.ssh = ssh

    # ------------------------------------------------------------- backup

    def backup(self, db: dict, dest_dir: str) -> Optional[str]:
        """Dump one database into dest_dir on the remote host.
        Returns the dump path, or None on failure."""
        engine = db.get("engine")
        name = db.get("name") or "db"
        safe = name.replace("/", "_")
        self.ssh.run(f"mkdir -p {shlex.quote(dest_dir)}", sudo=True)

        try:
            if engine == "sqlite":
                return self._backup_sqlite(db, dest_dir, safe)
            if engine in ("mysql", "mariadb"):
                return self._backup_mysql(db, dest_dir, safe)
            if engine == "postgresql":
                return self._backup_postgres(db, dest_dir, safe)
            if engine == "mongodb":
                return self._backup_mongo(db, dest_dir, safe)
            if engine == "redis":
                return self._backup_redis(db, dest_dir, safe)
        except SSHError as e:
            log.error("Backup failed for %s (%s): %s", name, engine, e)
            return None
        log.warning("Unknown database engine %r — skipped", engine)
        return None

    def _backup_sqlite(self, db: dict, dest: str, safe: str) -> Optional[str]:
        src = db.get("sqlite_path", "")
        if not src or not self.ssh.exists(src):
            log.warning("SQLite file missing: %s", src)
            return None
        out = f"{dest}/{safe}.sqlite"
        # Use sqlite3 .backup for a consistent snapshot when available,
        # falling back to a plain copy.
        if self.ssh.which("sqlite3"):
            r = self.ssh.run(
                f"sqlite3 {shlex.quote(src)} \".backup '{out}'\"", sudo=True)
            if r.ok:
                return out
            log.warning("sqlite3 .backup failed, falling back to cp: %s",
                        r.stderr.strip())
        self.ssh.run(f"cp -a {shlex.quote(src)} {shlex.quote(out)}",
                     sudo=True, check=True)
        return out

    def _backup_mysql(self, db: dict, dest: str, safe: str) -> str:
        out = f"{dest}/{safe}.sql"
        env = _env_pw(db.get("password", ""), "MYSQL_PWD")
        user = f"-u {shlex.quote(db['user'])}" if db.get("user") else ""
        host = f"-h {shlex.quote(db.get('host', 'localhost'))}"
        port = f"-P {db['port']}" if db.get("port") else ""
        self.ssh.run(
            f"{env}mysqldump --single-transaction --routines --triggers "
            f"{user} {host} {port} {shlex.quote(db['name'])} "
            f"> {shlex.quote(out)}",
            sudo=True, check=True, timeout=3600)
        return out

    def _backup_postgres(self, db: dict, dest: str, safe: str) -> str:
        out = f"{dest}/{safe}.pgdump"
        env = _env_pw(db.get("password", ""), "PGPASSWORD")
        user = f"-U {shlex.quote(db['user'])}" if db.get("user") else ""
        host = f"-h {shlex.quote(db.get('host', 'localhost'))}"
        port = f"-p {db['port']}" if db.get("port") else ""
        self.ssh.run(
            f"{env}pg_dump -Fc {user} {host} {port} "
            f"{shlex.quote(db['name'])} -f {shlex.quote(out)}",
            sudo=True, check=True, timeout=3600)
        return out

    def _backup_mongo(self, db: dict, dest: str, safe: str) -> str:
        out = f"{dest}/{safe}.mongodump"
        auth = ""
        if db.get("user"):
            auth = (f"-u {shlex.quote(db['user'])} "
                    f"-p {shlex.quote(db.get('password', ''))} "
                    f"--authenticationDatabase admin ")
        host = db.get("host", "localhost")
        port = db.get("port") or 27017
        self.ssh.run(
            f"mongodump --host {shlex.quote(host)} --port {port} {auth}"
            f"--db {shlex.quote(db['name'])} --out {shlex.quote(out)}",
            sudo=True, check=True, timeout=3600)
        return out

    def _backup_redis(self, db: dict, dest: str, safe: str) -> Optional[str]:
        out = f"{dest}/{safe}.rdb"
        # Trigger a synchronous save, then copy the RDB file.
        self.ssh.run("redis-cli SAVE", sudo=True)
        r = self.ssh.run("redis-cli CONFIG GET dir | tail -1", sudo=True)
        rdb_dir = r.stdout.strip() or "/var/lib/redis"
        rdb = f"{rdb_dir}/dump.rdb"
        if not self.ssh.exists(rdb):
            log.warning("Redis RDB not found at %s", rdb)
            return None
        self.ssh.run(f"cp -a {shlex.quote(rdb)} {shlex.quote(out)}",
                     sudo=True, check=True)
        return out

    # ------------------------------------------------------------- restore

    def restore(self, db: dict, dump_path: str) -> bool:
        engine = db.get("engine")
        try:
            if engine == "sqlite":
                target = db.get("sqlite_path", "")
                if target:
                    self.ssh.run(
                        f"mkdir -p $(dirname {shlex.quote(target)}) && "
                        f"cp -a {shlex.quote(dump_path)} {shlex.quote(target)}",
                        sudo=True, check=True)
                return True
            if engine in ("mysql", "mariadb"):
                return self._restore_mysql(db, dump_path)
            if engine == "postgresql":
                return self._restore_postgres(db, dump_path)
            if engine == "mongodb":
                return self._restore_mongo(db, dump_path)
            if engine == "redis":
                return self._restore_redis(dump_path)
        except SSHError as e:
            log.error("Restore failed for %s (%s): %s",
                      db.get("name"), engine, e)
            return False
        return False

    def _restore_mysql(self, db: dict, dump: str) -> bool:
        env = _env_pw(db.get("password", ""), "MYSQL_PWD")
        user = f"-u {shlex.quote(db['user'])}" if db.get("user") else ""
        name = shlex.quote(db["name"])
        # Ensure the database and user exist first (root socket auth).
        self.ssh.run(
            f"mysql -e 'CREATE DATABASE IF NOT EXISTS `{db['name']}`'",
            sudo=True)
        if db.get("user") and db.get("password"):
            self.ssh.run(
                "mysql -e \"CREATE USER IF NOT EXISTS "
                f"'{db['user']}'@'localhost' IDENTIFIED BY "
                f"'{db['password']}'; GRANT ALL ON `{db['name']}`.* TO "
                f"'{db['user']}'@'localhost'; FLUSH PRIVILEGES\"",
                sudo=True)
        self.ssh.run(f"{env}mysql {user} {name} < {shlex.quote(dump)}",
                     sudo=True, check=True, timeout=3600)
        return True

    def _restore_postgres(self, db: dict, dump: str) -> bool:
        name = db["name"]
        user = db.get("user", "")
        if user:
            self.ssh.run(
                f"sudo -u postgres psql -tc \"SELECT 1 FROM pg_roles "
                f"WHERE rolname='{user}'\" | grep -q 1 || "
                f"sudo -u postgres psql -c \"CREATE ROLE {user} LOGIN "
                f"PASSWORD '{db.get('password', '')}'\"")
        self.ssh.run(
            f"sudo -u postgres psql -tc \"SELECT 1 FROM pg_database "
            f"WHERE datname='{name}'\" | grep -q 1 || "
            f"sudo -u postgres createdb -O {user or 'postgres'} {name}")
        self.ssh.run(
            f"sudo -u postgres pg_restore --clean --if-exists "
            f"-d {shlex.quote(name)} {shlex.quote(dump)}",
            check=True, timeout=3600)
        return True

    def _restore_mongo(self, db: dict, dump: str) -> bool:
        self.ssh.run(
            f"mongorestore --drop --db {shlex.quote(db['name'])} "
            f"{shlex.quote(dump)}/{shlex.quote(db['name'])}",
            sudo=True, check=True, timeout=3600)
        return True

    def _restore_redis(self, dump: str) -> bool:
        r = self.ssh.run("redis-cli CONFIG GET dir | tail -1", sudo=True)
        rdb_dir = r.stdout.strip() or "/var/lib/redis"
        self.ssh.run("systemctl stop redis-server || systemctl stop redis",
                     sudo=True)
        self.ssh.run(
            f"cp -a {shlex.quote(dump)} {shlex.quote(rdb_dir)}/dump.rdb && "
            f"chown redis:redis {shlex.quote(rdb_dir)}/dump.rdb", sudo=True)
        self.ssh.run("systemctl start redis-server || systemctl start redis",
                     sudo=True)
        return True
