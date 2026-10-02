#!/usr/bin/env bash
# Deploys multi-account Cloudflare DNS support onto OpsLab Server Panel.
# Safe to re-run: backs up whatever's currently in place before writing
# anything, and skips the config.py patch if it's already applied.
set -euo pipefail

# --- Verify/adjust these paths for your layout before running ---------
PANEL_DIR="/root/server-panel"
CONFIG_PY="$PANEL_DIR/config.py"
CF_SERVICE_PY="$PANEL_DIR/services/cloudflare_service.py"
DNS_ROUTES_PY="$PANEL_DIR/modules/dns/routes.py"
DNS_FORMS_PY="$PANEL_DIR/modules/dns/forms.py"
DNS_TEMPLATE="$PANEL_DIR/modules/dns/templates/dns_index.html"
# ------------------------------------------------------------------------

BACKUP_DIR="$PANEL_DIR/backups/dns-multi-account-$(date +%Y%m%d-%H%M%S)"

echo "== DNS multi-account deploy =="

for f in "$CONFIG_PY" "$CF_SERVICE_PY" "$DNS_ROUTES_PY" "$DNS_FORMS_PY" "$DNS_TEMPLATE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected file not found: $f"
    echo "Edit the path variables at the top of this script to match your actual layout, then re-run."
    echo "(e.g. run: find \"$PANEL_DIR\" -iname 'dns_index.html' -o -iname 'cloudflare_service.py')"
    exit 1
  fi
done

mkdir -p "$BACKUP_DIR"
echo "Backing up current files to $BACKUP_DIR"
cp "$CONFIG_PY" "$BACKUP_DIR/config.py.bak"
cp "$CF_SERVICE_PY" "$BACKUP_DIR/cloudflare_service.py.bak"
cp "$DNS_ROUTES_PY" "$BACKUP_DIR/routes.py.bak"
cp "$DNS_FORMS_PY" "$BACKUP_DIR/forms.py.bak"
cp "$DNS_TEMPLATE" "$BACKUP_DIR/dns_index.html.bak"

# 1) Patch config.py additively - only appends, never removes anything,
#    and skips entirely if already applied so this script is re-run-safe.
if grep -q "def get_cloudflare_connections" "$CONFIG_PY"; then
  echo "config.py already patched - skipping."
else
  echo "Patching config.py..."
  grep -q "^import json" "$CONFIG_PY" || sed -i '1i import json' "$CONFIG_PY"
  grep -q "^import base64" "$CONFIG_PY" || sed -i '1i import base64' "$CONFIG_PY"

  cat >> "$CONFIG_PY" << 'CONFIG_PATCH_EOF'

def get_cloudflare_connections():
    """Returns saved Cloudflare accounts: [{"id", "label", "token"}, ...].
    Stored as base64-encoded JSON in one env line (CLOUDFLARE_CONNECTIONS_B64)
    rather than raw JSON, because _write_env_line() does no escaping - a
    JSON value containing '=', '#', or spaces could corrupt the .env file
    or get truncated on the next rewrite. Base64 avoids that with zero
    changes to _write_env_line.

    Transparently migrates a legacy single CLOUDFLARE_API_TOKEN (from
    before multi-account support) into this list on first read, so
    existing installs don't lose their saved token.
    """
    raw = os.environ.get("CLOUDFLARE_CONNECTIONS_B64", "")
    if raw:
        try:
            return json.loads(base64.b64decode(raw.encode("utf-8")).decode("utf-8"))
        except Exception:
            return []

    legacy_token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if legacy_token:
        migrated = [{"id": "default", "label": "Default", "token": legacy_token}]
        persist_cloudflare_connections(migrated)
        return migrated
    return []


def persist_cloudflare_connections(connections):
    encoded = base64.b64encode(
        json.dumps(connections, separators=(",", ":")).encode("utf-8")
    ).decode("utf-8")
    _write_env_line("CLOUDFLARE_CONNECTIONS_B64", encoded)


def persist_cloudflare_active_zone(connection_id, zone_id):
    """Which zone is selected right now, and which saved connection owns
    it - two lines so record add/edit/delete can find the right token
    without re-querying every connection's zones on each request."""
    _write_env_line("CLOUDFLARE_ACTIVE_CONNECTION_ID", connection_id or "")
    _write_env_line("CLOUDFLARE_ZONE_ID", zone_id or "")

