#!/usr/bin/env bash
# Fixes the client-facing install experience on the instances page:
#   1. REAL BUG: the shown Linux command was missing --admin-url entirely,
#      which install.sh requires - every client who copy-pasted it verbatim
#      would have hit "ERROR: --admin-url is required" immediately. Caught
#      only by testing the EXACT string the page renders, not a
#      hand-written equivalent.
#   2. No Windows command was shown at all, and the note beneath the table
#      incorrectly said "Windows MSI" (the actual artifact is install.ps1).
#   3. Added a Linux/Windows tab picker (defaults to the visiting browser's
#      own OS) and a one-click Copy button for each, so a client just opens
#      this page on the machine they're installing onto and clicks Copy -
#      no manual token/URL assembly, no risk of the line-ordering mistakes
#      that come from typing multi-step instructions by hand.
# Verified by extracting the EXACT command string the real rendered page
# produces and running it end-to-end against a real server - not a
# hand-reconstructed approximation. Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Rewriting app/templates/instances/list.html"
cat > app/templates/instances/list.html << 'LIST_EOF_MARKER'
{% extends "base.html" %}
{% block title %}Fleet — {{ company.name }}{% endblock %}
{% block content %}
<div class="page-header">
  <div class="titles">
    <a href="{{ url_for('companies.detail', company_id=company.public_id) }}" class="crumb">← {{ company.name }}</a>
    <h1>Kiosk instances</h1>
  </div>
  {% if role in ["owner", "administrator"] %}
    <div class="page-actions">
      <a href="{{ url_for('instances.bulk_schedule', company_id=company.public_id) }}" class="btn btn-secondary btn-sm">Push to multiple →</a>
      <a href="{{ url_for('rollouts.list_rollouts', company_id=company.public_id) }}" class="btn btn-secondary btn-sm">Staged rollouts →</a>
    </div>
  {% endif %}
</div>

<div class="stat-grid">
  <div class="stat-tile"><div class="stat-num">{{ stats.total }}</div><div class="stat-label">Total kiosks</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--green);">{{ stats.online }}</div><div class="stat-label">Online</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--muted);">{{ stats.offline }}</div><div class="stat-label">Offline</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--amber);">{{ stats.updating }}</div><div class="stat-label">Updating</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:{{ 'var(--red)' if stats.failed_24h else 'var(--text)' }};">{{ stats.failed_24h }}</div><div class="stat-label">Failed (24h)</div></div>
</div>

<div class="panel" style="padding:8px 22px 20px;">
  {% if instances %}
    <div class="table-scroll">
    <table>
      <thead>
        <tr><th>Name</th><th>OS</th><th>Version</th><th>Connection</th><th>Update status</th><th>Last seen</th><th></th></tr>
      </thead>
      <tbody>
        {% for i in instances %}
          {% set d = i.active_deployment() %}
          <tr>
            <td style="font-weight:600;">{{ i.display_name() }}</td>
            <td>{{ i.os }}{% if i.os_version %} <span class="muted">({{ i.os_version }})</span>{% endif %}</td>
            <td class="mono">{{ i.app_version or '—' }}</td>
            <td>
              {% if i.connection_status == 'online' %}
                <span class="pill pill-green">Online</span>
              {% else %}
                <span class="pill pill-muted">Offline</span>
              {% endif %}
            </td>
            <td>
              {% if d %}
                <span class="pill pill-amber">{{ d.status.replace('_',' ')|capitalize }} → v{{ d.package.version }}</span>
              {% else %}
                <span class="muted">Up to date</span>
              {% endif %}
            </td>
            <td class="muted">{{ i.last_seen_at.strftime('%Y-%m-%d %H:%M UTC') if i.last_seen_at else 'never' }}</td>
            <td><a href="{{ url_for('instances.detail', company_id=company.public_id, instance_id=i.public_id) }}" class="btn btn-secondary btn-sm">Open →</a></td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
  {% else %}
    <div class="empty">No instances registered yet. Use an enrollment token below to connect your first kiosk.</div>
  {% endif %}
