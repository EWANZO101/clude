"""
Long-polls remote.opslabsystems.cloud for proxied HTTP requests from the
portal (see stocktool-remote/app.py for the server side), executes each
one against this kiosk's own 127.0.0.1:<port>, and posts the response
back. No-ops entirely until paired (settings.json has
setup_installation_token) -- same dormant-until-configured pattern as
backup_loop.py. Outbound-only, same as everything else added for cloud
pairing: nothing here opens an inbound port or changes bind_mode.

FIXED: the original version read settings.json exactly ONCE, at
start_relay_client() call time, and if no token existed yet it returned
None immediately -- meaning if this app was already running when
pairing completed (e.g. `--cloud-setup` run as a separate process
against an already-running kiosk), the relay thread would NEVER start
at all, not even with a stale token, until the whole app was manually
restarted. The loop now re-checks settings.json on every cycle until a
token appears, so pairing that happens after boot is picked up
automatically, with no restart needed.
"""
import base64
import json
import logging
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("relay_client")

POLL_TIMEOUT_SECONDS = 35       # client-side socket timeout for the long-poll GET --
                                # the relay holds this connection open for up to
                                # POLL_WAIT_SECONDS=25 (see stocktool-remote/app.py)
                                # before replying even with "no job", so this needs a
                                # real buffer above that for the full network round
                                # trip -- 30s left almost no margin and caused constant
                                # spurious timeouts on networks with any real latency,
                                # proxies, or firewalls that re-buffer traffic. Kept
                                # under gunicorn's own --timeout 40 worker ceiling on
                                # the relay side, so this can never outlive the server
                                # anyway.
LOCAL_REQUEST_TIMEOUT_SECONDS = 25
RETRY_BACKOFF_SECONDS = 5       # pause after a poll/respond failure before trying again
UNPAIRED_RECHECK_SECONDS = 10   # how often to re-check settings.json while waiting to be paired


def _poll_once(relay_base: str, token: str) -> dict | None:
    req = urllib.request.Request(
        f"{relay_base.rstrip('/')}/kiosk/poll",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT_SECONDS) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("job")


def _run_job_locally(job: dict, local_port: int) -> dict:
    method = job["method"]
    path = job["path"]
    headers = dict(job.get("headers", {}))
    headers["Host"] = f"127.0.0.1:{local_port}"  # not the relay's own Host
    body = base64.b64decode(job["body_b64"]) if job.get("body_b64") else None

    url = f"http://127.0.0.1:{local_port}{path}"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=LOCAL_REQUEST_TIMEOUT_SECONDS) as resp:
            resp_body = resp.read()
            return {
                "job_id": job["job_id"],
                "status": resp.status,
                "headers": dict(resp.headers.items()),
                "body_b64": base64.b64encode(resp_body).decode(),
            }
    except urllib.error.HTTPError as e:
        # A real HTTP error response (404, 500, ...) from the local app --
        # still a valid response to relay back, not a relay failure.
        resp_body = e.read()
        return {
            "job_id": job["job_id"],
            "status": e.code,
            "headers": dict(e.headers.items()) if e.headers else {},
            "body_b64": base64.b64encode(resp_body).decode(),
        }
    except (urllib.error.URLError, OSError) as exc:
        log.warning("Local request for job %s failed: %s", job.get("job_id"), exc)
        return {
            "job_id": job["job_id"],
            "status": 502,
            "headers": {"Content-Type": "text/plain"},
            "body_b64": base64.b64encode(b"Kiosk could not reach its own local app.").decode(),
        }


def _respond_once(relay_base: str, token: str, result: dict) -> None:
    body = json.dumps(result).encode("utf-8")
    req = urllib.request.Request(
        f"{relay_base.rstrip('/')}/kiosk/respond",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15):
        pass


def start_relay_client(app) -> "threading.Thread":
    from app.settings import load_settings

    data_dir = app.config["DATA_DIR"]

    def _current_pairing():
        """Re-reads settings.json fresh every call -- deliberately not
        cached at thread-start time, so pairing completed after this
        thread is already running gets picked up on the next check
        rather than requiring a restart."""
        settings = load_settings(data_dir)
        return settings.get("setup_installation_token"), settings.get("relay_api_base"), settings.get("port", 8420)

    def loop():
        token, relay_base, local_port = _current_pairing()
        if not token or not relay_base:
            log.info("Not paired with StockTool Setup yet — waiting (will start automatically once paired, no restart needed)...")

        while True:
            if not token or not relay_base:
                time.sleep(UNPAIRED_RECHECK_SECONDS)
                token, relay_base, local_port = _current_pairing()
                if token and relay_base:
                    log.info("Pairing detected — starting relay polling now.")
                continue

            try:
                job = _poll_once(relay_base, token)
            except (urllib.error.URLError, OSError) as exc:
                log.warning("Relay poll failed, retrying in %ds: %s", RETRY_BACKOFF_SECONDS, exc)
                time.sleep(RETRY_BACKOFF_SECONDS)
                # Re-read in case the token was rotated/fixed server-side
                # between failures (e.g. re-pairing after a bad token).
                token, relay_base, local_port = _current_pairing()
                continue
            except Exception:
                log.exception("Unexpected relay poll error")
                time.sleep(RETRY_BACKOFF_SECONDS)
                continue

            if not job:
                continue  # long-poll just timed out with nothing pending -- immediately re-poll

            try:
                result = _run_job_locally(job, local_port)
                _respond_once(relay_base, token, result)
            except Exception:
                log.exception("Failed handling relay job %s", job.get("job_id"))

    t = threading.Thread(target=loop, daemon=True, name="RelayClient")
    t.start()
    return t