CONFIG_PATCH_EOF
  echo "config.py patched."
fi

# 2) Full-file replacements
echo "Writing services/cloudflare_service.py..."
cat > "$CF_SERVICE_PY" << 'CF_SERVICE_EOF'
"""Thin wrapper around the Cloudflare v4 REST API for managing DNS
records. Plain authenticated HTTPS calls via `requests` — no Cloudflare
SDK dependency.

Every function here takes the API token explicitly as its first argument
rather than reading one global token out of app config. That's what makes
multi-account support possible: the panel can hold several saved
Cloudflare accounts (config.get_cloudflare_connections()), each with its
own token, and this module doesn't need to know or care how many there
are — it just talks to whichever token it's handed for that call.
"""
import requests

API_BASE = "https://api.cloudflare.com/client/v4"
TIMEOUT = 15

# Record types the panel's Add/Edit form exposes. Cloudflare also supports
# structured types like SRV/CAA/DS that use a nested "data" object instead
# of a flat "content" string — deliberately left out here rather than
# half-supporting them with a form that can't represent their real shape.
# Those can still be managed directly in the Cloudflare dashboard.
RECORD_TYPES = ["A", "AAAA", "CNAME", "TXT", "MX", "NS"]

# Record types Cloudflare allows to be proxied through its edge network
# (the "orange cloud"). Everything else must stay DNS-only.
PROXYABLE_TYPES = {"A", "AAAA", "CNAME"}


class CloudflareError(Exception):
    pass


def _request(method, path, token, **kwargs):
    if not token:
        raise CloudflareError("No Cloudflare API token provided for this request.")

    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    try:
        resp = requests.request(method, f"{API_BASE}{path}", headers=headers, timeout=TIMEOUT, **kwargs)
    except requests.RequestException as exc:
        raise CloudflareError(f"Couldn't reach Cloudflare: {exc}") from exc

    try:
        payload = resp.json()
    except ValueError:
        raise CloudflareError(f"Cloudflare returned an unexpected response (HTTP {resp.status_code}).")

    if not payload.get("success"):
        messages = [e.get("message", "Unknown error") for e in payload.get("errors", [])]
        raise CloudflareError("; ".join(messages) or f"Cloudflare API error (HTTP {resp.status_code}).")

    return payload.get("result")


def verify_token(token):
    """Validates a token before it's saved as a new connection, so a
    typo'd/scoped-wrong token never gets written to disk."""
    _request("GET", "/user/tokens/verify", token)
    return True


def list_zones(token):
    result = _request("GET", "/zones?per_page=50", token)
    return [{"id": z["id"], "name": z["name"], "status": z.get("status", "unknown")} for z in result]


def list_dns_records(token, zone_id):
    result = _request("GET", f"/zones/{zone_id}/dns_records?per_page=100", token)
    records = [
        {
            "id": r["id"],
            "type": r["type"],
            "name": r["name"],
            "content": r["content"],
            "ttl": r["ttl"],
            "proxied": r.get("proxied", False),
            "priority": r.get("priority"),
        }
        for r in result
    ]
    records.sort(key=lambda r: (r["type"], r["name"]))
    return records


def _record_body(record_type, name, content, ttl, proxied, priority):
    body = {"type": record_type, "name": name, "content": content, "ttl": int(ttl or 1)}
    if record_type in PROXYABLE_TYPES:
        body["proxied"] = bool(proxied)
    if record_type == "MX" and priority not in (None, ""):
        body["priority"] = int(priority)
    return body


