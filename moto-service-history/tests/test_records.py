from tests.conftest import register, create_motorcycle


def test_full_record_lifecycle_and_timeline(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)

    r = client.post(
        f"/motorcycles/{moto_id}/service/new",
        data={"date": "2020-03-01", "work_type": "Oil change", "total_cost": "120"},
        follow_redirects=False,
    )
    assert r.status_code == 302

    r = client.post(
        f"/motorcycles/{moto_id}/mods/new",
        data={"name": "Exhaust", "date_fitted": "2021-01-01", "cost": "650"},
        follow_redirects=False,
    )
    assert r.status_code == 302

    r = client.post(
        f"/motorcycles/{moto_id}/accidents/new",
        data={"date": "2022-06-01", "description": "Rear-end shunt", "repair_cost": "1850"},
        follow_redirects=False,
    )
    assert r.status_code == 302

    timeline = client.get(f"/motorcycles/{moto_id}/timeline")
    assert timeline.status_code == 200
    for expected in (b"Exhaust", b"Oil change", b"Rear-end shunt"):
        assert expected in timeline.data


def test_part_fit_moves_to_modifications(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)

    client.post(
        f"/motorcycles/{moto_id}/parts/new",
        data={"part_name": "Brake levers", "purchase_price": "40", "quantity": "1"},
        follow_redirects=False,
    )

    with app.app_context():
        from app.models import PartNotFitted
        part = PartNotFitted.query.filter_by(part_name="Brake levers").first()
        assert part.status == "in_stock"
        part_id = part.id

    view_before = client.get(f"/motorcycles/{moto_id}")
    assert b"Brake levers" in view_before.data

    r = client.post(
        f"/motorcycles/{moto_id}/parts/{part_id}/fit",
        data={"date_fitted": "2023-01-01"},
        follow_redirects=False,
    )
    assert r.status_code == 302

    with app.app_context():
        from app.models import PartNotFitted, Modification
        part = PartNotFitted.query.get(part_id)
        assert part.status == "fitted"
        assert Modification.query.filter_by(name="Brake levers").first() is not None

    view_after = client.get(f"/motorcycles/{moto_id}")
    # No longer listed in the "not yet fitted" stock section
    stock_section = view_after.data.split(b'id="parts"')[1].split(b'id="accidents"')[0]
    assert b"Brake levers" not in stock_section


def test_service_record_belongs_only_to_its_motorcycle(client):
    register(client, "rider")
    moto_id_1, _ = create_motorcycle(client, make="Honda", model="CB500")
    moto_id_2, _ = create_motorcycle(client, make="Kawasaki", model="Z650")

    client.post(
        f"/motorcycles/{moto_id_1}/service/new",
        data={"date": "2021-01-01", "work_type": "Chain adjust"},
        follow_redirects=False,
    )

    view1 = client.get(f"/motorcycles/{moto_id_1}")
    view2 = client.get(f"/motorcycles/{moto_id_2}")
    assert b"Chain adjust" in view1.data
    assert b"Chain adjust" not in view2.data
