"""
TeamTreck Agent - configuration.

Config lives in a JSON file in the user's home directory so it survives
reinstalls/updates. Created with sane defaults on first run if missing.
"""
import json
import os
from pathlib import Path

CONFIG_DIR = Path.home() / '.teamtreck-agent'
CONFIG_FILE = CONFIG_DIR / 'config.json'
QUEUE_DB = CONFIG_DIR / 'queue.db'

DEFAULT_CONFIG = {
    "server_url": "http://localhost:5050",
    "api_token": "",
    "screenshot_interval_seconds": 600,     # 10 min - matches TeamTreck's "every 5/10/15 min" examples
    "activity_report_interval_seconds": 300,  # 5 min
    "sync_interval_seconds": 60,
    "idle_threshold_seconds": 120,
}


def ensure_config_dir():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_config():
    ensure_config_dir()
    if not CONFIG_FILE.exists():
        save_config(DEFAULT_CONFIG)
        return dict(DEFAULT_CONFIG)

    with open(CONFIG_FILE, 'r') as f:
        cfg = json.load(f)

    # backfill any missing keys added in later versions
    changed = False
    for k, v in DEFAULT_CONFIG.items():
        if k not in cfg:
            cfg[k] = v
            changed = True
    if changed:
        save_config(cfg)

    return cfg


def save_config(cfg):
    ensure_config_dir()
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)


def set_token(token):
    cfg = load_config()
    cfg['api_token'] = token
    save_config(cfg)


def set_server_url(url):
    cfg = load_config()
    cfg['server_url'] = url.rstrip('/')
    save_config(cfg)
