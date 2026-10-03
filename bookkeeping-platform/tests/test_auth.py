def test_register_and_login(client):
    resp = client.post("/auth/register", data={
        "full_name": "Ada Lovelace",
        "email": "ada@example.com",
        "password": "correct-horse-battery",
        "confirm_password": "correct-horse-battery",
    }, follow_redirects=True)
    assert resp.status_code == 200

    client.get("/auth/logout")

    resp = client.post("/auth/login", data={
        "email": "ada@example.com",
        "password": "correct-horse-battery",
    }, follow_redirects=True)
    assert resp.status_code == 200


def test_business_data_isolation(app, db, client):
    from app.models.user import User
    from app.models.business import Business, Membership, ROLE_OWNER

    u1 = User(email="a@example.com", full_name="A")
    u1.set_password("password123456")
    u2 = User(email="b@example.com", full_name="B")
    u2.set_password("password123456")
    db.session.add_all([u1, u2])
    db.session.flush()

    biz = Business(name="Private Co")
    db.session.add(biz)
    db.session.flush()
    db.session.add(Membership(user_id=u1.id, business_id=biz.id, role=ROLE_OWNER))
    db.session.commit()

    assert u1.role_in(biz) == ROLE_OWNER
    assert u2.role_in(biz) is None
