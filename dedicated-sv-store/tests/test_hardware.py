from app.extensions import db
from app.models.user import AccountType
from app.models.hardware import HardwareBrand, Cpu, Availability
from tests.conftest import login


def _make_brand():
    brand = HardwareBrand(name="Intel", slug="intel", is_active=True)
    db.session.add(brand)
    db.session.commit()
    return brand


def test_admin_can_create_cpu(client, make_user):
    make_user(email="hwadmin@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "hwadmin@example.com", "Password123")
    brand = _make_brand()

    resp = client.post(
        "/admin/hardware/cpus/new",
        data={
            "brand_id": brand.id,
            "model_name": "EPYC 7763",
            "cores": "64",
            "threads": "128",
            "tdp_watts": "280",
            "availability": "in_stock",
            "is_active": "y",
        },
    )
    assert resp.status_code == 302
    cpu = Cpu.query.filter_by(model_name="EPYC 7763").first()
    assert cpu is not None
    assert cpu.cores == 64
    assert cpu.availability == Availability.IN_STOCK


def test_editing_cpu_updates_availability_enum(client, make_user):
    make_user(email="hwadmin2@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "hwadmin2@example.com", "Password123")
    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="Xeon Silver 4310", availability=Availability.IN_STOCK)
    db.session.add(cpu)
    db.session.commit()

    resp = client.post(
        f"/admin/hardware/cpus/{cpu.id}",
        data={
            "brand_id": brand.id,
            "model_name": "Xeon Silver 4310",
            "availability": "discontinued",
            "is_active": "y",
        },
    )
    assert resp.status_code == 302
    db.session.refresh(cpu)
    assert cpu.availability == Availability.DISCONTINUED


def test_merge_marks_source_inactive(client, make_user):
    make_user(email="hwadmin3@example.com", password="Password123", account_type=AccountType.ADMIN, roles=["Super Admin"])
    login(client, "hwadmin3@example.com", "Password123")
    brand = _make_brand()
    keep = Cpu(brand_id=brand.id, model_name="Keep Me")
    dupe = Cpu(brand_id=brand.id, model_name="Duplicate")
    db.session.add_all([keep, dupe])
    db.session.commit()

    resp = client.post(f"/admin/hardware/cpus/{dupe.id}/merge", data={"target_id": keep.id})
    assert resp.status_code == 302
    db.session.refresh(dupe)
    assert dupe.is_active is False
    assert dupe.merged_into_id == keep.id


def test_non_privileged_staff_cannot_edit_hardware(client, make_user):
    make_user(email="supportonly2@example.com", password="Password123", account_type=AccountType.STAFF, roles=["Support"])
    login(client, "supportonly2@example.com", "Password123")
    resp = client.get("/admin/hardware/cpus/new")
    assert resp.status_code == 403
