from datetime import datetime
import os
import time

from flask import Blueprint, current_app, jsonify, render_template, request
from flask_login import current_user

from database import db
from models.job import Job
from models.tx_instance import TxInstance
from models.tx_network import TxDomain, TxPortRequest
from services import database_service as dbsvc
from services import txadmin_api as txapi
from services import txadmin_service as txsvc
from services import txadmin_net as net
from tasks.background import start_job
from utils.permissions import require_permission

txadmin_bp = Blueprint("txadmin", __name__, template_folder="templates")

BUSY_STATES = {"installing", "working", "deleting"}


def _ok(**data):
    return jsonify({"ok": True, **data})


def _fail(msg, status=400):
    return jsonify({"ok": False, "error": str(msg)}), status


def _body():
    return request.get_json(silent=True) or {}


def _audit(action, detail):
    current_app.logger.warning("TX %s by %s: %s", action, getattr(current_user, "username", "?"), detail)


def _get(inst_id):
    inst = db.session.get(TxInstance, inst_id)
    if not inst:
        raise txsvc.TxError("Instance not found.")
    return inst


def _start(inst, label, fn, *args, state="working"):
    if inst.state in BUSY_STATES:
        raise txsvc.TxError(f"'{inst.name}' is busy ({inst.state}) — wait for the current job to finish.")
    inst.state = state
    db.session.commit()
    app = current_app._get_current_object()
    job_id = start_job(app, f"{label}: {inst.name}", f"tx:{inst.slug}", fn, current_user.id, app, inst.id, *args)
    inst.last_job_id = job_id
    db.session.commit()
    return job_id


def _adopt_existing():
    """Register txAdmin installs that already exist on the box (e.g. the
    original /root/fivem) so they show up next to panel-made ones."""
    known = {i.service_unit for i in TxInstance.query.all()}
    added = False
    for cand in txsvc.discover_unmanaged(known):
        info = txsvc.adopt_info(cand)
        base_slug = txsvc.slugify(cand["unit"].removesuffix(".service"))
        slug, n = base_slug, 2
        while TxInstance.query.filter_by(slug=slug).first():
            slug, n = f"{base_slug[:19]}_{n}", n + 1
        db.session.add(TxInstance(
            slug=slug, name=cand["unit"].removesuffix(".service"), managed=False,
            base_dir=cand["base_dir"], txdata_dir=cand["txdata_dir"], server_dir=cand["server_dir"],
            artifact_build=info.get("artifact_build"), service_unit=cand["unit"],
            tx_port=cand["tx_port"], game_port=info.get("game_port", 30120),
            tx_username=info.get("tx_username"), db_name=info.get("database"), db_user=info.get("user"),
            db_password=info.get("password"), cfx_key=info.get("cfx_key"),
            notes="Existing install found on this server. The txAdmin password wasn't recorded by the panel — use 'Reset password' to set one you can see here.",
        ))
        added = True
    if added:
        db.session.commit()


@txadmin_bp.route("/tx")
@require_permission("txadmin.manage")
def index():
    return render_template("tx_index.html")


@txadmin_bp.route("/tx/<int:inst_id>/panel")
@require_permission("txadmin.manage")
def panel(inst_id):
    inst = db.session.get(TxInstance, inst_id)
    if not inst:
        return render_template("tx_index.html"), 404
    d = inst.to_dict(txsvc.public_ip(), secrets=False)
    _add_net(inst, d, with_ports=False)
    return render_template("tx_panel.html", inst=d)


@txadmin_bp.route("/tx/api/instances")
@require_permission("txadmin.manage")
def api_instances():
    try:
        _adopt_existing()
    except Exception as exc:  # noqa: BLE001 - discovery must never break the page
        current_app.logger.warning("tx discovery failed: %s", exc)
    ip = txsvc.public_ip()
    out = []
    for inst in TxInstance.query.order_by(TxInstance.created_at).all():
        d = inst.to_dict(ip, secrets=False)
        try:
            d["status"] = txsvc.status(inst)
        except Exception as exc:  # noqa: BLE001
            d["status"] = {"state": "unknown", "error": str(exc)}
        _add_net(inst, d)
        out.append(d)
    admin = net.is_full_admin(current_user)
    pending = TxPortRequest.query.filter_by(status="pending").count()
    return _ok(instances=out, public_ip=ip, pending_requests=pending,
               me={"username": current_user.username, "full_admin": admin}, join_zone=net.JOIN_ZONE)


