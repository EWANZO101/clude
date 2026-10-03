import secrets
import string
import base64
import hashlib
import bcrypt
from cryptography.fernet import Fernet


def generate_user_id() -> str:
    """Public-facing numeric user ID, e.g. USR-482910"""
    return "USR-" + "".join(secrets.choice(string.digits) for _ in range(6))


def generate_support_id() -> str:
    """Support-lookup ID, e.g. SUP-849201-AB"""
    digits = "".join(secrets.choice(string.digits) for _ in range(6))
    letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(2))
    return f"SUP-{digits}-{letters}"


def generate_api_identifier() -> str:
    """Opaque identifier used for external API correlation (not a secret key)."""
    return "API-" + secrets.token_hex(8).upper()


def generate_recovery_pin() -> str:
    """Human-typeable recovery PIN, e.g. 4821-9034. Shown once, never stored raw."""
    part1 = "".join(secrets.choice(string.digits) for _ in range(4))
    part2 = "".join(secrets.choice(string.digits) for _ in range(4))
    return f"{part1}-{part2}"


def hash_secret(raw: str) -> str:
    """bcrypt hash for passwords and recovery PINs."""
    return bcrypt.hashpw(raw.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_secret(raw: str, hashed: str) -> bool:
    if not hashed:
        return False
    try:
        return bcrypt.checkpw(raw.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


def generate_product_id() -> str:
    """Public product identifier, e.g. PRD-849201"""
    return "PRD-" + "".join(secrets.choice(string.digits) for _ in range(6))


def generate_product_api_key() -> str:
    """Non-secret key sent by the loader to identify the product (like a public key)."""
    return "pk_" + secrets.token_hex(16)


def generate_product_secret_key() -> str:
    """Secret key - shown once, only the hash is stored, verified server-side."""
    return "sk_" + secrets.token_hex(24)


def generate_license_key() -> str:
    """Customer-facing license key, e.g. XXXX-XXXX-XXXX-XXXX"""
    alphabet = string.ascii_uppercase + string.digits
    groups = ["".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4)]
    return "-".join(groups)


def generate_developer_api_key():
    """Returns (full_key, prefix) - full key shown once, only hash stored.
    Prefix is kept in plaintext so the UI can show 'dev_9f2a...' for reference."""
    raw = "dev_" + secrets.token_hex(20)
    prefix = raw[:8]
    return raw, prefix


def _fernet():
    """Derives a Fernet key from the app SECRET_KEY so webhook secrets can be
    encrypted at rest but still decrypted server-side to verify incoming
    HMAC signatures (unlike passwords, this can't be a one-way hash)."""
    from flask import current_app
    key_material = hashlib.sha256(current_app.config["SECRET_KEY"].encode("utf-8")).digest()
    key = base64.urlsafe_b64encode(key_material)
    return Fernet(key)


def encrypt_secret(raw: str) -> str:
    return _fernet().encrypt(raw.encode("utf-8")).decode("utf-8")


def decrypt_secret(token: str) -> str:
    return _fernet().decrypt(token.encode("utf-8")).decode("utf-8")


def generate_webhook_secret() -> str:
    return "whsec_" + secrets.token_hex(24)


def generate_server_token():
    """Returns (full_token, prefix, lookup_hash). Full token shown once;
    lookup_hash (SHA-256, deterministic) is what's stored and queried -
    bcrypt is deliberately slow and wrong for exact-match lookups like this."""
    raw = "srv_" + secrets.token_hex(20)
    prefix = raw[:8]
    lookup_hash = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    return raw, prefix, lookup_hash


def hash_server_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def generate_totp_secret() -> str:
    import pyotp
    return pyotp.random_base32()


def generate_backup_codes(count: int = 8):
    """Returns list of raw codes like 'XXXX-XXXX'. Caller hashes each with
    hash_secret() before storing - these are shown once, like a password."""
    alphabet = string.ascii_uppercase + string.digits
    codes = []
    for _ in range(count):
        part1 = "".join(secrets.choice(alphabet) for _ in range(4))
        part2 = "".join(secrets.choice(alphabet) for _ in range(4))
        codes.append(f"{part1}-{part2}")
    return codes


# CloudLoader checks in every ~30 minutes (initial connect + the periodic
# re-check loop) - a generous buffer past that window before calling a
# server "offline" avoids false negatives from a check-in landing a
# little late.
SERVER_ONLINE_THRESHOLD_MINUTES = 40


def is_server_online(last_seen_at) -> bool:
    if not last_seen_at:
        return False
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    if last_seen_at.tzinfo is None:
        last_seen_at = last_seen_at.replace(tzinfo=timezone.utc)
    return (now - last_seen_at).total_seconds() < SERVER_ONLINE_THRESHOLD_MINUTES * 60


def humanize_relative_time(dt) -> str:
    """'3 minutes ago', '2 hours ago', '5 days ago' - no dependency needed
    for something this simple."""
    if not dt:
        return "never"
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    seconds = (now - dt).total_seconds()
    if seconds < 0:
        seconds = 0
    if seconds < 60:
        return "just now"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
    hours = int(minutes // 60)
    if hours < 24:
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    days = int(hours // 24)
    return f"{days} day{'s' if days != 1 else ''} ago"


def generate_temp_password(length: int = 12) -> str:
    """Used by support staff to issue a temporary password during account recovery."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))
