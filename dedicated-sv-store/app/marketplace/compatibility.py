from collections import defaultdict

from app.models.server import ComponentType
from app.models.configuration import CompatibilityRule, RuleType


def _resolve_selections(selections):
    """selections: list of {component_type, hardware_id, quantity}.
    Returns dict[ComponentType] -> list of (hardware_obj, quantity)."""
    from app.hardware.registry import HARDWARE_REGISTRY
    from app.extensions import db

    resolved = defaultdict(list)
    for item in selections:
        ctype = item["component_type"]
        entry = HARDWARE_REGISTRY.get(ctype.value if isinstance(ctype, ComponentType) else ctype)
        if not entry:
            continue
        hw = db.session.get(entry["model"], item["hardware_id"])
        if hw is not None:
            key = ctype if isinstance(ctype, ComponentType) else ComponentType(ctype)
            resolved[key].append((hw, item.get("quantity", 1)))
    return resolved


def check_compatibility(selections):
    """Returns a list of human-readable violation messages. Empty list means
    the configuration passes every active compatibility rule."""
    resolved = _resolve_selections(selections)
    violations = []

    rules = CompatibilityRule.query.filter_by(is_active=True).all()
    active_types = {r.rule_type for r in rules} if rules else set(RuleType)

    cpus = resolved.get(ComponentType.CPU, [])
    rams = resolved.get(ComponentType.RAM, [])
    storages = resolved.get(ComponentType.STORAGE, [])
    gpus = resolved.get(ComponentType.GPU, [])
    psus = resolved.get(ComponentType.POWER_SUPPLY, [])
    chassis_list = resolved.get(ComponentType.CHASSIS, [])
    raid_controllers = resolved.get(ComponentType.RAID_CONTROLLER, [])

    if RuleType.SOCKET_MATCH in active_types and cpus:
        sockets = {c.socket for c, _ in cpus if c.socket}
        if len(sockets) > 1:
            violations.append(f"Selected CPUs use incompatible sockets: {', '.join(sockets)}.")

    if RuleType.MEMORY_GENERATION_MATCH in active_types and cpus and rams:
        supported = set()
        for cpu, _ in cpus:
            supported.update(cpu.memory_support or [])
        if supported:
            for ram, _ in rams:
                if ram.ddr_generation and ram.ddr_generation not in supported:
                    violations.append(
                        f"{ram.model_name} ({ram.ddr_generation}) is not supported by the selected CPU(s) "
                        f"(supports {', '.join(supported)})."
                    )

    if RuleType.MAX_DRIVE_BAYS in active_types and chassis_list:
        max_bays = sum((c.drive_bays or 0) * qty for c, qty in chassis_list)
        drive_count = sum(qty for _, qty in storages)
        if max_bays and drive_count > max_bays:
            violations.append(f"Selected chassis supports {max_bays} drive bays, but {drive_count} drives were selected.")

    if RuleType.MAX_GPU_COUNT in active_types and chassis_list:
        max_gpu = sum((c.max_gpu_count or 0) * qty for c, qty in chassis_list)
        gpu_count = sum(qty for _, qty in gpus)
        if gpu_count > max_gpu:
            violations.append(f"Selected chassis supports {max_gpu} GPU(s), but {gpu_count} were selected.")

    if RuleType.MAX_PSU_COUNT in active_types and chassis_list:
        max_psu = sum((c.max_psu_count or 0) * qty for c, qty in chassis_list)
        psu_count = sum(qty for _, qty in psus)
        if psu_count > max_psu:
            violations.append(f"Selected chassis supports {max_psu} PSU(s), but {psu_count} were selected.")

    if RuleType.PSU_WATTAGE_SUFFICIENT in active_types and psus:
        supplied = sum((p.wattage or 0) * qty for p, qty in psus)
        draw = sum((c.tdp_watts or 0) * qty for c, qty in cpus) + sum((g.power_watts or 0) * qty for g, qty in gpus) + 150
        if supplied and supplied < draw:
            violations.append(f"Selected PSU(s) supply {supplied}W, but estimated draw is {draw}W.")

    if RuleType.DRIVE_INTERFACE_MATCH in active_types and raid_controllers and storages:
        for raid, _ in raid_controllers:
            raid_iface = (raid.interface or "").lower()
            if not raid_iface:
                continue
            for storage, _ in storages:
                storage_iface = (storage.interface or "").lower()
                if storage_iface and raid_iface not in storage_iface and storage_iface not in raid_iface:
                    violations.append(
                        f"{storage.model_name} ({storage.interface}) may not be compatible with "
                        f"RAID controller {raid.model_name} ({raid.interface})."
                    )

    return violations
