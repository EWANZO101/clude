"""Encrypts bank OAuth tokens before they're stored in the database.

Uses Fernet (symmetric, authenticated encryption) from the `cryptography`
package. The key comes from the FINANCE_ENCRYPTION_KEY environment
variable — generate one with:

    python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

and put it in .env. If it's not set, a random key is generated at process
startup as a fallback so the app doesn't crash — but tokens encrypted with
that ephemeral key become unreadable the moment the process restarts
(refresh tokens would be lost, requiring the user to reconnect their
bank). This is loud in the logs on purpose rather than a silent data-loss
trap.
"""
import logging
import os

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)

_key = os.environ.get("FINANCE_ENCRYPTION_KEY")
if not _key:
    _key = Fernet.generate_key().decode()
    logger.warning(
        "FINANCE_ENCRYPTION_KEY is not set — using a random key for this process only. "
        "Bank connection tokens will stop decrypting after a restart, requiring "
        "reconnection. Set FINANCE_ENCRYPTION_KEY in .env for persistent connections."
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
        logger.error("Could not decrypt a stored bank token — likely FINANCE_ENCRYPTION_KEY changed or was unset.")
        return None
