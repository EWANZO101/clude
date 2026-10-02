from flask import render_template, request, jsonify, redirect, url_for, flash
from flask_login import login_required, current_user

from app.extensions import db
from app.hardware.registry import HARDWARE_REGISTRY
from app.models.server import ComponentType
from app.models.configuration import ServerConfiguration, ConfigurationComponent, ConfigurationStatus
from app.marketplace.compatibility import check_compatibility
from app.marketplace.pricing import calculate_price, get_additional_services_catalog


def _hardware_catalog_json():
    catalog = {}
    for slug, entry in HARDWARE_REGISTRY.items():
        items = entry["model"].query.filter_by(is_active=True).order_by(entry["model"].model_name).all()
        catalog[slug] = [
            {
                "id": item.id,
                "label": item.model_name,
                "price": float(item.price or 0),
            }
            for item in items
        ]
    return catalog


def _parse_selections(payload):
    selections = []
    for row in payload.get("components", []):
        ctype = row.get("component_type")
        hardware_id = row.get("hardware_id")
        quantity = row.get("quantity", 1)
        if not ctype or not hardware_id:
            continue
        try:
            selections.append(
                {
                    "component_type": ComponentType(ctype),
                    "hardware_id": int(hardware_id),
                    "quantity": max(1, int(quantity)),
                }
            )
        except (ValueError, KeyError):
            continue
    return selections


def _money(value):
    return float(value)


def _serialize_pricing(pricing):
    return {
        "base_price": _money(pricing["base_price"]),
        "lines": [
            {
                "component_type": line["component_type"].value,
                "label": line["label"],
                "unit_price": _money(line["unit_price"]),
                "quantity": line["quantity"],
                "line_total": _money(line["line_total"]),
            }
            for line in pricing["lines"]
        ],
        "component_total": _money(pricing["component_total"]),
        "extra_ips": pricing["extra_ips"],
        "ip_total": _money(pricing["ip_total"]),
        "service_lines": [
            {"name": s["name"], "price": _money(s["price"])} for s in pricing["service_lines"]
        ],
        "services_total": _money(pricing["services_total"]),
        "setup_fee": _money(pricing["setup_fee"]),
        "total_monthly": _money(pricing["total_monthly"]),
        "total_setup": _money(pricing["total_setup"]),
        "currency": pricing["currency"],
    }


def register_builder_routes(marketplace_bp):
    @marketplace_bp.route("/build-server")
    def build_server():
        catalog = _hardware_catalog_json()
        services_catalog = get_additional_services_catalog()
        component_labels = {ct.value: HARDWARE_REGISTRY[ct.value]["label"] for ct in ComponentType}
        return render_template(
            "marketplace/build_server.html",
            catalog=catalog,
            services_catalog=services_catalog,
            component_labels=component_labels,
            component_types=[ct.value for ct in ComponentType],
        )

    @marketplace_bp.route("/build-server/quote", methods=["POST"])
    def build_server_quote():
        payload = request.get_json(silent=True) or {}
        selections = _parse_selections(payload)
        violations = check_compatibility(selections)
        pricing = calculate_price(
            selections,
            ip_addresses=int(payload.get("ip_addresses") or 1),
            additional_services=payload.get("additional_services") or [],
        )
        return jsonify(
            {
                "success": True,
                "data": {
                    "violations": violations,
                    "pricing": _serialize_pricing(pricing),
                },
            }
        )

    @marketplace_bp.route("/build-server/save", methods=["POST"])
    @login_required
    def build_server_save():
        payload = request.get_json(silent=True) or request.form.to_dict()
        if isinstance(payload.get("components"), str):
            import json

            payload["components"] = json.loads(payload["components"])
            payload["additional_services"] = json.loads(payload.get("additional_services", "[]"))

        selections = _parse_selections(payload)
        violations = check_compatibility(selections)
        if violations:
            return jsonify({"success": False, "error": {"code": "INVALID_CONFIGURATION", "message": "; ".join(violations)}}), 400

        pricing = calculate_price(
            selections,
            ip_addresses=int(payload.get("ip_addresses") or 1),
            additional_services=payload.get("additional_services") or [],
        )

        config = ServerConfiguration(
            user_id=current_user.id,
            name=payload.get("name") or "Custom Build",
            operating_system=payload.get("operating_system"),
            country=payload.get("country"),
            datacenter_name=payload.get("datacenter_name"),
            additional_services=payload.get("additional_services") or [],
            ip_addresses=int(payload.get("ip_addresses") or 1),
            status=ConfigurationStatus.SAVED,
            monthly_price=pricing["total_monthly"],
            setup_fee=pricing["total_setup"],
        )
        db.session.add(config)
        db.session.flush()

        for item in selections:
            db.session.add(
                ConfigurationComponent(
                    configuration_id=config.id,
                    component_type=item["component_type"],
                    hardware_id=item["hardware_id"],
                    quantity=item["quantity"],
                )
            )
        db.session.commit()

        if request.is_json:
            return jsonify({"success": True, "data": {"configuration_id": config.id}})

        flash("Configuration saved.", "success")
        return redirect(url_for("customer.configurations"))