@txadmin_bp.route("/tx/api/versions")
@require_permission("txadmin.manage")
def api_versions():
    cached = txsvc.cached_artifacts()
    try:
        return _ok(versions=txsvc.artifact_versions(), cached=cached)
    except txsvc.TxError as exc:
        return _ok(versions={}, cached=cached, warning=str(exc))


@txadmin_bp.route("/tx/api/create", methods=["POST"])
@require_permission("txadmin.manage")
def api_create():
    d = _body()
    name = (d.get("name") or "").strip()
    if not 2 <= len(name) <= 60:
        return _fail("Give the server a name (2–60 characters).")
    username = (d.get("tx_username") or "admin").strip()
    if not txsvc.USERNAME_RE.match(username):
        return _fail("txAdmin username must be 3–20 characters: letters, numbers, _ . - (not starting/ending with . or -).")
    cfx_key = (d.get("cfx_key") or "").strip() or None
    if cfx_key and not txsvc.CFX_KEY_RE.match(cfx_key):
        return _fail("That doesn't look like a Cfx.re license key (cfxk_…).")

    base_slug = txsvc.slugify(d.get("slug") or name)
    slug, n = base_slug, 2
    existing_dbs = {x["name"] for x in dbsvc.list_databases()} if dbsvc.is_installed() else set()
    existing_users = {u["user"] for u in dbsvc.list_users()} if dbsvc.is_installed() else set()
    while (TxInstance.query.filter_by(slug=slug).first() or os.path.exists(os.path.join(txsvc.TX_ROOT, slug))
           or f"tx_{slug}" in existing_dbs or f"tx_{slug}" in existing_users):
        slug, n = f"{base_slug[:19]}_{n}", n + 1

    insts = TxInstance.query.all()
    taken_tx, taken_game = {i.tx_port for i in insts}, {i.game_port for i in insts}
    try:
        if d.get("port_mode") == "custom":
            tx_port, game_port = net.validate_custom_ports(d.get("tx_port"), d.get("game_port"), taken_tx, taken_game)
        else:
            tx_port, game_port = txsvc.allocate_ports(taken_tx, taken_game)
    except net.NetError as exc:
        return _fail(exc)

    domain_label = (d.get("domain") or "").strip().lower()
    if domain_label:
        if not net.LABEL_RE.match(domain_label) or domain_label in net.RESERVED_LABELS:
            return _fail("That join subdomain isn't allowed — use letters, numbers and hyphens.")
        if TxDomain.query.filter_by(hostname=f"{domain_label}.{net.JOIN_ZONE}").first():
            return _fail(f"{domain_label}.{net.JOIN_ZONE} is already taken.")

    auto_open = net.is_full_admin(current_user)
    base_dir = os.path.join(txsvc.TX_ROOT, slug)
    os.makedirs(base_dir, exist_ok=True)

    inst = TxInstance(
        slug=slug, name=name, managed=True, base_dir=base_dir,
        txdata_dir=os.path.join(base_dir, "txData"), server_dir=os.path.join(base_dir, "server"),
        service_unit=f"txadmin-{slug.replace('_', '-')}.service", tx_port=tx_port, game_port=game_port,
        tx_username=username, tx_password=txsvc.gen_password(),
        db_name=f"tx_{slug}", db_user=f"tx_{slug}"[:32], db_password=txsvc.gen_password(24),
        cfx_key=cfx_key, notes=(d.get("notes") or "").strip() or None, state="ready",
    )
    db.session.add(inst)
    db.session.commit()
    try:
        job_id = _start(inst, "txAdmin install", txsvc.job_install, d.get("build") or "recommended", auto_open, state="installing")
    except txsvc.TxError as exc:
        return _fail(exc)

    port_request = None
    if not auto_open:
        port_request = TxPortRequest(instance_id=inst.id, tx_port=tx_port, game_port=game_port,
                                     reason=(d.get("port_reason") or "").strip()[:1000] or None,
                                     requested_by=current_user.username)
        db.session.add(port_request)
        db.session.commit()

    domain, domain_error = None, None
    if domain_label:
        try:
            domain = _create_managed_domain(inst, domain_label)
        except net.NetError as exc:
            domain_error = str(exc)

    _audit("create", f"{slug} tx:{tx_port} game:{game_port} ports={'opened' if auto_open else 'requested'}")
    return _ok(instance=inst.to_dict(txsvc.public_ip()), job_id=job_id, ports_opened=auto_open,
               port_request=port_request.to_dict() if port_request else None,
               domain=domain.to_dict(inst.game_port) if domain else None, domain_error=domain_error)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>")
