"""
run.py — start StockTool using waitress (production WSGI server).
Binds to 0.0.0.0:5030 so the app is reachable via CF tunnel or direct IP.
"""

from app import create_app

app = create_app()

if __name__ == "__main__":
    host = "0.0.0.0"
    port = 5030

    try:
        from waitress import serve

        print(f"StockTool starting on http://{host}:{port}")
        print("Press Ctrl+C to stop.")

        serve(
            app,
            host=host,
            port=port,
            threads=4
        )

    except ImportError:
        print("waitress not found — using Flask dev server (not for production)")

        app.run(
            host=host,
            port=port,
            debug=False
        )