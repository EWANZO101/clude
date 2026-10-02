"""Gunicorn / CLI entrypoint."""
from motoguard import create_app

app = create_app()

if __name__ == "__main__":
    import os
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5060")), debug=True)
