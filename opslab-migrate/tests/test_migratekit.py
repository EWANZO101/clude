"""Offline unit tests — no SSH needed."""

import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from migratekit.config import (BackupConfig, Config, ConfigError, HostConfig,
                               load_config, redact)
from migratekit.discovery import DB_URI_RE, Discoverer, SCHEME_TO_ENGINE
from migratekit.report import Reporter, _fmt_bytes, _fmt_duration
from migratekit.state import MigrationState


# ------------------------------------------------------------------ config

def _write_key(tmp_path: Path) -> Path:
    key = tmp_path / "id_test"
    key.write_text("fake key")
    key.chmod(0o600)
    return key


def test_load_config_valid(tmp_path):
    key = _write_key(tmp_path)
    cfg_file = tmp_path / "config.yaml"
    cfg_file.write_text(f"""
source:
  host: 10.0.0.1
  username: root
  ssh_key: {key}
destination:
  host: 10.0.0.2
  username: root
  ssh_key: {key}
backup:
  compression: zstd
  keep_days: 7
""")
    cfg = load_config(cfg_file)
    assert cfg.source.host == "10.0.0.1"
    assert cfg.backup.keep_days == 7


def test_config_rejects_same_host(tmp_path):
    key = _write_key(tmp_path)
    cfg_file = tmp_path / "config.yaml"
    cfg_file.write_text(f"""
source: {{host: 10.0.0.1, username: root, ssh_key: {key}}}
destination: {{host: 10.0.0.1, username: root, ssh_key: {key}}}
""")
    with pytest.raises(ConfigError, match="different hosts"):
        load_config(cfg_file)


def test_config_rejects_bad_compression(tmp_path):
    key = _write_key(tmp_path)
    cfg_file = tmp_path / "config.yaml"
    cfg_file.write_text(f"""
source: {{host: a, username: root, ssh_key: {key}}}
destination: {{host: b, username: root, ssh_key: {key}}}
backup: {{compression: rar}}
""")
    with pytest.raises(ConfigError, match="compression"):
        load_config(cfg_file)


def test_config_rejects_insecure_key(tmp_path):
    key = tmp_path / "id_open"
    key.write_text("k")
    key.chmod(0o644)
    with pytest.raises(ConfigError, match="insecure permissions"):
        HostConfig("h", "u", str(key)).validate("source")


def test_redact_hides_credentials():
    samples = [
        ("mysql://bob:s3cret@localhost/db", "s3cret"),
        ("PASSWORD = hunter2", "hunter2"),
        ("mysqldump -pTopSecret db", "TopSecret"),
    ]
    for text, secret in samples:
        assert secret not in redact(text)


# --------------------------------------------------------------- discovery

@pytest.mark.parametrize("line,engine,name", [
    ("SQLALCHEMY_DATABASE_URI = 'postgresql://u:p@localhost:5432/appdb'",
     "postgresql", "appdb"),
    ('DATABASE_URL="mysql+pymysql://root:pw@127.0.0.1/stock"',
     "mysql", "stock"),
    ("SQLALCHEMY_DATABASE_URI = 'sqlite:///instance/app.db'",
     "sqlite", "app.db"),
    ("DATABASE_URL=redis://localhost:6379/0", "redis", "0"),
])
def test_db_uri_parsing(line, engine, name):
    m = DB_URI_RE.search(line)
    assert m, f"regex missed: {line}"
    d = Discoverer.__new__(Discoverer)
    db = d._parse_uri(m.group("uri"), "/opt/app")
    assert db is not None
    assert db.engine == engine
    assert db.name == name


def test_db_uri_credentials_extracted():
    d = Discoverer.__new__(Discoverer)
    db = d._parse_uri("postgresql://alice:hunter2@db.internal:5433/prod",
                      "/opt/app")
    assert db.user == "alice"
    assert db.password == "hunter2"
    assert db.host == "db.internal"
    assert db.port == 5433


def test_relative_sqlite_resolved_against_project():
    d = Discoverer.__new__(Discoverer)
    db = d._parse_uri("sqlite:///data/app.db", "/opt/myapp")
    assert db.sqlite_path == "/opt/myapp/data/app.db"


def test_all_schemes_mapped():
    for scheme in ("sqlite", "mysql", "postgresql", "mongodb", "redis"):
        assert scheme in SCHEME_TO_ENGINE


# -------------------------------------------------------------------- state

def test_state_resume_roundtrip(tmp_path):
    f = tmp_path / "migration_state.json"
    st = MigrationState(f)
    st.set_phase("app1", "backed_up", archive="/tmp/a.tar.zst", sha256="ab")
    st.set_phase("app1", "transferred", dest_archive="/tmp/b")
    assert st.phase_reached("app1", "backed_up")
    assert not st.phase_reached("app1", "restored")

    st2 = MigrationState(f)  # reload from disk
    assert st2.phase("app1") == "transferred"
    assert st2.project("app1")["archive"] == "/tmp/a.tar.zst"


def test_state_failed_not_reached(tmp_path):
    st = MigrationState(tmp_path / "s.json")
    st.set_phase("x", "failed", error="boom")
    assert not st.phase_reached("x", "backed_up")
    assert st.pending_projects(["x", "y"]) == ["x", "y"]


# ------------------------------------------------------------------ report

def test_report_generation(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    summary = {
        "source": "a", "destination": "b", "duration_seconds": 3723,
        "projects": [{
            "name": "app1", "framework": "flask", "status": "done",
            "size": 1048576, "sha256": "ab" * 32, "transfer_seconds": 10,
            "databases": [{"engine": "sqlite", "name": "app.db"}],
            "checks": [{"name": "port 8000 listening", "passed": True,
                        "detail": ""},
                       {"name": "nginx config valid", "passed": False,
                        "detail": "syntax error"}],
        }],
        "warnings": ["app1: 1 verification check(s) still failing"],
        "heal_actions": ["app1: restarted service app1.service"],
        "disk_free_mb": 20480,
    }
    paths = Reporter(summary).write_all()
    for kind, p in paths.items():
        assert p.exists() and p.stat().st_size > 0, kind
    html = paths["html"].read_text()
    assert "app1" in html and "syntax error" in html
    data = json.loads(paths["json"].read_text())
    assert data["projects"][0]["name"] == "app1"
    txt = paths["txt"].read_text()
    assert "01:02:03" in txt  # duration formatting


def test_fmt_helpers():
    assert _fmt_bytes(1536) == "1.5 KB"
    assert _fmt_duration(61) == "00:01:01"


# ---------------------------------------------------------- password auth

def test_config_password_auth(tmp_path):
    cfg_file = tmp_path / "config.yaml"
    cfg_file.write_text("""
source: {host: a, username: root, password: hunter2}
destination: {host: b, username: root, password: hunter2}
""")
    cfg = load_config(cfg_file)
    assert cfg.source.uses_password
    assert cfg.source.password == "hunter2"


def test_config_requires_key_or_password(tmp_path):
    cfg_file = tmp_path / "config.yaml"
    cfg_file.write_text("""
source: {host: a, username: root}
destination: {host: b, username: root, password: x}
""")
    with pytest.raises(ConfigError, match="ssh_key or password"):
        load_config(cfg_file)


def test_redact_sshpass():
    assert "hunter2" not in redact("SSHPASS=hunter2 sshpass -e rsync ...")
