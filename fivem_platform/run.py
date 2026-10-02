import os
from dotenv import load_dotenv

# Explicit path, not the default load_dotenv() which walks UP the
# directory tree looking for a .env - that silent fallback is what caused
# config changes to appear to do nothing whenever this file was missing
# and a totally different .env elsewhere on the system took over instead.
_ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
load_dotenv(_ENV_PATH)

from app import create_app  # noqa: E402
from app.extensions import db  # noqa: E402

app = create_app(os.environ.get("FLASK_ENV", "development"))


@app.shell_context_processor
def make_shell_context():
    from app.models.user import User, SupportAuditLog
    return {"db": db, "User": User, "SupportAuditLog": SupportAuditLog}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
