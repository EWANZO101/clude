import json

from app.extensions import db
from app.models.hardware import HardwareBrand, Cpu, RamModule
from app.models.configuration import CompatibilityRule, RuleType, ServerConfiguration
from app.marketplace.compatibility import check_compatibility
from app.marketplace.pricing import calculate_price
from app.models.server import ComponentType
from tests.conftest import login


def _make_brand():
    brand = HardwareBrand(name="Intel", slug="intel", is_active=True)
    db.session.add(brand)
    db.session.commit()
    return brand


def test_pricing_engine_sums_base_and_components():
    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="Xeon Gold", price=50, is_active=True)
    db.session.add(cpu)
    db.session.commit()

    result = calculate_price(
        [{"component_type": ComponentType.CPU, "hardware_id": cpu.id, "quantity": 2}],
        ip_addresses=1,
    )
    assert result["component_total"] == 100
    assert result["total_monthly"] == result["base_price"] + 100


def test_pricing_engine_charges_for_extra_ips():
    result = calculate_price([], ip_addresses=3)
    assert result["extra_ips"] == 2
    assert result["ip_total"] > 0


def test_pricing_rule_applies_markup():
    from app.models.configuration import PricingRule, PricingMethod

    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="Xeon Gold", price=100, is_active=True)
    db.session.add(cpu)
    db.session.add(
        PricingRule(name="CPU markup", component_type=ComponentType.CPU, method=PricingMethod.MARKUP_PERCENT, value=10, is_active=True)
    )
    db.session.commit()

    result = calculate_price([{"component_type": ComponentType.CPU, "hardware_id": cpu.id, "quantity": 1}])
    assert result["component_total"] == 110


def test_compatibility_engine_flags_socket_mismatch():
    brand = _make_brand()
    cpu_a = Cpu(brand_id=brand.id, model_name="CPU A", socket="LGA4189", is_active=True)
    cpu_b = Cpu(brand_id=brand.id, model_name="CPU B", socket="SP3", is_active=True)
    db.session.add_all([cpu_a, cpu_b])
    db.session.add(CompatibilityRule(name="Socket match", rule_type=RuleType.SOCKET_MATCH, is_active=True))
    db.session.commit()

    violations = check_compatibility(
        [
            {"component_type": ComponentType.CPU, "hardware_id": cpu_a.id, "quantity": 1},
            {"component_type": ComponentType.CPU, "hardware_id": cpu_b.id, "quantity": 1},
        ]
    )
    assert len(violations) == 1
    assert "incompatible sockets" in violations[0]


def test_compatibility_engine_passes_matching_memory():
    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="CPU", memory_support=["DDR5"], is_active=True)
    ram = RamModule(brand_id=brand.id, model_name="RAM", ddr_generation="DDR5", is_active=True)
    db.session.add_all([cpu, ram])
    db.session.add(CompatibilityRule(name="Memory gen match", rule_type=RuleType.MEMORY_GENERATION_MATCH, is_active=True))
    db.session.commit()

    violations = check_compatibility(
        [
            {"component_type": ComponentType.CPU, "hardware_id": cpu.id, "quantity": 1},
            {"component_type": ComponentType.RAM, "hardware_id": ram.id, "quantity": 1},
        ]
    )
    assert violations == []


def test_compatibility_engine_flags_memory_mismatch():
    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="CPU", memory_support=["DDR4"], is_active=True)
    ram = RamModule(brand_id=brand.id, model_name="RAM", ddr_generation="DDR5", is_active=True)
    db.session.add_all([cpu, ram])
    db.session.add(CompatibilityRule(name="Memory gen match", rule_type=RuleType.MEMORY_GENERATION_MATCH, is_active=True))
    db.session.commit()

    violations = check_compatibility(
        [
            {"component_type": ComponentType.CPU, "hardware_id": cpu.id, "quantity": 1},
            {"component_type": ComponentType.RAM, "hardware_id": ram.id, "quantity": 1},
        ]
    )
    assert len(violations) == 1


def test_builder_save_requires_login(client):
    resp = client.post(
        "/build-server/save",
        data=json.dumps({"components": []}),
        content_type="application/json",
    )
    assert resp.status_code == 302
    assert "/auth/login" in resp.headers["Location"]


def test_builder_save_persists_configuration(client, make_user):
    brand = _make_brand()
    cpu = Cpu(brand_id=brand.id, model_name="Xeon Gold", price=50, is_active=True)
    db.session.add(cpu)
    db.session.commit()

    make_user(email="builder@example.com", password="Password123")
    login(client, "builder@example.com", "Password123")

    resp = client.post(
        "/build-server/save",
        data=json.dumps(
            {
                "components": [{"component_type": "cpus", "hardware_id": cpu.id, "quantity": 1}],
                "name": "My Build",
            }
        ),
        content_type="application/json",
    )
    assert resp.status_code == 200
    assert resp.get_json()["success"] is True
    config = ServerConfiguration.query.filter_by(name="My Build").first()
    assert config is not None
    assert len(config.components) == 1


def test_builder_save_rejects_incompatible_configuration(client, make_user):
    brand = _make_brand()
    cpu_a = Cpu(brand_id=brand.id, model_name="CPU A", socket="LGA4189", is_active=True)
    cpu_b = Cpu(brand_id=brand.id, model_name="CPU B", socket="SP3", is_active=True)
    db.session.add_all([cpu_a, cpu_b])
    db.session.add(CompatibilityRule(name="Socket match", rule_type=RuleType.SOCKET_MATCH, is_active=True))
    db.session.commit()

    make_user(email="builder2@example.com", password="Password123")
    login(client, "builder2@example.com", "Password123")

    resp = client.post(
        "/build-server/save",
        data=json.dumps(
            {
                "components": [
                    {"component_type": "cpus", "hardware_id": cpu_a.id, "quantity": 1},
                    {"component_type": "cpus", "hardware_id": cpu_b.id, "quantity": 1},
                ],
            }
        ),
        content_type="application/json",
    )
    assert resp.status_code == 400
    assert resp.get_json()["success"] is False
