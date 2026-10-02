"""
Production entrypoint for Windows deployments (Waitress).

Usage:
    venv\\Scripts\\python.exe deploy\\serve_windows.py

For running as an actual Windows service, wrap this with NSSM
(https://nssm.cc/) pointing at the venv's python.exe with this script
as the argument — that gets you start/stop/auto-restart like any other
Windows service without writing a service wrapper by hand.
"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

from waitress import serve
from app import create_app

if __name__ == "__main__":
    app = create_app(os.environ.get("FLASK_ENV", "production"))
    host = os.environ.get("WAITRESS_HOST", "0.0.0.0")
    port = int(os.environ.get("WAITRESS_PORT", 8000))
    threads = int(os.environ.get("WAITRESS_THREADS", 8))

    print(f"Serving on {host}:{port} ({threads} threads)")
    serve(app, host=host, port=port, threads=threads, channel_timeout=1800)
