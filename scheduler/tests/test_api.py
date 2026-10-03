from datetime import datetime, timedelta

import pytest

from app import create_app, db
from app.models.booking import Booking, BookingType
from app.models.user import User


@pytest.fixture
def client():
    app = create_app("testing")
    with app.app_context():
        db.create_all()
        user = User(email="owner@example.com", name="Owner", timezone="UTC")
        user.set_password("correct-horse")
        db.session.add(user)
        db.session.commit()
        bt = BookingType(user_id=user.id, name="Chat", duration=30)
        db.session.add(bt)
        db.session.commit()
        start = datetime.utcnow().replace(second=0, microsecond=0) + timedelta(days=1)
        db.session.add(
            Booking(
                user_id=user.id, booking_type_id=bt.id, name="Alice", email="a@example.com",
                start_datetime=start, end_datetime=start + timedelta(minutes=30),
            )
        )
        db.session.commit()
        yield app.test_client()
        db.drop_all()


def _login(client, password="correct-horse"):
    return client.post("/api/v1/auth/login", json={"email": "Owner@Example.com ", "password": password})


def _auth(client):
    return {"Authorization": f"Bearer {_login(client).get_json()['token']}"}


def test_login_and_me(client):
    res = _login(client)
    assert res.status_code == 200
    headers = {"Authorization": f"Bearer {res.get_json()['token']}"}
    assert client.get("/api/v1/me", headers=headers).get_json()["user"]["email"] == "owner@example.com"


def test_bad_password_and_missing_token(client):
    assert _login(client, "wrong").status_code == 401
    assert client.get("/api/v1/me").status_code == 401
    assert client.get("/api/v1/me", headers={"Authorization": "Bearer junk"}).status_code == 401


def test_password_change_invalidates_token(client):
    headers = _auth(client)
    # The fixture's app context is still active, so this is the same session
    # the request below will use.
    user = User.query.first()
    user.set_password("new-password")
    db.session.commit()
    assert client.get("/api/v1/me", headers=headers).status_code == 401


def test_dashboard_and_status(client):
    headers = _auth(client)
    data = client.get("/api/v1/dashboard", headers=headers).get_json()
    assert data["stats"]["week_bookings"] == 1
    assert data["next_booking"]["name"] == "Alice"

    res = client.post("/api/v1/status", json={"status": "busy", "message": "In a meeting"}, headers=headers)
    assert res.get_json()["status"] == {"status": "busy", "message": "In a meeting", "is_manual": True, "next_available": res.get_json()["status"]["next_available"]}
    res = client.post("/api/v1/status", json={"status": None, "message": "ignored"}, headers=headers)
    assert res.get_json()["status"]["is_manual"] is False
    assert client.post("/api/v1/status", json={"status": "offline"}, headers=headers).status_code == 400

    assert client.post("/api/v1/current-task", json={"current_task": " Fixing Wi-Fi "}, headers=headers).get_json() == {"current_task": "Fixing Wi-Fi"}


def test_booking_actions(client):
    headers = _auth(client)
    upcoming = client.get("/api/v1/bookings?filter=upcoming", headers=headers).get_json()["bookings"]
    assert len(upcoming) == 1
    booking_id = upcoming[0]["id"]

    assert client.post(f"/api/v1/bookings/{booking_id}/cancel", headers=headers).get_json()["booking"]["status"] == "cancelled"
    assert client.get("/api/v1/bookings?filter=upcoming", headers=headers).get_json()["bookings"] == []
    assert len(client.get("/api/v1/bookings?filter=cancelled", headers=headers).get_json()["bookings"]) == 1
    assert client.get("/api/v1/bookings/9999", headers=headers).status_code == 404


