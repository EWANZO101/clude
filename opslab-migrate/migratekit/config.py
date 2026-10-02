"""Configuration loading and validation (config.yaml)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import yaml

VALID_COMPRESSION = ("zstd", "gzip", "xz")


class ConfigError(Exception):
    pass


@dataclass
class HostConfig:
    host: str
    username: str
    ssh_key: str = ""
    password: str = ""      # plain password, or "ask" to prompt at runtime
    port: int = 22

    @property
    def uses_password(self) -> bool:
        return bool(self.password) and not self.ssh_key

    def resolve_password(self, label: str) -> None:
        """Prompt for the password now if configured as 'ask'."""
        if self.password == "ask":
            import getpass
            self.password = getpass.getpass(
                f"SSH password for {self.username}@{self.host} ({label}): ")

    def validate(self, label: str) -> None:
        if not self.host:
            raise ConfigError(f"{label}.host is required")
        if not self.username:
            raise ConfigError(f"{label}.username is required")
        if not self.ssh_key and not self.password:
            raise ConfigError(
                f"{label}: provide either ssh_key or password "
                f"(use 'password: ask' to be prompted at runtime)")
        if self.ssh_key:
            key = Path(os.path.expanduser(self.ssh_key))
            if not key.exists():
                raise ConfigError(f"{label}.ssh_key not found: {key}")
            mode = key.stat().st_mode & 0o777
            if mode & 0o077:
                raise ConfigError(
                    f"{label}.ssh_key has insecure permissions {oct(mode)} "
                    f"(expected 600): {key}"
                )


@dataclass
class BackupConfig:
    compression: str = "zstd"
    keep_days: int = 30
    include_venv: bool = False
    staging_dir: str = "/var/tmp/opslab-migrate"

    def validate(self) -> None:
        if self.compression not in VALID_COMPRESSION:
            raise ConfigError(
                f"backup.compression must be one of {VALID_COMPRESSION}, "
                f"got {self.compression!r}"
            )
        if self.keep_days < 1:
            raise ConfigError("backup.keep_days must be >= 1")


@dataclass
class RestoreConfig:
    overwrite: bool = False
    install_dependencies: bool = True
    restart_services: bool = True


@dataclass
class VerifyConfig:
    enabled: bool = True
    http_timeout: int = 15
    expect_status: tuple = (200, 301, 302)


@dataclass
class TransferConfig:
    bandwidth_limit_kbps: int = 0  # 0 = unlimited
    retries: int = 3
    checksum: bool = True


@dataclass
class HealConfig:
    enabled: bool = True
    max_attempts: int = 3


@dataclass
class Config:
    source: HostConfig
    destination: HostConfig
    backup: BackupConfig = field(default_factory=BackupConfig)
    restore: RestoreConfig = field(default_factory=RestoreConfig)
    verify: VerifyConfig = field(default_factory=VerifyConfig)
    transfer: TransferConfig = field(default_factory=TransferConfig)
    heal: HealConfig = field(default_factory=HealConfig)
    parallel_workers: int = 2
    projects: Optional[list] = None  # None = auto-discover all
    scan_roots: list = field(default_factory=lambda: [
        "/opt", "/srv", "/var/www", "/home", "/root",
    ])
    exclude_paths: list = field(default_factory=lambda: [
        "/proc", "/dev", "/sys", "/tmp", "/run", "/boot",
        "/var/lib/docker/overlay2", "/snap",
    ])

    def validate(self) -> None:
        self.source.validate("source")
        self.destination.validate("destination")
        self.backup.validate()
        if self.parallel_workers < 1:
            raise ConfigError("parallel_workers must be >= 1")
        if self.source.host == self.destination.host and \
                self.source.port == self.destination.port:
            raise ConfigError("source and destination must be different hosts")


def _host(d: dict, label: str) -> HostConfig:
    if not isinstance(d, dict):
        raise ConfigError(f"{label} section missing or invalid")
    return HostConfig(
        host=str(d.get("host", "")),
        username=str(d.get("username", "")),
        ssh_key=str(d.get("ssh_key", "") or ""),
        password=str(d.get("password", "") or ""),
        port=int(d.get("port", 22)),
    )


def load_config(path: str | Path) -> Config:
    """Load and validate config.yaml."""
    p = Path(path)
    if not p.exists():
        raise ConfigError(f"Config file not found: {p}")
    with open(p, "r", encoding="utf-8") as fh:
        raw: dict[str, Any] = yaml.safe_load(fh) or {}

    cfg = Config(
        source=_host(raw.get("source", {}), "source"),
        destination=_host(raw.get("destination", {}), "destination"),
        backup=BackupConfig(**(raw.get("backup") or {})),
        restore=RestoreConfig(**(raw.get("restore") or {})),
        verify=VerifyConfig(**{
            k: v for k, v in (raw.get("verify") or {}).items()
            if k in ("enabled", "http_timeout")
        }),
        transfer=TransferConfig(**(raw.get("transfer") or {})),
        heal=HealConfig(**(raw.get("heal") or {})),
        parallel_workers=int(raw.get("parallel_workers", 2)),
        projects=raw.get("projects"),
    )
    if raw.get("scan_roots"):
        cfg.scan_roots = list(raw["scan_roots"])
    if raw.get("exclude_paths"):
        cfg.exclude_paths = list(raw["exclude_paths"])
    cfg.validate()
    return cfg


def redact(text: str) -> str:
    """Redact anything that looks like a credential before logging."""
    import re
    patterns = [
        (r"(password['\"]?\s*[:=]\s*)['\"]?[^\s'\"]+", r"\1********"),
        (r"(passwd=)[^\s&]+", r"\1********"),
        (r"(://[^:/@\s]+:)[^@\s]+(@)", r"\1********\2"),
        (r"(SECRET[_A-Z]*\s*=\s*)\S+", r"\1********"),
        (r"(SSHPASS=)\S+", r"\1********"),
        (r"(MYSQL_PWD=)\S+", r"\1********"),
        (r"(PGPASSWORD=)\S+", r"\1********"),
        (r"(-p)[^\s]+", r"\1********"),  # mysqldump -pPASS
    ]
    for pat, rep in patterns:
        text = re.sub(pat, rep, text, flags=re.IGNORECASE)
    return text
