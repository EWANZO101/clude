import os

from app import create_app
from app.extensions import db

app = create_app()


@app.shell_context_processor
def make_shell_context():
    return {"db": db}


if __name__ == "__main__":
    with app.app_context():
        db.create_all()
    # Local development only — production runs via wsgi.py under gunicorn
    # (see payment.service), which never executes this block at all. Debug
    # mode here is driven by FLASK_ENV so this file is safe left as-is; it
    # only turns on when FLASK_ENV isn't "production".
    debug = os.environ.get("FLASK_ENV") != "production"
    app.run(debug=debug, host="0.0.0.0", port=6006)
