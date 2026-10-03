from decimal import Decimal

from app.models.configuration import PricingRule
from app.models.settings import SystemSetting

DEFAULT_ADDITIONAL_SERVICES = {
    "Managed Backups": 15,
    "DDoS Protection": 10,
    "Priority Support": 20,
    "Managed OS Patching": 12,
}


def get_additional_services_catalog():
    return SystemSetting.get("builder_additional_services", DEFAULT_ADDITIONAL_SERVICES)


def _pricing_rule_for(component_type):
    specific = PricingRule.query.filter_by(component_type=component_type, is_active=True).first()
    if specific:
        return specific
    return PricingRule.query.filter_by(component_type=None, is_active=True).first()


def calculate_price(selections, ip_addresses=1, additional_services=None):
    """selections: list of {component_type, hardware_id, quantity, hardware (optional resolved object)}.
    Returns a breakdown dict with Decimal money values and a `total_monthly` / `total_setup`.
    """
    from app.hardware.registry import HARDWARE_REGISTRY
    from app.extensions import db
    from app.models.server import ComponentType

    base_price = Decimal(str(SystemSetting.get("builder_base_price", 20)))
    setup_fee = Decimal(str(SystemSetting.get("builder_setup_fee", 0)))
    price_per_extra_ip = Decimal(str(SystemSetting.get("price_per_extra_ip", 2)))
    included_ips = int(SystemSetting.get("builder_included_ips", 1))

    lines = []
    component_total = Decimal("0")

    for item in selections:
        ctype = item["component_type"]
        ctype = ctype if isinstance(ctype, ComponentType) else ComponentType(ctype)
        entry = HARDWARE_REGISTRY.get(ctype.value)
        if not entry:
            continue
        hw = item.get("hardware") or db.session.get(entry["model"], item["hardware_id"])
        if hw is None:
            continue
        quantity = item.get("quantity", 1)
        unit_price = Decimal(str(hw.price or 0))

        rule = _pricing_rule_for(ctype)
        if rule:
            unit_price = rule.apply(unit_price)

        line_total = unit_price * quantity
        component_total += line_total
        lines.append(
            {
                "component_type": ctype,
                "label": hw.model_name,
                "unit_price": unit_price,
                "quantity": quantity,
                "line_total": line_total,
            }
        )

    extra_ips = max(0, (ip_addresses or included_ips) - included_ips)
    ip_total = price_per_extra_ip * extra_ips

    services_catalog = get_additional_services_catalog()
    service_lines = []
    services_total = Decimal("0")
    for service_name in additional_services or []:
        price = Decimal(str(services_catalog.get(service_name, 0)))
        services_total += price
        service_lines.append({"name": service_name, "price": price})

    total_monthly = base_price + component_total + ip_total + services_total

    return {
        "base_price": base_price,
        "lines": lines,
        "component_total": component_total,
        "extra_ips": extra_ips,
        "ip_total": ip_total,
        "service_lines": service_lines,
        "services_total": services_total,
        "setup_fee": setup_fee,
        "total_monthly": total_monthly,
        "total_setup": setup_fee,
        "currency": SystemSetting.get("default_currency", "GBP"),
    }
