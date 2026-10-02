from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from flask import current_app


def _serializer():
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"])


def generate_email_verify_token(user_id: int) -> str:
    return _serializer().dumps({"uid": user_id, "purpose": "verify"}, salt="email-verify")


def verify_email_verify_token(token: str, max_age: int):
    try:
        data = _serializer().loads(token, salt="email-verify", max_age=max_age)
    except (BadSignature, SignatureExpired):
        return None
    if data.get("purpose") != "verify":
        return None
    return data.get("uid")


def generate_password_reset_token(user_id: int, password_hash_fragment: str) -> str:
    # Including a fragment of the current hash means the token is invalidated
    # automatically the moment the password is changed.
    return _serializer().dumps(
        {"uid": user_id, "purpose": "reset", "h": password_hash_fragment[-16:]},
        salt="password-reset",
    )


def verify_password_reset_token(token: str, max_age: int, password_hash_fragment: str):
    try:
        data = _serializer().loads(token, salt="password-reset", max_age=max_age)
    except (BadSignature, SignatureExpired):
        return None
    if data.get("purpose") != "reset":
        return None
    if data.get("h") != password_hash_fragment[-16:]:
        return None
    return data.get("uid")
