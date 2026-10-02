import pytest


def test_lookup_fails_without_credentials(app):
    with app.app_context():
        from app.mot.dvsa import lookup_mot_history, MOTLookupError
        with pytest.raises(MOTLookupError):
            lookup_mot_history("SB26CBK")


def test_lookup_requires_a_registration(app):
    with app.app_context():
        from app.models import AppSetting
        AppSetting.set("dvsa_api_key", "k")
        AppSetting.set("dvsa_client_id", "c")
        AppSetting.set("dvsa_client_secret", "s")
        AppSetting.set("dvsa_token_url", "https://example.com/token")
        AppSetting.set("dvsa_scope_url", "https://example.com/scope")

        from app.mot.dvsa import lookup_mot_history, MOTLookupError
        with pytest.raises(MOTLookupError):
            lookup_mot_history("")


def test_lookup_handles_auth_failure(app, monkeypatch):
    with app.app_context():
        from app.models import AppSetting
        AppSetting.set("dvsa_api_key", "k")
        AppSetting.set("dvsa_client_id", "c")
        AppSetting.set("dvsa_client_secret", "s")
        AppSetting.set("dvsa_token_url", "https://example.com/token")
        AppSetting.set("dvsa_scope_url", "https://example.com/scope")

        import app.mot.dvsa as dvsa_module

        class FakeResp:
            status_code = 401
            text = "unauthorized"

            def json(self):
                return {}

        monkeypatch.setattr(dvsa_module.requests, "post", lambda *a, **k: FakeResp())

        with pytest.raises(dvsa_module.MOTLookupError):
            dvsa_module.lookup_mot_history("SB26CBK")


def test_lookup_parses_successful_response(app, monkeypatch):
    with app.app_context():
        from app.models import AppSetting
        AppSetting.set("dvsa_api_key", "k")
        AppSetting.set("dvsa_client_id", "c")
        AppSetting.set("dvsa_client_secret", "s")
        AppSetting.set("dvsa_token_url", "https://example.com/token")
        AppSetting.set("dvsa_scope_url", "https://example.com/scope")

        import app.mot.dvsa as dvsa_module

        class FakeTokenResp:
            status_code = 200
            def json(self):
                return {"access_token": "abc123", "expires_in": 3600}

        class FakeApiResp:
            status_code = 200
            def json(self):
                return {
                    "motTests": [{
                        "completedDate": "2023-05-01 10:00:00",
                        "expiryDate": "2024-05-01",
                        "testResult": "PASSED",
                        "odometerValue": "18500",
                        "odometerUnit": "mi",
                        "motTestNumber": "123456789012",
                        "rfrAndComments": [
                            {"type": "ADVISORY", "text": "Front tyre wearing"},
                            {"type": "FAIL", "text": "Rear light not working"},
                        ],
                    }]
                }

        monkeypatch.setattr(dvsa_module.requests, "post", lambda *a, **k: FakeTokenResp())
        monkeypatch.setattr(dvsa_module.requests, "get", lambda *a, **k: FakeApiResp())

        records = dvsa_module.lookup_mot_history("SB26 CBK")["tests"]
        assert len(records) == 1
        assert records[0]["result"] == "PASSED"
        assert records[0]["mileage"] == 18500
        assert "Front tyre wearing" in records[0]["advisories"]
        assert "Rear light not working" in records[0]["failures"]
