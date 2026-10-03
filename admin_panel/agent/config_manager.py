"""
Implements the receive -> validate -> apply -> confirm -> report cycle from
spec Section 11, against the Admin Panel's /api/v1/instances/config
(poll) and /config/ack (report) endpoints built in the Admin Panel's Part 3.

'Apply' here means writing the config out to kiosk_config_path as JSON for
the Kiosk Application to read on its own next start/reload. The Kiosk
Application itself doesn't exist yet, so there's nothing to reload — this
module still does everything on the Agent's side honestly (real file write,
real validation, real ack), it just has no downstream consumer yet.
"""
import json
import logging
import os

from agent.api_client import ApiClient, ApiError
from agent.config import AgentSettings

log = logging.getLogger("agent.config_manager")


class ConfigValidationError(Exception):
    pass


def validate_config(config: dict) -> None:
    """Minimal validation available without a Kiosk Application schema to
    check against. Raises ConfigValidationError on anything that looks
    unsafe or malformed; a real schema check belongs here once the Kiosk
    Application defines what keys it actually expects."""
    if not isinstance(config, dict):
        raise ConfigValidationError("config must be a JSON object")


def apply_config(config: dict, kiosk_config_path: str) -> None:
    if not kiosk_config_path:
        raise ConfigValidationError(
            "kiosk_config_path is not set in agent settings — nothing to write to"
        )
    directory = os.path.dirname(kiosk_config_path)
    if directory:
        os.makedirs(directory, exist_ok=True)

    # Atomic write — a crash mid-write must never leave the Kiosk Application
    # reading a half-written config file.
    tmp_path = kiosk_config_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    os.replace(tmp_path, kiosk_config_path)


def check_and_apply(client: ApiClient, settings: AgentSettings, wait_seconds: float = 0) -> bool:
    """One poll cycle. Returns True if a config was found (regardless of
    whether it applied cleanly — check the logs/ack for the outcome),
    False if there was nothing pending."""
    result = client.get_config(wait_seconds=wait_seconds)
    pending = result.get("pending")
    if not pending:
        return False

    version = pending["version"]
    config = pending["config"]
    log.info("Applying pending config v%s", version)

    try:
        validate_config(config)
    except ConfigValidationError as e:
        log.error("Config v%s rejected by local validation: %s", version, e)
        client.ack_config(version, "rejected", str(e))
        return True

    try:
        apply_config(config, settings.kiosk_config_path)
    except Exception as e:
        log.exception("Failed to apply config v%s", version)
        client.ack_config(version, "failed", str(e))
        return True

    client.ack_config(version, "applied", "written to kiosk_config_path")
    log.info("Config v%s applied and acknowledged.", version)
    return True


def run_config_poll_loop(client: ApiClient, settings: AgentSettings, interval_seconds: int, stop_event,
                          long_poll_wait_seconds: float = 20):
    """Long-polls by default (see check_and_apply/ApiClient.get_config) so a
    config pushed from the Admin Panel (e.g. the Login Screen's
    tenant_name) reaches the Agent within about a second of Save, instead
    of waiting up to interval_seconds for the next ordinary poll.
    interval_seconds is still used, but only as the backoff after a failed
    poll (server unreachable, auth error, etc.) — not the steady-state
    cadence, which the long poll itself now provides. Mirrors
    run_command_poll_loop's identical reasoning in agent/commands.py."""
    while not stop_event.is_set():
        try:
            check_and_apply(client, settings, wait_seconds=long_poll_wait_seconds)
        except ApiError as e:
            log.warning("Config poll failed: %s", e)
            stop_event.wait(interval_seconds)
        except Exception:
            log.exception("Unexpected error during config poll")
            stop_event.wait(interval_seconds)
        # No wait on the ordinary path: the long poll above already waited
        # (up to long_poll_wait_seconds) when nothing was pending, and if a
        # config WAS found/applied, looping straight back around picks up
        # anything else already queued without delay.
