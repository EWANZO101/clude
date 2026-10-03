from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app

from services.dns_providers.registry import get_provider, all_providers, is_valid, DEFAULT_PROVIDER
from services.dns_providers.base import DNSProviderError
from modules.dns.forms import TokenForm, NamecheapCredentialsForm, GoDaddyCredentialsForm, DnsRecordForm
from utils.permissions import require_permission
from config import persist_dns_provider

dns_bp = Blueprint("dns", __name__, template_folder="templates")


def _active_provider_key():
    requested = request.args.get("provider")
    if requested and is_valid(requested):
        return requested
    key = current_app.config.get("DNS_PROVIDER", DEFAULT_PROVIDER)
    return key if is_valid(key) else DEFAULT_PROVIDER


@dns_bp.route("/dns")
@require_permission("dns.view")
def index():
    provider_key = _active_provider_key()
    # Clicking a provider tab is "select this as my DNS provider" — persist
    # it so the page opens here next time too, not just for this request.
    if request.args.get("provider") == provider_key:
        persist_dns_provider(provider_key)
        current_app.config["DNS_PROVIDER"] = provider_key

    provider = get_provider(provider_key)
    providers = all_providers()

    if not provider.is_configured():
        return render_template(
            "dns_index.html",
            configured=False,
            provider_key=provider_key,
            provider=provider,
            providers=providers,
            token_form=TokenForm(),
            namecheap_form=NamecheapCredentialsForm(),
            godaddy_form=GoDaddyCredentialsForm(),
        )

    zones, records, active_zone, error, nameserver_mode = [], [], None, None, None
    zone_id = provider.active_domain_id()
    try:
        zones = provider.list_domains()
        if zones and not any(z["id"] == zone_id for z in zones):
            # Previously-selected domain no longer visible to these
            # credentials — fall back to the first one rather than
            # silently showing an empty/broken page.
            zone_id = zones[0]["id"]
            provider.persist_active_domain(zone_id)
        active_zone = next((z for z in zones if z["id"] == zone_id), None)
        if zone_id:
            records = provider.list_records(zone_id)
            if provider.supports_nameserver_switch:
                nameserver_mode = provider.get_nameserver_mode(zone_id)
    except DNSProviderError as exc:
        error = str(exc)

    record_form = DnsRecordForm()
    record_form.type.choices = [(t, t) for t in provider.record_types]

    return render_template(
        "dns_index.html",
        configured=True,
        provider_key=provider_key,
        provider=provider,
        providers=providers,
        zones=zones,
        zone_id=zone_id,
        active_zone=active_zone,
        records=records,
        error=error,
        record_form=record_form,
        proxyable_types=provider.proxyable_types,
        nameserver_mode=nameserver_mode,
    )


# ---------------------------------------------------------------------------
# Cloudflare credentials (kept at their original URLs for compatibility)
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/token", methods=["POST"])
@require_permission("dns.manage")
def save_token():
    provider = get_provider("cloudflare")
    form = TokenForm()
    if form.validate_on_submit():
        token = form.token.data.strip()
        try:
            provider.verify_credentials(token=token)
            provider.save_credentials(token=token)
            flash("Cloudflare API token saved and verified.", "success")
        except DNSProviderError as exc:
            flash(f"Token rejected: {exc}", "error")
    else:
        flash("Enter an API token.", "error")
    return redirect(url_for("dns.index", provider="cloudflare"))


