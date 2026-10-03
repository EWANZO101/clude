import os

from dotenv import load_dotenv

load_dotenv()  # no-op if .env doesn't exist; systemd sets env vars directly and doesn't need this

from app import create_app
from app.extensions import db

app = create_app(os.environ.get("FLASK_ENV", "development"))


@app.shell_context_processor
def make_shell_context():
    from app.models import User, Export, AuditLog
    return {"db": db, "User": User, "Export": Export, "AuditLog": AuditLog}


if __name__ == "__main__":
    is_windows = os.name == "nt"
    if is_windows:
        # Development convenience only — use Waitress for real Windows deployment.
        app.run(host="0.0.0.0", port=5000, debug=True)
    else:
        app.run(host="0.0.0.0", port=5000, debug=True)
