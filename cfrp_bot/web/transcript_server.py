"""
Transcript Web Server — serves ticket transcripts as styled HTML pages.
Runs on port 5000 alongside the bot.
"""

import os
import json
from flask import Flask, abort, render_template_string
from datetime import datetime

TRANSCRIPT_DIR = os.path.join(os.path.dirname(__file__), "..", "transcripts")
WEB_PORT       = int(os.environ.get("WEB_PORT", "5000"))

app = Flask(__name__)

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{ ticket_id }} — CFRP Transcript</title>
<style>
:root{--bg:#1e1f22;--surface:#2b2d31;--surface2:#313338;--border:#3f4248;
  --text:#dbdee1;--muted:#949ba4;--accent:#5865f2;--green:#2d7d46;
  --red:#da373c;--yellow:#f0b232;}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',sans-serif}

.header{background:var(--surface);border-bottom:1px solid var(--border);
  padding:20px 32px;display:flex;align-items:center;gap:14px}
.badge{background:var(--accent);color:#fff;padding:4px 12px;border-radius:20px;
  font-size:13px;font-weight:700;letter-spacing:.5px}
.header h1{font-size:20px;font-weight:700}
.header .sub{color:var(--muted);font-size:13px;margin-top:3px}

.meta{background:var(--surface2);border-bottom:1px solid var(--border);
  padding:14px 32px;display:flex;gap:40px;flex-wrap:wrap}
.mi{display:flex;flex-direction:column;gap:2px}
.mi .lbl{font-size:11px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.5px}
.mi .val{font-size:14px}

.msgs{padding:24px 32px;max-width:880px;margin:0 auto}

.divider{display:flex;align-items:center;gap:12px;color:var(--muted);
  font-size:12px;font-weight:600;margin:24px 0 16px}
.divider::before,.divider::after{content:'';flex:1;height:1px;background:var(--border)}

.msg{display:flex;gap:14px;padding:4px 8px;border-radius:6px}
.msg:hover{background:rgba(255,255,255,.04)}
.av{width:40px;height:40px;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-weight:700;font-size:15px;flex-shrink:0;
  margin-top:2px;color:#fff;text-transform:uppercase}
.mb{flex:1;min-width:0}
.mh{display:flex;align-items:baseline;gap:8px;margin-bottom:2px}
.au{font-weight:600;font-size:15px}
.au.bot{color:var(--accent)}
.au.staff{color:var(--yellow)}
.ts{font-size:11px;color:var(--muted)}
.ct{font-size:14px;line-height:1.55;word-break:break-word;white-space:pre-wrap}
.att{color:var(--accent);font-size:13px;display:inline-block;margin-top:4px}
.sys{text-align:center;color:var(--muted);font-size:12px;
  padding:6px 0;font-style:italic;margin:4px 0}

footer{text-align:center;color:var(--muted);font-size:12px;
  padding:32px;border-top:1px solid var(--border);margin-top:32px}
</style>
</head>
<body>
<div class="header">
  <div>
    <div style="display:flex;align-items:center;gap:10px">
      <span class="badge">{{ ticket_id }}</span>
      <h1>{{ ticket_type }} Ticket</h1>
    </div>
    <div class="sub">Cape Flats Roleplay &bull; Ticket Transcript</div>
  </div>
</div>
<div class="meta">
  <div class="mi"><span class="lbl">Ticket ID</span><span class="val">{{ ticket_id }}</span></div>
  <div class="mi"><span class="lbl">Type</span><span class="val">{{ ticket_type }}</span></div>
  <div class="mi"><span class="lbl">Opened By</span><span class="val">{{ opened_by }}</span></div>
  <div class="mi"><span class="lbl">Opened</span><span class="val">{{ opened_at }}</span></div>
  <div class="mi"><span class="lbl">Closed By</span><span class="val">{{ closed_by }}</span></div>
  <div class="mi"><span class="lbl">Closed</span><span class="val">{{ closed_at }}</span></div>
  <div class="mi"><span class="lbl">Messages</span><span class="val">{{ message_count }}</span></div>
</div>
<div class="msgs">
{% set ns = namespace(last_day='') %}
{% for m in messages %}
  {% if m.day != ns.last_day %}
    <div class="divider">{{ m.day }}</div>
    {% set ns.last_day = m.day %}
  {% endif %}
  {% if m.system %}
    <div class="sys">{{ m.content }}</div>
  {% else %}
    <div class="msg">
      <div class="av" style="background:{{ m.color }}">{{ m.initial }}</div>
      <div class="mb">
        <div class="mh">
          <span class="au {{ m.role }}">{{ m.author }}</span>
          <span class="ts">{{ m.time }}</span>
        </div>
        {% if m.content %}<div class="ct">{{ m.content }}</div>{% endif %}
        {% for a in m.attachments %}<a class="att" href="{{ a }}" target="_blank">📎 {{ a }}</a>{% endfor %}
      </div>
    </div>
  {% endif %}
{% endfor %}
</div>
<footer>Cape Flats Roleplay &bull; {{ ticket_id }} &bull; Auto-generated transcript</footer>
</body></html>"""

COLORS = ["#5865f2","#57f287","#fee75c","#eb459e","#ed4245",
          "#3498db","#e67e22","#9b59b6","#1abc9c","#e74c3c"]

def _color(name):  return COLORS[hash(name) % len(COLORS)]
def _initial(name):
    p = name.split()
    return (p[0][0] + (p[-1][0] if len(p)>1 else "")).upper()

@app.route("/t/<tid>")
def view(tid):
    path = os.path.join(TRANSCRIPT_DIR, f"{tid.upper()}.json")
    if not os.path.exists(path):
        abort(404)
    with open(path) as f:
        data = json.load(f)
    msgs = []
    for m in data.get("messages", []):
        dt = datetime.fromisoformat(m["ts"])
        msgs.append(dict(
            day=dt.strftime("%B %d, %Y"), time=dt.strftime("%H:%M"),
            author=m["author"], initial=_initial(m["author"]),
            color=_color(m["author"]), role=m.get("role",""),
            content=m.get("content",""), attachments=m.get("attachments",[]),
            system=m.get("system", False),
        ))
    return render_template_string(HTML,
        ticket_id=data["ticket_id"], ticket_type=data["ticket_type"],
        opened_by=data["opened_by"], opened_at=data["opened_at"],
        closed_by=data["closed_by"], closed_at=data["closed_at"],
        message_count=len([m for m in msgs if not m["system"]]),
        messages=msgs)

@app.route("/")
def index():
    files = sorted([f[:-5] for f in os.listdir(TRANSCRIPT_DIR) if f.endswith(".json")], reverse=True)
    rows = "".join(f'<li style="padding:4px 0"><a href="/t/{f}" style="color:#5865f2;text-decoration:none">{f}</a></li>' for f in files[:100])
    return f'<html><body style="font-family:sans-serif;background:#1e1f22;color:#dbdee1;padding:40px;max-width:600px;margin:auto"><h2 style="margin-bottom:8px">CFRP Transcripts</h2><p style="color:#949ba4;margin-bottom:20px">{len(files)} transcripts</p><ul style="list-style:none;padding:0">{rows}</ul></body></html>'

if __name__ == "__main__":
    os.makedirs(TRANSCRIPT_DIR, exist_ok=True)
    app.run(host="0.0.0.0", port=WEB_PORT, debug=False)