@require_permission("txadmin.manage")
def api_instance(inst_id):
    try:
        inst = _get(inst_id)
        d = inst.to_dict(txsvc.public_ip())
        d["status"] = txsvc.status(inst)
        d["folders"] = txsvc.server_data_folders(inst)
        d["env_path"] = txsvc._env_path(inst.slug)
        _add_net(inst, d)
        d["port_requests"] = [r.to_dict() for r in TxPortRequest.query.filter_by(instance_id=inst.id)
                              .order_by(TxPortRequest.created_at.desc()).limit(10).all()]
        return _ok(instance=d, me={"username": current_user.username, "full_admin": net.is_full_admin(current_user)},
                   dns=net.zone_info())
    except txsvc.TxError as exc:
        return _fail(exc, 404)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/control", methods=["POST"])
@require_permission("txadmin.manage")
def api_control(inst_id):
    action = _body().get("action")
    try:
        inst = _get(inst_id)
        if inst.state in BUSY_STATES:
            return _fail("Instance is busy with a job.")
        txsvc.control(inst, action)
        _audit(action, inst.slug)
        return _ok()
    except txsvc.TxError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/logs")
@require_permission("txadmin.manage")
def api_logs(inst_id):
    try:
        return _ok(logs=txsvc.logs(_get(inst_id), request.args.get("lines", 300)))
    except (txsvc.TxError, ValueError) as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/reinstall", methods=["POST"])
@require_permission("txadmin.manage")
def api_reinstall(inst_id):
    d = _body()
    try:
        inst = _get(inst_id)
        if not inst.managed and not net.is_full_admin(current_user):
            return _fail("Only full admins can reinstall or delete an existing (non-panel) install.", 403)
        job_id = _start(inst, "txAdmin reinstall", txsvc.job_reinstall, bool(d.get("wipe_db", True)), bool(d.get("keep_backup", True)))
        _audit("reinstall", f"{inst.slug} wipe_db={d.get('wipe_db', True)} backup={d.get('keep_backup', True)}")
        return _ok(job_id=job_id)
    except txsvc.TxError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/update", methods=["POST"])
@require_permission("txadmin.manage")
def api_update(inst_id):
    try:
        inst = _get(inst_id)
        job_id = _start(inst, "FXServer update", txsvc.job_update_artifact, _body().get("build") or "recommended")
        _audit("update artifact", inst.slug)
        return _ok(job_id=job_id)
    except txsvc.TxError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/delete", methods=["POST"])
@require_permission("txadmin.manage")
def api_delete(inst_id):
    d = _body()
    try:
        inst = _get(inst_id)
        if not inst.managed and not net.is_full_admin(current_user):
            return _fail("Only full admins can reinstall or delete an existing (non-panel) install.", 403)
        job_id = _start(inst, "txAdmin delete", txsvc.job_delete, bool(d.get("drop_db")), bool(d.get("delete_files", True)), state="deleting")
        txapi.forget(inst.id)
        _audit("DELETE", f"{inst.slug} drop_db={d.get('drop_db')} files={d.get('delete_files', True)}")
        return _ok(job_id=job_id)
    except txsvc.TxError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/details", methods=["POST"])
