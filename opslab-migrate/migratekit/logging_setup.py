"""Logging: logs/migration.log, backup.log, restore.log, verify.log, errors.log."""

from __future__ import annotations

import logging
from pathlib import Path

from .config import redact

LOG_DIR = Path("logs")
_FMT = "%(asctime)s [%(levelname)-7s] %(name)s: %(message)s"


class RedactingFormatter(logging.Formatter):
    """Never write plaintext credentials to disk."""

    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


def _file_handler(filename: str, level: int = logging.DEBUG) -> logging.Handler:
    LOG_DIR.mkdir(exist_ok=True)
    h = logging.FileHandler(LOG_DIR / filename, encoding="utf-8")
    h.setLevel(level)
    h.setFormatter(RedactingFormatter(_FMT))
    return h


def setup_logging(verbose: bool = False) -> None:
    root = logging.getLogger("migratekit")
    root.setLevel(logging.DEBUG)
    root.handlers.clear()

    # Master log — everything
    root.addHandler(_file_handler("migration.log"))

    # Errors from anywhere
    root.addHandler(_file_handler("errors.log", logging.ERROR))

    # Phase-specific logs
    for phase in ("backup", "restore", "verify", "transfer", "discovery", "heal"):
        h = _file_handler(f"{phase}.log")
        logging.getLogger(f"migratekit.{phase}").addHandler(h)


def get_logger(phase: str) -> logging.Logger:
    return logging.getLogger(f"migratekit.{phase}")
