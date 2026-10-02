"""
run.py — start the StockTool admin frontend using waitress. This process
never touches a database; it's a pure client of stocktool-api (see
config.py's API_BASE_URL).
"""
from adminapp import create_app
from config import Config

app = create_app()

if __name__ == "__main__":
    host = Config.HOST
    port = Config.PORT

    try:
        from waitress import serve
        print(f"StockTool admin frontend starting on http://{host}:{port}")
        print(f"Talking to StockTool API at {Config.API_BASE_URL}")
        print("Press Ctrl+C to stop.")
        serve(app, host=host, port=port, threads=4)
    except ImportError:
        print("waitress not found — using Flask dev server (not for production)")
        app.run(host=host, port=port, debug=False)