@require_permission("txadmin.manage")
def api_details(inst_id):
    """Edit the saved details. Doesn't touch MySQL or txAdmin itself — it's
    the panel's record (and the deployer defaults on next setup)."""
    d = _body()
    try:
        inst = _get(inst_id)
        if "name" in d:
            name = (d.get("name") or "").strip()
            if not 2 <= len(name) <= 60:
                return _fail("Name must be 2–60 characters.")
            inst.name = name
        if "tx_username" in d:
            u = (d.get("tx_username") or "").strip() or None
            if u and not txsvc.USERNAME_RE.match(u):
                return _fail("Invalid txAdmin username.")
            inst.tx_username = u
        for field, limit in (("db_name", 64), ("db_user", 32), ("db_password", 128), ("notes", 5000), ("tx_password", 128)):
            if field in d:
                val = (d.get(field) or "").strip() or None
                if val and len(val) > limit:
                    return _fail(f"{field} is too long.")
                setattr(inst, field, val)
        if "cfx_key" in d:
            key = (d.get("cfx_key") or "").strip() or None
            if key and not txsvc.CFX_KEY_RE.match(key):
                return _fail("That doesn't look like a Cfx.re license key.")
            inst.cfx_key = key
        db.session.commit()
        if inst.managed:
            txsvc.write_env(inst, include_account=not os.path.isfile(os.path.join(inst.txdata_dir, "admins.json")))
        _audit("edit details", inst.slug)
        return _ok(instance=inst.to_dict(txsvc.public_ip()))
    except txsvc.TxError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/password", methods=["POST"])
@require_permission("txadmin.manage")
def api_password(inst_id):
    d = _body()
    try:
        inst = _get(inst_id)
        if inst.state in BUSY_STATES:
            return _fail("Instance is busy with a job.")
        if d.get("tx_username"):
            if not txsvc.USERNAME_RE.match(d["tx_username"]):
                return _fail("Invalid txAdmin username.")
            inst.tx_username = d["tx_username"]
        password = (d.get("password") or "").strip() or txsvc.gen_password()
        txsvc.reset_tx_password(inst, password)
        db.session.commit()
        _audit("reset password", inst.slug)
        return _ok(instance=inst.to_dict(txsvc.public_ip()))
    except txsvc.TxError as exc:
        db.session.rollback()
        return _fail(exc)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/folder/delete", methods=["POST"])
@require_permission("txadmin.manage")
def api_folder_delete(inst_id):
    name = _body().get("name") or ""
    try:
        inst = _get(inst_id)
        txsvc.delete_server_data(inst, name)
        _audit("delete server data", f"{inst.slug}/{name}")
        return _ok()
    except txsvc.TxError as exc:
        return _fail(exc)


def _add_net(inst, d, with_ports=True):
    doms = TxDomain.query.filter_by(instance_id=inst.id).order_by(TxDomain.created_at).all()
    d["domains"] = [x.to_dict(inst.game_port) for x in doms]
    primary = next((x for x in doms if x.status == "active"), None)
    d["join"] = primary.to_dict(inst.game_port)["connect"] if primary else d.get("connect")
    if with_ports:
        d["ports"] = net.port_state(inst)
        pr = TxPortRequest.query.filter_by(instance_id=inst.id, status="pending").first()
        d["ports"]["pending_request"] = pr.to_dict() if pr else None


def _create_managed_domain(inst, label):
    fqdn, zone_id, rec_id = net.create_managed(label)
    dom = TxDomain(instance_id=inst.id, hostname=fqdn, kind="managed", zone_id=zone_id, record_id=rec_id,
                   status="active", detail=f"A record → {txsvc.public_ip()} (DNS only)",
                   created_by=current_user.username, checked_at=datetime.utcnow())
    db.session.add(dom)
    db.session.commit()
    _audit("domain create", fqdn)
    return dom


# ---------------------------------------------------------------- ports

@txadmin_bp.route("/tx/api/instance/<int:inst_id>/ports", methods=["POST"])
@require_permission("txadmin.manage")
def api_ports(inst_id):
    """Full admins: open the ports now. Everyone else: file a request."""
    d = _body()
    try:
        inst = _get(inst_id)
    except txsvc.TxError as exc:
        return _fail(exc, 404)
    if net.is_full_admin(current_user):
        try:
            opened = net.open_ports(inst)
        except Exception as exc:  # noqa: BLE001
            return _fail(f"Firewall error: {exc}")
        for r in TxPortRequest.query.filter_by(instance_id=inst.id, status="pending").all():
            r.status, r.decided_by, r.decided_at, r.decision_note = "approved", current_user.username, datetime.utcnow(), "Opened directly"
        db.session.commit()
        _audit("ports open", f"{inst.slug} {opened}")
        return _ok(opened=opened, message="Ports opened: " + ", ".join(opened))
    if TxPortRequest.query.filter_by(instance_id=inst.id, status="pending").first():
        return _fail("There's already a pending request for this server.")
    r = TxPortRequest(instance_id=inst.id, tx_port=inst.tx_port, game_port=inst.game_port,
                      reason=(d.get("reason") or "").strip()[:1000] or None, requested_by=current_user.username)
    db.session.add(r)
    db.session.commit()
    _audit("ports request", inst.slug)
    return _ok(request=r.to_dict(), message="Request sent — an admin will review it.")


