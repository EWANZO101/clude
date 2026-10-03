"""
Handles turning an enrollment token into a permanent instance identity
(spec Section 5/6: "Generate a unique instance identity" / "Connect/register
with the management service"). Runs at most once per install — after
that, settings.json already has instance_id/instance_secret and this
module is never called again unless someone deliberately re-provisions
the machine.
"""
import logging

from agent.api_client import ApiClient, ApiError
from agent.config import AgentSettings, save_settings
from agent import system_info

log = logging.getLogger("agent.identity")


class RegistrationError(Exception):
    pass


def ensure_registered(settings: AgentSettings, settings_path=None) -> AgentSettings:
    """If settings already has an identity, returns it unchanged. Otherwise
    consumes settings.registration_token to register, persists the result
    (including clearing the now-spent token), and returns the updated
    settings. Never leaves a half-registered state on disk: the file is only
    written once registration actually succeeds."""
    if settings.is_registered():
        return settings

    if not settings.admin_url:
        raise RegistrationError("admin_url is not set — nothing to register against")
    if not settings.registration_token:
        raise RegistrationError(
            "No instance identity on disk and no registration_token provided — "
            "this machine needs an enrollment token from the Admin Panel."
        )

    hostname = system_info.detect_hostname()
    os_name = system_info.detect_os()
    os_version = system_info.detect_os_version()

    log.info("Registering as a new instance (hostname=%s, os=%s)...", hostname, os_name)

    client = ApiClient(settings.admin_url)
    try:
        result = client.register(
            registration_token=settings.registration_token,
            hostname=hostname,
            os_name=os_name,
            os_version=os_version,
            agent_version=system_info.agent_version(),
        )
    except ApiError as e:
        raise RegistrationError(f"Registration rejected by Admin Panel: {e}") from e

    settings.instance_id = result["instance_id"]
    settings.instance_secret = result["instance_secret"]
    settings.registration_token = ""  # single-use — never keep it around after success

    save_settings(settings, settings_path)
    log.info(
        "Registered successfully as instance %s under company '%s'.",
        settings.instance_id, result.get("company_name"),
    )
    return settings
