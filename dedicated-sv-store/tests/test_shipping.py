from app.extensions import db
from app.models.user import AccountType
from app.models.equipment import EquipmentType, CustomerEquipmentRequest, CustomerEquipmentItem, RequestStatus
from app.models.shipping import Shipment, ShipmentStatus, ReceivingRecord, InspectionRecord
from tests.conftest import login


def _make_locked_request_with_item(make_user):
    buyer = make_user(email="shipper@example.com", password="Password123")
    et = EquipmentType(name="Server", slug="server-ship", is_networking=False)
    db.session.add(et)
    db.session.commit()

    req = CustomerEquipmentRequest(user_id=buyer.id, status=RequestStatus.LOCKED_FOR_SHIPMENT)
    db.session.add(req)
    db.session.flush()
    item = CustomerEquipmentItem(request_id=req.id, equipment_type_id=et.id, manufacturer="Dell", model="R760", quantity=1)
    db.session.add(item)
    db.session.commit()
    return buyer, req, item


def test_admin_can_create_shipment_for_request(client, make_user):
    _, req, _ = _make_locked_request_with_item(make_user)
    make_user(email="shipadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "shipadmin@example.com", "Password123")

    resp = client.post(f"/admin/requests/{req.id}/shipment/new", data={"carrier": "UPS", "tracking_number": "1Z123"})
    assert resp.status_code == 302

    shipment = Shipment.query.filter_by(equipment_request_id=req.id).first()
    assert shipment is not None
    assert shipment.carrier == "UPS"
    db.session.refresh(req)
    assert req.status == RequestStatus.SHIPPING_ARRANGED


def test_adding_transit_event_updates_request_status(client, make_user):
    _, req, _ = _make_locked_request_with_item(make_user)
    make_user(email="shipadmin2@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "shipadmin2@example.com", "Password123")
    client.post(f"/admin/requests/{req.id}/shipment/new", data={"carrier": "UPS"})
    shipment = Shipment.query.filter_by(equipment_request_id=req.id).first()

    resp = client.post(f"/admin/shipments/{shipment.id}", data={"status": "in_transit", "location": "Memphis"})
    assert resp.status_code == 302

    db.session.refresh(req)
    db.session.refresh(shipment)
    assert req.status == RequestStatus.IN_TRANSIT
    assert shipment.status == ShipmentStatus.IN_TRANSIT
    assert len(shipment.events) == 2  # created + in_transit


def test_receiving_marks_request_received(client, make_user):
    _, req, _ = _make_locked_request_with_item(make_user)
    make_user(email="shipadmin3@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "shipadmin3@example.com", "Password123")
    client.post(f"/admin/requests/{req.id}/shipment/new", data={"carrier": "UPS"})
    shipment = Shipment.query.filter_by(equipment_request_id=req.id).first()

    resp = client.post(
        f"/admin/shipments/{shipment.id}/receive",
        data={"condition": "good", "packaging_condition": "good", "damage_noted": ""},
    )
    assert resp.status_code == 302
    db.session.refresh(req)
    assert req.status == RequestStatus.RECEIVED
    assert ReceivingRecord.query.filter_by(shipment_id=shipment.id).first() is not None


def test_inspection_records_checklist_and_result(client, make_user):
    _, req, item = _make_locked_request_with_item(make_user)
    req.status = RequestStatus.RECEIVED
    db.session.commit()
    make_user(email="inspector@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "inspector@example.com", "Password123")

    resp = client.post(
        f"/admin/requests/{req.id}/items/{item.id}/inspect",
        data={"result": "passed", "notes": "Looks great", "cpu_verified": "on", "boot_tested": "on"},
    )
    assert resp.status_code == 302

    record = InspectionRecord.query.filter_by(item_id=item.id).first()
    assert record is not None
    assert record.result.value == "passed"
    checklist = {ci.checklist_key: ci.passed for ci in record.checklist_items}
    assert checklist["cpu_verified"] is True
    assert checklist["ram_verified"] is False

    db.session.refresh(req)
    assert req.status == RequestStatus.INSPECTION


def test_customer_can_track_own_shipment_only(client, make_user):
    _, req, _ = _make_locked_request_with_item(make_user)
    make_user(email="shipadmin4@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "shipadmin4@example.com", "Password123")
    client.post(f"/admin/requests/{req.id}/shipment/new", data={"carrier": "UPS"})
    shipment = Shipment.query.filter_by(equipment_request_id=req.id).first()
    client.get("/auth/logout")

    login(client, "shipper@example.com", "Password123")
    resp = client.get(f"/customer/shipments/{shipment.id}")
    assert resp.status_code == 200

    make_user(email="other@example.com", password="Password123")
    client.get("/auth/logout")
    login(client, "other@example.com", "Password123")
    resp = client.get(f"/customer/shipments/{shipment.id}")
    assert resp.status_code == 404