@txadmin_bp.route("/tx/api/port-requests")
@require_permission("txadmin.manage")
def api_port_requests():
    q = TxPortRequest.query
    if not net.is_full_admin(current_user):
        q = q.filter_by(requested_by=current_user.username)
    status = request.args.get("status")
    if status:
        q = q.filter_by(status=status)
    reqs = q.order_by(TxPortRequest.created_at.desc()).limit(100).all()
    names = {i.id: (i.name, i.slug) for i in TxInstance.query.all()}
    out = []
    for r in reqs:
        d = r.to_dict()
        d["instance_name"] = names.get(r.instance_id, ("(deleted)", ""))[0]
        out.append(d)
    return _ok(requests=out)


@txadmin_bp.route("/tx/api/port-requests/<int:req_id>/<action>", methods=["POST"])
@require_permission("txadmin.manage")
def api_port_request_action(req_id, action):
    r = db.session.get(TxPortRequest, req_id)
    if not r:
        return _fail("Request not found.", 404)
    if r.status != "pending":
        return _fail(f"This request was already {r.status}.")
    note = (_body().get("note") or "").strip()[:1000] or None
    if action == "cancel":
        if r.requested_by != current_user.username and not net.is_full_admin(current_user):
            return _fail("You can only cancel your own requests.", 403)
        r.status = "cancelled"
    elif action in ("approve", "deny"):
        if not net.is_full_admin(current_user):
            return _fail("Only full admins can approve or deny port requests.", 403)
        if action == "approve":
            inst = db.session.get(TxInstance, r.instance_id)
            if not inst:
                return _fail("That server no longer exists.")
            # ports may have changed since the request; open what the server uses now
            try:
                net.open_ports(inst)
            except Exception as exc:  # noqa: BLE001
                return _fail(f"Firewall error: {exc}")
        r.status = "approved" if action == "approve" else "denied"
    else:
        return _fail("Unknown action.", 404)
    r.decided_by, r.decided_at, r.decision_note = current_user.username, datetime.utcnow(), note
    db.session.commit()
    _audit(f"ports {action}", f"request {r.id}")
    return _ok(request=r.to_dict())


# ---------------------------------------------------------------- join domains

@txadmin_bp.route("/tx/api/instance/<int:inst_id>/domains", methods=["POST"])
@require_permission("txadmin.manage")
def api_domain_create(inst_id):
    d = _body()
    try:
        inst = _get(inst_id)
    except txsvc.TxError as exc:
        return _fail(exc, 404)
    try:
        if d.get("kind") == "custom":
            host = net.normalize_custom(d.get("hostname"))
            if TxDomain.query.filter_by(hostname=host).first():
                return _fail(f"{host} is already linked to a server.")
            managed = TxDomain.query.filter_by(instance_id=inst.id, kind="managed").first()
            target = managed.hostname if managed else net.ensure_shared_target()
            status, detail = net.check(host)
            dom = TxDomain(instance_id=inst.id, hostname=host, kind="custom", target=target, status=status,
                           detail=detail, created_by=current_user.username, checked_at=datetime.utcnow())
            db.session.add(dom)
            db.session.commit()
            _audit("domain link", host)
        else:
            if TxDomain.query.filter_by(hostname=f"{(d.get('label') or '').strip().lower()}.{net.JOIN_ZONE}").first():
                return _fail("That subdomain is already taken.")
            dom = _create_managed_domain(inst, d.get("label"))
        return _ok(domain=dom.to_dict(inst.game_port), public_ip=txsvc.public_ip())
    except net.NetError as exc:
        return _fail(exc)


@txadmin_bp.route("/tx/api/domains/<int:dom_id>/verify", methods=["POST"])
@require_permission("txadmin.manage")
def api_domain_verify(dom_id):
    dom = db.session.get(TxDomain, dom_id)
    if not dom:
        return _fail("Domain not found.", 404)
    dom.status, dom.detail = net.check(dom.hostname)
    dom.checked_at = datetime.utcnow()
    db.session.commit()
    inst = db.session.get(TxInstance, dom.instance_id)
    return _ok(domain=dom.to_dict(inst.game_port if inst else None))


