import time

def stamp(msg):
    print(f"[{time.time()-t0:6.2f}s] {msg}", flush=True)

t0 = time.time()
stamp("importing...")
from app import create_app
from app.settings import load_settings, resolve_bind_host
from sync_loop import start_sync_loop
from backup_loop import start_backup_loop
from relay_client import start_relay_client
from waitress import serve

stamp("create_app() starting")
app = create_app()
stamp("create_app() done")

settings = load_settings(app.config["DATA_DIR"])
host = resolve_bind_host(settings)
port = settings.get("port", 8420)
stamp(f"resolved host={host} port={port} bind_mode={settings.get('bind_mode')}")

if app.config.get("SYNC_ENGINE"):
    start_sync_loop(app)
    stamp("start_sync_loop done")
else:
    stamp("SYNC_ENGINE not configured, skipping")

start_backup_loop(app)
stamp("start_backup_loop done")

start_relay_client(app)
stamp("start_relay_client done")

stamp("calling waitress.serve() now -- this should print almost immediately after, then block")
serve(app, host=host, port=port, threads=8)