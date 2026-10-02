from tests.conftest import register, create_motorcycle


def _get_share_token(app, moto_id):
    with app.app_context():
        from app.models import Motorcycle
        return Motorcycle.query.get(moto_id).share_token


def test_share_disabled_by_default(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)
    token = _get_share_token(app, moto_id)

    anon = app.test_client()
    resp = anon.get(f"/share/{token}")
    assert resp.status_code == 404


def test_enabling_share_exposes_public_page(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client, registration="SB26 CBK")
    client.post(
        f"/motorcycles/{moto_id}/share",
        data={"share_enabled": "y", "share_show_service": "y", "share_show_mods": "y"},
        follow_redirects=False,
    )
    token = _get_share_token(app, moto_id)

    anon = app.test_client()
    resp = anon.get(f"/share/{token}")
    assert resp.status_code == 200
    assert b"SB26" in resp.data


def test_hidden_sections_not_shown_publicly(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)

    client.post(
        f"/motorcycles/{moto_id}/accidents/new",
        data={"date": "2022-06-01", "description": "Secret crash details"},
        follow_redirects=False,
    )
    # share_show_accidents left unticked (defaults False)
    client.post(
        f"/motorcycles/{moto_id}/share",
        data={"share_enabled": "y", "share_show_service": "y"},
        follow_redirects=False,
    )
    token = _get_share_token(app, moto_id)

    anon = app.test_client()
    resp = anon.get(f"/share/{token}")
    assert resp.status_code == 200
    assert b"Secret crash details" not in resp.data

    # Owner still sees it privately
    owner_view = client.get(f"/motorcycles/{moto_id}")
    assert b"Secret crash details" in owner_view.data


def test_regenerating_share_link_invalidates_old_token(client, app):
    register(client, "rider")
    moto_id, _ = create_motorcycle(client)
    client.post(f"/motorcycles/{moto_id}/share", data={"share_enabled": "y"}, follow_redirects=False)
    old_token = _get_share_token(app, moto_id)

    client.post(f"/motorcycles/{moto_id}/share/regenerate", follow_redirects=False)
    new_token = _get_share_token(app, moto_id)
    assert old_token != new_token

    anon = app.test_client()
    assert anon.get(f"/share/{old_token}").status_code == 404
    assert anon.get(f"/share/{new_token}").status_code == 200