@txadmin_bp.route("/tx/api/domains/<int:dom_id>/delete", methods=["POST"])
@require_permission("txadmin.manage")
def api_domain_delete(dom_id):
    dom = db.session.get(TxDomain, dom_id)
    if not dom:
        return _fail("Domain not found.", 404)
    if dom.kind == "managed":
        try:
            net.delete_managed(dom.zone_id, dom.record_id, dom.hostname)
        except net.NetError as exc:
            return _fail(exc)
    db.session.delete(dom)
    db.session.commit()
    _audit("domain delete", dom.hostname)
    return _ok()


# ---------------------------------------------------------------- Claude Code (claude.ai/code Remote Control)
# Full admins only: Claude Code runs as root on this machine.

import re as _re  # noqa: E402

from models.tx_claude import TxClaudeLink  # noqa: E402
from services import claude_rc  # noqa: E402
from services import claude_hooks  # noqa: E402

_SESSION_KEY_RE = _re.compile(r"^(login|trust-\d+|rc-\d+)$")


def _claude_admin_or_403():
    if not net.is_full_admin(current_user):
        return _fail("Claude Code is limited to full admins: it runs with root access on this server.", 403)
    return None


def _link_dir(inst, rel):
    root = txsvc._resources_root(inst)
    path = os.path.realpath(os.path.join(root, rel)) if rel else root
    if path != root and not path.startswith(root + os.sep):
        raise txsvc.TxError("Invalid folder.")
    if not os.path.isdir(path):
        raise txsvc.TxError("That folder doesn't exist.")
    return path


def _start_link(link, path):
    """Install the live-error hooks, then start Remote Control."""
    try:
        claude_hooks.write_config(current_app._get_current_object())
        claude_hooks.install(path)
    except Exception as exc:  # noqa: BLE001 - never block linking on the hooks
        current_app.logger.warning("claude hooks install failed for %s: %s", path, exc)
    claude_rc.start_remote_control(link.id, path, link.name, link.permission_mode)


def _link_targets(inst):
    """Folders that can be linked: the whole resources folder, each
    [category] folder, and each resource."""
    out = [{"rel_path": "", "label": "Whole resources folder", "kind": "root"}]
    seen = set()
    for r in sorted(txsvc.scan_resources(inst), key=lambda r: (r["folder"], r["name"])):
        parts = [p for p in r["folder"].split("/") if p]
        for i in range(1, len(parts) + 1):
            f = "/".join(parts[:i])
            if f not in seen:
                seen.add(f)
                out.append({"rel_path": f, "label": f, "kind": "folder"})
        out.append({"rel_path": (r["folder"] + "/" if r["folder"] else "") + r["name"], "label": r["name"], "kind": "resource", "folder": r["folder"]})
    return out


def _link_dict(link, inst=None):
    d = link.to_dict()
    st = claude_rc.link_status(link.id)
    d.update(status=st["state"], prompt=st.get("prompt"), question=st.get("question"), url=st.get("url"), alive=st["alive"])
    if inst:
        try:
            d["path"] = _link_dir(inst, link.rel_path)
            d["trusted"] = claude_rc.is_trusted(d["path"])
            d["live_errors"] = claude_hooks.installed(d["path"])
        except txsvc.TxError as exc:
            d["path"], d["trusted"], d["error"] = None, False, str(exc)
    return d


@txadmin_bp.route("/tx/api/claude/account")
@require_permission("txadmin.manage")
def api_claude_account():
    deny = _claude_admin_or_403()
    if deny:
        return deny
    return _ok(account=claude_rc.auth_status())


@txadmin_bp.route("/tx/api/claude/<action>", methods=["POST"])
@require_permission("txadmin.manage")
def api_claude_account_action(action):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    try:
        if action == "login":
            claude_rc.start_login()
            _audit("claude login started", "")
            return _ok(session="login")
        if action == "logout":
            claude_rc.logout()
            _audit("claude logout", "")
            return _ok(account=claude_rc.auth_status())
    except claude_rc.ClaudeError as exc:
        return _fail(exc)
    return _fail("Unknown action.", 404)


