"""
run.py — start StockTool API (backend + REST API + kiosk touch-UI) using
waitress (production WSGI server).
"""

from app import create_app

app = create_app()

if __name__ == "__main__":
    host = "0.0.0.0"
    port = 5032

    try:
        from waitress import serve
        print(f"StockTool API starting on http://{host}:{port}")
        print(f"Kiosk touch-UI available at http://{host}:{port}/kiosk/")
        print("Press Ctrl+C to stop.")
        serve(app, host=host, port=port, threads=4)
    except ImportError:
        print("waitress not found — using Flask dev server (not for production)")
        app.run(host=host, port=port, debug=False)