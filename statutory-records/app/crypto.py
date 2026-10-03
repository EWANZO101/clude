"""Encrypts bank OAuth tokens before they're stored in the database. Same
pattern as /root/payments' finance module: Fernet (symmetric, authenticated
encryption), key from ENCRYPTION_KEY in .env. Falls back to a random
per-process key with a loud warning rather than crashing -- but tokens
encrypted with that fallback key stop decrypting on restart, so a real key
belongs in .env for any persistent bank connection.

Generate one with:
    python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
"""
import logging
import os

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)

_key = os.environ.get("ENCRYPTION_KEY")
if not _key:
    _key = Fernet.generate_key().decode()
    logger.warning(
        "ENCRYPTION_KEY is not set — using a random key for this process only. "
        "Bank connection tokens will stop decrypting after a restart, requiring "
        "reconnection. Set ENCRYPTION_KEY in .env for persistent connections."
    )

_fernet = Fernet(_key.encode() if isinstance(_key, str) else _key)


def encrypt_token(plaintext):
    if not plaintext:
        return None
    return _fernet.encrypt(plaintext.encode()).decode()


def decrypt_token(ciphertext):
    if not ciphertext:
        return None
    try:
        return _fernet.decrypt(ciphertext.encode()).decode()
    except InvalidToken:
        logger.error("Could not decrypt a stored bank token — likely ENCRYPTION_KEY changed or was unset.")
        return None