@dns_bp.route("/dns/token/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_token():
    get_provider("cloudflare").remove_credentials()
    flash("Cloudflare disconnected. The token was removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="cloudflare"))


# ---------------------------------------------------------------------------
# Namecheap credentials
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/namecheap/credentials", methods=["POST"])
@require_permission("dns.manage")
def save_namecheap_credentials():
    provider = get_provider("namecheap")
    form = NamecheapCredentialsForm()
    if form.validate_on_submit():
        creds = dict(
            api_user=form.api_user.data.strip(),
            api_key=form.api_key.data.strip(),
            username=(form.username.data or "").strip(),
            client_ip=form.client_ip.data.strip(),
        )
        try:
            provider.verify_credentials(**creds)
            provider.save_credentials(**creds)
            flash("Namecheap API credentials saved and verified.", "success")
        except DNSProviderError as exc:
            flash(
                f"Namecheap rejected these credentials: {exc}. "
                "Double check the client IP is whitelisted under Profile → Tools → API Access on Namecheap.",
                "error",
            )
    else:
        flash("Check the Namecheap credential fields and try again.", "error")
    return redirect(url_for("dns.index", provider="namecheap"))


@dns_bp.route("/dns/namecheap/credentials/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_namecheap_credentials():
    get_provider("namecheap").remove_credentials()
    flash("Namecheap disconnected. Credentials were removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="namecheap"))


@dns_bp.route("/dns/namecheap/nameservers", methods=["POST"])
@require_permission("dns.manage")
def switch_namecheap_nameservers():
    provider = get_provider("namecheap")
    domain = provider.active_domain_id()
    action = request.form.get("action", "")
    if not domain:
        flash("Select a domain first.", "error")
        return redirect(url_for("dns.index", provider="namecheap"))
    try:
        if action == "default":
            provider.use_provider_dns(domain)
            flash(f"{domain} is now using Namecheap's DNS — records managed here will resolve.", "success")
        elif action == "custom":
            raw = request.form.get("nameservers", "")
            nameservers = [n.strip() for n in raw.split(",") if n.strip()]
            if not nameservers:
                flash("Enter at least one nameserver.", "error")
            else:
                provider.use_custom_nameservers(domain, nameservers)
                flash(f"{domain} switched to custom nameservers. Records managed here will no longer resolve until it's switched back.", "success")
        else:
            flash("Unknown nameserver action.", "error")
    except DNSProviderError as exc:
        flash(str(exc), "error")
    return redirect(url_for("dns.index", provider="namecheap"))


# ---------------------------------------------------------------------------
# GoDaddy credentials
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/godaddy/credentials", methods=["POST"])
@require_permission("dns.manage")
def save_godaddy_credentials():
    provider = get_provider("godaddy")
    form = GoDaddyCredentialsForm()
    if form.validate_on_submit():
        token = form.token.data.strip()
        domain = form.domain.data.strip()
        try:
            provider.verify_credentials(token=token, domain=domain)
            provider.save_credentials(token=token, domain=domain)
            flash("GoDaddy API token saved and verified.", "success")
        except DNSProviderError as exc:
            flash(f"GoDaddy rejected these credentials: {exc}", "error")
    else:
        flash("Enter a GoDaddy API token and the domain to manage.", "error")
    return redirect(url_for("dns.index", provider="godaddy"))


@dns_bp.route("/dns/godaddy/credentials/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_godaddy_credentials():
    get_provider("godaddy").remove_credentials()
    flash("GoDaddy disconnected. The token was removed from this panel.", "success")
    return redirect(url_for("dns.index", provider="godaddy"))


# ---------------------------------------------------------------------------
# Provider-agnostic: active domain/zone + record CRUD
# ---------------------------------------------------------------------------

@dns_bp.route("/dns/zone", methods=["POST"])
@require_permission("dns.manage")
def select_zone():
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = request.form.get("zone_id", "").strip()
    provider.persist_active_domain(zone_id)
    flash("Active domain updated.", "success")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/add", methods=["POST"])
@require_permission("dns.manage")
def add_record():
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    if not zone_id:
        flash("Select a domain before adding records.", "error")
        return redirect(url_for("dns.index", provider=provider_key))

    form = DnsRecordForm()
    form.type.choices = [(t, t) for t in provider.record_types]
    if form.validate_on_submit():
        try:
            provider.create_record(
                zone_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Created {form.type.data} record for {form.name.data}.", "success")
        except DNSProviderError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/<record_id>/edit", methods=["POST"])
@require_permission("dns.manage")
def edit_record(record_id):
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    form = DnsRecordForm()
    form.type.choices = [(t, t) for t in provider.record_types]
    if form.validate_on_submit():
        try:
            provider.update_record(
                zone_id, record_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Updated {form.type.data} record for {form.name.data}.", "success")
        except DNSProviderError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index", provider=provider_key))


@dns_bp.route("/dns/record/<record_id>/delete", methods=["POST"])
@require_permission("dns.manage")
def delete_record(record_id):
    provider_key = request.form.get("provider", _active_provider_key())
    provider = get_provider(provider_key)
    zone_id = provider.active_domain_id()
    try:
        provider.delete_record(zone_id, record_id)
        flash("Record deleted.", "success")
    except DNSProviderError as exc:
        flash(str(exc), "error")
    return redirect(url_for("dns.index", provider=provider_key))