@txadmin_bp.route("/tx/api/claude/session/<key>")
@require_permission("txadmin.manage")
def api_claude_session(key):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    if not _SESSION_KEY_RE.match(key):
        return _fail("Unknown session.", 404)
    text = claude_rc.screen(key)
    info = claude_rc.analyse(text)
    return _ok(alive=text is not None, screen="\n".join((text or "").splitlines()[-80:]), **info)


@txadmin_bp.route("/tx/api/claude/session/<key>/<action>", methods=["POST"])
@require_permission("txadmin.manage")
def api_claude_session_action(key, action):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    if not _SESSION_KEY_RE.match(key):
        return _fail("Unknown session.", 404)
    d = _body()
    try:
        if action == "send":
            claude_rc.send(key, text=d.get("text") or None, keys=d.get("keys") or [], enter=bool(d.get("enter")))
            return _ok()
        if action == "stop":
            claude_rc.stop_session(key)
            return _ok()
    except claude_rc.ClaudeError as exc:
        return _fail(exc)
    return _fail("Unknown action.", 404)


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/claude")
@require_permission("txadmin.manage")
def api_claude_instance(inst_id):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    try:
        inst = _get(inst_id)
        root = txsvc._resources_root(inst)
    except txsvc.TxError as exc:
        return _fail(exc)
    links = TxClaudeLink.query.filter_by(instance_id=inst.id).order_by(TxClaudeLink.created_at).all()
    return _ok(account=claude_rc.auth_status(), resources_root=root, root_trusted=claude_rc.is_trusted(root),
               links=[_link_dict(l, inst) for l in links], targets=_link_targets(inst),
               trust_session=f"trust-{inst.id}", modes=list(claude_rc.PERMISSION_MODES))


@txadmin_bp.route("/tx/api/instance/<int:inst_id>/claude/<action>", methods=["POST"])
@require_permission("txadmin.manage")
def api_claude_instance_action(inst_id, action):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    d = _body()
    try:
        inst = _get(inst_id)
        if action == "trust":
            # trusting the resources folder covers every folder inside it
            claude_rc.start_trust(f"trust-{inst.id}", txsvc._resources_root(inst))
            _audit("claude trust started", inst.slug)
            return _ok(session=f"trust-{inst.id}")
        if action == "link-all":
            # one session per top-level [folder]; linking every resource would
            # start ~90 Claude Code processes and exhaust the server's memory
            mode = d.get("permission_mode") if d.get("permission_mode") in claude_rc.PERMISSION_MODES else "default"
            linked = {l.rel_path for l in TxClaudeLink.query.filter_by(instance_id=inst.id).all()}
            folders = [t["rel_path"] for t in _link_targets(inst) if t["kind"] == "folder" and "/" not in t["rel_path"]]
            can_start = claude_rc.auth_status().get("loggedIn") and claude_rc.is_trusted(txsvc._resources_root(inst))
            created, skipped = [], [f for f in folders if f in linked]
            for rel in folders:
                if rel in linked:
                    continue
                link = TxClaudeLink(instance_id=inst.id, rel_path=rel, name=f"{inst.name} · {rel}"[:120],
                                    permission_mode=mode, created_by=current_user.username)
                db.session.add(link)
                db.session.commit()
                if can_start:
                    try:
                        _start_link(link, _link_dir(inst, rel))
                    except claude_rc.ClaudeError as exc:
                        current_app.logger.warning("link-all start failed for %s: %s", rel, exc)
                created.append(rel)
            _audit("claude link all", f"{inst.slug}: {', '.join(created) or 'nothing new'}")
            return _ok(created=created, already=skipped, started=bool(can_start))
        if action in ("start-all", "stop-all"):
            done = []
            for link in TxClaudeLink.query.filter_by(instance_id=inst.id).all():
                key = claude_rc.link_key(link.id)
                if action == "stop-all":
                    if claude_rc.session_alive(key):
                        claude_rc.stop_session(key)
                        done.append(link.name)
                    link.enabled = False
                else:
                    path = _link_dir(inst, link.rel_path)
                    if not claude_rc.session_alive(key) and claude_rc.is_trusted(path):
                        _start_link(link, path)
                        done.append(link.name)
                    link.enabled = True
            db.session.commit()
            _audit(f"claude {action}", inst.slug)
            return _ok(done=done)
        if action == "link":
            rel = (d.get("rel_path") or "").strip().strip("/")
            if rel and rel not in {t["rel_path"] for t in _link_targets(inst)}:
                return _fail("Pick a folder from the list.")
            path = _link_dir(inst, rel)
            if TxClaudeLink.query.filter_by(instance_id=inst.id, rel_path=rel).first():
                return _fail("That folder is already linked.")
            mode = d.get("permission_mode") if d.get("permission_mode") in claude_rc.PERMISSION_MODES else "default"
            leaf = rel.split("/")[-1] if rel else "resources"
            link = TxClaudeLink(instance_id=inst.id, rel_path=rel, name=f"{inst.name} · {leaf}"[:120], permission_mode=mode,
                                created_by=current_user.username)
            db.session.add(link)
            db.session.commit()
            started = False
            if claude_rc.is_trusted(path) and claude_rc.auth_status().get("loggedIn"):
                _start_link(link, path)
                started = True
            _audit("claude link", f"{inst.slug}:{rel or '/'}")
            return _ok(link=_link_dict(link, inst), started=started)
    except (txsvc.TxError, claude_rc.ClaudeError) as exc:
        return _fail(exc)
    return _fail("Unknown action.", 404)


