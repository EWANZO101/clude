# OpsLabs FiveM backup

Backup of the OpsLabs phone ecosystem for the ESX Legacy server.

| Folder | What it is |
|---|---|
| `resources/opslabs-phone` | OPS OS phone (iPhone-style), OPS Mobile carrier, camera, TIDAL / Spotify |
| `resources/opslabs-towers` | Cell towers & Wi-Fi coverage, CAT6 / fibre cabling, poles, ladders, ISP + ONT status lights |
| `resources/opslabs-props` | Custom 3D models (UniFi, TP-Link / Omada, telecom kit, cabling, ladders) + Blender build scripts in `source/` |
| `store` | opsphone-store Flask site (OPS Mobile shop + admin), systemd unit |
| `nginx` | nginx site configs for ops-phone / opsphone-store |

## Secrets are not in this repo
- `resources/opslabs-phone/config_server.lua` → copy `config_server.example.lua` and fill in the Spotify / TIDAL app keys and the Developer app login.
- `store/.env` → `SECRET_KEY`, `ADMIN_PASSWORD`, `PHONE_API_URL`, `PHONE_API_KEY`.
- `server.cfg` → `set opslabs_phone_api_key "..."` (same key as `PHONE_API_KEY`).

## Install
1. Copy the three resources into `resources/[rps]/` and `ensure opslabs-props`, `opslabs-towers`, `opslabs-phone` (needs oxmysql, ox_lib, es_extended).
2. Store: `python3 -m venv venv && venv/bin/pip install -r requirements.txt`, create `.env`, install `opsphone-store.service`.
