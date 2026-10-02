from tests.conftest import register, login, create_motorcycle


def test_create_and_view_motorcycle(client):
    register(client, "rider")
    moto_id, resp = create_motorcycle(client)
    assert resp.status_code == 302
    view = client.get(f"/motorcycles/{moto_id}")
    assert view.status_code == 200
    assert b"Bonneville" in view.data


def test_motorcycle_not_visible_to_other_user(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)
    client.post("/auth/logout")

    register(client, "someone_else")
    resp = client.get(f"/motorcycles/{moto_id}")
    assert resp.status_code == 403


def test_admin_can_view_any_motorcycle(client):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)
    client.post("/auth/logout")

    login(client, "admin", "changeme123")
    resp = client.get(f"/motorcycles/{moto_id}")
    assert resp.status_code == 200


def test_nonexistent_motorcycle_404s(client):
    register(client, "rider")
    resp = client.get("/motorcycles/does-not-exist")
    assert resp.status_code == 404


def test_delete_motorcycle_removes_it(client):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)
    resp = client.post(f"/motorcycles/{moto_id}/delete", follow_redirects=False)
    assert resp.status_code == 302
    assert client.get(f"/motorcycles/{moto_id}").status_code == 404