def test_time_off_crud_and_calendar(client):
    headers = _auth(client)
    tomorrow = (datetime.utcnow() + timedelta(days=1)).date()
    res = client.post(
        "/api/v1/time-off",
        json={"start_date": tomorrow.isoformat(), "end_date": tomorrow.isoformat(), "all_day": True, "reason": "Holiday"},
        headers=headers,
    )
    assert res.status_code == 201
    entry_id = res.get_json()["time_off"]["id"]

    bad = client.post(
        "/api/v1/time-off",
        json={"start_date": tomorrow.isoformat(), "end_date": tomorrow.isoformat(), "all_day": False, "start_time": "15:00", "end_time": "14:00"},
        headers=headers,
    )
    assert bad.status_code == 400

    cal = client.get(f"/api/v1/calendar?year={tomorrow.year}&month={tomorrow.month}", headers=headers).get_json()
    day = next(d for d in cal["days"] if d["date"] == tomorrow.isoformat())
    assert day["time_offs"][0]["reason"] == "Holiday"
    assert day["bookings"][0]["name"] == "Alice"

    assert client.delete(f"/api/v1/time-off/{entry_id}", headers=headers).status_code == 204
    assert client.get("/api/v1/time-off", headers=headers).get_json()["time_off"] == []


def test_cors_preflight(client):
    res = client.options("/api/v1/dashboard")
    assert res.status_code == 204
    assert res.headers["Access-Control-Allow-Origin"] == "*"


def test_push_device_registration(client):
    headers = _auth(client)
    token = "ExponentPushToken[abc123]"
    assert client.post("/api/v1/push-devices/test", headers=headers).status_code == 400
    assert client.post("/api/v1/push-devices", json={"token": "nonsense"}, headers=headers).status_code == 400
    assert client.post("/api/v1/push-devices", json={"token": token}, headers=headers).status_code == 200
    # Registering the same phone again is idempotent.
    assert client.post("/api/v1/push-devices", json={"token": token}, headers=headers).status_code == 200
    from app.models.push_device import PushDevice
    assert PushDevice.query.count() == 1
    assert client.post("/api/v1/push-devices/test", headers=headers).get_json() == {"sent": True}
    assert client.delete("/api/v1/push-devices", json={"token": token}, headers=headers).status_code == 204
    assert PushDevice.query.count() == 0


def test_new_booking_push_payload_and_dead_token_cleanup(client, monkeypatch):
    import app.services.push as push
    from app.models.push_device import PushDevice

    client.post("/api/v1/push-devices", json={"token": "ExponentPushToken[live]"}, headers=_auth(client))
    client.post("/api/v1/push-devices", json={"token": "ExponentPushToken[dead]"}, headers=_auth(client))

    sent = []

    def fake_post(messages):
        sent.extend(messages)
        return {"data": [
            {"status": "ok"} if m["to"].endswith("[live]") else {"status": "error", "details": {"error": "DeviceNotRegistered"}}
            for m in messages
        ]}

    # Run the "background" delivery inline so the test can see its effects.
    class InlineThread:
        def __init__(self, target, args, daemon):
            self.target, self.args = target, args

        def start(self):
            self.target(*self.args)

    monkeypatch.setattr(push, "_post", fake_post)
    monkeypatch.setattr(push.threading, "Thread", InlineThread)
    client.application.config["PUSH_SEND_IN_TESTS"] = True

    booking = Booking.query.first()
    push.push_new_booking(booking)

    assert {m["to"] for m in sent} == {"ExponentPushToken[live]", "ExponentPushToken[dead]"}
    assert sent[0]["title"] == "New booking: Alice"
    assert sent[0]["data"] == {"booking_id": booking.id, "kind": "new_booking"}
    assert [d.token for d in PushDevice.query.all()] == ["ExponentPushToken[live]"]


def test_push_failure_never_raises(client, monkeypatch):
    import app.services.push as push

    client.post("/api/v1/push-devices", json={"token": "ExponentPushToken[x]"}, headers=_auth(client))

    def broken_post(messages):
        raise OSError("network down")

    class InlineThread:
        def __init__(self, target, args, daemon):
            self.target, self.args = target, args

        def start(self):
            self.target(*self.args)

    monkeypatch.setattr(push, "_post", broken_post)
    monkeypatch.setattr(push.threading, "Thread", InlineThread)
    client.application.config["PUSH_SEND_IN_TESTS"] = True
    push.push_new_booking(Booking.query.first())  # must not raise


def test_privacy_page(client):
    res = client.get("/privacy")
    assert res.status_code == 200
    assert b"Privacy policy" in res.data and b"owner@example.com" in res.data
