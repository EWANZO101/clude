"""Entrypoint: `python3 run.py`"""
import os
from dotenv import load_dotenv
load_dotenv()  # loads .env from current directory

from app import create_app

app = create_app()

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5041))
    debug = os.environ.get("FLASK_DEBUG", "true").lower() == "true"
    app.run(host="0.0.0.0", port=port, debug=debug)