def create_dns_record(token, zone_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    body = _record_body(record_type, name, content, ttl, proxied, priority)
    return _request("POST", f"/zones/{zone_id}/dns_records", token, json=body)


def update_dns_record(token, zone_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
    body = _record_body(record_type, name, content, ttl, proxied, priority)
    return _request("PUT", f"/zones/{zone_id}/dns_records/{record_id}", token, json=body)


def delete_dns_record(token, zone_id, record_id):
    _request("DELETE", f"/zones/{zone_id}/dns_records/{record_id}", token)
    return True

CF_SERVICE_EOF

echo "Writing modules/dns/forms.py..."
cat > "$DNS_FORMS_PY" << 'DNS_FORMS_EOF'
from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, IntegerField, BooleanField
from wtforms.validators import DataRequired, Length, Optional, NumberRange

from services.cloudflare_service import RECORD_TYPES


class ConnectionForm(FlaskForm):
    """Adds a new saved Cloudflare account. Label is just a local display
    name ("Personal", "Client X") used to tell accounts apart in the zone
    dropdown — Cloudflare itself doesn't know about it."""
    label = StringField("Label", validators=[DataRequired(), Length(max=60)])
    token = StringField("Cloudflare API Token", validators=[DataRequired(), Length(max=200)])


class DnsRecordForm(FlaskForm):
    type = SelectField("Type", choices=[(t, t) for t in RECORD_TYPES], validators=[DataRequired()])
    name = StringField("Name", validators=[DataRequired(), Length(max=255)])
    content = StringField("Content", validators=[DataRequired(), Length(max=500)])
    ttl = IntegerField("TTL (seconds, 1 = Auto)", default=1, validators=[Optional(), NumberRange(min=1, max=86400)])
    proxied = BooleanField("Proxied (orange cloud)")
    priority = IntegerField("Priority (MX only)", validators=[Optional(), NumberRange(min=0, max=65535)])

DNS_FORMS_EOF

echo "Writing modules/dns/routes.py..."
cat > "$DNS_ROUTES_PY" << 'DNS_ROUTES_EOF'
import os
import secrets

from flask import Blueprint, render_template, redirect, url_for, flash, request

from services import cloudflare_service as cf
from modules.dns.forms import ConnectionForm, DnsRecordForm
from utils.permissions import require_permission
from config import (
    get_cloudflare_connections,
    persist_cloudflare_connections,
    persist_cloudflare_active_zone,
)

dns_bp = Blueprint("dns", __name__, template_folder="templates")


def _active_zone_ref():
    """Which zone is currently selected, and which saved connection owns
    it. Read straight from os.environ (same as config.get_cloudflare_
    connections() does) rather than current_app.config, since
    _write_env_line() only updates os.environ — current_app.config would
    go stale until a restart otherwise."""
    return (
        os.environ.get("CLOUDFLARE_ACTIVE_CONNECTION_ID", ""),
        os.environ.get("CLOUDFLARE_ZONE_ID", ""),
    )


def _connection_by_id(connections, connection_id):
    return next((c for c in connections if c["id"] == connection_id), None)


def _active_token_and_zone():
    connection_id, zone_id = _active_zone_ref()
    conn = _connection_by_id(get_cloudflare_connections(), connection_id)
    return (conn["token"] if conn else None), zone_id


@dns_bp.route("/dns")
@require_permission("dns.view")
def index():
    connections = get_cloudflare_connections()
    if not connections:
        return render_template("dns_index.html", configured=False, connection_form=ConnectionForm())

    # Pull each connection's zones independently — one revoked or
    # miss-scoped token shouldn't take the whole page down, just that
    # account's zones.
    all_zones = []
    connection_errors = {}
    for conn in connections:
        try:
            for zone in cf.list_zones(conn["token"]):
                zone["connection_id"] = conn["id"]
                zone["connection_label"] = conn["label"]
                all_zones.append(zone)
        except cf.CloudflareError as exc:
            connection_errors[conn["id"]] = str(exc)

    active_connection_id, active_zone_id = _active_zone_ref()
    active_zone = next(
        (z for z in all_zones if z["id"] == active_zone_id and z["connection_id"] == active_connection_id),
        None,
    )
    if not active_zone and all_zones:
        # Previously-active zone is gone (its account was removed, the
        # zone was deleted, or nothing's been picked yet) — fall back to
        # the first available zone across all connected accounts rather
        # than showing a blank page.
        active_zone = all_zones[0]
        active_connection_id, active_zone_id = active_zone["connection_id"], active_zone["id"]
        persist_cloudflare_active_zone(active_connection_id, active_zone_id)

    records = []
    error = connection_errors.get(active_connection_id) if active_zone else None
    if active_zone:
        conn = _connection_by_id(connections, active_connection_id)
        try:
            records = cf.list_dns_records(conn["token"], active_zone_id)
        except cf.CloudflareError as exc:
            error = str(exc)

    return render_template(
        "dns_index.html",
        configured=True,
        connections=connections,
        zones=all_zones,
        connection_errors=connection_errors,
        active_connection_id=active_connection_id,
        active_zone_id=active_zone_id,
        active_zone=active_zone,
        records=records,
        error=error,
        connection_form=ConnectionForm(),
        record_form=DnsRecordForm(),
        proxyable_types=cf.PROXYABLE_TYPES,
    )


@dns_bp.route("/dns/connection/add", methods=["POST"])
@require_permission("dns.manage")
def add_connection():
    form = ConnectionForm()
    if form.validate_on_submit():
        token = form.token.data.strip()
        label = form.label.data.strip()
        try:
            cf.verify_token(token)
            connections = get_cloudflare_connections()
            connections.append({"id": secrets.token_hex(4), "label": label, "token": token})
            persist_cloudflare_connections(connections)
            flash(f'Cloudflare account "{label}" connected.', "success")
        except cf.CloudflareError as exc:
            flash(f"Token rejected: {exc}", "error")
    else:
        flash("Enter a label and an API token.", "error")
    return redirect(url_for("dns.index"))


@dns_bp.route("/dns/connection/<connection_id>/remove", methods=["POST"])
@require_permission("dns.manage")
def remove_connection(connection_id):
    connections = get_cloudflare_connections()
    remaining = [c for c in connections if c["id"] != connection_id]
    persist_cloudflare_connections(remaining)

    active_connection_id, _ = _active_zone_ref()
    if active_connection_id == connection_id:
        # The account backing the currently-selected zone just got
        # removed — clear the selection instead of leaving it pointed at
        # a zone this panel can no longer authenticate to.
        persist_cloudflare_active_zone("", "")

    flash("Cloudflare account disconnected.", "success")
    return redirect(url_for("dns.index"))


@dns_bp.route("/dns/zone", methods=["POST"])
@require_permission("dns.manage")
def select_zone():
    # The dropdown submits one combined value ("<connection_id>::<zone_id>")
    # since a zone_id alone doesn't say which saved account's token owns it.
    raw = request.form.get("zone_ref", "")
    connection_id, _, zone_id = raw.partition("::")
    persist_cloudflare_active_zone(connection_id, zone_id)
    flash("Active zone updated.", "success")
    return redirect(url_for("dns.index"))


@dns_bp.route("/dns/record/add", methods=["POST"])
@require_permission("dns.manage")
def add_record():
    token, zone_id = _active_token_and_zone()
    if not token or not zone_id:
        flash("Select a zone before adding records.", "error")
        return redirect(url_for("dns.index"))

    form = DnsRecordForm()
    if form.validate_on_submit():
        try:
            cf.create_dns_record(
                token, zone_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Created {form.type.data} record for {form.name.data}.", "success")
        except cf.CloudflareError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index"))


@dns_bp.route("/dns/record/<record_id>/edit", methods=["POST"])
@require_permission("dns.manage")
def edit_record(record_id):
    token, zone_id = _active_token_and_zone()
    if not token or not zone_id:
        flash("Select a zone first.", "error")
        return redirect(url_for("dns.index"))

    form = DnsRecordForm()
    if form.validate_on_submit():
        try:
            cf.update_dns_record(
                token, zone_id, record_id, form.type.data, form.name.data.strip(), form.content.data.strip(),
                ttl=form.ttl.data or 1, proxied=form.proxied.data, priority=form.priority.data,
            )
            flash(f"Updated {form.type.data} record for {form.name.data}.", "success")
        except cf.CloudflareError as exc:
            flash(str(exc), "error")
    else:
        flash("Check the record fields and try again.", "error")
    return redirect(url_for("dns.index"))


@dns_bp.route("/dns/record/<record_id>/delete", methods=["POST"])
@require_permission("dns.manage")
def delete_record(record_id):
    token, zone_id = _active_token_and_zone()
    if not token or not zone_id:
        flash("Select a zone first.", "error")
        return redirect(url_for("dns.index"))
    try:
        cf.delete_dns_record(token, zone_id, record_id)
        flash("Record deleted.", "success")
    except cf.CloudflareError as exc:
        flash(str(exc), "error")
    return redirect(url_for("dns.index"))

DNS_ROUTES_EOF

echo "Writing modules/dns/templates/dns_index.html..."
cat > "$DNS_TEMPLATE" << 'DNS_TEMPLATE_EOF'
{% extends "base.html" %}
{% block title %}Cloudflare DNS — {{ panel_name }}{% endblock %}
{% block content %}
<div class="topbar">
  <div>
    <p class="page-eyebrow">Cloudflare</p>
    <h1 class="page-title">DNS</h1>
    <p class="page-sub">Manage DNS records across your Cloudflare-hosted domains</p>
  </div>
  {% if configured and zones %}
  <div class="topbar-actions">
    <form method="POST" action="{{ url_for('dns.select_zone') }}">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <select name="zone_ref" onchange="this.form.submit()" style="min-width:260px;">
        {% for conn in connections %}
          {% set conn_zones = zones | selectattr('connection_id', 'equalto', conn.id) | list %}
          {% if conn_zones %}
          <optgroup label="{{ conn.label }}">
            {% for zone in conn_zones %}
            <option value="{{ conn.id }}::{{ zone.id }}" {{ 'selected' if zone.id == active_zone_id and conn.id == active_connection_id }}>{{ zone.name }} ({{ zone.status }})</option>
            {% endfor %}
          </optgroup>
          {% endif %}
        {% endfor %}
      </select>
      <noscript><button type="submit" class="btn btn-secondary">Switch</button></noscript>
    </form>
  </div>
  {% endif %}
</div>

{% if not configured %}
  <div class="card" style="max-width:520px;">
    <div class="card-label">Connect a Cloudflare account</div>
    <p class="page-sub" style="margin:6px 0 16px;">
      Create an API token at <span class="mono">Cloudflare dashboard → My Profile → API Tokens</span> using the
      <strong>Edit zone DNS</strong> template, scoped to the zone(s) you want this panel to manage. The token is
      verified against Cloudflare before it's saved, and stored the same way this panel already stores its own
      secret key — plaintext in its private data directory, never in the code folder. You can connect more
      accounts later if your domains live under more than one Cloudflare login.
    </p>
    <form method="POST" action="{{ url_for('dns.add_connection') }}">
      {{ connection_form.hidden_tag() }}
      <div class="field">
        {{ connection_form.label.label }}
        {{ connection_form.label(placeholder="e.g. Personal, Client X") }}
      </div>
      <div class="field">
        {{ connection_form.token.label }}
        {{ connection_form.token(placeholder="Cloudflare API token", type="password", autocomplete="off") }}
      </div>
      <button class="btn btn-primary btn-block" type="submit">Verify &amp; connect</button>
    </form>
  </div>
{% else %}

  {% if error %}
  <div class="flash flash-error">{{ error }}</div>
  {% endif %}

  <div class="card flush tight" style="margin-bottom:16px;">
    <div class="card-header" style="padding:16px 18px 0;">
      <div class="card-label" style="margin:0;">Connected accounts</div>
      <button type="button" class="btn btn-secondary btn-sm" onclick="openAccountModal()">+ Add account</button>
    </div>
    <div class="table-wrap">
      <table class="data-table" style="margin-top:8px;">
        <thead><tr><th>Label</th><th>Status</th><th>Actions</th></tr></thead>
        <tbody>
          {% for conn in connections %}
          <tr>
            <td class="mono primary">{{ conn.label }}</td>
            <td>
              {% if connection_errors.get(conn.id) %}
                <span class="badge badge-muted" style="color:#ef4444;" title="{{ connection_errors[conn.id] }}">Error</span>
              {% else %}
                <span class="badge badge-ok">Connected</span>
              {% endif %}
            </td>
            <td class="table-actions">
              <form method="POST" action="{{ url_for('dns.remove_connection', connection_id=conn.id) }}"
                    onsubmit="return confirm('Remove the &quot;{{ conn.label }}&quot; Cloudflare account? Domains under it will no longer be manageable from this panel.');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <button type="submit" class="btn btn-danger btn-sm">Remove</button>
              </form>
            </td>
          </tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>

  {% if zones %}
  <div class="grid">
    <div class="card stat">
      <div class="card-label">Zone</div>
      <div class="card-value line">
        <span class="status-dot {{ 'ok live' if active_zone and active_zone.status == 'active' else '' }}"></span>
        {{ active_zone.name if active_zone else '—' }}
      </div>
      <div class="card-meta">{{ active_zone.connection_label if active_zone else '' }}{% if active_zone %} · {{ active_zone.status | capitalize }}{% endif %}</div>
    </div>
    <div class="card stat">
      <div class="card-label">Domains connected</div>
      <div class="card-value">{{ zones | length }}</div>
      <div class="card-meta">across {{ connections | length }} account{{ 's' if connections | length != 1 }}</div>
    </div>
    <div class="card stat">
      <div class="card-label">Total Records</div>
      <div class="card-value">{{ records | length }}</div>
      <div class="card-meta">on the active zone</div>
    </div>
    <div class="card stat">
      <div class="card-label">Proxied</div>
      <div class="card-value">{{ records | selectattr('proxied') | list | length }}</div>
      <div class="card-meta">routed through Cloudflare's edge</div>
    </div>
  </div>

  <div class="card flush tight" style="margin-top:16px;">
    <div class="card-header" style="padding:16px 18px 0;">
      <div class="card-label" style="margin:0;">
        {{ active_zone.name if active_zone else 'Zone' }} — {{ records | length }} record{{ 's' if records | length != 1 }}
      </div>
      <button type="button" class="btn btn-primary btn-sm" onclick="openRecordModal()">+ Add record</button>
    </div>
    <div class="table-wrap">
      <table class="data-table" style="margin-top:8px;">
        <thead><tr><th>Type</th><th>Name</th><th>Content</th><th>TTL</th><th>Proxy</th><th>Actions</th></tr></thead>
        <tbody>
          {% for r in records %}
          <tr>
            <td><span class="badge badge-muted mono">{{ r.type }}</span></td>
            <td class="mono primary">{{ r.name }}</td>
            <td class="mono">{{ r.content }}{% if r.type == 'MX' and r.priority is not none %} <span class="page-sub">(pri {{ r.priority }})</span>{% endif %}</td>
            <td class="mono">{{ 'Auto' if r.ttl == 1 else r.ttl }}</td>
            <td>
              {% if r.type in proxyable_types %}
                {% if r.proxied %}<span class="badge badge-ok">Proxied</span>{% else %}<span class="badge badge-muted">DNS only</span>{% endif %}
              {% else %}
                <span class="badge badge-muted">—</span>
              {% endif %}
            </td>
            <td class="table-actions">
              <button type="button" class="btn btn-secondary btn-sm"
                      onclick='openRecordModal({{ r | tojson }})'>Edit</button>
              <form method="POST" action="{{ url_for('dns.delete_record', record_id=r.id) }}"
                    onsubmit="return confirm('Delete the {{ r.type }} record for {{ r.name }}?');">
                <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
                <button type="submit" class="btn btn-danger btn-sm">Delete</button>
              </form>
            </td>
          </tr>
          {% else %}
          <tr><td colspan="6"><div class="empty-state"><strong>No DNS records on this zone yet.</strong>Click "+ Add record" above to create your first one.</div></td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>
  {% else %}
  <div class="card">
    <div class="empty-state">
      <strong>No zones visible yet</strong>
      Double check each connected account's token scope in the Cloudflare dashboard, then reload this page.
    </div>
  </div>
  {% endif %}

  <div class="modal-overlay" id="record-modal">
    <div class="modal-box modal-browse">
      <div class="modal-header">
        <h3 id="record-modal-title">Add record</h3>
        <button class="modal-close" type="button" id="record-close">&times;</button>
      </div>
      <form method="POST" id="record-form" style="padding:18px;">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <div class="field">
          <label for="record-type">Type</label>
          <select name="type" id="record-type" onchange="toggleRecordFields()">
            {% for t in record_form.type.choices %}
            <option value="{{ t[0] }}">{{ t[1] }}</option>
            {% endfor %}
          </select>
        </div>
        <div class="field"><label for="record-name">Name</label><input type="text" name="name" id="record-name" placeholder="www or @ for root"></div>
        <div class="field"><label for="record-content">Content</label><input type="text" name="content" id="record-content" placeholder="192.0.2.1 or target host"></div>
        <div class="field"><label for="record-ttl">TTL (seconds, 1 = Auto)</label><input type="number" name="ttl" id="record-ttl" min="1" max="86400" value="1"></div>
        <div class="field field-inline" id="record-proxied-field">
          <input type="checkbox" name="proxied" id="record-proxied" value="y"> <label for="record-proxied" style="margin:0;">Proxied (orange cloud)</label>
        </div>
        <div class="field" id="record-priority-field">
          <label for="record-priority">Priority (MX only)</label>
          <input type="number" name="priority" id="record-priority" min="0" max="65535" placeholder="10">
        </div>
        <div class="editor-footer" style="padding:0; border:none;">
          <button type="button" class="btn btn-ghost" id="record-cancel">Cancel</button>
          <button type="submit" class="btn btn-primary" id="record-submit">Add record</button>
        </div>
      </form>
    </div>
  </div>

  <div class="modal-overlay" id="account-modal">
    <div class="modal-box modal-browse">
      <div class="modal-header">
        <h3>Add Cloudflare account</h3>
        <button class="modal-close" type="button" id="account-close">&times;</button>
      </div>
      <form method="POST" action="{{ url_for('dns.add_connection') }}" style="padding:18px;">
        {{ connection_form.hidden_tag() }}
        <div class="field">
          {{ connection_form.label.label }}
          {{ connection_form.label(placeholder="e.g. Personal, Client X") }}
        </div>
        <div class="field">
          {{ connection_form.token.label }}
          {{ connection_form.token(placeholder="Cloudflare API token", type="password", autocomplete="off") }}
        </div>
        <div class="editor-footer" style="padding:0; border:none;">
          <button type="button" class="btn btn-ghost" id="account-cancel">Cancel</button>
          <button type="submit" class="btn btn-primary">Verify &amp; connect</button>
        </div>
      </form>
    </div>
  </div>
{% endif %}
{% endblock %}

{% block scripts %}
<script>
  const PROXYABLE_TYPES = {{ (proxyable_types | list) | tojson if proxyable_types else '[]' }};
  const ADD_URL = {{ url_for('dns.add_record') | tojson if configured else '""' }};

  function toggleRecordFields() {
    const type = document.getElementById('record-type').value;
    const proxiedField = document.getElementById('record-proxied-field');
    const priorityField = document.getElementById('record-priority-field');
    proxiedField.style.display = PROXYABLE_TYPES.includes(type) ? '' : 'none';
    priorityField.style.display = type === 'MX' ? '' : 'none';
  }

  const recordModal = document.getElementById('record-modal');

  // Called with no args to add a new record, or with a record object
  // (from the row's Edit button) to pre-fill and edit that one in place.
  function openRecordModal(record) {
    const form = document.getElementById('record-form');
    const title = document.getElementById('record-modal-title');
    const submitBtn = document.getElementById('record-submit');

    if (record) {
      title.textContent = 'Edit record';
      submitBtn.textContent = 'Save changes';
      form.action = '/dns/record/' + record.id + '/edit';
      document.getElementById('record-type').value = record.type;
      document.getElementById('record-name').value = record.name;
      document.getElementById('record-content').value = record.content;
      document.getElementById('record-ttl').value = record.ttl;
      document.getElementById('record-proxied').checked = !!record.proxied;
      document.getElementById('record-priority').value = record.priority ?? '';
    } else {
      title.textContent = 'Add record';
      submitBtn.textContent = 'Add record';
      form.action = ADD_URL;
      form.reset();
      document.getElementById('record-ttl').value = 1;
    }
    toggleRecordFields();
    recordModal.classList.add('open');
  }

  if (recordModal) {
    document.getElementById('record-close').addEventListener('click', () => recordModal.classList.remove('open'));
    document.getElementById('record-cancel').addEventListener('click', () => recordModal.classList.remove('open'));
    recordModal.addEventListener('click', (e) => { if (e.target === recordModal) recordModal.classList.remove('open'); });
  }

  const accountModal = document.getElementById('account-modal');

  function openAccountModal() {
    if (accountModal) accountModal.classList.add('open');
  }

  if (accountModal) {
    document.getElementById('account-close').addEventListener('click', () => accountModal.classList.remove('open'));
    document.getElementById('account-cancel').addEventListener('click', () => accountModal.classList.remove('open'));
    accountModal.addEventListener('click', (e) => { if (e.target === accountModal) accountModal.classList.remove('open'); });
  }
</script>
{% endblock %}

DNS_TEMPLATE_EOF

echo ""
echo "Done. Previous versions backed up to: $BACKUP_DIR"
echo ""
echo "Next steps:"
echo "  1) Restart the panel service (e.g. systemctl restart server-panel, or whatever you use)"
echo "  2) Load /dns - your existing token should auto-migrate into a connection named 'Default'"
echo "  3) If anything looks wrong, restore from $BACKUP_DIR and let me know what broke"
