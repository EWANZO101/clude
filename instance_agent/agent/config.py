"""
Settings persistence for the Instance Agent.

Mirrors the StockTool Kiosk's settings.json pattern (bind mode, pairing
token, etc. — see the kiosk's own technical docs) but scoped to what the
Agent itself needs: where to find the Admin Panel, and the instance identity
issued at registration.

Default on-disk locations follow the same split the existing kiosk uses:
  - Windows service / Linux root install: a system-wide data directory
  - interactive / dev run: a local fallback next to the agent

This module never talks to the network — see identity.py and api_client.py.
"""
import json
import os
import platform
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Optional


def default_data_dir() -> Path:
    if platform.system() == "Windows":
        base = os.environ.get("PROGRAMDATA", r"C:\ProgramData")
        return Path(base) / "OpsLabAgent"
    # Linux: prefer /etc for a root-installed service, fall back to a local
    # dir for interactive/dev runs where /etc isn't writable.
    system_dir = Path("/etc/opslab-agent")
    if os.access("/etc", os.W_OK) or system_dir.exists():
        return system_dir
    return Path.home() / ".opslab-agent"


def default_settings_path() -> Path:
    env_override = os.environ.get("OPSLAB_SETTINGS_PATH")
    if env_override:
        return Path(env_override)
    return default_data_dir() / "settings.json"


def default_app_install_dir() -> Path:
    return default_data_dir() / "app"


def default_download_dir() -> Path:
    return default_data_dir() / "downloads"


def default_recovery_dir() -> Path:
    return default_data_dir() / "recovery"


@dataclass
class AgentSettings:
    admin_url: str = ""
    registration_token: str = ""  # consumed once at registration, then cleared

    instance_id: Optional[str] = None
    instance_secret: Optional[str] = None

    heartbeat_interval_seconds: int = 60
    config_poll_interval_seconds: int = 30
    update_poll_interval_seconds: int = 60

    # Where the Agent writes an applied kiosk config for the Kiosk Application
    # to read. The Kiosk Application itself isn't built yet (see the Admin
    # Panel's progress notes) — this path is honored on the Agent side
    # regardless, so nothing needs to change here once it exists.
    kiosk_config_path: str = ""

    # Update handling (Part 2): where the installed application's files live,
    # where downloaded packages land temporarily, and where recovery points
    # (Last Known Good snapshots) are kept — deliberately a separate tree
    # from app_install_dir per spec Section 46 ("Data protection... an
    # update should replace the application without accidentally deleting
    # customer data" — recovery data is never stored only inside the files
    # being replaced).
    app_install_dir: str = ""
    download_dir: str = ""
    recovery_dir: str = ""

    # Process supervision (Part 3): the command that starts the Kiosk
    # Application, and where to run it from. Empty command means "nothing to
    # supervise yet" — the Agent runs fine without this set (e.g. during
    # early bring-up before a Kiosk Application exists to point it at).
    kiosk_start_command: str = ""
    kiosk_working_dir: str = ""

    # Real health checks + automatic rollback (Part 4). Both check fields are
    # optional and mutually exclusive in practice (URL takes priority if both
    # are somehow set) — if neither is configured, the health check honestly
    # falls back to "is the supervised process still running" rather than
    # pretending to check something it can't.
    kiosk_health_check_url: str = ""       # e.g. http://127.0.0.1:8080/health
    kiosk_health_check_command: str = ""   # exit code 0 = healthy
    health_check_timeout_seconds: float = 5.0
    health_check_retries: int = 5
    health_check_retry_delay_seconds: float = 2.0
    # Grace period after (re)starting the process before the first health
    # check attempt — separate from retries, since a freshly-started app
    # legitimately needs a moment before it's even worth probing once.
    health_check_grace_period_seconds: float = 3.0

    # Remote tunnel polling (Part 6, stub — see agent/tunnel.py) and error
    # reporting (Part 6 — see agent/error_reporter.py), all optional with
    # sensible defaults.
    tunnel_poll_interval_seconds: int = 120
    error_report_max_per_window: int = 10
    error_report_window_seconds: float = 60.0
    error_report_dedup_seconds: float = 30.0

    extra: dict = field(default_factory=dict)  # forward-compatible catch-all

    def is_registered(self) -> bool:
        return bool(self.instance_id and self.instance_secret)

    def resolve_app_install_dir(self) -> str:
        return self.app_install_dir or str(default_app_install_dir())

    def resolve_download_dir(self) -> str:
        return self.download_dir or str(default_download_dir())

    def resolve_recovery_dir(self) -> str:
        return self.recovery_dir or str(default_recovery_dir())

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "AgentSettings":
        known = set(cls.__dataclass_fields__) - {"extra"}
        clean = {k: v for k, v in data.items() if k in known}
        leftover = {k: v for k, v in data.items() if k not in known and k != "extra"}
        clean["extra"] = {**data.get("extra", {}), **leftover}
        return cls(**clean)


def load_settings(path: Path = None) -> AgentSettings:
    path = path or default_settings_path()
    if not path.exists():
        return AgentSettings()
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return AgentSettings.from_dict(data)


def save_settings(settings: AgentSettings, path: Path = None) -> None:
    path = path or default_settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    # Atomic write — never leave settings.json half-written if the process
    # dies mid-save (this file holds the instance's only copy of its secret).
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(settings.to_dict(), f, indent=2)
    os.replace(tmp_path, path)