</div>

{% if role in ["owner", "administrator", "manager"] %}
<div class="panel">
  <h2>Enrollment tokens</h2>
  <p class="muted">A customer runs the install command below on their server; it registers the new kiosk against this company automatically — no manual pairing required.</p>

  {% if tokens %}
    <div class="table-scroll">
    <table style="margin-bottom:20px;">
      <thead><tr><th>Label</th><th>Uses</th><th>Expires</th><th class="wrap-cell">Install command</th><th></th></tr></thead>
      <tbody>
        {% for t in tokens %}
          <tr>
            <td>{{ t.label or '—' }}</td>
            <td class="mono">{{ t.use_count }}{% if t.max_uses %} / {{ t.max_uses }}{% endif %}</td>
            <td class="muted">{{ t.expires_at.strftime('%Y-%m-%d') if t.expires_at else 'never' }}</td>
            <td class="wrap-cell">
              <div class="install-tabs" data-token="{{ t.token }}">
                <div class="install-tab-buttons">
                  <button type="button" class="install-tab-btn active" data-os="linux">Linux</button>
                  <button type="button" class="install-tab-btn" data-os="windows">Windows</button>
                </div>
                <div class="install-tab-panel" data-os-panel="linux">
                  <code class="install-cmd">curl -fsSL {{ config.BASE_URL }}/install.sh | sudo bash -s -- --token {{ t.token }} --admin-url {{ config.BASE_URL }}</code>
                  <button type="button" class="btn btn-secondary btn-sm copy-btn">Copy</button>
                </div>
                <div class="install-tab-panel" data-os-panel="windows" style="display:none;">
                  <code class="install-cmd">irm {{ config.BASE_URL }}/install.ps1 -OutFile install.ps1; .\install.ps1 -Token {{ t.token }} -AdminUrl {{ config.BASE_URL }}</code>
                  <button type="button" class="btn btn-secondary btn-sm copy-btn">Copy</button>
                  <div class="muted" style="font-size:11px; margin-top:4px;">Run in an elevated (Administrator) PowerShell window. Requires Python 3.10+ already installed from python.org (not the Microsoft Store) with "Add to PATH" checked.</div>
                </div>
              </div>
            </td>
            <td>
              <form method="post" action="{{ url_for('instances.revoke_token', company_id=company.public_id, token_id=t.id) }}">
                <button type="submit" class="btn btn-danger btn-sm">Revoke</button>
              </form>
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
  {% endif %}

  <p class="muted" style="font-size:12px;">
    Note: the install scripts (Ubuntu/Debian and Windows PowerShell) ship with the
    Instance Agent — this token is what it will call
    <code>POST /api/v1/instances/register</code> with.
  </p>

  <form method="post" action="{{ url_for('instances.new_token', company_id=company.public_id) }}" class="form-row" style="margin-top:14px;">
    <div>
      <label>Label (optional)</label>
      <input type="text" name="label" placeholder="e.g. Branch 2 rollout">
    </div>
    <div>
      <label>Expires in (days, optional)</label>
      <input type="text" name="expires_in_days" placeholder="never">
    </div>
    <div>
      <label>Max uses (optional)</label>
      <input type="text" name="max_uses" placeholder="unlimited">
    </div>
    <div style="flex:0 0 auto;">
      <button type="submit">Generate token</button>
    </div>
  </form>
</div>
{% endif %}
{% endblock %}
LIST_EOF_MARKER

