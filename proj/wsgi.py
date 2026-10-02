import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "app"))

from app import app  # noqa: E402

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=app.config["PORT"])
