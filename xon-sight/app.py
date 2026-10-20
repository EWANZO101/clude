from dotenv import load_dotenv

load_dotenv()

from xonsight import create_app  # noqa: E402

app = create_app()

if __name__ == "__main__":
    import os

    port = int(os.environ.get("PORT", 5010))
    app.run(host="0.0.0.0", port=port, debug=False, threaded=True)
