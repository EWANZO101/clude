"""Generic provider-adapter architecture (spec section 50): the hardware
catalog and seller-listing sync jobs are written against this interface
only, so adding a new external provider never touches the catalog models —
just register a new adapter class in PROVIDER_ADAPTERS.
"""

import requests


class ConnectionTestResult:
    def __init__(self, success, message):
        self.success = success
        self.message = message


class BaseProviderAdapter:
    provider_type = "base"

    def __init__(self, base_url, api_key=None):
        self.base_url = base_url
        self.api_key = api_key

    def test_connection(self) -> ConnectionTestResult:
        raise NotImplementedError

    def fetch_catalog(self):
        """Returns a list of raw provider records to be normalized and
        upserted into the hardware catalog. Not implemented for the
        generic adapter — real providers subclass this with their own
        response parsing."""
        raise NotImplementedError


class GenericRestAdapter(BaseProviderAdapter):
    """Minimal reference adapter: verifies the configured endpoint is
    reachable over HTTPS/HTTP. A real provider integration would subclass
    this and implement fetch_catalog() to parse that provider's response
    shape into the normalized hardware fields."""

    provider_type = "generic_rest"

    def test_connection(self) -> ConnectionTestResult:
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        try:
            resp = requests.get(self.base_url, headers=headers, timeout=8)
            if resp.status_code < 500:
                return ConnectionTestResult(True, f"Reachable (HTTP {resp.status_code}).")
            return ConnectionTestResult(False, f"Provider returned HTTP {resp.status_code}.")
        except requests.RequestException as exc:
            return ConnectionTestResult(False, str(exc))

    def fetch_catalog(self):
        raise NotImplementedError("Connect a real hardware provider by subclassing GenericRestAdapter.")


PROVIDER_ADAPTERS = {
    "generic_rest": GenericRestAdapter,
}


def get_adapter(provider_type, base_url, api_key=None):
    adapter_cls = PROVIDER_ADAPTERS.get(provider_type, GenericRestAdapter)
    return adapter_cls(base_url, api_key)