@txadmin_bp.route("/tx/api/claude/links/<int:link_id>/<action>", methods=["POST"])
@require_permission("txadmin.manage")
def api_claude_link_action(link_id, action):
    deny = _claude_admin_or_403()
    if deny:
        return deny
    link = db.session.get(TxClaudeLink, link_id)
    if not link:
        return _fail("Link not found.", 404)
    inst = db.session.get(TxInstance, link.instance_id)
    try:
        if action == "start":
            path = _link_dir(inst, link.rel_path)
            if not claude_rc.auth_status().get("loggedIn"):
                return _fail("Log in to Claude Code first.")
            if not claude_rc.is_trusted(path):
                return _fail("Trust the resources folder first.")
            _start_link(link, path)
            link.enabled = True
        elif action == "stop":
            claude_rc.stop_session(claude_rc.link_key(link.id))
            link.enabled = False
        elif action == "remove":
            claude_rc.stop_session(claude_rc.link_key(link.id))
            try:
                claude_hooks.uninstall(_link_dir(inst, link.rel_path))
            except (txsvc.TxError, OSError):
                pass
            db.session.delete(link)
            db.session.commit()
            _audit("claude unlink", f"{inst.slug if inst else '?'}:{link.rel_path or '/'}")
            return _ok()
        elif action == "settings":
            if d := _body():
                if d.get("permission_mode") in claude_rc.PERMISSION_MODES:
                    link.permission_mode = d["permission_mode"]
        else:
            return _fail("Unknown action.", 404)
        db.session.commit()
        _audit(f"claude link {action}", f"{inst.slug if inst else '?'}:{link.rel_path or '/'}")
        return _ok(link=_link_dict(link, inst))
    except (txsvc.TxError, claude_rc.ClaudeError) as exc:
        return _fail(exc)


def resume_claude_links(app):
    """After a reboot the tmux/systemd sessions are gone; bring enabled
    links back once the panel is up."""
    import threading

    def run():
        time.sleep(20)
        with app.app_context():
            try:
                if not claude_rc.auth_status().get("loggedIn"):
                    return
                for link in TxClaudeLink.query.filter_by(enabled=True).all():
                    if claude_rc.session_alive(claude_rc.link_key(link.id)):
                        continue
                    inst = db.session.get(TxInstance, link.instance_id)
                    try:
                        path = _link_dir(inst, link.rel_path)
                        if claude_rc.is_trusted(path):
                            claude_hooks.write_config(app)
                            claude_hooks.install(path)
                            claude_rc.start_remote_control(link.id, path, link.name, link.permission_mode)
                            app.logger.warning("Claude link resumed: %s", link.name)
                    except Exception as exc:  # noqa: BLE001
                        app.logger.warning("Claude link %s not resumed: %s", link.name, exc)
            except Exception as exc:  # noqa: BLE001
                app.logger.warning("Claude link resume failed: %s", exc)

    threading.Thread(target=run, daemon=True, name="claude-link-resume").start()


@txadmin_bp.route("/tx/api/job/<job_id>")
@require_permission("txadmin.manage")
def api_job(job_id):
    job = db.session.get(Job, job_id)
    if not job or not job.target.startswith("tx:"):
        return _fail("Job not found.", 404)
    return _ok(job=job.to_dict())
