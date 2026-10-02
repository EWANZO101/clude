from app.extensions import db
from app.models.user import AccountType
from app.models.equipment import EquipmentType, CustomerEquipmentRequest, CustomerEquipmentItem, RequestStatus
from app.models.infrastructure import Datacenter, Rack, RackAssignment, PowerAssignment, NetworkAssignment
from tests.conftest import login


def _make_item(make_user):
    buyer = make_user(email="infra@example.com", password="Password123")
    et = EquipmentType(name="Server", slug="server-infra", is_networking=False)
    db.session.add(et)
    db.session.commit()
    req = CustomerEquipmentRequest(user_id=buyer.id, status=RequestStatus.DEPLOYMENT)
    db.session.add(req)
    db.session.flush()
    item = CustomerEquipmentItem(request_id=req.id, equipment_type_id=et.id, manufacturer="Dell", model="R760", quantity=1)
    db.session.add(item)
    db.session.commit()
    return req, item


def _make_dc_and_rack():
    dc = Datacenter(name="London DC1", code="LON1", country="GB", city="London")
    db.session.add(dc)
    db.session.flush()
    rack = Rack(datacenter_id=dc.id, name="R1", total_u=42)
    db.session.add(rack)
    db.session.commit()
    return dc, rack


def test_admin_can_assign_rack_to_item(client, make_user):
    req, item = _make_item(make_user)
    dc, rack = _make_dc_and_rack()
    make_user(email="infraadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "infraadmin@example.com", "Password123")

    resp = client.post(
        f"/admin/requests/{req.id}/items/{item.id}/deploy",
        data={"action": "assign_rack", "rack-rack_id": rack.id, "rack-start_u": "5", "rack-u_height": "2"},
    )
    assert resp.status_code == 302
    assignment = RackAssignment.query.filter_by(equipment_item_id=item.id).first()
    assert assignment is not None
    assert assignment.rack_id == rack.id
    assert assignment.start_u == 5
    assert rack.used_u == 2


def test_admin_can_assign_power_and_network(client, make_user):
    req, item = _make_item(make_user)
    make_user(email="infraadmin2@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "infraadmin2@example.com", "Password123")

    resp = client.post(
        f"/admin/requests/{req.id}/items/{item.id}/deploy",
        data={"action": "assign_power", "power-power_feed_a": "A1", "power-pdu_outlet_a": "3"},
    )
    assert resp.status_code == 302
    power = PowerAssignment.query.filter_by(equipment_item_id=item.id).first()
    assert power.power_feed_a == "A1"

    resp = client.post(
        f"/admin/requests/{req.id}/items/{item.id}/deploy",
        data={
            "action": "assign_network",
            "network-switch_name": "SW1",
            "network-switch_port": "Gi0/1",
            "network-public_ipv4": "203.0.113.5",
        },
    )
    assert resp.status_code == 302
    net = NetworkAssignment.query.filter_by(equipment_item_id=item.id).first()
    assert net.switch_name == "SW1"
    assert net.public_ipv4 == "203.0.113.5"


def test_reassigning_rack_updates_existing_record_not_duplicate(client, make_user):
    req, item = _make_item(make_user)
    dc, rack = _make_dc_and_rack()
    make_user(email="infraadmin3@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "infraadmin3@example.com", "Password123")

    client.post(
        f"/admin/requests/{req.id}/items/{item.id}/deploy",
        data={"action": "assign_rack", "rack-rack_id": rack.id, "rack-start_u": "5", "rack-u_height": "2"},
    )
    client.post(
        f"/admin/requests/{req.id}/items/{item.id}/deploy",
        data={"action": "assign_rack", "rack-rack_id": rack.id, "rack-start_u": "20", "rack-u_height": "2"},
    )
    assignments = RackAssignment.query.filter_by(equipment_item_id=item.id).all()
    assert len(assignments) == 1
    assert assignments[0].start_u == 20
