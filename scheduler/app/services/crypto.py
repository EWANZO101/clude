"""At-rest encryption for sensitive fields.

Used for the handful of ISP-support fields that are genuinely sensitive if
the database file itself is ever copied or leaked (DOB, mother's maiden
name, account numbers, security answers). This is symmetric encryption
with a key stored on disk next to the database — it protects a raw SQLite
file dump, not a fully-compromised server. It is deliberately NOT used for
anything the checklist says must never be stored at all (passwords, OTPs).
"""

import os

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy.types import TypeDecorator, LargeBinary

_KEY_ENV_VAR = "ISP_SUPPORT_ENC_KEY"
_fernet = None


def _load_or_create_key(instance_path):
    """Reuse a key from the environment if set, else a persisted key file.

    Keeping the key on disk (rather than requiring env-var setup) means
    this works out of the box on a fresh checkout, the same way Flask's
    own SECRET_KEY has a dev fallback — but it's still a real per-install
    random key, not a hardcoded one, and production deployments can
    override it via the environment.
    """
    env_key = os.environ.get(_KEY_ENV_VAR)
    if env_key:
        return env_key.encode()

    key_path = os.path.join(instance_path, "isp_support.key")
    if os.path.exists(key_path):
        with open(key_path, "rb") as f:
            return f.read().strip()

    key = Fernet.generate_key()
    os.makedirs(instance_path, exist_ok=True)
    with open(key_path, "wb") as f:
        f.write(key)
    try:
        os.chmod(key_path, 0o600)
    except OSError:
        pass
    return key


def init_encryption(instance_path):
    """Call once at app startup (from create_app) before any encrypted
    column is read or written."""
    global _fernet
    _fernet = Fernet(_load_or_create_key(instance_path))


def _require_fernet():
    if _fernet is None:
        raise RuntimeError(
            "Encryption not initialized — call init_encryption() from create_app() first."
        )
    return _fernet


class EncryptedString(TypeDecorator):
    """A String column that's encrypted at rest and transparent in Python.

    Reads/writes plain str in application code; stores encrypted bytes in
    the database. A blank/None value stays None (no point encrypting
    emptiness, and it keeps "not provided" distinguishable from "provided
    but empty").
    """

    impl = LargeBinary
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None or value == "":
            return None
        token = _require_fernet().encrypt(value.encode("utf-8"))
        return token

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        try:
            return _require_fernet().decrypt(bytes(value)).decode("utf-8")
        except InvalidToken:
            # Key rotated/mismatched — surface as missing rather than a
            # hard crash on every page that lists requests.
            return None