echo "==> Rewriting app/templates/base.html (adds tab/copy JS + CSS)"
cat > app/templates/base.html << 'BASE_EOF_MARKER'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{% block title %}OpsLab Admin Panel{% endblock %}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root{
    --bg:#0a0d17;
    --surface:#0e1220;
    --surface-2:#141828;
    --surface-3:#191e33;
    --border:#242a3d;
    --border-soft:#1b2032;
    --text:#e9ebf3;
    --muted:#8a91a8;
    --muted-2:#5e6479;
    --accent:#7c6cf6;
    --accent-hover:#8f81f8;
    --accent-dim:rgba(124,108,246,.14);
    --green:#34c98a;
    --green-dim:rgba(52,201,138,.14);
    --amber:#e3a83f;
    --amber-dim:rgba(227,168,63,.14);
    --red:#f0605c;
    --red-dim:rgba(240,96,92,.14);
    --blue:#4f8ef7;
    --blue-dim:rgba(79,142,247,.14);
    --sidebar-w:232px;
    --radius:8px;
  }
  *{box-sizing:border-box;}
  html,body{height:100%;}
  body{
    margin:0; background:var(--bg); color:var(--text);
    font-family:'Inter',system-ui,-apple-system,"Segoe UI",sans-serif;
    font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased;
  }
  a{color:var(--accent); text-decoration:none;}
  a:hover{color:var(--accent-hover);}
  code, .mono{font-family:'JetBrains Mono',ui-monospace,monospace;}
  ::selection{background:var(--accent-dim); color:var(--text);}
  :focus-visible{outline:2px solid var(--accent); outline-offset:2px;}

  h1{font-size:20px; font-weight:600; margin:0; letter-spacing:-.01em;}
  h2{font-size:14.5px; font-weight:600; margin:0 0 14px; color:var(--text);}
  h3{font-size:13px; font-weight:600; margin:0 0 8px; color:var(--muted);}
  .muted{color:var(--muted);}
  p{margin:0 0 10px;}

  /* ---------- Auth (unauthenticated) shell ---------- */
  .authshell{min-height:100%; display:flex; flex-direction:column;}
  .auth-top{
    display:flex; align-items:center; justify-content:space-between;
    padding:18px 28px; border-bottom:1px solid var(--border-soft);
  }
  .auth-main{flex:1; display:flex; align-items:center; justify-content:center; padding:40px 20px;}
  .auth-card{width:100%; max-width:400px;}
  .auth-card .panel{margin:0;}

  /* ---------- Authenticated app shell ---------- */
  .appshell{display:flex; min-height:100%;}
  .sidebar{
    width:var(--sidebar-w); flex-shrink:0; background:var(--surface);
    border-right:1px solid var(--border-soft);
    display:flex; flex-direction:column; position:fixed; top:0; bottom:0; left:0;
  }
  .sidebar-brand{
    display:flex; align-items:center; gap:9px; padding:20px 20px 16px;
    font-weight:700; font-size:14.5px; letter-spacing:-.01em;
  }
  .sidebar-brand .mark{
    width:26px; height:26px; border-radius:7px; flex-shrink:0;
    background:linear-gradient(155deg, var(--accent), #4d3fc4);
    display:flex; align-items:center; justify-content:center;
    font-size:13px; font-weight:700; color:#fff;
  }
  .sidebar-brand .accent{color:var(--accent);}
  .sidebar-scroll{flex:1; overflow-y:auto; padding:6px 12px;}
  .nav-group{margin-bottom:18px;}
  .nav-label{
    font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.06em;
    color:var(--muted-2); padding:8px 10px 6px;
  }
  .nav-link{
    display:flex; align-items:center; gap:10px; padding:8px 10px; border-radius:7px;
    color:var(--muted); font-size:13.5px; font-weight:500; margin-bottom:1px;
  }
  .nav-link svg{flex-shrink:0; opacity:.85;}
  .nav-link:hover{background:var(--surface-2); color:var(--text); text-decoration:none;}
  .nav-link.active{background:var(--accent-dim); color:var(--accent);}
  .nav-link.active svg{opacity:1;}
  .nav-context{
    margin:4px 10px 10px; padding:9px 10px; border-radius:7px;
    background:var(--surface-2); border:1px solid var(--border-soft);
  }
  .nav-context-label{font-size:10.5px; color:var(--muted-2); text-transform:uppercase; letter-spacing:.05em; margin-bottom:2px;}
  .nav-context-name{font-size:13px; font-weight:600; color:var(--text); overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
  .sidebar-foot{
    border-top:1px solid var(--border-soft); padding:12px; display:flex; align-items:center; gap:10px;
  }
  .avatar{
    width:30px; height:30px; border-radius:50%; background:var(--surface-3); color:var(--text);
    display:flex; align-items:center; justify-content:center; font-size:12.5px; font-weight:600;
    flex-shrink:0; border:1px solid var(--border);
  }
  .sidebar-foot-info{flex:1; min-width:0;}
  .sidebar-foot-name{font-size:13px; font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;}
  .sidebar-foot-links{font-size:11.5px; color:var(--muted-2);}
  .sidebar-foot-links a{color:var(--muted); font-size:11.5px;}
  .sidebar-foot-links a:hover{color:var(--text);}

  .main{margin-left:var(--sidebar-w); flex:1; min-width:0; padding:32px 40px 60px;}
  .wrap{max-width:1080px; margin:0 auto;}

  /* ---------- Page header ---------- */
  .page-header{display:flex; justify-content:space-between; align-items:flex-start; gap:16px; margin-bottom:22px;}
  .page-header .titles{min-width:0;}
  .crumb{
    display:inline-flex; align-items:center; gap:5px; font-size:12.5px; color:var(--muted);
    margin-bottom:8px;
  }
  .crumb:hover{color:var(--text);}
  .page-sub{margin-top:5px; font-size:13px; color:var(--muted); display:flex; align-items:center; gap:8px; flex-wrap:wrap;}
  .page-actions{display:flex; gap:8px; flex-shrink:0;}

  /* ---------- Panels ---------- */
  .panel{
    background:var(--surface-2); border:1px solid var(--border);
    border-radius:var(--radius); padding:22px; margin-bottom:16px;
  }
  .panel-head{display:flex; justify-content:space-between; align-items:center; margin-bottom:14px;}
  .panel-head h2{margin:0;}

  /* ---------- Stat tiles ---------- */
  .stat-grid{display:grid; grid-template-columns:repeat(auto-fit, minmax(120px,1fr)); gap:10px; margin-bottom:20px;}
  .stat-tile{
    background:var(--surface-2); border:1px solid var(--border); border-radius:var(--radius);
    padding:16px 16px 14px;
  }
  .stat-num{font-size:24px; font-weight:700; letter-spacing:-.01em; line-height:1.1; font-variant-numeric:tabular-nums;}
  .stat-label{font-size:11.5px; color:var(--muted); margin-top:5px; font-weight:500;}

  /* ---------- Forms ---------- */
  label{display:block; margin:14px 0 6px; color:var(--muted); font-size:12.5px; font-weight:500;}
  label:first-child{margin-top:0;}
  input[type=text], input[type=email], input[type=password], input[type=tel],
  input[type=datetime-local], textarea, select{
    width:100%; padding:9px 12px; border-radius:7px; border:1px solid var(--border);
    background:var(--surface); color:var(--text); font-size:13.5px; font-family:inherit;
  }
  textarea{font-family:'JetBrains Mono',ui-monospace,monospace; font-size:12.5px;}
  input:focus, textarea:focus, select:focus{outline:none; border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-dim);}
  input::placeholder, textarea::placeholder{color:var(--muted-2);}
  input[type=checkbox]{width:auto;}
  .checkline{display:flex; align-items:center; gap:8px; margin-top:10px; font-size:13px; color:var(--muted);}
  .field-hint{font-size:12px; color:var(--muted-2); margin-top:4px;}
  .form-row{display:flex; gap:12px; align-items:flex-end;}
  .form-row > div{flex:1;}
  .checklist{
    border:1px solid var(--border); border-radius:7px; padding:6px 10px; max-height:260px; overflow-y:auto;
    background:var(--surface);
  }
  .checklist label{
    display:flex; align-items:center; gap:9px; margin:2px 0; padding:6px 2px;
    font-size:13px; color:var(--text); font-weight:400; border-bottom:1px solid var(--border-soft);
  }
  .checklist label:last-child{border-bottom:none;}

  /* ---------- Buttons ---------- */
  button, .btn{
    display:inline-flex; align-items:center; gap:6px;
    background:var(--accent); color:#fff; border:none;
    padding:9px 15px; border-radius:7px; font-size:13.5px; cursor:pointer; font-weight:600;
    font-family:inherit; transition:background-color .12s ease;
  }
  button:hover, .btn:hover{background:var(--accent-hover); text-decoration:none;}
  .btn-secondary{background:var(--surface-3); border:1px solid var(--border); color:var(--text);}
  .btn-secondary:hover{background:var(--surface-2); border-color:var(--muted-2);}
  .btn-danger{background:var(--red-dim); color:var(--red); border:1px solid rgba(240,96,92,.3);}
  .btn-danger:hover{background:rgba(240,96,92,.22);}
  .btn-sm{padding:6px 11px; font-size:12.5px;}
  .btn-block{width:100%; justify-content:center;}

  /* ---------- Flash ---------- */
  .flash{padding:11px 14px; border-radius:7px; margin-bottom:14px; font-size:13.5px; border:1px solid transparent;}
  .flash-success{background:var(--green-dim); border-color:rgba(52,201,138,.3); color:var(--green);}
  .flash-danger{background:var(--red-dim); border-color:rgba(240,96,92,.3); color:var(--red);}
  .flash-warning{background:var(--amber-dim); border-color:rgba(227,168,63,.3); color:var(--amber);}
  .flash-info{background:var(--blue-dim); border-color:rgba(79,142,247,.3); color:var(--blue);}

  /* ---------- Tables ---------- */
  .table-scroll{overflow-x:auto; margin:-4px -4px 0;}
  table{width:100%; border-collapse:collapse;}
  th, td{text-align:left; padding:11px 10px; border-bottom:1px solid var(--border-soft); font-size:13.5px; white-space:nowrap;}
  td.wrap-cell, th.wrap-cell{white-space:normal;}
  th{color:var(--muted-2); font-weight:600; font-size:11px; text-transform:uppercase; letter-spacing:.05em;}
  tbody tr:last-child td{border-bottom:none;}
  tbody tr:hover td{background:rgba(255,255,255,.012);}
  .kv-table th{width:190px; text-transform:none; font-size:12.5px; letter-spacing:0; color:var(--muted); font-weight:500; vertical-align:top; padding-top:12px;}
  .kv-table td{vertical-align:top; padding-top:12px;}

  /* ---------- Status pills ---------- */
  .pill{
    display:inline-flex; align-items:center; gap:5px; padding:3px 9px; border-radius:20px;
    font-size:11.5px; font-weight:600; white-space:nowrap;
  }
  .pill::before{content:''; width:6px; height:6px; border-radius:50%; background:currentColor; flex-shrink:0;}
  .pill-green{background:var(--green-dim); color:var(--green);}
  .pill-red{background:var(--red-dim); color:var(--red);}
  .pill-amber{background:var(--amber-dim); color:var(--amber);}
  .pill-blue{background:var(--blue-dim); color:var(--blue);}
  .pill-muted{background:rgba(138,145,168,.14); color:var(--muted);}
  .pill-accent{background:var(--accent-dim); color:var(--accent);}

  /* ---------- Role badges (kept semantically distinct from status pills) ---------- */
  .badge{padding:2px 8px; border-radius:20px; font-size:11px; font-weight:600;}
  .badge-owner{background:var(--accent-dim); color:var(--accent);}
  .badge-administrator{background:var(--blue-dim); color:var(--blue);}
  .badge-manager{background:var(--amber-dim); color:var(--amber);}
  .badge-operator{background:rgba(138,145,168,.14); color:var(--muted);}

  /* ---------- List rows (companies list etc.) ---------- */
  .row-list{list-style:none; margin:0; padding:0;}
  .row-list li{
    display:flex; justify-content:space-between; align-items:center;
    padding:14px 16px; border:1px solid var(--border); border-radius:var(--radius); margin-bottom:8px;
    background:var(--surface-2);
  }
  .row-actions form{display:inline;}

  .empty{
    text-align:center; padding:36px 20px; color:var(--muted); font-size:13.5px;
  }

  code{font-family:'JetBrains Mono',ui-monospace,monospace; background:var(--surface); padding:2px 6px; border-radius:4px; font-size:12px; color:var(--text); border:1px solid var(--border-soft);}

  @media (max-width: 880px){
    .sidebar{transform:translateX(-100%);}
    .main{margin-left:0; padding:24px 18px 50px;}
  }

  /* Install command tabs (per-token OS picker) */
  .install-tabs{min-width:280px;}
  .install-tab-buttons{display:flex; gap:4px; margin-bottom:6px;}
  .install-tab-btn{
    background:transparent; border:1px solid var(--panel-border); color:var(--muted);
    padding:4px 10px; font-size:11.5px; border-radius:6px; cursor:pointer;
  }
  .install-tab-btn.active{background:var(--accent); color:#fff; border-color:var(--accent);}
  .install-tab-panel{display:flex; align-items:flex-start; gap:8px; flex-wrap:wrap;}
  .install-cmd{font-size:11px; word-break:break-all; max-width:420px; display:inline-block;}
  .copy-btn.copied{background:var(--green); color:#fff; border-color:var(--green);}
</style>
</head>
<body>
{% macro flashes() %}
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% if messages %}
      {% for category, message in messages %}
        <div class="flash flash-{{ category }}">{{ message }}</div>
      {% endfor %}
    {% endif %}
  {% endwith %}
{% endmacro %}
{% if current_user.is_authenticated %}
  {% import "_icons.html" as icons %}
  <div class="appshell">
    <aside class="sidebar">
      <a href="{{ url_for('dashboard.index') }}" class="sidebar-brand" style="color:var(--text);">
        <span class="mark">O</span>OpsLab <span class="accent">Admin</span>
      </a>
      <div class="sidebar-scroll">
        {% if current_user.is_platform_admin %}
        <div class="nav-group">
          <div class="nav-label">Platform</div>
          <a href="{{ url_for('platform.dashboard') }}" class="nav-link {{ 'active' if request.endpoint == 'platform.dashboard' }}">{{ icons.icon('overview') }}Overview</a>
          <a href="{{ url_for('releases.list_releases') }}" class="nav-link {{ 'active' if request.blueprint == 'releases' }}">{{ icons.icon('releases') }}Releases</a>
          <a href="{{ url_for('platform.list_users') }}" class="nav-link {{ 'active' if request.endpoint and request.endpoint.startswith('platform.') and 'user' in request.endpoint }}">{{ icons.icon('user') }}Users</a>
        </div>
        {% endif %}

        {% if company is defined and company %}
        <div class="nav-context">
          <div class="nav-context-label">Company</div>
          <div class="nav-context-name">{{ company.name }}</div>
        </div>
        <div class="nav-group">
          <div class="nav-label">{{ company.name }}</div>
          <a href="{{ url_for('companies.detail', company_id=company.public_id) }}" class="nav-link {{ 'active' if request.endpoint == 'companies.detail' }}">{{ icons.icon('companies') }}Company home</a>
          <a href="{{ url_for('instances.list_instances', company_id=company.public_id) }}" class="nav-link {{ 'active' if request.endpoint in ['instances.list_instances','instances.detail','instances.bulk_schedule'] }}">{{ icons.icon('fleet') }}Fleet</a>
          <a href="{{ url_for('rollouts.list_rollouts', company_id=company.public_id) }}" class="nav-link {{ 'active' if request.blueprint == 'rollouts' }}">{{ icons.icon('rollouts') }}Rollouts</a>
          <a href="{{ url_for('instances.audit_log', company_id=company.public_id) }}" class="nav-link {{ 'active' if request.endpoint == 'instances.audit_log' }}">{{ icons.icon('audit') }}Audit log</a>
        </div>
        <div class="nav-group">
          <div class="nav-label">Workspace</div>
          <a href="{{ url_for('dashboard.index') }}" class="nav-link">{{ icons.icon('back', 14) }}All companies</a>
        </div>
        {% else %}
        <div class="nav-group">
          <div class="nav-label">Workspace</div>
          <a href="{{ url_for('dashboard.index') }}" class="nav-link {{ 'active' if request.endpoint == 'dashboard.index' }}">{{ icons.icon('companies') }}Companies</a>
        </div>
        {% endif %}
      </div>
      <div class="sidebar-foot">
        <div class="avatar">{{ current_user.full_name[:1]|upper }}</div>
        <div class="sidebar-foot-info">
          <div class="sidebar-foot-name">{{ current_user.full_name }}</div>
          <div class="sidebar-foot-links"><a href="{{ url_for('auth.profile') }}">Profile</a> &nbsp;·&nbsp; <a href="{{ url_for('auth.logout') }}">Log out</a></div>
        </div>
      </div>
    </aside>
    <div class="main">
      <div class="wrap">
        {{ flashes() }}
        {% block content %}{% endblock %}
      </div>
    </div>
  </div>
{% else %}
  <div class="authshell">
    <div class="auth-top">
      <div class="sidebar-brand" style="padding:0;">
        <span class="mark">O</span>OpsLab <span class="accent">Admin</span>
      </div>
      <div>
        <a href="{{ url_for('auth.login') }}">Log in</a>
        &nbsp;&nbsp;<a href="{{ url_for('auth.signup') }}" class="btn btn-sm">Sign up</a>
      </div>
    </div>
    <div class="auth-main">
      <div class="auth-card">
        {{ flashes() }}
        {{ self.content() }}
      </div>
    </div>
  </div>
{% endif %}
<script>
document.addEventListener('DOMContentLoaded', function () {
  var isWindows = /Windows/i.test(navigator.userAgent || navigator.platform || '');

  document.querySelectorAll('.install-tabs').forEach(function (wrap) {
    var buttons = wrap.querySelectorAll('.install-tab-btn');
    var panels = wrap.querySelectorAll('.install-tab-panel');

    function activate(osName) {
      buttons.forEach(function (b) { b.classList.toggle('active', b.dataset.os === osName); });
      panels.forEach(function (p) { p.style.display = (p.dataset.osPanel === osName) ? '' : 'none'; });
    }

    // Default to the visiting browser's own OS — a client opening this page
    // on the machine they're about to install onto sees the right tab first.
    activate(isWindows ? 'windows' : 'linux');

    buttons.forEach(function (btn) {
      btn.addEventListener('click', function () { activate(btn.dataset.os); });
    });

    wrap.querySelectorAll('.copy-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var code = btn.previousElementSibling.textContent;
        navigator.clipboard.writeText(code).then(function () {
          var original = btn.textContent;
          btn.textContent = 'Copied!';
          btn.classList.add('copied');
          setTimeout(function () { btn.textContent = original; btn.classList.remove('copied'); }, 1500);
        });
      });
    });
  });
});
</script>
</body>
</html>
BASE_EOF_MARKER

echo ""
echo "Done. Restart the app the same way as before:"
echo "    pkill -f 'admin_panel/run.py'"
echo "    cd /root/admin_panel && source venv/bin/activate && nohup python run.py > /root/admin_panel/app.log 2>&1 &"
echo ""
echo "Then open a company's instances page in a browser and confirm you see"
echo "Linux/Windows tabs with a Copy button next to each enrollment token."
