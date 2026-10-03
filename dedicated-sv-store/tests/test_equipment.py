from app.extensions import db
from app.models.user import AccountType
from app.models.equipment import (
    EquipmentType,
    CustomerEquipmentRequest,
    CustomerEquipmentItem,
    RequestStatus,
    EquipmentChangeRequest,
)
from tests.conftest import login


def _make_equipment_type():
    et = EquipmentType.query.filter_by(name="Server").first()
    if et is None:
        et = EquipmentType(name="Server", slug="server", is_networking=False)
        db.session.add(et)
        db.session.commit()
    return et


def test_customer_can_create_and_submit_request(client, make_user):
    make_user(email="byoe@example.com", password="Password123")
    login(client, "byoe@example.com", "Password123")
    et = _make_equipment_type()

    resp = client.post("/customer/requests/new")
    assert resp.status_code == 302
    req = CustomerEquipmentRequest.query.first()
    assert req is not None
    assert req.status == RequestStatus.DRAFT

    resp = client.post(
        f"/customer/requests/{req.id}/items/new",
        data={"equipment_type_id": et.id, "manufacturer": "Dell", "model": "R760", "quantity": "2", "declared_value": "1000"},
    )
    assert resp.status_code == 302
    item = CustomerEquipmentItem.query.filter_by(request_id=req.id).first()
    assert item is not None
    assert item.quantity == 2

    db.session.refresh(req)
    assert req.declared_value_total == 2000

    resp = client.post(f"/customer/requests/{req.id}/submit")
    assert resp.status_code == 302
    db.session.refresh(req)
    assert req.status == RequestStatus.SUBMITTED
    assert len(req.history) >= 1


def test_cannot_submit_empty_request(client, make_user):
    make_user(email="empty@example.com", password="Password123")
    login(client, "empty@example.com", "Password123")
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.first()

    resp = client.post(f"/customer/requests/{req.id}/submit", follow_redirects=True)
    assert b"Add at least one" in resp.data
    db.session.refresh(req)
    assert req.status == RequestStatus.DRAFT


def test_cannot_edit_items_once_locked(client, make_user):
    make_user(email="locked@example.com", password="Password123")
    login(client, "locked@example.com", "Password123")
    et = _make_equipment_type()
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.first()
    client.post(
        f"/customer/requests/{req.id}/items/new",
        data={"equipment_type_id": et.id, "manufacturer": "Dell", "model": "R760", "quantity": "1"},
    )
    item = CustomerEquipmentItem.query.filter_by(request_id=req.id).first()

    req.status = RequestStatus.LOCKED_FOR_SHIPMENT
    db.session.commit()

    resp = client.get(f"/customer/requests/{req.id}/items/new")
    assert resp.status_code == 403

    resp = client.post(
        f"/customer/requests/{req.id}/items/{item.id}",
        data={"equipment_type_id": et.id, "manufacturer": "Changed", "model": "R760", "quantity": "1"},
    )
    assert resp.status_code == 403


def test_customer_cannot_view_others_request(client, make_user):
    make_user(email="owner@example.com", password="Password123")
    login(client, "owner@example.com", "Password123")
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.first()
    client.get("/auth/logout")

    make_user(email="intruder@example.com", password="Password123")
    login(client, "intruder@example.com", "Password123")
    resp = client.get(f"/customer/requests/{req.id}")
    assert resp.status_code == 404


def test_admin_approve_and_lock_workflow(client, make_user):
    buyer = make_user(email="wf@example.com", password="Password123")
    login(client, "wf@example.com", "Password123")
    et = _make_equipment_type()
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.filter_by(user_id=buyer.id).first()
    client.post(
        f"/customer/requests/{req.id}/items/new",
        data={"equipment_type_id": et.id, "manufacturer": "Dell", "model": "R760", "quantity": "1"},
    )
    client.post(f"/customer/requests/{req.id}/submit")
    client.get("/auth/logout")

    make_user(email="admin2@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "admin2@example.com", "Password123")

    resp = client.post(f"/admin/requests/{req.id}", data={"action": "approve"})
    assert resp.status_code == 302
    db.session.refresh(req)
    assert req.status == RequestStatus.APPROVED

    resp = client.post(f"/admin/requests/{req.id}", data={"action": "lock"})
    assert resp.status_code == 302
    db.session.refresh(req)
    assert req.status == RequestStatus.LOCKED_FOR_SHIPMENT
    assert req.is_locked is True
    assert req.is_editable is False


def test_change_request_flow_when_locked(client, make_user):
    buyer = make_user(email="cr@example.com", password="Password123")
    login(client, "cr@example.com", "Password123")
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.filter_by(user_id=buyer.id).first()
    req.status = RequestStatus.LOCKED_FOR_SHIPMENT
    db.session.commit()

    resp = client.post(f"/customer/requests/{req.id}/change-request", data={"message": "Add a switch"})
    assert resp.status_code == 302
    cr = EquipmentChangeRequest.query.filter_by(request_id=req.id).first()
    assert cr is not None
    assert cr.message == "Add a switch"
    client.get("/auth/logout")

    make_user(email="admin3@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "admin3@example.com", "Password123")
    resp = client.post(
        f"/admin/requests/{req.id}/change-requests/{cr.id}",
        data={"action": "approve", "response": "Sure thing"},
    )
    assert resp.status_code == 302
    db.session.refresh(cr)
    assert cr.status.value == "approved"
    assert cr.admin_response == "Sure thing"


def test_request_progress_info(client, make_user):
    buyer = make_user(email="progress@example.com", password="Password123")
    login(client, "progress@example.com", "Password123")
    client.post("/customer/requests/new")
    req = CustomerEquipmentRequest.query.filter_by(user_id=buyer.id).first()

    assert req.status == RequestStatus.DRAFT
    info = req.progress_info
    assert info["current_index"] == -1
    assert info["percent"] == 0
    assert info["stopped"] is False

    req.status = RequestStatus.SUBMITTED
    info = req.progress_info
    assert info["current_index"] == 0
    assert info["percent"] == round(1 / 8 * 100)

    req.status = RequestStatus.COMPLETED
    info = req.progress_info
    assert info["current_index"] == len(info["steps"]) - 1
    assert info["percent"] == 100

    req.status = RequestStatus.REJECTED
    info = req.progress_info
    assert info["stopped"] is True
    assert info["stopped_label"] == "This request was rejected."
