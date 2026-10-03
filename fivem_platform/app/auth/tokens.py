from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from flask import current_app


def _serializer():
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"])


def generate_reset_token(user_id: int) -> str:
    return _serializer().dumps({"uid": user_id}, salt="password-reset")


def verify_reset_token(token: str, max_age: int = None):
    max_age = max_age or current_app.config["RESET_TOKEN_MAX_AGE"]
    try:
        data = _serializer().loads(token, salt="password-reset", max_age=max_age)
    except SignatureExpired:
        return None, "expired"
    except BadSignature:
        return None, "invalid"
    return data.get("uid"), None


def generate_verify_email_token(user_id: int, email: str) -> str:
    # Email is baked into the token itself, not just looked up by user_id -
    # so if someone changes their email after requesting a link, an old
    # link can't verify the new address.
    return _serializer().dumps({"uid": user_id, "email": email}, salt="verify-email")


def verify_verify_email_token(token: str, max_age: int = 86400):
    try:
        data = _serializer().loads(token, salt="verify-email", max_age=max_age)
    except SignatureExpired:
        return None, None, "expired"
    except BadSignature:
        return None, None, "invalid"
    return data.get("uid"), data.get("email"), None
