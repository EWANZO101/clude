import click
from flask.cli import with_appcontext

from app.extensions import db
from app.utils.permissions import seed_roles_and_permissions


def register_cli(app):
    @app.cli.command("seed-permissions")
    @with_appcontext
    def seed_permissions_command():
        """Create/update the default roles and permissions."""
        seed_roles_and_permissions()
        click.echo("Roles and permissions seeded.")

    @app.cli.command("create-superadmin")
    @click.option("--email", required=True)
    @click.option("--password", required=True)
    @click.option("--first-name", default="Admin")
    @click.option("--last-name", default="User")
    @with_appcontext
    def create_superadmin_command(email, password, first_name, last_name):
        """Create (or promote) a Super Admin user."""
        from app.models.user import User, AccountType, UserRole
        from app.models.user import Role

        seed_roles_and_permissions()

        user = User.query.filter_by(email=email.lower()).first()
        if user is None:
            user = User(
                email=email.lower(),
                first_name=first_name,
                last_name=last_name,
                account_type=AccountType.ADMIN,
                is_active=True,
                is_email_verified=True,
            )
            user.set_password(password)
            db.session.add(user)
            db.session.flush()
        else:
            user.account_type = AccountType.ADMIN
            user.set_password(password)

        role = Role.query.filter_by(name="Super Admin").first()
        if not any(ur.role_id == role.id for ur in user.user_roles):
            db.session.add(UserRole(user_id=user.id, role_id=role.id))

        db.session.commit()
        click.echo(f"Super Admin ready: {user.email}")

    @app.cli.command("seed-equipment-types")
    @with_appcontext
    def seed_equipment_types_command():
        """Create the default Bring-Your-Own-Equipment equipment types."""
        from app.models.equipment import EquipmentType
        from app.utils.helpers import generate_unique_slug

        defaults = [
            ("Server", False),
            ("Storage Server", False),
            ("Switch", True),
            ("Router", True),
            ("Firewall", True),
            ("Load Balancer", True),
            ("Network Card", True),
            ("Transceiver", True),
            ("GPU", False),
            ("Storage Device", False),
            ("Rack Equipment", False),
            ("Other", False),
        ]
        for name, is_networking in defaults:
            if not EquipmentType.query.filter_by(name=name).first():
                db.session.add(
                    EquipmentType(
                        name=name, slug=generate_unique_slug(EquipmentType, name), is_networking=is_networking
                    )
                )
        db.session.commit()
        click.echo("Equipment types seeded.")

    @app.cli.command("seed-email-templates")
    @with_appcontext
    def seed_email_templates_command():
        """Create the default editable email templates."""
        from app.models.settings import EmailTemplate

        defaults = [
            ("welcome", "Welcome", "Welcome to {{ app_name }}", "<p>Hi {{ user.first_name }}, welcome aboard!</p>"),
            ("email_verification", "Email Verification", "Verify your email address", "<p>Please verify your email by clicking the link we sent.</p>"),
            ("password_reset", "Password Reset", "Reset your password", "<p>Click the link to reset your password.</p>"),
            ("order_confirmation", "Order Confirmation", "Your order {{ order.order_number }} is confirmed", "<p>Thanks for your order!</p>"),
            ("invoice_created", "Invoice Created", "Invoice {{ invoice.invoice_number }} issued", "<p>A new invoice has been issued.</p>"),
            ("payment_received", "Payment Received", "Payment received for {{ invoice.invoice_number }}", "<p>We've received your payment. Thank you!</p>"),
            ("request_submitted", "Request Submitted", "Request {{ request.request_number }} submitted", "<p>Your equipment hosting request has been submitted for review.</p>"),
            ("request_approved", "Request Approved", "Request {{ request.request_number }} approved", "<p>Your request has been approved.</p>"),
            ("request_rejected", "Request Rejected", "Request {{ request.request_number }} rejected", "<p>Your request could not be approved.</p>"),
            ("information_required", "Information Required", "We need more information on {{ request.request_number }}", "<p>Please provide the requested information.</p>"),
            ("shipment_created", "Shipment Created", "Your shipment {{ shipment.shipment_number }} is on its way", "<p>Your shipment has been created.</p>"),
            ("shipment_delivered", "Shipment Delivered", "Your shipment {{ shipment.shipment_number }} was delivered", "<p>Your equipment has arrived safely.</p>"),
            ("equipment_received", "Equipment Received", "Your equipment has been received", "<p>We've received and logged your equipment.</p>"),
            ("server_deployed", "Server Deployed", "Your server is now live", "<p>Your server has been deployed and is now online.</p>"),
            ("new_message", "New Message", "You have a new message", "<p>You have a new message waiting for you.</p>"),
            ("support_ticket_updated", "Support Ticket Updated", "Your ticket {{ ticket.ticket_number }} was updated", "<p>There's an update on your support ticket.</p>"),
        ]
        for code, name, subject, body in defaults:
            if not EmailTemplate.query.filter_by(code=code).first():
                db.session.add(EmailTemplate(code=code, name=name, subject=subject, body_html=body))
        db.session.commit()
        click.echo("Email templates seeded.")

    @app.cli.command("seed-hardware-catalog")
    @with_appcontext
    def seed_hardware_catalog_command():
        """Populate the /build-server hardware catalog with a broad set of real,
        currently-available server components and ESTIMATED monthly rental
        pricing (not live vendor pricing)."""
        from app.models.hardware import (
            HardwareBrand, Cpu, RamModule, StorageDevice, Gpu,
            NetworkCard, RaidController, PowerSupply, ServerChassis, StorageType,
        )
        from app.hardware import seed_data as sd

        brands = {}
        for name, slug in sd.BRANDS:
            b = HardwareBrand.query.filter_by(name=name).first()
            if b is None:
                b = HardwareBrand(name=name, slug=slug)
                db.session.add(b)
                db.session.flush()
            brands[name] = b
        db.session.commit()

        def upsert(model, brand_name, model_name, **fields):
            brand = brands[brand_name]
            row = model.query.filter_by(brand_id=brand.id, model_name=model_name).first()
            if row is None:
                row = model(brand_id=brand.id, model_name=model_name)
                db.session.add(row)
            for key, value in fields.items():
                setattr(row, key, value)
            row.is_active = True
            return row

        counts = {}

        for brand, model_name, sku, cores, threads, base_ghz, boost_ghz, tdp, cache_mb, socket, price in sd.CPUS:
            upsert(
                Cpu, brand, model_name,
                sku=sku, cores=cores, threads=threads, base_clock_ghz=base_ghz, boost_clock_ghz=boost_ghz,
                tdp_watts=tdp, cache_mb=cache_mb, socket=socket, price=price, ecc_support=True,
            )
        counts["cpus"] = len(sd.CPUS)

        for brand, model_name, sku, ddr_gen, capacity_gb, speed_mhz, ecc, registered, price in sd.RAM_MODULES:
            upsert(
                RamModule, brand, model_name,
                sku=sku, part_number=sku, ddr_generation=ddr_gen, capacity_gb=capacity_gb, speed_mhz=speed_mhz,
                ecc=ecc, registered=registered, dimm_type="RDIMM", price=price,
            )
        counts["ram"] = len(sd.RAM_MODULES)

        for brand, model_name, sku, storage_type, capacity_gb, interface, form_factor, price in sd.STORAGE_DEVICES:
            upsert(
                StorageDevice, brand, model_name,
                sku=sku, storage_type=StorageType(storage_type), capacity_gb=capacity_gb, interface=interface,
                form_factor=form_factor, price=price,
            )
        counts["storage"] = len(sd.STORAGE_DEVICES)

        for brand, model_name, sku, vram_gb, gpu_cores, power_w, pcie_gen, price in sd.GPUS:
            upsert(
                Gpu, brand, model_name,
                sku=sku, vram_gb=vram_gb, gpu_cores=gpu_cores, power_watts=power_w,
                pcie_generation=pcie_gen, price=price,
            )
        counts["gpus"] = len(sd.GPUS)

        for brand, model_name, sku, port_count, port_type, speed_gbps, interface, price in sd.NETWORK_CARDS:
            upsert(
                NetworkCard, brand, model_name,
                sku=sku, port_count=port_count, port_type=port_type, port_speed_gbps=speed_gbps,
                interface=interface, price=price,
            )
        counts["network-cards"] = len(sd.NETWORK_CARDS)

        for brand, model_name, sku, raid_levels, cache_mb, interface, port_count, price in sd.RAID_CONTROLLERS:
            upsert(
                RaidController, brand, model_name,
                sku=sku, supported_raid_levels=raid_levels, cache_mb=cache_mb, interface=interface,
                port_count=port_count, price=price,
            )
        counts["raid-controllers"] = len(sd.RAID_CONTROLLERS)

        for brand, model_name, sku, wattage, form_factor, efficiency, redundant, price in sd.POWER_SUPPLIES:
            upsert(
                PowerSupply, brand, model_name,
                sku=sku, wattage=wattage, form_factor=form_factor, efficiency_rating=efficiency,
                redundant=redundant, price=price,
            )
        counts["power-supplies"] = len(sd.POWER_SUPPLIES)

        for brand, model_name, sku, form_factor, rack_units, drive_bays, max_gpu, max_psu, dims, weight_kg, price in sd.CHASSIS:
            upsert(
                ServerChassis, brand, model_name,
                sku=sku, form_factor=form_factor, rack_units=rack_units, drive_bays=drive_bays,
                max_gpu_count=max_gpu, max_psu_count=max_psu, dimensions=dims, weight_kg=weight_kg, price=price,
            )
        counts["chassis"] = len(sd.CHASSIS)

        # Clean up known placeholder/test rows left over from manual admin testing,
        # but only when nothing else references them.
        from app.models.configuration import ConfigurationComponent

        dupe_cpu = Cpu.query.filter_by(model_name="Xeon Gold 6248R (dupe)").first()
        if dupe_cpu and not ConfigurationComponent.query.filter_by(hardware_id=dupe_cpu.id).first():
            db.session.delete(dupe_cpu)

        stray_brand = HardwareBrand.query.filter_by(slug="ryzen").first()
        if stray_brand:
            still_used = any(
                model.query.filter_by(brand_id=stray_brand.id).first()
                for model in (Cpu, RamModule, StorageDevice, Gpu, NetworkCard, RaidController, PowerSupply, ServerChassis)
            )
            if not still_used:
                db.session.delete(stray_brand)

        db.session.commit()
        click.echo("Hardware catalog seeded: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
